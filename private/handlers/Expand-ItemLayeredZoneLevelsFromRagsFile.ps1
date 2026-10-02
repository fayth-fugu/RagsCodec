#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-ItemLayeredZoneLevelsFromRagsFile {
    <#
    .SYNOPSIS
    Expands ItemLayeredZoneLevels data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER OutputPath
    Path of the folder to export the expanded ItemLayeredZoneLevels data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Expand-ItemLayeredZoneLevelsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    Write-Host 'TODO: Implement Expand-ItemLayeredZoneLevelsFromRagsFile.'
}

