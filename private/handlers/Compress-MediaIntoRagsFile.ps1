#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-MediaIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses Media data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded Media data of a source folder back into the
    Media table of a RAGS file (schema version 2.6.1) through an open SQL
    Server Compact connection, appending the compressed rows as the
    inverse of Expand-MediaFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    Every '.yaml' file of the 'Media' subfolder of the source folder is
    read as a YAML document mapping a media Name value to the other eight
    columns of the Media table (BackgroundColor, TextColor, TextFont,
    ImageName, UseEnhancedGraphics, NewImage, Data, GroupName). One row is
    appended per file (the table has no identity column to supply),
    replicating the row set of the original expansion.

    The YAML files of the subfolder are consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents. A file which carries an empty or
      comment-only stream aborts the whole operation with an exception.
    - The file names are never interpreted (the Media expansion writes
      them from the derived GUID of the Name value): the Name value of
      the contents is the truth, so a file which is not named like its
      derived GUID is still a perfectly valid source.
    - A YAML document which is not a mapping (for example a scalar or a
      sequence), a Name value which is neither a scalar nor a string, a
      text column value which is a sequence or a mapping, a bit column
      value which is neither a boolean nor the integer 0 or 1, a Data
      value which is not a string scalar and not null, and a Data string
      which the Base64 decoder cannot read abort the whole operation with
      an exception, as no meaningful media row can be derived from them.
    - A mapping defining keys other than the nine column names of the
      table is accepted with one warning naming the unexpected keys; the
      unexpected keys are ignored.
    - A file whose Name value is missing, null, empty or whitespace-only
      is skipped in its entirety with a warning, as no media can be
      derived from it (its row may therefore not survive a compress/expand
      cycle and its column values are discarded).
    - A Name value longer than the 250 characters of the table column is
      truncated with a warning; note that re-expanding the appended data
      then derives a different file name from the truncated value (the
      file name GUID is derived from the stored truncated value).
    - The List-column values of the Media table are documented as
      case-insensitive and always coerced to lowercase ('Values are
      case-insensitive' / 'Always coerced to lowercase' in the Media
      section of docs/data-mapping.md), so every accepted Name value is
      lowercased with ToLowerInvariant (after its truncation, before the
      duplicate check), and every appended row carries the lowercased
      form (the re-expansion of the appended data lowercases its read
      values anyway, so these rows re-expand with their Name value
      unchanged).
    - A file whose lowercased Name value was already contributed by a
      previously read file is skipped in its entirety with a warning
      which cites the column values of the ignored duplicate file, as
      only one row can be stored per media Name (the 'If multiple
      identical Names exist, then only the first row's column values will
      be read' Unique rule of the docs). The first-read file of a set of
      duplicate names is decided by the ordinal file name order, so
      hand-made files can steal the admission from an expansion-written
      GUID-named file, which the re-expansion of the appended rows
      reproduces faithfully. The Data value of the ignored duplicate file
      is deliberately not cited, as the documentation exempts it ('The
      value of the Data column will not be shown in the warning', Media
      section of docs/data-mapping.md).
    - A text column value (BackgroundColor, TextColor, TextFont,
      ImageName, NewImage, GroupName) which is missing or null is stored
      as the empty string without a warning, mirroring the null-string
      emission rule of the expansion (a null column value is emitted as
      the empty string). A scalar of any other type (an
      unquoted integer or decimal, for example) is coerced to its
      invariant string form with a warning; a sequence or a mapping
      throws. A value longer than the maximum length of the table column
      is truncated with a warning. The text column values are stored
      verbatim: no line-ending normalization is applied, mirroring the
      expansion, which emits the column values verbatim (a multi-line
      value written as a YAML literal block re-parses with LF line
      endings through the YAML reader, so the appended row stores the
      parsed form, which re-expands verbatim and re-parses to the same
      LF-headed value).
    - The UseEnhancedGraphics bit column value which is missing or null
      is stored as the false the documented bit mapping reads a null at
      ('0 and null values are mapped to false, while 1 is mapped to
      true', docs/data-mapping.md), without a warning, as the expansion
      of a null bit column emits a YAML false. A boolean value is stored
      as read; an integer of the value 1 or 0 is coerced with a warning
      (the integer forms are hand-written values the expansion never
      emits); any other value throws.
    - The Data column holds the media byte stream (an 'image' table
      column; 'The binary stream is Base64-encoded during expansion',
      docs/data-mapping.md). A Data value which is missing or null is
      stored as a database null without a warning, as the expansion emits
      a YAML null for a missing byte stream. The Base64 form is decoded
      with the tolerant whitespace handling of the .NET decoder, so
      embedded line breaks and other whitespace are accepted where the
      format allows them; a string which the decoder cannot read throws,
      and a string which contains invalid Base64 characters throws as
      well. An empty or whitespace-only string is stored as an empty byte
      stream, as the expansion emits an empty string for an empty byte
      stream. A scalar of any other type (an unquoted integer, for
      example) is coerced to its invariant string form with a warning
      and decoded like a string; a sequence or a mapping throws.
    - Every file of the subfolder is read, validated and decoded before
      the first row is appended, so the table remains empty when the
      source folder carries invalid content. The appended rows are then
      written inside a transaction, so a failure while appending leaves
      no partially appended data behind.

    The Media subfolder is read silently; a missing source folder or
    subfolder is not an error and compresses nothing. Files of any other
    extension are skipped with a warning.

    Compressed rows are appended to the Media table, which is expected to
    receive them (the RAGS Designer workflow of compressing expanded data
    keeps the convention of starting from the template file, or a
    blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run, and the appended duplicate Name
    values replicate the read-order duplicates of the docs' Unique rule
    on re-expansion.

    .PARAMETER SourcePath
    Path of the folder to compress the Media data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Media data has been compressed
    successfully.

    .EXAMPLE
    Compress-MediaIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the Media data of the 'C:\Export\MyGame' folder to the RAGS
    file connected through $openRagsConnection.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot compress the Media data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'Media' subfolder: no
    # expansion may have happened yet, in which case there is nothing to
    # compress.
    $mediaFolder = Join-Path $SourcePath 'Media'
    if (-not (Test-Path -LiteralPath $mediaFolder -PathType Container)) {
        Write-Verbose "The source folder carries no 'Media' subfolder, so there is no Media data to compress."
        return $true
    }
    Write-Verbose "Compressing the Media data of the RAGS file from '$mediaFolder'."

    # Collect the files of the subfolder in file name order, so that the
    # first-read file of a set of duplicate media Name values is decided
    # by a stable and reproducible order (see the duplicate check below).
    # The names are sorted ordinally, so that the order does not depend on
    # the culture of the host. The expansion writes everything as '.yaml'
    # files; anything else is skipped with a warning.
    Write-Verbose "Reading the YAML files of '$mediaFolder'."
    $filesByName = @{}
    foreach ($foundFile in @(Get-ChildItem -LiteralPath $mediaFolder -File)) {
        $filesByName[$foundFile.Name] = $foundFile
    }
    $yamlFileNames = [System.Collections.Generic.List[string]]::new()
    foreach ($foundFileName in $filesByName.Keys) {
        $yamlFileNames.Add($foundFileName)
    }
    $yamlFileNames.Sort([System.StringComparer]::Ordinal)
    Write-Verbose "Found $($yamlFileNames.Count) file(s) in the 'Media' subfolder."

    # Stage one row before appending anything, so that nothing is written
    # when any source file carries invalid content (all-or-nothing, like
    # the expansion). Every staged value carries the source file name for
    # the messages of the append phase and the nine column values of the
    # row. The validation of every column is performed inline below, so
    # that each file is fully validated (and every failure reported)
    # before any file contributes rows.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingFileNames = [System.Collections.Generic.List[string]]::new()

    # The lowercased Name values of the media whose rows were staged, kept
    # in a separate list so that the duplicate check below can compare the
    # already-lowercased values with ordinal comparisons ("If multiple
    # identical Names exist, then only the first row's column values will
    # be read" with "Values are case-insensitive" and "Always coerced to
    # lowercase", see the Media section of docs/data-mapping.md) - a file
    # whose lowercased Name was already staged contributes nothing, in the
    # ordinal file name order fixed by the sort above.
    $admittedNames = [System.Collections.Generic.List[string]]::new()

    foreach ($yamlFileName in $yamlFileNames) {
        $file = $filesByName[$yamlFileName]
        if (-not [System.String]::Equals($file.Extension, '.yaml', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Skipping the file '$($file.Name)' of the Media subfolder: it does not have a '.yaml' extension."
            continue
        }

        # Read the whole file as text ([System.IO.File]::ReadAllText
        # auto-detects the UTF-8/UTF-16 byte-order marks and defaults to
        # UTF-8, which matches the encoding the expansion writes).
        try {
            $fileText = [System.IO.File]::ReadAllText($file.FullName)
        }
        catch {
            $message = "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder could not be read. "
            $message += "The file system reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        if ([string]::IsNullOrWhiteSpace($fileText)) {
            throw "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder is empty."
        }

        # Parse the file as a YAML multi-document stream. A file which
        # defines more than one document is consumed from its first
        # document only, with a warning about the extra documents (the
        # expansion writes exactly one mapping per file, so extra
        # documents in a source folder are usually leftovers of a manual
        # edit).
        try {
            $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
        }
        catch {
            $message = "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder is not a valid YAML document. "
            $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # ConvertFrom-Yaml returns the parsed value of a single document
        # directly (a mapping, a sequence or a scalar, as read), the
        # values of multiple documents as an object array, and no value at
        # all for an empty stream - an empty or comment-only stream can
        # never produce a mapping, so it aborts the operation.
        if ($parsedDocuments.Count -gt 1) {
            Write-Warning "The file '$($file.Name)' of the Media subfolder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
        }
        if ($parsedDocuments.Count -lt 1) {
            throw "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder carries no YAML document."
        }

        $mapping = $parsedDocuments[0]
        if ($null -eq $mapping) {
            throw "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder carries no YAML document."
        }
        if ($mapping -isnot [System.Collections.IDictionary]) {
            if ($mapping -is [string]) {
                $actualType = 'a scalar'
            }
            elseif ($mapping -is [System.Collections.IList]) {
                $actualType = 'a sequence'
            }
            else {
                $actualType = "a value of type '$($mapping.GetType().FullName)'"
            }

            throw "Cannot compress the Media data of the RAGS file: the file '$($file.Name)' of the Media subfolder carries $actualType where a mapping is expected."
        }

        # Resolve the nine column values of the mapping by key, so that
        # the key comparison does not depend on the dictionary semantics
        # of the YAML reader: the expansion writes the nine column names
        # exactly, and any other key (a case variant included) counts as
        # unexpected.
        $nameValue = $null
        $backgroundColorValue = $null
        $textColorValue = $null
        $textFontValue = $null
        $imageNameValue = $null
        $useEnhancedGraphicsValue = $null
        $newImageValue = $null
        $dataValue = $null
        $groupNameValue = $null
        $unexpectedKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($documentKey in $mapping.Keys) {
            $documentKeyText = [string]$documentKey
            if ([string]::Equals($documentKeyText, 'Name', [System.StringComparison]::Ordinal)) {
                $nameValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'BackgroundColor', [System.StringComparison]::Ordinal)) {
                $backgroundColorValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'TextColor', [System.StringComparison]::Ordinal)) {
                $textColorValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'TextFont', [System.StringComparison]::Ordinal)) {
                $textFontValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'ImageName', [System.StringComparison]::Ordinal)) {
                $imageNameValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'UseEnhancedGraphics', [System.StringComparison]::Ordinal)) {
                $useEnhancedGraphicsValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'NewImage', [System.StringComparison]::Ordinal)) {
                $newImageValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'Data', [System.StringComparison]::Ordinal)) {
                $dataValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'GroupName', [System.StringComparison]::Ordinal)) {
                $groupNameValue = $mapping[$documentKey]
            }
            else {
                $unexpectedKeys.Add($documentKeyText)
            }
        }
        if ($unexpectedKeys.Count -gt 0) {
            $unexpectedKeyText = ($unexpectedKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The file '$($file.Name)' of the Media subfolder defines the unexpected key(s) $unexpectedKeyText; they are ignored."
        }

        # Locate and validate the Name value of the mapping, which is
        # expected to be the string scalar the expansion wrote. A scalar of
        # any other type (a hand-edited unquoted number, for example) is
        # coerced to its invariant string form with a warning.
        if ($null -eq $nameValue) {
            Write-Warning "Skipping the file '$($file.Name)' of the Media subfolder: the Name value is missing or null, so no media can be derived for it."
            continue
        }
        if ($nameValue -is [System.Collections.IList]) {
            throw "Cannot compress the Media data of the RAGS file: the Name value of the file '$($file.Name)' carries a sequence where a scalar value is expected."
        }
        if ($nameValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Media data of the RAGS file: the Name value of the file '$($file.Name)' carries a mapping where a scalar value is expected."
        }
        if ($nameValue -isnot [string]) {
            Write-Warning "The Name value of the file '$($file.Name)' is of type '$($nameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($nameValue -is [System.IFormattable]) {
                $nameValue = $nameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $nameValue = [string]$nameValue
            }
        }
        if ([string]::IsNullOrWhiteSpace($nameValue)) {
            Write-Warning "Skipping the file '$($file.Name)' of the Media subfolder: the Name value is empty, so no media can be derived for it."
            continue
        }

        # Truncate the Name value to the length of the table column, as a
        # longer value could not be stored. The truncation runs before the
        # lowercasing and the duplicate check below, so that the stored
        # value is what they validate; the re-expansion of the appended
        # data derives the file name GUID from the lowercased truncated
        # value, not from the original one.
        $name = $nameValue
        if ($name.Length -gt 250) {
            Write-Warning "The Name value of the file '$($file.Name)' is $($name.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different file name from the truncated value."
            $name = $name.Substring(0, 250)
        }

        # The List-column values of the Media table are documented as
        # case-insensitive and always coerced to lowercase ('Values are
        # case-insensitive' / 'Always coerced to lowercase' in the Media
        # section of docs/data-mapping.md), so the truncated value is
        # lowered with ToLowerInvariant (the invariant result is
        # independent of the current culture). Everything below - the
        # duplicate check and the appended row - works with and cites this
        # lowercased form. The expansion of the appended data lowercases
        # its read values anyway, so the lowercased rows re-expand with
        # their Name value unchanged.
        $name = $name.ToLowerInvariant()

        # A file whose lowercased Name value was already staged contributes
        # nothing (as only one row can be stored per Name: "If multiple
        # identical Names exist, then only the first row's column values
        # will be read", docs/data-mapping.md, Media section), and the
        # ignored duplicate file is skipped with a warning which cites the
        # column values its row would have won with (the Data column is
        # deliberately absent from the evidence, "The value of the Data
        # column will not be shown in the warning"). The first-read file of
        # a set of duplicate names is fixed by the ordinal file name order,
        # so the warning is emitted before the remaining column values are
        # validated, in the read order of the files.
        $duplicate = $false
        foreach ($existingName in $admittedNames) {
            if ([string]::Equals($existingName, $name, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            Write-Warning "Skipping the file '$($file.Name)' of the Media subfolder: the Name value '$name' duplicates the Name value of a previously read file (whose column values win). The column values of the ignored duplicate file are validated with the column rules below, but never staged."
            continue
        }
        $admittedNames.Add($name)

        # Validate the six text column values (BackgroundColor, TextColor,
        # TextFont, ImageName, NewImage, GroupName) with the shared scalar
        # ladder: missing or null is stored as the empty string without a
        # warning, mirroring the null-string emission rule of the
        # expansion (a null column value is emitted as the empty string);
        # a string is stored as read (verbatim: no line-ending
        # normalization, mirroring the expansion's verbatim emission); a
        # scalar of any other type is coerced to its invariant string form
        # with a warning; a sequence or a mapping throws. Each value is
        # truncated to the maximum length of its table column with a
        # warning.
        $backgroundColor = ''
        if ($null -ne $backgroundColorValue) {
            if ($backgroundColorValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the BackgroundColor of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($backgroundColorValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the BackgroundColor of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($backgroundColorValue -isnot [string]) {
                Write-Warning "The BackgroundColor of the file '$($file.Name)' of media '$name' is of type '$($backgroundColorValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($backgroundColorValue -is [System.IFormattable]) {
                    $backgroundColor = $backgroundColorValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $backgroundColor = [string]$backgroundColorValue
                }
            }
            else {
                $backgroundColor = $backgroundColorValue
            }
            if ($backgroundColor.Length -gt 250) {
                Write-Warning "The BackgroundColor of the file '$($file.Name)' of media '$name' is $($backgroundColor.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $backgroundColor = $backgroundColor.Substring(0, 250)
            }
        }

        $textColor = ''
        if ($null -ne $textColorValue) {
            if ($textColorValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the TextColor of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($textColorValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the TextColor of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($textColorValue -isnot [string]) {
                Write-Warning "The TextColor of the file '$($file.Name)' of media '$name' is of type '$($textColorValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($textColorValue -is [System.IFormattable]) {
                    $textColor = $textColorValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $textColor = [string]$textColorValue
                }
            }
            else {
                $textColor = $textColorValue
            }
            if ($textColor.Length -gt 250) {
                Write-Warning "The TextColor of the file '$($file.Name)' of media '$name' is $($textColor.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $textColor = $textColor.Substring(0, 250)
            }
        }

        $textFont = ''
        if ($null -ne $textFontValue) {
            if ($textFontValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the TextFont of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($textFontValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the TextFont of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($textFontValue -isnot [string]) {
                Write-Warning "The TextFont of the file '$($file.Name)' of media '$name' is of type '$($textFontValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($textFontValue -is [System.IFormattable]) {
                    $textFont = $textFontValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $textFont = [string]$textFontValue
                }
            }
            else {
                $textFont = $textFontValue
            }
            if ($textFont.Length -gt 250) {
                Write-Warning "The TextFont of the file '$($file.Name)' of media '$name' is $($textFont.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $textFont = $textFont.Substring(0, 250)
            }
        }

        $imageName = ''
        if ($null -ne $imageNameValue) {
            if ($imageNameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the ImageName of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($imageNameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the ImageName of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($imageNameValue -isnot [string]) {
                Write-Warning "The ImageName of the file '$($file.Name)' of media '$name' is of type '$($imageNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($imageNameValue -is [System.IFormattable]) {
                    $imageName = $imageNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $imageName = [string]$imageNameValue
                }
            }
            else {
                $imageName = $imageNameValue
            }
            if ($imageName.Length -gt 250) {
                Write-Warning "The ImageName of the file '$($file.Name)' of media '$name' is $($imageName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $imageName = $imageName.Substring(0, 250)
            }
        }

        $newImage = ''
        if ($null -ne $newImageValue) {
            if ($newImageValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the NewImage of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($newImageValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the NewImage of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($newImageValue -isnot [string]) {
                Write-Warning "The NewImage of the file '$($file.Name)' of media '$name' is of type '$($newImageValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($newImageValue -is [System.IFormattable]) {
                    $newImage = $newImageValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $newImage = [string]$newImageValue
                }
            }
            else {
                $newImage = $newImageValue
            }
            if ($newImage.Length -gt 250) {
                Write-Warning "The NewImage of the file '$($file.Name)' of media '$name' is $($newImage.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $newImage = $newImage.Substring(0, 250)
            }
        }

        $groupName = ''
        if ($null -ne $groupNameValue) {
            if ($groupNameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the GroupName of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($groupNameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the GroupName of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            if ($groupNameValue -isnot [string]) {
                Write-Warning "The GroupName of the file '$($file.Name)' of media '$name' is of type '$($groupNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($groupNameValue -is [System.IFormattable]) {
                    $groupName = $groupNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $groupName = [string]$groupNameValue
                }
            }
            else {
                $groupName = $groupNameValue
            }
            if ($groupName.Length -gt 255) {
                Write-Warning "The GroupName of the file '$($file.Name)' of media '$name' is $($groupName.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $groupName = $groupName.Substring(0, 255)
            }
        }

        # The UseEnhancedGraphics bit column: a boolean is stored as read;
        # a missing or null value is stored as the documented false ('0 and
        # null values are mapped to false, while 1 is mapped to true',
        # docs/data-mapping.md) without a warning, as the expansion of a
        # null bit column emits a YAML false; an integer of the value 1 or
        # 0 is coerced with a warning; anything else throws.
        $useEnhancedGraphics = $false
        if ($null -ne $useEnhancedGraphicsValue) {
            if ($useEnhancedGraphicsValue -is [bool]) {
                $useEnhancedGraphics = $useEnhancedGraphicsValue
            }
            elseif ($useEnhancedGraphicsValue -is [int]) {
                if ($useEnhancedGraphicsValue -eq 1) {
                    Write-Warning "The UseEnhancedGraphics of the file '$($file.Name)' of media '$name' is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $useEnhancedGraphics = $true
                }
                elseif ($useEnhancedGraphicsValue -eq 0) {
                    Write-Warning "The UseEnhancedGraphics of the file '$($file.Name)' of media '$name' is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $useEnhancedGraphics = $false
                }
                else {
                    throw "Cannot compress the Media data of the RAGS file: the UseEnhancedGraphics of the file '$($file.Name)' of media '$name' is of type '$($useEnhancedGraphicsValue.GetType().FullName)' and its value cannot be read as one of the two boolean states."
                }
            }
            else {
                throw "Cannot compress the Media data of the RAGS file: the UseEnhancedGraphics of the file '$($file.Name)' of media '$name' is of type '$($useEnhancedGraphicsValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        # The Data column is the binary image column of the table ('The
        # binary stream is Base64-encoded during expansion',
        # docs/data-mapping.md): a missing or null value is stored as a
        # database null; an empty or whitespace-only string is stored as
        # an empty byte stream; every other string is trimmed and decoded
        # through the tolerant whitespace handling of the .NET decoder
        # (embedded line breaks and other whitespace between the Base64
        # groups are accepted); a scalar of any other type is coerced to
        # its invariant string form with a warning and decoded like a
        # string; a sequence or a mapping throws. A string the decoder
        # cannot read aborts the operation.
        $data = $null
        if ($null -ne $dataValue) {
            if ($dataValue -is [System.Collections.IList]) {
                throw "Cannot compress the Media data of the RAGS file: the Data of the file '$($file.Name)' of media '$name' carries a sequence where a scalar value is expected."
            }
            if ($dataValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Media data of the RAGS file: the Data of the file '$($file.Name)' of media '$name' carries a mapping where a scalar value is expected."
            }
            $dataText = $null
            if ($dataValue -is [string]) {
                $dataText = $dataValue
            }
            else {
                Write-Warning "The Data of the file '$($file.Name)' of media '$name' is of type '$($dataValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($dataValue -is [System.IFormattable]) {
                    $dataText = $dataValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $dataText = [string]$dataValue
                }
            }

            $trimmedDataText = $dataText.Trim()
            if ($trimmedDataText.Length -gt 0) {
                try {
                    $data = [System.Convert]::FromBase64String($trimmedDataText)
                }
                catch [System.FormatException] {
                    throw "Cannot compress the Media data of the RAGS file: the Data of the file '$($file.Name)' of media '$name' is not a valid Base64-encoded byte stream. The decoder reported the following error: '$($_.Exception.Message)'."
                }
            }
            else {
                $data = [byte[]]::new(0)
            }
        }

        # Stage the row of the file with its nine column values.
        $stagedRows.Add([pscustomobject]@{
            Name = $name
            BackgroundColor = $backgroundColor
            TextColor = $textColor
            TextFont = $textFont
            ImageName = $imageName
            UseEnhancedGraphics = $useEnhancedGraphics
            NewImage = $newImage
            Data = $data
            GroupName = $groupName
            FileName = $file.Name
        })
        if (-not $contributingFileNames.Contains($file.Name)) {
            $contributingFileNames.Add($file.Name)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the Media table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the RAGS media byte streams are far
        # beyond any quoting limit (and the text values are not SQL
        # literals either). The staged text values are always strings (a
        # null source value stages the empty string), while the missing
        # Data value is expressed with [System.DBNull]::Value, as a raw
        # $null means 'not supplied' to the SQL Server Compact parameter
        # binding; the byte-array Data value is assigned through the
        # branch structure directly, as the if-statement pipeline form
        # would enumerate the array into an object array which the Image
        # parameter refuses.
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the row of the file '$($stagedRow.FileName)' of media '$($stagedRow.Name)' to the Media table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [Media] ([Name], [BackgroundColor], [TextColor], [TextFont], [ImageName], [UseEnhancedGraphics], [NewImage], [Data], [GroupName]) VALUES (@name, @bgcolor, @textcolor, @textfont, @imagename, @enhanced, @newimage, @data, @groupname)'

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 250)
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $bgParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@bgcolor', [System.Data.SqlDbType]::NVarChar, 250)
                    # The staged text values are always strings (a null
                    # source value stages the empty string), so the text
                    # parameters bind their staged values directly; the
                    # Data parameter keeps its database-null branch.
                    $bgParameter.Value = $stagedRow.BackgroundColor
                    $null = $command.Parameters.Add($bgParameter)

                    $fgParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@textcolor', [System.Data.SqlDbType]::NVarChar, 250)
                    $fgParameter.Value = $stagedRow.TextColor
                    $null = $command.Parameters.Add($fgParameter)

                    $fontParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@textfont', [System.Data.SqlDbType]::NVarChar, 250)
                    $fontParameter.Value = $stagedRow.TextFont
                    $null = $command.Parameters.Add($fontParameter)

                    $imgParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@imagename', [System.Data.SqlDbType]::NVarChar, 250)
                    $imgParameter.Value = $stagedRow.ImageName
                    $null = $command.Parameters.Add($imgParameter)

                    $enhancedParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enhanced', [System.Data.SqlDbType]::Bit)
                    $enhancedParameter.Value = $stagedRow.UseEnhancedGraphics
                    $null = $command.Parameters.Add($enhancedParameter)

                    $newImgParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@newimage', [System.Data.SqlDbType]::NVarChar, 250)
                    $newImgParameter.Value = $stagedRow.NewImage
                    $null = $command.Parameters.Add($newImgParameter)

                    $dataParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@data', [System.Data.SqlDbType]::Image)
                    if ($null -eq $stagedRow.Data) { $dataParameter.Value = [System.DBNull]::Value } else { $dataParameter.Value = [byte[]]$stagedRow.Data }
                    $null = $command.Parameters.Add($dataParameter)

                    $groupParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@groupname', [System.Data.SqlDbType]::NVarChar, 255)
                    $groupParameter.Value = $stagedRow.GroupName
                    $null = $command.Parameters.Add($groupParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the Media table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The Media transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the Media data of the RAGS file: the staged rows could not be appended to the Media table. "
            $message += "The database reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }
        finally {
            if ($null -ne $transaction) {
                $transaction.Dispose()
            }
        }
    }
    else {
        Write-Verbose 'No rows were staged, so no transaction is opened.'
    }

    Write-Verbose "Compressed the Media data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingFileNames.Count) file(s)."
    return $true
}

