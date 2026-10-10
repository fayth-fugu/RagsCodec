#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-ItemActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses ItemActions data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded ItemActions data of a source folder back into the
    ItemActions table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-ItemActionsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    Every '.yaml' file of the 'ItemActions' subfolder of the source folder
    is read as a YAML document mapping an ItemID value to a Data sequence of
    RAGS action expansions. Each sequence entry is converted from the
    pretty-printed XML of the entry into its encoded RAGS action form (four
    padding bytes followed by a GZip stream, Base64-encoded) through
    Compress-RagsActionFromXml. One table row is appended per entry (the
    Identity column value is supplied by the database), replicating the row
    order of the original expansion: source files are read in file name
    order, the entries of each file keep their YAML sequence order, and the
    Identity values of the appended rows grow in insertion order, so
    re-expanding the appended data restores each item's entries in ascending
    row ID order.

    The YAML files of the subfolder are consumed as follows:
    - A file which defines more than one YAML document is consumed from its
      first document only, with a warning naming the file and the number of
      ignored extra documents.
    - A YAML document which is not a mapping (for example a scalar or a
      sequence), an ItemID value which is not a string, a Data value which
      is neither a string scalar nor a sequence (for example a YAML mapping
      or an unquoted number), a Data entry which is not a string, and a
      non-empty Data entry whose content is not well-formed XML abort the
      whole operation with an exception, as no meaningful RAGS action can be
      derived from them.
    - A mapping defining keys other than 'ItemID' and 'Data' is accepted
      with one warning naming the unexpected keys; the unexpected keys are
      ignored.
    - A file whose ItemID value is missing, null, empty or whitespace-only
      is skipped in its entirety with a warning, as no meaningful expansion
      target could be derived from it (its rows may therefore not survive a
      compress/expand cycle and its Data values are discarded).
    - An ItemID value longer than the 250 characters of the table column is
      truncated with a warning; note that re-expanding the appended data
      then derives a different file name from the truncated value.
    - The file names of the subfolder are never interpreted: the ItemID
      value of the contents is the truth, so the file name an expansion
      originally wrote is silently irrelevant. An ItemID value which cannot
      form a valid Windows file name (because it contains characters that
      are invalid in file names, ends with a dot or a space, or names a
      reserved device such as CON, NUL or COM1) still contributes its rows,
      since the value itself is stored as-is and no file is created from it
      here; a warning reports that re-expanding the appended data skips
      these rows as documented (the warning fires only for files which
      actually contribute rows).
    - ItemID values of two files which differ only in character case would
      re-expand into one file, since the expansion groups ItemID values
      case-insensitively; such files are therefore merged - the casing read
      first (of the file whose name sorts first) wins for the appended rows,
      and every later case mate is reported with one warning. Case mates
      which do not contribute rows (their Data value is missing, empty or
      yields only empty entries) are reported through their skip warnings
      only, as they merge nothing. ItemID values which are exactly equal in
      other files are appended without a warning, as append-only
      accumulation is the documented caller workflow.
    - A file whose Data value is missing, null, empty or whitespace-only,
      or whose Data sequence is empty, contributes no rows and is skipped
      with a warning.
    - A Data value which is a string scalar (instead of a sequence) is
      accepted as the single entry of the sequence with a warning; a scalar
      Data value which is empty or whitespace-only is treated like a missing
      Data value.
    - Individual entries which are null, empty or whitespace-only are
      skipped with a warning.

    Every file of the subfolder is read, validated and encoded before the
    first row is appended, so the table remains empty when the source
    folder carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no partially
    appended data behind.

    The ItemActions subfolder is read silently; a missing source folder or
    subfolder is not an error and compresses nothing. Files of any other
    extension are skipped with a warning.

    Compressed rows are appended to the ItemActions table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template file,
    or a blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the ItemActions data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemActions data has been
    compressed successfully.

    .EXAMPLE
    Compress-ItemActionsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the ItemActions data of the 'C:\Export\MyGame' folder to the
    RAGS file connected through $openRagsConnection.
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
        throw "Cannot compress the ItemActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'ItemActions' subfolder: no
    # expansion may have happened yet, in which case there is nothing to
    # compress.
    $itemActionsFolder = Join-Path $SourcePath 'ItemActions'
    if (-not (Test-Path -LiteralPath $itemActionsFolder -PathType Container)) {
        Write-Verbose "The source folder carries no 'ItemActions' subfolder, so there is no ItemActions data to compress."
        return $true
    }
    Write-Verbose "Compressing the ItemActions data of the RAGS file from '$itemActionsFolder'."

    # Collect the files of the subfolder in file name order, so that a given
    # exact item always receives its rows in a stable and reproducible
    # order, and so that the casing of a set of case-mate items is decided
    # by the file whose name sorts first. The expansion writes everything as
    # '.yaml' files; anything else is skipped with a warning.
    Write-Verbose "Reading the YAML files of '$itemActionsFolder'."
    $yamlFiles = @(Get-ChildItem -LiteralPath $itemActionsFolder -File |
        Sort-Object -Property Name)
    Write-Verbose "Found $($yamlFiles.Count) file(s) in the 'ItemActions' subfolder."

    # Characters that are invalid in file names on the current file system.
    # The array includes control characters (tab and line-break characters
    # included) on both supported hosts.
    $invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()

    # Stage one row per Data entry before appending anything, so that
    # nothing is written when any source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged value
    # carries the item id, the source file name and the 1-based entry index
    # which produced it for the messages of the append phase, and the
    # Base64-encoded RAGS action payload. The validation of every entry is
    # performed inline below, so that each file is fully validated (and
    # every failure reported) before any file contributes rows.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingFileNames = [System.Collections.Generic.List[string]]::new()

    # The ItemID value groups are tracked as a list of the casings read
    # first, so that ItemID values which differ only in character case can
    # merge under the first-read casing (the expansion of the appended data
    # writes such rows back into one file).
    $groupNames = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $yamlFiles) {
        if (-not [System.String]::Equals($file.Extension, '.yaml', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Skipping the file '$($file.Name)' of the ItemActions subfolder: it does not have a '.yaml' extension."
            continue
        }

        # Read the whole file as text ([System.IO.File]::ReadAllText
        # auto-detects the UTF-8/UTF-16 byte-order marks and defaults to
        # UTF-8, which matches the encoding the expansion writes).
        try {
            $fileText = [System.IO.File]::ReadAllText($file.FullName)
        }
        catch {
            $message = "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder could not be read. "
            $message += "The file system reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        if ([string]::IsNullOrWhiteSpace($fileText)) {
            throw "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder is empty."
        }

        # Parse the file as a YAML multi-document stream. A file which
        # defines more than one document is consumed from its first
        # document only, with a warning about the extra documents (the
        # expansion writes exactly one mapping per file, so extra documents
        # in a source folder are usually leftovers of a manual edit).
        try {
            $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
        }
        catch {
            $message = "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder is not a valid YAML document. "
            $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # ConvertFrom-Yaml returns the parsed value of a single document
        # directly (a mapping, a sequence or a scalar, as read), the values
        # of multiple documents as an object array, and no value at all for
        # an empty stream. Extra documents are ignored with a warning, as
        # the first document alone determines the appended rows.
        if ($parsedDocuments.Count -gt 1) {
            Write-Warning "The file '$($file.Name)' of the ItemActions subfolder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
        }
        if ($parsedDocuments.Count -lt 1) {
            throw "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder carries no YAML document."
        }

        $mapping = $parsedDocuments[0]
        if ($null -eq $mapping) {
            throw "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder carries no YAML document."
        }
        if ($mapping -isnot [System.Collections.IDictionary]) {
            if ($mapping -is [string]) {
                $actualType = 'a scalar'
            }
            elseif ($mapping -is [System.Collections.IList]) {
                $actualType = 'a sequence'
            }
            else {
                $actualType = "a value of type '$($mapping.GetType().FullName)'"
            }

            throw "Cannot compress the ItemActions data of the RAGS file: the file '$($file.Name)' of the ItemActions subfolder carries $actualType where a mapping is expected."
        }

        # Resolve the ItemID and Data values of the mapping by key, so that
        # the key comparison does not depend on the dictionary semantics of
        # the YAML reader: the expansion writes 'ItemID' and 'Data' exactly,
        # and any other key (a case variant included) counts as unexpected.
        $itemIdValue = $null
        $dataValue = $null
        $unexpectedKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($documentKey in $mapping.Keys) {
            $documentKeyText = [string]$documentKey
            if ([string]::Equals($documentKeyText, 'ItemID', [System.StringComparison]::Ordinal)) {
                $itemIdValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'Data', [System.StringComparison]::Ordinal)) {
                $dataValue = $mapping[$documentKey]
            }
            else {
                $unexpectedKeys.Add($documentKeyText)
            }
        }
        if ($unexpectedKeys.Count -gt 0) {
            $unexpectedKeyText = ($unexpectedKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The file '$($file.Name)' of the ItemActions subfolder defines the unexpected key(s) $unexpectedKeyText; they are ignored."
        }

        # Locate and validate the ItemID value of the mapping, which is
        # expected to be the string scalar the expansion wrote.
        if ($null -eq $itemIdValue) {
            Write-Warning "Skipping the file '$($file.Name)' of the ItemActions subfolder: the ItemID value is missing or null, so no item can be derived for it."
            continue
        }
        if ($itemIdValue -isnot [string]) {
            throw "Cannot compress the ItemActions data of the RAGS file: the ItemID value of the file '$($file.Name)' is of type '$($itemIdValue.GetType().FullName)' instead of a string."
        }
        if ([string]::IsNullOrWhiteSpace($itemIdValue)) {
            Write-Warning "Skipping the file '$($file.Name)' of the ItemActions subfolder: the ItemID value is empty, so no item can be derived for it."
            continue
        }

        # Truncate the ItemID value to the length of the table column, as a
        # longer value could not be stored. The value is truncated before
        # the file-name and case-mate checks below, so that the stored value
        # is what they validate.
        $itemId = $itemIdValue
        if ($itemId.Length -gt 250) {
            Write-Warning "The ItemID value of the file '$($file.Name)' is $($itemId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different file name from the truncated value."
            $itemId = $itemId.Substring(0, 250)
        }

        # An ItemID value which cannot form a valid file name still
        # contributes its rows, as the file name of an expansion is never
        # interpreted here; the round-trip loss is reported below (the
        # warning is deferred until the file has actually staged rows).
        # The deferred warnings of a file (a file-name round-trip loss and a
        # case-mate merge) are kept in one list which both check phases
        # fill, so that a contributing file reports all of its deferred
        # warnings.
        $pendingWarnings = [System.Collections.Generic.List[string]]::new()
        $fileNameProblem = $null
        if (-1 -lt $itemId.IndexOfAny($invalidFileNameChars)) {
            $fileNameProblem = 'it contains a character that is invalid in file names'
        }
        elseif (($itemId.EndsWith('.')) -or ($itemId.EndsWith(' '))) {
            $fileNameProblem = 'it ends with a dot or a space, which is not allowed in file names'
        }
        elseif ($itemId -match '^((CON|PRN|AUX|NUL)|COM[1-9]|LPT[1-9])(\..+)?$') {
            $fileNameProblem = 'it names a reserved device, which cannot be used as a file name'
        }
        if ($null -ne $fileNameProblem) {
            $pendingWarnings.Add("The ItemID value of the file '$($file.Name)' of item '$itemId' cannot form a valid file name because $fileNameProblem; the rows are appended with this ItemID value, but re-expanding the appended data skips these rows as documented.")
        }

        # Locate or create the case-insensitive group of the item, whose
        # name keeps the casing read first. A file whose ItemID differs from
        # an earlier file's value only in character case merges into the
        # group; its warning is deferred until the file has actually staged
        # rows, as it describes the casing of appended data.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $itemId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($itemId)
        }
        elseif (-not [string]::Equals($groupNames[$groupIndex], $itemId, [System.StringComparison]::Ordinal)) {
            $pendingWarnings.Add("Merging the rows of the file '$($file.Name)' of item '$itemId' into the rows of item '$($groupNames[$groupIndex])': the ItemID values differ only in character case.")
        }

        # Every appended row of the file carries the group's ItemID value
        # (the first-read casing of its set of case mates).
        $stagedItemId = $groupNames[$groupIndex]

        # Locate and validate the Data value of the mapping, which is a
        # sequence of pretty-printed XML action expansions. A scalar value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        if ($null -eq $dataValue) {
            Write-Warning "Skipping the file '$($file.Name)' of item '$itemId': the Data value is missing or null, so no data can be derived from it."
            continue
        }

        if ($dataValue -is [System.Collections.IList]) {
            if ($dataValue.Count -eq 0) {
                Write-Warning "Skipping the file '$($file.Name)' of item '$itemId': the Data value is an empty sequence, so no data can be derived from it."
                continue
            }
        }
        elseif ($dataValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($dataValue)) {
                Write-Warning "Skipping the file '$($file.Name)' of item '$itemId': the Data value is empty, so no data can be derived from it."
                continue
            }

            Write-Warning "The Data value of the file '$($file.Name)' of item '$itemId' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($dataValue)
            $dataValue = $coercedEntries
        }
        else {
            throw "Cannot compress the ItemActions data of the RAGS file: the Data value of the file '$($file.Name)' of item '$itemId' is of type '$($dataValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every Data entry is validated and encoded before any row of the
        # file is staged.
        $fileRowsBefore = $stagedRows.Count
        for ($entryIndex = 0; $entryIndex -lt $dataValue.Count; $entryIndex++) {
            $entryValue = $dataValue[$entryIndex]

            if ($null -eq $entryValue) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for item '$stagedItemId': the entry is null."
                continue
            }
            if ($entryValue -isnot [string]) {
                throw "Cannot compress the ItemActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for item '$stagedItemId' is of type '$($entryValue.GetType().FullName)' instead of a string."
            }
            if ([string]::IsNullOrWhiteSpace($entryValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for item '$stagedItemId': the entry is empty."
                continue
            }

            # Compress the pretty-printed XML snippet into its encoded RAGS
            # action form; the snippet is linearized (and its line endings
            # normalized) by the compressor, as the payload is usually
            # stored linearized.
            try {
                $encodedAction = Compress-RagsActionFromXml -XmlRagsAction $entryValue
            }
            catch {
                $message = "Cannot compress the ItemActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for item '$stagedItemId' could not be compressed as a RAGS action. "
                $message += "The compression reported the following error: '$($_.Exception.Message)'."
                throw [System.Exception]::new($message, $_.Exception)
            }

            $stagedRows.Add([pscustomobject]@{
                ItemID = $stagedItemId
                FileName = $file.Name
                EntryIndex = $entryIndex + 1
                Payload = $encodedAction
            })
        }

        # The deferred warnings of the file (a file-name round-trip loss and
        # a case-mate merge) fire only when it actually contributed rows: an
        # ItemID value whose data was skipped entirely loses nothing at
        # re-expansion.
        if ($stagedRows.Count -gt $fileRowsBefore) {
            foreach ($pendingWarning in $pendingWarnings) {
                Write-Warning $pendingWarning
            }
            $contributingFileNames.Add($file.Name)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the ItemActions table inside one
        # transaction, so that a failed INSERT leaves no partially appended
        # data behind. The values are bound through provider parameters
        # throughout, as the text values are not SQL literals (and the
        # payloads are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) of the file '$($stagedRow.FileName)' for item '$($stagedRow.ItemID)' to the ItemActions table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [ItemActions] ([ItemID], [Data]) VALUES (@itemid, @data)'

                    $itemParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@itemid', [System.Data.SqlDbType]::NVarChar, 250)
                    $itemParameter.Value = $stagedRow.ItemID
                    $null = $command.Parameters.Add($itemParameter)

                    $dataParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@data', [System.Data.SqlDbType]::NText)
                    $dataParameter.Value = $stagedRow.Payload
                    $null = $command.Parameters.Add($dataParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the ItemActions table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The ItemActions transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the ItemActions data of the RAGS file: the staged rows could not be appended to the ItemActions table. "
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

    Write-Verbose "Compressed the ItemActions data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingFileNames.Count) file(s)."
    return $true
}

