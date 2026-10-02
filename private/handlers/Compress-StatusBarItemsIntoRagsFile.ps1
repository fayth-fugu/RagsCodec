#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-StatusBarItemsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses StatusBarItems data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER SourcePath
    Path of the folder to compress the StatusBarItems data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-StatusBarItemsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Compress-StatusBarItemsIntoRagsFile.'
}

