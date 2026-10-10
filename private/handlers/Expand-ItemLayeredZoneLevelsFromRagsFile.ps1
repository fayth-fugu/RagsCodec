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
    RAGS action decoding); embedded carriage returns are normalized to
    line-feed characters, because YAML literal block scalars normalize
    line breaks that way when read back. The Data values of an item are
    never deduplicated: every read row of an item contributes exactly one
    Data sequence entry, and identical values may repeat.

    Rows with a null, empty or whitespace-only ItemID or Data value are
    skipped with a warning, as no meaningful entry key or Data sequence
    entry can be derived from them.

    Rows whose ItemID values differ only in character case form one entry:
    the item identity of the layered zone level data is treated
    case-insensitively, matching the collation of the underlying database,
    which sorts such values together. The entry's ItemID key uses the
    casing that is read first (which is the case mate with the lowest row
    ID, since the table is sorted by ItemID and then by row ID), and every
    such row is reported with a warning describing the merge. Its Data
    value is appended to the same Data sequence.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. Rows of one item appear in
    the Data sequence in ascending row ID order. An empty table expands to
    a top-level empty 'ItemLayeredZoneLevels' sequence.

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

    # Read all rows of the table, ordered first by ItemID and then by row
    # ID, as documented. The ItemID column of the database is collated
    # case-insensitively, so rows of items whose names differ only in
    # character case may interleave here. Such rows are grouped
    # case-insensitively below (the item identity of the layered zone level
    # data is treated case-insensitively, matching that collation),
    # keeping every row in ascending ID order and the first-read casing as
    # the ItemID key (the SQL sort and row IDs make the first-read casing
    # the one with the lowest ID).
    Write-Verbose 'Reading the ItemLayeredZoneLevels rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [ItemID], [Data] FROM [ItemLayeredZoneLevels] ORDER BY [ItemID] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) ItemLayeredZoneLevels row(s)."

    # Group the rows by the ItemID value case-insensitively (see above;
    # the grouping happens here because SQL Server Compact orders values
    # case-insensitively). Group names and Data value lists are kept as
    # parallel lists so that the name lookup below can compare each
    # candidate with the case-insensitive contract. For a fixed
    # case-insensitive name the rows arrive in ascending ID order (the SQL
    # sort is a total order within a set of case mates, separated by row
    # IDs), so appending each Data value to its group as the rows arrive
    # preserves the documented row order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupDataValues = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $itemId = $row['ItemID']
        if (($null -eq $itemId) -or ($itemId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$itemId)) {
            Write-Warning "Skipping the ItemLayeredZoneLevels row (ID '$rowId'): the ItemID value is null or empty, so no file entry can be derived for it."
            continue
        }
        $itemId = [string]$itemId

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the ItemLayeredZoneLevels row of item '$itemId' (ID '$rowId'): the Data value is null or empty."
            continue
        }

        # Locate or create the case-insensitive group of the item. A row
        # whose ItemID differs from the group name only in character case
        # is merged into the group with a warning; its Data value is
        # written into the same Data sequence under the group's casing.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $itemId, [System.StringComparison]::OrdinalIgnoreCase)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($itemId)
            $groupDataValues.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupNames[$groupIndex], $itemId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the ItemLayeredZoneLevels row of item '$itemId' (ID '$rowId') into the entry of item '$($groupNames[$groupIndex])': the ItemID values differ only in character case."
        }

        # A YAML literal block scalar normalizes line breaks to line-feed
        # characters when the written YAML is read back, so carriage
        # returns are normalized away beforehand to keep the round-trip
        # byte-exact. The normalized value is assigned to a local first:
        # operator expressions passed directly as method arguments are
        # mis-tokenized as additional arguments on both hosts.
        $normalizedData = ([string]$data) -replace '\r\n?', "`n"
        $groupDataValues[$groupIndex].Add($normalizedData)
    }

    # Build the top-level entry list, one entry per item in first-row
    # order (= ascending ItemID of the case-insensitive group names, from
    # the SQL sort).
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

