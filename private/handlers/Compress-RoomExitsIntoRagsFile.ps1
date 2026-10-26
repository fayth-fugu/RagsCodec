#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-RoomExitsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses RoomExits data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded RoomExits data of a source folder back
    into the RoomExits table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection, appending the
    compressed rows as the inverse of Expand-RoomExitsFromRagsFile and
    following the conventions documented in docs/data-mapping.md.

    The single 'RoomExits.yaml' file of the source folder is read as a
    YAML document holding a top-level 'RoomExits' mapping whose value is
    a sequence with one entry per distinct room: each entry maps the
    lowercased RoomID value to the Direction key, whose value is a
    sequence of exit mappings holding the Direction value, the Active
    value and the two text values of the exit. One table row is appended
    per exit (the ID identity column is excluded and auto-supplied by
    the database), replicating the row order of the original expansion:
    the exits of every entry keep their YAML sequence order, and entries
    keep their YAML sequence order, so re-expanding the file restores
    the entries and their exits in read order.

    The 'RoomExits.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'RoomExits' envelope
      around the entry sequence, so a non-mapping document predates this
      layout). Keys of the document other than the 'RoomExits' envelope
      key are ignored with a warning.
    - A document whose RoomExits value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      A RoomExits value which is an empty sequence is treated like the
      empty sequence an expansion writes for an empty table and
      contributes no rows without a warning. A RoomExits value which is
      a scalar or a single mapping (as hand-edited files omitting the
      trailing sequence dash commonly are) is accepted as the single
      entry of the sequence with a warning; a scalar which is not a
      string is additionally coerced to its invariant string form with
      a second warning, and a scalar entry then aborts the operation in
      the entry validation below (an entry has to be a mapping). A value
      of any other type aborts the whole operation with an exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful room exit can be derived from it. Keys of an entry
      other than the two column names are ignored with a warning.
    - An entry whose RoomID value is missing, null or empty is skipped
      in its entirety with a warning, including a whitespace-only
      RoomID, as no room exit can be derived from it.
    - A scalar RoomID value which is not a string is coerced to its
      invariant string form with a warning; a RoomID value which is a
      sequence or a mapping aborts the whole operation with an
      exception.
    - A RoomID value longer than the 250 characters of the table column
      is truncated with a warning, which fires as soon as the value is
      accepted (before the Direction value of the entry is validated);
      note that re-expanding the appended data then derives a different
      room from the truncated value. Because a longer value could not
      be stored, the truncation happens before the lowercasing and
      case-insensitive grouping below, so two RoomID values which become
      equal only by their truncation group together like any other set
      of case mates.
    - Entries whose RoomID values differ only in character case form
      one room entry: the room identity of the exit data is treated
      case-insensitively ('Values are case-insensitive',
      docs/data-mapping.md, RoomExits section) and every RoomID value is
      coerced to lowercase ('Always coerced to lowercase',
      docs/data-mapping.md, RoomExits section): after the truncation
      above, the value is lowercased with ToLowerInvariant, so the
      appended rows carry the lowercased form and re-expand into the
      same lowercased entry. Case mates group under the lowercased value
      read first; an entry whose raw RoomID value differs from the
      first-read raw value of its group only in character case is merged
      into it with one warning. Entries whose RoomID values are exactly
      equal are appended without a warning, as append-only accumulation
      is the documented caller workflow.
    - An entry whose Direction value is missing, null, empty,
      whitespace-only or an empty sequence is skipped in its entirety
      with a warning, as no exit can be derived from it. A Direction
      value which is a scalar or a single mapping is accepted as the
      single exit of the sequence with a warning (a hand-edited file
      commonly omits the trailing sequence dash of a single exit).
    - Exits which are null are skipped with a warning. An exit which is
      not a mapping aborts the whole operation with an exception, as no
      meaningful room exit can be derived from it. Keys of an exit other
      than the Direction, Active, DestinationRoom and PortalObjectName
      keys are ignored with a warning.
    - An exit whose Direction value is missing or null is skipped with
      a warning, as no room exit can be derived from it (mirroring the
      null Direction skip of the expansion). A scalar Direction value
      which is an integer is read as is; a scalar Direction value of any
      other type is coerced to its invariant string form (a string, its
      own form), parsed with the invariant culture and read with a
      warning, as no meaningful integer can be derived from it
      otherwise; a scalar Direction value which cannot be parsed as an
      integer (including an integer outside the range of the int table
      column), and Direction values which are sequences or mappings,
      abort the whole operation with an exception. Direction values of
      different rooms are independent and never compared against each
      other.
    - The Active value of an exit holds the two boolean states; a
      missing or null Active value is read as $false without a warning
      (the documented null bit mapping, which the expansion applies to
      its read values as well), a boolean Active value is read as is,
      and an integer Active value which is 0 or 1 is read as the
      matching boolean with a warning; any other Active value aborts the
      whole operation with an exception, as no boolean can be derived
      from it.
    - The DestinationRoom value of an exit is a plain string: a missing
      or null DestinationRoom value is stored as the empty string
      without a warning, mirroring the null-string emission rule of the
      expansion (a null column value is emitted as the empty string),
      and an empty or whitespace-only value is kept as is. A scalar
      DestinationRoom value which is not a string is coerced to its
      invariant string form with a warning; a DestinationRoom value
      which is a sequence or a mapping aborts the whole operation with
      an exception. A DestinationRoom value longer than the 250
      characters of the table column is truncated with a warning (the
      truncation measures the as-parsed value, as the stored value is
      that value verbatim); note that re-expanding the appended data
      then derives a different value from the truncated one. The
      truncation happens before the lowercasing below, so the truncated
      value is the value stored. The DestinationRoom value is always
      coerced to lowercase ('Lowercase enforcement',
      docs/data-mapping.md, RoomExits section): the lowercasing is
      silent, so the appended rows carry the lowercased form and
      re-expand without a warning.
    - The PortalObjectName value of an exit is stored like the
      DestinationRoom value (a missing or null value stored as the
      empty string without a warning, empty and whitespace-only values
      kept as is, non-string scalars coerced with a warning, sequences
      and mappings rejected, truncation before the lowercasing), except
      for its lowercase rule: the PortalObjectName value is always
      coerced to lowercase too ('Lowercase enforcement',
      docs/data-mapping.md, RoomExits section), but the literal '<None>'
      value is always passed through verbatim ('The string value <None>
      is always passed through verbatim during expansion and compression
      of PortalObjectName without coercion', docs/data-mapping.md,
      RoomExits section). The passthrough is case-insensitive, so any
      casing of the value keeps its raw characters; every other
      PortalObjectName value is lowercased.
    - An exit which repeats an exactly read Direction value of its room
      is skipped with a warning (the column values of the first read
      exit win, mirroring the Unique soft-validation of the expansion):
      every exit of one room carries its Direction value in one
      per-room set which the entries of that room share, so a duplicate
      Direction value across the entries of one room is detected as
      well (hand-edited files may repeat an entry, and the merged case
      mates of one room append their exits to the same set). NULL
      Direction values never reach this check (they are skipped above).
      The ignored duplicate exit is reported with its own normalized
      column values ('A warning containing the values of subsequent
      ignored duplicate rows will be shown', docs/data-mapping.md,
      RoomExits section): the Direction value, the Active value it was
      read as, and the normalized DestinationRoom and PortalObjectName
      values, with the raw missing keys kept as their <null> tokens
      (a null source value stages the empty string).
    - Exit values are stored as read: no line-ending normalization is
      applied (the verbatim contract of the expansion family - note
      that a multi-line value re-emits through a YAML literal block,
      whose re-read normalizes the written breaks to line feeds; a
      carriage return which arrives in the parsed value, from a
      double-quoted '\r' escape in a hand-edited file for example, is
      staged verbatim).

    The 'RoomExits.yaml' file is read, validated and fully staged before
    the first row is appended, so the table remains empty when the
    source folder carries invalid content. The appended rows are then
    written inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The 'RoomExits.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the RoomExits table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source folder compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .OUTPUTS
    System.Boolean. Returns $true when the RoomExits data has been
    compressed successfully.

    .EXAMPLE
    Compress-RoomExitsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded RoomExits data of the 'C:\Export\MyGame'
    folder to the RoomExits table of the RAGS file connected through
    $openRagsConnection.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlServerCe.SqlCeConnection]$RagsConnection
    )

    if ($RagsConnection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Cannot compress the RoomExits data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'RoomExits.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'RoomExits.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'RoomExits.yaml' file, so there is no RoomExits data to compress."
        return $true
    }
    Write-Verbose "Compressing the RoomExits data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the RoomExits data of the RAGS file: the file 'RoomExits.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the RoomExits data of the RAGS file: the file 'RoomExits.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the RoomExits data of the RAGS file: the file 'RoomExits.yaml' of the source folder is not a valid YAML document. "
        $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    # ConvertFrom-Yaml returns the parsed value of a multi-document stream
    # as an object array of one element per document (see the
    # CharacterActions handler); a single-document stream is collapsed by
    # the array wrap, so a count above one is always the sign of extra
    # documents. Note that the wrap can inflate the count when a document
    # itself is a sequence; the warning only ever dismisses trailing
    # content, so this cannot misdirect the read below.
    if ($parsedDocuments.Count -gt 1) {
        Write-Warning "The file 'RoomExits.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values of
    # multiple documents as an object array, and no value at all for an
    # empty or comment-only stream. A missing value after the parse is
    # therefore reported like a missing document.
    $rootDocument = $null
    if ($parsedDocuments.Count -gt 0) {
        $rootDocument = $parsedDocuments[0]
    }
    if ($null -eq $rootDocument) {
        throw "Cannot compress the RoomExits data of the RAGS file: the file 'RoomExits.yaml' of the source folder carries no YAML document."
    }
    if ($rootDocument -isnot [System.Collections.IDictionary]) {
        if ($rootDocument -is [string]) {
            $rootType = 'a scalar'
        }
        elseif ($rootDocument -is [System.Collections.IList]) {
            $rootType = 'a sequence'
        }
        else {
            $rootType = "a value of type '$($rootDocument.GetType().FullName)'"
        }

        throw "Cannot compress the RoomExits data of the RAGS file: the file 'RoomExits.yaml' of the source folder carries $rootType where a mapping is expected."
    }
    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'RoomExits' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'RoomExits', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'RoomExits.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash; a non-string scalar is coerced to its
    # invariant string form with a second warning, so the coerced entry
    # is rejected by the entry validation below (an entry has to be a
    # mapping).
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['RoomExits']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'RoomExits.yaml' of the source folder: the RoomExits value is missing or null, so no room exit can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'RoomExits.yaml' of the source folder: the RoomExits value is empty, so no room exit can be derived from it."
        }
        else {
            Write-Warning "The RoomExits value of the file 'RoomExits.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The RoomExits value of the file 'RoomExits.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        Write-Warning "The RoomExits value of the file 'RoomExits.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
        Write-Warning "The RoomExits value of the file 'RoomExits.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
        if ($envelopeValue -is [System.IFormattable]) {
            $envelopeScalarValue = $envelopeValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            $envelopeScalarValue = [string]$envelopeValue
        }
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeScalarValue)
        $entriesValue = $coercedEntries
    }

    # Stage one row per exit before appending anything, so that nothing
    # is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the room, the storable exit direction (an integer),
    # the storable Active boolean and the two storable text values (a
    # string or a null), and the 1-based entry and exit indices which
    # produced it for the messages of the append phase. The validation of
    # every entry is performed inline below, so that the file is fully
    # validated (and every failure reported) before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The RoomID values of the entries are kept in one list, and the
    # first-read raw values in a parallel list, so that RoomID values
    # which differ only in character case can merge into the lowercased
    # group ('Values are case-insensitive' and 'Always coerced to
    # lowercase', docs/data-mapping.md, RoomExits section, the grouping
    # the expansion performs as well). Group names are the canonical
    # lowercased values and are looked up ordinally, and the first-read
    # raw value of every group is kept alongside, so that the merge
    # comparison below can detect the entries whose raw RoomID values
    # differ from the first-read one. A third parallel list keeps one
    # integer Direction-value set per room, which validates the Unique
    # Direction column across every entry of its room, exactly like the
    # expansion (which shares the Direction values of one room across
    # the case mates it merges).
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupDirectionSets = [System.Collections.Generic.List[object]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder: the entry is null."
            continue
        }
        if ($entryValue -isnot [System.Collections.IDictionary]) {
            if ($entryValue -is [string]) {
                $entryType = 'a scalar'
            }
            elseif ($entryValue -is [System.Collections.IList]) {
                $entryType = 'a sequence'
            }
            else {
                $entryType = "a value of type '$($entryValue.GetType().FullName)'"
            }

            throw "Cannot compress the RoomExits data of the RAGS file: the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the RoomID and Direction keys
        # only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'RoomID', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Direction', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # The List-column RoomID value of the entry, which the expansion
        # writes as a string scalar. A scalar of any other type (a
        # hand-edited unquoted number, for example) is coerced to its
        # invariant string form with a warning.
        $entryRoomIdValue = $entryValue['RoomID']
        if ($null -eq $entryRoomIdValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder: the RoomID value is missing, null or empty, so no room exit can be derived from it."
            continue
        }

        $room = $null
        if ($entryRoomIdValue -is [System.Collections.IList]) {
            throw "Cannot compress the RoomExits data of the RAGS file: the RoomID of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($entryRoomIdValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the RoomExits data of the RAGS file: the RoomID of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($entryRoomIdValue -is [string]) {
            $room = $entryRoomIdValue
        }
        else {
            Write-Warning "The RoomID of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder is of type '$($entryRoomIdValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryRoomIdValue -is [System.IFormattable]) {
                $room = $entryRoomIdValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $room = [string]$entryRoomIdValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($room)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder: the RoomID value is missing, null or empty, so no room exit can be derived from it."
            continue
        }

        # Truncate the RoomID value to the length of the table column,
        # as a longer value could not be stored. The truncation runs
        # before the lowercasing and grouping below, so two RoomID values
        # which become equal only by their truncation behave like any
        # other set of case mates. The warning fires as soon as the value
        # is accepted - like every other RoomID-value warning, before the
        # Direction value of the entry is validated.
        if ($room.Length -gt 250) {
            Write-Warning "The RoomID value of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder is $($room.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different room from the truncated value."
            $room = $room.Substring(0, 250)
        }

        # The List-column values of the RoomExits table are documented as
        # case-insensitive and always coerced to lowercase ('Values are
        # case-insensitive' / 'Always coerced to lowercase' in the
        # RoomExits section of docs/data-mapping.md), so the truncated
        # raw value is lowered with ToLowerInvariant (the invariant
        # result is independent of the current culture). Everything
        # below - the grouping and the appended rows - works with and
        # cites this lowercased form; the raw value is kept only for the
        # merge reporting of the grouping. The expansion of the appended
        # data lowercases its read values anyway, so the lowercased rows
        # re-expand with their RoomID value unchanged.
        $roomRaw = $room
        $room = $roomRaw.ToLowerInvariant()

        # Locate or create the group of the room. The lowercased value is
        # canonical, so the lookup compares ordinal against it (a
        # case-insensitive comparison would change no outcome). The
        # first-read raw value is kept per group, and an entry whose raw
        # value differs from it is merged with a warning which cites the
        # lowercased value on both sides; the first-read entry of a case
        # mate set and entries repeating its raw value are appended
        # without a warning, as append-only accumulation is the documented
        # caller workflow. The warning fires as soon as the value is
        # accepted - like every other RoomID-value warning, before the
        # Direction value of the entry is validated.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $room, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($room)
            $groupRawNames.Add($roomRaw)
            $groupDirectionSets.Add([System.Collections.Generic.HashSet[int]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $roomRaw, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the exits of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$room' into the exits of room '$($groupNames[$groupIndex])': the raw RoomID value differs only in character case and is merged into the lowercased rows."
        }

        # Every appended row of the entry carries the group's RoomID
        # value (the lowercased form common to its set of case mates),
        # and the Direction values of the entry join the Direction-value
        # set of that room, exactly like the Direction values of any
        # other entry of the same room.
        $stagedRoom = $groupNames[$groupIndex]
        $directionSet = $groupDirectionSets[$groupIndex]

        # Locate and validate the Direction value of the entry, which is
        # a sequence of exit mappings. A scalar or single-mapping value
        # is accepted as the single exit of the sequence with a warning,
        # as single-exit sequences are commonly written without their
        # leading sequence dash.
        $entryDirectionValue = $entryValue['Direction']
        if ($null -eq $entryDirectionValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom': the Direction value is missing or null, so no exit can be derived from it."
            continue
        }

        if ($entryDirectionValue -is [System.Collections.IList]) {
            if ($entryDirectionValue.Count -eq 0) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom': the Direction value is an empty sequence, so no exit can be derived from it."
                continue
            }
        }
        elseif ($entryDirectionValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($entryDirectionValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom': the Direction value is empty, so no exit can be derived from it."
                continue
            }

            Write-Warning "The Direction value of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom' is a scalar, not a sequence; it is treated as the single exit of the sequence."
            $coercedExits = [System.Collections.Generic.List[object]]::new()
            $coercedExits.Add($entryDirectionValue)
            $entryDirectionValue = $coercedExits
        }
        elseif ($entryDirectionValue -is [System.Collections.IDictionary]) {
            Write-Warning "The Direction value of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom' is a single mapping, not a sequence; it is treated as the single exit of the sequence."
            $coercedExits = [System.Collections.Generic.List[object]]::new()
            $coercedExits.Add($entryDirectionValue)
            $entryDirectionValue = $coercedExits
        }
        else {
            throw "Cannot compress the RoomExits data of the RAGS file: the Direction value of the entry $($entryIndex + 1) of the file 'RoomExits.yaml' of the source folder of room '$stagedRoom' is of type '$($entryDirectionValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every exit of the entry is validated and staged inline below,
        # so that no exit of the entry appends a row before a later exit
        # of the same entry is fully validated.
        $entryRowsBefore = $stagedRows.Count
        for ($exitIndex = 0; $exitIndex -lt $entryDirectionValue.Count; $exitIndex++) {
            $exitValue = $entryDirectionValue[$exitIndex]
            if ($null -eq $exitValue) {
                Write-Warning "Skipping the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom': the exit is null."
                continue
            }
            if ($exitValue -isnot [System.Collections.IDictionary]) {
                throw "Cannot compress the RoomExits data of the RAGS file: the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitValue.GetType().FullName)' instead of a mapping."
            }

            # Ignore any unexpected key of the exit with a warning, as
            # the expansion writes exits with the Direction, Active,
            # DestinationRoom and PortalObjectName keys only.
            $exitExtraKeys = [System.Collections.Generic.List[string]]::new()
            foreach ($exitKey in $exitValue.Keys) {
                $exitKeyText = [string]$exitKey
                if ((-not [string]::Equals($exitKeyText, 'Direction', [System.StringComparison]::Ordinal)) -and
                    (-not [string]::Equals($exitKeyText, 'Active', [System.StringComparison]::Ordinal)) -and
                    (-not [string]::Equals($exitKeyText, 'DestinationRoom', [System.StringComparison]::Ordinal)) -and
                    (-not [string]::Equals($exitKeyText, 'PortalObjectName', [System.StringComparison]::Ordinal))) {
                    $exitExtraKeys.Add($exitKeyText)
                }
            }
            if ($exitExtraKeys.Count -gt 0) {
                $exitExtraKeyText = ($exitExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
                Write-Warning "The exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' defines the unexpected key(s) $exitExtraKeyText; they are ignored."
            }

            # Locate and validate the Direction value of the exit, which
            # the expansion writes as an integer scalar. A missing or
            # null Direction value contributes no exit (it is skipped
            # like the null-Direction rows of the expansion); a scalar of
            # any other type is parsed with the invariant culture.
            $exitDirectionValue = $exitValue['Direction']
            $exitDirection = $null
            if ($null -eq $exitDirectionValue) {
                Write-Warning "Skipping the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom': the Direction value is missing or null, so no exit can be derived from it."
                continue
            }

            if ($exitDirectionValue -is [System.Collections.IList]) {
                throw "Cannot compress the RoomExits data of the RAGS file: the Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a sequence where an integer scalar is expected."
            }
            elseif ($exitDirectionValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the RoomExits data of the RAGS file: the Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a mapping where an integer scalar is expected."
            }
            elseif (($exitDirectionValue -is [int]) -or ($exitDirectionValue -is [long])) {
                # The value is converted through a 64-bit intermediate
                # before the 32-bit assign, so that an integer beyond the
                # range of the int table column reports the contextual
                # rejection instead of a raw cast failure.
                $exitDirectionLong = [System.Convert]::ToInt64($exitDirectionValue)
                if (($exitDirectionLong -lt [int]::MinValue) -or ($exitDirectionLong -gt [int]::MaxValue)) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is a scalar which cannot be parsed as an integer."
                }
                $exitDirection = [int]$exitDirectionLong
            }
            else {
                $directionText = $null
                if ($exitDirectionValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($exitDirectionValue)) {
                        throw "Cannot compress the RoomExits data of the RAGS file: the Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is a scalar which cannot be parsed as an integer."
                    }
                    $directionText = $exitDirectionValue
                    Write-Warning "The Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitDirectionValue.GetType().FullName)' instead of an integer; it is parsed with the invariant culture."
                }
                else {
                    Write-Warning "The Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitDirectionValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                    if ($exitDirectionValue -is [System.IFormattable]) {
                        $directionText = $exitDirectionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $directionText = [string]$exitDirectionValue
                    }
                }

                $parsedDirection = 0
                if (-not [int]::TryParse($directionText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedDirection)) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the Direction of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is a scalar which cannot be parsed as an integer."
                }
                $exitDirection = $parsedDirection
            }

            # The Active value of the exit, which the expansion writes
            # as a boolean scalar read from the two-state column. The
            # staged value starts as the false the documented null bit
            # mapping reads (a missing or null Active value is read as
            # $false without a warning, like the expansion), a boolean
            # value is read as is, and an integer value which is 0 or 1
            # is read as the matching boolean with a warning.
            $stagedActive = $false
            $exitActiveValue = $exitValue['Active']
            if ($null -ne $exitActiveValue) {
                if ($exitActiveValue -is [System.Collections.IList]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a sequence where a boolean scalar is expected."
                }
                elseif ($exitActiveValue -is [System.Collections.IDictionary]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a mapping where a boolean scalar is expected."
                }
                elseif ($exitActiveValue -is [bool]) {
                    $stagedActive = [bool]$exitActiveValue
                }
                else {
                    $exitActiveIsInteger = ($exitActiveValue -is [int]) -or ($exitActiveValue -is [long])
                    if ($exitActiveIsInteger) {
                        # The value is converted to a 64-bit integer
                        # before the two-state comparison, so that an
                        # integer beyond the range of the 32-bit column
                        # reports the contextual rejection instead of a
                        # cast failure.
                        $exitActiveNumber = [System.Convert]::ToInt64($exitActiveValue)
                        if ($exitActiveNumber -eq 1) {
                            Write-Warning "The Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is the integer 1 instead of a boolean; it is stored as the boolean true."
                            $stagedActive = $true
                        }
                        elseif ($exitActiveNumber -eq 0) {
                            Write-Warning "The Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is the integer 0 instead of a boolean; it is stored as the boolean false."
                            $stagedActive = $false
                        }
                        else {
                            throw "Cannot compress the RoomExits data of the RAGS file: the Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitActiveValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
                        }
                    }
                    else {
                        throw "Cannot compress the RoomExits data of the RAGS file: the Active of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitActiveValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
                    }
                }
            }

            # The DestinationRoom value of the exit, which the expansion
            # writes as a string scalar. A missing or null value is
            # stored as the empty string without a warning, mirroring the
            # null-string emission rule of the expansion (a null column
            # value is emitted as the empty string); empty and
            # whitespace-only strings are kept as is; a scalar of any
            # other type is coerced to its invariant string form with a
            # warning.
            $stagedDestinationRoom = ''
            $exitDestinationRoomValue = $exitValue['DestinationRoom']
            if ($null -ne $exitDestinationRoomValue) {
                if ($exitDestinationRoomValue -is [System.Collections.IList]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the DestinationRoom of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a sequence where a scalar value is expected."
                }
                elseif ($exitDestinationRoomValue -is [System.Collections.IDictionary]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the DestinationRoom of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a mapping where a scalar value is expected."
                }
                elseif ($exitDestinationRoomValue -is [string]) {
                    $stagedDestinationRoom = $exitDestinationRoomValue
                }
                else {
                    Write-Warning "The DestinationRoom of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitDestinationRoomValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                    if ($exitDestinationRoomValue -is [System.IFormattable]) {
                        $stagedDestinationRoom = $exitDestinationRoomValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $stagedDestinationRoom = [string]$exitDestinationRoomValue
                    }
                }

                # A YAML literal block scalar normalizes line breaks to
                # line-feed characters when the written YAML is read
                # back - a parsed carriage return from a double-quoted
                # escape arrives as-is and is staged verbatim, like the
                # expansion family's verbatim contract.
                $stagedDestinationRoom = [string]$stagedDestinationRoom

                # Truncate the value to the length of the table column,
                # as a longer value could not be stored. The truncation
                # measures the as-parsed value (see above), as the stored
                # value is that value verbatim.
                if ($stagedDestinationRoom.Length -gt 250) {
                    Write-Warning "The DestinationRoom value of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is $($stagedDestinationRoom.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                    $stagedDestinationRoom = $stagedDestinationRoom.Substring(0, 250)
                }

                # The DestinationRoom value is always coerced to lowercase
                # ('Lowercase enforcement', docs/data-mapping.md, RoomExits
                # section), after the truncation above - the truncated
                # value is the value stored. The lowercasing is silent:
                # the appended rows simply carry the lowercase form, which
                # the expansion of the appended data reads and emits
                # unchanged.
                $stagedDestinationRoom = $stagedDestinationRoom.ToLowerInvariant()
            }

            # The PortalObjectName value of the exit, which the expansion
            # writes as a string scalar too. The storage rules are the
            # DestinationRoom rules above (a missing or null value
            # stored as the empty string without a warning, empty and
            # whitespace-only strings kept as is, other scalars coerced
            # with a warning, truncation after the coercion).
            $stagedPortalObjectName = ''
            $exitPortalObjectNameValue = $exitValue['PortalObjectName']
            if ($null -ne $exitPortalObjectNameValue) {
                if ($exitPortalObjectNameValue -is [System.Collections.IList]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the PortalObjectName of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a sequence where a scalar value is expected."
                }
                elseif ($exitPortalObjectNameValue -is [System.Collections.IDictionary]) {
                    throw "Cannot compress the RoomExits data of the RAGS file: the PortalObjectName of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' carries a mapping where a scalar value is expected."
                }
                elseif ($exitPortalObjectNameValue -is [string]) {
                    $stagedPortalObjectName = $exitPortalObjectNameValue
                }
                else {
                    Write-Warning "The PortalObjectName of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is of type '$($exitPortalObjectNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                    if ($exitPortalObjectNameValue -is [System.IFormattable]) {
                        $stagedPortalObjectName = $exitPortalObjectNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $stagedPortalObjectName = [string]$exitPortalObjectNameValue
                    }
                }

                $stagedPortalObjectName = [string]$stagedPortalObjectName

                if ($stagedPortalObjectName.Length -gt 250) {
                    Write-Warning "The PortalObjectName value of the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom' is $($stagedPortalObjectName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                    $stagedPortalObjectName = $stagedPortalObjectName.Substring(0, 250)
                }

                # The PortalObjectName value is always coerced to
                # lowercase too ('Lowercase enforcement',
                # docs/data-mapping.md, RoomExits section), after the
                # truncation above, except for the literal '<None>' value:
                # '<None>' is always passed through verbatim ('The string
                # value <None> is always passed through verbatim during
                # expansion and compression of PortalObjectName without
                # coercion', docs/data-mapping.md, RoomExits section). The
                # passthrough is case-insensitive, so any casing of the
                # value keeps its raw characters; every other value is
                # lowercased silently.
                if ([string]::Equals($stagedPortalObjectName, '<None>', [System.StringComparison]::OrdinalIgnoreCase)) {
                    # nothing to do: the raw characters of the passthrough
                    # value are kept
                }
                else {
                    $stagedPortalObjectName = $stagedPortalObjectName.ToLowerInvariant()
                }
            }

            # Soft-validate the Unique Direction column: the Direction
            # values of a room are expected to contain only distinct
            # values ('If multiple identical Directions exist for the
            # same RoomID value, then only the first row's column values
            # will be read', docs/data-mapping.md, RoomExits section), so
            # an exit which repeats the exactly read Direction value of
            # its room is skipped with a warning (the column values of
            # the first read exit win, like the expansion). The
            # Direction-value set of the room is shared by every entry of
            # the room, including merged case-mate entries and hand-edited
            # repeated entries. A NULL Direction never reaches this check
            # (it is skipped above). All staged values were derived before
            # the duplicate check, so the warning reports the normalized
            # column values of the ignored exit itself ('A warning
            # containing the values of subsequent ignored duplicate rows
            # will be shown', docs/data-mapping.md, RoomExits section):
            # integer Direction values are reported without quotes,
            # boolean Active values are reported as the boolean they were
            # read as (a missing or null Active reports as the false it
            # was read as), and the normalized DestinationRoom and
            # PortalObjectName values are quoted, with the raw missing
            # keys keeping the <null> token (a null source value stages
            # the empty string, mirroring the null-string emission rule
            # of the expansion).
            if (-not $directionSet.Add($exitDirection)) {
                $duplicateEvidence = [System.Collections.Generic.List[string]]::new()
                $duplicateEvidence.Add("Direction $exitDirection")
                $duplicateEvidence.Add("Active equals $stagedActive after reading")
                if ($null -eq $exitDestinationRoomValue) {
                    $duplicateEvidence.Add('DestinationRoom <null>')
                }
                else {
                    $duplicateEvidence.Add("DestinationRoom '$stagedDestinationRoom'")
                }
                if ($null -eq $exitPortalObjectNameValue) {
                    $duplicateEvidence.Add('PortalObjectName <null>')
                }
                else {
                    $duplicateEvidence.Add("PortalObjectName '$stagedPortalObjectName'")
                }
                $duplicateEvidenceText = $duplicateEvidence -join ', '
                Write-Warning "Skipping the exit $($exitIndex + 1) of the entry $($entryIndex + 1) for room '$stagedRoom': the Direction value $exitDirection duplicates the Direction value of a previously read exit (whose column values win). The ignored duplicate exit has the column values $duplicateEvidenceText."
                continue
            }

            $stagedRows.Add([pscustomobject]@{
                RoomID             = $stagedRoom
                Direction          = $exitDirection
                Active             = $stagedActive
                DestinationRoom    = $stagedDestinationRoom
                PortalObjectName   = $stagedPortalObjectName
                EntryIndex         = $entryIndex + 1
                ExitIndex          = $exitIndex + 1
            })
        }

        if ($stagedRows.Count -gt $entryRowsBefore) {
            $contributingEntries.Add($entryIndex + 1)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the RoomExits table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the exit $($stagedRow.ExitIndex) of the entry $($stagedRow.EntryIndex) (room '$($stagedRow.RoomID)') to the RoomExits table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [RoomExits] ([RoomID], [Direction], [Active], [DestinationRoom], [PortalObjectName]) VALUES (@roomid, @direction, @active, @destinationroom, @portalobjectname)'

                    $roomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@roomid', [System.Data.SqlDbType]::NVarChar, 250)
                    $roomParameter.Value = $stagedRow.RoomID
                    $null = $command.Parameters.Add($roomParameter)

                    $directionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@direction', [System.Data.SqlDbType]::Int)
                    $directionParameter.Value = $stagedRow.Direction
                    $null = $command.Parameters.Add($directionParameter)

                    $activeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@active', [System.Data.SqlDbType]::Bit)
                    $activeParameter.Value = $stagedRow.Active
                    $null = $command.Parameters.Add($activeParameter)

                    $destinationRoomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@destinationroom', [System.Data.SqlDbType]::NVarChar, 250)
                    # The staged text values are always strings (a null
                    # source value stages the empty string), so the text
                    # parameters bind their staged values directly.
                    $destinationRoomParameter.Value = $stagedRow.DestinationRoom
                    $null = $command.Parameters.Add($destinationRoomParameter)

                    $portalObjectNameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@portalobjectname', [System.Data.SqlDbType]::NVarChar, 250)
                    $portalObjectNameParameter.Value = $stagedRow.PortalObjectName
                    $null = $command.Parameters.Add($portalObjectNameParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the RoomExits table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The RoomExits transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the RoomExits data of the RAGS file: the staged rows could not be appended to the RoomExits table. "
            $message += "The database reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }
        finally {
            if ($null -ne $transaction) {
                $transaction.Dispose()
            }
        }
    }
    else {
        Write-Verbose 'No rows were staged, so no transaction is opened.'
    }

    Write-Verbose "Compressed the RoomExits data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

