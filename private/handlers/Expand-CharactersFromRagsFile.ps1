#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-CharactersFromRagsFile {
    <#
    .SYNOPSIS
    Expands Characters data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the Characters table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    the single 'Characters.yaml' file in the output folder, following the
    conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'Characters' mapping whose value
    is a sequence with one entry per character, each mapping the nine
    columns of the Characters table: the Charname key and the other eight
    column values. Character genders are emitted as YAML integers, the
    three inventory/time flags are emitted as YAML booleans and the
    Description column is emitted as a multi-line literal block scalar whose
    line breaks were normalized to line-feed characters (YAML normalizes
    line breaks to line feeds when a literal block is read back, so
    carriage returns are normalized beforehand to keep the round-trip
    byte-exact). Every other null column value is emitted as a YAML null.

    Rows are expected to hold distinct Charname values: the table is sorted
    by Charname before it is read, so for every character after the first
    whose Charname compares equal (ignoring character case, mirroring the
    case-insensitive database collation) to a previously read character the
    second and later rows are skipped with a warning which names the column
    values of the ignored duplicate row — the column values of the first
    read row win. Rows with a null, empty or whitespace-only Charname value
    are also skipped with a warning, as no character entry key can be
    derived from them.

    The output folder is silently created when it is missing and the written
    file silently overwrites any existing one. An empty table expands to a
    top-level empty 'Characters' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded Characters data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Characters data has been
    expanded successfully.

    .EXAMPLE
    Expand-CharactersFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the Characters data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\Characters.yaml' file.
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
        throw "Cannot expand the Characters data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the Characters data into '$OutputPath'."

    # Read all rows of the table, ordered by Charname, as documented. The
    # Charname column of the database is collated case-insensitively, so
    # rows of characters whose names differ only in character case sort
    # next to each other here; duplicates among them are dropped case-
    # insensitively below, in the read order of the rows.
    Write-Verbose 'Reading the Characters rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [Charname], [CharnameOverride], [CharGender], [CurrentRoom], [Description], [AllowInventoryInteraction], [EnterFirstTime], [LeaveFirstTime], [CharPortrait] FROM [Characters] ORDER BY [Charname] ASC')
    Write-Verbose "Read $($rows.Count) Characters row(s)."

    # The Characters table has no identity column which could label the
    # rows of a duplicate or null-Charname warning, so such warnings refer
    # to the position of the row in the read result instead.
    $readRowNumber = 0

    # The Charname values of the characters whose entries were built,
    # kept in a separate list so that the duplicate check below can
    # compare case-insensitively (the Unique semantics follow the
    # case-insensitive database collation, in deviation from the other
    # expansions which group case-sensitively).
    $admittedCharnames = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $readRowNumber++

        $charname = $row['Charname']
        if (($null -eq $charname) -or ($charname -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$charname)) {
            Write-Warning "Skipping the Characters row $($readRowNumber) of the read result: the Charname value is null or empty, so no character entry can be derived for it."
            continue
        }
        $charname = [string]$charname

        # A null column value is written as a YAML null, except for the
        # three bit columns, where a null is written as a YAML false
        # (documented flag mapping). The Description value is normalized
        # to line feeds beforehand, both because a YAML literal block
        # scalar normalizes line breaks that way when read back and so
        # that the duplicate warning below can report the value of the
        # ignored row as it would have been written. Every value is
        # computed before the duplicate check so that the warnings below
        # never read a value of a previous iteration.
        $charnameOverride = $row['CharnameOverride']
        if (($null -eq $charnameOverride) -or ($charnameOverride -is [System.DBNull])) {
            $charnameOverride = $null
        }
        else {
            $charnameOverride = [string]$charnameOverride
        }

        $charGender = $row['CharGender']
        if (($null -eq $charGender) -or ($charGender -is [System.DBNull])) {
            $charGender = $null
        }

        $currentRoom = $row['CurrentRoom']
        if (($null -eq $currentRoom) -or ($currentRoom -is [System.DBNull])) {
            $currentRoom = $null
        }
        else {
            $currentRoom = [string]$currentRoom
        }

        $description = $row['Description']
        if (($null -eq $description) -or ($description -is [System.DBNull])) {
            $description = $null
        }
        else {
            $description = ([string]$description) -replace '\r\n?', "`n"
        }

        # The managed reader returns bit columns as Boolean values; a
        # missing value is read as the documented false.
        $allowInventoryInteraction = $row['AllowInventoryInteraction']
        if (($null -eq $allowInventoryInteraction) -or ($allowInventoryInteraction -is [System.DBNull])) {
            $allowInventoryInteraction = $false
        }

        $enterFirstTime = $row['EnterFirstTime']
        if (($null -eq $enterFirstTime) -or ($enterFirstTime -is [System.DBNull])) {
            $enterFirstTime = $false
        }

        $leaveFirstTime = $row['LeaveFirstTime']
        if (($null -eq $leaveFirstTime) -or ($leaveFirstTime -is [System.DBNull])) {
            $leaveFirstTime = $false
        }

        $charPortrait = $row['CharPortrait']
        if (($null -eq $charPortrait) -or ($charPortrait -is [System.DBNull])) {
            $charPortrait = $null
        }
        else {
            $charPortrait = [string]$charPortrait
        }

        # Soft-validate the Unique Charname column: a row whose value
        # compares equal to a previously read row's value, ignoring
        # character case, is skipped with a warning naming the column
        # values of the ignored duplicate row (the column values of the
        # first read row win).
        $duplicate = $false
        foreach ($existingCharname in $admittedCharnames) {
            if ([string]::Equals($existingCharname, $charname, [System.StringComparison]::OrdinalIgnoreCase)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $charnameOverride) { $evidenceParts.Add('CharnameOverride <null>') } else { $evidenceParts.Add('CharnameOverride ''' + $charnameOverride + '''') }
            if ($null -eq $charGender) { $evidenceParts.Add('CharGender <null>') } else { $evidenceParts.Add('CharGender ' + $charGender) }
            if ($null -eq $currentRoom) { $evidenceParts.Add('CurrentRoom <null>') } else { $evidenceParts.Add('CurrentRoom ''' + $currentRoom + '''') }
            if ($null -eq $description) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            $evidenceParts.Add('AllowInventoryInteraction equals ' + $allowInventoryInteraction + ' after reading')
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $charPortrait) { $evidenceParts.Add('CharPortrait <null>') } else { $evidenceParts.Add('CharPortrait ''' + $charPortrait + '''') }

            Write-Warning "Skipping the Characters row $($readRowNumber) of the read result: the Charname value '$charname' duplicates the Charname value of a previously read row (whose column values win). The ignored duplicate row has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedCharnames.Add($charname)

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $entries.Add([ordered]@{
            Charname                  = $charname
            CharnameOverride          = $charnameOverride
            CharGender                = $charGender
            CurrentRoom               = $currentRoom
            Description               = $description
            AllowInventoryInteraction = $allowInventoryInteraction
            EnterFirstTime            = $enterFirstTime
            LeaveFirstTime            = $leaveFirstTime
            CharPortrait              = $charPortrait
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
    # character entries is emitted indented, and repeated strings are never
    # collapsed into anchors/aliases. The sequence is wrapped in a top-level
    # 'Characters' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ Characters = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a failure
    # for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the Characters data of the RAGS file: the YAML content of the Characters data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'Characters.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) Characters row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the Characters data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

