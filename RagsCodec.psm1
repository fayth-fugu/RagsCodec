# RagsCodec module loader.
# This module is distributed as a collection of files and is never compiled
# into a single .psm1 file. This loader discovers and dot-sources every
# script file in the module tree at import time.

$moduleRoot = $PSScriptRoot

# Vendored third-party dependencies live under deps\. Import powershell-yaml
# into this module's session state so its commands (ConvertTo-Yaml /
# ConvertFrom-Yaml) are available to this module's functions. Because the
# import happens at module scope, the dependency's commands do not leak into
# the consumer's session. The deps\ folder must ship together with the
# module code.
$yamlModuleManifest = Join-Path $moduleRoot 'deps\powershell-yaml\powershell-yaml.psd1'
if (-not (Test-Path -LiteralPath $yamlModuleManifest)) {
    throw "Vendored dependency 'powershell-yaml' is missing: expected manifest at '$yamlModuleManifest'."
}
Write-Verbose "Loading vendored dependency manifest: $yamlModuleManifest"
Import-Module -Name $yamlModuleManifest -ErrorAction Stop

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
