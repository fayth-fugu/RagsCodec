#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-ItemGroupsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses ItemGroups data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded ItemGroups data of a source folder back into the
    ItemGroups table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-ItemGroupsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'ItemGroups.yaml' file of the source folder is read as a YAML
    document holding a top-level 'ItemGroups' mapping whose value is a
    sequence with one entry per item group, each mapping the two data
    columns of the ItemGroups table: the Name key and the Parent column
    value. One table row is appended per item group entry (the ID identity
    column is excluded and auto-supplied by the database), replicating the
    row order of the original expansion: entries keep their YAML sequence
    order, which is the ascending Name order of the original table read.

    The 'ItemGroups.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'ItemGroups' envelope
      around the entry sequence, so a non-mapping document predates this
      layout). Keys of the document other than the 'ItemGroups' envelope
      key are ignored with a warning.
    - A document whose ItemGroups value is missing or null contributes no
      rows and is skipped with a warning. An ItemGroups value which is an
      empty string or whitespace-only scalar is skipped with a warning as
      well. An ItemGroups value which is an empty sequence is treated like
      the empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - An ItemGroups value which is a scalar or a single mapping (as
      hand-edited files omitting the trailing sequence dash commonly are)
      is accepted as the single entry of the sequence with a warning (for
      a scalar entry this aborts the operation in the entry validation
      below); a value of any other type aborts the whole operation with
      an exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful row can be derived from it.
    - An entry whose Name value is missing, null, empty or whitespace-only
      is skipped in its entirety with a warning, as no item group entry
      key can be derived from it.
    - A scalar Name or Parent value which is not a string (a hand-edited
      unquoted number, for example) is coerced to its string form with a
      warning; the string form of format-sensitive values is derived with
      the invariant culture, so such a value round-trips through hosts of
      different cultures. A Name or Parent value which is a sequence or a
      mapping aborts the whole operation with an exception, as no
      meaningful scalar can be derived from it.
    - A Name or Parent value longer than the 255 characters of its table
      column is truncated with a warning; note that re-expanding the
      appended data then derives a different entry from the truncated
      value.
    - A Parent value which is missing or null is stored as a database
      null without a warning, as the expansion emits a YAML null for a
      null Parent column; empty or whitespace-only Parent values are
      stored as read.
    - An entry which repeats the Name value of a previously read entry,
      ignoring character case (mirroring the case-insensitive unique check
      of the expansion and the RAGS Designer limitation it documents), is
      skipped with a warning which names the column values of the ignored
      duplicate entry (the column values of the first read entry win).
    - Keys of an entry other than the two column names are ignored with
      a warning.

    The 'ItemGroups.yaml' file is read, validated and fully staged before
    the first row is appended, so the table remains empty when the source
    folder carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no partially
    appended data behind.

    The 'ItemGroups.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the ItemGroups table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source folder compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the ItemGroups data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-ItemGroupsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded ItemGroups data of the 'C:\Export\MyGame' folder
    to the ItemGroups table of the RAGS file connected through
    $openRagsConnection.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot compress the ItemGroups data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'ItemGroups.yaml' file:
    # no expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'ItemGroups.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'ItemGroups.yaml' file, so there is no ItemGroups data to compress."
        return $true
    }
    Write-Verbose "Compressing the ItemGroups data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the ItemGroups data of the RAGS file: the file 'ItemGroups.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the ItemGroups data of the RAGS file: the file 'ItemGroups.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the ItemGroups data of the RAGS file: the file 'ItemGroups.yaml' of the source folder is not a valid YAML document. "
        $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    # ConvertFrom-Yaml returns the parsed value of a multi-document stream
    # as an object array of one element per document (see the
    # CharacterActions handler); a single-document stream is collapsed by
    # the array wrap, so a count above one is always the sign of extra
    # documents. Note that the wrap can inflate the count when a document
    # itself is a sequence; the warning only ever dismisses trailing
    # content, so this cannot misdirect the read below.
    if ($parsedDocuments.Count -gt 1) {
        Write-Warning "The file 'ItemGroups.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream. A missing value after the parse is therefore reported
    # like a missing document.
    $rootDocument = $parsedDocuments[0]
    if ($null -eq $rootDocument) {
        throw "Cannot compress the ItemGroups data of the RAGS file: the file 'ItemGroups.yaml' of the source folder carries no YAML document."
    }
    if ($rootDocument -isnot [System.Collections.IDictionary]) {
        if ($rootDocument -is [string]) {
            $rootType = 'a scalar'
        }
        elseif ($rootDocument -is [System.Collections.IList]) {
            $rootType = 'a sequence'
        }
        else {
            $rootType = "a value of type '$($rootDocument.GetType().FullName)'"
        }

        throw "Cannot compress the ItemGroups data of the RAGS file: the file 'ItemGroups.yaml' of the source folder carries $rootType where a mapping is expected."
    }
    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'ItemGroups' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'ItemGroups', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'ItemGroups.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['ItemGroups']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'ItemGroups.yaml' of the source folder: the ItemGroups value is missing or null, so no item group data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'ItemGroups.yaml' of the source folder: the ItemGroups value is empty, so no item group data can be derived from it."
        }
        else {
            Write-Warning "The ItemGroups value of the file 'ItemGroups.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The ItemGroups value of the file 'ItemGroups.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        throw "Cannot compress the ItemGroups data of the RAGS file: the ItemGroups value of the file 'ItemGroups.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per item group entry before appending anything, so
    # that nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the two column values of the row and the 1-based
    # entry index which produced it for the messages of the append phase.
    # The validation of every entry is performed inline below, so that the
    # file is fully validated (and every failure reported) before any row
    # is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The Name values of the entries whose rows were staged are kept in a
    # separate list so that the duplicate check below can compare
    # case-insensitively (the Unique semantics of this table follow the
    # case-insensitive database collation, as documented for RAGS
    # Designer).
    $admittedNames = [System.Collections.Generic.List[string]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder: the entry is null."
            continue
        }
        if ($entryValue -isnot [System.Collections.IDictionary]) {
            if ($entryValue -is [string]) {
                $entryType = 'a scalar'
            }
            elseif ($entryValue -is [System.Collections.IList]) {
                $entryType = 'a sequence'
            }
            else {
                $entryType = "a value of type '$($entryValue.GetType().FullName)'"
            }

            throw "Cannot compress the ItemGroups data of the RAGS file: the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Locate and validate the Name value of the entry, which the
        # expansion writes as a string scalar. A scalar of any other type
        # (a hand-edited unquoted number, for example) is coerced to its
        # invariant string form with a warning.
        $entryNameValue = $entryValue['Name']
        if ($null -eq $entryNameValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder: the Name value is missing or null, so no item group entry can be derived from it."
            continue
        }

        $name = $null
        if ($entryNameValue -is [System.Collections.IList]) {
            throw "Cannot compress the ItemGroups data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($entryNameValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the ItemGroups data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($entryNameValue -is [string]) {
            $name = $entryNameValue
        }
        else {
            Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder is of type '$($entryNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryNameValue -is [System.IFormattable]) {
                $name = $entryNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $name = [string]$entryNameValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder: the Name value is empty, so no item group entry can be derived from it."
            continue
        }

        # Truncate the Name value to the length of the table column, as a
        # longer value could not be stored.
        if ($name.Length -gt 255) {
            Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder is $($name.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry from the truncated value."
            $name = $name.Substring(0, 255)
        }

        # Normalize the Parent value to its storable row value. A null
        # value is stored as a database null without a warning, as the
        # expansion emits a YAML null for a null Parent column; empty and
        # whitespace-only values are stored as read. A scalar of any
        # other type than a string is coerced to its invariant string
        # form with a warning. Like every normalization this is performed
        # BEFORE the duplicate check below, so that the warning of the
        # check reports the values of the ignored duplicate entry.
        $parentValue = $entryValue['Parent']
        $parent = $null
        if ($null -ne $parentValue) {
            if ($parentValue -is [System.Collections.IList]) {
                throw "Cannot compress the ItemGroups data of the RAGS file: the Parent of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($parentValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the ItemGroups data of the RAGS file: the Parent of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($parentValue -is [string]) {
                $parent = $parentValue
            }
            else {
                Write-Warning "The Parent of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder is of type '$($parentValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($parentValue -is [System.IFormattable]) {
                    $parent = $parentValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $parent = [string]$parentValue
                }
            }

            if ($parent.Length -gt 255) {
                Write-Warning "The Parent of the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder is $($parent.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $parent = $parent.Substring(0, 255)
            }
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the two column names only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Parent', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder for item group '$name' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Soft-validate the Unique Name column: an entry whose value
        # compares equal to a previously read entry's value, ignoring
        # character case, is skipped with a warning naming the column
        # values of the ignored duplicate entry (the column values of the
        # first read entry win).
        $duplicate = $false
        foreach ($existingName in $admittedNames) {
            if ([string]::Equals($existingName, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            if ($null -eq $parent) { $parentEvidence = 'Parent <null>' } else { $parentEvidence = 'Parent ''' + $parent + '''' }

            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemGroups.yaml' of the source folder: the Name value '$name' duplicates the Name value of a previously read entry (whose column values win). The ignored duplicate entry has the column values Name '$name', $parentEvidence."
            continue
        }

        $admittedNames.Add($name)

        $stagedRows.Add([pscustomobject]@{
            Name       = $name
            Parent     = $parent
            EntryIndex = $entryIndex + 1
        })

        $contributingEntries.Add($entryIndex + 1)
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the ItemGroups table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout.
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) (item group '$($stagedRow.Name)') to the ItemGroups table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [ItemGroups] ([Name], [Parent]) VALUES (@name, @parent)'

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 255)
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $parentParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@parent', [System.Data.SqlDbType]::NVarChar, 255)
                    if ($null -eq $stagedRow.Parent) {
                        # A parameter value of $null means 'not supplied',
                        # so a null column value is bound as a database
                        # null.
                        $parentParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $parentParameter.Value = $stagedRow.Parent
                    }
                    $null = $command.Parameters.Add($parentParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the ItemGroups table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The ItemGroups transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the ItemGroups data of the RAGS file: the staged rows could not be appended to the ItemGroups table. "
            $message += "The database reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }
        finally {
            if ($null -ne $transaction) {
                $transaction.Dispose()
            }
        }
    }
    else {
        Write-Verbose 'No rows were staged, so no transaction is opened.'
    }

    Write-Verbose "Compressed the ItemGroups data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

