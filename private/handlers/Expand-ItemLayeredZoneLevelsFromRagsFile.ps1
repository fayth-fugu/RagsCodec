#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-ItemLayeredZoneLevelsFromRagsFile {
    <#
    .SYNOPSIS
    Expands ItemLayeredZoneLevels data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the ItemLayeredZoneLevels table of a RAGS file (schema version
    2.6.1) through an open SQL Server Compact connection and expands the
    data into the single 'ItemLayeredZoneLevels.yaml' file in the output
    folder, following the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'ItemLayeredZoneLevels' mapping
    whose value is a sequence with one entry per distinct ItemID value.
    Each entry is a mapping of the ItemID value and the Data key whose
    value is a sequence of strings, one per ItemLayeredZoneLevels row of
    that item. Unlike the ItemActions data, the Data column of this table
    is a plain string column whose value is written verbatim (without
    RAGS action decoding), original line breaks included; a YAML literal
    block scalar normalizes a written value's line breaks to line feeds
    only when the written YAML is read back. The Data values of an item are
    never deduplicated: every read row of an item contributes exactly one
    Data sequence entry, and identical values may repeat.

    Rows with a null, empty or whitespace-only ItemID or Data value are
    skipped with a warning, as no meaningful entry key or Data sequence
    entry can be derived from them.

    Rows whose ItemID values differ only in character case form one entry:
    the item identity of the layered zone level data is treated
    case-insensitively ('Values are case-insensitive',
    docs/data-mapping.md, ItemLayeredZoneLevels section), and every read
    ItemID value is normalized to lowercase ('Always coerced to
    lowercase', docs/data-mapping.md, ItemLayeredZoneLevels section):
    after the null and empty checks, the value is lowercased with
    ToLowerInvariant, so the entry's ItemID key is always the lowercase
    form of the value. The case mate whose raw casing is read first (the
    first read row of the unsorted read result) opens the entry, and
    every later row whose raw ItemID value differs from that first-read
    raw value only in character case is merged into the entry with a
    warning describing the merge; its Data value is appended to the same
    Data sequence. Every warning and verbose message of the expansion
    cites the lowercased ItemID value.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. Rows of one item appear in
    the Data sequence in read order. An empty table expands to a
    top-level empty 'ItemLayeredZoneLevels' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded ItemLayeredZoneLevels data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemLayeredZoneLevels data has
    been expanded successfully.

    .EXAMPLE
    Expand-ItemLayeredZoneLevelsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the ItemLayeredZoneLevels data of the RAGS file connected through
    $openRagsConnection into the
    'C:\Export\MyGame\ItemLayeredZoneLevels.yaml' file.
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
        throw "Cannot expand the ItemLayeredZoneLevels data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the ItemLayeredZoneLevels data into '$OutputPath'."

    # Read all rows of the table in the order the database returns them
    # (no ORDER BY; the table has no documented sort). The ItemID column
    # of the database is collated case-insensitively, so rows of items
    # whose names differ only in character case may return in any relative
    # order. Such rows are grouped by their lowercased values below
    # ('Values are case-insensitive' and 'Always coerced to lowercase',
    # docs/data-mapping.md, ItemLayeredZoneLevels section), keeping every
    # row in read order and the first-read raw casing for the merge
    # comparisons.
    Write-Verbose 'Reading the ItemLayeredZoneLevels rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [ItemID], [Data] FROM [ItemLayeredZoneLevels]')
    Write-Verbose "Read $($rows.Count) ItemLayeredZoneLevels row(s)."

    # Group the rows by their lowercased ItemID value ('Always coerced to
    # lowercase', docs/data-mapping.md, ItemLayeredZoneLevels section; the
    # grouping happens here because SQL Server Compact orders values
    # case-insensitively). Group names are the canonical lowercased values
    # and are looked up ordinally, and the first-read raw value of every
    # group is kept alongside, so that the merge comparison below can
    # detect the rows whose raw casing differs from the first-read one.
    # Group names, first-read raw names and Data value lists are kept as
    # parallel lists. Appending each Data value to its group as the rows
    # arrive preserves the read order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupDataValues = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $itemId = $row['ItemID']
        if (($null -eq $itemId) -or ($itemId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$itemId)) {
            Write-Warning "Skipping the ItemLayeredZoneLevels row (ID '$rowId'): the ItemID value is null or empty, so no file entry can be derived for it."
            continue
        }
        # The ItemID values are always coerced to lowercase ('Always
        # coerced to lowercase', docs/data-mapping.md, ItemLayeredZoneLevels
        # section): the raw value is kept for the merge comparison below,
        # and every later use (the entry key and the citations of the
        # warnings and verbose messages) gets the lowercased form.
        $rawItemId = [string]$itemId
        $itemId = $rawItemId.ToLowerInvariant()

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the ItemLayeredZoneLevels row of item '$itemId' (ID '$rowId'): the Data value is null or empty."
            continue
        }

        # Locate or create the group of the item by its lowercased value
        # (an ordinal lookup: two lowercased values are the same group
        # exactly when they are equal). A row whose raw ItemID value
        # differs from the first-read raw value of the group only in
        # character case is merged into the group with a warning; its Data
        # value is written into the same Data sequence under the
        # lowercased group key.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $itemId, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($itemId)
            $groupRawNames.Add($rawItemId)
            $groupDataValues.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawItemId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the ItemLayeredZoneLevels row of item '$itemId' (ID '$rowId') into the entry of item '$($groupNames[$groupIndex])': the raw ItemID value differs only in character case and is merged into the lowercased entry key."
        }

        # The Data value is staged verbatim, original line breaks included;
        # a YAML literal block scalar normalizes a written value's line
        # breaks to line feeds only when the written YAML is read back.
        # The value is assigned to a local first, as operator expressions
        # passed directly as method arguments are mis-tokenized as
        # additional arguments on both hosts.
        $stagedData = [string]$data
        $groupDataValues[$groupIndex].Add($stagedData)
    }

    # Build the top-level entry list, one entry per item in first-read
    # order.
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $entries.Add([ordered]@{
            ItemID = $groupNames[$groupIndex]
            Data   = $groupDataValues[$groupIndex].ToArray()
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequences of
    # the Data mapping entries are emitted indented, and repeated strings
    # are never collapsed into anchors/aliases. The sequence is wrapped in
    # a top-level 'ItemLayeredZoneLevels' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ ItemLayeredZoneLevels = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the ItemLayeredZoneLevels data of the RAGS file: the YAML content of the ItemLayeredZoneLevels data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'ItemLayeredZoneLevels.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) ItemLayeredZoneLevels row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the ItemLayeredZoneLevels data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

