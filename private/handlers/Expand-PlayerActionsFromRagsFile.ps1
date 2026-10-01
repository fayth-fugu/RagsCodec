#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-PlayerActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes PlayerActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER OutputPath
    Path of the folder containing the exported PlayerActions data to deserialize.

    .PARAMETER RagsConnection
    An open OLE DB connection to the RAGS file (provider Microsoft.SQLSERVER.CE.OLEDB.3.5),
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Expand-PlayerActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.OleDb.OleDbConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Expand-PlayerActionsFromRagsFile.'
}

