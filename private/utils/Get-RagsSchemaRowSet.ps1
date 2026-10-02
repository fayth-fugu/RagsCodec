#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-RagsSchemaRowSet {
    <#
    .SYNOPSIS
    Reads a schema metadata row set from an opened RAGS file connection.

    .DESCRIPTION
    Executes the given SQL statement through an opened SQL Server Compact
    connection (a RAGS file connection, as opened by Open-RagsFileConnection)
    and materializes the result rows as hashtables which map the column names
    of the result set to their values. Null values are represented by DBNull
    values, mirroring the behavior of a raw data reader.

    The function is intended for the schema metadata queries against the
    SQL Server Compact INFORMATION_SCHEMA views, but can execute any query.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to a RAGS file, as returned by
    Open-RagsFileConnection.

    .PARAMETER Sql
    The SQL statement to execute.

    .OUTPUTS
    System.Collections.Hashtable[]. One hashtable per result row; each
    hashtable maps the column names of the result set to the values of the
    row. The array is returned as a single object and is never $null.

    .EXAMPLE
    $tables = Get-RagsSchemaRowSet -RagsConnection $connection -Sql 'SELECT [TABLE_NAME], [TABLE_TYPE] FROM INFORMATION_SCHEMA.TABLES'

    Reads the table metadata of the connected database.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection,

        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot read schema metadata from the RAGS file: the given connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    $command = $RagsConnection.CreateCommand()
    $command.CommandText = $Sql
    $reader = $command.ExecuteReader()
    try {
        $fieldNames = @(0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetName($_) })
        $rows = [System.Collections.Generic.List[System.Collections.Hashtable]]::new()
        while ($reader.Read()) {
            $row = @{}
            foreach ($fieldIndex in 0..($reader.FieldCount - 1)) {
                $row[$fieldNames[$fieldIndex]] = $reader.GetValue($fieldIndex)
            }
            $rows.Add($row)
        }

        # The rows are returned unwrapped: callers capture the result through
        # @(...) which produces an empty array for an empty result set, and
        # pipeline callers receive the individual row hashtables. (A comma
        # wrapper would emit the array itself as a single pipeline item,
        # breaking string-keyed indexing downstream.)
        return $rows.ToArray()
    }
    finally {
        $reader.Dispose()
        $command.Dispose()
    }
}
