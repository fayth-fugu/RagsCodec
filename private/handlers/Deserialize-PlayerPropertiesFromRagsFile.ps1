#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-PlayerPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes PlayerProperties data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported PlayerProperties data to deserialize.

    .EXAMPLE
    Deserialize-PlayerPropertiesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-PlayerPropertiesFromRagsFile.'
}

