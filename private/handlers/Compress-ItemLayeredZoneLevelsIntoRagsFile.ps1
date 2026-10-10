#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-ItemLayeredZoneLevelsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses ItemLayeredZoneLevels data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded ItemLayeredZoneLevels data of a source folder
    back into the ItemLayeredZoneLevels table of a RAGS file (schema
    version 2.6.1) through an open SQL Server Compact connection, appending
    the compressed rows as the inverse of
    Expand-ItemLayeredZoneLevelsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'ItemLayeredZoneLevels.yaml' file of the source folder is
    read as a YAML document holding a top-level 'ItemLayeredZoneLevels'
    mapping whose value is a sequence with one entry per distinct item, each
    mapping the two data columns of the ItemLayeredZoneLevels table: the
    ItemID key and the Data column whose value is a sequence of plain
    strings, one per ItemLayeredZoneLevels row of that item. One table row
    is appended per Data sequence entry (the ID identity column is excluded
    and auto-supplied by the database), replicating the row order of the
    original expansion: an item's values keep the entry order of its Data
    sequence, which is the ascending row ID order of the original table
    read, and entries keep their YAML sequence order, which is the
    ascending ItemID order of the original table read (with every set of
    case-mate items merged into the first-read casing).

    The 'ItemLayeredZoneLevels.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'ItemLayeredZoneLevels'
      envelope around the entry sequence, so a non-mapping document
      predates this layout). Keys of the document other than the
      'ItemLayeredZoneLevels' envelope key are ignored with a warning.
    - A document whose ItemLayeredZoneLevels value is missing or null
      contributes no rows and is skipped with a warning. An
      ItemLayeredZoneLevels value which is an empty string or
      whitespace-only scalar is skipped with a warning as well. An
      ItemLayeredZoneLevels value which is an empty sequence is treated
      like the empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - An ItemLayeredZoneLevels value which is a scalar or a single mapping
      (as hand-edited files omitting the trailing sequence dash commonly
      are) is accepted as the single entry of the sequence with a warning
      (for a scalar entry this aborts the operation in the entry validation
      below); a value of any other type aborts the whole operation with an
      exception.
    - Entries which are null are skipped with a warning. An entry which is
      not a mapping aborts the whole operation with an exception, as no
      meaningful item can be derived from it.
    - An entry whose ItemID value is missing, null, empty or
      whitespace-only is skipped in its entirety with a warning, as no
      item can be derived from it.
    - A scalar ItemID value which is not a string (a hand-edited unquoted
      number, for example) is coerced to its string form with a warning;
      the string form of format-sensitive values is derived with the
      invariant culture, so such a value round-trips through hosts of
      different cultures. An ItemID value which is a sequence or a mapping
      aborts the whole operation with an exception, as no meaningful
      scalar can be derived from it.
    - An entry whose Data value is missing, null or empty contributes no
      rows and is skipped with a warning, as no row of the item could be
      derived from it.
    - A Data value which is a string scalar (instead of a sequence) is
      accepted as the single entry of the sequence with a warning; a
      scalar Data value which is empty or whitespace-only is treated like
      a missing Data value. A Data value which is a mapping aborts the
      whole operation with an exception.
    - Individual Data sequence entries which are null are skipped with a
      warning. Data sequence entries which are not strings are coerced to
      their invariant string form with a warning, as above; a sequence or
      mapping entry aborts the whole operation with an exception. Data
      sequence entries which are empty or whitespace-only are skipped with
      a warning, as the expansion never reads a row whose Data value is
      empty.
    - Data values are normalized to line-feed line breaks before they are
      staged, because the expansion emits every string with line-feed
      breaks (a literal block scalar normalizes its line breaks on read);
      carriage returns in hand-edited files would otherwise re-expand into
      different values. The truncation below measures the normalized
      values.
    - An ItemID or Data value longer than the 250 characters of its table
      column is truncated with a warning; note that re-expanding the
      appended data then derives a different item or value from the
      truncated one. Because a longer value could not be stored, the
      truncation happens before the case-insensitive item grouping below,
      so two ItemID values which become equal only by their truncation
      group together like any other set of case mates.
    - Entries whose ItemID values differ only in character case form one
      item: the item identity of the layered zone level data is treated
      case-insensitively (matching the collation of the underlying
      database, which sorts such values together and with which the
      grouped items re-expand into one entry). Every such entry is merged
      under the casing read first, with one warning per merged entry; its
      rows carry the first-read casing, so the appended data re-expands
      into the same single entry. Entries whose ItemID values are exactly
      equal are appended without a warning, as append-only accumulation is
      the documented caller workflow.
    - Keys of an entry other than the two column names are ignored with
      a warning.

    The 'ItemLayeredZoneLevels.yaml' file is read, validated and fully
    staged before the first row is appended, so the table remains empty
    when the source folder carries invalid content. The appended rows are
    then written inside a transaction, so a failure while appending leaves
    no partially appended data behind.

    The 'ItemLayeredZoneLevels.yaml' file is read silently; a missing
    source folder or file is not an error and compresses nothing.

    Compressed rows are appended to the ItemLayeredZoneLevels table, which
    is expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template file,
    or a blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the ItemLayeredZoneLevels data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemLayeredZoneLevels data has
    been compressed successfully.

    .EXAMPLE
    Compress-ItemLayeredZoneLevelsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded ItemLayeredZoneLevels data of the
    'C:\Export\MyGame' folder to the ItemLayeredZoneLevels table of the
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
        throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or
    # 'ItemLayeredZoneLevels.yaml' file: no expansion may have happened
    # yet, in which case there is nothing to compress.
    $filePath = Join-Path $SourcePath 'ItemLayeredZoneLevels.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'ItemLayeredZoneLevels.yaml' file, so there is no ItemLayeredZoneLevels data to compress."
        return $true
    }
    Write-Verbose "Compressing the ItemLayeredZoneLevels data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the file 'ItemLayeredZoneLevels.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the file 'ItemLayeredZoneLevels.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the file 'ItemLayeredZoneLevels.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'ItemLayeredZoneLevels.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream. A missing value after the parse is therefore reported
    # like a missing document.
    $rootDocument = $parsedDocuments[0]
    if ($null -eq $rootDocument) {
        throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the file 'ItemLayeredZoneLevels.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the file 'ItemLayeredZoneLevels.yaml' of the source folder carries $rootType where a mapping is expected."
    }
    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'ItemLayeredZoneLevels'
    # envelope mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'ItemLayeredZoneLevels', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'ItemLayeredZoneLevels.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['ItemLayeredZoneLevels']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'ItemLayeredZoneLevels.yaml' of the source folder: the ItemLayeredZoneLevels value is missing or null, so no ItemLayeredZoneLevels data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'ItemLayeredZoneLevels.yaml' of the source folder: the ItemLayeredZoneLevels value is empty, so no ItemLayeredZoneLevels data can be derived from it."
        }
        else {
            Write-Warning "The ItemLayeredZoneLevels value of the file 'ItemLayeredZoneLevels.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The ItemLayeredZoneLevels value of the file 'ItemLayeredZoneLevels.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the ItemLayeredZoneLevels value of the file 'ItemLayeredZoneLevels.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per Data sequence entry before appending anything, so
    # that nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the item id, the normalized Data value and the 1-based
    # entry and Data entry indices which produced it, for the messages of
    # the append phase. The validation of every entry is performed inline
    # below, so that the file is fully validated (and every failure
    # reported) before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The ItemID values of the entries whose rows were staged are kept in
    # a separate list so that ItemID values which differ only in character
    # case can merge under the first-read casing (the expansion groups
    # ItemID values case-insensitively, matching the collation of the
    # database, so the appended data re-expands into one entry).
    $groupNames = [System.Collections.Generic.List[string]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the two column names only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'ItemID', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Data', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # The deferred warnings of the entry (an ItemID truncation
        # round-trip loss and a case-mate merge) are kept in one list which
        # the check phases below fill; they fire only when the entry has
        # actually staged rows, as an entry which contributes no rows
        # loses nothing at re-expansion.
        $pendingWarnings = [System.Collections.Generic.List[string]]::new()

        # Locate and validate the ItemID value of the entry, which the
        # expansion writes as a string scalar. A scalar of any other type
        # (a hand-edited unquoted number, for example) is coerced to its
        # invariant string form with a warning.
        $entryItemIdValue = $entryValue['ItemID']
        if ($null -eq $entryItemIdValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder: the ItemID value is missing, null or empty, so no item can be derived from it."
            continue
        }

        $itemId = $null
        if ($entryItemIdValue -is [System.Collections.IList]) {
            throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the ItemID of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($entryItemIdValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the ItemID of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($entryItemIdValue -is [string]) {
            $itemId = $entryItemIdValue
        }
        else {
            Write-Warning "The ItemID of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder is of type '$($entryItemIdValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryItemIdValue -is [System.IFormattable]) {
                $itemId = $entryItemIdValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $itemId = [string]$entryItemIdValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($itemId)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder: the ItemID value is missing, null or empty, so no item can be derived from it."
            continue
        }

        # Truncate the ItemID value to the length of the table column, as
        # a longer value could not be stored. The truncation runs before
        # the case-insensitive grouping below, so two ItemID values which
        # become equal only by their truncation behave like any other set
        # of case mates.
        if ($itemId.Length -gt 250) {
            $pendingWarnings.Add("The ItemID value of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder is $($itemId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different item from the truncated value.")
            $itemId = $itemId.Substring(0, 250)
        }

        # Locate or create the case-insensitive group of the item, whose
        # name keeps the casing read first. An entry whose ItemID differs
        # from an earlier entry's value only in character case merges into
        # the group; its warning is deferred until the entry has actually
        # staged rows, as it describes the casing of appended data.
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
            $pendingWarnings.Add("Merging the rows of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder of item '$itemId' into the rows of item '$($groupNames[$groupIndex])': the ItemID values differ only in character case.")
        }

        # Every appended row of the entry carries the group's ItemID value
        # (the first-read casing of its set of case mates).
        $stagedItemId = $groupNames[$groupIndex]

        # Locate and validate the Data value of the entry, which the
        # expansion writes as a sequence of plain strings. A scalar value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        $entryDataValue = $entryValue['Data']
        if ($null -eq $entryDataValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId': the Data value is missing or null, so no ItemLayeredZoneLevels data can be derived from it."
            continue
        }

        if ($entryDataValue -is [System.Collections.IList]) {
            if ($entryDataValue.Count -eq 0) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId': the Data value is an empty sequence, so no ItemLayeredZoneLevels data can be derived from it."
                continue
            }
        }
        elseif ($entryDataValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($entryDataValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId': the Data value is empty, so no ItemLayeredZoneLevels data can be derived from it."
                continue
            }

            Write-Warning "The Data value of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedDataEntries = [System.Collections.Generic.List[object]]::new()
            $coercedDataEntries.Add($entryDataValue)
            $entryDataValue = $coercedDataEntries
        }
        else {
            throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the Data value of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' is of type '$($entryDataValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every Data entry is normalized to its storable row value before
        # any row of the entry is staged: a null is skipped with a warning,
        # a scalar of any type other than a string is coerced to its
        # invariant string form with a warning, and a sequence or mapping
        # aborts the whole operation with an exception. Empty and
        # whitespace-only Data entries are skipped with a warning, as the
        # expansion never reads a row whose Data value is empty.
        $entryRowsBefore = $stagedRows.Count
        for ($dataIndex = 0; $dataIndex -lt $entryDataValue.Count; $dataIndex++) {
            $dataValue = $entryDataValue[$dataIndex]

            if ($null -eq $dataValue) {
                Write-Warning "Skipping the Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId': the Data value is null."
                continue
            }
            if ($dataValue -is [System.Collections.IList]) {
                throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' carries a sequence where a scalar value is expected."
            }
            if ($dataValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' carries a mapping where a scalar value is expected."
            }
            if ($dataValue -isnot [string]) {
                Write-Warning "The Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' is of type '$($dataValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($dataValue -is [System.IFormattable]) {
                    $dataValue = $dataValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $dataValue = [string]$dataValue
                }
            }

            # A YAML literal block scalar normalizes line breaks to
            # line-feed characters when the written YAML is read back, so
            # carriage returns are normalized away beforehand to keep the
            # round-trip byte-exact. The normalized value is assigned to a
            # local first: operator expressions passed directly as method
            # arguments are mis-tokenized as additional arguments on both
            # hosts.
            $normalizedData = ([string]$dataValue) -replace '\r\n?', "`n"

            if ([string]::IsNullOrWhiteSpace($normalizedData)) {
                Write-Warning "Skipping the Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId': the Data value is empty."
                continue
            }

            # Truncate the Data value to the length of the table column,
            # as a longer value could not be stored. The truncation
            # measures the normalized value (see above), as the stored
            # value is the normalized one.
            if ($normalizedData.Length -gt 250) {
                Write-Warning "The Data entry $($dataIndex + 1) of the entry $($entryIndex + 1) of the file 'ItemLayeredZoneLevels.yaml' of the source folder for item '$stagedItemId' is $($normalizedData.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $normalizedData = $normalizedData.Substring(0, 250)
            }

            $stagedRows.Add([pscustomobject]@{
                ItemID     = $stagedItemId
                Data       = $normalizedData
                EntryIndex = $entryIndex + 1
                DataIndex  = $dataIndex + 1
            })
        }

        # The deferred warnings of the entry (an ItemID truncation
        # round-trip loss and a case-mate merge) fire only when it actually
        # contributed rows: an entry whose Data was skipped entirely loses
        # nothing at re-expansion.
        if ($stagedRows.Count -gt $entryRowsBefore) {
            foreach ($pendingWarning in $pendingWarnings) {
                Write-Warning $pendingWarning
            }
            $contributingEntries.Add($entryIndex + 1)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the ItemLayeredZoneLevels table inside
        # one transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout.
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the Data entry $($stagedRow.DataIndex) of the entry $($stagedRow.EntryIndex) (item '$($stagedRow.ItemID)') to the ItemLayeredZoneLevels table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [ItemLayeredZoneLevels] ([ItemID], [Data]) VALUES (@itemid, @data)'

                    $itemParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@itemid', [System.Data.SqlDbType]::NVarChar, 250)
                    $itemParameter.Value = $stagedRow.ItemID
                    $null = $command.Parameters.Add($itemParameter)

                    $dataParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@data', [System.Data.SqlDbType]::NVarChar, 250)
                    $dataParameter.Value = $stagedRow.Data
                    $null = $command.Parameters.Add($dataParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the ItemLayeredZoneLevels table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The ItemLayeredZoneLevels transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the ItemLayeredZoneLevels data of the RAGS file: the staged rows could not be appended to the ItemLayeredZoneLevels table. "
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

    Write-Verbose "Compressed the ItemLayeredZoneLevels data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

