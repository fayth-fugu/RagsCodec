#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-RoomActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses RoomActions data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded RoomActions data of a source folder back into the
    RoomActions table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-RoomActionsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    Every '.yaml' file of the 'RoomActions' subfolder of the source folder
    is read as a YAML document mapping an RoomID value to a Data sequence of
    RAGS action expansions. Each sequence entry is converted from the
    pretty-printed XML of the entry into its encoded RAGS action form (four
    padding bytes followed by a GZip stream, Base64-encoded) through
    Compress-RagsActionFromXml. One table row is appended per entry (the
    Identity column value is supplied by the database), replicating the row
    order of the original expansion: source files are read in file name
    order, the entries of each file keep their YAML sequence order, and the
    Identity values of the appended rows grow in insertion order, so
    re-expanding the appended data restores each room's entries in ascending
    row ID order.

    The YAML files of the subfolder are consumed as follows:
    - A file which defines more than one YAML document is consumed from its
      first document only, with a warning naming the file and the number of
      ignored extra documents.
    - A YAML document which is not a mapping (for example a scalar or a
      sequence), an RoomID value which is not a string, a Data value which
      is neither a string scalar nor a sequence (for example a YAML mapping
      or an unquoted number), a Data entry which is not a string, and a
      non-empty Data entry whose content is not well-formed XML abort the
      whole operation with an exception, as no meaningful RAGS action can be
      derived from them.
    - A mapping defining keys other than 'RoomID' and 'Data' is accepted
      with one warning naming the unexpected keys; the unexpected keys are
      ignored.
    - A file whose RoomID value is missing, null, empty or whitespace-only
      is skipped in its entirety with a warning, as no meaningful expansion
      target could be derived from it (its rows may therefore not survive a
      compress/expand cycle and its Data values are discarded).
    - An RoomID value longer than the 250 characters of the table column is
      truncated with a warning; note that re-expanding the appended data
      then derives a different file name from the truncated value.
    - The List-column values of the RoomActions table are documented as
      case-insensitive and always coerced to lowercase ('Values are
      case-insensitive' / 'Always coerced to lowercase' in the RoomActions
      section of docs/data-mapping.md), so every accepted RoomID value is
      lowercased with ToLowerInvariant (after its truncation, before the
      file-name and case-mate checks), and every appended row carries the
      lowercased form (the re-expansion of the appended data lowercases its
      read values anyway, so these rows re-expand with their RoomID value
      unchanged).
    - The file names of the subfolder are never interpreted: the RoomID
      value of the contents is the truth, so the file name an expansion
      originally wrote is silently irrelevant. An RoomID value which cannot
      form a valid Windows file name (because it contains characters that
      are invalid in file names, ends with a dot or a space, or names a
      reserved device such as CON, NUL or COM1) still contributes its rows,
      since the value itself is stored lowercased and no file is created
      from it here; a warning reports that re-expanding the appended data
      skips these rows as documented (the warning fires when the RoomID
      value is accepted, before the file's Data value is validated).
    - RoomID values of two files which differ only in character case would
      re-expand into one file, since the expansion groups RoomID values
      case-insensitively; such files are therefore merged - every file
      whose raw RoomID value differs from the first-read raw value of its
      set of case mates (the file whose name sorts first reads first) is
      reported with one warning which cites the lowercased value on both
      sides, and the appended rows of all such files carry one common
      lowercased RoomID value. The warning fires when the RoomID value is
      accepted, so a case mate whose Data value is skipped entirely is
      merge-reported in addition to its skip warning. RoomID values which
      are exactly equal in other files are appended without a warning, as
      append-only accumulation is the documented caller workflow.
    - A file whose Data value is missing, null, empty or whitespace-only,
      or whose Data sequence is empty, contributes no rows and is skipped
      with a warning.
    - A Data value which is a string scalar (instead of a sequence) is
      accepted as the single entry of the sequence with a warning; a scalar
      Data value which is empty or whitespace-only is treated like a missing
      Data value.
    - Individual entries which are null, empty or whitespace-only are
      skipped with a warning.

    Every file of the subfolder is read, validated and encoded before the
    first row is appended, so the table remains empty when the source
    folder carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no partially
    appended data behind.

    The RoomActions subfolder is read silently; a missing source folder or
    subfolder is not an error and compresses nothing. Files of any other
    extension are skipped with a warning.

    Compressed rows are appended to the RoomActions table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template file,
    or a blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the RoomActions data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the RoomActions data has been
    compressed successfully.

    .EXAMPLE
    Compress-RoomActionsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the RoomActions data of the 'C:\Export\MyGame' folder to the
    RAGS file connected through $openRagsConnection.
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
        throw "Cannot compress the RoomActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'RoomActions' subfolder: no
    # expansion may have happened yet, in which case there is nothing to
    # compress.
    $roomActionsFolder = Join-Path $SourcePath 'RoomActions'
    if (-not (Test-Path -LiteralPath $roomActionsFolder -PathType Container)) {
        Write-Verbose "The source folder carries no 'RoomActions' subfolder, so there is no RoomActions data to compress."
        return $true
    }
    Write-Verbose "Compressing the RoomActions data of the RAGS file from '$roomActionsFolder'."

    # Collect the files of the subfolder in file name order, so that a given
    # room always receives its rows in a stable and reproducible order, and
    # so that the first-read raw value of a set of case-mate rooms is
    # decided by the file whose name sorts first. The names are sorted
    # ordinally, so that the order does not depend on the culture of the
    # host. The expansion writes everything as '.yaml' files; anything else
    # is skipped with a warning.
    Write-Verbose "Reading the YAML files of '$roomActionsFolder'."
    $filesByName = @{}
    foreach ($foundFile in @(Get-ChildItem -LiteralPath $roomActionsFolder -File)) {
        $filesByName[$foundFile.Name] = $foundFile
    }
    $yamlFileNames = [System.Collections.Generic.List[string]]::new()
    foreach ($foundFileName in $filesByName.Keys) {
        $yamlFileNames.Add($foundFileName)
    }
    $yamlFileNames.Sort([System.StringComparer]::Ordinal)
    Write-Verbose "Found $($yamlFileNames.Count) file(s) in the 'RoomActions' subfolder."

    # Characters that are invalid in file names on the current file system.
    # The array includes control characters (tab and line-break characters
    # included) on both supported hosts.
    $invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()

    # Stage one row per Data entry before appending anything, so that
    # nothing is written when any source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged value
    # carries the room id, the source file name and the 1-based entry index
    # which produced it for the messages of the append phase, and the
    # Base64-encoded RAGS action payload. The validation of every entry is
    # performed inline below, so that each file is fully validated (and
    # every failure reported) before any file contributes rows.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingFileNames = [System.Collections.Generic.List[string]]::new()

    # The RoomID value groups are tracked as parallel lists keyed by the
    # canonical lowercased value: the group names are the RoomID values of
    # the appended rows, and the raw names keep the pre-lowercasing value
    # of the file which opened the group, so that a later case mate whose
    # raw value differs from it is merge-reported (the expansion of the
    # appended data writes such rows back into one file).
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()

    foreach ($yamlFileName in $yamlFileNames) {
        $file = $filesByName[$yamlFileName]
        if (-not [System.String]::Equals($file.Extension, '.yaml', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Skipping the file '$($file.Name)' of the RoomActions subfolder: it does not have a '.yaml' extension."
            continue
        }

        # Read the whole file as text ([System.IO.File]::ReadAllText
        # auto-detects the UTF-8/UTF-16 byte-order marks and defaults to
        # UTF-8, which matches the encoding the expansion writes).
        try {
            $fileText = [System.IO.File]::ReadAllText($file.FullName)
        }
        catch {
            $message = "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder could not be read. "
            $message += "The file system reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        if ([string]::IsNullOrWhiteSpace($fileText)) {
            throw "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder is empty."
        }

        # Parse the file as a YAML multi-document stream. A file which
        # defines more than one document is consumed from its first
        # document only, with a warning about the extra documents (the
        # expansion writes exactly one mapping per file, so extra documents
        # in a source folder are usually leftovers of a manual edit).
        try {
            $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
        }
        catch {
            $message = "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder is not a valid YAML document. "
            $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # ConvertFrom-Yaml returns the parsed value of a single document
        # directly (a mapping, a sequence or a scalar, as read), the values
        # of multiple documents as an object array, and no value at all for
        # an empty stream. Extra documents are ignored with a warning, as
        # the first document alone determines the appended rows.
        if ($parsedDocuments.Count -gt 1) {
            Write-Warning "The file '$($file.Name)' of the RoomActions subfolder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
        }
        if ($parsedDocuments.Count -lt 1) {
            throw "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder carries no YAML document."
        }

        $mapping = $parsedDocuments[0]
        if ($null -eq $mapping) {
            throw "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder carries no YAML document."
        }
        if ($mapping -isnot [System.Collections.IDictionary]) {
            if ($mapping -is [string]) {
                $actualType = 'a scalar'
            }
            elseif ($mapping -is [System.Collections.IList]) {
                $actualType = 'a sequence'
            }
            else {
                $actualType = "a value of type '$($mapping.GetType().FullName)'"
            }

            throw "Cannot compress the RoomActions data of the RAGS file: the file '$($file.Name)' of the RoomActions subfolder carries $actualType where a mapping is expected."
        }

        # Resolve the RoomID and Data values of the mapping by key, so that
        # the key comparison does not depend on the dictionary semantics of
        # the YAML reader: the expansion writes 'RoomID' and 'Data' exactly,
        # and any other key (a case variant included) counts as unexpected.
        $roomIdValue = $null
        $dataValue = $null
        $unexpectedKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($documentKey in $mapping.Keys) {
            $documentKeyText = [string]$documentKey
            if ([string]::Equals($documentKeyText, 'RoomID', [System.StringComparison]::Ordinal)) {
                $roomIdValue = $mapping[$documentKey]
            }
            elseif ([string]::Equals($documentKeyText, 'Data', [System.StringComparison]::Ordinal)) {
                $dataValue = $mapping[$documentKey]
            }
            else {
                $unexpectedKeys.Add($documentKeyText)
            }
        }
        if ($unexpectedKeys.Count -gt 0) {
            $unexpectedKeyText = ($unexpectedKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The file '$($file.Name)' of the RoomActions subfolder defines the unexpected key(s) $unexpectedKeyText; they are ignored."
        }

        # Locate and validate the RoomID value of the mapping, which is
        # expected to be the string scalar the expansion wrote.
        if ($null -eq $roomIdValue) {
            Write-Warning "Skipping the file '$($file.Name)' of the RoomActions subfolder: the RoomID value is missing or null, so no room can be derived for it."
            continue
        }
        if ($roomIdValue -isnot [string]) {
            throw "Cannot compress the RoomActions data of the RAGS file: the RoomID value of the file '$($file.Name)' is of type '$($roomIdValue.GetType().FullName)' instead of a string."
        }
        if ([string]::IsNullOrWhiteSpace($roomIdValue)) {
            Write-Warning "Skipping the file '$($file.Name)' of the RoomActions subfolder: the RoomID value is empty, so no room can be derived for it."
            continue
        }

        # Truncate the RoomID value to the length of the table column, as a
        # longer value could not be stored. The value is truncated before
        # the file-name and case-mate checks below, so that the stored value
        # is what they validate (the warning above cites the pre-truncation
        # length, so the value is only cut afterwards).
        $roomId = $roomIdValue
        if ($roomId.Length -gt 250) {
            Write-Warning "The RoomID value of the file '$($file.Name)' is $($roomId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different file name from the truncated value."
            $roomId = $roomId.Substring(0, 250)
        }

        # The List-column values of the RoomActions table are documented as
        # case-insensitive and always coerced to lowercase ('Values are
        # case-insensitive' / 'Always coerced to lowercase' in the
        # RoomActions section of docs/data-mapping.md), so the truncated raw
        # value is lowered with ToLowerInvariant (the invariant result is
        # independent of the current culture). Everything below - the
        # file-name checks, the case-mate grouping and the appended rows -
        # works with and cites this lowercased form; the raw value is kept
        # only for the merge reporting of the case-mate grouping. The
        # expansion of the appended data lowercases its read values anyway,
        # so the lowercased rows re-expand with their RoomID value
        # unchanged.
        $roomIdRaw = $roomId
        $roomId = $roomIdRaw.ToLowerInvariant()

        # An RoomID value which cannot form a valid file name still
        # contributes its rows, as the file name of an expansion is never
        # interpreted here; the round-trip loss is reported as soon as the
        # value is accepted (all three checks are case-agnostic, so running
        # them on the lowercased value changes no outcome).
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
            Write-Warning "The RoomID value of the file '$($file.Name)' of room '$roomId' cannot form a valid file name because $fileNameProblem; the rows are appended with this RoomID value, but re-expanding the appended data skips these rows as documented."
        }

        # Locate or create the group of the room. The lowercased value is
        # canonical, so the lookup compares ordinal against it (a
        # case-insensitive comparison would change no outcome). The
        # first-read raw value is kept per group, and a file whose raw value
        # differs from it is merged with a warning which cites the
        # lowercased value on both sides; the first-read file of a case mate
        # set and files repeating its raw value merge without a warning. The
        # warning fires as soon as the value is accepted - like every other
        # RoomID-value warning, before the Data value of the file is
        # validated.
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
            $groupRawNames.Add($roomIdRaw)
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $roomIdRaw, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the rows of the file '$($file.Name)' of room '$roomId' into the rows of room '$($groupNames[$groupIndex])': the raw RoomID value differs only in character case and is merged into the lowercased rows."
        }

        # Every appended row of the file carries the group's RoomID value
        # (the lowercased form common to its set of case mates).
        $stagedRoomId = $groupNames[$groupIndex]

        # Locate and validate the Data value of the mapping, which is a
        # sequence of pretty-printed XML action expansions. A scalar value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        if ($null -eq $dataValue) {
            Write-Warning "Skipping the file '$($file.Name)' of room '$roomId': the Data value is missing or null, so no data can be derived from it."
            continue
        }

        if ($dataValue -is [System.Collections.IList]) {
            if ($dataValue.Count -eq 0) {
                Write-Warning "Skipping the file '$($file.Name)' of room '$roomId': the Data value is an empty sequence, so no data can be derived from it."
                continue
            }
        }
        elseif ($dataValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($dataValue)) {
                Write-Warning "Skipping the file '$($file.Name)' of room '$roomId': the Data value is empty, so no data can be derived from it."
                continue
            }

            Write-Warning "The Data value of the file '$($file.Name)' of room '$roomId' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($dataValue)
            $dataValue = $coercedEntries
        }
        else {
            throw "Cannot compress the RoomActions data of the RAGS file: the Data value of the file '$($file.Name)' of room '$roomId' is of type '$($dataValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every Data entry is validated and encoded before any row of the
        # file is staged.
        $fileRowsBefore = $stagedRows.Count
        for ($entryIndex = 0; $entryIndex -lt $dataValue.Count; $entryIndex++) {
            $entryValue = $dataValue[$entryIndex]

            if ($null -eq $entryValue) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for room '$stagedRoomId': the entry is null."
                continue
            }
            if ($entryValue -isnot [string]) {
                throw "Cannot compress the RoomActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for room '$stagedRoomId' is of type '$($entryValue.GetType().FullName)' instead of a string."
            }
            if ([string]::IsNullOrWhiteSpace($entryValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for room '$stagedRoomId': the entry is empty."
                continue
            }

            # Compress the pretty-printed XML snippet into its encoded RAGS
            # action form; the snippet is linearized (its line breaks
            # stripped by the XML writer) by the compressor, as the
            # payload is usually stored linearized.
            try {
                $encodedAction = Compress-RagsActionFromXml -XmlRagsAction $entryValue
            }
            catch {
                $message = "Cannot compress the RoomActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for room '$stagedRoomId' could not be compressed as a RAGS action. "
                $message += "The compression reported the following error: '$($_.Exception.Message)'."
                throw [System.Exception]::new($message, $_.Exception)
            }

            $stagedRows.Add([pscustomobject]@{
                RoomID = $stagedRoomId
                FileName = $file.Name
                EntryIndex = $entryIndex + 1
                Payload = $encodedAction
            })
        }

        if ($stagedRows.Count -gt $fileRowsBefore) {
            $contributingFileNames.Add($file.Name)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the RoomActions table inside one
        # transaction, so that a failed INSERT leaves no partially appended
        # data behind. The values are bound through provider parameters
        # throughout, as the text values are not SQL literals (and the
        # payloads are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) of the file '$($stagedRow.FileName)' for room '$($stagedRow.RoomID)' to the RoomActions table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [RoomActions] ([RoomID], [Data]) VALUES (@roomid, @data)'

                    $roomParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@roomid', [System.Data.SqlDbType]::NVarChar, 250)
                    $roomParameter.Value = $stagedRow.RoomID
                    $null = $command.Parameters.Add($roomParameter)

                    $dataParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@data', [System.Data.SqlDbType]::NText)
                    $dataParameter.Value = $stagedRow.Payload
                    $null = $command.Parameters.Add($dataParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the RoomActions table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The RoomActions transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the RoomActions data of the RAGS file: the staged rows could not be appended to the RoomActions table. "
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

    Write-Verbose "Compressed the RoomActions data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingFileNames.Count) file(s)."
    return $true
}

