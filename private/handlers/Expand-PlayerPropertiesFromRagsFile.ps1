#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-PlayerPropertiesFromRagsFile {
    <#
    .SYNOPSIS
    Expands PlayerProperties data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the PlayerProperties table of a RAGS file (schema version 2.6.1) through
    an open SQL Server Compact connection and expands the data into the
    single 'PlayerProperties.yaml' file in the output folder, following the
    conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'PlayerProperties' mapping whose value
    is a sequence with one entry per player property, each mapping the non-excluded
    columns of the PlayerProperties table: the Name key and the Value column value.
    Rows are read in the order the database returns them (the SELECT
    carries no ORDER BY; the table has no documented sort). A null Value
    value is emitted as the empty string; every other null column value is
    emitted as a YAML null.

    Rows are expected to hold distinct Name values: rows are read in the
    order the database returns them, so for every row after the first
    whose Name compares equal to a previously read row — comparing
    character case, per
    the 'Values are case-sensitive' Unique handling documented for the table
    (see the PlayerProperties section of docs/data-mapping.md) — the second and
    later rows of the pair are skipped with a warning which contains the column
    values of the ignored duplicate row ("A warning containing the values of
    subsequent ignored duplicate rows will be shown", docs/data-mapping.md,
    PlayerProperties section); the column values of the first read row win.
    Rows with a null, empty or whitespace-only Name value are also skipped
    with a warning, as no player property entry can be derived from them.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. An empty table expands to a
    top-level empty 'PlayerProperties' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded PlayerProperties data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the PlayerProperties data has been
    expanded successfully.

    .EXAMPLE
    Expand-PlayerPropertiesFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the PlayerProperties data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\PlayerProperties.yaml' file.
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
        throw "Cannot expand the PlayerProperties data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the PlayerProperties data into '$OutputPath'."

    # Read all rows of the table in the order the database returns them
    # (no ORDER BY; the table has no documented sort). The Name column of
    # the database is collated case-insensitively, so rows whose names
    # differ only in character case may return adjacent to each other;
    # duplicates among them are dropped case-SENSITIVELY below, in the
    # read order of the rows, so the first read row among identical names
    # wins and names which differ only in character case produce distinct
    # entries.
    Write-Verbose 'Reading the PlayerProperties rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [Name], [Value] FROM [PlayerProperties]')
    Write-Verbose "Read $($rows.Count) PlayerProperties row(s)."

    # The Name values of the player properties whose entries were built, kept
    # in a separate list so that the duplicate check below can compare
    # case-SENSITIVELY (the documented Unique handling of the table —
    # "If multiple identical Names exist, then only the Value of the first
    # row will be read" with "Values are case-sensitive", see the
    # PlayerProperties section of docs/data-mapping.md).
    $admittedNames = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$name)) {
            Write-Warning "Skipping the PlayerProperties row (ID '$rowId'): the Name value is null or empty, so no player property entry can be derived for it."
            continue
        }
        $name = [string]$name

        # A null Value value is written as the empty string. The Value value
        # is staged verbatim (its line breaks are kept; the literal block's
        # reading rule drifts them to line feeds only when the written file
        # is parsed again), and the raw value is kept alongside because the
        # duplicate warning below cites it (a null keeps its '<null>'
        # citation even though its emitted value is the empty string). The
        # value is read before the duplicate check so that the warning
        # below never reads a value of a previous iteration.
        $value = $row['Value']
        if (($null -eq $value) -or ($value -is [System.DBNull])) {
            $value = $null
        }
        else {
            $value = [string]$value
        }
        $valueRaw = $value
        if ($null -eq $value) {
            $value = ''
        }

        # Soft-validate the Unique Name column: a row whose value compares
        # equal to a previously read row's value, comparing character case, is
        # skipped with a warning containing the column values of the ignored
        # duplicate row ("A warning containing the values of subsequent
        # ignored duplicate rows will be shown", docs/data-mapping.md,
        # PlayerProperties section; the column values of the first read row
        # win).
        $duplicate = $false
        foreach ($existingName in $admittedNames) {
            if ([string]::Equals($existingName, $name, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            if ($null -eq $valueRaw) { $valueEvidence = 'Value <null>' } else { $valueEvidence = 'Value ' + $valueRaw }

            Write-Warning "Skipping the PlayerProperties row (ID '$rowId'): the Name value '$name' duplicates the Name value of a previously read row (whose column values win). The ignored duplicate row has the column values Name '$name', $valueEvidence."
            continue
        }

        $admittedNames.Add($name)

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $entries.Add([ordered]@{
            Name  = $name
            Value = $value
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
    # player property entries is emitted indented, and repeated strings are
    # never collapsed into anchors/aliases. The sequence is wrapped in a
    # top-level 'PlayerProperties' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ PlayerProperties = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the PlayerProperties data of the RAGS file: the YAML content of the PlayerProperties data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'PlayerProperties.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) player property entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) PlayerProperties row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the PlayerProperties data into $($entries.Count) player property entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

