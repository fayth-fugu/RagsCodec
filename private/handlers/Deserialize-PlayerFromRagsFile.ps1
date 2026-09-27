#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-PlayerFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes Player data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported Player data to deserialize.

    .EXAMPLE
    Deserialize-PlayerFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-PlayerFromRagsFile.'
}

