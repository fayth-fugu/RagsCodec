#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-RoomsIntoRagsFile {
    <#
    .SYNOPSIS
    Serializes Rooms data into a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFileConnection
    Connection to the RAGS file to serialize the Rooms data from.

    .EXAMPLE
    Serialize-RoomsIntoRagsFile -RagsFileConnection $connection
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RagsFileConnection
    )

    Write-Host 'TODO: Implement Serialize-RoomsIntoRagsFile.'
}

