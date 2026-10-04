#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-CharacterPropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses CharacterProperties data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded CharacterProperties data of a source folder back
    into the CharacterProperties table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection, appending the compressed
    rows as the inverse of Expand-CharacterPropertiesFromRagsFile and
    following the conventions documented in docs/data-mapping.md.

    The single 'CharacterProperties.yaml' file of the source folder is read
    as a YAML document holding a top-level 'CharacterProperties' mapping
    whose value is a sequence with one entry per character: each entry maps
    a Charname value to the Name key, whose value is a sequence of property
    mappings holding the property Name and its Value. One table row is
    appended per property (the Identity column value is supplied by the
    database), replicating the row order of the original expansion: entries
    keep their YAML sequence order and the properties of every entry keep
    their YAML sequence order, so re-expanding the file restores the
    entries and their properties in ascending row ID order.

    The 'CharacterProperties.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'CharacterProperties'
      envelope around the entry sequence, so a non-mapping document
      predates this layout). Keys of the document other than the
      'CharacterProperties' envelope key are ignored with a warning.
    - A document whose CharacterProperties value is missing, null, empty
      or whitespace-only contributes no rows and is skipped with a
      warning. A CharacterProperties value which is an empty sequence is
      treated like the empty sequence an expansion writes for an empty
      table and contributes no rows without a warning.
    - A CharacterProperties value which is a scalar or a single mapping
      (as hand-edited files omitting the trailing sequence dash commonly
      are) is accepted as the single entry of the sequence with a
      warning; a value of any other type aborts the whole operation with
      an exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping, an entry whose Charname value is not a string, an
      entry whose Name value is neither a scalar nor a sequence, a
      property which is not a mapping, a property whose Name value is not
      a string, and a property Value which is a sequence or a mapping
      abort the whole operation with an exception, as no meaningful row
      can be derived from them.
    - An entry whose Charname value is missing, null, empty or
      whitespace-only is skipped in its entirety with a warning, as no
      meaningful expansion target could be derived from it. A Charname
      value longer than the 250 characters of the table column is
      truncated with a warning; note that re-expanding the appended data
      then derives a different entry layout from the truncated value, so
      such an entry may not survive a compress/expand cycle byte-exactly
      either.
    - An entry which repeats the exact Charname value of a previously
      read entry is warned about; the properties of all such entries are
      appended under the same character, as one character cannot carry
      two property sets in the table. Property names which differ only in
      character case remain distinct names.
    - An entry whose Name value is missing, null, empty, whitespace-only
      or an empty sequence is skipped in its entirety with a warning, as
      no property can be derived from it. A Name value which is a scalar
      or a single mapping is accepted as the single entry of the sequence
      with a warning.
    - Properties which are null, or whose Name value is missing, null,
      empty or whitespace-only, are skipped with a warning. A property
      Name value longer than the 250 characters of the table column is
      truncated with a warning, which may make two distinct property
      names indistinguishable.
    - A property which repeats the exact property name of a previously
      read property of the same character is skipped with a warning (the
      value of the first read property wins, mirroring the Unique
      soft-validation of the expansion; the warning reports the value of
      the ignored property).
    - A property Value which is missing or null is stored as a database
      null without a warning, as the expansion emits a YAML null for a
      null Value column. A property Value which is a scalar but not a
      string (a hand-edited unquoted number, for example) is coerced to
      its string form with a warning; the string form of format-sensitive
      values is derived with the invariant culture, so such a value
      round-trips through hosts of different cultures (except for date
      values, which are written in their invariant general form rather
      than as the ISO 8601 string an expansion extracts).
    - Keys of an entry other than Charname and Name, and keys of a
      property other than Name and Value, are ignored with a warning.

    The 'CharacterProperties.yaml' file is read, validated and fully
    staged before the first row is appended, so the table remains empty
    when the source folder carries invalid content. The appended rows are
    then written inside a transaction, so a failure while appending leaves
    no partially appended data behind.

    The 'CharacterProperties.yaml' file is read silently; a missing source
    folder or file is not an error and compresses nothing.

    Compressed rows are appended to the CharacterProperties table, which
    is expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template file,
    or a blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the CharacterProperties data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-CharacterPropertiesIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
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
        throw "Cannot compress the CharacterProperties data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'CharacterProperties.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'CharacterProperties.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'CharacterProperties.yaml' file, so there is no CharacterProperties data to compress."
        return $true
    }
    Write-Verbose "Compressing the CharacterProperties data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the CharacterProperties data of the RAGS file: the file 'CharacterProperties.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the CharacterProperties data of the RAGS file: the file 'CharacterProperties.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the CharacterProperties data of the RAGS file: the file 'CharacterProperties.yaml' of the source folder is not a valid YAML document. "
        $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    # ConvertFrom-Yaml returns the parsed value of a multi-document stream
    # as an object array of one element per document (see the CharacterActions
    # handler); a single-document stream is collapsed by the array wrap, so
    # a count above one is always the sign of extra documents. Note that
    # the wrap can inflate the count when a document itself is a sequence;
    # the warning only ever dismisses trailing content, so this cannot
    # misdirect the read below.
    if ($parsedDocuments.Count -gt 1) {
        Write-Warning "The file 'CharacterProperties.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream. A missing value after the parse is therefore reported
    # like a missing document.
    $rootDocument = $parsedDocuments[0]
    if ($null -eq $rootDocument) {
        throw "Cannot compress the CharacterProperties data of the RAGS file: the file 'CharacterProperties.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the CharacterProperties data of the RAGS file: the file 'CharacterProperties.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'CharacterProperties'
    # envelope mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'CharacterProperties', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'CharacterProperties.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['CharacterProperties']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'CharacterProperties.yaml' of the source folder: the CharacterProperties value is missing or null, so no property data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'CharacterProperties.yaml' of the source folder: the CharacterProperties value is empty, so no property data can be derived from it."
        }
        else {
            Write-Warning "The CharacterProperties value of the file 'CharacterProperties.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The CharacterProperties value of the file 'CharacterProperties.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        throw "Cannot compress the CharacterProperties data of the RAGS file: the CharacterProperties value of the file 'CharacterProperties.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per property before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the character name, the property name, the storable
    # property value (a string, or $null for a database null) and the
    # 1-based entry and property indices which produced it for the
    # messages of the append phase. The validation of every entry is
    # performed inline below, so that the file is fully validated (and
    # every failure reported) before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # Character names and their per-character property name sets are kept
    # as parallel lists so that repeated entries of one character merge
    # their properties under one name set (a character cannot carry two
    # property sets in the table), and so the character lookup can compare
    # ordinally (property names which differ only in character case are
    # distinct properties). The name sets are ordinal hash sets, which
    # both compare and reject duplicate names in one operation.
    $entryCharnames = [System.Collections.Generic.List[string]]::new()
    $characterNameSets = [System.Collections.Generic.List[object]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the CharacterProperties data of the RAGS file: the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Locate and validate the Charname value of the entry, which is
        # expected to be the string scalar the expansion wrote.
        $entryCharname = $entryValue['Charname']
        if ($null -eq $entryCharname) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder: the Charname value is missing or null, so no character can be derived for it."
            continue
        }
        if ($entryCharname -isnot [string]) {
            throw "Cannot compress the CharacterProperties data of the RAGS file: the Charname value of the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder is of type '$($entryCharname.GetType().FullName)' instead of a string."
        }
        if ([string]::IsNullOrWhiteSpace($entryCharname)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder: the Charname value is empty, so no character can be derived for it."
            continue
        }

        # Truncate the Charname value to the length of the table column,
        # as a longer value could not be stored.
        $charname = $entryCharname
        if ($charname.Length -gt 250) {
            Write-Warning "The Charname value of the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder is $($charname.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry layout from the truncated value."
            $charname = $charname.Substring(0, 250)
        }

        # Locate or create the character tracked for the (truncated)
        # Charname value, warning about every repeated entry.
        $characterFound = -1
        for ($candidateIndex = 0; $candidateIndex -lt $entryCharnames.Count; $candidateIndex++) {
            if ([string]::Equals($entryCharnames[$candidateIndex], $charname, [System.StringComparison]::Ordinal)) {
                $characterFound = $candidateIndex
                break
            }
        }
        if ($characterFound -lt 0) {
            $entryCharnames.Add($charname)
            $characterNameSets.Add([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal))
            $characterIndex = $entryCharnames.Count - 1
        }
        else {
            $characterIndex = $characterFound
            Write-Warning "The entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder repeats the Charname value of a previously read entry; the properties of both entries are appended under the same character."
        }
        $nameSet = $characterNameSets[$characterIndex]

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the Charname and Name keys only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'Charname', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder for character '$charname' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Locate and validate the Name value of the entry, which is a
        # sequence of property mappings. A scalar or single-mapping value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        $propertiesValue = $entryValue['Name']
        if ($null -eq $propertiesValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname': the Name value is missing or null, so no property can be derived from it."
            continue
        }

        if ($propertiesValue -is [System.Collections.IList]) {
            if ($propertiesValue.Count -eq 0) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname': the Name value is an empty sequence, so no property can be derived from it."
                continue
            }
        }
        elseif ($propertiesValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($propertiesValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname': the Name value is empty, so no property can be derived from it."
                continue
            }

            Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedProperties = [System.Collections.Generic.List[object]]::new()
            $coercedProperties.Add($propertiesValue)
            $propertiesValue = $coercedProperties
        }
        elseif ($propertiesValue -is [System.Collections.IDictionary]) {
            Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname' is a single mapping, not a sequence; it is treated as the single entry of the sequence."
            $coercedProperties = [System.Collections.Generic.List[object]]::new()
            $coercedProperties.Add($propertiesValue)
            $propertiesValue = $coercedProperties
        }
        else {
            throw "Cannot compress the CharacterProperties data of the RAGS file: the Name value of the entry $($entryIndex + 1) of the file 'CharacterProperties.yaml' of the source folder of character '$charname' is of type '$($propertiesValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        $entryRowsBefore = $stagedRows.Count
        for ($propertyIndex = 0; $propertyIndex -lt $propertiesValue.Count; $propertyIndex++) {
            $propertyValue = $propertiesValue[$propertyIndex]
            if ($null -eq $propertyValue) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname': the property is null."
                continue
            }
            if ($propertyValue -isnot [System.Collections.IDictionary]) {
                throw "Cannot compress the CharacterProperties data of the RAGS file: the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname' is of type '$($propertyValue.GetType().FullName)' instead of a mapping."
            }

            # Locate and validate the Name value of the property, which is
            # expected to be the string scalar the expansion wrote.
            $propertyNameValue = $propertyValue['Name']
            if ($null -eq $propertyNameValue) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname': the Name value is missing or null, so no property can be derived from it."
                continue
            }
            if ($propertyNameValue -isnot [string]) {
                throw "Cannot compress the CharacterProperties data of the RAGS file: the Name value of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname' is of type '$($propertyNameValue.GetType().FullName)' instead of a string."
            }
            if ([string]::IsNullOrWhiteSpace($propertyNameValue)) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname': the Name value is empty, so no property can be derived from it."
                continue
            }

            # Truncate the property Name value to the length of the table
            # column, as a longer value could not be stored.
            $propertyName = $propertyNameValue
            if ($propertyName.Length -gt 250) {
                Write-Warning "The Name value of the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname' is $($propertyName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different property from the truncated value."
                $propertyName = $propertyName.Substring(0, 250)
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
                Write-Warning "The property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname' defines the unexpected key(s) $propertyExtraKeyText; they are ignored."
            }

            # A null Value value is a meaningful property value (it is
            # stored as a database null); every other value is stored as a
            # string as read, except for non-string scalars which are
            # coerced to their invariant string form (format-sensitive
            # values therefore round-trip through hosts of different
            # cultures). The value is derived BEFORE the duplicate check
            # below, so that the warning of the check reports the value of
            # the ignored property.
            $propertyDataValue = $propertyValue['Value']
            $storableValue = $null
            if ($null -ne $propertyDataValue) {
                if ($propertyDataValue -is [string]) {
                    $storableValue = $propertyDataValue
                }
                elseif ($propertyDataValue -is [System.Collections.IList]) {
                    throw "Cannot compress the CharacterProperties data of the RAGS file: the Value of the property '$propertyName' of the entry $($entryIndex + 1) for character '$charname' carries a sequence where a scalar value is expected."
                }
                elseif ($propertyDataValue -is [System.Collections.IDictionary]) {
                    throw "Cannot compress the CharacterProperties data of the RAGS file: the Value of the property '$propertyName' of the entry $($entryIndex + 1) for character '$charname' carries a mapping where a scalar value is expected."
                }
                else {
                    Write-Warning "The Value of the property '$propertyName' of the entry $($entryIndex + 1) for character '$charname' is of type '$($propertyDataValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                    if ($propertyDataValue -is [System.IFormattable]) {
                        $storableValue = $propertyDataValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $storableValue = [string]$propertyDataValue
                    }
                }
            }

            # Soft-validate the Unique Name column: the property Name of a
            # character is expected to contain only distinct values, so a
            # property which repeats the exact property name of a
            # previously read property of the same character is skipped
            # with a warning (the value of the first read property wins,
            # like the expansion). Names which differ only in character
            # case are distinct properties.
            if (-not $nameSet.Add($propertyName)) {
                Write-Warning "Skipping the property $($propertyIndex + 1) of the entry $($entryIndex + 1) for character '$charname': the property name '$propertyName' duplicates the property name of a previously read property (whose value wins). The ignored duplicate property has the value $(if ($null -eq $storableValue) { '<null>' } else { $storableValue })."
                continue
            }

            $stagedRows.Add([pscustomobject]@{
                Charname      = $charname
                Name          = $propertyName
                Value         = $storableValue
                EntryIndex    = $entryIndex + 1
                PropertyIndex = $propertyIndex + 1
            })
        }

        if ($stagedRows.Count -gt $entryRowsBefore) {
            $contributingEntries.Add($entryIndex + 1)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the CharacterProperties table inside
        # one transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the property $($stagedRow.PropertyIndex) of the entry $($stagedRow.EntryIndex) for character '$($stagedRow.Charname)' to the CharacterProperties table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [CharacterProperties] ([Charname], [Name], [Value]) VALUES (@charname, @name, @value)'

                    $charnameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@charname', [System.Data.SqlDbType]::NVarChar, 250)
                    $charnameParameter.Value = $stagedRow.Charname
                    $null = $command.Parameters.Add($charnameParameter)

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
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the CharacterProperties table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The CharacterProperties transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the CharacterProperties data of the RAGS file: the staged rows could not be appended to the CharacterProperties table. "
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

    Write-Verbose "Compressed the CharacterProperties data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

