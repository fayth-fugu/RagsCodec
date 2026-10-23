#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-PlayerIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses Player data into a RagsFile.

    <#
    .SYNOPSIS
    Compresses Player data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded Player data of a source folder back into the
    Player table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed row as the
    inverse of Expand-PlayerFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'Player.yaml' file of the source folder is read as a YAML
    document holding a bare top-level mapping which carries one key per
    column of the Player table, in the column order of the schema. One
    table row is appended from the mapping, whichever subset of the
    column keys the mapping defines.

    The 'Player.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the bare column mapping, so
      a non-mapping document predates this layout).
    - Keys of the document other than the eleven table columns are
      ignored with a warning.
    - A text column value (Name, CurrentRoom, PlayerLayeredImage) which
      is missing or null is stored as a database null without a warning,
      as the expansion emits a YAML null for a null column. A value
      which is a scalar but not a string (a hand-edited unquoted number,
      for example) is coerced to its string form with a warning; the
      string form of format-sensitive values is derived with the
      invariant culture, so such a value round-trips through hosts of
      different cultures. A text column value longer than the 250
      characters of its table column is truncated with a warning; a text
      column value which is a sequence or a mapping aborts the whole
      operation with an exception, as no meaningful scalar can be
      derived from it.
    - The StartingRoom and PlayerPortrait values are additionally always
      coerced to lowercase during compression, as documented for the
      'Player' table in docs/data-mapping.md ('values of these columns
      will always be coerced to lowercase during expansion and
      compression'). The truncation described above runs first, and the
      truncated value is then lowercased whenever its casing differs
      from its lowercase form — with one warning naming the value and
      the lowercased form it is stored with (the expansion warns the
      same way during expansion).
    - The Description ntext column value is stored as read, with the
      same scalar coercion as the text columns. Like every ntext column
      it holds no length limit to truncate to; no line-ending
      normalization is applied on either side of the round-trip (the
      verbatim contract of the expansion family).
    - A bit column value (PromptForName, PromptForGender, EnforceWeight)
      which is missing or null is stored as false without a warning, as
      the YAML rules of the data mapping document: the value 0 and null
      of a bit column map to false. A bit column value which is a
      boolean is stored as read; an integer scalar of 1 or 0 is accepted
      with a warning; a value of any other type or content aborts the
      whole operation with an exception.
    - A PlayerGender value which is missing or null is stored as a
      database null without a warning. An integer scalar is stored as
      read; a string or other scalar is parsed with the invariant
      culture with a warning; a value which cannot be parsed aborts the
      whole operation with an exception.
    - A WeightLimit value which is missing or null is stored as a
      database null without a warning. Every numeric scalar form the
      YAML parser can produce for an emitted value (doubles, integers,
      decimals and arbitrary-precision integers) is converted to its
      float form without a warning, as those are re-parse forms of
      expansion emissions; a string or any other scalar is derived to
      its invariant text form with a warning and parsed with the
      invariant culture. A value which cannot be parsed, or whose parsed
      form is not a storable float number (NaN or an infinity), aborts
      the whole operation with an exception.
    - A mapping which defines none of the column keys (an empty mapping,
      such as the one the expansion writes for an empty Player table)
      still contributes one row of database-null text values and false
      bit values. Note that re-expanding such a row then yields the
      values the row was stored with (the false bit values), never the
      all-null mapping again: a stored false bit cannot be distinguished
      from the documented false reading of a null bit after the
      round-trip.

    The 'Player.yaml' file is read, validated and fully staged before
    the row is appended, so the table remains unchanged when the source
    folder carries invalid content. The appended row is then written
    inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The 'Player.yaml' file is read silently; a missing source folder or
    file is not an error and compresses nothing.

    Compressed rows are appended to the Player table, which is expected
    to receive them (the RAGS Designer workflow of compressing expanded
    data keeps the convention of starting from the template file, or
    from a blank/formatted RAGS file at the caller's discretion). The
    Player table is documented in docs/data-mapping.md to hold only a
    single row, so the expansion reads only the first row the database
    returns and shows 'a warning containing the values of subsequent
    ignored duplicate rows': a source folder appended to a RAGS file
    which already carries Player rows therefore leaves the appended row
    readable only where the engine returns it ahead of them (every row
    read ahead is then reported as ignored), and a source folder
    compressed more than once into the same RAGS file appends the table
    once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the Player data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-PlayerIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded Player data of the 'C:\Export\MyGame' folder
    to the Player table of the RAGS file connected through
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
        throw "Cannot compress the Player data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'Player.yaml' file:
    # no expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'Player.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'Player.yaml' file, so there is no Player data to compress."
        return $true
    }
    Write-Verbose "Compressing the Player data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the Player data of the RAGS file: the file 'Player.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the Player data of the RAGS file: the file 'Player.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the Player data of the RAGS file: the file 'Player.yaml' of the source folder is not a valid YAML document. "
        $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    # ConvertFrom-Yaml returns the parsed value of a multi-document stream
    # as an object array of one element per document (see the
    # CharacterActions handler); a single-document stream is collapsed by
    # the array wrap, so a count above one is still the sign of extra
    # documents. Note that the wrap can inflate the count when a document
    # itself is a sequence; the warning only ever dismisses trailing
    # content, so this cannot misdirect the read below.
    if ($parsedDocuments.Count -gt 1) {
        Write-Warning "The file 'Player.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream — including a stream which carries comments only, which
    # yields nothing at all. A missing value after the parse is therefore
    # reported like a missing document; the count is guarded first, so
    # that a comment-only stream reaches the contextual throw below
    # instead of a raw array-index error under strict mode.
    $rootDocument = $null
    if ($parsedDocuments.Count -gt 0) {
        $rootDocument = $parsedDocuments[0]
    }
    if ($null -eq $rootDocument) {
        throw "Cannot compress the Player data of the RAGS file: the file 'Player.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the Player data of the RAGS file: the file 'Player.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document with the eleven column names only.
    $documentExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if ((-not [string]::Equals($documentKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'Description', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'StartingRoom', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'CurrentRoom', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PlayerLayeredImage', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PlayerGender', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PromptForName', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PromptForGender', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PlayerPortrait', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'EnforceWeight', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'WeightLimit', [System.StringComparison]::Ordinal))) {
            $documentExtraKeys.Add($documentKeyText)
        }
    }
    if ($documentExtraKeys.Count -gt 0) {
        $documentExtraKeyText = ($documentExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'Player.yaml' of the source folder defines the unexpected key(s) $documentExtraKeyText; they are ignored."
    }

    # The nvarchar columns are stored as their YAML strings, with
    # format-sensitive scalars coerced through their invariant string
    # form.
    $nameValue = $rootDocument['Name']
    $name = $null
    if ($null -ne $nameValue) {
        if ($nameValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the Name of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($nameValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the Name of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($nameValue -is [string]) {
            $name = $nameValue
        }
        else {
            Write-Warning "The Name of the file 'Player.yaml' of the source folder is of type '$($nameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($nameValue -is [System.IFormattable]) {
                $name = $nameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $name = [string]$nameValue
            }
        }

        if ($name.Length -gt 250) {
            Write-Warning "The Name of the file 'Player.yaml' of the source folder is $($name.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $name = $name.Substring(0, 250)
        }
    }

    # The Description ntext column is stored as read, with the same
    # scalar coercion as the text columns but no length limit to truncate
    # to (the verbatim contract of the expansion family).
    $descriptionValue = $rootDocument['Description']
    $description = $null
    if ($null -ne $descriptionValue) {
        if ($descriptionValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the Description of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($descriptionValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the Description of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($descriptionValue -is [string]) {
            $description = $descriptionValue
        }
        else {
            Write-Warning "The Description of the file 'Player.yaml' of the source folder is of type '$($descriptionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($descriptionValue -is [System.IFormattable]) {
                $description = $descriptionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $description = [string]$descriptionValue
            }
        }
    }

    # The StartingRoom value is stored truncated and lowercased, as
    # documented for the 'Player' table in docs/data-mapping.md ('values
    # of these columns will always be coerced to lowercase during
    # expansion and compression'). Truncation runs first, the truncated
    # value is then evaluated against its lowercase form and is warned
    # about once before it is stored lowercased — the expansion warns
    # the same way per written value during expansion, so a hand-edited
    # mixed-case value never reaches the database unflagged.
    $startingRoomValue = $rootDocument['StartingRoom']
    $startingRoom = $null
    if ($null -ne $startingRoomValue) {
        if ($startingRoomValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the StartingRoom of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($startingRoomValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the StartingRoom of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($startingRoomValue -is [string]) {
            $startingRoom = $startingRoomValue
        }
        else {
            Write-Warning "The StartingRoom of the file 'Player.yaml' of the source folder is of type '$($startingRoomValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($startingRoomValue -is [System.IFormattable]) {
                $startingRoom = $startingRoomValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $startingRoom = [string]$startingRoomValue
            }
        }

        if ($startingRoom.Length -gt 250) {
            Write-Warning "The StartingRoom of the file 'Player.yaml' of the source folder is $($startingRoom.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $startingRoom = $startingRoom.Substring(0, 250)
        }

        $startingRoomLowercased = $startingRoom.ToLowerInvariant()
        if (-not [string]::Equals($startingRoomLowercased, $startingRoom, [System.StringComparison]::Ordinal)) {
            Write-Warning "The StartingRoom value '$startingRoom' of the file 'Player.yaml' of the source folder is coerced to its lowercase form '$startingRoomLowercased' during compression."
        }
        $startingRoom = $startingRoomLowercased
    }

    $currentRoomValue = $rootDocument['CurrentRoom']
    $currentRoom = $null
    if ($null -ne $currentRoomValue) {
        if ($currentRoomValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the CurrentRoom of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($currentRoomValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the CurrentRoom of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($currentRoomValue -is [string]) {
            $currentRoom = $currentRoomValue
        }
        else {
            Write-Warning "The CurrentRoom of the file 'Player.yaml' of the source folder is of type '$($currentRoomValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($currentRoomValue -is [System.IFormattable]) {
                $currentRoom = $currentRoomValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $currentRoom = [string]$currentRoomValue
            }
        }

        if ($currentRoom.Length -gt 250) {
            Write-Warning "The CurrentRoom of the file 'Player.yaml' of the source folder is $($currentRoom.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $currentRoom = $currentRoom.Substring(0, 250)
        }
    }

    $playerLayeredImageValue = $rootDocument['PlayerLayeredImage']
    $playerLayeredImage = $null
    if ($null -ne $playerLayeredImageValue) {
        if ($playerLayeredImageValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerLayeredImage of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($playerLayeredImageValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerLayeredImage of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($playerLayeredImageValue -is [string]) {
            $playerLayeredImage = $playerLayeredImageValue
        }
        else {
            Write-Warning "The PlayerLayeredImage of the file 'Player.yaml' of the source folder is of type '$($playerLayeredImageValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($playerLayeredImageValue -is [System.IFormattable]) {
                $playerLayeredImage = $playerLayeredImageValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $playerLayeredImage = [string]$playerLayeredImageValue
            }
        }

        if ($playerLayeredImage.Length -gt 250) {
            Write-Warning "The PlayerLayeredImage of the file 'Player.yaml' of the source folder is $($playerLayeredImage.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $playerLayeredImage = $playerLayeredImage.Substring(0, 250)
        }
    }

    # The PlayerPortrait value follows the StartingRoom pattern: stored
    # truncated and lowercased, with one warning per value whose casing
    # differs from its lowercase form (the expansion warns the same way
    # per written value during expansion).
    $playerPortraitValue = $rootDocument['PlayerPortrait']
    $playerPortrait = $null
    if ($null -ne $playerPortraitValue) {
        if ($playerPortraitValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerPortrait of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($playerPortraitValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerPortrait of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($playerPortraitValue -is [string]) {
            $playerPortrait = $playerPortraitValue
        }
        else {
            Write-Warning "The PlayerPortrait of the file 'Player.yaml' of the source folder is of type '$($playerPortraitValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($playerPortraitValue -is [System.IFormattable]) {
                $playerPortrait = $playerPortraitValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $playerPortrait = [string]$playerPortraitValue
            }
        }

        if ($playerPortrait.Length -gt 250) {
            Write-Warning "The PlayerPortrait of the file 'Player.yaml' of the source folder is $($playerPortrait.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $playerPortrait = $playerPortrait.Substring(0, 250)
        }

        $playerPortraitLowercased = $playerPortrait.ToLowerInvariant()
        if (-not [string]::Equals($playerPortraitLowercased, $playerPortrait, [System.StringComparison]::Ordinal)) {
            Write-Warning "The PlayerPortrait value '$playerPortrait' of the file 'Player.yaml' of the source folder is coerced to its lowercase form '$playerPortraitLowercased' during compression."
        }
        $playerPortrait = $playerPortraitLowercased
    }

    # The PlayerGender column is nullable in the database, so a missing
    # or null value is stored as a database null without a warning; an
    # integer scalar is stored as read; every other scalar is parsed
    # with the invariant culture with a warning.
    $playerGenderValue = $rootDocument['PlayerGender']
    $playerGender = $null
    if ($null -ne $playerGenderValue) {
        if ($playerGenderValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerGender of the file 'Player.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($playerGenderValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the PlayerGender of the file 'Player.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif (($playerGenderValue -is [int]) -or ($playerGenderValue -is [long])) {
            $playerGender = [int]$playerGenderValue
        }
        else {
            if ($playerGenderValue -is [string]) {
                if ([string]::IsNullOrWhiteSpace($playerGenderValue)) {
                    throw "Cannot compress the Player data of the RAGS file: the PlayerGender of the file 'Player.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                }
                Write-Warning "The PlayerGender of the file 'Player.yaml' of the source folder is a string instead of an integer; it is parsed with the invariant culture."
                $playerGenderText = $playerGenderValue
            }
            else {
                Write-Warning "The PlayerGender of the file 'Player.yaml' of the source folder is of type '$($playerGenderValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                if ($playerGenderValue -is [System.IFormattable]) {
                    $playerGenderText = $playerGenderValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $playerGenderText = [string]$playerGenderValue
                }
            }

            $parsedPlayerGender = 0
            if (-not [int]::TryParse($playerGenderText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedPlayerGender)) {
                throw "Cannot compress the Player data of the RAGS file: the PlayerGender of the file 'Player.yaml' of the source folder is a scalar which cannot be parsed as an integer."
            }
            $playerGender = $parsedPlayerGender
        }
    }

    # The managed reader of the expansion reads bit columns as Boolean
    # values, so the YAML counterparts are booleans; a missing or null
    # value is stored as the documented false (the value null of a bit
    # column maps to false, per the YAML rules of the data mapping
    # document).
    $promptForNameValue = $rootDocument['PromptForName']
    $promptForName = $false
    if ($promptForNameValue -is [bool]) {
        $promptForName = $promptForNameValue
    }
    elseif ($null -ne $promptForNameValue) {
        if (($promptForNameValue -is [int]) -or ($promptForNameValue -is [long])) {
            if ($promptForNameValue -eq 1) {
                Write-Warning "The PromptForName of the file 'Player.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $promptForName = $true
            }
            elseif ($promptForNameValue -eq 0) {
                Write-Warning "The PromptForName of the file 'Player.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $promptForName = $false
            }
            else {
                throw "Cannot compress the Player data of the RAGS file: the PromptForName of the file 'Player.yaml' of the source folder is the integer $promptForNameValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the Player data of the RAGS file: the PromptForName of the file 'Player.yaml' of the source folder is of type '$($promptForNameValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $promptForGenderValue = $rootDocument['PromptForGender']
    $promptForGender = $false
    if ($promptForGenderValue -is [bool]) {
        $promptForGender = $promptForGenderValue
    }
    elseif ($null -ne $promptForGenderValue) {
        if (($promptForGenderValue -is [int]) -or ($promptForGenderValue -is [long])) {
            if ($promptForGenderValue -eq 1) {
                Write-Warning "The PromptForGender of the file 'Player.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $promptForGender = $true
            }
            elseif ($promptForGenderValue -eq 0) {
                Write-Warning "The PromptForGender of the file 'Player.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $promptForGender = $false
            }
            else {
                throw "Cannot compress the Player data of the RAGS file: the PromptForGender of the file 'Player.yaml' of the source folder is the integer $promptForGenderValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the Player data of the RAGS file: the PromptForGender of the file 'Player.yaml' of the source folder is of type '$($promptForGenderValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $enforceWeightValue = $rootDocument['EnforceWeight']
    $enforceWeight = $false
    if ($enforceWeightValue -is [bool]) {
        $enforceWeight = $enforceWeightValue
    }
    elseif ($null -ne $enforceWeightValue) {
        if (($enforceWeightValue -is [int]) -or ($enforceWeightValue -is [long])) {
            if ($enforceWeightValue -eq 1) {
                Write-Warning "The EnforceWeight of the file 'Player.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $enforceWeight = $true
            }
            elseif ($enforceWeightValue -eq 0) {
                Write-Warning "The EnforceWeight of the file 'Player.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $enforceWeight = $false
            }
            else {
                throw "Cannot compress the Player data of the RAGS file: the EnforceWeight of the file 'Player.yaml' of the source folder is the integer $enforceWeightValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the Player data of the RAGS file: the EnforceWeight of the file 'Player.yaml' of the source folder is of type '$($enforceWeightValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    # The WeightLimit column is a float column; the expansion emits a
    # YAML number for a present value and a YAML null for a missing one.
    # Every numeric scalar form the YAML parser can produce for an
    # emitted value (doubles, integers, decimals and
    # arbitrary-precision integers) is converted to its float form
    # without a warning, as those are re-parse forms of expansion
    # emissions (the shortest-float emission '2.5' re-parses as a
    # decimal, integer-valued floats re-parse as integers); a
    # conversion result which cannot be storable as a float number
    # aborts the whole operation. A string or any other scalar is
    # derived to its invariant text form with a warning and parsed with
    # the invariant culture. A missing or null value is stored as a
    # database null without a warning.
    $weightLimitValue = $rootDocument['WeightLimit']
    $weightLimit = $null
    if ($null -ne $weightLimitValue) {
        if ($weightLimitValue -is [System.Collections.IList]) {
            throw "Cannot compress the Player data of the RAGS file: the WeightLimit of the file 'Player.yaml' of the source folder carries a sequence where a number is expected."
        }
        elseif ($weightLimitValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Player data of the RAGS file: the WeightLimit of the file 'Player.yaml' of the source folder carries a mapping where a number is expected."
        }
        else {
            $weightLimitText = $null
            if ($weightLimitValue -is [string]) {
                if ([string]::IsNullOrWhiteSpace($weightLimitValue)) {
                    throw "Cannot compress the Player data of the RAGS file: the WeightLimit of the file 'Player.yaml' of the source folder is a scalar which cannot be parsed as a number."
                }
                $weightLimitText = $weightLimitValue
                Write-Warning "The WeightLimit of the file 'Player.yaml' of the source folder is a string instead of a number; it is parsed with the invariant culture."
            }
            else {
                $weightLimitIsNumeric = ($weightLimitValue -is [double]) -or
                    ($weightLimitValue -is [SByte]) -or
                    ($weightLimitValue -is [Byte]) -or
                    ($weightLimitValue -is [Int16]) -or
                    ($weightLimitValue -is [UInt16]) -or
                    ($weightLimitValue -is [int]) -or
                    ($weightLimitValue -is [UInt32]) -or
                    ($weightLimitValue -is [long]) -or
                    ($weightLimitValue -is [UInt64]) -or
                    ($weightLimitValue -is [float]) -or
                    ($weightLimitValue -is [decimal]) -or
                    ($weightLimitValue -is [System.Numerics.BigInteger])
                if ($weightLimitValue -is [System.IFormattable]) {
                    $weightLimitText = $weightLimitValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $weightLimitText = [string]$weightLimitValue
                }
                if (-not $weightLimitIsNumeric) {
                    Write-Warning "The WeightLimit of the file 'Player.yaml' of the source folder is of type '$($weightLimitValue.GetType().FullName)' instead of a number; it is coerced to its invariant string form and parsed with the invariant culture."
                }
            }

            $parsedWeightLimit = [double]0
            if (-not [double]::TryParse($weightLimitText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedWeightLimit)) {
                throw "Cannot compress the Player data of the RAGS file: the WeightLimit of the file 'Player.yaml' of the source folder is a scalar which cannot be parsed as a number."
            }
            if ([System.Double]::IsNaN($parsedWeightLimit) -or [System.Double]::IsInfinity($parsedWeightLimit)) {
                throw "Cannot compress the Player data of the RAGS file: the WeightLimit of the file 'Player.yaml' of the source folder is a scalar which cannot be stored as a float number."
            }
            $weightLimit = $parsedWeightLimit
        }
    }

    # The validated column values are staged before anything is appended,
    # so that the file is fully validated before any SQL runs (all-or-
    # nothing, like every file of the expansion). Exactly one row is
    # appended per source file — also for a mapping which defines none
    # of the column keys (an empty mapping, such as the one the
    # expansion writes for an empty Player table), which contributes one
    # row of database-null text values and false bit values.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $stagedRows.Add([pscustomobject]@{
        Name               = $name
        Description        = $description
        StartingRoom       = $startingRoom
        CurrentRoom        = $currentRoom
        PlayerLayeredImage = $playerLayeredImage
        PlayerGender       = $playerGender
        PromptForName      = $promptForName
        PromptForGender    = $promptForGender
        PlayerPortrait     = $playerPortrait
        EnforceWeight      = $enforceWeight
        WeightLimit        = $weightLimit
    })

    # Append the staged row to the Player table inside one transaction,
    # so that a failed INSERT leaves no partially appended data behind.
    # The values are bound through provider parameters throughout, as the
    # text values are not SQL literals (and long values are far beyond
    # any quoting limit).
    $transaction = $null
    try {
        $transaction = $RagsConnection.BeginTransaction()

        Write-Verbose "Appending the Player row to the Player table."

        $command = $RagsConnection.CreateCommand()
        try {
            $command.Transaction = $transaction
            $command.CommandText = 'INSERT INTO [Player] ([Name], [Description], [StartingRoom], [CurrentRoom], [PlayerLayeredImage], [PlayerGender], [PromptForName], [PromptForGender], [PlayerPortrait], [EnforceWeight], [WeightLimit]) VALUES (@name, @description, @startingroom, @currentroom, @playerlayeredimage, @playergender, @promptforname, @promptforgender, @playerportrait, @enforceweight, @weightlimit)'

            $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $name) {
                # A parameter value of $null means 'not supplied', so a
                # null column value is bound as a database null.
                $nameParameter.Value = [System.DBNull]::Value
            }
            else {
                $nameParameter.Value = $name
            }
            $null = $command.Parameters.Add($nameParameter)

            $descriptionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@description', [System.Data.SqlDbType]::NText)
            if ($null -eq $description) {
                $descriptionParameter.Value = [System.DBNull]::Value
            }
            else {
                $descriptionParameter.Value = $description
            }
            $null = $command.Parameters.Add($descriptionParameter)

            $startingRoomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@startingroom', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $startingRoom) {
                $startingRoomParameter.Value = [System.DBNull]::Value
            }
            else {
                $startingRoomParameter.Value = $startingRoom
            }
            $null = $command.Parameters.Add($startingRoomParameter)

            $currentRoomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@currentroom', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $currentRoom) {
                $currentRoomParameter.Value = [System.DBNull]::Value
            }
            else {
                $currentRoomParameter.Value = $currentRoom
            }
            $null = $command.Parameters.Add($currentRoomParameter)

            $playerLayeredImageParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@playerlayeredimage', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $playerLayeredImage) {
                $playerLayeredImageParameter.Value = [System.DBNull]::Value
            }
            else {
                $playerLayeredImageParameter.Value = $playerLayeredImage
            }
            $null = $command.Parameters.Add($playerLayeredImageParameter)

            $playerGenderParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@playergender', [System.Data.SqlDbType]::Int)
            if ($null -eq $playerGender) {
                $playerGenderParameter.Value = [System.DBNull]::Value
            }
            else {
                $playerGenderParameter.Value = $playerGender
            }
            $null = $command.Parameters.Add($playerGenderParameter)

            # A bit parameter requires a boolean value no matter what the
            # column carried in the YAML file, so every bit value is bound
            # as the boolean it normalized to.
            $promptForNameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@promptforname', [System.Data.SqlDbType]::Bit)
            $promptForNameParameter.Value = $promptForName
            $null = $command.Parameters.Add($promptForNameParameter)

            $promptForGenderParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@promptforgender', [System.Data.SqlDbType]::Bit)
            $promptForGenderParameter.Value = $promptForGender
            $null = $command.Parameters.Add($promptForGenderParameter)

            $playerPortraitParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@playerportrait', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $playerPortrait) {
                $playerPortraitParameter.Value = [System.DBNull]::Value
            }
            else {
                $playerPortraitParameter.Value = $playerPortrait
            }
            $null = $command.Parameters.Add($playerPortraitParameter)

            # The WeightLimit parameter binds the normalized float value
            # (the column is nullable, so a missing value is bound as a
            # database null).
            $weightLimitParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@weightlimit', [System.Data.SqlDbType]::Float)
            if ($null -eq $weightLimit) {
                $weightLimitParameter.Value = [System.DBNull]::Value
            }
            else {
                $weightLimitParameter.Value = [double]$weightLimit
            }
            $null = $command.Parameters.Add($weightLimitParameter)

            $enforceWeightParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enforceweight', [System.Data.SqlDbType]::Bit)
            $enforceWeightParameter.Value = $enforceWeight
            $null = $command.Parameters.Add($enforceWeightParameter)

            $null = $command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }

        $transaction.Commit()
        Write-Verbose 'Appended 1 row(s) to the Player table.'
    }
    catch {
        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            }
            catch {
                Write-Warning "The Player transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
            }
        }

        $message = "Cannot compress the Player data of the RAGS file: the staged row could not be appended to the Player table. "
        $message += "The database reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }
    finally {
        if ($null -ne $transaction) {
            $transaction.Dispose()
        }
    }

    Write-Verbose 'Compressed the Player data of the RAGS file: 1 row(s) appended.'
    return $true
}

