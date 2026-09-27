#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-PlayerActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes PlayerActions data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the PlayerActions data from.

    .EXAMPLE
    Serialize-PlayerActionsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-PlayerActionsIntoRagsFile.'
}

