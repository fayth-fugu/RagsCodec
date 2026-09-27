#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-RoomActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes RoomActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported RoomActions data to deserialize.

    .EXAMPLE
    Deserialize-RoomActionsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-RoomActionsFromRagsFile.'
}

