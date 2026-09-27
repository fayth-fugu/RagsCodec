#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-PlayerIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes Player data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the Player data from.

    .EXAMPLE
    Serialize-PlayerIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-PlayerIntoRagsFile.'
}

