#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-PlayerPropertiesIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes PlayerProperties data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the PlayerProperties data from.

    .EXAMPLE
    Serialize-PlayerPropertiesIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-PlayerPropertiesIntoRagsFile.'
}

