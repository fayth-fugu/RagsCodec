#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-CharacterPropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes CharacterProperties data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the CharacterProperties data from.

    .EXAMPLE
    Serialize-CharacterPropertiesIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-CharacterPropertiesIntoRagsFile.'
}

