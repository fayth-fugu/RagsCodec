#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-RoomsFromRagsFile {
    <#
    .SYNOPSIS
    Expands Rooms data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the Rooms table of a RAGS file (schema version 2.6.1) through an
    open SQL Server Compact connection and expands the data into the single
    'Rooms.yaml' file in the output folder, following the conventions
    documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'Rooms' mapping whose value is a
    sequence with one entry per room, each mapping the nine columns of the
    Rooms table in the order of the documented sample structure. The flag
    columns are emitted as YAML booleans where a missing value is read as
    false (the documented flag mapping). The Description column is emitted
    as a multi-line literal block scalar. YAML normalizes a literal block's
    line breaks to line feeds when the written YAML is read back, so a
    read-back description carries the line-feed form of whatever line breaks
    the table stores; the value itself is emitted verbatim. Every other null
    column value is emitted as a YAML null.

    Rows are expected to hold distinct UniqueID values: the table is
    sorted by UniqueID ascending before it is read ("Table is sorted by
    UniqueID ascending", docs/data-mapping.md, Rooms section), so for
    every room after the first whose UniqueID compares equal to a
    previously read room — ignoring character case and always coerced to
    lowercase, per the 'Values are case-insensitive' / 'Always coerced
    to lowercase' Unique handling documented for the table (see the
    Rooms section of docs/data-mapping.md) — the second and later rows
    are skipped with a warning which contains the column values of the
    ignored duplicate row, as the documentation requires; the column
    values of the first read row win, and the emitted entries are keyed
    by the lowercased UniqueID values the documented Unique handling
    produces. Rows with a null, empty or whitespace-only UniqueID value
    are also skipped with a warning, as no room entry can be derived
    from them.

    The picture columns are always coerced to lowercase ('Lowercase
    enforcement', docs/data-mapping.md, Rooms section), except for the
    literal 'None' values which are always passed through verbatim
    ('The string value None is always passed through verbatim during
    expansion and compression of RoomPic/LayeredRoomPic without
    coercion', docs/data-mapping.md, Rooms section): the passthrough
    matches case-insensitively, so any casing of the value keeps its
    raw characters; every other value is lowercased.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one. An empty table
    expands to a top-level empty 'Rooms' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded Rooms data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Rooms data has been expanded
    successfully.

    .EXAMPLE
    Expand-RoomsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the Rooms data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\Rooms.yaml' file.
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
        throw "Cannot expand the Rooms data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the Rooms data into '$OutputPath'."

    # Read all rows of the table, ordered by UniqueID ascending ("Table
    # is sorted by UniqueID ascending", docs/data-mapping.md, Rooms
    # section; the table has no identity column, so the documented sort
    # ends here). The UniqueID column of the database is collated
    # case-insensitively, so rows of rooms whose UniqueID values differ
    # only in character case sort next to each other here (their
    # relative read order is the engine's tiebreak); duplicates among
    # them are dropped case-insensitively below, in the read order of
    # the rows.
    Write-Verbose 'Reading the Rooms rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [UniqueID], [Description], [SDesc], [Name], [RoomPic], [EnterFirstTime], [LeaveFirstTime], [Group], [LayeredRoomPic] FROM [Rooms] ORDER BY [UniqueID] ASC')
    Write-Verbose "Read $($rows.Count) Rooms row(s)."

    # The Rooms table has no identity column which could label the rows of
    # a duplicate or null-UniqueID warning, so such warnings refer to the
    # position of the row in the read result instead.
    $readRowNumber = 0

    # The UniqueID values of the rooms whose entries were built, kept in a
    # separate list so that the duplicate check below can compare the
    # normalized values with the ordinal comparison (the values are
    # normalized to lowercase before the check, so the ordinal comparison
    # implements the documented case-insensitive duplicate rule).
    $admittedUniqueIds = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $readRowNumber++

        $uniqueId = $row['UniqueID']
        if (($null -eq $uniqueId) -or ($uniqueId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$uniqueId)) {
            Write-Warning "Skipping the Rooms row $($readRowNumber) of the read result: the UniqueID value is null or empty, so no room entry can be derived for it."
            continue
        }

        # The documented Unique handling of this table always coerces the
        # UniqueID values to lowercase ('Always coerced to lowercase',
        # docs/data-mapping.md, Rooms section — as the documentation
        # requires): entries are keyed by the lowercased value, and the
        # duplicate check below therefore compares the normalized values
        # with ordinal comparisons.
        $uniqueId = ([string]$uniqueId).ToLowerInvariant()

        # A null column value is written as a YAML null, except for the bit
        # columns, where a null is written as a YAML false (documented flag
        # mapping). The Description value is staged verbatim (a YAML literal
        # block scalar normalizes a written value's line breaks to line
        # feeds only when the written YAML is read back). Every value is
        # computed before the duplicate check so that the warnings below
        # never read a value of a previous iteration (the stale-variable
        # rule), and the duplicate warning cites the values the row stages.
        $description = $row['Description']
        if (($null -eq $description) -or ($description -is [System.DBNull])) {
            $description = $null
        }
        else {
            $description = [string]$description
        }

        $sdesc = $row['SDesc']
        if (($null -eq $sdesc) -or ($sdesc -is [System.DBNull])) {
            $sdesc = $null
        }
        else {
            $sdesc = [string]$sdesc
        }

        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull])) {
            $name = $null
        }
        else {
            $name = [string]$name
        }

        # The RoomPic value is always coerced to lowercase ('Lowercase
        # enforcement', docs/data-mapping.md, Rooms section), except for
        # the literal 'None' value which is always passed through verbatim
        # ('The string value None is always passed through verbatim during
        # expansion and compression of RoomPic without coercion',
        # docs/data-mapping.md, Rooms section). The passthrough is
        # case-insensitive, so any casing of the value keeps its raw
        # characters; every other value is lowercased.
        $roomPic = $row['RoomPic']
        if (($null -eq $roomPic) -or ($roomPic -is [System.DBNull])) {
            $roomPic = $null
        }
        elseif ([string]::Equals([string]$roomPic, 'None', [System.StringComparison]::OrdinalIgnoreCase)) {
            $roomPic = [string]$roomPic
        }
        else {
            $roomPic = ([string]$roomPic).ToLowerInvariant()
        }

        # The LayeredRoomPic value is coerced to lowercase under the same
        # rules, its 'None' passthrough documented for the column itself.
        $layeredRoomPic = $row['LayeredRoomPic']
        if (($null -eq $layeredRoomPic) -or ($layeredRoomPic -is [System.DBNull])) {
            $layeredRoomPic = $null
        }
        elseif ([string]::Equals([string]$layeredRoomPic, 'None', [System.StringComparison]::OrdinalIgnoreCase)) {
            $layeredRoomPic = [string]$layeredRoomPic
        }
        else {
            $layeredRoomPic = ([string]$layeredRoomPic).ToLowerInvariant()
        }

        # The managed reader returns bit columns as Boolean values; a
        # missing value is read as the documented false. The duplicate
        # warning below accordingly cites these values as read at this
        # point ('after reading'): a row storing a null is reported with
        # the false it was read as, never with the null it holds.
        $enterFirstTime = $row['EnterFirstTime']
        if (($null -eq $enterFirstTime) -or ($enterFirstTime -is [System.DBNull])) {
            $enterFirstTime = $false
        }

        $leaveFirstTime = $row['LeaveFirstTime']
        if (($null -eq $leaveFirstTime) -or ($leaveFirstTime -is [System.DBNull])) {
            $leaveFirstTime = $false
        }

        $group = $row['Group']
        if (($null -eq $group) -or ($group -is [System.DBNull])) {
            $group = $null
        }
        else {
            $group = [string]$group
        }

        # Soft-validate the Unique UniqueID column: a row whose value
        # compares equal to a previously read row's value, ignoring
        # character case (the values are already normalized to lowercase
        # above), is skipped with a warning naming the column values of
        # the ignored duplicate row ("A warning containing the values of
        # subsequent ignored duplicate rows will be shown",
        # docs/data-mapping.md, Rooms section; the column values of the
        # first read row win).
        $duplicate = $false
        foreach ($existingUniqueId in $admittedUniqueIds) {
            if ([string]::Equals($existingUniqueId, $uniqueId, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $description) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            if ($null -eq $sdesc) { $evidenceParts.Add('SDesc <null>') } else { $evidenceParts.Add('SDesc ''' + $sdesc + '''') }
            if ($null -eq $name) { $evidenceParts.Add('Name <null>') } else { $evidenceParts.Add('Name ''' + $name + '''') }
            if ($null -eq $roomPic) { $evidenceParts.Add('RoomPic <null>') } else { $evidenceParts.Add('RoomPic ''' + $roomPic + '''') }
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $group) { $evidenceParts.Add('Group <null>') } else { $evidenceParts.Add('Group ''' + $group + '''') }
            if ($null -eq $layeredRoomPic) { $evidenceParts.Add('LayeredRoomPic <null>') } else { $evidenceParts.Add('LayeredRoomPic ''' + $layeredRoomPic + '''') }

            Write-Warning "Skipping the Rooms row $($readRowNumber) of the read result: the UniqueID value '$uniqueId' duplicates the UniqueID value of a previously read row (whose column values win). The ignored duplicate row has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedUniqueIds.Add($uniqueId)

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $entries.Add([ordered]@{
            UniqueID       = $uniqueId
            Description    = $description
            SDesc          = $sdesc
            Name           = $name
            RoomPic        = $roomPic
            EnterFirstTime = $enterFirstTime
            LeaveFirstTime = $leaveFirstTime
            Group          = $group
            LayeredRoomPic = $layeredRoomPic
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
    # room entries is emitted indented, and repeated strings are never
    # collapsed into anchors/aliases. The sequence is wrapped in a
    # top-level 'Rooms' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ Rooms = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a
    # failure for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the Rooms data of the RAGS file: the YAML content of the Rooms data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'Rooms.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) Rooms row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the Rooms data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

