#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-PlayerPropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes PlayerProperties data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER SourcePath
    Path of the folder to serialize the PlayerProperties data from.

    .PARAMETER RagsConnection
    An open OLE DB connection to the RAGS file (provider Microsoft.SQLSERVER.CE.OLEDB.3.5),
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-PlayerPropertiesIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Data.OleDb.OleDbConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Compress-PlayerPropertiesIntoRagsFile.'
}

