#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-ItemPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Expands ItemProperties data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the ItemProperties table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    the single 'ItemProperties.yaml' file in the output folder, following
    the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'ItemProperties' mapping whose
    value is a sequence with one entry per distinct ItemID value. Each
    entry is a mapping of the ItemID value and the Name key whose value is
    a sequence of mappings, one per ItemProperties row of that item: each
    of those holds the property Name and its Value.

    Rows are grouped by the ItemID value case-insensitively, mirroring the
    case-insensitive collation of the database: ItemID values which differ
    only in character case belong to one and the same item. The casing of
    the first read row names the group (which case mate is read first is
    determined by the sorting rules of the table), and
    every later row whose ItemID differs from that group name only in
    character case is merged into the entry with a warning.

    The Value of a row is emitted as a YAML null when the column is null,
    and multi-line values are emitted as YAML literal block scalars whose
    line breaks were normalized to line-feed characters (YAML normalizes
    line breaks to line feeds when a literal block is read back, so
    carriage returns are normalized beforehand to keep the round-trip
    byte-exact).

    Rows with a null, empty or whitespace-only ItemID or Name value are
    skipped with a warning, as no meaningful entry or property key can be
    derived from them. Rows within one item which repeat an exact,
    previously read property Name are also skipped with a warning (the
    Value of the first read row wins): all rows are sorted first by
    ItemID, then by Name and then by row ID, which both orders the
    reported rows and makes the winning row of such a duplicate
    deterministic. Property names which differ only in character case are
    distinct properties and never considered duplicates.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one. An empty table
    expands to a top-level empty 'ItemProperties' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded ItemProperties data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemProperties data has been
    expanded successfully.

    .EXAMPLE
    Expand-ItemPropertiesFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the ItemProperties data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\ItemProperties.yaml'
    file.
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
        throw "Cannot expand the ItemProperties data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the ItemProperties data into '$OutputPath'."

    # Read all rows of the table, ordered first by ItemID, then by Name
    # and then by row ID, as documented. The ItemID and Name columns of
    # the database are collated case-insensitively, so rows whose values
    # differ only in character case may interleave here and sort next to
    # each other.
    Write-Verbose 'Reading the ItemProperties rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [ItemID], [Name], [Value] FROM [ItemProperties] ORDER BY [ItemID] ASC, [Name] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) ItemProperties row(s)."

    # Group the rows by the ItemID value case-insensitively (see above;
    # the grouping happens here because SQL Server Compact orders values
    # case-insensitively and PowerShell hashtables normalize keys
    # case-insensitively as well). Group names and per-item property lists
    # are kept as parallel lists so that the name lookup below can compare
    # each candidate with the case-insensitive contract, while the
    # duplicate check further down compares property names ordinally. For
    # a fixed case-insensitive item name the rows arrive in ascending Name
    # and row ID order (the SQL sort is a total order within a set of case
    # mates, separated by their property names and row IDs), so processing
    # each row as it arrives preserves the documented row order within
    # every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupProperties = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $itemId = $row['ItemID']
        if (($null -eq $itemId) -or ($itemId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$itemId)) {
            Write-Warning "Skipping the ItemProperties row (ID '$rowId'): the ItemID value is null or empty, so no file entry can be derived for it."
            continue
        }
        $itemId = [string]$itemId

        $propertyName = $row['Name']
        if (($null -eq $propertyName) -or ($propertyName -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$propertyName)) {
            Write-Warning "Skipping the ItemProperties row of item '$itemId' (ID '$rowId'): the Name value is null or empty, so no property can be derived for it."
            continue
        }
        $propertyName = [string]$propertyName

        # Locate or create the case-insensitive group of the item. A row
        # whose ItemID differs from the group name only in character case
        # is merged into the group with a warning; its property is written
        # into the same group under the group's casing.
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
            $groupProperties.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupNames[$groupIndex], $itemId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the ItemProperties row of item '$itemId' (ID '$rowId') into the entry of item '$($groupNames[$groupIndex])': the ItemID values differ only in character case."
        }
        $properties = $groupProperties[$groupIndex]

        # A null Value column is a meaningful property value (it is emitted
        # as a YAML null); every other value is read as a string whose line
        # breaks were normalized to line feed characters, because a YAML
        # literal block scalar normalizes line breaks that way when read
        # back. Values are never skipped. The normalized value is assigned
        # to a local before the duplicate check, so that the warning can
        # report the value of the ignored row itself.
        $propertyValue = $row['Value']
        if (($null -eq $propertyValue) -or ($propertyValue -is [System.DBNull])) {
            $propertyValue = $null
        }
        else {
            $propertyValue = ([string]$propertyValue) -replace '\r\n?', "`n"
        }

        # Soft-validate the Unique Name column: the property names of an
        # item are expected to contain only distinct values, so a row which
        # repeats the exact property name of a previously read row of the
        # same item is skipped with a warning (the value of the first read
        # row wins). Property names which differ only in character case
        # are distinct properties.
        $duplicate = $false
        foreach ($existingProperty in $properties) {
            if ([string]::Equals([string]$existingProperty['Name'], $propertyName, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            Write-Warning "Skipping the ItemProperties row of item '$itemId' (ID '$rowId'): the property name '$propertyName' duplicates the property name of a previously read row (whose value wins). The ignored duplicate row has the value $(if ($null -eq $propertyValue) { '<null>' } else { [string]$propertyValue })."
            continue
        }

        # The property mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order) with a string-keyed
        # access to the Name value of the duplicate lookup above.
        $properties.Add([ordered]@{
            Name  = $propertyName
            Value = $propertyValue
        })
    }

    # Build the top-level entry list, one entry per item in first-row
    # order (= ascending ItemID of the case-insensitive group names, from
    # the SQL sort).
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $entries.Add([ordered]@{
            ItemID = $groupNames[$groupIndex]
            Name   = $groupProperties[$groupIndex].ToArray()
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequences of
    # the Name mapping entries are emitted indented, and repeated strings
    # are never collapsed into anchors/aliases. The sequence is wrapped in
    # a top-level 'ItemProperties' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ ItemProperties = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the ItemProperties data of the RAGS file: the YAML content of the ItemProperties data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'ItemProperties.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) ItemProperties row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the ItemProperties data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}




