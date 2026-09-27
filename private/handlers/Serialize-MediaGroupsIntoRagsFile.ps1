#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-MediaGroupsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes MediaGroups data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the MediaGroups data from.

    .EXAMPLE
    Serialize-MediaGroupsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-MediaGroupsIntoRagsFile.'
}

