#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-MediaFromRagsFile {
    <#
    .SYNOPSIS
    Expands Media data from a RagsFile into YAML files.

    .DESCRIPTION
    Reads the Media table of a RAGS file (schema version 2.6.1) through an
    open SQL Server Compact connection and expands the data into one YAML
    file per media entry, written into the 'Media' subfolder of the output
    folder, following the conventions documented in docs/data-mapping.md.

    Each file is named by the GUID derived from the Name value: the UTF-8
    encoded bytes of the value are MD5-hashed and the resulting 16-byte
    digest is used directly as the GUID (see ConvertTo-RagsFilenameGuid and
    the GUID file name generation rule of docs/data-mapping.md), whose
    lowercase, dash-separated string form is followed by a lowercase '.yaml'
    extension. The file contains a mapping with the nine columns of the
    Media table in their documented sample-structure order. The Data column
    holds the media byte stream, which is Base64 encoded (without line
    breaks) into a plain string value (the binary image data documented as
    Base64-encoded in docs/data-mapping.md); a missing byte stream is
    emitted as a YAML null and an empty byte stream is emitted as an empty
    string. The UseEnhancedGraphics flag column is emitted as a YAML
    boolean where a missing value is read as false (the documented flag
    mapping). Every other column value is emitted as a plain string or, if
    missing, as the empty string.

    A media Name is always emitted in the lowercased form the table's
    Unique handling documents ('Values are case-insensitive' / 'Always
    coerced to lowercase', see the Media section of docs/data-mapping.md),
    and the GUID naming the file is derived from that lowercased form as
    well.

    Rows are expected to hold distinct Name values: the table is sorted by
    Name ascending ('Table is sorted by Name ascending',
    docs/data-mapping.md, Media section) before it is read, so for every
    media after the first whose Name compares equal to a previously read
    media — ignoring character case, per the Unique handling quoted above —
    the second and later rows are skipped with a warning which contains the
    column values of the ignored duplicate row, as the documentation
    requires ('A warning containing the values of subsequent ignored
    duplicate rows will be shown'); the column values of the first read row
    win. The value of the Data column is deliberately left out of that
    warning, as the documentation explicitly exempts it ('The value of the
    Data column will not be shown in the warning'). Rows with a null, empty
    or whitespace-only Name value are also skipped with a warning, as no
    file name and no media entry can be derived from them.

    The Media table has no identity column which could label the rows of a
    duplicate or null-Name warning, so such warnings refer to the position
    of the row in the read result instead.

    The subfolder and its parent folders are created silently when missing,
    and written files silently overwrite existing ones. The expansion is
    all-or-nothing: every YAML content is serialized before the first file
    is written, so a serialization failure leaves no file behind.

    .PARAMETER OutputPath
    Path of the folder to export the expanded Media data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Media data has been expanded
    successfully.

    .EXAMPLE
    Expand-MediaFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the Media data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\Media' folder.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot expand the Media data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the 'Media' subfolder when it is missing (this also
    # creates the output folder itself and any missing parents).
    $mediaFolder = Join-Path $OutputPath 'Media'
    $null = New-Item -ItemType Directory -Force -Path $mediaFolder
    Write-Verbose "Expanding the Media data into '$mediaFolder'."

    # Read all rows of the table, ordered by Name ascending ("Table is
    # sorted by Name ascending", docs/data-mapping.md, Media section; the
    # SELECT reads every column because the table has neither an
    # Exclude-tagged nor an identity column). The Name column of the
    # database is collated case-insensitively, so rows of media whose names
    # differ only in character case sort next to each other here (their
    # relative read order is the engine's tiebreak); duplicates among them
    # are dropped case-insensitively below, in the read order of the rows.
    Write-Verbose 'Reading the Media rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [Name], [BackgroundColor], [TextColor], [TextFont], [ImageName], [UseEnhancedGraphics], [NewImage], [Data], [GroupName] FROM [Media] ORDER BY [Name] ASC')
    Write-Verbose "Read $($rows.Count) Media row(s)."

    # The Media table has no identity column which could label the rows of
    # a duplicate or null-Name warning, so such warnings refer to the
    # position of the row in the read result instead.
    $readRowNumber = 0

    # The lowercased Name values of the media whose files were built, kept
    # in a separate list so that the duplicate check below can compare the
    # already-lowercased values with ordinal comparisons ("If multiple
    # identical Names exist, then only the first row's column values will
    # be read" with "Values are case-insensitive" and "Always coerced to
    # lowercase", see the Media section of docs/data-mapping.md).
    $admittedNames = [System.Collections.Generic.List[string]]::new()
    $fileEntries = [System.Collections.Generic.List[object]]::new()
    $fileNames = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $rows) {
        $readRowNumber++

        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$name)) {
            Write-Warning "Skipping the Media row $($readRowNumber) of the read result: the Name value is null or empty, so no file name can be derived for it."
            continue
        }

        # The documented Unique handling of this table always coerces the
        # Name values to lowercase ("Always coerced to lowercase",
        # docs/data-mapping.md, Media section - as the documentation
        # requires): entries are keyed and files named by the lowercased
        # value, and the duplicate check below therefore compares the
        # normalized values with ordinal comparisons.
        $name = ([string]$name).ToLowerInvariant()

        # A null column value is written as a YAML null, except for the
        # UseEnhancedGraphics bit column, where a null is written as a YAML
        # false (documented flag mapping), and except for the six string
        # columns, where a null is written as the empty string. The Data
        # column holds the media byte stream: a missing value is written
        # as a YAML null, and a present value is Base64 encoded (without
        # line breaks) into the plain string value that is emitted. Every
        # value is computed before the duplicate check so that the
        # warnings below never read a value of a previous iteration (the
        # stale-variable rule), and the duplicate warning cites the raw
        # value of the ignored row (a null keeps its '<null>' citation
        # even though its emitted value is the empty string).
        $backgroundColor = $row['BackgroundColor']
        if (($null -eq $backgroundColor) -or ($backgroundColor -is [System.DBNull])) {
            $backgroundColor = $null
        }
        else {
            $backgroundColor = [string]$backgroundColor
        }
        $backgroundColorRaw = $backgroundColor
        if ($null -eq $backgroundColor) {
            $backgroundColor = ''
        }

        $textColor = $row['TextColor']
        if (($null -eq $textColor) -or ($textColor -is [System.DBNull])) {
            $textColor = $null
        }
        else {
            $textColor = [string]$textColor
        }
        $textColorRaw = $textColor
        if ($null -eq $textColor) {
            $textColor = ''
        }

        $textFont = $row['TextFont']
        if (($null -eq $textFont) -or ($textFont -is [System.DBNull])) {
            $textFont = $null
        }
        else {
            $textFont = [string]$textFont
        }
        $textFontRaw = $textFont
        if ($null -eq $textFont) {
            $textFont = ''
        }

        $imageName = $row['ImageName']
        if (($null -eq $imageName) -or ($imageName -is [System.DBNull])) {
            $imageName = $null
        }
        else {
            $imageName = [string]$imageName
        }
        $imageNameRaw = $imageName
        if ($null -eq $imageName) {
            $imageName = ''
        }

        # The managed reader returns bit columns as Boolean values; a
        # missing value is read as the documented false. The duplicate
        # warning below accordingly cites these values as read at this
        # point ('after reading'): a row storing a null is reported with
        # the false it was read as, never with the null it holds.
        $useEnhancedGraphics = $row['UseEnhancedGraphics']
        if (($null -eq $useEnhancedGraphics) -or ($useEnhancedGraphics -is [System.DBNull])) {
            $useEnhancedGraphics = $false
        }

        $newImage = $row['NewImage']
        if (($null -eq $newImage) -or ($newImage -is [System.DBNull])) {
            $newImage = $null
        }
        else {
            $newImage = [string]$newImage
        }
        $newImageRaw = $newImage
        if ($null -eq $newImage) {
            $newImage = ''
        }

        # The Data column is the binary image column of the table; the
        # managed reader materializes a present value as a byte stream
        # (System.Byte[]) and a missing value as System.DBNull.
        $rawData = $row['Data']
        if (($null -eq $rawData) -or ($rawData -is [System.DBNull])) {
            $data = $null
        }
        else {
            $data = [System.Convert]::ToBase64String([byte[]]$rawData, [System.Base64FormattingOptions]::None)
        }

        $groupName = $row['GroupName']
        if (($null -eq $groupName) -or ($groupName -is [System.DBNull])) {
            $groupName = $null
        }
        else {
            $groupName = [string]$groupName
        }
        $groupNameRaw = $groupName
        if ($null -eq $groupName) {
            $groupName = ''
        }

        # Soft-validate the Unique Name column: a row whose value compares
        # equal to a previously read row's value, ignoring character case
        # (the values are already normalized to lowercase above), is
        # skipped with a warning naming the column values of the ignored
        # duplicate row ("A warning containing the values of subsequent
        # ignored duplicate rows will be shown", docs/data-mapping.md,
        # Media section; the column values of the first read row win). The
        # documented Data-column exemption keeps the (potentially large)
        # byte stream out of the evidence ("The value of the Data column
        # will not be shown in the warning").
        $duplicate = $false
        foreach ($existingName in $admittedNames) {
            if ([string]::Equals($existingName, $name, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $backgroundColorRaw) { $evidenceParts.Add('BackgroundColor <null>') } else { $evidenceParts.Add('BackgroundColor ''' + $backgroundColorRaw + '''') }
            if ($null -eq $textColorRaw) { $evidenceParts.Add('TextColor <null>') } else { $evidenceParts.Add('TextColor ''' + $textColorRaw + '''') }
            if ($null -eq $textFontRaw) { $evidenceParts.Add('TextFont <null>') } else { $evidenceParts.Add('TextFont ''' + $textFontRaw + '''') }
            if ($null -eq $imageNameRaw) { $evidenceParts.Add('ImageName <null>') } else { $evidenceParts.Add('ImageName ''' + $imageNameRaw + '''') }
            $evidenceParts.Add('UseEnhancedGraphics equals ' + $useEnhancedGraphics + ' after reading')
            if ($null -eq $newImageRaw) { $evidenceParts.Add('NewImage <null>') } else { $evidenceParts.Add('NewImage ''' + $newImageRaw + '''') }
            if ($null -eq $groupNameRaw) { $evidenceParts.Add('GroupName <null>') } else { $evidenceParts.Add('GroupName ''' + $groupNameRaw + '''') }

            Write-Warning "Skipping the Media row $($readRowNumber) of the read result: the Name value '$name' duplicates the Name value of a previously read row (whose column values win). The ignored duplicate row has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedNames.Add($name)

        # The file name derives from the lowercased Name value through the
        # same GUID algorithm the documentation pins for this table (the
        # UTF-8 encoded bytes of the value are MD5-hashed and the digest is
        # used directly as the GUID).
        $fileName = (ConvertTo-RagsFilenameGuid -Value $name) + '.yaml'

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $fileEntries.Add([ordered]@{
            Name                = $name
            BackgroundColor     = $backgroundColor
            TextColor           = $textColor
            TextFont            = $textFont
            ImageName           = $imageName
            UseEnhancedGraphics = $useEnhancedGraphics
            NewImage            = $newImage
            Data                = $data
            GroupName           = $groupName
        })
        $fileNames.Add($fileName)
    }

    # Serialize every file content BEFORE the first file is written, so a
    # serialization failure leaves the subfolder without any file behind
    # (the all-or-nothing rule of the sibling expansions). Roundtrip +
    # DisableAliases + WithIndentedSequences: the entries are emitted
    # indented and repeated strings are never collapsed into anchors or
    # aliases.
    $fileYamls = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $fileEntries) {
        $fileYaml = ConvertTo-Yaml -Data $entry -Options 35

        # ConvertTo-Yaml reports .NET serialization failures by emitting the
        # error record to the output pipeline instead of throwing, so the
        # returned value is validated to guard against mistaking such a
        # failure for YAML content.
        if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
            throw 'Cannot expand the Media data of the RAGS file: the YAML content of the Media data could not be serialized.'
        }
        $fileYamls.Add($fileYaml)
    }

    $fileIndex = 0
    foreach ($fileName in $fileNames) {
        $filePath = Join-Path $mediaFolder $fileName
        Write-Verbose "Writing '$filePath'."
        [System.IO.File]::WriteAllText($filePath, $fileYamls[$fileIndex], [System.Text.UTF8Encoding]::new($false))
        $fileIndex++
    }

    Write-Verbose "Expanded the Media data into $($fileEntries.Count) file$(if ($fileEntries.Count -ne 1) { 's' }) for $($rows.Count) Media row(s)."
    return $true
}
