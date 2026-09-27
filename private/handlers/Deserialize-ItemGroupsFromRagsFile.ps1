#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-ItemGroupsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes ItemGroups data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported ItemGroups data to deserialize.

    .EXAMPLE
    Deserialize-ItemGroupsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-ItemGroupsFromRagsFile.'
}

