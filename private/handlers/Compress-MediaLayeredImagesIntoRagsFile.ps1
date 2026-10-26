#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-MediaLayeredImagesIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses MediaLayeredImages data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded MediaLayeredImages data of a source folder back
    into the MediaLayeredImages table of a RAGS file (schema version
    2.6.1) through an open SQL Server Compact connection, appending the
    compressed rows as the inverse of
    Expand-MediaLayeredImagesFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'MediaLayeredImages.yaml' file of the source folder is
    read as a YAML document holding a top-level 'MediaLayeredImages'
    mapping whose value is a sequence with one entry per distinct media
    name: each entry maps the lowercased MediaName value to the Order
    key, whose value is a sequence of layer mappings holding the Order
    value and its Data value. One table row is appended per layer (the
    ID identity column is excluded and auto-supplied by the database),
    replicating the row order of the original expansion: the layers of
    every entry keep their YAML sequence order, and entries keep their
    YAML sequence order, so re-expanding the file restores the entries
    and their layers in read order.

    The 'MediaLayeredImages.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'MediaLayeredImages'
      envelope around the entry sequence, so a non-mapping document
      predates this layout). Keys of the document other than the
      'MediaLayeredImages' envelope key are ignored with a warning.
    - A document whose MediaLayeredImages value is missing, null, empty
      or whitespace-only contributes no rows and is skipped with a
      warning. A MediaLayeredImages value which is an empty sequence is
      treated like the empty sequence an expansion writes for an empty
      table and contributes no rows without a warning. A
      MediaLayeredImages value which is a scalar or a single mapping
      (as hand-edited files omitting the trailing sequence dash
      commonly are) is accepted as the single entry of the sequence
      with a warning; a scalar which is not a string is additionally
      coerced to its invariant string form with a second warning, and
      a scalar entry then aborts the operation in the entry validation
      below (an entry has to be a mapping). A value of any other type
      aborts the whole operation with an exception.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful media layered image can be derived from it. Keys of
      an entry other than the two column names are ignored with a
      warning.
    - An entry whose MediaName value is missing, null or empty is
      skipped in its entirety with a warning, including a whitespace-only
      MediaName, as no media layered image can be derived from it.
    - A scalar MediaName value which is not a string is coerced to its
      invariant string form with a warning; a MediaName value which is a
      sequence or a mapping aborts the whole operation with an
      exception.
    - A MediaName value longer than the 250 characters of the table
      column is truncated with a warning, which fires as soon as the
      value is accepted (before the Order value of the entry is
      validated); note that re-expanding the appended data then derives
      a different media name from the truncated value. Because a longer
      value could not be stored, the truncation happens before the
      lowercasing and case-insensitive grouping below, so two MediaName
      values which become equal only by their truncation group together
      like any other set of case mates.
    - Entries whose MediaName values differ only in character case form
      one media layered image: the media name identity of the layered
      image data is treated case-insensitively ('Values are
      case-insensitive', docs/data-mapping.md, MediaLayeredImages
      section) and every MediaName value is coerced to lowercase
      ('Always coerced to lowercase', docs/data-mapping.md,
      MediaLayeredImages section): after the truncation above, the
      value is lowercased with ToLowerInvariant, so the appended rows
      carry the lowercased form and re-expand into the same lowercased
      entry. Case mates group under the lowercased value read first; an
      entry whose raw MediaName value differs from the first-read raw
      value of its group only in character case is merged into it with
      one warning. Entries whose MediaName values are exactly equal are
      appended without a warning, as append-only accumulation is the
      documented caller workflow.
    - An entry whose Order value is missing, null, empty,
      whitespace-only or an empty sequence is skipped in its entirety
      with a warning, as no layer can be derived from it. An Order
      value which is a scalar or a single mapping is accepted as the
      single layer of the sequence with a warning.
    - Layers which are null are skipped with a warning. A layer which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful layer can be derived from it. Keys of a layer other
      than the Order and Data keys are ignored with a warning.
    - A layer whose Order value is missing or null is skipped with a
      warning, as no layer can be derived from it (mirroring the null
      Order skip of the expansion). A scalar Order value which is an
      integer is read as is; a scalar Order value of any other type is
      coerced to its invariant string form (a string, its own form),
      parsed with the invariant culture and read with a warning, as no
      meaningful integer can be derived from it otherwise; a scalar
      Order value which cannot be parsed as an integer, and Order
      values which are sequences or mappings, abort the whole operation
      with an exception. Order values of different media names are
      independent and never compared against each other.
    - A layer whose Data value is missing, null, empty or
      whitespace-only is skipped with a warning, as no meaningful layer
      Data can be derived from it. A scalar Data value which is not a
      string is coerced to its invariant string form with a warning. A
      Data value which is a sequence or a mapping aborts the whole
      operation with an exception.
    - A Data value longer than the 250 characters of the table column
      is truncated with a warning (the truncation measures the
      as-parsed value, as the stored value is that value verbatim);
      note that re-expanding the appended data then derives a different
      value from the truncated one. The truncation happens before the
      lowercasing below, so the truncated value is the value stored.
    - The Data value is always coerced to lowercase ('Always coerced to
      lowercase', docs/data-mapping.md, MediaLayeredImages section): the
      lowercasing is silent, so the appended rows carry the lowercased
      form and re-expand without a warning.
    - A layer which repeats an exactly read Order value of its media
      name is skipped with a warning (the Data of the first read layer
      wins, mirroring the Unique soft-validation of the expansion):
      every layer of one media name carries its Order value in one
      per-media name set which the entries of that media name share, so
      a duplicate Order value across the entries of one media name is
      detected as well (hand-edited files may repeat an entry, and the
      merged case mates of one media name append their layers to the
      same set). NULL Order values never reach this check (they are
      skipped above). The ignored duplicate layer is reported with its
      own lowercased Data value.
    - Layer values are stored as read: no line-ending normalization is
      applied (the verbatim contract of the expansion family - note
      that a multi-line value re-emits through a YAML literal block,
      whose re-read normalizes the written breaks to line feeds; a
      carriage return which arrives in the parsed value, from a
      double-quoted '\r' escape in a hand-edited file for example, is
      staged verbatim).

    The 'MediaLayeredImages.yaml' file is read, validated and fully
    staged before the first row is appended, so the table remains empty
    when the source folder carries invalid content. The appended rows
    are then written inside a transaction, so a failure while appending
    leaves no partially appended data behind.

    The 'MediaLayeredImages.yaml' file is read silently; a missing
    source folder or file is not an error and compresses nothing.

    Compressed rows are appended to the MediaLayeredImages table, which
    is expected to receive them (the RAGS Designer workflow of
    compressing expanded data keeps the convention of starting from the
    template file, or a blank/formatted RAGS file at the caller's
    discretion). A source folder compressed more than once into the
    same RAGS file therefore appends the table once per run.

    .OUTPUTS
    System.Boolean. Returns $true when the MediaLayeredImages data has
    been compressed successfully.

    .EXAMPLE
    Compress-MediaLayeredImagesIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded MediaLayeredImages data of the 'C:\Export\MyGame'
    folder to the MediaLayeredImages table of the RAGS file connected
    through $openRagsConnection.
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
        throw "Cannot compress the MediaLayeredImages data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'MediaLayeredImages.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'MediaLayeredImages.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'MediaLayeredImages.yaml' file, so there is no MediaLayeredImages data to compress."
        return $true
    }
    Write-Verbose "Compressing the MediaLayeredImages data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the MediaLayeredImages data of the RAGS file: the file 'MediaLayeredImages.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the MediaLayeredImages data of the RAGS file: the file 'MediaLayeredImages.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the MediaLayeredImages data of the RAGS file: the file 'MediaLayeredImages.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'MediaLayeredImages.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
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
        throw "Cannot compress the MediaLayeredImages data of the RAGS file: the file 'MediaLayeredImages.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the MediaLayeredImages data of the RAGS file: the file 'MediaLayeredImages.yaml' of the source folder carries $rootType where a mapping is expected."
    }
    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'MediaLayeredImages'
    # envelope mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'MediaLayeredImages', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'MediaLayeredImages.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
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
    $envelopeValue = $rootDocument['MediaLayeredImages']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'MediaLayeredImages.yaml' of the source folder: the MediaLayeredImages value is missing or null, so no media layered image can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'MediaLayeredImages.yaml' of the source folder: the MediaLayeredImages value is empty, so no media layered image can be derived from it."
        }
        else {
            Write-Warning "The MediaLayeredImages value of the file 'MediaLayeredImages.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The MediaLayeredImages value of the file 'MediaLayeredImages.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        Write-Warning "The MediaLayeredImages value of the file 'MediaLayeredImages.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
        Write-Warning "The MediaLayeredImages value of the file 'MediaLayeredImages.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
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

    # Stage one row per layer before appending anything, so that nothing
    # is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the media name, the storable layer order (an integer)
    # and Data value (a string), and the 1-based entry and layer indices
    # which produced it for the messages of the append phase. The
    # validation of every entry is performed inline below, so that the
    # file is fully validated (and every failure reported) before any row
    # is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The MediaName values of the entries are kept in one list, and the
    # first-read raw values in a parallel list, so that MediaName values
    # which differ only in character case can merge into the lowercased
    # group ('Values are case-insensitive' and 'Always coerced to
    # lowercase', docs/data-mapping.md, MediaLayeredImages section, the
    # grouping the expansion performs as well). Group names are the
    # canonical lowercased values and are looked up ordinally, and the
    # first-read raw value of every group is kept alongside, so that the
    # merge comparison below can detect the entries whose raw MediaName
    # values differ from the first-read one. A third parallel list keeps
    # one integer Order-value set per media layered image, which
    # validates the Unique Order column across every entry of its media
    # name, exactly like the expansion (which shares the Order values of
    # one media name across the case mates it merges).
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupOrderSets = [System.Collections.Generic.List[object]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the MediaLayeredImages data of the RAGS file: the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the MediaName and Order keys only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'MediaName', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Order', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # The List-column MediaName value of the entry, which the
        # expansion writes as a string scalar. A scalar of any other type
        # (a hand-edited unquoted number, for example) is coerced to its
        # invariant string form with a warning.
        $entryMediaNameValue = $entryValue['MediaName']
        if ($null -eq $entryMediaNameValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder: the MediaName value is missing, null or empty, so no media layered image can be derived from it."
            continue
        }

        $mediaName = $null
        if ($entryMediaNameValue -is [System.Collections.IList]) {
            throw "Cannot compress the MediaLayeredImages data of the RAGS file: the MediaName of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        elseif ($entryMediaNameValue -is [System.Collections.IDictionary]) {
            throw "Cannot compress the MediaLayeredImages data of the RAGS file: the MediaName of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        elseif ($entryMediaNameValue -is [string]) {
            $mediaName = $entryMediaNameValue
        }
        else {
            Write-Warning "The MediaName of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder is of type '$($entryMediaNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryMediaNameValue -is [System.IFormattable]) {
                $mediaName = $entryMediaNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $mediaName = [string]$entryMediaNameValue
            }
        }

        if ([string]::IsNullOrWhiteSpace($mediaName)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder: the MediaName value is missing, null or empty, so no media layered image can be derived from it."
            continue
        }

        # Truncate the MediaName value to the length of the table column,
        # as a longer value could not be stored. The truncation runs
        # before the lowercasing and grouping below, so two MediaName
        # values which become equal only by their truncation behave like
        # any other set of case mates. The warning fires as soon as the
        # value is accepted - like every other MediaName-value warning,
        # before the Order value of the entry is validated.
        if ($mediaName.Length -gt 250) {
            Write-Warning "The MediaName value of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder is $($mediaName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different media name from the truncated value."
            $mediaName = $mediaName.Substring(0, 250)
        }

        # The List-column values of the MediaLayeredImages table are
        # documented as case-insensitive and always coerced to lowercase
        # ('Values are case-insensitive' / 'Always coerced to lowercase'
        # in the MediaLayeredImages section of docs/data-mapping.md), so
        # the truncated raw value is lowered with ToLowerInvariant (the
        # invariant result is independent of the current culture).
        # Everything below - the grouping and the appended rows - works
        # with and cites this lowercased form; the raw value is kept only
        # for the merge reporting of the grouping. The expansion of the
        # appended data lowercases its read values anyway, so the
        # lowercased rows re-expand with their MediaName value unchanged.
        $mediaNameRaw = $mediaName
        $mediaName = $mediaNameRaw.ToLowerInvariant()

        # Locate or create the group of the media name. The lowercased
        # value is canonical, so the lookup compares ordinal against it
        # (a case-insensitive comparison would change no outcome). The
        # first-read raw value is kept per group, and an entry whose raw
        # value differs from it is merged with a warning which cites the
        # lowercased value on both sides; the first-read entry of a case
        # mate set and entries repeating its raw value are appended
        # without a warning, as append-only accumulation is the documented
        # caller workflow. The warning fires as soon as the value is
        # accepted - like every other MediaName-value warning, before the
        # Order value of the entry is validated.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $mediaName, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($mediaName)
            $groupRawNames.Add($mediaNameRaw)
            $groupOrderSets.Add([System.Collections.Generic.HashSet[int]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $mediaNameRaw, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the layers of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$mediaName' into the layers of media name '$($groupNames[$groupIndex])': the raw MediaName value differs only in character case and is merged into the lowercased rows."
        }

        # Every appended row of the entry carries the group's MediaName
        # value (the lowercased form common to its set of case mates), and
        # the Order values of the entry join the Order-value set of that
        # media layered image, exactly like the Order values of any other
        # entry of the same media name.
        $stagedMediaName = $groupNames[$groupIndex]
        $orderSet = $groupOrderSets[$groupIndex]

        # Locate and validate the Order value of the entry, which is a
        # sequence of layer mappings. A scalar or single-mapping value is
        # accepted as the single layer of the sequence with a warning, as
        # single-layer sequences are commonly written without their
        # leading sequence dash.
        $entryOrderValue = $entryValue['Order']
        if ($null -eq $entryOrderValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName': the Order value is missing or null, so no layer can be derived from it."
            continue
        }

        if ($entryOrderValue -is [System.Collections.IList]) {
            if ($entryOrderValue.Count -eq 0) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName': the Order value is an empty sequence, so no layer can be derived from it."
                continue
            }
        }
        elseif ($entryOrderValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($entryOrderValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName': the Order value is empty, so no layer can be derived from it."
                continue
            }

            Write-Warning "The Order value of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName' is a scalar, not a sequence; it is treated as the single layer of the sequence."
            $coercedLayers = [System.Collections.Generic.List[object]]::new()
            $coercedLayers.Add($entryOrderValue)
            $entryOrderValue = $coercedLayers
        }
        elseif ($entryOrderValue -is [System.Collections.IDictionary]) {
            Write-Warning "The Order value of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName' is a single mapping, not a sequence; it is treated as the single layer of the sequence."
            $coercedLayers = [System.Collections.Generic.List[object]]::new()
            $coercedLayers.Add($entryOrderValue)
            $entryOrderValue = $coercedLayers
        }
        else {
            throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Order value of the entry $($entryIndex + 1) of the file 'MediaLayeredImages.yaml' of the source folder of media name '$stagedMediaName' is of type '$($entryOrderValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every layer of the entry is validated and staged inline below,
        # so that no layer of the entry appends a row before a later
        # layer of the same entry is fully validated.
        $entryRowsBefore = $stagedRows.Count
        for ($layerIndex = 0; $layerIndex -lt $entryOrderValue.Count; $layerIndex++) {
            $layerValue = $entryOrderValue[$layerIndex]
            if ($null -eq $layerValue) {
                Write-Warning "Skipping the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName': the layer is null."
                continue
            }
            if ($layerValue -isnot [System.Collections.IDictionary]) {
                throw "Cannot compress the MediaLayeredImages data of the RAGS file: the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is of type '$($layerValue.GetType().FullName)' instead of a mapping."
            }

            # Ignore any unexpected key of the layer with a warning, as
            # the expansion writes layers with the Order and Data keys
            # only.
            $layerExtraKeys = [System.Collections.Generic.List[string]]::new()
            foreach ($layerKey in $layerValue.Keys) {
                $layerKeyText = [string]$layerKey
                if ((-not [string]::Equals($layerKeyText, 'Order', [System.StringComparison]::Ordinal)) -and
                    (-not [string]::Equals($layerKeyText, 'Data', [System.StringComparison]::Ordinal))) {
                    $layerExtraKeys.Add($layerKeyText)
                }
            }
            if ($layerExtraKeys.Count -gt 0) {
                $layerExtraKeyText = ($layerExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
                Write-Warning "The layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' defines the unexpected key(s) $layerExtraKeyText; they are ignored."
            }

            # Locate and validate the Order value of the layer, which the
            # expansion writes as an integer scalar. A missing or null
            # Order value contributes no layer (it is skipped like the
            # null-Order rows of the expansion); a scalar of any other
            # type is parsed with the invariant culture.
            $layerOrderValue = $layerValue['Order']
            $layerOrder = $null
            if ($null -eq $layerOrderValue) {
                Write-Warning "Skipping the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName': the Order value is missing or null, so no layer can be derived from it."
                continue
            }

            if ($layerOrderValue -is [System.Collections.IList]) {
                throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' carries a sequence where an integer scalar is expected."
            }
            elseif ($layerOrderValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' carries a mapping where an integer scalar is expected."
            }
            elseif (($layerOrderValue -is [int]) -or ($layerOrderValue -is [long])) {
                $layerOrder = [int]$layerOrderValue
            }
            else {
                $orderText = $null
                if ($layerOrderValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($layerOrderValue)) {
                        throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is a scalar which cannot be parsed as an integer."
                    }
                    $orderText = $layerOrderValue
                    Write-Warning "The Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is of type '$($layerOrderValue.GetType().FullName)' instead of an integer; it is parsed with the invariant culture."
                }
                else {
                    Write-Warning "The Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is of type '$($layerOrderValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                    if ($layerOrderValue -is [System.IFormattable]) {
                        $orderText = $layerOrderValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $orderText = [string]$layerOrderValue
                    }
                }

                $parsedOrder = 0
                if (-not [int]::TryParse($orderText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedOrder)) {
                    throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Order of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is a scalar which cannot be parsed as an integer."
                }
                $layerOrder = $parsedOrder
            }

            # The Data value of the layer, which the expansion writes as
            # a string scalar. A missing or null Data value contributes
            # no layer; a scalar of any other type is coerced to its
            # invariant string form with a warning.
            $layerDataValue = $layerValue['Data']
            if ([string]::IsNullOrWhiteSpace([string]$layerDataValue)) {
                Write-Warning "Skipping the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName': the Data value is missing, null or empty."
                continue
            }

            $layerData = $null
            if ($layerDataValue -is [System.Collections.IList]) {
                throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Data of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' carries a sequence where a scalar value is expected."
            }
            elseif ($layerDataValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the MediaLayeredImages data of the RAGS file: the Data of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' carries a mapping where a scalar value is expected."
            }
            elseif ($layerDataValue -is [string]) {
                $layerData = $layerDataValue
            }
            else {
                Write-Warning "The Data of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is of type '$($layerDataValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($layerDataValue -is [System.IFormattable]) {
                    $layerData = $layerDataValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $layerData = [string]$layerDataValue
                }
            }

            # A YAML literal block scalar normalizes line breaks to
            # line-feed characters when the written YAML is read back - a
            # parsed carriage return from a double-quoted escape arrives
            # as-is and is staged verbatim, like the expansion family's
            # verbatim contract.
            $layerData = [string]$layerData

            # Truncate the Data value to the length of the table column,
            # as a longer value could not be stored. The truncation
            # measures the as-parsed value (see above), as the stored
            # value is that value verbatim.
            if ($layerData.Length -gt 250) {
                Write-Warning "The Data value of the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName' is $($layerData.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $layerData = $layerData.Substring(0, 250)
            }

            # The Data values are always coerced to lowercase ('Always
            # coerced to lowercase' in the MediaLayeredImages section of
            # docs/data-mapping.md), after the truncation above - the
            # truncated value is the value stored. The lowercasing is
            # silent: the appended rows simply carry the lowercase form,
            # which the expansion of the appended data reads and emits
            # unchanged.
            $stagedData = $layerData.ToLowerInvariant()

            # Soft-validate the Unique Order column: the Order values of
            # a media layered image are expected to contain only distinct
            # values ('If multiple identical Orders exist for the same
            # MediaName value, then only the Data of the first row will
            # be read', docs/data-mapping.md, MediaLayeredImages section),
            # so a layer which repeats the exactly read Order value of
            # its media layered image is skipped with a warning (the Data
            # of the first read layer wins, like the expansion). The
            # Order-value set of the media layered image is shared by
            # every entry of the media name, including merged case-mate
            # entries and hand-edited repeated entries. A NULL Order never
            # reaches this check (it is skipped above). The lowercased
            # Data value was derived BEFORE the duplicate check, so the
            # warning reports the value of the ignored layer itself.
            if (-not $orderSet.Add($layerOrder)) {
                Write-Warning "Skipping the layer $($layerIndex + 1) of the entry $($entryIndex + 1) for media name '$stagedMediaName': the Order value $layerOrder duplicates the Order value of a previously read layer (whose Data wins). The ignored duplicate layer has the Data value '$stagedData'."
                continue
            }

            $stagedRows.Add([pscustomobject]@{
                MediaName  = $stagedMediaName
                Order      = $layerOrder
                Data       = $stagedData
                EntryIndex = $entryIndex + 1
                LayerIndex = $layerIndex + 1
            })
        }

        if ($stagedRows.Count -gt $entryRowsBefore) {
            $contributingEntries.Add($entryIndex + 1)
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the MediaLayeredImages table inside
        # one transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the layer $($stagedRow.LayerIndex) of the entry $($stagedRow.EntryIndex) (media name '$($stagedRow.MediaName)') to the MediaLayeredImages table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [MediaLayeredImages] ([MediaName], [Order], [Data]) VALUES (@medianame, @order, @data)'

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@medianame', [System.Data.SqlDbType]::NVarChar, 250)
                    $nameParameter.Value = $stagedRow.MediaName
                    $null = $command.Parameters.Add($nameParameter)

                    $orderParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@order', [System.Data.SqlDbType]::Int)
                    $orderParameter.Value = $stagedRow.Order
                    $null = $command.Parameters.Add($orderParameter)

                    $dataParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@data', [System.Data.SqlDbType]::NVarChar, 250)
                    $dataParameter.Value = $stagedRow.Data
                    $null = $command.Parameters.Add($dataParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the MediaLayeredImages table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The MediaLayeredImages transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the MediaLayeredImages data of the RAGS file: the staged rows could not be appended to the MediaLayeredImages table. "
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

    Write-Verbose "Compressed the MediaLayeredImages data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}


