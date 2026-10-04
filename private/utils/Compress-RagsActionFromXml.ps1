#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-RagsActionFromXml {
    <#
    .SYNOPSIS
    Compresses the XML representation of a RAGS action into its encoded form.

    .DESCRIPTION
    Compresses an XML snippet back into the encoded RAGS action form stored in
    columns tagged with the RagsAction handling instruction.

    The input is first verified to contain a well-formed XML snippet. The XML
    snippet is usually stored linearized (it is pretty-printed during
    expansion), so it is linearized here before being encoded.

    The encoded value is a Base64-encoded binary stream with the following
    structure:

    - 4 bytes of padding at the start of the stream, storing the decompressed
    size of the subsequent GZip stream as a little-endian unsigned int. RAGS
    Designer requires this information for its internal GZip decompression,
    and the value is determined by the input XML size, with an additional
    1 MiB (1048576 bytes) added as buffer.
    - All subsequent bytes represent a standard GZip stream containing the
    XML snippet. The snippet is usually stored linearized, and is linearized
    here before compression; the stream is compressed with the default
    compression level.

    The XML snippet carries no XML declaration in the RAGS action format. A
    declaration present on the input snippet is nevertheless preserved
    verbatim at the start of the compressed payload, so snippets round-trip
    with or without one.

    .PARAMETER XmlRagsAction
    The XML snippet to compress into its encoded RAGS action form. The value
    is verified to be a well-formed XML snippet before it is encoded; an XML
    declaration is optional.

    .OUTPUTS
    System.String. The Base64-encoded RAGS action.

    .EXAMPLE
    PS> $encodedAction = Compress-RagsActionFromXml -XmlRagsAction $actionXml

    Compresses the XML snippet in $actionXml into its Base64-encoded RAGS
    action form, determining the 4-byte padding from the input XML size plus
    a 1 MiB buffer.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlRagsAction
    )

    # Trim surrounding whitespace so that values carried over from pretty-
    # printed YAML files still parse.
    $xmlValue = $XmlRagsAction.Trim()

    if ([string]::IsNullOrEmpty($xmlValue)) {
        throw 'Cannot compress the RAGS action: the input XML snippet is empty.'
    }

    # Verify that the input contains a well-formed XML snippet. The document
    # is kept around afterwards for linearization.
    $xmlDocument = [System.Xml.XmlDocument]::new()
    $xmlDocument.PreserveWhitespace = $false
    try {
        $xmlDocument.LoadXml($xmlValue)
    }
    catch {
        $displayValue =
            if ($xmlValue.Length -gt 64) {
                $xmlValue.Substring(0, 64) + '...'
            }
            else {
                $xmlValue
            }

        $message = "Cannot compress the RAGS action: the input value '$displayValue' is not a well-formed XML snippet. "
        $message += "The XML parser reported the following error: '$($_.Exception.Message)'."

        throw [System.Exception]::new($message, $_.Exception)
    }

    # Linearize the XML snippet (it is usually stored linearized and was
    # pretty-printed during expansion). A writer created over a string
    # builder regenerates the XML declaration with its own (wrong) encoding,
    # so the declaration is suppressed here; documents without one stay free
    # of one, and a declaration present on the input is preserved verbatim by
    # prepending it to the linearized body.
    $xmlDeclaration = $xmlDocument.FirstChild -as [System.Xml.XmlDeclaration]

    $writerSettings = [System.Xml.XmlWriterSettings]::new()
    $writerSettings.Indent = $false
    $writerSettings.IndentChars = '  '
    $writerSettings.NewLineHandling = [System.Xml.NewLineHandling]::None
    $writerSettings.OmitXmlDeclaration = $true

    $stringBuilder = [System.Text.StringBuilder]::new()
    $xmlWriter = $null
    try {
        $xmlWriter = [System.Xml.XmlWriter]::Create($stringBuilder, $writerSettings)
        $xmlDocument.Save($xmlWriter)
    }
    catch {
        $message = 'Cannot compress the RAGS action: the XML snippet could not be linearized. '
        $message += "The XML writer reported the following error: '$($_.Exception.Message)'."

        throw [System.Exception]::new($message, $_.Exception)
    }
    finally {
        if ($null -ne $xmlWriter) {
            $xmlWriter.Dispose()
        }
    }

    $linearXml = $stringBuilder.ToString()
    if ($null -ne $xmlDeclaration) {
        $linearXml = $xmlDeclaration.OuterXml + $linearXml
    }

    # Encode the payload as UTF-8 without a byte-order mark (GetBytes never
    # emits a preamble), matching how RAGS stores the XML payload.
    $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($linearXml)

    Write-Verbose "Compressing the $($xmlBytes.Length)-byte linearized XML snippet into a GZip stream."

    $compressedStream = $null
    $gzipStream = $null
    try {
        $compressedStream = [System.IO.MemoryStream]::new()
        # Default (Optimal) compression level, as recommended.
        $gzipStream = [System.IO.Compression.GZipStream]::new($compressedStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $gzipStream.Write($xmlBytes, 0, $xmlBytes.Length)
        $gzipStream.Dispose()
        $gzipStream = $null
    }
    catch {
        $message = 'Cannot compress the RAGS action: the XML snippet could not be GZip-compressed. '
        $message += "The GZip encoder reported the following error: '$($_.Exception.Message)'."

        throw [System.Exception]::new($message, $_.Exception)
    }
    finally {
        if ($null -ne $gzipStream) {
            $gzipStream.Dispose()
        }
        if ($null -ne $compressedStream) {
            $compressedStream.Dispose()
        }
    }

    # MemoryStream.ToArray remains callable after disposal.
    $gzipBytes = $compressedStream.ToArray()
    if ($gzipBytes.Length -eq 0) {
        throw 'Cannot compress the RAGS action: the GZip stream was empty.'
    }

    # The padding advertises the decompressed size of the GZip stream for
    # RAGS Designer's internal decompression. Following the RAGS Action format
    # specification, the value is determined by the input XML size with an
    # additional 1 MiB (1048576 bytes) added as buffer.
    $paddingBufferBytes = 1048576
    $paddedSize = [uint64]$xmlBytes.Length + $paddingBufferBytes
    if ($paddedSize -gt [uint32]::MaxValue) {
        throw "Cannot compress the RAGS action: the input XML size of $($xmlBytes.Length) byte(s) plus the 1 MiB padding buffer exceeds the largest value representable by the 4-byte padding (4294967295)."
    }

    # Assemble the padded stream: 4 bytes of little-endian padding followed by
    # the GZip stream, then Base64-encode the whole stream.
    $paddingBytes = [System.BitConverter]::GetBytes([uint32]$paddedSize)
    $ragsActionBytes = [byte[]]::new(4 + $gzipBytes.Length)
    [Array]::Copy($paddingBytes, 0, $ragsActionBytes, 0, 4)
    [Array]::Copy($gzipBytes, 0, $ragsActionBytes, 4, $gzipBytes.Length)

    Write-Verbose ("Compressed the RAGS action into a {0}-byte stream (4 padding bytes + {1} GZip byte(s)) with a padding value of {2} ({3} byte(s) of XML plus a 1 MiB buffer)." -f $ragsActionBytes.Length, $gzipBytes.Length, $paddedSize, $xmlBytes.Length)

    return [System.Convert]::ToBase64String($ragsActionBytes)
}
