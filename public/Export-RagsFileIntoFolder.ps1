#Requires -Version 5.1
Set-StrictMode -Version Latest

function Export-RagsFileIntoFolder {
    <#
    .SYNOPSIS
    Exports the contents of a RAGS file into a folder structure.

    .DESCRIPTION
    Placeholder. This function is still to be implemented.

    .PARAMETER RagsFilePath
    Path to the RAGS file to export.

    .PARAMETER DestinationFolder
    Folder the RAGS file contents will be exported into.

    .EXAMPLE
    Export-RagsFileIntoFolder -RagsFilePath 'C:\Games\MyGame.rag' -DestinationFolder 'C:\Export\MyGame'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RagsFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFolder,

        [Parameter()]
        [switch]$Force
    )

    Write-Host 'TODO: Implement Export-RagsFileIntoFolder.'
}
