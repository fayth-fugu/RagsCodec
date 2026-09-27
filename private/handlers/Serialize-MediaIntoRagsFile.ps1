#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-MediaIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes Media data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the Media data from.

    .EXAMPLE
    Serialize-MediaIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-MediaIntoRagsFile.'
}

