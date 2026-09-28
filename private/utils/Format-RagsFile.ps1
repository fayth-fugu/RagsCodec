#Requires -Version 5.1
Set-StrictMode -Version Latest

function Format-RagsFile {
    <#
    .SYNOPSIS
    Empties every table of an opened RAGS file connection.

    .DESCRIPTION
    Deletes all rows of every table of a RAGS file (RAGS file schema version
    2.6.1) through an open OLE DB connection to the
    'Microsoft.SQLSERVER.CE.OLEDB.3.5' provider (as opened by
    Open-RagsFileConnection). The table list is discovered from the schema
    metadata of the connection; only tables of the TABLE type are considered,
    and system tables and views are excluded. The schema (the tables and their
    columns) of the file is left intact.

    The deletion is attempted for every table. If the deletion failed for any
    of the tables, the function throws a single exception which lists every
    table which could not be emptied.

    .PARAMETER RagsConnection
    An open OLE DB connection to a RAGS file, as returned by
    Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when every table of the connected RAGS file
    has been emptied, and otherwise throws.

    .EXAMPLE
    $connection = Open-RagsFileConnection -Path 'C:\Games\MyGame.rag'
    try {
        Format-RagsFile -RagsConnection $connection
    }
    finally {
        $connection.Dispose()
    }

    Empties every table of a RAGS file through an open connection.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.OleDb.OleDbConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot format the RAGS file: the given OLE DB connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Read the table metadata of the connected database. Only tables of the
    # TABLE type are considered; system tables and views are excluded.
    Write-Verbose "Reading the table metadata of the RAGS file connected through '$($RagsConnection.DataSource)'."
    $tableNames = @(
        $RagsConnection.GetOleDbSchemaTable([System.Data.OleDb.OleDbSchemaGuid]::Tables, $null).Rows |
            Where-Object { $_.TABLE_TYPE -eq 'TABLE' } |
            ForEach-Object { [string]$_.TABLE_NAME } |
            Sort-Object
    )

    $failedTableNames = [System.Collections.Generic.List[string]]::new()

    foreach ($tableName in $tableNames) {
        Write-Verbose "Deleting all rows of table '$tableName'."
        try {
            $command = $RagsConnection.CreateCommand()
            try {
                $command.CommandText = "DELETE FROM [$($tableName.Replace(']', ']]'))]"
                $null = $command.ExecuteNonQuery()
            }
            finally {
                $command.Dispose()
            }
        }
        catch {
            Write-Warning "Failed to delete all rows of table '${tableName}': $($_.Exception.Message)"
            $failedTableNames.Add($tableName)
        }
    }

    if ($failedTableNames.Count -gt 0) {
        $messageLines = [System.Collections.Generic.List[string]]::new()
        $messageLines.Add("Failed to delete all rows of the following tables of the RAGS file connected through '$($RagsConnection.DataSource)':")
        foreach ($failedTableName in $failedTableNames) {
            $messageLines.Add("- '$failedTableName'")
        }
        throw ($messageLines -join [System.Environment]::NewLine)
    }

    Write-Verbose "Emptied all $($tableNames.Count) tables of the RAGS file."
    return $true
}
