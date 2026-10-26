#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-PlayerFromRagsFile {
    <#
    .SYNOPSIS
    Expands Player data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the Player table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data
    into the single 'Player.yaml' file in the output folder, following
    the conventions documented in docs/data-mapping.md.

    The written YAML file holds a bare top-level mapping with one key per
    column of the Player table, in the column order of the schema. The
    three bit columns are emitted as YAML booleans, the PlayerGender
    column as a YAML integer, the WeightLimit column as a YAML number
    and every other column as a YAML string — the Description ntext
    column as a multi-line literal block scalar. A YAML literal block
    normalizes a written value's line breaks to line feeds when the
    written YAML is read back, so a read-back value carries the
    line-feed form of whatever line breaks the table stores; the values
    themselves are emitted verbatim. Every null column value is emitted
    as a YAML null, except the null values of the string columns (Name,
    Description, StartingRoom, CurrentRoom, PlayerLayeredImage and
    PlayerPortrait), which are emitted as the empty string.

    The Player table is documented to hold a single row; 'if multiple
    rows exist, only the first row's column values will be read' and
    'A warning containing the values of subsequent ignored duplicate
    rows will be shown' (docs/data-mapping.md, Player section). Every
    row after the first is therefore ignored with one warning each,
    which names the row's position in the read result ('the Player row
    N of the read result') and its column values as stored — a bit
    column storing a null is reported with the false it was read as, a
    null string column value with '<null>' and the WeightLimit value
    with its invariant numeric form. The table has no identity column
    and no documented sort, so the expanded row is always the first row
    of the unsorted read result.

    As documented for the 'Player' table in docs/data-mapping.md, the
    values of the StartingRoom and PlayerPortrait columns 'will always
    be coerced to lowercase during expansion and compression'. The
    expanded row's two values are therefore read as lowercase, and a
    value whose stored casing differs warns once, naming the stored
    value and the lowercased form it is written to the file with. A
    null value of either column is emitted as the empty string and
    never triggers the casing warning. The ignored rows are never
    lowercased — a casing warning about values that are never written
    would be misleading — so their column values are cited with the raw
    casing the table stores.

    When the table is empty altogether (e.g. in a formatted RAGS file),
    the file is still written, with every string column key holding the
    empty string and every integer, number and bit column key holding a
    YAML null (the bit columns are then not mapped to booleans, since
    there is no row whose values could be read).

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one.

    .PARAMETER OutputPath
    Path of the folder to export the expanded Player data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Player data has been
    expanded successfully.

    .EXAMPLE
    Expand-PlayerFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the Player data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\Player.yaml' file.
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
        throw "Cannot expand the Player data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the Player data into '$OutputPath'."

    # Read all rows of the table. The Player table has no List, Unique or
    # Exclude column and no documented sort, so all columns are read
    # unsorted and the row order is the database return order.
    Write-Verbose 'Reading the Player rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [Name], [Description], [StartingRoom], [CurrentRoom], [PlayerLayeredImage], [PlayerGender], [PromptForName], [PromptForGender], [PlayerPortrait], [EnforceWeight], [WeightLimit] FROM [Player]')
    Write-Verbose "Read $($rows.Count) Player row(s)."

    # The first returned row is the expanded one (a well-formed RAGS file
    # holds exactly one Player row).
    $row = $null
    if ($rows.Count -gt 0) {
        $row = $rows[0]
    }

    # Column values, computed in the schema column order and before the
    # ignored-row warnings below, so those warnings follow the casing
    # warnings of the expanded row (whose values are written to the file)
    # in the same warning stream. When no row was read, the string
    # column values stage the empty string while the integer, number and
    # Boolean column values stay null: an empty Player table is expanded
    # into a mapping whose string column keys hold '' (whereas a read
    # row maps its null bit columns to false, per the documented reading
    # of missing bit values).
    $name = ''
    $description = ''
    $startingRoom = ''
    $currentRoom = ''
    $playerLayeredImage = ''
    $playerGender = $null
    $promptForName = $null
    $promptForGender = $null
    $playerPortrait = ''
    $enforceWeight = $null
    $weightLimit = $null

    if ($null -ne $row) {
        # The nvarchar columns are emitted as YAML strings.
        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull])) {
            $name = ''
        }
        else {
            $name = [string]$name
        }

        # The Description ntext column is emitted as a YAML string,
        # verbatim. A YAML literal block scalar normalizes a written
        # value's line breaks to line feeds only when the written YAML
        # is read back.
        $description = $row['Description']
        if (($null -eq $description) -or ($description -is [System.DBNull])) {
            $description = ''
        }
        else {
            $description = [string]$description
        }

        # The StartingRoom value is always coerced to lowercase during
        # expansion, as documented for the 'Player' table in
        # docs/data-mapping.md ('values of these columns will always be
        # coerced to lowercase during expansion and compression'). A
        # stored value whose casing differs warns once; the warning
        # cites the raw stored value and the lowercased form. A null
        # value is emitted as the empty string and never triggers the
        # casing warning.
        $startingRoom = $row['StartingRoom']
        if (($null -eq $startingRoom) -or ($startingRoom -is [System.DBNull])) {
            $startingRoom = ''
        }
        else {
            $startingRoomRaw = [string]$startingRoom
            $startingRoom = $startingRoomRaw.ToLowerInvariant()
            if (-not [string]::Equals($startingRoom, $startingRoomRaw, [System.StringComparison]::Ordinal)) {
                Write-Warning "The StartingRoom value '$startingRoomRaw' of the Player row 1 of the read result is coerced to its lowercase form '$startingRoom' during expansion."
            }
        }

        $currentRoom = $row['CurrentRoom']
        if (($null -eq $currentRoom) -or ($currentRoom -is [System.DBNull])) {
            $currentRoom = ''
        }
        else {
            $currentRoom = [string]$currentRoom
        }

        $playerLayeredImage = $row['PlayerLayeredImage']
        if (($null -eq $playerLayeredImage) -or ($playerLayeredImage -is [System.DBNull])) {
            $playerLayeredImage = ''
        }
        else {
            $playerLayeredImage = [string]$playerLayeredImage
        }

        # The PlayerGender column is emitted as a YAML integer; every
        # null value is emitted as a YAML null.
        $playerGender = $row['PlayerGender']
        if (($null -eq $playerGender) -or ($playerGender -is [System.DBNull])) {
            $playerGender = $null
        }

        # The managed reader returns the bit columns as Boolean values;
        # a missing value is read as the documented false.
        $promptForName = $row['PromptForName']
        if (($null -eq $promptForName) -or ($promptForName -is [System.DBNull])) {
            $promptForName = $false
        }

        $promptForGender = $row['PromptForGender']
        if (($null -eq $promptForGender) -or ($promptForGender -is [System.DBNull])) {
            $promptForGender = $false
        }

        # The PlayerPortrait value is always coerced to lowercase during
        # expansion, as documented for the 'Player' table in
        # docs/data-mapping.md ('values of these columns will always be
        # coerced to lowercase during expansion and compression'). A
        # stored value whose casing differs warns once; the warning
        # cites the raw stored value and the lowercased form. A null
        # value is emitted as the empty string and never triggers the
        # casing warning.
        $playerPortrait = $row['PlayerPortrait']
        if (($null -eq $playerPortrait) -or ($playerPortrait -is [System.DBNull])) {
            $playerPortrait = ''
        }
        else {
            $playerPortraitRaw = [string]$playerPortrait
            $playerPortrait = $playerPortraitRaw.ToLowerInvariant()
            if (-not [string]::Equals($playerPortrait, $playerPortraitRaw, [System.StringComparison]::Ordinal)) {
                Write-Warning "The PlayerPortrait value '$playerPortraitRaw' of the Player row 1 of the read result is coerced to its lowercase form '$playerPortrait' during expansion."
            }
        }

        $enforceWeight = $row['EnforceWeight']
        if (($null -eq $enforceWeight) -or ($enforceWeight -is [System.DBNull])) {
            $enforceWeight = $false
        }

        # The WeightLimit column is emitted as a YAML number; every null
        # value is emitted as a YAML null.
        $weightLimit = $row['WeightLimit']
        if (($null -eq $weightLimit) -or ($weightLimit -is [System.DBNull])) {
            $weightLimit = $null
        }
        else {
            $weightLimit = [double]$weightLimit
        }
    }

    # Every row after the first is ignored, one warning each, which
    # names the row's position in the read result and its column values,
    # as documented for the 'Player' table in docs/data-mapping.md
    # ('A warning containing the values of subsequent ignored duplicate
    # rows will be shown'). The Player table has no identity column
    # which could label these rows, so such warnings refer to the
    # position of the row in the read result instead.
    $readRowNumber = 0
    foreach ($ignoredRow in $rows) {
        $readRowNumber++
        if ($readRowNumber -eq 1) {
            continue
        }

        # Every value is computed before the warning below so that it
        # never reads a value of a previous iteration. The ignored rows
        # are cited with the raw casing the table stores (never
        # lowercased), and in the schema column order (the order of the
        # written mapping keys): text columns quoted, the ntext column
        # unquoted, a null cited as '<null>'.
        $ignoredName = $ignoredRow['Name']
        if (($null -eq $ignoredName) -or ($ignoredName -is [System.DBNull])) {
            $ignoredName = $null
        }
        else {
            $ignoredName = [string]$ignoredName
        }

        $ignoredDescription = $ignoredRow['Description']
        if (($null -eq $ignoredDescription) -or ($ignoredDescription -is [System.DBNull])) {
            $ignoredDescription = $null
        }
        else {
            $ignoredDescription = [string]$ignoredDescription
        }

        $ignoredStartingRoom = $ignoredRow['StartingRoom']
        if (($null -eq $ignoredStartingRoom) -or ($ignoredStartingRoom -is [System.DBNull])) {
            $ignoredStartingRoom = $null
        }
        else {
            $ignoredStartingRoom = [string]$ignoredStartingRoom
        }

        $ignoredCurrentRoom = $ignoredRow['CurrentRoom']
        if (($null -eq $ignoredCurrentRoom) -or ($ignoredCurrentRoom -is [System.DBNull])) {
            $ignoredCurrentRoom = $null
        }
        else {
            $ignoredCurrentRoom = [string]$ignoredCurrentRoom
        }

        $ignoredPlayerLayeredImage = $ignoredRow['PlayerLayeredImage']
        if (($null -eq $ignoredPlayerLayeredImage) -or ($ignoredPlayerLayeredImage -is [System.DBNull])) {
            $ignoredPlayerLayeredImage = $null
        }
        else {
            $ignoredPlayerLayeredImage = [string]$ignoredPlayerLayeredImage
        }

        $ignoredPlayerGender = $ignoredRow['PlayerGender']
        if (($null -eq $ignoredPlayerGender) -or ($ignoredPlayerGender -is [System.DBNull])) {
            $ignoredPlayerGender = $null
        }

        $ignoredPromptForName = $ignoredRow['PromptForName']
        if (($null -eq $ignoredPromptForName) -or ($ignoredPromptForName -is [System.DBNull])) {
            $ignoredPromptForName = $false
        }

        $ignoredPromptForGender = $ignoredRow['PromptForGender']
        if (($null -eq $ignoredPromptForGender) -or ($ignoredPromptForGender -is [System.DBNull])) {
            $ignoredPromptForGender = $false
        }

        $ignoredPlayerPortrait = $ignoredRow['PlayerPortrait']
        if (($null -eq $ignoredPlayerPortrait) -or ($ignoredPlayerPortrait -is [System.DBNull])) {
            $ignoredPlayerPortrait = $null
        }
        else {
            $ignoredPlayerPortrait = [string]$ignoredPlayerPortrait
        }

        $ignoredEnforceWeight = $ignoredRow['EnforceWeight']
        if (($null -eq $ignoredEnforceWeight) -or ($ignoredEnforceWeight -is [System.DBNull])) {
            $ignoredEnforceWeight = $false
        }

        $ignoredWeightLimitText = $null
        $ignoredWeightLimit = $ignoredRow['WeightLimit']
        if (($null -eq $ignoredWeightLimit) -or ($ignoredWeightLimit -is [System.DBNull])) {
            $ignoredWeightLimit = $null
        }
        else {
            $ignoredWeightLimit = [double]$ignoredWeightLimit
            $ignoredWeightLimitText = $ignoredWeightLimit.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }

        # The bit columns are cited as read: the managed reader returns
        # them as Boolean values, a missing value is read as the
        # documented false, whose value the warning below accordingly
        # cites 'after reading' — a row storing a null is reported with
        # the false it was read as, never with the null it holds.
        $evidenceParts = [System.Collections.Generic.List[string]]::new()
        if ($null -eq $ignoredName) { $evidenceParts.Add('Name <null>') } else { $evidenceParts.Add('Name ''' + $ignoredName + '''') }
        if ($null -eq $ignoredDescription) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $ignoredDescription) }
        if ($null -eq $ignoredStartingRoom) { $evidenceParts.Add('StartingRoom <null>') } else { $evidenceParts.Add('StartingRoom ''' + $ignoredStartingRoom + '''') }
        if ($null -eq $ignoredCurrentRoom) { $evidenceParts.Add('CurrentRoom <null>') } else { $evidenceParts.Add('CurrentRoom ''' + $ignoredCurrentRoom + '''') }
        if ($null -eq $ignoredPlayerLayeredImage) { $evidenceParts.Add('PlayerLayeredImage <null>') } else { $evidenceParts.Add('PlayerLayeredImage ''' + $ignoredPlayerLayeredImage + '''') }
        if ($null -eq $ignoredPlayerGender) { $evidenceParts.Add('PlayerGender <null>') } else { $evidenceParts.Add('PlayerGender ' + $ignoredPlayerGender) }
        $evidenceParts.Add('PromptForName equals ' + $ignoredPromptForName + ' after reading')
        $evidenceParts.Add('PromptForGender equals ' + $ignoredPromptForGender + ' after reading')
        if ($null -eq $ignoredPlayerPortrait) { $evidenceParts.Add('PlayerPortrait <null>') } else { $evidenceParts.Add('PlayerPortrait ''' + $ignoredPlayerPortrait + '''') }
        $evidenceParts.Add('EnforceWeight equals ' + $ignoredEnforceWeight + ' after reading')
        if ($null -eq $ignoredWeightLimitText) { $evidenceParts.Add('WeightLimit <null>') } else { $evidenceParts.Add('WeightLimit ' + $ignoredWeightLimitText) }

        Write-Warning "Ignoring the Player row $($readRowNumber) of the read result: the Player table is expected to hold a single row, so only the first read row is expanded. The ignored row has the column values $($evidenceParts -join ', ')."
    }

    # Bare, top-level ordered mapping: one key per Player column, in
    # the documented sample-structure order (the column order of the
    # schema) — no envelope key wraps the mapping.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{
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
        }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the Player data of the RAGS file: the YAML content of the Player data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'Player.yaml'
    $ignoredRowCount = $rows.Count - 1
    if ($null -eq $row) {
        Write-Verbose "Writing '$filePath' from an empty Player table (empty-string string keys; null integer, number and bit keys)."
    }
    else {
        Write-Verbose "Writing '$filePath' from the first read row ($($ignoredRowCount) further row(s) ignored)."
    }
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose 'Expanded the Player data.'
    return $true
}

