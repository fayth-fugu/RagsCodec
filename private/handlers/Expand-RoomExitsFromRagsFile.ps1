#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-RoomExitsFromRagsFile {
    <#
    .SYNOPSIS
    Expands RoomExits data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the RoomExits table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data
    into the single 'RoomExits.yaml' file in the output folder,
    following the conventions documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'RoomExits' mapping whose
    value is a sequence with one entry per distinct RoomID value. Each
    entry is a mapping of the RoomID value and the Direction key whose
    value is a sequence of mappings, one per RoomExits row of that
    room: each of those holds the row's Direction value, its Active
    value, its DestinationRoom value and its PortalObjectName value.

    Rows whose RoomID values differ only in character case form one
    entry: the room identity of the exit data is treated
    case-insensitively ('Values are case-insensitive',
    docs/data-mapping.md, RoomExits section), and every read RoomID
    value is normalized to lowercase ('Always coerced to lowercase',
    docs/data-mapping.md, RoomExits section): after the null and empty
    checks, the value is lowercased with ToLowerInvariant, so the
    entry's RoomID key is always the lowercase form of the value. The
    case mate whose raw casing is read first (which is the case mate
    with the lowest Direction and then the lowest row ID, since the
    table is sorted by RoomID, then by Direction and then by row ID)
    opens the entry, and every later row whose raw RoomID value differs
    from that first-read raw value only in character case is merged
    into the entry with a warning describing the merge; its exit is
    written into the same Direction sequence. Every warning and verbose
    message of the expansion cites the lowercased RoomID value.

    Rows with a null, empty or whitespace-only RoomID value are skipped
    with a warning, as no meaningful file entry can be derived from
    them. Rows with a null Direction value are skipped with a warning,
    as no exit can be derived from them. Rows within one room which
    repeat an exact, previously read Direction value are also skipped
    with a warning (the column values of the first read row win; 'If
    multiple identical Directions exist for the same RoomID value, then
    only the first row's column values will be read',
    docs/data-mapping.md, RoomExits section): all rows are sorted first
    by RoomID, then by Direction and then by row ID, which both orders
    the reported rows and makes the winning row of such a duplicate
    deterministic. Direction values of different rooms are independent
    and never compared against each other.

    The Active column holds the two boolean states; a null Active value
    is read as $false. The DestinationRoom value is always normalized
    to lowercase ('Lowercase enforcement', docs/data-mapping.md,
    RoomExits section). The PortalObjectName value is normalized to
    lowercase as well, except for the literal string '<None>' value,
    which is always passed through verbatim ('The string value <None>
    is always passed through verbatim during expansion and compression
    of PortalObjectName without coercion', docs/data-mapping.md,
    RoomExits section); the passthrough is case-insensitive, so any
    casing of the value keeps its raw characters; a null value never
    matches the passthrough. Null DestinationRoom and PortalObjectName
    values are emitted as the empty string.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one. Rows of one room
    appear in the Direction sequence in ascending Direction and row ID
    order. An empty table expands to a top-level empty 'RoomExits'
    sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded RoomExits data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the RoomExits data has been
    expanded successfully.

    .EXAMPLE
    Expand-RoomExitsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the RoomExits data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\RoomExits.yaml' file.
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
        throw "Cannot expand the RoomExits data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the RoomExits data into '$OutputPath'."

    # Read all rows of the table, ordered first by RoomID, then by
    # Direction and then by row ID ('Table is sorted first by RoomID
    # ascending, then by Direction ascending, then by ID ascending',
    # docs/data-mapping.md, RoomExits section). The RoomID column of the
    # database is collated case-insensitively, so rows whose values
    # differ only in character case may interleave here and sort next to
    # each other, separated by their Direction and row ID values.
    Write-Verbose 'Reading the RoomExits rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [RoomID], [Direction], [Active], [DestinationRoom], [PortalObjectName] FROM [RoomExits] ORDER BY [RoomID] ASC, [Direction] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) RoomExits row(s)."

    # Group the rows by their lowercased RoomID value ('Always coerced
    # to lowercase', docs/data-mapping.md, RoomExits section; the
    # grouping happens here because SQL Server Compact orders values
    # case-insensitively). Group names are the canonical lowercased
    # values and are looked up ordinally, and the first-read raw value
    # of every group is kept alongside, so that the merge comparison
    # below can detect the rows whose raw casing differs from the
    # first-read one. Group names, first-read raw names and per-room
    # exit lists are kept as parallel lists, while the duplicate check
    # further down compares Direction values with integer equality. For
    # a fixed lowercased room the rows arrive in ascending Direction and
    # row ID order (the SQL sort is a total order within a set of case
    # mates, separated by their Direction and row ID values), so
    # processing each row as it arrives preserves the documented row
    # order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupExits = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $roomId = $row['RoomID']
        if (($null -eq $roomId) -or ($roomId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$roomId)) {
            Write-Warning "Skipping the RoomExits row (ID '$rowId'): the RoomID value is null or empty, so no file entry can be derived for it."
            continue
        }

        # The RoomID values are always coerced to lowercase ('Always
        # coerced to lowercase', docs/data-mapping.md, RoomExits
        # section): the raw value is kept for the merge comparison
        # below, and every later use (the entry key and the citations of
        # the warnings and verbose messages) gets the lowercased form.
        $rawRoomId = [string]$roomId
        $roomId = $rawRoomId.ToLowerInvariant()

        # A NULL Direction row is dropped BEFORE the grouping: no exit
        # can be derived from it, so it never opens or joins an entry and
        # never takes part in the case-mate merge comparison.
        $exitDirection = $row['Direction']
        if (($null -eq $exitDirection) -or ($exitDirection -is [System.DBNull])) {
            Write-Warning "Skipping the RoomExits row of room '$roomId' (ID '$rowId'): the Direction value is null, so no exit can be derived from it."
            continue
        }

        # Locate or create the group of the room by its lowercased value
        # (an ordinal lookup: two lowercased values are the same group
        # exactly when they are equal). A row whose raw RoomID value
        # differs from the first-read raw value of the group only in
        # character case is merged into the group with a warning; its
        # exit is written into the same Direction sequence under the
        # lowercased group key.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $roomId, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($roomId)
            $groupRawNames.Add($rawRoomId)
            $groupExits.Add([System.Collections.Generic.List[object]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawRoomId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the RoomExits row of room '$roomId' (ID '$rowId') into the entry of room '$($groupNames[$groupIndex])': the raw RoomID value differs only in character case and is merged into the lowercased entry key."
        }
        $exits = $groupExits[$groupIndex]

        # The Active column holds the two boolean states; a null Active
        # value is read as $false (the documented null bit mapping). The
        # remaining columns stage the values which are cited by the
        # duplicate warning below, so that the warning reports the
        # ignored row's own column values even when the row is skipped
        # (locals assigned later in the same iteration would silently
        # hold the previous row's values).
        $active = $row['Active']
        if (($null -eq $active) -or ($active -is [System.DBNull])) {
            $active = $false
        }

        # The DestinationRoom value is always coerced to lowercase
        # (docs/data-mapping.md, RoomExits section, Lowercase
        # enforcement), and staged verbatim otherwise; a null value is
        # emitted as the empty string. The lowercased value is assigned
        # to a local before the duplicate check, so that the warning can
        # report the lowercased value of the ignored row itself (a null
        # keeps its '<null>' citation even though its emitted value is
        # the empty string, so the citation tests the raw value).
        $destinationRoom = $row['DestinationRoom']
        if (($null -eq $destinationRoom) -or ($destinationRoom -is [System.DBNull])) {
            $stagedDestinationRoom = ''
        }
        else {
            $stagedDestinationRoom = ([string]$destinationRoom).ToLowerInvariant()
        }

        # The PortalObjectName value is coerced to lowercase too, except
        # for the literal '<None>' value which is always passed through
        # verbatim ('The string value <None> is always passed through
        # verbatim during expansion and compression of PortalObjectName
        # without coercion', docs/data-mapping.md, RoomExits section).
        # The passthrough is case-insensitive, so any casing of the
        # value keeps its raw characters; every other value is
        # lowercased. A null value is emitted as the empty string and
        # never matches the passthrough.
        $portalObjectName = $row['PortalObjectName']
        if (($null -eq $portalObjectName) -or ($portalObjectName -is [System.DBNull])) {
            $stagedPortalObjectName = ''
        }
        elseif ([string]::Equals([string]$portalObjectName, '<None>', [System.StringComparison]::OrdinalIgnoreCase)) {
            $stagedPortalObjectName = [string]$portalObjectName
        }
        else {
            $stagedPortalObjectName = ([string]$portalObjectName).ToLowerInvariant()
        }

        # Soft-validate the Unique Direction column: the Direction
        # values within a room are expected to contain only distinct
        # values ('If multiple identical Directions exist for the same
        # RoomID value, then only the first row's column values will be
        # read', docs/data-mapping.md, RoomExits section), so a row
        # which repeats the exact Direction value of a previously read
        # row of the same room is skipped with a warning (the column
        # values of the first read row win). A NULL Direction never
        # reaches this check (it is skipped above). Direction values of
        # different rooms are never compared against each other. The
        # comparison uses integer equality, never string equality, so
        # that string representations of the same number can arise only
        # from the database itself.
        $exitDirectionInt = [int]$exitDirection
        $duplicate = $false
        foreach ($existingExit in $exits) {
            if ([int]$existingExit['Direction'] -eq $exitDirectionInt) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            # The duplicate warning cites the ignored row's own column
            # values ('A warning containing the values of subsequent
            # ignored duplicate rows will be shown',
            # docs/data-mapping.md, RoomExits section). The evidence
            # pieces are built before the branch, in the documented
            # sample-structure order: integer Direction values are
            # reported without quotes, boolean Active values are
            # reported as the boolean they were read as (a stored null
            # reports as the false it was read as), and the normalized
            # DestinationRoom and PortalObjectName values are quoted
            # with their null values keeping the <null> token.
            $duplicateEvidence = [System.Collections.Generic.List[string]]::new()
            $duplicateEvidence.Add("Direction $exitDirectionInt")
            $duplicateEvidence.Add("Active equals $active after reading")
            if (($null -eq $destinationRoom) -or ($destinationRoom -is [System.DBNull])) {
                $duplicateEvidence.Add('DestinationRoom <null>')
            }
            else {
                $duplicateEvidence.Add("DestinationRoom '$stagedDestinationRoom'")
            }
            if (($null -eq $portalObjectName) -or ($portalObjectName -is [System.DBNull])) {
                $duplicateEvidence.Add('PortalObjectName <null>')
            }
            else {
                $duplicateEvidence.Add("PortalObjectName '$stagedPortalObjectName'")
            }
            $duplicateEvidenceText = $duplicateEvidence -join ', '
            Write-Warning "Skipping the RoomExits row of room '$roomId' (ID '$rowId'): the Direction value $exitDirectionInt duplicates the Direction value of a previously read row (whose column values win). The ignored duplicate row has the column values $duplicateEvidenceText."
            continue
        }

        # The exit mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order) with an integer-keyed
        # access to the Direction value of the duplicate lookup above.
        $exits.Add([ordered]@{
            Direction        = $exitDirectionInt
            Active           = [bool]$active
            DestinationRoom  = $stagedDestinationRoom
            PortalObjectName = $stagedPortalObjectName
        })
    }

    # Build the top-level entry list, one entry per room in first-row
    # order (= ascending lowercased RoomID of the case-insensitive
    # group names, from the SQL sort).
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $entries.Add([ordered]@{
            RoomID    = $groupNames[$groupIndex]
            Direction = $groupExits[$groupIndex].ToArray()
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequences
    # of the exit mapping entries are emitted indented, and repeated
    # strings are never collapsed into anchors/aliases. The sequence is
    # wrapped in a top-level 'RoomExits' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ RoomExits = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a
    # failure for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the RoomExits data of the RAGS file: the YAML content of the RoomExits data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'RoomExits.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) RoomExits row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the RoomExits data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

