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

    Rows whose ItemID values differ only in character case form one entry:
    the item identity of the property data is treated case-insensitively
    ('Values are case-insensitive', docs/data-mapping.md, ItemProperties
    section), and every read ItemID value is normalized to lowercase
    ('Always coerced to lowercase', docs/data-mapping.md, ItemProperties
    section): after the null and empty checks, the value is lowercased
    with ToLowerInvariant, so the entry's ItemID key is always the
    lowercase form of the value. The case mate whose raw casing is read
    first (which is the case mate with the lowest property Name and then
    the lowest row ID, since the table is sorted by ItemID, then by Name
    and then by row ID) opens the entry, and every later row whose raw
    ItemID value differs from that first-read raw value only in character
    case is merged into the entry with a warning describing the merge; its
    property is written into the same property sequence. Every warning and
    verbose message of the expansion cites the lowercased ItemID value.

    The Value of a row is emitted as the empty string when the column is
    null, and multi-line values are emitted as YAML literal block scalars.
    YAML
    normalizes a literal block's line breaks to line feeds when the
    written YAML is read back, so a read-back value carries the line-feed
    form of whatever line breaks the table stores; the value itself is
    emitted verbatim.

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
    # and then by row ID ('Table is sorted first by ItemID ascending, then
    # by Name ascending, then by ID ascending', docs/data-mapping.md,
    # ItemProperties section). The ItemID and Name columns of the database
    # are collated case-insensitively, so rows whose values differ only in
    # character case may interleave here and sort next to each other.
    Write-Verbose 'Reading the ItemProperties rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [ItemID], [Name], [Value] FROM [ItemProperties] ORDER BY [ItemID] ASC, [Name] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) ItemProperties row(s)."

    # Group the rows by their lowercased ItemID value ('Always coerced to
    # lowercase', docs/data-mapping.md, ItemProperties section; the
    # grouping happens here because SQL Server Compact orders values
    # case-insensitively). Group names are the canonical lowercased values
    # and are looked up ordinally, and the first-read raw value of every
    # group is kept alongside, so that the merge comparison below can
    # detect the rows whose raw casing differs from the first-read one.
    # Group names, first-read raw names and per-item property lists are
    # kept as parallel lists, while the duplicate check further down
    # compares property names ordinally. For a fixed lowercased item name
    # the rows arrive in ascending Name and row ID order (the SQL sort is
    # a total order within a set of case mates, separated by their
    # property names and row IDs), so processing each row as it arrives
    # preserves the documented row order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupProperties = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $itemId = $row['ItemID']
        if (($null -eq $itemId) -or ($itemId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$itemId)) {
            Write-Warning "Skipping the ItemProperties row (ID '$rowId'): the ItemID value is null or empty, so no file entry can be derived for it."
            continue
        }
        # The ItemID values are always coerced to lowercase ('Always
        # coerced to lowercase', docs/data-mapping.md, ItemProperties
        # section): the raw value is kept for the merge comparison below,
        # and every later use (the entry key and the citations of the
        # warnings and verbose messages) gets the lowercased form.
        $rawItemId = [string]$itemId
        $itemId = $rawItemId.ToLowerInvariant()

        $propertyName = $row['Name']
        if (($null -eq $propertyName) -or ($propertyName -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$propertyName)) {
            Write-Warning "Skipping the ItemProperties row of item '$itemId' (ID '$rowId'): the Name value is null or empty, so no property can be derived for it."
            continue
        }
        $propertyName = [string]$propertyName

        # Locate or create the group of the item by its lowercased value
        # (an ordinal lookup: two lowercased values are the same group
        # exactly when they are equal). A row whose raw ItemID value
        # differs from the first-read raw value of the group only in
        # character case is merged into the group with a warning; its
        # property is written into the same property sequence under the
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
            $groupProperties.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawItemId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the ItemProperties row of item '$itemId' (ID '$rowId') into the entry of item '$($groupNames[$groupIndex])': the raw ItemID value differs only in character case and is merged into the lowercased entry key."
        }
        $properties = $groupProperties[$groupIndex]

        # A null Value column is a meaningful property value (it is
        # emitted as the empty string); every other value is read as a
        # string and staged verbatim (a YAML literal block scalar
        # normalizes a written value's line breaks to line feeds only
        # when the written YAML is read back). Values are never skipped.
        # The value is assigned to a local before the duplicate check, so
        # that the warning can report the raw value of the ignored row
        # itself (a null keeps its '<null>' citation even though its
        # emitted value is the empty string).
        $propertyValue = $row['Value']
        if (($null -eq $propertyValue) -or ($propertyValue -is [System.DBNull])) {
            $propertyValue = $null
        }
        else {
            $propertyValue = [string]$propertyValue
        }
        $propertyValueRaw = $propertyValue
        if ($null -eq $propertyValue) {
            $propertyValue = ''
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
            Write-Warning "Skipping the ItemProperties row of item '$itemId' (ID '$rowId'): the property name '$propertyName' duplicates the property name of a previously read row (whose value wins). The ignored duplicate row has the value $(if ($null -eq $propertyValueRaw) { '<null>' } else { [string]$propertyValueRaw })."
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
    # order (= ascending lowercased ItemID of the case-insensitive group
    # names, from the SQL sort).
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




