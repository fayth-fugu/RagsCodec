#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-CharacterPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Expands CharacterProperties data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the CharacterProperties table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    the single 'CharacterProperties.yaml' file in the output folder,
    following the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'CharacterProperties' mapping
    whose value is a sequence with one entry per distinct Charname value.
    Each entry is a mapping of the Charname value and the Name key whose
    value is a sequence of mappings, one per CharacterProperties row of
    that character: each of those holds the property Name and its Value.
    The Value of a row is emitted as a YAML null when the column is null,
    and multi-line values are emitted as YAML literal block scalars whose
    line breaks were normalized to line-feed characters (YAML normalizes
    line breaks to line feeds when a literal block is read back, so
    carriage returns are normalized beforehand to keep the round-trip
    byte-exact).

    Rows are grouped by the exact Charname value: names differ in character
    case produce separate entries.

    Rows with a null, empty or whitespace-only Charname or Name value are
    skipped with a warning, as no meaningful entry or property key can be
    derived from them. Rows within one character which repeat an exact,
    previously read property Name are also skipped with a warning (the Value
    of the first read row wins): all rows are sorted first by Charname, then
    by Name and then by row ID, which both orders the reported rows and
    makes the winning row of such a duplicate deterministic. Property names
    which differ only in character case are distinct properties and never
    considered duplicates.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. An empty table expands to a
    top-level empty 'CharacterProperties' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded CharacterProperties data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the CharacterProperties data has been
    expanded successfully.

    .EXAMPLE
    Expand-CharacterPropertiesFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the CharacterProperties data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\CharacterProperties.yaml'
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
        throw "Cannot expand the CharacterProperties data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the CharacterProperties data into '$OutputPath'."

    # Read all rows of the table, ordered first by Charname, then by Name
    # and then by row ID, as documented. The Charname and Name columns of
    # the database are collated case-insensitively, so rows whose values
    # differ only in character case may interleave here and sort next to
    # each other; both cases are handled case-sensitively below.
    Write-Verbose 'Reading the CharacterProperties rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [Charname], [Name], [Value] FROM [CharacterProperties] ORDER BY [Charname] ASC, [Name] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) CharacterProperties row(s)."

    # Group the rows by the Charname value, case-sensitively by ordinal
    # comparison (the grouping happens here because SQL Server Compact
    # orders values case-insensitively, and PowerShell hashtables normalize
    # keys case-insensitively as well). Names and property entries are kept
    # as parallel lists so that the name lookup below can compare ordinally.
    # For a fixed exact name the rows arrive in ascending Name and row ID
    # order (the SQL sort is a total order and equal exact names are only
    # separated by their row IDs), so processing each row as it arrives
    # preserves the documented row order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupProperties = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $charname = $row['Charname']
        if (($null -eq $charname) -or ($charname -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$charname)) {
            Write-Warning "Skipping the CharacterProperties row (ID '$rowId'): the Charname value is null or empty, so no file entry can be derived for it."
            continue
        }
        $charname = [string]$charname

        $propertyName = $row['Name']
        if (($null -eq $propertyName) -or ($propertyName -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$propertyName)) {
            Write-Warning "Skipping the CharacterProperties row of character '$charname' (ID '$rowId'): the Name value is null or empty, so no property can be derived for it."
            continue
        }
        $propertyName = [string]$propertyName

        # Locate or create the case-sensitive group of the character.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $charname, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($charname)
            $groupProperties.Add([System.Collections.Generic.List[object]]::new())
        }
        $properties = $groupProperties[$groupIndex]

        # A null Value column is a meaningful property value (it is emitted
        # as a YAML null); every other value is read as a string whose line
        # breaks were normalized to line feed characters, because a YAML
        # literal block scalar normalizes line breaks that way when read
        # back. Values are never skipped.
        $propertyValue = $row['Value']
        if (($null -eq $propertyValue) -or ($propertyValue -is [System.DBNull])) {
            $propertyValue = $null
        }
        else {
            $propertyValue = ([string]$propertyValue) -replace '\r\n?', "`n"
        }

        # A null Value column is a meaningful property value (it is emitted
        # as a YAML null; see the normalization above, which is done before
        # the duplicate check so that its warning can report the value of
        # the ignored row).

        # Soft-validate the Unique Name column: the property Name of a
        # character is expected to contain only distinct values, so a row
        # which repeats the exact property name of a previously read row of
        # the same character is skipped with a warning (the value of the
        # first read row wins). Names which differ only in character case
        # are distinct properties.
        $duplicate = $false
        foreach ($existingProperty in $properties) {
            if ([string]::Equals([string]$existingProperty['Name'], $propertyName, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            Write-Warning "Skipping the CharacterProperties row of character '$charname' (ID '$rowId'): the property name '$propertyName' duplicates the property name of a previously read row (whose value wins). The ignored duplicate row has the value $(if ($null -eq $propertyValue) { '<null>' } else { [string]$propertyValue })."
            continue
        }

        # The property mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order) with a string-keyed access
        # to the Name value of the duplicate lookup above.
        $properties.Add([ordered]@{
            Name  = $propertyName
            Value = $propertyValue
        })
    }

    # Build the top-level entry list, one entry per character in first-row
    # order (= ascending Charname of the exact names, from the SQL sort).
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $entries.Add([ordered]@{
            Charname = $groupNames[$groupIndex]
            Name     = $groupProperties[$groupIndex].ToArray()
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequences of
    # the Name mapping entries are emitted indented, and repeated strings
    # are never collapsed into anchors/aliases. The sequence is wrapped in
    # a top-level 'CharacterProperties' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ CharacterProperties = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the CharacterProperties data of the RAGS file: the YAML content of the CharacterProperties data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'CharacterProperties.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) CharacterProperties row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the CharacterProperties data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}