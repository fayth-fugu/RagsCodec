#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-TimerActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes TimerActions data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the TimerActions data from.

    .EXAMPLE
    Serialize-TimerActionsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-TimerActionsIntoRagsFile.'
}

