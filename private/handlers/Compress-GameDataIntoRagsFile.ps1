#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-GameDataIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses GameData data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded GameData data of a source folder back into the
    GameData table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed row as the
    inverse of Expand-GameDataFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'GameData.yaml' file of the source folder is read as a YAML
    document holding a bare top-level mapping which carries one key per
    column of the GameData table, in the column order of the schema. One
    table row is appended from the mapping (the GameData table holds a
    single row in a well-formed RAGS file and carries no identity column),
    whichever subset of the column keys the mapping defines.

    The 'GameData.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the bare column mapping, so
      a non-mapping document predates this layout).
    - Keys of the document other than the twenty table columns are
      ignored with a warning.
    - A text column value (Title, AuthorName, GameVersion, bgMusic,
      GamePassword, ObjectVersionNumber, GameFont) which is missing or
      null is stored as a database null without a warning, as the
      expansion emits a YAML null for a null column. A value which is a
      scalar but not a string (a hand-edited unquoted number, for
      example) is coerced to its string form with a warning; the string
      form of format-sensitive values is derived with the invariant
      culture, so such a value round-trips through hosts of different
      cultures. The GameVersion value is truncated to the 50 characters
      of its table column, the remaining nvarchar values to the 250
      characters of their columns; a text column value which is a
      sequence or a mapping aborts the whole operation with an exception,
      as no meaningful scalar can be derived from it.
    - An ntext column value (OpeningMessage, GameInformation, RoomGroups,
      ClothingZoneLevels) is stored as read, with the same scalar coercion
      as the text columns. Like every ntext column it holds no length
      limit to truncate to; the expansion normalizes line breaks on both
      sides of the round-trip.
    - A bit column value (HideMainPicDisplay, UseInlineImages, HidePortrait,
      RepeatbgMusic, PasswordProtected, NotificationsOff) which is missing
      or null is stored as false without a warning, as the expansion emits
      a YAML false for a null bit column. A bit column value which is a
      boolean is stored as read; an integer scalar of 1 or 0 is accepted
      with a warning; a value of any other type or content aborts the
      whole operation with an exception.
    - A SortOrderRoom, SortOrderCharacters or SortOrderInventory value
      which is missing or null is stored as the 0 its not-null table
      column documents as its default value, with a warning (an expansion
      never emits such a value, since these columns cannot be read as
      null). An integer scalar is stored as read; a string or other
      scalar is parsed with the invariant culture with a warning; a value
      which cannot be parsed aborts the whole operation with an exception.
    - A mapping which defines none of the column keys (an empty mapping,
      such as the one the expansion writes for an empty GameData table)
      still contributes one row of database-null text values, false bit
      values and the documented 0 sort orders. Note that re-expanding
      such a row then yields the all-null mapping an expansion writes for
      an empty table; the false bit values and the 0 sort orders cannot
      be distinguished from their null counterparts after the round-trip.

    The 'GameData.yaml' file is read, validated and fully staged before
    the row is appended, so the table remains unchanged when the source
    folder carries invalid content. The appended row is then written
    inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The 'GameData.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the GameData table, which is expected
    to receive them (the RAGS Designer workflow of compressing expanded
    data keeps the convention of starting from the template file, or from
    a blank/formatted RAGS file at the caller's discretion). The GameData
    table carries a single row in a well-formed RAGS file, and the
    expansion reads only the first row the database returns: a source
    folder appended to a RAGS file which already carries GameData rows
    therefore leaves the appended row readable only where the engine
    returns it ahead of them, and a source folder compressed more than
    once into the same RAGS file appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the GameData data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-GameDataIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded GameData data of the 'C:\Export\MyGame' folder
    to the GameData table of the RAGS file connected through
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
        throw "Cannot compress the GameData data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'GameData.yaml' file:
    # no expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'GameData.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'GameData.yaml' file, so there is no GameData data to compress."
        return $true
    }
    Write-Verbose "Compressing the GameData data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the GameData data of the RAGS file: the file 'GameData.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the GameData data of the RAGS file: the file 'GameData.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the GameData data of the RAGS file: the file 'GameData.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'GameData.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty stream. A missing value after the parse is therefore reported
    # like a missing document.
    $rootDocument = $parsedDocuments[0]
    if ($null -eq $rootDocument) {
        throw "Cannot compress the GameData data of the RAGS file: the file 'GameData.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the GameData data of the RAGS file: the file 'GameData.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document with the twenty column names only.
    $documentExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if ((-not [string]::Equals($documentKeyText, 'Title', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'OpeningMessage', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'HideMainPicDisplay', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'UseInlineImages', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'HidePortrait', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'AuthorName', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'GameVersion', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'GameInformation', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'bgMusic', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'RepeatbgMusic', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'PasswordProtected', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'GamePassword', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'ObjectVersionNumber', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'GameFont', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'RoomGroups', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'ClothingZoneLevels', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'NotificationsOff', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'SortOrderRoom', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'SortOrderCharacters', [System.StringComparison]::Ordinal)) -and
            (-not [string]::Equals($documentKeyText, 'SortOrderInventory', [System.StringComparison]::Ordinal))) {
            $documentExtraKeys.Add($documentKeyText)
        }
    }
    if ($documentExtraKeys.Count -gt 0) {
        $documentExtraKeyText = ($documentExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'GameData.yaml' of the source folder defines the unexpected key(s) $documentExtraKeyText; they are ignored."
    }

    # Normalize the twenty column values of the document to their storable
    # row values before anything is appended, so that the file is fully
    # validated before any SQL runs. A missing value reads as null.

    # The nvarchar columns are stored as their YAML strings, with
    # format-sensitive scalars coerced through their invariant string form.

    $titleValue = $rootDocument['Title']
    $title = $null
    if ($null -ne $titleValue) {
        if ($titleValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the Title of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($titleValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the Title of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($titleValue -is [string]) {
            $title = $titleValue
        }
        else {
            Write-Warning "The Title of the file 'GameData.yaml' of the source folder is of type '$($titleValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($titleValue -is [System.IFormattable]) {
                $title = $titleValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $title = [string]$titleValue
            }
        }

        if ($title.Length -gt 250) {
            Write-Warning "The Title of the file 'GameData.yaml' of the source folder is $($title.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $title = $title.Substring(0, 250)
        }
    }

    $authorNameValue = $rootDocument['AuthorName']
    $authorName = $null
    if ($null -ne $authorNameValue) {
        if ($authorNameValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the AuthorName of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($authorNameValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the AuthorName of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($authorNameValue -is [string]) {
            $authorName = $authorNameValue
        }
        else {
            Write-Warning "The AuthorName of the file 'GameData.yaml' of the source folder is of type '$($authorNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($authorNameValue -is [System.IFormattable]) {
                $authorName = $authorNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $authorName = [string]$authorNameValue
            }
        }

        if ($authorName.Length -gt 250) {
            Write-Warning "The AuthorName of the file 'GameData.yaml' of the source folder is $($authorName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $authorName = $authorName.Substring(0, 250)
        }
    }

    $gameVersionValue = $rootDocument['GameVersion']
    $gameVersion = $null
    if ($null -ne $gameVersionValue) {
        if ($gameVersionValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameVersion of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($gameVersionValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameVersion of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($gameVersionValue -is [string]) {
            $gameVersion = $gameVersionValue
        }
        else {
            Write-Warning "The GameVersion of the file 'GameData.yaml' of the source folder is of type '$($gameVersionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($gameVersionValue -is [System.IFormattable]) {
                $gameVersion = $gameVersionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $gameVersion = [string]$gameVersionValue
            }
        }

        if ($gameVersion.Length -gt 50) {
            Write-Warning "The GameVersion of the file 'GameData.yaml' of the source folder is $($gameVersion.Length) characters long, which exceeds the 50 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $gameVersion = $gameVersion.Substring(0, 50)
        }
    }

    $bgMusicValue = $rootDocument['bgMusic']
    $bgMusic = $null
    if ($null -ne $bgMusicValue) {
        if ($bgMusicValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the bgMusic of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($bgMusicValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the bgMusic of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($bgMusicValue -is [string]) {
            $bgMusic = $bgMusicValue
        }
        else {
            Write-Warning "The bgMusic of the file 'GameData.yaml' of the source folder is of type '$($bgMusicValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($bgMusicValue -is [System.IFormattable]) {
                $bgMusic = $bgMusicValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $bgMusic = [string]$bgMusicValue
            }
        }

        if ($bgMusic.Length -gt 250) {
            Write-Warning "The bgMusic of the file 'GameData.yaml' of the source folder is $($bgMusic.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $bgMusic = $bgMusic.Substring(0, 250)
        }
    }

    $gamePasswordValue = $rootDocument['GamePassword']
    $gamePassword = $null
    if ($null -ne $gamePasswordValue) {
        if ($gamePasswordValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the GamePassword of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($gamePasswordValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the GamePassword of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($gamePasswordValue -is [string]) {
            $gamePassword = $gamePasswordValue
        }
        else {
            Write-Warning "The GamePassword of the file 'GameData.yaml' of the source folder is of type '$($gamePasswordValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($gamePasswordValue -is [System.IFormattable]) {
                $gamePassword = $gamePasswordValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $gamePassword = [string]$gamePasswordValue
            }
        }

        if ($gamePassword.Length -gt 250) {
            Write-Warning "The GamePassword of the file 'GameData.yaml' of the source folder is $($gamePassword.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $gamePassword = $gamePassword.Substring(0, 250)
        }
    }

    $objectVersionNumberValue = $rootDocument['ObjectVersionNumber']
    $objectVersionNumber = $null
    if ($null -ne $objectVersionNumberValue) {
        if ($objectVersionNumberValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the ObjectVersionNumber of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($objectVersionNumberValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the ObjectVersionNumber of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($objectVersionNumberValue -is [string]) {
            $objectVersionNumber = $objectVersionNumberValue
        }
        else {
            Write-Warning "The ObjectVersionNumber of the file 'GameData.yaml' of the source folder is of type '$($objectVersionNumberValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($objectVersionNumberValue -is [System.IFormattable]) {
                $objectVersionNumber = $objectVersionNumberValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $objectVersionNumber = [string]$objectVersionNumberValue
            }
        }

        if ($objectVersionNumber.Length -gt 250) {
            Write-Warning "The ObjectVersionNumber of the file 'GameData.yaml' of the source folder is $($objectVersionNumber.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $objectVersionNumber = $objectVersionNumber.Substring(0, 250)
        }
    }

    $gameFontValue = $rootDocument['GameFont']
    $gameFont = $null
    if ($null -ne $gameFontValue) {
        if ($gameFontValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameFont of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($gameFontValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameFont of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($gameFontValue -is [string]) {
            $gameFont = $gameFontValue
        }
        else {
            Write-Warning "The GameFont of the file 'GameData.yaml' of the source folder is of type '$($gameFontValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($gameFontValue -is [System.IFormattable]) {
                $gameFont = $gameFontValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $gameFont = [string]$gameFontValue
            }
        }

        if ($gameFont.Length -gt 250) {
            Write-Warning "The GameFont of the file 'GameData.yaml' of the source folder is $($gameFont.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
            $gameFont = $gameFont.Substring(0, 250)
        }
    }

    # The ntext columns are stored as read, with the same scalar coercion
    # as the text columns but no length limit to truncate to.
    $openingMessageValue = $rootDocument['OpeningMessage']
    $openingMessage = $null
    if ($null -ne $openingMessageValue) {
        if ($openingMessageValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the OpeningMessage of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($openingMessageValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the OpeningMessage of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($openingMessageValue -is [string]) {
            $openingMessage = $openingMessageValue
        }
        else {
            Write-Warning "The OpeningMessage of the file 'GameData.yaml' of the source folder is of type '$($openingMessageValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($openingMessageValue -is [System.IFormattable]) {
                $openingMessage = $openingMessageValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $openingMessage = [string]$openingMessageValue
            }
        }
    }

    $gameInformationValue = $rootDocument['GameInformation']
    $gameInformation = $null
    if ($null -ne $gameInformationValue) {
        if ($gameInformationValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameInformation of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($gameInformationValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the GameInformation of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($gameInformationValue -is [string]) {
            $gameInformation = $gameInformationValue
        }
        else {
            Write-Warning "The GameInformation of the file 'GameData.yaml' of the source folder is of type '$($gameInformationValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($gameInformationValue -is [System.IFormattable]) {
                $gameInformation = $gameInformationValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $gameInformation = [string]$gameInformationValue
            }
        }
    }

    $roomGroupsValue = $rootDocument['RoomGroups']
    $roomGroups = $null
    if ($null -ne $roomGroupsValue) {
        if ($roomGroupsValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the RoomGroups of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($roomGroupsValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the RoomGroups of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($roomGroupsValue -is [string]) {
            $roomGroups = $roomGroupsValue
        }
        else {
            Write-Warning "The RoomGroups of the file 'GameData.yaml' of the source folder is of type '$($roomGroupsValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($roomGroupsValue -is [System.IFormattable]) {
                $roomGroups = $roomGroupsValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $roomGroups = [string]$roomGroupsValue
            }
        }
    }

    $clothingZoneLevelsValue = $rootDocument['ClothingZoneLevels']
    $clothingZoneLevels = $null
    if ($null -ne $clothingZoneLevelsValue) {
        if ($clothingZoneLevelsValue -is [System.Collections.IList]) {
            throw "Cannot compress the GameData data of the RAGS file: the ClothingZoneLevels of the file 'GameData.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($clothingZoneLevelsValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the GameData data of the RAGS file: the ClothingZoneLevels of the file 'GameData.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($clothingZoneLevelsValue -is [string]) {
            $clothingZoneLevels = $clothingZoneLevelsValue
        }
        else {
            Write-Warning "The ClothingZoneLevels of the file 'GameData.yaml' of the source folder is of type '$($clothingZoneLevelsValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($clothingZoneLevelsValue -is [System.IFormattable]) {
                $clothingZoneLevels = $clothingZoneLevelsValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $clothingZoneLevels = [string]$clothingZoneLevelsValue
            }
        }
    }

    # The managed reader of the expansion reads bit columns as Boolean
    # values, so the YAML counterparts are booleans; a missing or null
    # value is stored as the documented false.
    $hideMainPicDisplayValue = $rootDocument['HideMainPicDisplay']
    $hideMainPicDisplay = $false
    if ($hideMainPicDisplayValue -is [bool]) {
        $hideMainPicDisplay = $hideMainPicDisplayValue
    }
    elseif ($null -ne $hideMainPicDisplayValue) {
        if (($hideMainPicDisplayValue -is [int]) -or ($hideMainPicDisplayValue -is [long])) {
            if ($hideMainPicDisplayValue -eq 1) {
                Write-Warning "The HideMainPicDisplay of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $hideMainPicDisplay = $true
            }
            elseif ($hideMainPicDisplayValue -eq 0) {
                Write-Warning "The HideMainPicDisplay of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $hideMainPicDisplay = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the HideMainPicDisplay of the file 'GameData.yaml' of the source folder is the integer $hideMainPicDisplayValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the HideMainPicDisplay of the file 'GameData.yaml' of the source folder is of type '$($hideMainPicDisplayValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $useInlineImagesValue = $rootDocument['UseInlineImages']
    $useInlineImages = $false
    if ($useInlineImagesValue -is [bool]) {
        $useInlineImages = $useInlineImagesValue
    }
    elseif ($null -ne $useInlineImagesValue) {
        if (($useInlineImagesValue -is [int]) -or ($useInlineImagesValue -is [long])) {
            if ($useInlineImagesValue -eq 1) {
                Write-Warning "The UseInlineImages of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $useInlineImages = $true
            }
            elseif ($useInlineImagesValue -eq 0) {
                Write-Warning "The UseInlineImages of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $useInlineImages = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the UseInlineImages of the file 'GameData.yaml' of the source folder is the integer $useInlineImagesValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the UseInlineImages of the file 'GameData.yaml' of the source folder is of type '$($useInlineImagesValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $hidePortraitValue = $rootDocument['HidePortrait']
    $hidePortrait = $false
    if ($hidePortraitValue -is [bool]) {
        $hidePortrait = $hidePortraitValue
    }
    elseif ($null -ne $hidePortraitValue) {
        if (($hidePortraitValue -is [int]) -or ($hidePortraitValue -is [long])) {
            if ($hidePortraitValue -eq 1) {
                Write-Warning "The HidePortrait of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $hidePortrait = $true
            }
            elseif ($hidePortraitValue -eq 0) {
                Write-Warning "The HidePortrait of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $hidePortrait = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the HidePortrait of the file 'GameData.yaml' of the source folder is the integer $hidePortraitValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the HidePortrait of the file 'GameData.yaml' of the source folder is of type '$($hidePortraitValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $repeatbgMusicValue = $rootDocument['RepeatbgMusic']
    $repeatbgMusic = $false
    if ($repeatbgMusicValue -is [bool]) {
        $repeatbgMusic = $repeatbgMusicValue
    }
    elseif ($null -ne $repeatbgMusicValue) {
        if (($repeatbgMusicValue -is [int]) -or ($repeatbgMusicValue -is [long])) {
            if ($repeatbgMusicValue -eq 1) {
                Write-Warning "The RepeatbgMusic of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $repeatbgMusic = $true
            }
            elseif ($repeatbgMusicValue -eq 0) {
                Write-Warning "The RepeatbgMusic of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $repeatbgMusic = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the RepeatbgMusic of the file 'GameData.yaml' of the source folder is the integer $repeatbgMusicValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the RepeatbgMusic of the file 'GameData.yaml' of the source folder is of type '$($repeatbgMusicValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $passwordProtectedValue = $rootDocument['PasswordProtected']
    $passwordProtected = $false
    if ($passwordProtectedValue -is [bool]) {
        $passwordProtected = $passwordProtectedValue
    }
    elseif ($null -ne $passwordProtectedValue) {
        if (($passwordProtectedValue -is [int]) -or ($passwordProtectedValue -is [long])) {
            if ($passwordProtectedValue -eq 1) {
                Write-Warning "The PasswordProtected of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $passwordProtected = $true
            }
            elseif ($passwordProtectedValue -eq 0) {
                Write-Warning "The PasswordProtected of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $passwordProtected = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the PasswordProtected of the file 'GameData.yaml' of the source folder is the integer $passwordProtectedValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the PasswordProtected of the file 'GameData.yaml' of the source folder is of type '$($passwordProtectedValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    $notificationsOffValue = $rootDocument['NotificationsOff']
    $notificationsOff = $false
    if ($notificationsOffValue -is [bool]) {
        $notificationsOff = $notificationsOffValue
    }
    elseif ($null -ne $notificationsOffValue) {
        if (($notificationsOffValue -is [int]) -or ($notificationsOffValue -is [long])) {
            if ($notificationsOffValue -eq 1) {
                Write-Warning "The NotificationsOff of the file 'GameData.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $notificationsOff = $true
            }
            elseif ($notificationsOffValue -eq 0) {
                Write-Warning "The NotificationsOff of the file 'GameData.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $notificationsOff = $false
            }
            else {
                throw "Cannot compress the GameData data of the RAGS file: the NotificationsOff of the file 'GameData.yaml' of the source folder is the integer $notificationsOffValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the GameData data of the RAGS file: the NotificationsOff of the file 'GameData.yaml' of the source folder is of type '$($notificationsOffValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }
    }

    # The three sort-order columns are not null in the database and
    # document a default value of 0; a missing or null value is stored
    # as that 0, with a warning (an expansion never emits such a value).
    # An integer scalar is stored as read; any other scalar is parsed
    # with the invariant culture with a warning.
    $sortOrderRoomValue = $rootDocument['SortOrderRoom']
    $sortOrderRoom = 0
    if ($null -eq $sortOrderRoomValue) {
        Write-Warning "The SortOrderRoom of the file 'GameData.yaml' of the source folder is missing or null; it is stored as the 0 the not-null table column documents as its default value."
    }
    elseif (($sortOrderRoomValue -is [int]) -or ($sortOrderRoomValue -is [long])) {
        $sortOrderRoom = [int]$sortOrderRoomValue
    }
    else {
        if ($sortOrderRoomValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($sortOrderRoomValue)) {
                throw "Cannot compress the GameData data of the RAGS file: the SortOrderRoom of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
            }
            Write-Warning "The SortOrderRoom of the file 'GameData.yaml' of the source folder is a string instead of an integer; it is parsed with the invariant culture."
            $sortOrderRoomText = $sortOrderRoomValue
        }
        else {
            Write-Warning "The SortOrderRoom of the file 'GameData.yaml' of the source folder is of type '$($sortOrderRoomValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
            if ($sortOrderRoomValue -is [System.IFormattable]) {
                $sortOrderRoomText = $sortOrderRoomValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $sortOrderRoomText = [string]$sortOrderRoomValue
            }
        }

        $parsedSortOrderRoom = 0
        if (-not [int]::TryParse($sortOrderRoomText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSortOrderRoom)) {
            throw "Cannot compress the GameData data of the RAGS file: the SortOrderRoom of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
        }
        $sortOrderRoom = $parsedSortOrderRoom
    }

    $sortOrderCharactersValue = $rootDocument['SortOrderCharacters']
    $sortOrderCharacters = 0
    if ($null -eq $sortOrderCharactersValue) {
        Write-Warning "The SortOrderCharacters of the file 'GameData.yaml' of the source folder is missing or null; it is stored as the 0 the not-null table column documents as its default value."
    }
    elseif (($sortOrderCharactersValue -is [int]) -or ($sortOrderCharactersValue -is [long])) {
        $sortOrderCharacters = [int]$sortOrderCharactersValue
    }
    else {
        if ($sortOrderCharactersValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($sortOrderCharactersValue)) {
                throw "Cannot compress the GameData data of the RAGS file: the SortOrderCharacters of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
            }
            Write-Warning "The SortOrderCharacters of the file 'GameData.yaml' of the source folder is a string instead of an integer; it is parsed with the invariant culture."
            $sortOrderCharactersText = $sortOrderCharactersValue
        }
        else {
            Write-Warning "The SortOrderCharacters of the file 'GameData.yaml' of the source folder is of type '$($sortOrderCharactersValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
            if ($sortOrderCharactersValue -is [System.IFormattable]) {
                $sortOrderCharactersText = $sortOrderCharactersValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $sortOrderCharactersText = [string]$sortOrderCharactersValue
            }
        }

        $parsedSortOrderCharacters = 0
        if (-not [int]::TryParse($sortOrderCharactersText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSortOrderCharacters)) {
            throw "Cannot compress the GameData data of the RAGS file: the SortOrderCharacters of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
        }
        $sortOrderCharacters = $parsedSortOrderCharacters
    }

    $sortOrderInventoryValue = $rootDocument['SortOrderInventory']
    $sortOrderInventory = 0
    if ($null -eq $sortOrderInventoryValue) {
        Write-Warning "The SortOrderInventory of the file 'GameData.yaml' of the source folder is missing or null; it is stored as the 0 the not-null table column documents as its default value."
    }
    elseif (($sortOrderInventoryValue -is [int]) -or ($sortOrderInventoryValue -is [long])) {
        $sortOrderInventory = [int]$sortOrderInventoryValue
    }
    else {
        if ($sortOrderInventoryValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($sortOrderInventoryValue)) {
                throw "Cannot compress the GameData data of the RAGS file: the SortOrderInventory of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
            }
            Write-Warning "The SortOrderInventory of the file 'GameData.yaml' of the source folder is a string instead of an integer; it is parsed with the invariant culture."
            $sortOrderInventoryText = $sortOrderInventoryValue
        }
        else {
            Write-Warning "The SortOrderInventory of the file 'GameData.yaml' of the source folder is of type '$($sortOrderInventoryValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
            if ($sortOrderInventoryValue -is [System.IFormattable]) {
                $sortOrderInventoryText = $sortOrderInventoryValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $sortOrderInventoryText = [string]$sortOrderInventoryValue
            }
        }

        $parsedSortOrderInventory = 0
        if (-not [int]::TryParse($sortOrderInventoryText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSortOrderInventory)) {
            throw "Cannot compress the GameData data of the RAGS file: the SortOrderInventory of the file 'GameData.yaml' of the source folder is a scalar which cannot be parsed as an integer."
        }
        $sortOrderInventory = $parsedSortOrderInventory
    }

    # The validated column values are staged before anything is appended,
    # so that the file is fully validated before any SQL runs (all-or-
    # nothing, like every file of the expansion). The GameData table
    # expands to exactly one row per source file.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $stagedRows.Add([pscustomobject]@{
        Title               = $title
        OpeningMessage      = $openingMessage
        HideMainPicDisplay  = $hideMainPicDisplay
        UseInlineImages     = $useInlineImages
        HidePortrait        = $hidePortrait
        AuthorName          = $authorName
        GameVersion         = $gameVersion
        GameInformation     = $gameInformation
        bgMusic             = $bgMusic
        RepeatbgMusic       = $repeatbgMusic
        PasswordProtected   = $passwordProtected
        GamePassword        = $gamePassword
        ObjectVersionNumber = $objectVersionNumber
        GameFont            = $gameFont
        RoomGroups          = $roomGroups
        ClothingZoneLevels  = $clothingZoneLevels
        NotificationsOff    = $notificationsOff
        SortOrderRoom       = $sortOrderRoom
        SortOrderCharacters = $sortOrderCharacters
        SortOrderInventory  = $sortOrderInventory
    })

    # Append the staged row to the GameData table inside one transaction,
    # so that a failed INSERT leaves no partially appended data behind.
    # The values are bound through provider parameters throughout, as the
    # text values are not SQL literals (and long values are far beyond
    # any quoting limit).
    $transaction = $null
    try {
        $transaction = $RagsConnection.BeginTransaction()

        Write-Verbose "Appending the GameData row to the GameData table."

        $command = $RagsConnection.CreateCommand()
        try {
            $command.Transaction = $transaction
            $command.CommandText = 'INSERT INTO [GameData] ([Title], [OpeningMessage], [HideMainPicDisplay], [UseInlineImages], [HidePortrait], [AuthorName], [GameVersion], [GameInformation], [bgMusic], [RepeatbgMusic], [PasswordProtected], [GamePassword], [ObjectVersionNumber], [GameFont], [RoomGroups], [ClothingZoneLevels], [NotificationsOff], [SortOrderRoom], [SortOrderCharacters], [SortOrderInventory]) VALUES (@title, @openingmessage, @hidemainpicdisplay, @useinlineimages, @hideportrait, @authorname, @gameversion, @gameinformation, @bgmusic, @repeatbgmusic, @passwordprotected, @gamepassword, @objectversionnumber, @gamefont, @roomgroups, @clothingzonelevels, @notificationsoff, @sortorderroom, @sortordercharacters, @sortorderinventory)'

            $titleParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@title', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $title) {
                # A parameter value of $null means 'not supplied', so a
                # null column value is bound as a database null.
                $titleParameter.Value = [System.DBNull]::Value
            }
            else {
                $titleParameter.Value = $title
            }
            $null = $command.Parameters.Add($titleParameter)

            $openingMessageParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@openingmessage', [System.Data.SqlDbType]::NText)
            if ($null -eq $openingMessage) {
                $openingMessageParameter.Value = [System.DBNull]::Value
            }
            else {
                $openingMessageParameter.Value = $openingMessage
            }
            $null = $command.Parameters.Add($openingMessageParameter)

            # A bit parameter requires a boolean value no matter what the
            # column carried in the YAML file, so every bit value is bound
            # as the boolean it normalized to.
            $hideMainPicDisplayParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@hidemainpicdisplay', [System.Data.SqlDbType]::Bit)
            $hideMainPicDisplayParameter.Value = $hideMainPicDisplay
            $null = $command.Parameters.Add($hideMainPicDisplayParameter)

            $useInlineImagesParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@useinlineimages', [System.Data.SqlDbType]::Bit)
            $useInlineImagesParameter.Value = $useInlineImages
            $null = $command.Parameters.Add($useInlineImagesParameter)

            $hidePortraitParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@hideportrait', [System.Data.SqlDbType]::Bit)
            $hidePortraitParameter.Value = $hidePortrait
            $null = $command.Parameters.Add($hidePortraitParameter)

            $authorNameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@authorname', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $authorName) {
                $authorNameParameter.Value = [System.DBNull]::Value
            }
            else {
                $authorNameParameter.Value = $authorName
            }
            $null = $command.Parameters.Add($authorNameParameter)

            $gameVersionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@gameversion', [System.Data.SqlDbType]::NVarChar, 50)
            if ($null -eq $gameVersion) {
                $gameVersionParameter.Value = [System.DBNull]::Value
            }
            else {
                $gameVersionParameter.Value = $gameVersion
            }
            $null = $command.Parameters.Add($gameVersionParameter)

            $gameInformationParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@gameinformation', [System.Data.SqlDbType]::NText)
            if ($null -eq $gameInformation) {
                $gameInformationParameter.Value = [System.DBNull]::Value
            }
            else {
                $gameInformationParameter.Value = $gameInformation
            }
            $null = $command.Parameters.Add($gameInformationParameter)

            $bgMusicParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@bgmusic', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $bgMusic) {
                $bgMusicParameter.Value = [System.DBNull]::Value
            }
            else {
                $bgMusicParameter.Value = $bgMusic
            }
            $null = $command.Parameters.Add($bgMusicParameter)

            $repeatbgMusicParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@repeatbgmusic', [System.Data.SqlDbType]::Bit)
            $repeatbgMusicParameter.Value = $repeatbgMusic
            $null = $command.Parameters.Add($repeatbgMusicParameter)

            $passwordProtectedParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@passwordprotected', [System.Data.SqlDbType]::Bit)
            $passwordProtectedParameter.Value = $passwordProtected
            $null = $command.Parameters.Add($passwordProtectedParameter)

            $gamePasswordParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@gamepassword', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $gamePassword) {
                $gamePasswordParameter.Value = [System.DBNull]::Value
            }
            else {
                $gamePasswordParameter.Value = $gamePassword
            }
            $null = $command.Parameters.Add($gamePasswordParameter)

            $objectVersionNumberParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@objectversionnumber', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $objectVersionNumber) {
                $objectVersionNumberParameter.Value = [System.DBNull]::Value
            }
            else {
                $objectVersionNumberParameter.Value = $objectVersionNumber
            }
            $null = $command.Parameters.Add($objectVersionNumberParameter)

            $gameFontParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@gamefont', [System.Data.SqlDbType]::NVarChar, 250)
            if ($null -eq $gameFont) {
                $gameFontParameter.Value = [System.DBNull]::Value
            }
            else {
                $gameFontParameter.Value = $gameFont
            }
            $null = $command.Parameters.Add($gameFontParameter)

            $roomGroupsParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@roomgroups', [System.Data.SqlDbType]::NText)
            if ($null -eq $roomGroups) {
                $roomGroupsParameter.Value = [System.DBNull]::Value
            }
            else {
                $roomGroupsParameter.Value = $roomGroups
            }
            $null = $command.Parameters.Add($roomGroupsParameter)

            $clothingZoneLevelsParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@clothingzonelevels', [System.Data.SqlDbType]::NText)
            if ($null -eq $clothingZoneLevels) {
                $clothingZoneLevelsParameter.Value = [System.DBNull]::Value
            }
            else {
                $clothingZoneLevelsParameter.Value = $clothingZoneLevels
            }
            $null = $command.Parameters.Add($clothingZoneLevelsParameter)

            # NotificationsOff and the three sort-order columns are not
            # null in the database; a null would mean 'not supplied' to
            # SQL CE and fail the INSERT, so the normalized values are
            # bound (the documented defaults of false and 0).
            $notificationsOffParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@notificationsoff', [System.Data.SqlDbType]::Bit)
            $notificationsOffParameter.Value = $notificationsOff
            $null = $command.Parameters.Add($notificationsOffParameter)

            $sortOrderRoomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@sortorderroom', [System.Data.SqlDbType]::Int)
            $sortOrderRoomParameter.Value = $sortOrderRoom
            $null = $command.Parameters.Add($sortOrderRoomParameter)

            $sortOrderCharactersParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@sortordercharacters', [System.Data.SqlDbType]::Int)
            $sortOrderCharactersParameter.Value = $sortOrderCharacters
            $null = $command.Parameters.Add($sortOrderCharactersParameter)

            $sortOrderInventoryParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@sortorderinventory', [System.Data.SqlDbType]::Int)
            $sortOrderInventoryParameter.Value = $sortOrderInventory
            $null = $command.Parameters.Add($sortOrderInventoryParameter)

            $null = $command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }

        $transaction.Commit()
        Write-Verbose 'Appended 1 row(s) to the GameData table.'
    }
    catch {
        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            }
            catch {
                Write-Warning "The GameData transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
            }
        }

        $message = "Cannot compress the GameData data of the RAGS file: the staged row could not be appended to the GameData table. "
        $message += "The database reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }
    finally {
        if ($null -ne $transaction) {
            $transaction.Dispose()
        }
    }

    Write-Verbose 'Compressed the GameData data of the RAGS file: 1 row(s) appended.'
    return $true
}

