#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-CharactersIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes Characters data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the Characters data from.

    .EXAMPLE
    Serialize-CharactersIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-CharactersIntoRagsFile.'
}

