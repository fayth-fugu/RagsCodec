#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-RoomActionsFromRagsFile {
    <#
    .SYNOPSIS
    Expands RoomActions data from a RagsFile into YAML files.

    .DESCRIPTION
    Reads the RoomActions table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    one YAML file per distinct RoomID value (always coerced to lowercase,
    as the RoomActions List column documents), written into the
    'RoomActions' subfolder of the output folder, following the
    conventions documented in docs/data-mapping.md.

    Each file is named after the RoomID value it represents, coerced to
    lowercase as the RoomActions List column documents, followed by a
    lowercase '.yaml' extension; the file contains a mapping with the
    lowercased RoomID value and the Data sequence holding one entry per
    Data row of the room. Each entry is expanded from the encoded RAGS
    action of the row (Base64-decoded, GZip-decompressed and
    pretty-printed XML) through Expand-RagsActionIntoXml. Unlike the
    CharacterActions, Media and TimerActions tables, the file name is not
    derived from a GUID of the list value; the documented List-column
    value is used directly.

    Rows with a null, empty or whitespace-only RoomID or Data value are
    skipped with a warning, as no meaningful expansion target or content
    can be derived from them. A row whose RoomID value cannot be used to
    form a valid file name (because it contains characters that are invalid
    in file names, ends with a dot or a space, or names a reserved device
    such as CON, NUL or COM1) is skipped with a warning as well, since no
    meaningful expansion target can be derived from it either.

    The List-column values of the RoomActions table are documented as
    case-insensitive and always coerced to lowercase ('Values are
    case-insensitive' / 'Always coerced to lowercase' in the RoomActions
    section of docs/data-mapping.md), so every read RoomID value is
    lowercased with ToLowerInvariant right after it is read. The file
    names and the RoomID key of every written file always carry the
    lowercased form of the value, and the skip warnings, the merge warning
    and the corrupt-payload throw all cite that lowercased form as well.
    Rows whose raw RoomID values differ only in character case therefore
    share one file (a case mate with the lowest row ID is read first,
    since the table is sorted by RoomID and then by row ID). Every merged
    row whose raw RoomID value differs from the first-read raw value of
    its case mate set is reported with a warning; its payload is appended
    to the same Data sequence. The first-read row of such a set and rows
    repeating its raw value merge without a warning.

    A row whose non-empty Data value cannot be expanded aborts the whole
    operation with an exception before any YAML file is written (all
    payloads are expanded before any file is created).

    The subfolder and its parent folders are created silently when missing,
    and written files silently overwrite existing ones. Rows of one room
    appear in the Data sequence in ascending row ID order. When the table
    is empty altogether (or every row of it was skipped), the empty
    'RoomActions' subfolder is still created and holds no YAML file.

    .PARAMETER OutputPath
    Path of the folder to export the expanded RoomActions data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the RoomActions data has been
    expanded successfully.

    .EXAMPLE
    Expand-RoomActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the RoomActions data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\RoomActions' folder.
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
        throw "Cannot expand the RoomActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the 'RoomActions' subfolder when it is missing
    # (this also creates the output folder itself and any missing parents;
    # the folder is created even when the table turns out to be empty, as
    # no row is expanded into a YAML file then).
    $roomActionsFolder = Join-Path $OutputPath 'RoomActions'
    $null = New-Item -ItemType Directory -Force -Path $roomActionsFolder
    Write-Verbose "Expanding the RoomActions data into '$roomActionsFolder'."

    # Read all rows of the table, ordered first by RoomID and then by row
    # ID, as documented ('Table is sorted first by RoomID ascending, then
    # by ID ascending', docs/data-mapping.md, RoomActions section). The
    # RoomID column of the database is collated case-insensitively, so
    # rows of rooms whose names differ only in character case may
    # interleave here. Contrary to character names, room names are used
    # as file names directly, so such rows must NOT be grouped
    # case-sensitively: case mates would produce the same Windows file
    # name and silently overwrite each other. They are grouped by the
    # lowercased value below (the List-column values of the RoomActions
    # table are documented as case-insensitive and always coerced to
    # lowercase in docs/data-mapping.md), keeping every row in ascending
    # ID order and the first-read value's lowercase form as the file name
    # and RoomID key.
    Write-Verbose 'Reading the RoomActions rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [RoomID], [Data] FROM [RoomActions] ORDER BY [RoomID] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) RoomActions row(s)."

    # Characters that are invalid in file names on the current file system.
    # The array includes control characters (tab and line-break characters
    # included) on both supported hosts.
    $invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()

    # Group the payloads by the lowercased RoomID value. The List-column
    # handling of the RoomActions table pins the values as case-insensitive
    # and always coerced to lowercase (docs/data-mapping.md), so every
    # value is lowercased as soon as it is read and the groups are keyed
    # by that canonical form: two raw values that differ only in character
    # case share one group and therefore one file, which also keeps
    # Windows file-name collisions impossible. Group names (canonical),
    # first-read raw names and payload lists are kept as parallel lists:
    # the canonical names name the written file and its RoomID key, the
    # raw names drive the merge warning (a row whose raw value differs
    # from the first-read raw value of its group is reported), and the
    # payload lists receive the expanded payloads. For a fixed canonical
    # value the rows arrive in ascending ID order (the SQL sort is a total
    # order within a set of case mates, separated by row IDs), so
    # appending each expanded payload to its group as the rows arrive
    # preserves the documented row order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupPayloads = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $roomId = $row['RoomID']
        if (($null -eq $roomId) -or ($roomId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$roomId)) {
            Write-Warning "Skipping the RoomActions row (ID '$rowId'): the RoomID value is null or empty, so no file name can be derived for it."
            continue
        }
        $rawRoomId = [string]$roomId

        # The List-column values of the RoomActions table are documented as
        # case-insensitive and always coerced to lowercase, so the raw
        # value is lowered with ToLowerInvariant (the invariant result is
        # independent of the current culture) as soon as it is read.
        # Everything below - the file-name checks, the remaining skip
        # warnings and the merge reporting - works with and cites this
        # lowercased form; the raw value is kept only for the merge
        # reporting of the grouping.
        $roomId = $rawRoomId.ToLowerInvariant()

        # The lowercased RoomID value becomes the file name, so a value
        # that cannot form a valid file name is skipped with a warning. A
        # value either contains a character that is invalid in file names,
        # ends with a dot or a space, or names one of the reserved devices
        # (which also holds when a single extension is appended by the
        # '.yaml' suffix of the file); all three forms are rejected here.
        # All three checks are case-agnostic, so running them on the
        # lowercased value changes no outcome.
        $fileNameProblem = $null
        if (-1 -lt $roomId.IndexOfAny($invalidFileNameChars)) {
            $fileNameProblem = 'it contains a character that is invalid in file names'
        }
        elseif (($roomId.EndsWith('.')) -or ($roomId.EndsWith(' '))) {
            $fileNameProblem = 'it ends with a dot or a space, which is not allowed in file names'
        }
        elseif ($roomId -match '^((CON|PRN|AUX|NUL)|COM[1-9]|LPT[1-9])(\..+)?$') {
            $fileNameProblem = 'it names a reserved device, which cannot be used as a file name'
        }
        if ($null -ne $fileNameProblem) {
            Write-Warning "Skipping the RoomActions row of room '$roomId' (ID '$rowId'): the RoomID value cannot form a valid file name because $fileNameProblem."
            continue
        }

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the RoomActions row of room '$roomId' (ID '$rowId'): the Data value is null or empty."
            continue
        }
        $data = [string]$data

        # Locate or create the group of the room. The lookup and the
        # canonical group names compare ordinal against the lowercased
        # value, so case mates resolve to one group. The first-read raw
        # value is kept per group, and a row whose raw value differs from
        # it is merged with a warning which cites the lowercased value on
        # both sides; the first-read row of a case mate set and rows
        # repeating its raw value merge without a warning. In both cases
        # the payload is written into the same file under the lowercased
        # name.
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
            $groupPayloads.Add([System.Collections.Generic.List[string]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawRoomId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the RoomActions row of room '$roomId' (ID '$rowId') into the file of room '$($groupNames[$groupIndex])': the raw RoomID value differs only in character case and is merged into the lowercased file name."
        }

        Write-Verbose "Expanding the RAGS action of room '$roomId' (ID '$rowId')."
        try {
            $actionXml = Expand-RagsActionIntoXml -EncodedRagsAction $data
        }
        catch {
            $message = "Cannot expand the RoomActions data of the RAGS file: the Data payload of the row for room '$roomId' (ID '$rowId') could not be expanded as a RAGS action. "
            $message += "The expansion reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # The expanded action XML is staged verbatim, exactly as
        # Expand-RagsActionIntoXml produced it; a written value's line
        # breaks are normalized to line feeds only when the written YAML
        # is read back (the literal block scalar's reading rule).
        $stagedActionXml = [string]$actionXml
        $groupPayloads[$groupIndex].Add($stagedActionXml)
    }

    # Write one YAML file per room group. Rooms whose every row was skipped
    # above carry no payloads and produce no file.
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $payloads = $groupPayloads[$groupIndex].ToArray()
        if ($payloads.Count -eq 0) {
            continue
        }

        $roomId = $groupNames[$groupIndex]
        $fileName = $roomId + '.yaml'

        # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
        # the Data mapping entry is emitted indented, and repeated strings
        # are never collapsed into anchors/aliases.
        $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ RoomID = $roomId; Data = $payloads }) -Options 35

        # ConvertTo-Yaml reports .NET serialization failures by emitting the
        # error record to the output pipeline instead of throwing, so the
        # returned value is validated to guard against mistaking such a
        # failure for YAML content.
        if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
            throw "Cannot expand the RoomActions data of the RAGS file: the YAML content for room '$roomId' could not be serialized."
        }

        $filePath = Join-Path $roomActionsFolder $fileName
        Write-Verbose "Writing '$filePath' ($($payloads.Count) Data row(s) for room '$roomId')."
        [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Verbose "Expanded the RoomActions data into $($groupNames.Count) room group(s)."
    return $true
}

