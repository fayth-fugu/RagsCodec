#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-MediaFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes Media data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER OutputPath
    Path of the folder containing the exported Media data to deserialize.

    .PARAMETER RagsConnection
    An open OLE DB connection to the RAGS file (provider Microsoft.SQLSERVER.CE.OLEDB.3.5),
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Expand-MediaFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.OleDb.OleDbConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Expand-MediaFromRagsFile.'
}

