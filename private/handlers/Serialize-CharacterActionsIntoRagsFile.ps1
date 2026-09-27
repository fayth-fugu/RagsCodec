#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-CharacterActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes CharacterActions data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the CharacterActions data from.

    .EXAMPLE
    Serialize-CharacterActionsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-CharacterActionsIntoRagsFile.'
}

