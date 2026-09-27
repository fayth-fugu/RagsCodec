#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-ItemPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes ItemProperties data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported ItemProperties data to deserialize.

    .EXAMPLE
    Deserialize-ItemPropertiesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-ItemPropertiesFromRagsFile.'
}

