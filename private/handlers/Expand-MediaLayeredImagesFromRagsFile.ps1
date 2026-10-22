#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-MediaLayeredImagesFromRagsFile {
    <#
    .SYNOPSIS
    Expands MediaLayeredImages data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the MediaLayeredImages table of a RAGS file (schema version
    2.6.1) through an open SQL Server Compact connection and expands the
    data into the single 'MediaLayeredImages.yaml' file in the output
    folder, following the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'MediaLayeredImages' mapping
    whose value is a sequence with one entry per distinct MediaName value.
    Each entry is a mapping of the MediaName value and the Order key whose
    value is a sequence of mappings, one per MediaLayeredImages row of
    that media name: each of those holds the row's Order value and its
    Data value.

    Rows whose MediaName values differ only in character case form one
    entry: the media name identity of the layered image data is treated
    case-insensitively ('Values are case-insensitive',
    docs/data-mapping.md, MediaLayeredImages section), and every read
    MediaName value is normalized to lowercase ('Always coerced to
    lowercase', docs/data-mapping.md, MediaLayeredImages section): after
    the null and empty checks, the value is lowercased with
    ToLowerInvariant, so the entry's MediaName key is always the lowercase
    form of the value. The case mate whose raw casing is read first (which
    is the case mate with the lowest Order and then the lowest row ID,
    since the table is sorted by MediaName, then by Order and then by row
    ID) opens the entry, and every later row whose raw MediaName value
    differs from that first-read raw value only in character case is
    merged into the entry with a warning describing the merge; its layer
    is written into the same Order sequence. Every warning and verbose
    message of the expansion cites the lowercased MediaName value.

    Rows with a null, empty or whitespace-only MediaName value are
    skipped with a warning, as no meaningful file entry can be derived
    from them. Rows with a null, empty or whitespace-only Data value are
    skipped with a warning, as no meaningful layer Data can be derived
    from them. Rows with a null Order value are skipped with a warning,
    as no layer can be derived from them. Rows within one media name
    which repeat an exact, previously read Order value are also skipped
    with a warning (the Data of the first read row wins): all rows are
    sorted first by MediaName, then by Order and then by row ID, which
    both orders the reported rows and makes the winning row of such a
    duplicate deterministic. Order values of different media names are
    independent and never compared against each other.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one. Rows of one media
    name appear in the Order sequence in ascending Order and row ID order.
    An empty table expands to a top-level empty 'MediaLayeredImages'
    sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded MediaLayeredImages data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the MediaLayeredImages data has
    been expanded successfully.

    .EXAMPLE
    Expand-MediaLayeredImagesFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the MediaLayeredImages data of the RAGS file connected through
    $openRagsConnection into the
    'C:\Export\MyGame\MediaLayeredImages.yaml' file.
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
        throw "Cannot expand the MediaLayeredImages data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the MediaLayeredImages data into '$OutputPath'."

    # Read all rows of the table, ordered first by MediaName, then by
    # Order and then by row ID ('Table is sorted first by MediaName
    # ascending, then by Order ascending, then by ID ascending',
    # docs/data-mapping.md, MediaLayeredImages section). The MediaName
    # column of the database is collated case-insensitively, so rows whose
    # values differ only in character case may interleave here and sort
    # next to each other, separated by their Order and row ID values.
    Write-Verbose 'Reading the MediaLayeredImages rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [MediaName], [Order], [Data] FROM [MediaLayeredImages] ORDER BY [MediaName] ASC, [Order] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) MediaLayeredImages row(s)."

    # Group the rows by their lowercased MediaName value ('Always coerced
    # to lowercase', docs/data-mapping.md, MediaLayeredImages section; the
    # grouping happens here because SQL Server Compact orders values
    # case-insensitively). Group names are the canonical lowercased values
    # and are looked up ordinally, and the first-read raw value of every
    # group is kept alongside, so that the merge comparison below can
    # detect the rows whose raw casing differs from the first-read one.
    # Group names, first-read raw names and per-media layer lists are kept
    # as parallel lists, while the duplicate check further down compares
    # Order values with integer equality. For a fixed lowercased media
    # name the rows arrive in ascending Order and row ID order (the SQL
    # sort is a total order within a set of case mates, separated by their
    # Order and row ID values), so processing each row as it arrives
    # preserves the documented row order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupLayers = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $mediaName = $row['MediaName']
        if (($null -eq $mediaName) -or ($mediaName -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$mediaName)) {
            Write-Warning "Skipping the MediaLayeredImages row (ID '$rowId'): the MediaName value is null or empty, so no file entry can be derived for it."
            continue
        }
        # The MediaName values are always coerced to lowercase ('Always
        # coerced to lowercase', docs/data-mapping.md, MediaLayeredImages
        # section): the raw value is kept for the merge comparison below,
        # and every later use (the entry key and the citations of the
        # warnings and verbose messages) gets the lowercased form.
        $rawMediaName = [string]$mediaName
        $mediaName = $rawMediaName.ToLowerInvariant()

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the MediaLayeredImages row of media name '$mediaName' (ID '$rowId'): the Data value is null or empty."
            continue
        }

        $layerOrder = $row['Order']
        if (($null -eq $layerOrder) -or ($layerOrder -is [System.DBNull])) {
            Write-Warning "Skipping the MediaLayeredImages row of media name '$mediaName' (ID '$rowId'): the Order value is null, so no layer can be derived from it."
            continue
        }

        # Locate or create the group of the media name by its lowercased
        # value (an ordinal lookup: two lowercased values are the same
        # group exactly when they are equal). A row whose raw MediaName
        # value differs from the first-read raw value of the group only in
        # character case is merged into the group with a warning; its
        # layer is written into the same Order sequence under the
        # lowercased group key.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $mediaName, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($mediaName)
            $groupRawNames.Add($rawMediaName)
            $groupLayers.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawMediaName, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the MediaLayeredImages row of media name '$mediaName' (ID '$rowId') into the entry of media name '$($groupNames[$groupIndex])': the raw MediaName value differs only in character case and is merged into the lowercased entry key."
        }
        $layers = $groupLayers[$groupIndex]

        # The Data value is always coerced to lowercase ('Always coerced
        # to lowercase', docs/data-mapping.md, MediaLayeredImages section)
        # and staged verbatim, original line breaks included; a YAML
        # literal block scalar normalizes a written value's line breaks to
        # line feeds only when the written YAML is read back. The
        # lowercased value is assigned to a local before the duplicate
        # check, so that the warning can report the lowercased Data value
        # of the ignored row itself (a local assigned later in the same
        # iteration would silently hold the previous row's value), and
        # because operator expressions passed directly as method
        # arguments are mis-tokenized as additional arguments on both
        # hosts. The lowercasing is silent: the emitted entry simply
        # carries the lowercase form.
        $stagedData = ([string]$data).ToLowerInvariant()

        # Soft-validate the Unique Order column: the Order values within a
        # media name are expected to contain only distinct values ('If
        # multiple identical Orders exist for the same MediaName value,
        # then only the Data of the first row will be read',
        # docs/data-mapping.md, MediaLayeredImages section), so a row
        # which repeats the exact Order value of a previously read row of
        # the same media name is skipped with a warning (the Data of the
        # first read row wins). A NULL Order never reaches this check (it
        # is skipped above). Order values of different media names are
        # never compared against each other. The comparison uses integer
        # equality, never string equality, so that string representations
        # of the same number can arise only from the database itself.
        $duplicate = $false
        foreach ($existingLayer in $layers) {
            if ([int]$existingLayer['Order'] -eq [int]$layerOrder) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            Write-Warning "Skipping the MediaLayeredImages row of media name '$mediaName' (ID '$rowId'): the Order value $layerOrder duplicates the Order value of a previously read row (whose Data wins). The ignored duplicate row has the Data value '$stagedData'."
            continue
        }

        # The layer mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order) with an integer-keyed
        # access to the Order value of the duplicate lookup above.
        $layers.Add([ordered]@{
            Order = [int]$layerOrder
            Data  = $stagedData
        })
    }

    # Build the top-level entry list, one entry per media name in
    # first-row order (= ascending lowercased MediaName of the
    # case-insensitive group names, from the SQL sort).
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $entries.Add([ordered]@{
            MediaName = $groupNames[$groupIndex]
            Order     = $groupLayers[$groupIndex].ToArray()
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequences of
    # the Order mapping entries are emitted indented, and repeated strings
    # are never collapsed into anchors/aliases. The sequence is wrapped in
    # a top-level 'MediaLayeredImages' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ MediaLayeredImages = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the MediaLayeredImages data of the RAGS file: the YAML content of the MediaLayeredImages data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'MediaLayeredImages.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) MediaLayeredImages row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the MediaLayeredImages data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

