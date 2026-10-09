#Requires -Version 5.1
Set-StrictMode -Version Latest

function ConvertTo-RagsFilenameGuid {
    <#
    .SYNOPSIS
    Converts the value of a List column into the GUID used as a file name.

    .DESCRIPTION
    Derives the `System.Guid` which names the YAML file of a single-file-per-
    value (subfolder) expansion, according to the GUID filename generation
    logic documented in docs/data-mapping.md:

    1. The value is UTF-8 encoded.
    2. The encoded bytes are MD5-hashed (a 16-byte digest).
    3. The digest bytes are used directly to construct a System.Guid.
    4. The lowercase, dash-separated ('D' format) string form of the GUID is
    returned, to be used as the base file name (before the '.yaml' extension).

    The same algorithm must be used when re-compressing a subfolder back into
    a RAGS file (Compress-* handlers), although those handlers consume
    the file contents and merely accept any well-formed file names.

    .PARAMETER Value
    The List column value to convert, for example the Charname value of a
    CharacterActions row.

    .OUTPUTS
    System.String. The lowercase, dash-separated GUID string.

    .EXAMPLE
    PS> $fileName = (ConvertTo-RagsFilenameGuid -Value $charname) + '.yaml'

    Builds the YAML file name for the character named $charname.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'Cannot convert the value into a file name GUID: the given value is empty.'
    }

    # 1. UTF-8 encode the value.
    $valueBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)

    # 2. MD5-hash the encoded bytes.
    $hashAlgorithm = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $hashAlgorithm.ComputeHash($valueBytes)
    }
    finally {
        $hashAlgorithm.Dispose()
    }

    # 3. Construct the GUID directly from the 16 hash bytes.
    $guid = [System.Guid]::new($hashBytes)

    # 4. Return the lowercase, dash-separated string form.
    return $guid.ToString('D')
}
