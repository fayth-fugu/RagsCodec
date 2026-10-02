#Requires -Version 5.1
Set-StrictMode -Version Latest

function Assert-RagsFileStructure {
    <#
    .SYNOPSIS
    Validates the database structure of an opened RAGS file connection.

    .DESCRIPTION
    Asserts that the database structure of an opened RAGS file (RAGS file
    schema version 2.6.1) conforms to the expected schema. The expected schema
    is embedded in this function as static data; it mirrors
    'docs/rags-schema-v2.6.1.md' but is never read from disk at runtime.

    The function queries the SQL Server Compact schema metadata of the open
    connection (a managed System.Data.SqlServerCe connection to the SQL Server
    Compact 3.5 database, as opened by Open-RagsFileConnection) for the list
    of tables in the database and for the properties of the columns of those
    tables, and then crosschecks the metadata against the expected schema. For
    every expected column, the column name, data type, maximum length
    (nvarchar columns only), nullability, default value, and auto-increment
    setting are validated.

    Any of the following problems causes the function to throw a single
    exception which lists every problem found:
    - An expected table is missing from the file.
    - An expected column is missing from a table.
    - The data type, nullability, default value, or auto-increment setting of
      a column does not match the expected schema.
    - The maximum length of an nvarchar column is smaller than expected.

    The following deviations from the expected schema are only reported as
    warnings and do not fail the assertion:
    - The file contains tables which are not part of the expected schema.
    - A table contains columns which are not part of the expected schema.
    - An nvarchar column has a greater maximum length than expected.
    - A column has a default value although no default value is expected.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to a RAGS file, as returned by
    Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the database structure of the connected
    RAGS file conforms to the expected schema, and otherwise throws.

    .EXAMPLE
    $connection = Open-RagsFileConnection -Path 'C:\Games\MyGame.rag'
    try {
        Assert-RagsFileStructure -RagsConnection $connection
    }
    finally {
        $connection.Dispose()
    }

    Validates the database structure of a RAGS file through an open connection.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot assert the structure of a RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # The expected structure of a RAGS file database (RAGS file schema version
    # 2.6.1), embedded as static data. Each table maps to a list of column
    # specifications with the following keys:
    #   Name          - name of the expected column
    #   DataType      - expected data type of the column ('int', 'float',
    #                   'bit', 'nvarchar', 'ntext', 'image', or 'datetime')
    #   Nullable      - whether the column accepts null values
    #   AutoIncrement - whether the column is an auto-increment column
    #   MaxLength     - maximum length of the column (nvarchar columns only)
    #   Default       - default value of the column (only when it has one)
    # The data mirrors 'docs/rags-schema-v2.6.1.md' (26 tables, 166 columns)
    # and must be kept in sync with that document manually; the document is
    # never read by this function.
    $expectedSchema = [ordered]@{
        'CharacterActions' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Charname'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'CharacterProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Charname'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'Characters' = @(
            @{ Name = 'Charname'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'CharnameOverride'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'CharGender'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'CurrentRoom'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Description'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'AllowInventoryInteraction'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'EnterFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LeaveFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'CharPortrait'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
        'GameData' = @(
            @{ Name = 'Title'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'OpeningMessage'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'HideMainPicDisplay'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'UseInlineImages'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'HidePortrait'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'AuthorName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GameVersion'; DataType = 'nvarchar'; MaxLength = 50; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GameInformation'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'bgMusic'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'RepeatbgMusic'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PasswordProtected'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GamePassword'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'ObjectVersionNumber'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GameFont'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'RoomGroups'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'ClothingZoneLevels'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'NotificationsOff'; DataType = 'bit'; Nullable = $false; AutoIncrement = $false; Default = '0' }
            @{ Name = 'SortOrderRoom'; DataType = 'int'; Nullable = $false; AutoIncrement = $false; Default = '0' }
            @{ Name = 'SortOrderCharacters'; DataType = 'int'; Nullable = $false; AutoIncrement = $false; Default = '0' }
            @{ Name = 'SortOrderInventory'; DataType = 'int'; Nullable = $false; AutoIncrement = $false; Default = '0' }
        )
        'ItemActions' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'ItemID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'ItemGroups' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Parent'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
        'ItemLayeredZoneLevels' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'ItemID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
        )
        'ItemProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'ItemID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'Items' = @(
            @{ Name = 'UniqueID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Description'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'SDesc'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Preposition'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LocationName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LocationType'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Carryable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Wearable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Openable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Lockable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Enterable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Readable'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Container'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Weight'; DataType = 'float'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Worn'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Read'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Locked'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Open'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Entered'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Visible'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'EnterFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LeaveFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GroupName'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Important'; DataType = 'bit'; Nullable = $false; AutoIncrement = $false; Default = '0' }
        )
        'Media' = @(
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'BackgroundColor'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'TextColor'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'TextFont'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'ImageName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'UseEnhancedGraphics'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'NewImage'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'image'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GroupName'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
        'MediaGroups' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Parent'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
        'MediaLayeredImages' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'MediaName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Order'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
        )
        'Player' = @(
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Description'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'StartingRoom'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'CurrentRoom'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PlayerLayeredImage'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PlayerGender'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PromptForName'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PromptForGender'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PlayerPortrait'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'EnforceWeight'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'WeightLimit'; DataType = 'float'; Nullable = $true; AutoIncrement = $false }
        )
        'PlayerActions' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Data'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'PlayerProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'RoomActions' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'RoomID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'RoomExits' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'RoomID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Direction'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Active'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'DestinationRoom'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'PortalObjectName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
        )
        'RoomProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'RoomID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'Rooms' = @(
            @{ Name = 'UniqueID'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Description'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'SDesc'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'RoomPic'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'EnterFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LeaveFirstTime'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Group'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LayeredRoomPic'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
        )
        'StatusBarItems' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Text'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Width'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Visible'; DataType = 'bit'; Nullable = $false; AutoIncrement = $false; Default = '1' }
        )
        'Timer' = @(
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'TType'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Active'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Restart'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'TurnNumber'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Length'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'LiveTimer'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'TimerSeconds'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
        )
        'TimerActions' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Data'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'TimerProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'TimerName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'VariableGroups' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Parent'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
        'VariableProperties' = @(
            @{ Name = 'ID'; DataType = 'int'; Nullable = $false; AutoIncrement = $true }
            @{ Name = 'VarName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Name'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Value'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
        )
        'Variables' = @(
            @{ Name = 'VarName'; DataType = 'nvarchar'; MaxLength = 250; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'String'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'NumType'; DataType = 'float'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Min'; DataType = 'nvarchar'; MaxLength = 50; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'Max'; DataType = 'nvarchar'; MaxLength = 50; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'EnforceRestrictions'; DataType = 'bit'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'VarComment'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'dtDateTime'; DataType = 'datetime'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'VarType'; DataType = 'int'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'VarArray'; DataType = 'ntext'; Nullable = $true; AutoIncrement = $false }
            @{ Name = 'GroupName'; DataType = 'nvarchar'; MaxLength = 255; Nullable = $true; AutoIncrement = $false }
        )
    }

    # Maps a SQL Server Compact INFORMATION_SCHEMA.COLUMNS row (materialized
    # as a hashtable by Get-RagsSchemaRowSet) to the data type name used by
    # the static expected schema above. The INFORMATION_SCHEMA view reports
    # the data type directly as a name string ('int', 'float', 'bit', 'image',
    # 'nvarchar', 'ntext', or 'datetime'), so no type code mapping is needed.
    function Get-RagsSchemaTypeName {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$Column
        )

        $typeName = ([string]$Column['DATA_TYPE']).ToLowerInvariant()
        switch ($typeName) {
            'int'      { return 'int' }
            'float'    { return 'float' }
            'bit'      { return 'bit' }
            'image'    { return 'image' }
            'datetime' { return 'datetime' }
            'nvarchar' { return 'nvarchar' }
            'ntext'    { return 'ntext' }
            default    { return "unknown (data type '$typeName')" }
        }
    }

    # Returns the character maximum length of a schema column row, or $null
    # when the schema does not report a length for the column.
    function Get-RagsSchemaMaxLength {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$Column
        )

        $maxLength = $Column['CHARACTER_MAXIMUM_LENGTH']
        if (($null -eq $maxLength) -or ($maxLength -is [System.DBNull])) {
            return $null
        }
        return [long]$maxLength
    }

    # Returns the default value of a schema column row, or $null when the
    # column has no default value. The schema reports default values wrapped
    # in parentheses, such as '(0)' or '(1)', and padded with whitespace; both
    # are normalized away.
    function Get-RagsSchemaDefaultValue {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$Column
        )

        $hasDefault = $Column['COLUMN_HASDEFAULT']
        if (($null -eq $hasDefault) -or ($hasDefault -is [System.DBNull])) {
            return $null
        }
        if (-not [bool]$hasDefault) {
            return $null
        }
        if ($Column['COLUMN_DEFAULT'] -is [System.DBNull]) {
            return $null
        }

        $defaultValue = ([string]$Column['COLUMN_DEFAULT']).Trim()
        if (($defaultValue.Length -ge 2) -and $defaultValue.StartsWith('(') -and $defaultValue.EndsWith(')')) {
            $defaultValue = $defaultValue.Substring(1, $defaultValue.Length - 2).Trim()
        }
        if ($defaultValue.Length -eq 0) {
            return $null
        }
        return $defaultValue
    }

    # Determines whether a schema column row is an auto-increment (identity)
    # column. SQL Server Compact reports the next identity value in the
    # AUTOINC_NEXT INFORMATION_SCHEMA column for identity columns and reports
    # NULL for all other columns.
    function Test-RagsSchemaAutoIncrement {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$Column
        )

        $nextAutoIncrementValue = $Column['AUTOINC_NEXT']
        return (($null -ne $nextAutoIncrementValue) -and ($nextAutoIncrementValue -isnot [System.DBNull]))
    }

    # Read the table metadata of the connected database from the SQL Server
    # Compact INFORMATION_SCHEMA views. Only tables of the TABLE type are
    # considered; system tables are excluded.
    Write-Verbose "Reading the table metadata of the RAGS file connected through '$($RagsConnection.DataSource)'."
    $tableRows = @(
        Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT * FROM [INFORMATION_SCHEMA].[TABLES]' |
            Where-Object { $_['TABLE_TYPE'] -eq 'TABLE' }
    )

    # Read the column metadata of the connected database in a single query.
    Write-Verbose 'Reading the column metadata of the connected database.'
    $columnRows = @(
        Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT * FROM [INFORMATION_SCHEMA].[COLUMNS]'
    )

    # Index the actual tables and index the actual columns by table name and
    # column name. All lookups are performed through hashtables, which are
    # case-insensitive for string keys in PowerShell, so the case used by the
    # database for identifiers does not matter.
    $actualTableNames = @{}
    $actualColumnsByTable = @{}
    foreach ($tableRow in $tableRows) {
        $tableName = [string]$tableRow['TABLE_NAME']
        $actualTableNames[$tableName] = $true
        $actualColumnsByTable[$tableName] = @{}
    }
    foreach ($columnRow in $columnRows) {
        $tableName = [string]$columnRow['TABLE_NAME']
        if (-not $actualColumnsByTable.ContainsKey($tableName)) {
            # Columns of tables which are not user tables in the table
            # metadata above (system tables) are irrelevant.
            continue
        }
        $actualColumnsByTable[$tableName][[string]$columnRow['COLUMN_NAME']] = $columnRow
    }

    # Case-insensitive lookup of the expected table names, used to detect
    # extra tables in the file.
    $expectedTableNameLookup = @{}
    foreach ($expectedTableName in $expectedSchema.Keys) {
        $expectedTableNameLookup[$expectedTableName] = $true
    }

    $failureLines = [System.Collections.Generic.List[string]]::new()
    $warningLines = [System.Collections.Generic.List[string]]::new()

    # Extra tables in the file which are not part of the expected schema are
    # tolerated and only warned about.
    $extraTableNames = @(
        $actualTableNames.Keys |
            Where-Object { -not $expectedTableNameLookup.ContainsKey($_) } |
            Sort-Object
    )
    if ($extraTableNames.Count -gt 0) {
        $extraTableList = ($extraTableNames | ForEach-Object { "'$_'" }) -join ', '
        $warningLines.Add("The RAGS file contains tables which are not part of the expected RAGS file schema: $extraTableList. These tables are tolerated.")
    }

    # Crosscheck every expected table and every expected column.
    foreach ($expectedTableName in $expectedSchema.Keys) {
        if (-not $actualTableNames.ContainsKey($expectedTableName)) {
            $failureLines.Add("The table '$expectedTableName' is missing from the RAGS file.")
            continue
        }

        $expectedColumnSpecs = $expectedSchema[$expectedTableName]
        $actualColumns = $actualColumnsByTable[$expectedTableName]

        # Extra columns in an expected table which are not part of the
        # expected schema are tolerated and only warned about.
        $expectedColumnNameLookup = @{}
        foreach ($expectedColumnSpec in $expectedColumnSpecs) {
            $expectedColumnNameLookup[$expectedColumnSpec.Name] = $true
        }
        $extraColumnNames = @(
            $actualColumns.Keys |
                Where-Object { -not $expectedColumnNameLookup.ContainsKey($_) } |
                Sort-Object
        )
        if ($extraColumnNames.Count -gt 0) {
            $extraColumnList = ($extraColumnNames | ForEach-Object { "'$_'" }) -join ', '
            $warningLines.Add("The table '$expectedTableName' contains columns which are not part of the expected RAGS file schema: $extraColumnList. These columns are tolerated.")
        }

        foreach ($expectedColumnSpec in $expectedColumnSpecs) {
            $expectedColumnName = $expectedColumnSpec.Name
            $expectedTypeName = $expectedColumnSpec.DataType
            $expectedNullable = [bool]$expectedColumnSpec.Nullable
            $expectedAutoIncrement = [bool]$expectedColumnSpec.AutoIncrement

            if (-not $actualColumns.ContainsKey($expectedColumnName)) {
                $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': the column is missing from the table.")
                continue
            }

            $actualColumn = $actualColumns[$expectedColumnName]

            # Data type.
            $actualTypeName = Get-RagsSchemaTypeName -Column $actualColumn
            if (-not [string]::Equals($actualTypeName, $expectedTypeName, [System.StringComparison]::OrdinalIgnoreCase)) {
                $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': data type mismatch; expected '$expectedTypeName', found '$actualTypeName'.")
            }

            # Maximum length (nvarchar columns only). A greater actual maximum
            # length than expected is tolerated and only warned about; a
            # smaller maximum length fails the assertion.
            if ($expectedColumnSpec.ContainsKey('MaxLength') -and [string]::Equals($actualTypeName, 'nvarchar', [System.StringComparison]::OrdinalIgnoreCase)) {
                $expectedMaxLength = [long]$expectedColumnSpec.MaxLength
                $actualMaxLength = Get-RagsSchemaMaxLength -Column $actualColumn
                if ($null -eq $actualMaxLength) {
                    $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': maximum length mismatch; expected $expectedMaxLength, but the column reports no maximum length.")
                }
                elseif ($actualMaxLength -gt $expectedMaxLength) {
                    $warningLines.Add("Table '$expectedTableName', column '$expectedColumnName': the column has a greater maximum length ($actualMaxLength) than the expected maximum length ($expectedMaxLength); this is tolerated.")
                }
                elseif ($actualMaxLength -lt $expectedMaxLength) {
                    $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': maximum length mismatch; expected $expectedMaxLength, found $actualMaxLength.")
                }
            }

            # Nullability. The INFORMATION_SCHEMA view reports nullability as
            # the strings 'YES' and 'NO' (a [bool] cast of any non-empty
            # string would be $true, so the string is compared directly).
            $actualNullable = ('YES' -eq [string]$actualColumn['IS_NULLABLE'])
            if ($actualNullable -ne $expectedNullable) {
                $expectedNullableText = if ($expectedNullable) { 'nullable' } else { 'not nullable' }
                $actualNullableText = if ($actualNullable) { 'nullable' } else { 'not nullable' }
                $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': nullability mismatch; expected $expectedNullableText, found $actualNullableText.")
            }

            # Default value. A default value on a column for which no default
            # value is expected is tolerated and only warned about.
            $actualDefaultValue = Get-RagsSchemaDefaultValue -Column $actualColumn
            if ($expectedColumnSpec.ContainsKey('Default')) {
                $expectedDefaultValue = [string]$expectedColumnSpec.Default
                if ($null -eq $actualDefaultValue) {
                    $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': default value mismatch; expected the default value '$expectedDefaultValue', but the column has no default value.")
                }
                elseif (-not [string]::Equals($actualDefaultValue, $expectedDefaultValue, [System.StringComparison]::Ordinal)) {
                    $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': default value mismatch; expected the default value '$expectedDefaultValue', found '$actualDefaultValue'.")
                }
            }
            elseif ($null -ne $actualDefaultValue) {
                $warningLines.Add("Table '$expectedTableName', column '$expectedColumnName': the column has the default value '$actualDefaultValue' although no default value is expected; this is tolerated.")
            }

            # Auto-increment setting.
            $actualAutoIncrement = Test-RagsSchemaAutoIncrement -Column $actualColumn
            if ($actualAutoIncrement -ne $expectedAutoIncrement) {
                $expectedAutoIncrementText = if ($expectedAutoIncrement) { 'an auto-increment column' } else { 'not an auto-increment column' }
                $actualAutoIncrementText = if ($actualAutoIncrement) { 'an auto-increment column' } else { 'not an auto-increment column' }
                $failureLines.Add("Table '$expectedTableName', column '$expectedColumnName': auto-increment mismatch; expected $expectedAutoIncrementText, found $actualAutoIncrementText.")
            }
        }
    }

    foreach ($warningLine in $warningLines) {
        Write-Warning $warningLine
    }

    if ($failureLines.Count -gt 0) {
        $messageLines = [System.Collections.Generic.List[string]]::new()
        $messageLines.Add("The structure of the RAGS file connected through '$($RagsConnection.DataSource)' does not conform to the expected RAGS file schema (version 2.6.1). The following problems were found:")
        foreach ($failureLine in $failureLines) {
            $messageLines.Add("- $failureLine")
        }
        throw ($messageLines -join [System.Environment]::NewLine)
    }

    Write-Verbose 'The structure of the RAGS file conforms to the expected schema.'
    return $true
}
