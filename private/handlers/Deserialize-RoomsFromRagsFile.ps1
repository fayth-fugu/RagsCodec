#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-RoomsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes Rooms data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported Rooms data to deserialize.

    .EXAMPLE
    Deserialize-RoomsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-RoomsFromRagsFile.'
}

