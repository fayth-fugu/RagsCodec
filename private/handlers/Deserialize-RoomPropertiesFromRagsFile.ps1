#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-RoomPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes RoomProperties data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported RoomProperties data to deserialize.

    .EXAMPLE
    Deserialize-RoomPropertiesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-RoomPropertiesFromRagsFile.'
}

