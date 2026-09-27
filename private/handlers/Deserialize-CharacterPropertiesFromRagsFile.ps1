#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-CharacterPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes CharacterProperties data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported CharacterProperties data to deserialize.

    .EXAMPLE
    Deserialize-CharacterPropertiesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-CharacterPropertiesFromRagsFile.'
}

