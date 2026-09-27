#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-PlayerActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes PlayerActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported PlayerActions data to deserialize.

    .EXAMPLE
    Deserialize-PlayerActionsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-PlayerActionsFromRagsFile.'
}

