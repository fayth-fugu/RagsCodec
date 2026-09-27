@{
    RootModule        = 'RagsCodec.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '0adf49ea-0b95-401c-9bc8-e876284f8c64'
    Author            = 'RagsCodec Contributors'
    CompanyName       = 'Unknown'
    Copyright         = '(c) RagsCodec Contributors. All rights reserved.'
    Description       = 'PowerShell module for exporting RAGS game files into a folder structure and importing them back into a RAGS file.'
    PowerShellVersion = '5.1'
    FormatsToProcess  = @()
    FunctionsToExport = @(
        'Export-RagsFileIntoFolder'
        'Import-RagsFileFromFolder'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('RAGS', 'Codec', 'Serialization')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = 'Initial scaffold.'
        }
    }
}
