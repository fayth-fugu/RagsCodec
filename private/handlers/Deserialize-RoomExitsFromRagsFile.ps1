#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-RoomExitsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes RoomExits data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported RoomExits data to deserialize.

    .EXAMPLE
    Deserialize-RoomExitsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-RoomExitsFromRagsFile.'
}

