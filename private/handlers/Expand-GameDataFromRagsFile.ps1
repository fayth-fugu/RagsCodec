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
    the four ntext columns as multi-line literal block scalars whose line
    breaks were normalized to line-feed characters (YAML normalizes line
    breaks to line feeds when a literal block is read back, so carriage
    returns are normalized beforehand to keep the round-trip
    byte-exact). Every null column value is emitted as a YAML null.

    The GameData table is expected to hold a single row; rows after the
    first are ignored with a warning naming their number. When the table
    is empty altogether (e.g. in a formatted RAGS file), the file is
    still written, with every column key holding a YAML null (the bit
    columns are then not mapped to booleans, since there is no row whose
    values could be read).

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

    # Only the first returned row is expanded (a well-formed RAGS file
    # holds exactly one GameData row). When no row is returned the
    # mapping is expanded with all column keys as YAML nulls instead.
    $row = $null
    $ignoredRowCount = $rows.Count
    if ($rows.Count -gt 0) {
        $row = $rows[0]
        $ignoredRowCount = $rows.Count - 1
    }

    if ($ignoredRowCount -gt 0) {
        Write-Warning "Ignoring the remaining $($ignoredRowCount) GameData row$(if ($ignoredRowCount -eq 1) { '' } else { 's' }): the GameData table is expected to hold a single row, so only the first read row is expanded."
    }

    # Normalized column values, computed before the mapping is built. When
    # no row was read every value stays null: an empty GameData table is
    # expanded into an all-null mapping (whereas a read row maps its null
    # bit columns to false, per the documented reading of missing bit
    # values).
    $title = $null
    $openingMessage = $null
    $hideMainPicDisplay = $null
    $useInlineImages = $null
    $hidePortrait = $null
    $authorName = $null
    $gameVersion = $null
    $gameInformation = $null
    $bgMusic = $null
    $repeatbgMusic = $null
    $passwordProtected = $null
    $gamePassword = $null
    $objectVersionNumber = $null
    $gameFont = $null
    $roomGroups = $null
    $clothingZoneLevels = $null
    $notificationsOff = $null
    $sortOrderRoom = $null
    $sortOrderCharacters = $null
    $sortOrderInventory = $null

    if ($null -ne $row) {
        # The nvarchar columns are emitted as YAML strings.
        $title = $row['Title']
        if (($null -eq $title) -or ($title -is [System.DBNull])) {
            $title = $null
        }
        else {
            $title = [string]$title
        }

        $authorName = $row['AuthorName']
        if (($null -eq $authorName) -or ($authorName -is [System.DBNull])) {
            $authorName = $null
        }
        else {
            $authorName = [string]$authorName
        }

        $gameVersion = $row['GameVersion']
        if (($null -eq $gameVersion) -or ($gameVersion -is [System.DBNull])) {
            $gameVersion = $null
        }
        else {
            $gameVersion = [string]$gameVersion
        }

        $bgMusic = $row['bgMusic']
        if (($null -eq $bgMusic) -or ($bgMusic -is [System.DBNull])) {
            $bgMusic = $null
        }
        else {
            $bgMusic = [string]$bgMusic
        }

        $gamePassword = $row['GamePassword']
        if (($null -eq $gamePassword) -or ($gamePassword -is [System.DBNull])) {
            $gamePassword = $null
        }
        else {
            $gamePassword = [string]$gamePassword
        }

        $objectVersionNumber = $row['ObjectVersionNumber']
        if (($null -eq $objectVersionNumber) -or ($objectVersionNumber -is [System.DBNull])) {
            $objectVersionNumber = $null
        }
        else {
            $objectVersionNumber = [string]$objectVersionNumber
        }

        $gameFont = $row['GameFont']
        if (($null -eq $gameFont) -or ($gameFont -is [System.DBNull])) {
            $gameFont = $null
        }
        else {
            $gameFont = [string]$gameFont
        }

        # The ntext columns are emitted as YAML strings whose line breaks
        # were normalized to line feeds (both because a YAML literal block
        # scalar normalizes line breaks that way when read back and so
        # that the expansion round-trips byte-exactly).
        $openingMessage = $row['OpeningMessage']
        if (($null -eq $openingMessage) -or ($openingMessage -is [System.DBNull])) {
            $openingMessage = $null
        }
        else {
            $openingMessage = ([string]$openingMessage) -replace '\r\n?', "`n"
        }

        $gameInformation = $row['GameInformation']
        if (($null -eq $gameInformation) -or ($gameInformation -is [System.DBNull])) {
            $gameInformation = $null
        }
        else {
            $gameInformation = ([string]$gameInformation) -replace '\r\n?', "`n"
        }

        $roomGroups = $row['RoomGroups']
        if (($null -eq $roomGroups) -or ($roomGroups -is [System.DBNull])) {
            $roomGroups = $null
        }
        else {
            $roomGroups = ([string]$roomGroups) -replace '\r\n?', "`n"
        }

        $clothingZoneLevels = $row['ClothingZoneLevels']
        if (($null -eq $clothingZoneLevels) -or ($clothingZoneLevels -is [System.DBNull])) {
            $clothingZoneLevels = $null
        }
        else {
            $clothingZoneLevels = ([string]$clothingZoneLevels) -replace '\r\n?', "`n"
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
    Write-Verbose "Writing '$filePath'$(if ($null -eq $row) { ' from an empty GameData table (an all-null mapping).' } else { ' from the first read row' + $(if ($ignoredRowCount -gt 0) { " ($($ignoredRowCount) further row$(if ($ignoredRowCount -eq 1) { '' } else { 's'}) ignored)." } else { '.' }) })."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose 'Expanded the GameData data.'
    return $true
}

