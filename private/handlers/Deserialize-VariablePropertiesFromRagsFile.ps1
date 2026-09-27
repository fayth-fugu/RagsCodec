#Requires -Version 5.1
Set-StrictMode -Version Latest

function Deserialize-VariablePropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Deserializes VariableProperties data from a RagsFile.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER FolderPath
    Folder containing the exported VariableProperties data to deserialize.

    .EXAMPLE
    Deserialize-VariablePropertiesFromRagsFile -FolderPath 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    Write-Host 'TODO: Implement Deserialize-VariablePropertiesFromRagsFile.'
}

