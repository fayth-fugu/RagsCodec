#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-MediaLayeredImagesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes MediaLayeredImages data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported MediaLayeredImages data to deserialize.

    .EXAMPLE
    Deserialize-MediaLayeredImagesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-MediaLayeredImagesFromRagsFile.'
}

