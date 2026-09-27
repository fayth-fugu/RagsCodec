#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-ItemsFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes Items data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported Items data to deserialize.

    .EXAMPLE
    Deserialize-ItemsFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-ItemsFromRagsFile.'
}

