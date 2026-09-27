#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-GameDataFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes GameData data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported GameData data to deserialize.

    .EXAMPLE
    Deserialize-GameDataFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-GameDataFromRagsFile.'
}

