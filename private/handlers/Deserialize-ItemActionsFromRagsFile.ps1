#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-ItemActionsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes ItemActions data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported ItemActions data to deserialize.

    .EXAMPLE
    Deserialize-ItemActionsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-ItemActionsFromRagsFile.'
}

