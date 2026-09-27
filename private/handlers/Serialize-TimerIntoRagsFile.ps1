#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-TimerIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes Timer data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the Timer data from.

    .EXAMPLE
    Serialize-TimerIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-TimerIntoRagsFile.'
}

