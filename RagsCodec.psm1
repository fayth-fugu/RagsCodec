# RagsCodec module loader.
# This module is distributed as a collection of files and is never compiled
# into a single .psm1 file. This loader discovers and dot-sources every
# script file in the module tree at import time.

$moduleRoot = $PSScriptRoot

# Dot-source all function definition files, grouped by folder.
# Public functions become the module's exported commands; Private functions
# (Handlers/ and Utils/) are only visible inside the module scope.
$viewFolders = @(
    'Public'
    'Private'
    'Private\Utils'
    'Private\Handlers'
)

$viewFolders |
    ForEach-Object { Join-Path $moduleRoot $_ } |
    Where-Object { Test-Path -Path $_ } |
    ForEach-Object {
        Get-ChildItem -Path $_ -Filter '*.ps1' -File |
            ForEach-Object {
                Write-Verbose "Loading $($_.FullName)"
                . $_.FullName
            }
    }
