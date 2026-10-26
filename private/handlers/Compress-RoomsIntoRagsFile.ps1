#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-RoomsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses Rooms data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded Rooms data of a source folder back into the
    Rooms table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-RoomsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'Rooms.yaml' file of the source folder is read as a YAML
    document holding a top-level 'Rooms' mapping whose value is a
    sequence with one entry per room, each mapping the nine columns of
    the Rooms table: the UniqueID key and the other eight column
    values. One table row is appended per room entry (the Rooms table
    holds no identity column), replicating the row order of the
    original expansion: entries keep their YAML sequence order, which
    is the ascending UniqueID order of the original table read ("Table
    is sorted by UniqueID ascending", docs/data-mapping.md, Rooms
    section).

    The 'Rooms.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'Rooms' envelope
      around the entry sequence, so a non-mapping document predates this
      layout). Keys of the document other than the 'Rooms' envelope key
      are ignored with a warning.
    - A document whose Rooms value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      A Rooms value which is an empty sequence is treated like the
      empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - A Rooms value which is a scalar or a single mapping (as
      hand-edited files omitting the trailing sequence dash commonly
      are) is accepted as the single entry of the sequence with a
      warning, and the single entry then follows the entry rules below
      (a scalar entry aborts the whole operation with the contextual
      entry exception). A Rooms value which is a scalar but not a
      string is derived to its string form with a further warning, the
      string form of format-sensitive values being derived with the
      invariant culture, so the coerced entry carries its round-tripping
      value across hosts of different cultures.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful row can be derived from it.
    - An entry whose UniqueID value is missing, null, empty or
      whitespace-only is skipped in its entirety with a warning, as no
      room entry key can be derived from it. An entry whose UniqueID
      value is a sequence or a mapping aborts the whole operation with
      an exception; a UniqueID value which is a scalar but not a string
      (a hand-edited unquoted number, for example) is coerced to its
      string form with a warning, the string form of format-sensitive
      values being derived with the invariant culture.
    - A UniqueID value longer than the 250 characters of the table
      column is truncated to them with a warning, truncating before the
      lowercasing and the duplicate check below; note that re-expanding
      the appended data then derives a different entry from the
      truncated value.
    - The lowercased columns (the UniqueID key and the RoomPic and
      LayeredRoomPic picture columns) are always stored with the
      casing the documented Unique handling and the 'Lowercase
      enforcement' rule of the expansion produce ('Always coerced to
      lowercase' on the Unique handling and 'Lowercase enforcement'
      scoped to the two picture columns, docs/data-mapping.md, Rooms
      section), so that re-expanding the appended data normalizes the
      entry the same way again. A value which differs from its
      lowercase form is warned about once before it is stored
      lowercased, citing the value and its lowercase form, mirroring
      the expansion which warns the same way per written value (a
      hand-made mixed-case value is therefore never stored unflagged).
    - The special string 'None' of the picture columns is always
      passed through verbatim ('The string value None is always passed
      through verbatim during expansion and compression of RoomPic and
      LayeredRoomPic without coercion', docs/data-mapping.md, Rooms
      section): the passthrough matches case-insensitively, so any
      casing of the value is stored with its own characters, and such
      a value needs no lowercasing warning.
    - An entry which repeats the UniqueID value of a previously read
      entry, ignoring character case, is skipped with a warning which
      names the column values of the ignored duplicate entry (the
      column values of the first read entry win), as the documentation
      requires ('If multiple identical UniqueIDs exist, then only the
      first row's column values will be read' and 'A warning containing
      the values of subsequent ignored duplicate rows will be shown',
      docs/data-mapping.md, Rooms section).
    - A text column value (Description, SDesc, Name, RoomPic,
      LayeredRoomPic and Group) which is a scalar but not a string (a
      hand-edited unquoted number, for example) is coerced to its
      string form with a warning; the string form of format-sensitive
      values is derived with the invariant culture, so such a value
      round-trips through hosts of different cultures. Text values
      longer than the 250 characters of their table column are
      truncated with a warning. The truncation of the two picture
      columns runs before their lowercasing, so a lowercasing warning
      cites the truncated value; the Group value in particular is
      stored verbatim, without casing rules of any kind ('Lowercase
      enforcement' covers the two picture columns only).
    - The Description value (which never carries a length limit) is
      stored with the same scalar coercion as the text columns, with no
      line-ending normalization applied (the verbatim contract of the
      expansion family — note that a multi-line value re-emits through
      a YAML literal block, whose re-read normalizes the written breaks
      to line feeds; a parsed carriage return from a double-quoted
      '\r' escape is staged verbatim).
    - A bit column value (EnterFirstTime, LeaveFirstTime) which is
      missing or null is stored as false without a warning, as the
      expansion emits a YAML false for a null bit column. A bit column
      value which is a boolean is stored as read; an integer scalar of
      1 or 0 is accepted with a warning; a value of any other type or
      content aborts the whole operation with an exception.
    - Null text and Description values are stored as the empty string,
      mirroring the null-string emission rule of the expansion (a null
      column value is emitted as the empty string).
    - Keys of an entry other than the nine column names are ignored
      with a warning.

    The 'Rooms.yaml' file is read, validated and fully staged before
    the first row is appended, so the table remains empty when the
    source folder carries invalid content. The appended rows are then
    written inside a transaction, so a failure while appending leaves
    no partially appended data behind.

    The 'Rooms.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the Rooms table, which is expected
    to receive them (the RAGS Designer workflow of compressing expanded
    data keeps the convention of starting from the template file, or a
    blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the Rooms data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Rooms data has been
    compressed successfully.

    .EXAMPLE
    Compress-RoomsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded Rooms data of the 'C:\Export\MyGame' folder
    to the Rooms table of the RAGS file connected through
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
        throw "Cannot compress the Rooms data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'Rooms.yaml' file: no
    # expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'Rooms.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'Rooms.yaml' file, so there is no Rooms data to compress."
        return $true
    }
    Write-Verbose "Compressing the Rooms data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the Rooms data of the RAGS file: the file 'Rooms.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the Rooms data of the RAGS file: the file 'Rooms.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the Rooms data of the RAGS file: the file 'Rooms.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'Rooms.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values
    # of multiple documents as an object array, and no value at all for
    # an empty or comment-only stream. A missing value after the parse
    # is therefore reported like a missing document.
    $rootDocument = $null
    if ($parsedDocuments.Count -gt 0) {
        $rootDocument = $parsedDocuments[0]
    }
    if ($null -eq $rootDocument) {
        throw "Cannot compress the Rooms data of the RAGS file: the file 'Rooms.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the Rooms data of the RAGS file: the file 'Rooms.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'Rooms' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'Rooms', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'Rooms.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that
    # a missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['Rooms']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'Rooms.yaml' of the source folder: the Rooms value is missing or null, so no room data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'Rooms.yaml' of the source folder: the Rooms value is empty, so no room data can be derived from it."
        }
        else {
            Write-Warning "The Rooms value of the file 'Rooms.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The Rooms value of the file 'Rooms.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        # The full envelope ladder of the other compressors (Characters,
        # ItemGroups, ItemLayeredZoneLevels, ItemProperties): a scalar
        # envelope of any type is classified and handed to the entry
        # validation as the single entry of the sequence, a non-string
        # scalar being derived to its invariant string form with a
        # further warning (the string form of format-sensitive values
        # keeps its round-tripping form across hosts). The coerced value
        # is a scalar, so the entry validation below then throws the
        # contextual scalar-entry message before any row can be staged.
        Write-Warning "The Rooms value of the file 'Rooms.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
        if ($envelopeValue -isnot [string]) {
            Write-Warning "The Rooms value of the file 'Rooms.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($envelopeValue -is [System.IFormattable]) {
                $coercedEnvelopeValue = $envelopeValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $coercedEnvelopeValue = [string]$envelopeValue
            }
            $envelopeValue = $coercedEnvelopeValue
        }
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }

    # Stage one row per room entry before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the nine column values of the row and the 1-based
    # entry index which produced it for the messages of the append
    # phase. The validation of every entry is performed inline below,
    # so that the file is fully validated (and every failure reported)
    # before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The lowercased UniqueID values of the entries whose rows were
    # staged are kept separately so that the duplicate check below can
    # compare them in the stored form (the Unique semantics follow the
    # case-insensitive database collation, and the stored values are
    # always lowercased, so ordinal comparisons of the stored values
    # both mirror the documented check and cannot miss any case mate).
    $admittedUniqueIds = [System.Collections.Generic.List[string]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the Rooms data of the RAGS file: the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Locate and validate the UniqueID value of the entry, which is
        # expected to be the string scalar the expansion wrote. A
        # non-string scalar (a hand-edited unquoted number, for example)
        # is coerced to its string form with a warning, mirroring the
        # tolerant scalar ladder of the other text columns; a sequence
        # or a mapping value aborts the whole operation.
        $entryUniqueId = $entryValue['UniqueID']
        if ($null -eq $entryUniqueId) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder: the UniqueID value is missing or null, so no room entry can be derived for it."
            continue
        }
        if ($entryUniqueId -is [System.Collections.IList]) {
            throw "Cannot compress the Rooms data of the RAGS file: the UniqueID of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        if ($entryUniqueId -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Rooms data of the RAGS file: the UniqueID of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        if ($entryUniqueId -isnot [string]) {
            Write-Warning "The UniqueID of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($entryUniqueId.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryUniqueId -is [System.IFormattable]) {
                $entryUniqueId = $entryUniqueId.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $entryUniqueId = [string]$entryUniqueId
            }
        }
        if ([string]::IsNullOrWhiteSpace($entryUniqueId)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder: the UniqueID value is empty, so no room entry can be derived for it."
            continue
        }

        # Truncate the UniqueID value to the length of the table column
        # (before the lowercasing and the duplicate check below), as a
        # longer value could not be stored.
        $uniqueId = $entryUniqueId
        if ($uniqueId.Length -gt 250) {
            Write-Warning "The UniqueID of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($uniqueId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry from the truncated value."
            $uniqueId = $uniqueId.Substring(0, 250)
        }

        # Store the UniqueID value lowercased, mirroring the documented
        # Unique handling of the expansion (docs/data-mapping.md, Rooms
        # section: 'Values are case-insensitive' and 'Always coerced to
        # lowercase'), so that re-expanding the appended data keys the
        # entry lowercase again. The lowercasing is warned about once
        # per value which differs from its lowercase form, citing the
        # value and its lowercase form (the expansion warns the same
        # way per written value during expansion, so a hand-made
        # mixed-case value never reaches the database unflagged); the
        # warning cites the truncated value, as the truncation above
        # runs first.
        $uniqueIdLowercased = $uniqueId.ToLowerInvariant()
        if (-not [string]::Equals($uniqueIdLowercased, $uniqueId, [System.StringComparison]::Ordinal)) {
            Write-Warning "The UniqueID value '$uniqueId' of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is coerced to its lowercase form '$uniqueIdLowercased' during compression."
        }
        $uniqueId = $uniqueIdLowercased

        # The Description value is stored as read, verbatim: no
        # line-ending normalization is applied (the expansion family's
        # verbatim contract — a multi-line value re-emits through a
        # YAML literal block whose re-read normalizes the written
        # breaks to line feeds, while a parsed carriage return from a
        # double-quoted escape arrives as-is). Like every ntext column
        # it holds no length limit to truncate to, and the value is
        # derived BEFORE the duplicate evidence below so that the
        # warning reports the recorded value. A null text value stages
        # the empty string, mirroring the null-string emission rule of
        # the expansion (a null column value is emitted as the empty
        # string); the duplicate evidence tests the raw parsed value,
        # not the staged one.
        $descriptionValue = $entryValue['Description']
        $description = ''
        if ($null -ne $descriptionValue) {
            if ($descriptionValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($descriptionValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($descriptionValue -is [string]) {
                $description = $descriptionValue
            }
            else {
                Write-Warning "The Description of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($descriptionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($descriptionValue -is [System.IFormattable]) {
                    $description = $descriptionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $description = [string]$descriptionValue
                }
            }
        }

        $sdescValue = $entryValue['SDesc']
        $sdesc = ''
        if ($null -ne $sdescValue) {
            if ($sdescValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the SDesc of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($sdescValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the SDesc of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($sdescValue -is [string]) {
                $sdesc = $sdescValue
            }
            else {
                Write-Warning "The SDesc of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($sdescValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($sdescValue -is [System.IFormattable]) {
                    $sdesc = $sdescValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $sdesc = [string]$sdescValue
                }
            }

            if ($sdesc.Length -gt 250) {
                Write-Warning "The SDesc of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($sdesc.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $sdesc = $sdesc.Substring(0, 250)
            }
        }

        $nameValue = $entryValue['Name']
        $name = ''
        if ($null -ne $nameValue) {
            if ($nameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($nameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($nameValue -is [string]) {
                $name = $nameValue
            }
            else {
                Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($nameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($nameValue -is [System.IFormattable]) {
                    $name = $nameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $name = [string]$nameValue
                }
            }

            if ($name.Length -gt 250) {
                Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($name.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $name = $name.Substring(0, 250)
            }
        }

        # The RoomPic value follows the text ladder above, with the
        # documented lowercase enforcement applied on top ('Lowercase
        # enforcement', docs/data-mapping.md, Rooms section): the value
        # is truncated first, then the literal 'None' is passed through
        # verbatim ('The string value None is always passed through
        # verbatim during expansion and compression of RoomPic without
        # coercion', docs/data-mapping.md, Rooms section — the
        # passthrough matches case-insensitively, so any casing of the
        # value keeps its raw characters), while every other value is
        # warned about once when it differs from its lowercase form
        # (the expansion warns the same way per written value) and is
        # then stored lowercased.
        $roomPicValue = $entryValue['RoomPic']
        $roomPic = ''
        if ($null -ne $roomPicValue) {
            if ($roomPicValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the RoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($roomPicValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the RoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($roomPicValue -is [string]) {
                $roomPic = $roomPicValue
            }
            else {
                Write-Warning "The RoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($roomPicValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($roomPicValue -is [System.IFormattable]) {
                    $roomPic = $roomPicValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $roomPic = [string]$roomPicValue
                }
            }

            if ($roomPic.Length -gt 250) {
                Write-Warning "The RoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($roomPic.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $roomPic = $roomPic.Substring(0, 250)
            }

            if ([string]::Equals($roomPic, 'None', [System.StringComparison]::OrdinalIgnoreCase)) {
                $roomPic = [string]$roomPic
            }
            else {
                $roomPicLowercased = $roomPic.ToLowerInvariant()
                if (-not [string]::Equals($roomPicLowercased, $roomPic, [System.StringComparison]::Ordinal)) {
                    Write-Warning "The RoomPic value '$roomPic' of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is coerced to its lowercase form '$roomPicLowercased' during compression."
                }
                $roomPic = $roomPicLowercased
            }
        }

        # The managed reader of the expansion reads bit columns as
        # Boolean values, so the YAML counterparts are booleans; a
        # missing or null value is stored as the documented false.
        $enterFirstTimeValue = $entryValue['EnterFirstTime']
        $enterFirstTime = $false
        if ($enterFirstTimeValue -is [bool]) {
            $enterFirstTime = $enterFirstTimeValue
        }
        elseif ($null -ne $enterFirstTimeValue) {
            if (($enterFirstTimeValue -is [int]) -or ($enterFirstTimeValue -is [long])) {
                if ($enterFirstTimeValue -eq 1) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $enterFirstTime = $true
                }
                elseif ($enterFirstTimeValue -eq 0) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $enterFirstTime = $false
                }
                else {
                    throw "Cannot compress the Rooms data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer $enterFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Rooms data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($enterFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $leaveFirstTimeValue = $entryValue['LeaveFirstTime']
        $leaveFirstTime = $false
        if ($leaveFirstTimeValue -is [bool]) {
            $leaveFirstTime = $leaveFirstTimeValue
        }
        elseif ($null -ne $leaveFirstTimeValue) {
            if (($leaveFirstTimeValue -is [int]) -or ($leaveFirstTimeValue -is [long])) {
                if ($leaveFirstTimeValue -eq 1) {
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $leaveFirstTime = $true
                }
                elseif ($leaveFirstTimeValue -eq 0) {
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $leaveFirstTime = $false
                }
                else {
                    throw "Cannot compress the Rooms data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is the integer $leaveFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Rooms data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($leaveFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        # The Group value follows the plain text ladder: no casing rule
        # of any kind applies to it ('Lowercase enforcement' covers the
        # two picture columns only, docs/data-mapping.md, Rooms
        # section).
        $groupValue = $entryValue['Group']
        $group = ''
        if ($null -ne $groupValue) {
            if ($groupValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Group of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($groupValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the Group of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($groupValue -is [string]) {
                $group = $groupValue
            }
            else {
                Write-Warning "The Group of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($groupValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($groupValue -is [System.IFormattable]) {
                    $group = $groupValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $group = [string]$groupValue
                }
            }

            if ($group.Length -gt 250) {
                Write-Warning "The Group of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($group.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $group = $group.Substring(0, 250)
            }
        }

        # The LayeredRoomPic value follows the RoomPic rules, its 'None'
        # passthrough documented for the column itself.
        $layeredRoomPicValue = $entryValue['LayeredRoomPic']
        $layeredRoomPic = ''
        if ($null -ne $layeredRoomPicValue) {
            if ($layeredRoomPicValue -is [System.Collections.IList]) {
                throw "Cannot compress the Rooms data of the RAGS file: the LayeredRoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($layeredRoomPicValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Rooms data of the RAGS file: the LayeredRoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($layeredRoomPicValue -is [string]) {
                $layeredRoomPic = $layeredRoomPicValue
            }
            else {
                Write-Warning "The LayeredRoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is of type '$($layeredRoomPicValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($layeredRoomPicValue -is [System.IFormattable]) {
                    $layeredRoomPic = $layeredRoomPicValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $layeredRoomPic = [string]$layeredRoomPicValue
                }
            }

            if ($layeredRoomPic.Length -gt 250) {
                Write-Warning "The LayeredRoomPic of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is $($layeredRoomPic.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $layeredRoomPic = $layeredRoomPic.Substring(0, 250)
            }

            if ([string]::Equals($layeredRoomPic, 'None', [System.StringComparison]::OrdinalIgnoreCase)) {
                $layeredRoomPic = [string]$layeredRoomPic
            }
            else {
                $layeredRoomPicLowercased = $layeredRoomPic.ToLowerInvariant()
                if (-not [string]::Equals($layeredRoomPicLowercased, $layeredRoomPic, [System.StringComparison]::Ordinal)) {
                    Write-Warning "The LayeredRoomPic value '$layeredRoomPic' of the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder is coerced to its lowercase form '$layeredRoomPicLowercased' during compression."
                }
                $layeredRoomPic = $layeredRoomPicLowercased
            }
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the nine column names only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'UniqueID', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Description', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'SDesc', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'RoomPic', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'EnterFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LeaveFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Group', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LayeredRoomPic', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder for room '$uniqueId' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Soft-validate the Unique UniqueID column: an entry whose
        # stored value repeats the stored value of a previously read
        # entry (the stored values are always lowercased, so this
        # mirrors the case-insensitive unique check of the expansion),
        # is skipped with a warning naming the column values of the
        # ignored duplicate entry ("A warning containing the values of
        # subsequent ignored duplicate rows will be shown",
        # docs/data-mapping.md, Rooms section; the column values of the
        # first read entry win). The evidence cites the values in the
        # stored form: the lowercased picture columns their stored
        # casing (the verbatim 'None' casings included), the group its
        # raw casing, and the bit columns the read-as booleans.
        $duplicate = $false
        foreach ($existingUniqueId in $admittedUniqueIds) {
            if ([string]::Equals($existingUniqueId, $uniqueId, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $descriptionValue) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            if ($null -eq $sdescValue) { $evidenceParts.Add('SDesc <null>') } else { $evidenceParts.Add('SDesc ''' + $sdesc + '''') }
            if ($null -eq $nameValue) { $evidenceParts.Add('Name <null>') } else { $evidenceParts.Add('Name ''' + $name + '''') }
            if ($null -eq $roomPicValue) { $evidenceParts.Add('RoomPic <null>') } else { $evidenceParts.Add('RoomPic ''' + $roomPic + '''') }
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $groupValue) { $evidenceParts.Add('Group <null>') } else { $evidenceParts.Add('Group ''' + $group + '''') }
            if ($null -eq $layeredRoomPicValue) { $evidenceParts.Add('LayeredRoomPic <null>') } else { $evidenceParts.Add('LayeredRoomPic ''' + $layeredRoomPic + '''') }

            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Rooms.yaml' of the source folder: the UniqueID value '$uniqueId' duplicates the UniqueID value of a previously read entry (whose column values win). The ignored duplicate entry has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedUniqueIds.Add($uniqueId)

        $stagedRows.Add([pscustomobject]@{
            UniqueID       = $uniqueId
            Description    = $description
            SDesc          = $sdesc
            Name           = $name
            RoomPic        = $roomPic
            EnterFirstTime = $enterFirstTime
            LeaveFirstTime = $leaveFirstTime
            Group          = $group
            LayeredRoomPic = $layeredRoomPic
            EntryIndex     = $entryIndex + 1
        })

        $contributingEntries.Add($entryIndex + 1)
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the Rooms table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) (room '$($stagedRow.UniqueID)') to the Rooms table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [Rooms] ([UniqueID], [Description], [SDesc], [Name], [RoomPic], [EnterFirstTime], [LeaveFirstTime], [Group], [LayeredRoomPic]) VALUES (@uid, @desc, @sdesc, @name, @pic, @enter, @leave, @grp, @layer)'

                    $uidParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@uid', [System.Data.SqlDbType]::NVarChar, 250)
                    $uidParameter.Value = $stagedRow.UniqueID
                    $null = $command.Parameters.Add($uidParameter)

                    $descParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@desc', [System.Data.SqlDbType]::NText)
                    # The staged text values of the handler are always
                    # strings, so the text parameters bind their staged
                    # values directly (a null source value stages the
                    # empty string).
                    $descParameter.Value = $stagedRow.Description
                    $null = $command.Parameters.Add($descParameter)

                    $sdescParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@sdesc', [System.Data.SqlDbType]::NVarChar, 250)
                    $sdescParameter.Value = $stagedRow.SDesc
                    $null = $command.Parameters.Add($sdescParameter)

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 250)
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $picParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@pic', [System.Data.SqlDbType]::NVarChar, 250)
                    $picParameter.Value = $stagedRow.RoomPic
                    $null = $command.Parameters.Add($picParameter)

                    # A bit parameter requires a boolean value no matter
                    # what the column carried in the YAML file, so every
                    # bit value is bound as the boolean it normalized to.
                    $enterParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enter', [System.Data.SqlDbType]::Bit)
                    $enterParameter.Value = $stagedRow.EnterFirstTime
                    $null = $command.Parameters.Add($enterParameter)

                    $leaveParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@leave', [System.Data.SqlDbType]::Bit)
                    $leaveParameter.Value = $stagedRow.LeaveFirstTime
                    $null = $command.Parameters.Add($leaveParameter)

                    $grpParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@grp', [System.Data.SqlDbType]::NVarChar, 250)
                    $grpParameter.Value = $stagedRow.Group
                    $null = $command.Parameters.Add($grpParameter)

                    $layerParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@layer', [System.Data.SqlDbType]::NVarChar, 250)
                    $layerParameter.Value = $stagedRow.LayeredRoomPic
                    $null = $command.Parameters.Add($layerParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the Rooms table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The Rooms transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the Rooms data of the RAGS file: the staged rows could not be appended to the Rooms table. "
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

    Write-Verbose "Compressed the Rooms data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

