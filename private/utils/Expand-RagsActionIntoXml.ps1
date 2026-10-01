#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-RagsActionIntoXml {
    <#
    .SYNOPSIS
    Expands an encoded RAGS action back into its XML representation.

    .DESCRIPTION
    Decodes an encoded RAGS action (as stored in columns tagged with the
    RagsAction handling instruction) back into its XML representation.

    The encoded value is a Base64-encoded binary stream with the following
    structure:

    - 4 bytes of padding at the start of the stream, storing the size of the
    subsequent GZip stream. The padding is only needed by RAGS Designer for
    its internal GZip decompression and is safely discarded here (its value
    is still reported on the verbose stream for diagnostic purposes).
    - All subsequent bytes represent a standard GZip stream containing XML
    data.

    The decompressed XML data is usually stored linearized, so it is
    pretty-printed before being returned. When the decompressed data is not
    well-formed XML and cannot be pretty-printed, a warning is emitted and
    the raw decompressed value is returned instead.

    .PARAMETER EncodedRagsAction
    The Base64-encoded RAGS action to expand. The value is validated to
    be a valid Base64-encoded string before decoding.

    .OUTPUTS
    System.String. The pretty-printed XML representation of the RAGS action.

    .EXAMPLE
    PS> $actionXml = Expand-RagsActionIntoXml -EncodedRagsAction $encodedAction

    Decodes the Base64-encoded RAGS action stored in $encodedAction into its
    pretty-printed XML representation.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EncodedRagsAction
    )

    # Trim surrounding whitespace so that values carried over from database
    # columns (which may carry trailing line breaks) still decode.
    $base64Value = $EncodedRagsAction.Trim()

    if ([string]::IsNullOrEmpty($base64Value)) {
        throw 'Cannot expand the RAGS action: the encoded value is empty.'
    }

    # Validate the Base64 payload: Base64 digits only, with optional padding
    # ('=') confined to the end, and a total length that is a multiple of 4.
    $isValidBase64 =
        ($base64Value -cmatch '^[A-Za-z0-9+/]+={0,2}$') -and
        (($base64Value.Length % 4) -eq 0)
    if (-not $isValidBase64) {
        $displayValue =
            if ($base64Value.Length -gt 64) {
                $base64Value.Substring(0, 64) + '...'
            }
            else {
                $base64Value
            }

        throw "Cannot expand the RAGS action: the value '$displayValue' is not a valid Base64-encoded string."
    }

    $ragsActionBytes = [System.Convert]::FromBase64String($base64Value)

    # The stream must at least carry the 4-byte padding and some GZip data.
    $paddingByteCount = 4
    if ($ragsActionBytes.Length -le $paddingByteCount) {
        throw "Cannot expand the RAGS action: the decoded stream is $($ragsActionBytes.Length) byte(s) long, which is too short to contain the 4-byte padding followed by a GZip stream."
    }

    # The padding advertises the size of the GZip stream that follows it. The
    # value is only needed by RAGS Designer, so it is discarded; it is still
    # reported on the verbose stream for diagnostic purposes.
    $paddingValue = [System.BitConverter]::ToUInt32($ragsActionBytes, 0)
    Write-Verbose ("Discarding the 4-byte padding at the start of the stream; it advertises a GZip stream size of {0} byte(s) (0x{1:X8})." -f $paddingValue, $paddingValue)

    $gzipStreamOffset = $paddingByteCount
    $gzipStreamLength = $ragsActionBytes.Length - $paddingByteCount

    # A GZip member always carries a 10-byte header and an 8-byte trailer, so
    # anything shorter than 18 bytes cannot be a GZip stream.
    if ($gzipStreamLength -lt 18) {
        throw "Cannot expand the RAGS action: the data following the 4-byte padding is only ${gzipStreamLength} byte(s) long, which is too short to be a GZip stream."
    }

    # The first two bytes of a GZip stream are fixed magic bytes (0x1F 0x8B).
    if (($ragsActionBytes[$gzipStreamOffset] -ne 0x1F) -or ($ragsActionBytes[$gzipStreamOffset + 1] -ne 0x8B)) {
        throw 'Cannot expand the RAGS action: the data following the 4-byte padding does not begin with the GZip magic bytes (0x1F 0x8B), so it is not a GZip stream.'
    }

    Write-Verbose "Decompressing the ${gzipStreamLength}-byte GZip stream following the padding."

    $compressedStream = $null
    $gzipStream = $null
    $decompressedStream = $null
    try {
        $compressedStream = [System.IO.MemoryStream]::new($ragsActionBytes, $gzipStreamOffset, $gzipStreamLength)
        $gzipStream = [System.IO.Compression.GZipStream]::new($compressedStream, [System.IO.Compression.CompressionMode]::Decompress)
        $decompressedStream = [System.IO.MemoryStream]::new()
        $gzipStream.CopyTo($decompressedStream)
    }
    catch {
        $message = 'Cannot expand the RAGS action: the GZip stream following the 4-byte padding could not be decompressed. '
        $message += "The GZip decoder reported the following error: '$($_.Exception.Message)'. "
        $message += 'Verify that the value is a RAGS action (a Base64-encoded stream of a 4-byte padding followed by GZip-compressed XML data).'

        throw [System.Exception]::new($message, $_.Exception)
    }
    finally {
        if ($null -ne $gzipStream) {
            $gzipStream.Dispose()
        }
        if ($null -ne $compressedStream) {
            $compressedStream.Dispose()
        }
        if ($null -ne $decompressedStream) {
            $decompressedStream.Dispose()
        }
    }

    # MemoryStream.ToArray remains callable after disposal.
    $xmlBytes = $decompressedStream.ToArray()
    if ($xmlBytes.Length -eq 0) {
        throw 'Cannot expand the RAGS action: the GZip stream decompressed to 0 bytes of XML data.'
    }

    # Decode the XML payload. The payload may start with a byte-order mark
    # (BOM), which is detected here so that UTF-8 and UTF-16 payloads are
    # decoded correctly; payloads without a BOM are assumed to be UTF-8.
    if (($xmlBytes.Length -ge 3) -and ($xmlBytes[0] -eq 0xEF) -and ($xmlBytes[1] -eq 0xBB) -and ($xmlBytes[2] -eq 0xBF)) {
        Write-Verbose 'Decoding the XML data as UTF-8 (byte-order mark detected).'
        $xmlText = [System.Text.Encoding]::UTF8.GetString($xmlBytes, 3, $xmlBytes.Length - 3)
    }
    elseif (($xmlBytes.Length -ge 2) -and ($xmlBytes[0] -eq 0xFF) -and ($xmlBytes[1] -eq 0xFE)) {
        Write-Verbose 'Decoding the XML data as UTF-16 LE (byte-order mark detected).'
        $xmlText = [System.Text.Encoding]::Unicode.GetString($xmlBytes, 2, $xmlBytes.Length - 2)
    }
    elseif (($xmlBytes.Length -ge 2) -and ($xmlBytes[0] -eq 0xFE) -and ($xmlBytes[1] -eq 0xFF)) {
        Write-Verbose 'Decoding the XML data as UTF-16 BE (byte-order mark detected).'
        $xmlText = [System.Text.Encoding]::BigEndianUnicode.GetString($xmlBytes, 2, $xmlBytes.Length - 2)
    }
    else {
        Write-Verbose 'Decoding the XML data as UTF-8 (no byte-order mark detected).'
        $xmlText = [System.Text.Encoding]::UTF8.GetString($xmlBytes)
    }

    # Pretty-print the XML data (it is usually stored linearized). When the
    # data cannot be loaded as XML, the raw decompressed value is returned.
    try {
        $xmlDocument = [System.Xml.XmlDocument]::new()
        $xmlDocument.PreserveWhitespace = $false
        $xmlDocument.LoadXml($xmlText)

        # A writer created over a string builder regenerates the XML
        # declaration with its own (wrong) encoding, so the declaration is
        # suppressed here and the existing one is preserved verbatim by
        # prepending it to the pretty-printed body. Documents that were
        # stored without a declaration stay free of one.
        $xmlDeclaration = $xmlDocument.FirstChild -as [System.Xml.XmlDeclaration]

        $writerSettings = [System.Xml.XmlWriterSettings]::new()
        $writerSettings.Indent = $true
        $writerSettings.IndentChars = '  '
        $writerSettings.OmitXmlDeclaration = $true

        $stringBuilder = [System.Text.StringBuilder]::new()
        $xmlWriter = $null
        try {
            $xmlWriter = [System.Xml.XmlWriter]::Create($stringBuilder, $writerSettings)
            $xmlDocument.Save($xmlWriter)
        }
        finally {
            if ($null -ne $xmlWriter) {
                $xmlWriter.Dispose()
            }
        }

        $prettyXml = $stringBuilder.ToString()
        if ($null -ne $xmlDeclaration) {
            $prettyXml = $xmlDeclaration.OuterXml + [Environment]::NewLine + $prettyXml
        }

        Write-Verbose 'Successfully pretty-printed the XML data of the RAGS action.'

        return $prettyXml
    }
    catch {
        Write-Warning "Cannot pretty-print the XML data of the RAGS action ('$($_.Exception.Message)'); returning the raw decompressed value instead."
        return $xmlText
    }
}
