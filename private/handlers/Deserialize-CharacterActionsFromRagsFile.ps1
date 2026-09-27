#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-CharacterActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes CharacterActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported CharacterActions data to deserialize.

    .EXAMPLE
    Deserialize-CharacterActionsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-CharacterActionsFromRagsFile.'
}

