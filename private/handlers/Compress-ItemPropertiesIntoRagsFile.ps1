#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-ItemPropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses ItemProperties data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded ItemProperties data of a source folder back
    into the ItemProperties table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection, appending the
    compressed rows as the inverse of Expand-ItemPropertiesFromRagsFile
    and following the conventions documented in docs/data-mapping.md.

    The single 'ItemProperties.yaml' file of the source folder is read as
    a YAML document holding a top-level 'ItemProperties' mapping whose
    value is a sequence with one entry per distinct item: each entry maps
    an ItemID value to the Name key, whose value is a sequence of property
    mappings holding the property Name and its Value. One table row is
    appended per property (the ID identity column is excluded and
    auto-supplied by the database), replicating the row order of the
    original expansion: the properties of every entry keep their YAML
    sequence order, and entries keep their YAML sequence order, so
    re-expanding the file restores the entries and their properties in
    ascending row ID order.

    The 'ItemProperties.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'ItemProperties'
      envelope around the entry sequence, so a non-mapping document
      predates this layout). Keys of the document other than the
      'ItemProperties' envelope key are ignored with a warning.
    - A document whose ItemProperties value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      An ItemProperties value which is an empty sequence is treated like
      the empty sequence an expansion writes for an empty table and
      contributes no rows without a warning. An ItemProperties value
      which is a scalar or a single mapping (as hand-edited files
      omitting the trailing sequence dash commonly are) is accepted as
      the single entry of the sequence with a warning (for a scalar
      entry this aborts the operation in the entry validation below); a
      value of any other type aborts the whole operation with an
      exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful item can be derived from it. Keys of an entry other
      than the two column names are ignored with a warning.
    - An entry whose ItemID value is missing, null, empty or
      whitespace-only is skipped in its entirety with a warning, as no
      item can be derived from it.
    - A scalar ItemID value which is not a string (a hand-edited
      unquoted number, for example) is coerced to its string form with a
      warning; the string form of format-sensitive values is derived
      with the invariant culture, so such a value round-trips through
      hosts of different cultures. An ItemID value which is a sequence
      or a mapping aborts the whole operation with an exception, as no
      meaningful scalar can be derived from it.
    - An ItemID value longer than the 250 characters of the table column
      is truncated with a warning (which fires only when the entry
      contributes rows); note that re-expanding the appended data then
      derives a different item from the truncated value. Because a
      longer value could not be stored, the truncation happens before
      the case-insensitive item grouping below, so two ItemID values
      which become equal only by their truncation group together like
      any other set of case mates.
    - Entries whose ItemID values differ only in character case form one
      item: the item identity of the properties is case-insensitive,
      matching the collation of the underlying database and the
      case-insensitive grouping of the expansion (with which the grouped
      items re-expand into one entry). Every such entry is merged under
      the casing read first, with one warning per merged entry which
      fires only when the entry contributes rows; its rows carry the
      first-read casing, so the appended data re-expands into one entry
      silently.
    - An entry which repeats the exact ItemID value of a previously read
      entry is warned about; the properties of both entries are appended
      under the same item, as one item cannot carry two property sets in
      the table.
    - An entry whose Name value is missing, null, empty, whitespace-only
      or an empty sequence is skipped in its entirety with a warning, as
      no property can be derived from it. A Name value which is a scalar
      or a single mapping is accepted as the single entry of the
      sequence with a warning.
    - Properties which are null are skipped with a warning. A property
      which is not a mapping aborts the whole operation with an
      exception, as no property can be derived from it. Keys of a
      property other than the Name and Value keys are ignored with a
      warning.
    - A property whose Name value is missing, null, empty or
      whitespace-only is skipped with a warning. A scalar Name value
      which is not a string is coerced to its invariant string form with
      a warning, as above; a Name value which is a sequence or a mapping
      aborts the whole operation with an exception. A property Name
      value longer than the 250 characters of the table column is
      truncated with a warning, which may make two distinct property
      names indistinguishable.
    - A property which repeats the exact property name of a previously
      read property of the same item is skipped with a warning (the
      value of the first read property wins, mirroring the Unique
      soft-validation of the expansion; the warning reports the value of
      the ignored property). Property names which differ only in
      character case are distinct properties, both within one entry and
      across the entries of one item.
    - A property Value which is missing or null is stored as a database
      null without a warning, as the expansion emits a YAML null for a
      null Value column. A property Value which is a scalar but not a
      string (a hand-edited unquoted number, for example) is coerced to
      its string form with a warning; the string form of
      format-sensitive values is derived with the invariant culture, so
      such a value round-trips through hosts of different cultures
      (except for date values, which are written in their invariant
      general form rather than as the ISO 8601 string an expansion
      extracts). A property Value which is a sequence or a mapping
      aborts the whole operation with an exception.
    - Property values are normalized to line-feed line breaks before
      they are staged, because the expansion emits every multi-line
      value as a YAML literal block scalar whose line breaks are read
      back as line feeds; carriage returns in hand-edited files would
      otherwise re-expand into different values. The staged value never
      carries a line break other than a line feed.

    The 'ItemProperties.yaml' file is read, validated and fully staged
    before the first row is appended, so the table remains empty when the
    source folder carries invalid content. The appended rows are then
    written inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The 'ItemProperties.yaml' file is read silently; a missing source
    folder or file is not an error and compresses nothing.

    Compressed rows are appended to the ItemProperties table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source folder compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the ItemProperties data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemProperties data has been
    compressed successfully.

    .EXAMPLE
    Compress-ItemPropertiesIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded ItemProperties data of the 'C:\Export\MyGame'
    folder to the ItemProperties table of the RAGS file connected through
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
        throw "Cannot compress the ItemProperties data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'ItemProperties.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'ItemProperties.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'ItemProperties.yaml' file, so there is no ItemProperties data to compress."
        return $true
    }
    Write-Verbose "Compressing the ItemProperties data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the ItemProperties data of the RAGS file: the file 'ItemProperties.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the ItemProperties data of the RAGS file: the file 'ItemProperties.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the ItemProperties data of the RAGS file: the file 'ItemProperties.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'ItemProperties.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty or comment-only stream. A missing value after the parse is
    # therefore reported like a missing document.
    $rootDocument = $null
    if ($parsedDocuments.Count -gt 0) {
        $rootDocument = $parsedDocuments[0]
    }
    if ($null -eq $rootDocument) {
        throw "Cannot compress the ItemProperties data of the RAGS file: the file 'ItemProperties.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the ItemProperties data of the RAGS file: the file 'ItemProperties.yaml' of the source folder carries $rootType where a mapping is expected."
    }
    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'ItemProperties' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'ItemProperties', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'ItemProperties.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['ItemProperties']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'ItemProperties.yaml' of the source folder: the ItemProperties value is missing or null, so no item properties can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'ItemProperties.yaml' of the source folder: the ItemProperties value is empty, so no item properties can be derived from it."
        }
        else {
            Write-Warning "The ItemProperties value of the file 'ItemProperties.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The ItemProperties value of the file 'ItemProperties.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        throw "Cannot compress the ItemProperties data of the RAGS file: the ItemProperties value of the file 'ItemProperties.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per property before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the item id, the property name, the storable property
    # value (a string, or $null for a database null) and the 1-based entry
    # and property indices which produced it for the messages of the
    # append phase. The validation of every entry is performed inline
    # below, so that the file is fully validated (and every failure
    # reported) before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The ItemID values of the entries whose rows were staged are kept in
    # a separate list so that ItemID values which differ only in character
    # case can merge under the first-read casing (the expansion groups
    # ItemID values case-insensitively, matching the collation of the
    # database, so the appended data re-expands into one entry). A second
    # parallel list keeps one ordinal property-name set per item, which
    # validates the Unique Name column across every entry of its item,
    # exactly like the expansion.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupNameSets = [System.Collections.Generic.List[object]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the ItemProperties data of the RAGS file: the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the ItemID and Name keys only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'ItemID', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder defines the unexpected key(s) $entryExtraKeyText; they are ignored."
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
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder: the ItemID value is missing, null or empty, so no item can be derived from it."
            continue
        }

        $itemId = $null
        if ($entryItemIdValue -is [System.Collections.IList]) {
            throw "Cannot compress the ItemProperties data of the RAGS file: the ItemID of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($entryItemIdValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the ItemProperties data of the RAGS file: the ItemID of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($entryItemIdValue -is [string]) {
            $itemId = $entryItemIdValue
        }
        else {
            Write-Warning "The ItemID of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder is of type '$($entryItemIdValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryItemIdValue -is [System.IFormattable]) {
                $itemId = $entryItemIdValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $itemId = [string]$entryItemIdValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($itemId)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder: the ItemID value is missing, null or empty, so no item can be derived from it."
            continue
        }

        # Truncate the ItemID value to the length of the table column, as
        # a longer value could not be stored. The truncation runs before
        # the case-insensitive grouping below, so two ItemID values which
        # become equal only by their truncation behave like any other set
        # of case mates.
        if ($itemId.Length -gt 250) {
            $pendingWarnings.Add("The ItemID value of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder is $($itemId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different item from the truncated value.")
            $itemId = $itemId.Substring(0, 250)
        }

        # Locate or create the case-insensitive group of the item, whose
        # name keeps the casing read first. An entry whose ItemID differs
        # from an earlier entry's value only in character case merges into
        # the group; its warning is deferred until the entry has actually
        # staged rows, as it describes the casing of appended data. An
        # entry whose ItemID is exactly equal to a group name repeats the
        # item of that group, which is warned about immediately, because
        # one item cannot carry two property sets in the table.
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
            $groupNameSets.Add([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal))
        }
        elseif (-not [string]::Equals($groupNames[$groupIndex], $itemId, [System.StringComparison]::Ordinal)) {
            $pendingWarnings.Add("Merging the properties of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$itemId' into the properties of item '$($groupNames[$groupIndex])': the ItemID values differ only in character case.")
        }
        else {
            Write-Warning "The entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder repeats the ItemID value of a previously read entry; the properties of both entries are appended under the same item."
        }

        # Every appended row of the entry carries the group's ItemID value
        # (the first-read casing of its set of case mates), and the
        # property names of the entry join the property-name set of that
        # item, exactly like the property names of any other entry of the
        # same item.
        $stagedItemId = $groupNames[$groupIndex]
        $nameSet = $groupNameSets[$groupIndex]

        # Locate and validate the Name value of the entry, which is a
        # sequence of property mappings. A scalar or single-mapping value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        $propertiesValue = $entryValue['Name']
        if ($null -eq $propertiesValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId': the Name value is missing or null, so no property can be derived from it."
            continue
        }

        if ($propertiesValue -is [System.Collections.IList]) {
            if ($propertiesValue.Count -eq 0) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId': the Name value is an empty sequence, so no property can be derived from it."
                continue
            }
        }
        elseif ($propertiesValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($propertiesValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId': the Name value is empty, so no property can be derived from it."
                continue
            }

            Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedProperties = [System.Collections.Generic.List[object]]::new()
            $coercedProperties.Add($propertiesValue)
            $propertiesValue = $coercedProperties
        }
        elseif ($propertiesValue -is [System.Collections.IDictionary]) {
            Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId' is a single mapping, not a sequence; it is treated as the single entry of the sequence."
            $coercedProperties = [System.Collections.Generic.List[object]]::new()
            $coercedProperties.Add($propertiesValue)
            $propertiesValue = $coercedProperties
        }
        else {
            throw "Cannot compress the ItemProperties data of the RAGS file: the Name value of the entry $($entryIndex + 1) of the file 'ItemProperties.yaml' of the source folder of item '$stagedItemId' is of type '$($propertiesValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # The row count staged for the entry is remembered before its
        # properties are staged, so that the deferred warnings of the
        # entry fire only when it actually contributed rows.
        $entryRowsBefore = $stagedRows.Count
        for ($propertyIndex = 0; $propertyIndex -lt $propertiesValue.Count; $propertyIndex++) {
            $propertyValue = $propertiesValue[$propertyIndex]
            if ($null -eq $propertyValue) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId': the property is null."
                continue
            }
            if ($propertyValue -isnot [System.Collections.IDictionary]) {
                throw "Cannot compress the ItemProperties data of the RAGS file: the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' is of type '$($propertyValue.GetType().FullName)' instead of a mapping."
            }

            # Ignore any unexpected key of the property with a warning, as
            # the expansion writes properties with the Name and Value keys
            # only.
            $propertyExtraKeys = [System.Collections.Generic.List[string]]::new()
            foreach ($propertyKey in $propertyValue.Keys) {
                $propertyKeyText = [string]$propertyKey
                if ((-not [string]::Equals($propertyKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
                    (-not [string]::Equals($propertyKeyText, 'Value', [System.StringComparison]::Ordinal))) {
                    $propertyExtraKeys.Add($propertyKeyText)
                }
            }
            if ($propertyExtraKeys.Count -gt 0) {
                $propertyExtraKeyText = ($propertyExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
                Write-Warning "The property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' defines the unexpected key(s) $propertyExtraKeyText; they are ignored."
            }

            # Locate and validate the Name value of the property, which
            # the expansion writes as a string scalar. A scalar of any
            # other type (a hand-edited unquoted number, for example) is
            # coerced to its invariant string form with a warning.
            $propertyNameValue = $propertyValue['Name']
            if ($null -eq $propertyNameValue) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId': the Name value is missing or null, so no property can be derived from it."
                continue
            }

            if ($propertyNameValue -is [System.Collections.IList]) {
                throw "Cannot compress the ItemProperties data of the RAGS file: the Name of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' carries a sequence where a scalar value is expected."
            }
            elseif ($propertyNameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the ItemProperties data of the RAGS file: the Name of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' carries a mapping where a scalar value is expected."
            }
            elseif ($propertyNameValue -is [string]) {
                $propertyName = $propertyNameValue
            }
            else {
                Write-Warning "The Name of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' is of type '$($propertyNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($propertyNameValue -is [System.IFormattable]) {
                    $propertyName = $propertyNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $propertyName = [string]$propertyNameValue
                }
            }

            if ([string]::IsNullOrWhiteSpace($propertyName)) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId': the Name value is empty, so no property can be derived from it."
                continue
            }

            # Truncate the property Name value to the length of the table
            # column, as a longer value could not be stored.
            if ($propertyName.Length -gt 250) {
                Write-Warning "The Name value of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId' is $($propertyName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different property from the truncated value."
                $propertyName = $propertyName.Substring(0, 250)
            }

            # A null Value value is a meaningful property value (it is
            # stored as a database null); every other value is stored as a
            # string, except for non-string scalars which are coerced to
            # their invariant string form (format-sensitive values
            # therefore round-trip through hosts of different cultures).
            # The value is derived BEFORE the duplicate check below, so
            # that the warning of the check reports the value of the
            # ignored property.
            $propertyDataValue = $propertyValue['Value']
            $storableValue = $null
            if ($null -ne $propertyDataValue) {
                if ($propertyDataValue -is [string]) {
                    $storableValue = $propertyDataValue
                }
                elseif ($propertyDataValue -is [System.Collections.IList]) {
                    throw "Cannot compress the ItemProperties data of the RAGS file: the Value of the property '$propertyName' of the entry $($entryIndex + 1) for item '$stagedItemId' carries a sequence where a scalar value is expected."
                }
                elseif ($propertyDataValue -is [System.Collections.IDictionary]) {
                    throw "Cannot compress the ItemProperties data of the RAGS file: the Value of the property '$propertyName' of the entry $($entryIndex + 1) for item '$stagedItemId' carries a mapping where a scalar value is expected."
                }
                else {
                    Write-Warning "The Value of the property '$propertyName' of the entry $($entryIndex + 1) for item '$stagedItemId' is of type '$($propertyDataValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                    if ($propertyDataValue -is [System.IFormattable]) {
                        $storableValue = $propertyDataValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $storableValue = [string]$propertyDataValue
                    }
                }

                # A YAML literal block scalar normalizes line breaks to
                # line-feed characters when the written YAML is read back,
                # so carriage returns are normalized away beforehand to
                # keep the round-trip byte-exact. The normalized value is
                # assigned to a local first: operator expressions passed
                # directly as method arguments are mis-tokenized as
                # additional arguments on both hosts.
                $normalizedValue = ([string]$storableValue) -replace '\r\n?', "`n"
                $storableValue = $normalizedValue
            }

            # Soft-validate the Unique Name column: the property names of
            # an item are expected to contain only distinct values, so a
            # property which repeats the exact property name of a
            # previously read property of the same item is skipped with a
            # warning (the value of the first read property wins, like
            # the expansion). Names which differ only in character case
            # are distinct properties. The name set of the item is shared
            # by every entry of the item, including merged case-mate
            # entries.
            if (-not $nameSet.Add($propertyName)) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for item '$stagedItemId': the property name '$propertyName' duplicates the property name of a previously read property (whose value wins). The ignored duplicate property has the value $(if ($null -eq $storableValue) { '<null>' } else { $storableValue })."
                continue
            }

            $stagedRows.Add([pscustomobject]@{
                ItemID        = $stagedItemId
                Name          = $propertyName
                Value         = $storableValue
                EntryIndex    = $entryIndex + 1
                PropertyIndex = $propertyIndex + 1
            })
        }

        # The deferred warnings of the entry (an ItemID truncation
        # round-trip loss and a case-mate merge) fire only when it
        # actually contributed rows: an entry whose properties were all
        # skipped loses nothing at re-expansion.
        if ($stagedRows.Count -gt $entryRowsBefore) {
            foreach ($pendingWarning in $pendingWarnings) {
                Write-Warning $pendingWarning
            }
            $contributingEntries.Add($entryIndex + 1)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the ItemProperties table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the property $($stagedRow.PropertyIndex) of the entry $($stagedRow.EntryIndex) for item '$($stagedRow.ItemID)' to the ItemProperties table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [ItemProperties] ([ItemID], [Name], [Value]) VALUES (@itemid, @name, @value)'

                    $itemParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@itemid', [System.Data.SqlDbType]::NVarChar, 250)
                    $itemParameter.Value = $stagedRow.ItemID
                    $null = $command.Parameters.Add($itemParameter)

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 250)
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $valueParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@value', [System.Data.SqlDbType]::NText)
                    if ($null -eq $stagedRow.Value) {
                        # A parameter value of $null means 'not supplied',
                        # so a null Value column is bound as a database
                        # null.
                        $valueParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $valueParameter.Value = $stagedRow.Value
                    }
                    $null = $command.Parameters.Add($valueParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the ItemProperties table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The ItemProperties transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the ItemProperties data of the RAGS file: the staged rows could not be appended to the ItemProperties table. "
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

    Write-Verbose "Compressed the ItemProperties data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

