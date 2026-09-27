#Requires -Version 5.1
Set-StrictMode -Version Latest

function Import-RagsFileFromFolder {
    <#
    .SYNOPSIS
    Imports a previously exported folder structure back into a RAGS file.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER SourceFolder
    Folder containing the exported RAGS file contents.

    .PARAMETER RagsFilePath
    Path of the RAGS file to create from the folder contents.

    .EXAMPLE
    Import-RagsFileFromFolder -SourceFolder 'C:\Export\MyGame' -RagsFilePath 'C:\Games\MyRebuiltGame.rag'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFolder,

        [Parameter(Mandatory = $true)]
        [string]$RagsFilePath,

        [Parameter()]
        [switch]$Force
    )

    Write-Host 'TODO: Implement Import-RagsFileFromFolder.'
}
