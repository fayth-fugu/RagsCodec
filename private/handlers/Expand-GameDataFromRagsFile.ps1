#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-GameDataFromRagsFile {
    <#
    .SYNOPSIS
    Expands GameData data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the GameData table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data
    into the single 'GameData.yaml' file in the output folder, following
    the conventions documented in docs/data-mapping.md.

    The written YAML file holds a bare top-level mapping with one key per
    column of the GameData table, in the column order of the schema. The
    six bit columns are emitted as YAML booleans, the three sort-order
    columns as YAML integers and every other column as a YAML string —
    the four ntext columns as multi-line literal block scalars. YAML
    normalizes a literal block's line breaks to line feeds when the
    written YAML is read back, so a read-back value carries the line-feed
    form of whatever line breaks the table stores; the values themselves
    are emitted verbatim. Every null column value is emitted as a YAML
    null, except the null values of the string columns (Title,
    OpeningMessage, AuthorName, GameVersion, GameInformation, bgMusic,
    GamePassword, ObjectVersionNumber, GameFont, RoomGroups and
    ClothingZoneLevels), which are emitted as the empty string.

    The GameData table is documented to hold a single row; rows after
    the first are ignored, one warning each, which names the row's
    position in the read result ('the GameData row N of the read
    result') and its column values as stored — a bit column storing
    a null is reported with the false it was read as, a null string
    column value with '<null>' — as documented for the 'GameData' table
    in docs/data-mapping.md: 'A warning containing the values of
    subsequent ignored duplicate rows will be shown'. The column values
    of the first read row win. The table has no identity
    column and no documented sort ('SortOrderRoom', 'SortOrderCharacters'
    and 'SortOrderInventory' are plain int columns, not ordering
    directives), so the expanded row is always the first row of the
    unsorted read result.

    When the table is empty altogether (e.g. in a formatted RAGS file),
    the file is still written, with every string column key holding the
    empty string and every integer and bit column key holding a YAML
    null (the bit columns are then not mapped to booleans, since there
    is no row whose values could be read).

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one.

    .PARAMETER OutputPath
    Path of the folder to export the expanded GameData data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the GameData data has been
    expanded successfully.

    .EXAMPLE
    Expand-GameDataFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the GameData data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\GameData.yaml' file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot expand the GameData data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the GameData data into '$OutputPath'."

    # Read all rows of the table. The GameData table has no List, Unique
    # or Exclude column and no documented sort, so all columns are read
    # unsorted and the row order is the database return order.
    Write-Verbose 'Reading the GameData rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [Title], [OpeningMessage], [HideMainPicDisplay], [UseInlineImages], [HidePortrait], [AuthorName], [GameVersion], [GameInformation], [bgMusic], [RepeatbgMusic], [PasswordProtected], [GamePassword], [ObjectVersionNumber], [GameFont], [RoomGroups], [ClothingZoneLevels], [NotificationsOff], [SortOrderRoom], [SortOrderCharacters], [SortOrderInventory] FROM [GameData]')
    Write-Verbose "Read $($rows.Count) GameData row(s)."

    # The first returned row is the expanded one (a well-formed RAGS file
    # holds exactly one GameData row). Every row after the first is
    # ignored with one warning each, which names the row's position in
    # the read result and its column values, as documented for the
    # 'GameData' table in docs/data-mapping.md. When no row is returned
    # the mapping is expanded with all column keys as YAML nulls instead.
    $row = $null
    if ($rows.Count -gt 0) {
        $row = $rows[0]
    }

    # The GameData table has no identity column which could label the
    # rows of an ignored-row warning, so such warnings refer to the
    # position of the row in the read result instead.
    $readRowNumber = 0
    foreach ($ignoredRow in $rows) {
        $readRowNumber++
        if ($readRowNumber -eq 1) {
            continue
        }

        # Every value is computed before the warning below so that it
        # never reads a value of a previous iteration. Text columns are
        # cited quoted; a null is cited as '<null>'. The four ntext
        # values are cited as read (verbatim, original line breaks
        # included). The managed reader returns bit columns as
        # Boolean values; a missing value is read as the documented
        # false, whose value the warning below accordingly cites 'after
        # reading': a row storing a null is reported with the false it
        # was read as, never with the null it holds.
        $ignoredTitle = $ignoredRow['Title']
        if (($null -eq $ignoredTitle) -or ($ignoredTitle -is [System.DBNull])) {
            $ignoredTitle = $null
        }
        else {
            $ignoredTitle = [string]$ignoredTitle
        }

        $ignoredAuthorName = $ignoredRow['AuthorName']
        if (($null -eq $ignoredAuthorName) -or ($ignoredAuthorName -is [System.DBNull])) {
            $ignoredAuthorName = $null
        }
        else {
            $ignoredAuthorName = [string]$ignoredAuthorName
        }

        $ignoredGameVersion = $ignoredRow['GameVersion']
        if (($null -eq $ignoredGameVersion) -or ($ignoredGameVersion -is [System.DBNull])) {
            $ignoredGameVersion = $null
        }
        else {
            $ignoredGameVersion = [string]$ignoredGameVersion
        }

        $ignoredBgMusic = $ignoredRow['bgMusic']
        if (($null -eq $ignoredBgMusic) -or ($ignoredBgMusic -is [System.DBNull])) {
            $ignoredBgMusic = $null
        }
        else {
            $ignoredBgMusic = [string]$ignoredBgMusic
        }

        $ignoredGamePassword = $ignoredRow['GamePassword']
        if (($null -eq $ignoredGamePassword) -or ($ignoredGamePassword -is [System.DBNull])) {
            $ignoredGamePassword = $null
        }
        else {
            $ignoredGamePassword = [string]$ignoredGamePassword
        }

        $ignoredObjectVersionNumber = $ignoredRow['ObjectVersionNumber']
        if (($null -eq $ignoredObjectVersionNumber) -or ($ignoredObjectVersionNumber -is [System.DBNull])) {
            $ignoredObjectVersionNumber = $null
        }
        else {
            $ignoredObjectVersionNumber = [string]$ignoredObjectVersionNumber
        }

        $ignoredGameFont = $ignoredRow['GameFont']
        if (($null -eq $ignoredGameFont) -or ($ignoredGameFont -is [System.DBNull])) {
            $ignoredGameFont = $null
        }
        else {
            $ignoredGameFont = [string]$ignoredGameFont
        }

        # The ntext columns are cited as read (verbatim, original line
        # breaks included).
        $ignoredOpeningMessage = $ignoredRow['OpeningMessage']
        if (($null -eq $ignoredOpeningMessage) -or ($ignoredOpeningMessage -is [System.DBNull])) {
            $ignoredOpeningMessage = $null
        }
        else {
            $ignoredOpeningMessage = [string]$ignoredOpeningMessage
        }

        $ignoredGameInformation = $ignoredRow['GameInformation']
        if (($null -eq $ignoredGameInformation) -or ($ignoredGameInformation -is [System.DBNull])) {
            $ignoredGameInformation = $null
        }
        else {
            $ignoredGameInformation = [string]$ignoredGameInformation
        }

        $ignoredRoomGroups = $ignoredRow['RoomGroups']
        if (($null -eq $ignoredRoomGroups) -or ($ignoredRoomGroups -is [System.DBNull])) {
            $ignoredRoomGroups = $null
        }
        else {
            $ignoredRoomGroups = [string]$ignoredRoomGroups
        }

        $ignoredClothingZoneLevels = $ignoredRow['ClothingZoneLevels']
        if (($null -eq $ignoredClothingZoneLevels) -or ($ignoredClothingZoneLevels -is [System.DBNull])) {
            $ignoredClothingZoneLevels = $null
        }
        else {
            $ignoredClothingZoneLevels = [string]$ignoredClothingZoneLevels
        }

        $ignoredHideMainPicDisplay = $ignoredRow['HideMainPicDisplay']
        if (($null -eq $ignoredHideMainPicDisplay) -or ($ignoredHideMainPicDisplay -is [System.DBNull])) {
            $ignoredHideMainPicDisplay = $false
        }

        $ignoredUseInlineImages = $ignoredRow['UseInlineImages']
        if (($null -eq $ignoredUseInlineImages) -or ($ignoredUseInlineImages -is [System.DBNull])) {
            $ignoredUseInlineImages = $false
        }

        $ignoredHidePortrait = $ignoredRow['HidePortrait']
        if (($null -eq $ignoredHidePortrait) -or ($ignoredHidePortrait -is [System.DBNull])) {
            $ignoredHidePortrait = $false
        }

        $ignoredRepeatbgMusic = $ignoredRow['RepeatbgMusic']
        if (($null -eq $ignoredRepeatbgMusic) -or ($ignoredRepeatbgMusic -is [System.DBNull])) {
            $ignoredRepeatbgMusic = $false
        }

        $ignoredPasswordProtected = $ignoredRow['PasswordProtected']
        if (($null -eq $ignoredPasswordProtected) -or ($ignoredPasswordProtected -is [System.DBNull])) {
            $ignoredPasswordProtected = $false
        }

        $ignoredNotificationsOff = $ignoredRow['NotificationsOff']
        if (($null -eq $ignoredNotificationsOff) -or ($ignoredNotificationsOff -is [System.DBNull])) {
            $ignoredNotificationsOff = $false
        }

        $ignoredSortOrderRoom = $ignoredRow['SortOrderRoom']
        if (($null -eq $ignoredSortOrderRoom) -or ($ignoredSortOrderRoom -is [System.DBNull])) {
            $ignoredSortOrderRoom = $null
        }

        $ignoredSortOrderCharacters = $ignoredRow['SortOrderCharacters']
        if (($null -eq $ignoredSortOrderCharacters) -or ($ignoredSortOrderCharacters -is [System.DBNull])) {
            $ignoredSortOrderCharacters = $null
        }

        $ignoredSortOrderInventory = $ignoredRow['SortOrderInventory']
        if (($null -eq $ignoredSortOrderInventory) -or ($ignoredSortOrderInventory -is [System.DBNull])) {
            $ignoredSortOrderInventory = $null
        }

        # The warning cites every column value of the ignored row in the
        # schema column order (the order of the written mapping keys).
        $evidenceParts = [System.Collections.Generic.List[string]]::new()
        if ($null -eq $ignoredTitle) { $evidenceParts.Add('Title <null>') } else { $evidenceParts.Add('Title ''' + $ignoredTitle + '''') }
        if ($null -eq $ignoredOpeningMessage) { $evidenceParts.Add('OpeningMessage <null>') } else { $evidenceParts.Add('OpeningMessage ' + $ignoredOpeningMessage) }
        $evidenceParts.Add('HideMainPicDisplay equals ' + $ignoredHideMainPicDisplay + ' after reading')
        $evidenceParts.Add('UseInlineImages equals ' + $ignoredUseInlineImages + ' after reading')
        $evidenceParts.Add('HidePortrait equals ' + $ignoredHidePortrait + ' after reading')
        if ($null -eq $ignoredAuthorName) { $evidenceParts.Add('AuthorName <null>') } else { $evidenceParts.Add('AuthorName ''' + $ignoredAuthorName + '''') }
        if ($null -eq $ignoredGameVersion) { $evidenceParts.Add('GameVersion <null>') } else { $evidenceParts.Add('GameVersion ''' + $ignoredGameVersion + '''') }
        if ($null -eq $ignoredGameInformation) { $evidenceParts.Add('GameInformation <null>') } else { $evidenceParts.Add('GameInformation ' + $ignoredGameInformation) }
        if ($null -eq $ignoredBgMusic) { $evidenceParts.Add('bgMusic <null>') } else { $evidenceParts.Add('bgMusic ''' + $ignoredBgMusic + '''') }
        $evidenceParts.Add('RepeatbgMusic equals ' + $ignoredRepeatbgMusic + ' after reading')
        $evidenceParts.Add('PasswordProtected equals ' + $ignoredPasswordProtected + ' after reading')
        if ($null -eq $ignoredGamePassword) { $evidenceParts.Add('GamePassword <null>') } else { $evidenceParts.Add('GamePassword ''' + $ignoredGamePassword + '''') }
        if ($null -eq $ignoredObjectVersionNumber) { $evidenceParts.Add('ObjectVersionNumber <null>') } else { $evidenceParts.Add('ObjectVersionNumber ''' + $ignoredObjectVersionNumber + '''') }
        if ($null -eq $ignoredGameFont) { $evidenceParts.Add('GameFont <null>') } else { $evidenceParts.Add('GameFont ''' + $ignoredGameFont + '''') }
        if ($null -eq $ignoredRoomGroups) { $evidenceParts.Add('RoomGroups <null>') } else { $evidenceParts.Add('RoomGroups ' + $ignoredRoomGroups) }
        if ($null -eq $ignoredClothingZoneLevels) { $evidenceParts.Add('ClothingZoneLevels <null>') } else { $evidenceParts.Add('ClothingZoneLevels ' + $ignoredClothingZoneLevels) }
        $evidenceParts.Add('NotificationsOff equals ' + $ignoredNotificationsOff + ' after reading')
        if ($null -eq $ignoredSortOrderRoom) { $evidenceParts.Add('SortOrderRoom <null>') } else { $evidenceParts.Add('SortOrderRoom ' + $ignoredSortOrderRoom) }
        if ($null -eq $ignoredSortOrderCharacters) { $evidenceParts.Add('SortOrderCharacters <null>') } else { $evidenceParts.Add('SortOrderCharacters ' + $ignoredSortOrderCharacters) }
        if ($null -eq $ignoredSortOrderInventory) { $evidenceParts.Add('SortOrderInventory <null>') } else { $evidenceParts.Add('SortOrderInventory ' + $ignoredSortOrderInventory) }

        Write-Warning "Ignoring the GameData row $($readRowNumber) of the read result: the GameData table is expected to hold a single row, so only the first read row is expanded. The ignored row has the column values $($evidenceParts -join ', ')."
    }

    # Column values, computed before the mapping is built. When no row
    # was read, the string column values stage the empty string while
    # the integer and Boolean column values stay null: an empty GameData
    # table is expanded into a mapping whose string column keys hold ''
    # (whereas a read row maps its null bit columns to false, per the
    # documented reading of missing bit values).
    $title = ''
    $openingMessage = ''
    $hideMainPicDisplay = $null
    $useInlineImages = $null
    $hidePortrait = $null
    $authorName = ''
    $gameVersion = ''
    $gameInformation = ''
    $bgMusic = ''
    $repeatbgMusic = $null
    $passwordProtected = $null
    $gamePassword = ''
    $objectVersionNumber = ''
    $gameFont = ''
    $roomGroups = ''
    $clothingZoneLevels = ''
    $notificationsOff = $null
    $sortOrderRoom = $null
    $sortOrderCharacters = $null
    $sortOrderInventory = $null

    if ($null -ne $row) {
        # The nvarchar columns are emitted as YAML strings.
        $title = $row['Title']
        if (($null -eq $title) -or ($title -is [System.DBNull])) {
            $title = ''
        }
        else {
            $title = [string]$title
        }

        $authorName = $row['AuthorName']
        if (($null -eq $authorName) -or ($authorName -is [System.DBNull])) {
            $authorName = ''
        }
        else {
            $authorName = [string]$authorName
        }

        $gameVersion = $row['GameVersion']
        if (($null -eq $gameVersion) -or ($gameVersion -is [System.DBNull])) {
            $gameVersion = ''
        }
        else {
            $gameVersion = [string]$gameVersion
        }

        $bgMusic = $row['bgMusic']
        if (($null -eq $bgMusic) -or ($bgMusic -is [System.DBNull])) {
            $bgMusic = ''
        }
        else {
            $bgMusic = [string]$bgMusic
        }

        $gamePassword = $row['GamePassword']
        if (($null -eq $gamePassword) -or ($gamePassword -is [System.DBNull])) {
            $gamePassword = ''
        }
        else {
            $gamePassword = [string]$gamePassword
        }

        $objectVersionNumber = $row['ObjectVersionNumber']
        if (($null -eq $objectVersionNumber) -or ($objectVersionNumber -is [System.DBNull])) {
            $objectVersionNumber = ''
        }
        else {
            $objectVersionNumber = [string]$objectVersionNumber
        }

        $gameFont = $row['GameFont']
        if (($null -eq $gameFont) -or ($gameFont -is [System.DBNull])) {
            $gameFont = ''
        }
        else {
            $gameFont = [string]$gameFont
        }

        # The ntext columns are emitted as YAML strings, verbatim. A YAML
        # literal block scalar normalizes a written value's line breaks to
        # line feeds only when the written YAML is read back.
        $openingMessage = $row['OpeningMessage']
        if (($null -eq $openingMessage) -or ($openingMessage -is [System.DBNull])) {
            $openingMessage = ''
        }
        else {
            $openingMessage = [string]$openingMessage
        }

        $gameInformation = $row['GameInformation']
        if (($null -eq $gameInformation) -or ($gameInformation -is [System.DBNull])) {
            $gameInformation = ''
        }
        else {
            $gameInformation = [string]$gameInformation
        }

        $roomGroups = $row['RoomGroups']
        if (($null -eq $roomGroups) -or ($roomGroups -is [System.DBNull])) {
            $roomGroups = ''
        }
        else {
            $roomGroups = [string]$roomGroups
        }

        $clothingZoneLevels = $row['ClothingZoneLevels']
        if (($null -eq $clothingZoneLevels) -or ($clothingZoneLevels -is [System.DBNull])) {
            $clothingZoneLevels = ''
        }
        else {
            $clothingZoneLevels = [string]$clothingZoneLevels
        }

        # The managed reader returns bit columns as Boolean values; a
        # missing value is read as the documented false.
        $hideMainPicDisplay = $row['HideMainPicDisplay']
        if (($null -eq $hideMainPicDisplay) -or ($hideMainPicDisplay -is [System.DBNull])) {
            $hideMainPicDisplay = $false
        }

        $useInlineImages = $row['UseInlineImages']
        if (($null -eq $useInlineImages) -or ($useInlineImages -is [System.DBNull])) {
            $useInlineImages = $false
        }

        $hidePortrait = $row['HidePortrait']
        if (($null -eq $hidePortrait) -or ($hidePortrait -is [System.DBNull])) {
            $hidePortrait = $false
        }

        $repeatbgMusic = $row['RepeatbgMusic']
        if (($null -eq $repeatbgMusic) -or ($repeatbgMusic -is [System.DBNull])) {
            $repeatbgMusic = $false
        }

        $passwordProtected = $row['PasswordProtected']
        if (($null -eq $passwordProtected) -or ($passwordProtected -is [System.DBNull])) {
            $passwordProtected = $false
        }

        $notificationsOff = $row['NotificationsOff']
        if (($null -eq $notificationsOff) -or ($notificationsOff -is [System.DBNull])) {
            $notificationsOff = $false
        }

        $sortOrderRoom = $row['SortOrderRoom']
        if (($null -eq $sortOrderRoom) -or ($sortOrderRoom -is [System.DBNull])) {
            $sortOrderRoom = $null
        }

        $sortOrderCharacters = $row['SortOrderCharacters']
        if (($null -eq $sortOrderCharacters) -or ($sortOrderCharacters -is [System.DBNull])) {
            $sortOrderCharacters = $null
        }

        $sortOrderInventory = $row['SortOrderInventory']
        if (($null -eq $sortOrderInventory) -or ($sortOrderInventory -is [System.DBNull])) {
            $sortOrderInventory = $null
        }
    }

    # Bare, top-level ordered mapping: one key per GameData column, in
    # the documented sample-structure order (the column order of the
    # schema) — no envelope key wraps the mapping.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{
            Title                 = $title
            OpeningMessage        = $openingMessage
            HideMainPicDisplay    = $hideMainPicDisplay
            UseInlineImages       = $useInlineImages
            HidePortrait          = $hidePortrait
            AuthorName            = $authorName
            GameVersion           = $gameVersion
            GameInformation       = $gameInformation
            bgMusic               = $bgMusic
            RepeatbgMusic         = $repeatbgMusic
            PasswordProtected     = $passwordProtected
            GamePassword          = $gamePassword
            ObjectVersionNumber   = $objectVersionNumber
            GameFont              = $gameFont
            RoomGroups            = $roomGroups
            ClothingZoneLevels    = $clothingZoneLevels
            NotificationsOff      = $notificationsOff
            SortOrderRoom         = $sortOrderRoom
            SortOrderCharacters   = $sortOrderCharacters
            SortOrderInventory    = $sortOrderInventory
        }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the GameData data of the RAGS file: the YAML content of the GameData data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'GameData.yaml'
    Write-Verbose "Writing '$filePath'$(if ($null -eq $row) { ' from an empty GameData table (empty-string string keys and null integer and bit keys).' } else { ' from the first read row' + $(if ($rows.Count -gt 1) { " ($($rows.Count - 1) further row$(if ($rows.Count -eq 2) { '' } else { 's'}) ignored)." } else { '.' }) })."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose 'Expanded the GameData data.'
    return $true
}

