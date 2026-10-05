#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-CharactersIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses Characters data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded Characters data of a source folder back into the
    Characters table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-CharactersFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'Characters.yaml' file of the source folder is read as a YAML
    document holding a top-level 'Characters' mapping whose value is a
    sequence with one entry per character, each mapping the nine columns of
    the Characters table: the Charname key and the other eight column
    values. One table row is appended per character entry (the Characters
    table holds no identity column), replicating the row order of the
    original expansion: entries keep their YAML sequence order, which is
    the ascending Charname order of the original table read.

    The 'Characters.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'Characters' envelope
      around the entry sequence, so a non-mapping document predates this
      layout). Keys of the document other than the 'Characters' envelope
      key are ignored with a warning.
    - A document whose Characters value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      A Characters value which is an empty sequence is treated like the
      empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - A Characters value which is a scalar or a single mapping (as
      hand-edited files omitting the trailing sequence dash commonly are)
      is accepted as the single entry of the sequence with a warning; a
      value of any other type aborts the whole operation with an
      exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful row can be derived from it.
    - An entry whose Charname value is not a string aborts the whole
      operation with an exception. An entry whose Charname value is
      missing, null, empty or whitespace-only is skipped in its entirety
      with a warning, as no character entry key can be derived from it.
    - A Charname value longer than the 250 characters of the table column
      is truncated with a warning; note that re-expanding the appended
      data then derives a different entry from the truncated value.
    - A text column value which is a scalar but not a string (a
      hand-edited unquoted number, for example) is coerced to its string
      form with a warning; the string form of format-sensitive values is
      derived with the invariant culture, so such a value round-trips
      through hosts of different cultures. This applies to the
      CharnameOverride, CurrentRoom, Description and CharPortrait values.
      The CharnameOverride value is truncated to the 250 characters of
      its table column, the CharPortrait value to the 255 characters of
      its column; a text column value which is a sequence or a mapping
      aborts the whole operation with an exception, as no meaningful
      scalar can be derived from it.
    - A CharGender value which is missing or null is stored as a database
      null without a warning, as the expansion emits a YAML null for a
      null CharGender column. A CharGender value which is an integer
      scalar is stored as read. Any other scalar is parsed with the
      invariant culture with a warning; a value which cannot be parsed
      aborts the whole operation with an exception.
    - A bit column value (AllowInventoryInteraction, EnterFirstTime,
      LeaveFirstTime) which is missing or null is stored as false without
      a warning, as the expansion emits a YAML false for a null bit
      column. A bit column value which is a boolean is stored as read; an
      integer scalar of 1 or 0 is accepted with a warning; a value of any
      other type or content aborts the whole operation with an exception.
    - An entry which repeats the Charname value of a previously read
      entry, ignoring character case (mirroring the case-insensitive
      unique check of the expansion and the RAGS Designer limitation it
      documents), is skipped with a warning which names the column values
      of the ignored duplicate entry (the column values of the first read
      entry win).
    - Keys of an entry other than the nine column names are ignored with
      a warning.

    The 'Characters.yaml' file is read, validated and fully staged before
    the first row is appended, so the table remains empty when the source
    folder carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no partially
    appended data behind.

    The 'Characters.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the Characters table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source folder compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the Characters data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-CharactersIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded Characters data of the 'C:\Export\MyGame' folder
    to the Characters table of the RAGS file connected through
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
        throw "Cannot compress the Characters data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'Characters.yaml' file:
    # no expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'Characters.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'Characters.yaml' file, so there is no Characters data to compress."
        return $true
    }
    Write-Verbose "Compressing the Characters data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the Characters data of the RAGS file: the file 'Characters.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the Characters data of the RAGS file: the file 'Characters.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the Characters data of the RAGS file: the file 'Characters.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'Characters.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream. A missing value after the parse is therefore reported
    # like a missing document.
    $rootDocument = $parsedDocuments[0]
    if ($null -eq $rootDocument) {
        throw "Cannot compress the Characters data of the RAGS file: the file 'Characters.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the Characters data of the RAGS file: the file 'Characters.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'Characters' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'Characters', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'Characters.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['Characters']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'Characters.yaml' of the source folder: the Characters value is missing or null, so no character data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'Characters.yaml' of the source folder: the Characters value is empty, so no character data can be derived from it."
        }
        else {
            Write-Warning "The Characters value of the file 'Characters.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The Characters value of the file 'Characters.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        throw "Cannot compress the Characters data of the RAGS file: the Characters value of the file 'Characters.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per character entry before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the nine column values of the row and the 1-based
    # entry index which produced it for the messages of the append phase.
    # The validation of every entry is performed inline below, so that the
    # file is fully validated (and every failure reported) before any row
    # is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The Charname values of the entries whose rows were staged are kept
    # separately so that the duplicate check can compare them
    # case-insensitively (the Unique semantics follow the case-insensitive
    # database collation, in deviation from the compressions which group
    # case-sensitively).
    $admittedCharnames = [System.Collections.Generic.List[string]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the Characters data of the RAGS file: the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Locate and validate the Charname value of the entry, which is
        # expected to be the string scalar the expansion wrote.
        $entryCharname = $entryValue['Charname']
        if ($null -eq $entryCharname) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder: the Charname value is missing or null, so no character entry can be derived for it."
            continue
        }
        if ($entryCharname -isnot [string]) {
            throw "Cannot compress the Characters data of the RAGS file: the Charname value of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($entryCharname.GetType().FullName)' instead of a string."
        }
        if ([string]::IsNullOrWhiteSpace($entryCharname)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder: the Charname value is empty, so no character entry can be derived for it."
            continue
        }

        # Truncate the Charname value to the length of the table column,
        # as a longer value could not be stored.
        $charname = $entryCharname
        if ($charname.Length -gt 250) {
            Write-Warning "The Charname value of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is $($charname.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry from the truncated value."
            $charname = $charname.Substring(0, 250)
        }

        # Normalize the remaining eight column values to their storable
        # row values. Every value is derived BEFORE the duplicate check
        # below, so that the warning of the check reports the values of
        # the ignored duplicate entry. A null value is stored as a
        # database null, except for the three bit columns, where a null
        # is stored as the documented false.
        $charnameOverrideValue = $entryValue['CharnameOverride']
        $charnameOverride = $null
        if ($null -ne $charnameOverrideValue) {
            if ($charnameOverrideValue -is [System.Collections.IList]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharnameOverride of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($charnameOverrideValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharnameOverride of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($charnameOverrideValue -is [string]) {
                $charnameOverride = $charnameOverrideValue
            }
            else {
                Write-Warning "The CharnameOverride of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($charnameOverrideValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($charnameOverrideValue -is [System.IFormattable]) {
                    $charnameOverride = $charnameOverrideValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $charnameOverride = [string]$charnameOverrideValue
                }
            }

            if ($charnameOverride.Length -gt 250) {
                Write-Warning "The CharnameOverride of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is $($charnameOverride.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $charnameOverride = $charnameOverride.Substring(0, 250)
            }
        }

        $chargenderValue = $entryValue['CharGender']
        $charGender = $null
        if ($null -ne $chargenderValue) {
            if ($chargenderValue -is [System.Collections.IList]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a sequence where an integer scalar is expected."
            }
            elseif ($chargenderValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a mapping where an integer scalar is expected."
            }
            elseif (($chargenderValue -is [int]) -or ($chargenderValue -is [long])) {
                $charGender = [int]$chargenderValue
            }
            else {
                $genderText = $null
                if ($chargenderValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($chargenderValue)) {
                        throw "Cannot compress the Characters data of the RAGS file: the CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                    }
                    $genderText = $chargenderValue
                    Write-Warning "The CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($chargenderValue.GetType().FullName)' instead of an integer; it is parsed with the invariant culture."
                }
                else {
                    Write-Warning "The CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($chargenderValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                    if ($chargenderValue -is [System.IFormattable]) {
                        $genderText = $chargenderValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $genderText = [string]$chargenderValue
                    }
                }

                $parsedGender = 0
                if (-not [int]::TryParse($genderText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedGender)) {
                    throw "Cannot compress the Characters data of the RAGS file: the CharGender of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                }
                $charGender = $parsedGender
            }
        }

        $currentRoomValue = $entryValue['CurrentRoom']
        $currentRoom = $null
        if ($null -ne $currentRoomValue) {
            if ($currentRoomValue -is [System.Collections.IList]) {
                throw "Cannot compress the Characters data of the RAGS file: the CurrentRoom of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($currentRoomValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Characters data of the RAGS file: the CurrentRoom of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($currentRoomValue -is [string]) {
                $currentRoom = $currentRoomValue
            }
            else {
                Write-Warning "The CurrentRoom of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($currentRoomValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($currentRoomValue -is [System.IFormattable]) {
                    $currentRoom = $currentRoomValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $currentRoom = [string]$currentRoomValue
                }
            }
        }

        # The Description value is stored as read (the expansion normalizes
        # line breaks on both sides of the round-trip), with the same
        # scalar coercion as the other text columns. Like every ntext
        # column it holds no length limit to truncate to.
        $descriptionValue = $entryValue['Description']
        $description = $null
        if ($null -ne $descriptionValue) {
            if ($descriptionValue -is [System.Collections.IList]) {
                throw "Cannot compress the Characters data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($descriptionValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Characters data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($descriptionValue -is [string]) {
                $description = $descriptionValue
            }
            else {
                Write-Warning "The Description of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($descriptionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($descriptionValue -is [System.IFormattable]) {
                    $description = $descriptionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $description = [string]$descriptionValue
                }
            }
        }

        # The managed reader of the expansion reads bit columns as Boolean
        # values, so the YAML counterparts are booleans; a missing or null
        # value is stored as the documented false.
        $allowInventoryInteractionValue = $entryValue['AllowInventoryInteraction']
        $allowInventoryInteraction = $false
        if ($allowInventoryInteractionValue -is [bool]) {
            $allowInventoryInteraction = $allowInventoryInteractionValue
        }
        elseif ($null -ne $allowInventoryInteractionValue) {
            if (($allowInventoryInteractionValue -is [int]) -or ($allowInventoryInteractionValue -is [long])) {
                if ($allowInventoryInteractionValue -eq 1) {
                    Write-Warning "The AllowInventoryInteraction of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $allowInventoryInteraction = $true
                }
                elseif ($allowInventoryInteractionValue -eq 0) {
                    Write-Warning "The AllowInventoryInteraction of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $allowInventoryInteraction = $false
                }
                else {
                    throw "Cannot compress the Characters data of the RAGS file: the AllowInventoryInteraction of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer $allowInventoryInteractionValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Characters data of the RAGS file: the AllowInventoryInteraction of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($allowInventoryInteractionValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $enterFirstTimeValue = $entryValue['EnterFirstTime']
        $enterFirstTime = $false
        if ($enterFirstTimeValue -is [bool]) {
            $enterFirstTime = $enterFirstTimeValue
        }
        elseif ($null -ne $enterFirstTimeValue) {
            if (($enterFirstTimeValue -is [int]) -or ($enterFirstTimeValue -is [long])) {
                if ($enterFirstTimeValue -eq 1) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $enterFirstTime = $true
                }
                elseif ($enterFirstTimeValue -eq 0) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $enterFirstTime = $false
                }
                else {
                    throw "Cannot compress the Characters data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer $enterFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Characters data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($enterFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $leaveFirstTimeValue = $entryValue['LeaveFirstTime']
        $leaveFirstTime = $false
        if ($leaveFirstTimeValue -is [bool]) {
            $leaveFirstTime = $leaveFirstTimeValue
        }
        elseif ($null -ne $leaveFirstTimeValue) {
            if (($leaveFirstTimeValue -is [int]) -or ($leaveFirstTimeValue -is [long])) {
                if ($leaveFirstTimeValue -eq 1) {
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $leaveFirstTime = $true
                }
                elseif ($leaveFirstTimeValue -eq 0) {
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $leaveFirstTime = $false
                }
                else {
                    throw "Cannot compress the Characters data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is the integer $leaveFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Characters data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($leaveFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $charPortraitValue = $entryValue['CharPortrait']
        $charPortrait = $null
        if ($null -ne $charPortraitValue) {
            if ($charPortraitValue -is [System.Collections.IList]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharPortrait of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($charPortraitValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Characters data of the RAGS file: the CharPortrait of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($charPortraitValue -is [string]) {
                $charPortrait = $charPortraitValue
            }
            else {
                Write-Warning "The CharPortrait of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is of type '$($charPortraitValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($charPortraitValue -is [System.IFormattable]) {
                    $charPortrait = $charPortraitValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $charPortrait = [string]$charPortraitValue
                }
            }

            if ($charPortrait.Length -gt 255) {
                Write-Warning "The CharPortrait of the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder is $($charPortrait.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $charPortrait = $charPortrait.Substring(0, 255)
            }
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the nine column names only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'Charname', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'CharnameOverride', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'CharGender', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'CurrentRoom', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Description', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'AllowInventoryInteraction', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'EnterFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LeaveFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'CharPortrait', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder for character '$charname' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Soft-validate the Unique Charname column: an entry whose value
        # compares equal to a previously read entry's value, ignoring
        # character case, is skipped with a warning naming the column
        # values of the ignored duplicate entry (the column values of the
        # first read entry win).
        $duplicate = $false
        foreach ($existingCharname in $admittedCharnames) {
            if ([string]::Equals($existingCharname, $charname, [System.StringComparison]::OrdinalIgnoreCase)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $charnameOverride) { $evidenceParts.Add('CharnameOverride <null>') } else { $evidenceParts.Add('CharnameOverride ''' + $charnameOverride + '''') }
            if ($null -eq $charGender) { $evidenceParts.Add('CharGender <null>') } else { $evidenceParts.Add('CharGender ' + $charGender) }
            if ($null -eq $currentRoom) { $evidenceParts.Add('CurrentRoom <null>') } else { $evidenceParts.Add('CurrentRoom ''' + $currentRoom + '''') }
            if ($null -eq $description) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            $evidenceParts.Add('AllowInventoryInteraction equals ' + $allowInventoryInteraction + ' after reading')
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $charPortrait) { $evidenceParts.Add('CharPortrait <null>') } else { $evidenceParts.Add('CharPortrait ''' + $charPortrait + '''') }

            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Characters.yaml' of the source folder: the Charname value '$charname' duplicates the Charname value of a previously read entry (whose column values win). The ignored duplicate entry has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedCharnames.Add($charname)

        $stagedRows.Add([pscustomobject]@{
            Charname                  = $charname
            CharnameOverride          = $charnameOverride
            CharGender                = $charGender
            CurrentRoom               = $currentRoom
            Description               = $description
            AllowInventoryInteraction = $allowInventoryInteraction
            EnterFirstTime            = $enterFirstTime
            LeaveFirstTime            = $leaveFirstTime
            CharPortrait              = $charPortrait
            EntryIndex                = $entryIndex + 1
        })

        $contributingEntries.Add($entryIndex + 1)
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the Characters table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) (character '$($stagedRow.Charname)') to the Characters table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [Characters] ([Charname], [CharnameOverride], [CharGender], [CurrentRoom], [Description], [AllowInventoryInteraction], [EnterFirstTime], [LeaveFirstTime], [CharPortrait]) VALUES (@charname, @charnameoverride, @chargender, @currentroom, @description, @allowinventoryinteraction, @enterfirsttime, @leavefirsttime, @charportrait)'

                    $charnameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@charname', [System.Data.SqlDbType]::NVarChar, 250)
                    $charnameParameter.Value = $stagedRow.Charname
                    $null = $command.Parameters.Add($charnameParameter)

                    $charnameOverrideParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@charnameoverride', [System.Data.SqlDbType]::NVarChar, 250)
                    if ($null -eq $stagedRow.CharnameOverride) {
                        # A parameter value of $null means 'not supplied',
                        # so a null column value is bound as a database
                        # null.
                        $charnameOverrideParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $charnameOverrideParameter.Value = $stagedRow.CharnameOverride
                    }
                    $null = $command.Parameters.Add($charnameOverrideParameter)

                    $charGenderParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@chargender', [System.Data.SqlDbType]::Int)
                    if ($null -eq $stagedRow.CharGender) {
                        $charGenderParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $charGenderParameter.Value = $stagedRow.CharGender
                    }
                    $null = $command.Parameters.Add($charGenderParameter)

                    $currentRoomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@currentroom', [System.Data.SqlDbType]::NVarChar, 250)
                    if ($null -eq $stagedRow.CurrentRoom) {
                        $currentRoomParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $currentRoomParameter.Value = $stagedRow.CurrentRoom
                    }
                    $null = $command.Parameters.Add($currentRoomParameter)

                    $descriptionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@description', [System.Data.SqlDbType]::NText)
                    if ($null -eq $stagedRow.Description) {
                        $descriptionParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $descriptionParameter.Value = $stagedRow.Description
                    }
                    $null = $command.Parameters.Add($descriptionParameter)

                    # A bit parameter requires a boolean value no matter
                    # what the column carried in the YAML file, so every
                    # value is bound as the boolean it normalized to.
                    $allowInventoryInteractionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@allowinventoryinteraction', [System.Data.SqlDbType]::Bit)
                    $allowInventoryInteractionParameter.Value = $stagedRow.AllowInventoryInteraction
                    $null = $command.Parameters.Add($allowInventoryInteractionParameter)

                    $enterFirstTimeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enterfirsttime', [System.Data.SqlDbType]::Bit)
                    $enterFirstTimeParameter.Value = $stagedRow.EnterFirstTime
                    $null = $command.Parameters.Add($enterFirstTimeParameter)

                    $leaveFirstTimeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@leavefirsttime', [System.Data.SqlDbType]::Bit)
                    $leaveFirstTimeParameter.Value = $stagedRow.LeaveFirstTime
                    $null = $command.Parameters.Add($leaveFirstTimeParameter)

                    $charPortraitParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@charportrait', [System.Data.SqlDbType]::NVarChar, 255)
                    if ($null -eq $stagedRow.CharPortrait) {
                        $charPortraitParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $charPortraitParameter.Value = $stagedRow.CharPortrait
                    }
                    $null = $command.Parameters.Add($charPortraitParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the Characters table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The Characters transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the Characters data of the RAGS file: the staged rows could not be appended to the Characters table. "
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

    Write-Verbose "Compressed the Characters data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

