#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-VariableGroupsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes VariableGroups data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the VariableGroups data from.

    .EXAMPLE
    Serialize-VariableGroupsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-VariableGroupsIntoRagsFile.'
}

