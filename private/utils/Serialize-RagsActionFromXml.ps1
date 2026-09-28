#Requires -Version 5.1
Set-StrictMode -Version Latest

function Serialize-RagsActionFromXml {
    <#
    .SYNOPSIS
    Serializes the XML representation of a RAGS action into its encoded form.

    .DESCRIPTION
    Serializes an XML snippet back into the encoded RAGS action form stored in
    columns tagged with the RagsAction handling instruction.

    The input is first verified to contain a well-formed XML snippet. The XML
    snippet is usually stored linearized (it is pretty-printed during
    deserialization), so it is linearized here before being encoded.

    The encoded value is a Base64-encoded binary stream with the following
    structure:

    - 4 bytes of padding at the start of the stream, storing the size of the
    subsequent GZip stream. RAGS Designer requires this information for its
    internal GZip decompression, so a static value is written by default
    ('FF FF FF 00' - 16777215 in little-endian unsigned int, sufficient for a
    16 MiB GZip stream). A larger value may be supplied for massively complex
    RAGS actions, up to 'FF FF FF 7F' (2147483647 in little-endian unsigned
    int, sufficient for a 2 GiB GZip stream); lowering the padding value below
    the default is not supported.
    - All subsequent bytes represent a standard GZip stream containing the
    XML snippet. The snippet is usually stored linearized, and is linearized
    here before compression; the stream is compressed with the default
    compression level.

    The XML snippet carries no XML declaration in the RAGS action format. A
    declaration present on the input snippet is nevertheless preserved
    verbatim at the start of the compressed payload, so snippets round-trip
    with or without one.

    .PARAMETER XmlRagsAction
    The XML snippet to serialize into its encoded RAGS action form. The value
    is verified to be a well-formed XML snippet before it is encoded; an XML
    declaration is optional.

    .PARAMETER CustomPaddingSize
    Optional value written to the 4-byte padding at the start of the stream.
    The value defaults to 16777215 ('FF FF FF 00' in little-endian unsigned
    int, sufficient for a 16 MiB GZip stream) and must be at least that;
    lowering the padding value below the default is not supported. The value
    must not exceed 2147483647 ('FF FF FF 7F' in little-endian unsigned int,
    sufficient for a 2 GiB GZip stream).

    .OUTPUTS
    System.String. The Base64-encoded RAGS action.

    .EXAMPLE
    PS> $encodedAction = Serialize-RagsActionFromXml -XmlRagsAction $actionXml

    Serializes the XML snippet in $actionXml into its Base64-encoded RAGS
    action form, using the default padding value.

    .EXAMPLE
    PS> $encodedAction = Serialize-RagsActionFromXml -XmlRagsAction $actionXml -CustomPaddingSize 536870912

    Serializes the XML snippet using a custom padding value advertising a
    capacity for a 512 MiB GZip stream.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlRagsAction,

        [Parameter()]
        [uint32]$CustomPaddingSize = 16777215
    )

    $minimumPaddingSize = 16777215
    $maximumPaddingSize = 2147483647

    if ($CustomPaddingSize -lt $minimumPaddingSize) {
        throw "Cannot serialize the RAGS action: the custom padding size $CustomPaddingSize is lower than the default value of $minimumPaddingSize; lowering the padding value below the default is not supported."
    }

    if ($CustomPaddingSize -gt $maximumPaddingSize) {
        throw "Cannot serialize the RAGS action: the custom padding size $CustomPaddingSize exceeds the maximum supported value of $maximumPaddingSize."
    }

    # Trim surrounding whitespace so that values carried over from pretty-
    # printed YAML files still parse.
    $xmlValue = $XmlRagsAction.Trim()

    if ([string]::IsNullOrEmpty($xmlValue)) {
        throw 'Cannot serialize the RAGS action: the input XML snippet is empty.'
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

        $message = "Cannot serialize the RAGS action: the input value '$displayValue' is not a well-formed XML snippet. "
        $message += "The XML parser reported the following error: '$($_.Exception.Message)'."

        throw [System.Exception]::new($message, $_.Exception)
    }

    # Linearize the XML snippet (it is usually stored linearized and was
    # pretty-printed during deserialization). A writer created over a string
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
        $message = 'Cannot serialize the RAGS action: the XML snippet could not be linearized. '
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
        # Default (Optimal) compression level, as recommended for serializing.
        $gzipStream = [System.IO.Compression.GZipStream]::new($compressedStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        $gzipStream.Write($xmlBytes, 0, $xmlBytes.Length)
        $gzipStream.Dispose()
        $gzipStream = $null
    }
    catch {
        $message = 'Cannot serialize the RAGS action: the XML snippet could not be GZip-compressed. '
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
        throw 'Cannot serialize the RAGS action: the GZip stream was empty.'
    }

    # RAGS Designer requires the advertised capacity to cover the GZip stream;
    # the default padding is sufficient for all but massively complex actions.
    if ($gzipBytes.Length -gt $CustomPaddingSize) {
        Write-Warning "The GZip stream of the serialized RAGS action is $($gzipBytes.Length) byte(s) long, which exceeds the $($CustomPaddingSize) byte(s) advertised by the padding value; consider increasing -CustomPaddingSize for massively complex RAGS actions."
    }

    # Assemble the padded stream: 4 bytes of little-endian padding followed by
    # the GZip stream, then Base64-encode the whole stream.
    $paddingBytes = [System.BitConverter]::GetBytes([uint32]$CustomPaddingSize)
    $ragsActionBytes = [byte[]]::new(4 + $gzipBytes.Length)
    [Array]::Copy($paddingBytes, 0, $ragsActionBytes, 0, 4)
    [Array]::Copy($gzipBytes, 0, $ragsActionBytes, 4, $gzipBytes.Length)

    Write-Verbose ("Serialized the RAGS action into a {0}-byte stream (4 padding bytes + {1} GZip byte(s)) with a padding value of {2} (0x{2:X8})." -f $ragsActionBytes.Length, $gzipBytes.Length, $CustomPaddingSize)

    return [System.Convert]::ToBase64String($ragsActionBytes)
}
