#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-StatusBarItemsFromRagsFile {
    <#
    .SYNOPSIS
    Expands StatusBarItems data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the StatusBarItems table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    the single 'StatusBarItems.yaml' file in the output folder, following
    the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'StatusBarItems' mapping whose
    value is a sequence with one entry per status bar item, each mapping
    the non-excluded columns of the StatusBarItems table: the Name key, the
    Text value, the Width value and the Visible value. Rows are read in
    the order the database returns them (the SELECT carries no ORDER BY;
    the table has no documented sort). A null string column
    value (the Name key and the Text value) is emitted as the empty
    string; a null Width value is emitted as a YAML null; and the Visible
    bit column would emit $false for a null value (though the column is
    NOT NULL in the schema, so a null never occurs through the documented
    data path).

    Rows are expected to hold distinct Name values: rows are read in the
    order the database returns them, so for every row after the first
    whose Name
    compares equal to a previously read row — ignoring character case, per
    the 'Values are case-insensitive' / 'Only the first detected casing
    will be read' Unique handling documented for the table (see the
    StatusBarItems section of docs/data-mapping.md, and the
    'StatusBarItems.Name' breaking-change convention which keeps the first
    instance of any status bar item name stored verbatim and discards
    every subsequent case-insensitive repeat) — the second and later rows
    are skipped with a warning which contains the column values of the
    ignored duplicate row ("A warning containing the values of subsequent
    ignored duplicate rows will be shown", docs/data-mapping.md,
    StatusBarItems section); the column values of the first read row win.

    Rows with a null, empty or whitespace-only Name value are NOT skipped:
    unlike the entry-keyed tables whose null keys cannot name an entry,
    the status bar item entries are emitted in read order regardless of
    their Name value, so such a row emits an entry whose Name key is the
    empty string (a null Name value reads back as "") or the verbatim
    whitespace string. The case-insensitive duplicate handling applies to
    those values as well: after the first read row with a null (or empty,
    or any other equal-ignoring-character-case) Name value, every further
    row whose Name duplicates it is skipped with the duplicate warning
    described above (a null and the empty Name string duplicate each
    other, both are read back as ""). Two distinct Name values that
    differ only in leading/trailing whitespace (for example the empty
    string and a whitespace-only string) are NOT duplicates of each
    other; no value is trimmed or otherwise normalized.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. An empty table expands to a
    top-level empty 'StatusBarItems' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded StatusBarItems data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the StatusBarItems data has been
    expanded successfully.

    .EXAMPLE
    Expand-StatusBarItemsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the StatusBarItems data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\StatusBarItems.yaml'
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
        throw "Cannot expand the StatusBarItems data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the StatusBarItems data into '$OutputPath'."

    # Read all rows of the table in the order the database returns them
    # (no ORDER BY; the table has no documented sort). The Name column of
    # the database is collated case-insensitively, so rows whose names
    # differ only in character case may return adjacent to each other;
    # duplicates among them are dropped case-insensitively below, in the
    # read order of the rows, so the first read row wins.
    Write-Verbose 'Reading the StatusBarItems rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [Name], [Text], [Width], [Visible] FROM [StatusBarItems]')
    Write-Verbose "Read $($rows.Count) StatusBarItems row(s)."

    # The staged Name values of the status bar items whose entries were
    # built, kept in a separate list so that the duplicate check below can
    # compare case-insensitively (the documented Unique handling of the
    # table — "If multiple identical Names exist, then only the first
    # row's column values will be read" with "Values are case-insensitive",
    # see the StatusBarItems section of docs/data-mapping.md). A null Name
    # stages the empty string, so a null and an empty Name duplicate each
    # other while whitespace-only values stay distinct.
    $admittedValues = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        # A null Name value is written as the empty string (and never
        # skipped: rows with a null, empty or whitespace-only Name value
        # still emit their entry, per the elected contract of this table;
        # the raw value is kept because the duplicate warning below cites
        # it, so a null keeps its '<null>' citation even though its
        # emitted value is the empty string). Every value is staged before
        # the duplicate check so that the warning below never reads a
        # value of a previous iteration.
        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull])) {
            $name = $null
        }
        else {
            $name = [string]$name
        }
        $nameRaw = $name
        if ($null -eq $name) {
            $name = ''
        }

        # The multi-line Text value is staged verbatim (its line breaks are
        # kept; the literal block's reading rule drifts them to line feeds
        # only when the written file is parsed again); a null Text value is
        # written as the empty string, and the raw value is kept because
        # the duplicate warning below cites it ('<null>' citation kept).
        $text = $row['Text']
        if (($null -eq $text) -or ($text -is [System.DBNull])) {
            $text = $null
        }
        else {
            $text = [string]$text
        }
        $textRaw = $text
        if ($null -eq $text) {
            $text = ''
        }

        # The Width value is staged as an integer as read from the
        # database; a null value is emitted as a YAML null.
        $width = $row['Width']
        if (($null -eq $width) -or ($width -is [System.DBNull])) {
            $width = $null
        }
        else {
            $width = [int]$width
        }

        # A null bit value is written as $false (the documented bit null
        # mapping). The Visible column is NOT NULL (default 1) in the
        # schema, so this branch is defensive and never taken on the
        # documented data path.
        $visible = $row['Visible']
        if (($null -eq $visible) -or ($visible -is [System.DBNull])) {
            $visible = $false
        }
        else {
            $visible = [bool]$visible
        }

        # Soft-validate the Unique Name column: a row whose staged value
        # compares equal to a previously staged row's value — ignoring
        # character case, so a null and the empty Name string duplicate
        # each other while whitespace-only values stay distinct — is
        # skipped with a warning containing the column values of the
        # ignored duplicate row ("A warning containing the values of
        # subsequent ignored duplicate rows will be shown",
        # docs/data-mapping.md, StatusBarItems section; the column values
        # of the first read row win).
        $isDuplicate = $false
        foreach ($existingValue in $admittedValues) {
            if ([string]::Equals($existingValue, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isDuplicate = $true
                break
            }
        }
        if ($isDuplicate) {
            if ($null -eq $nameRaw) { $nameClause = '<null>' } else { $nameClause = "'" + $nameRaw + "'" }
            if ($null -eq $textRaw) { $textEvidence = 'Text <null>' } else { $textEvidence = 'Text ' + $textRaw }
            if ($null -eq $width) { $widthEvidence = 'Width <null>' } else { $widthEvidence = 'Width ' + [string]$width }
            if ($visible) { $visibleEvidence = 'Visible True' } else { $visibleEvidence = 'Visible False' }
            $evidenceText = 'Name ' + $nameClause + ', ' + $textEvidence + ', ' + $widthEvidence + ', ' + $visibleEvidence

            Write-Warning "Skipping the StatusBarItems row (ID '$rowId'): the Name value $nameClause duplicates the Name value of a previously read row (whose column values win). The ignored duplicate row has the column values $evidenceText."
            continue
        }

        $admittedValues.Add($name)

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $entries.Add([ordered]@{
            Name    = $name
            Text    = $text
            Width   = $width
            Visible = $visible
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
    # status bar item entries is emitted indented, and repeated strings are
    # never collapsed into anchors/aliases. The sequence is wrapped in a
    # top-level 'StatusBarItems' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ StatusBarItems = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the StatusBarItems data of the RAGS file: the YAML content of the StatusBarItems data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'StatusBarItems.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) status bar item entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) StatusBarItems row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the StatusBarItems data into $($entries.Count) status bar item entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

