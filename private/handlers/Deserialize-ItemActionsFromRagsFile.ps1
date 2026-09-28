#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-ItemActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes ItemActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER OutputPath
    Path of the folder containing the exported ItemActions data to deserialize.

    .PARAMETER RagsConnection
    An open OLE DB connection to the RAGS file (provider Microsoft.SQLSERVER.CE.OLEDB.3.5),
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Deserialize-ItemActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.OleDb.OleDbConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Deserialize-ItemActionsFromRagsFile.'
}

