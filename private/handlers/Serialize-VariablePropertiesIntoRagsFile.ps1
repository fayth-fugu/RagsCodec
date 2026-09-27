#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-VariablePropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes VariableProperties data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the VariableProperties data from.

    .EXAMPLE
    Serialize-VariablePropertiesIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-VariablePropertiesIntoRagsFile.'
}

