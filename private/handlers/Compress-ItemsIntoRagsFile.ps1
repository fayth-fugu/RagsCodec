#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-ItemsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses Items data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded Items data of a source folder back into the
    Items table of a RAGS file (schema version 2.6.1) through an open
    SQL Server Compact connection, appending the compressed rows as the
    inverse of Expand-ItemsFromRagsFile and following the conventions
    documented in docs/data-mapping.md.

    The single 'Items.yaml' file of the source folder is read as a YAML
    document holding a top-level 'Items' mapping whose value is a
    sequence with one entry per item, each mapping the twenty-five
    columns of the Items table: the UniqueID key and the other
    twenty-four column values. One table row is appended per item entry
    (the Items table holds no identity column), replicating the row
    order of the original expansion: entries keep their YAML sequence
    order, which is the ascending UniqueID order of the original table
    read ('Table is sorted by UniqueID ascending',
    docs/data-mapping.md, Items section).

    The 'Items.yaml' file is consumed as follows:
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'Items' envelope
      around the entry sequence, so a non-mapping document predates this
      layout). Keys of the document other than the 'Items' envelope key
      are ignored with a warning.
    - A document whose Items value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      An Items value which is an empty sequence is treated like the
      empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - An Items value which is a scalar or a single mapping (as
      hand-edited files omitting the trailing sequence dash commonly
      are) is accepted as the single entry of the sequence with a
      warning, and the single entry then follows the entry rules below
      (a scalar entry aborts the whole operation with the contextual
      entry exception). An Items value which is a scalar but not a
      string is derived to its string form with a further warning, the
      string form of format-sensitive values being derived with the
      invariant culture, so the coerced entry carries its round-tripping
      value across hosts of different cultures.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful row can be derived from it.
    - An entry whose UniqueID value is missing, null, empty or
      whitespace-only is skipped in its entirety with a warning, as no
      item entry key can be derived from it. An entry whose UniqueID
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
    - The UniqueID values are always stored lowercased, mirroring the
      documented Unique handling of the expansion ('Values are
      case-insensitive' and 'Always coerced to lowercase',
      docs/data-mapping.md, Items section), so that re-expanding the
      appended data keys the entry lowercase again. The lowercasing is
      silent; the duplicate check below reports a repeated entry, and a
      lone mixed-case entry documents its drift on re-expansion.
    - An entry which repeats the UniqueID value of a previously read
      entry, ignoring character case, is skipped with a warning which
      names the column values of the ignored duplicate entry (the
      column values of the first read entry win), as the documentation
      requires ('If multiple identical UniqueIDs exist, then only the
      first row's column values will be read' and 'A warning containing
      the values of subsequent ignored duplicate rows will be shown',
      docs/data-mapping.md, Items section).
    - A text column value (Name, SDesc, Preposition, LocationName and
      GroupName) which is a scalar but not a string (a hand-edited
      unquoted number, for example) is coerced to its string form with
      a warning; the string form of format-sensitive values is derived
      with the invariant culture, so such a value round-trips through
      hosts of different cultures. Values longer than the 250
      characters of their table column (255 for GroupName) are
      truncated with a warning; a text column value which is a sequence
      or a mapping aborts the whole operation with an exception, as no
      meaningful scalar can be derived from it.
    - The Description value (which never carries a length limit) is
      stored with the same scalar coercion as the text columns, with no
      line-ending normalization applied (the verbatim contract of the
      expansion family — note that a multi-line value re-emits through
      a YAML literal block, whose re-read normalizes the written breaks
      to line feeds; a parsed carriage return from a double-quoted
      '\r' escape is staged verbatim). A Description value which is a
      sequence or a mapping aborts the whole operation with an
      exception.
    - A LocationType value which is missing or null is stored as a
      database null without a warning, as the expansion emits a YAML
      null for a null LocationType column. A LocationType value which
      is an integer scalar is stored as read. Any other scalar is
      parsed with the invariant culture with a warning; a value which
      cannot be parsed aborts the whole operation with an exception.
    - A Weight value which is missing or null is stored as a database
      null without a warning, as the expansion emits a YAML null for a
      null Weight column. A Weight value which is a number (of any
      numeric form the expansion can emit, including integers, decimals
      and exponent notations) is stored as its float form without a
      warning; a conversion result which is not storable as a float
      number aborts the whole operation with an exception. A Weight
      value which is a string or any other scalar is derived to its
      invariant text form with a warning and parsed with the invariant
      culture; a value which cannot be parsed aborts the whole
      operation with an exception.
    - A bit column value (Carryable, Wearable, Openable, Lockable,
      Enterable, Readable, Container, Worn, Read, Locked, Open,
      Entered, Visible, EnterFirstTime, LeaveFirstTime) which is
      missing or null is stored as false without a warning, as the
      expansion emits a YAML false for a null bit column. A bit column
      value which is a boolean is stored as read; an integer scalar of
      1 or 0 is accepted with a warning; a value of any other type or
      content aborts the whole operation with an exception.
    - The Important column does not allow a database null, so an entry
      whose Important value is missing or null is stored as the false
      the not-null table column documents as its default value, with a
      warning (an expansion never emits such an entry). A present
      Important value follows the bit column rules above.
    - Null text and Description values are stored as the empty string,
      mirroring the null-string emission rule of the expansion (a null
      column value is emitted as the empty string); a null LocationType
      or Weight value is stored as a database null.
    - Keys of an entry other than the twenty-five column names are
      ignored with a warning.

    The 'Items.yaml' file is read, validated and fully staged before
    the first row is appended, so the table remains empty when the
    source folder carries invalid content. The appended rows are then
    written inside a transaction, so a failure while appending leaves
    no partially appended data behind.

    The 'Items.yaml' file is read silently; a missing source folder
    or file is not an error and compresses nothing.

    Compressed rows are appended to the Items table, which is expected
    to receive them (the RAGS Designer workflow of compressing expanded
    data keeps the convention of starting from the template file, or a
    blank/formatted RAGS file at the caller's discretion). A source
    folder compressed more than once into the same RAGS file therefore
    appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the Items data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .EXAMPLE
    Compress-ItemsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded Items data of the 'C:\Export\MyGame' folder
    to the Items table of the RAGS file connected through
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
        throw "Cannot compress the Items data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'Items.yaml' file: no
    # expansion may have happened yet, in which case there is nothing
    # to compress.
    $filePath = Join-Path $SourcePath 'Items.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'Items.yaml' file, so there is no Items data to compress."
        return $true
    }
    Write-Verbose "Compressing the Items data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the Items data of the RAGS file: the file 'Items.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the Items data of the RAGS file: the file 'Items.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the Items data of the RAGS file: the file 'Items.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'Items.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
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
        throw "Cannot compress the Items data of the RAGS file: the file 'Items.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the Items data of the RAGS file: the file 'Items.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'Items' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'Items', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'Items.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that
    # a missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['Items']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'Items.yaml' of the source folder: the Items value is missing or null, so no item data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'Items.yaml' of the source folder: the Items value is empty, so no item data can be derived from it."
        }
        else {
            Write-Warning "The Items value of the file 'Items.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The Items value of the file 'Items.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
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
        Write-Warning "The Items value of the file 'Items.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
        if ($envelopeValue -isnot [string]) {
            Write-Warning "The Items value of the file 'Items.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
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

    # Stage one row per item entry before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged
    # value carries the twenty-five column values of the row and the
    # 1-based entry index which produced it for the messages of the
    # append phase. The validation of every entry is performed inline
    # below, so that the file is fully validated (and every failure
    # reported) before any row is staged.
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
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the Items data of the RAGS file: the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # Locate and validate the UniqueID value of the entry, which is
        # expected to be the string scalar the expansion wrote. A
        # non-string scalar (a hand-edited unquoted number, for example)
        # is coerced to its string form with a warning, mirroring the
        # tolerant scalar ladder of the other text columns; a sequence
        # or a mapping value aborts the whole operation.
        $entryUniqueId = $entryValue['UniqueID']
        if ($null -eq $entryUniqueId) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder: the UniqueID value is missing or null, so no item entry can be derived for it."
            continue
        }
        if ($entryUniqueId -is [System.Collections.IList]) {
            throw "Cannot compress the Items data of the RAGS file: the UniqueID of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
        }
        if ($entryUniqueId -is [System.Collections.IDictionary]) {
            throw "Cannot compress the Items data of the RAGS file: the UniqueID of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
        }
        if ($entryUniqueId -isnot [string]) {
            Write-Warning "The UniqueID of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($entryUniqueId.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($entryUniqueId -is [System.IFormattable]) {
                $entryUniqueId = $entryUniqueId.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $entryUniqueId = [string]$entryUniqueId
            }
        }
        if ([string]::IsNullOrWhiteSpace($entryUniqueId)) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder: the UniqueID value is empty, so no item entry can be derived for it."
            continue
        }

        # Truncate the UniqueID value to the length of the table column
        # (before the lowercasing and the duplicate check below), as a
        # longer value could not be stored.
        $uniqueId = $entryUniqueId
        if ($uniqueId.Length -gt 250) {
            Write-Warning "The UniqueID of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($uniqueId.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry from the truncated value."
            $uniqueId = $uniqueId.Substring(0, 250)
        }

        # Store the UniqueID value lowercased, mirroring the documented
        # Unique handling of the expansion (docs/data-mapping.md, Items
        # section: 'Values are case-insensitive' and 'Always coerced to
        # lowercase'), so that re-expanding the appended data keys the
        # entry lowercase again. The lowercasing is silent: a duplicate
        # of a previously read entry is reported by the duplicate check
        # below (whose evidence cites the lowercased values), while a
        # lone mixed-case entry documents its drift on re-expansion.
        $uniqueId = $uniqueId.ToLowerInvariant()

        # Locate and validate the Name value of the entry, which is
        # expected to be the string scalar the expansion wrote. Every
        # remaining column value is derived BEFORE the duplicate check
        # below, so that the warning of the check reports the values of
        # the ignored duplicate entry — the evidence therefore tests the
        # raw parsed value ($<column>Value), not the staged one, so a
        # null keeps its '<null>' citation, while a null text value
        # stages the empty string, mirroring the null-string emission
        # rule of the expansion (a null column value is emitted as the
        # empty string). A null value of the LocationType and Weight
        # columns is stored as a database null, and a null of the bit
        # columns as the documented false.
        $nameValue = $entryValue['Name']
        $name = ''
        if ($null -ne $nameValue) {
            if ($nameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($nameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($nameValue -is [string]) {
                $name = $nameValue
            }
            else {
                Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($nameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($nameValue -is [System.IFormattable]) {
                    $name = $nameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $name = [string]$nameValue
                }
            }

            if ($name.Length -gt 250) {
                Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($name.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $name = $name.Substring(0, 250)
            }
        }

        # The Description value is stored as read, verbatim: no
        # line-ending normalization is applied (the expansion family's
        # verbatim contract — a multi-line value re-emits through a
        # YAML literal block whose re-read normalizes the written
        # breaks to line feeds, while a parsed carriage return from a
        # double-quoted escape arrives as-is). Like every ntext column
        # it holds no length limit to truncate to, and the value is
        # derived BEFORE the duplicate evidence below so that the
        # warning reports the recorded value (the evidence tests this
        # raw parsed value, not the staged one).
        $descriptionValue = $entryValue['Description']
        $description = ''
        if ($null -ne $descriptionValue) {
            if ($descriptionValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($descriptionValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the Description of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($descriptionValue -is [string]) {
                $description = $descriptionValue
            }
            else {
                Write-Warning "The Description of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($descriptionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
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
                throw "Cannot compress the Items data of the RAGS file: the SDesc of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($sdescValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the SDesc of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($sdescValue -is [string]) {
                $sdesc = $sdescValue
            }
            else {
                Write-Warning "The SDesc of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($sdescValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($sdescValue -is [System.IFormattable]) {
                    $sdesc = $sdescValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $sdesc = [string]$sdescValue
                }
            }

            if ($sdesc.Length -gt 250) {
                Write-Warning "The SDesc of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($sdesc.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $sdesc = $sdesc.Substring(0, 250)
            }
        }

        $prepositionValue = $entryValue['Preposition']
        $preposition = ''
        if ($null -ne $prepositionValue) {
            if ($prepositionValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the Preposition of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($prepositionValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the Preposition of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($prepositionValue -is [string]) {
                $preposition = $prepositionValue
            }
            else {
                Write-Warning "The Preposition of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($prepositionValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($prepositionValue -is [System.IFormattable]) {
                    $preposition = $prepositionValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $preposition = [string]$prepositionValue
                }
            }

            if ($preposition.Length -gt 250) {
                Write-Warning "The Preposition of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($preposition.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $preposition = $preposition.Substring(0, 250)
            }
        }

        $locationNameValue = $entryValue['LocationName']
        $locationName = ''
        if ($null -ne $locationNameValue) {
            if ($locationNameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the LocationName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($locationNameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the LocationName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($locationNameValue -is [string]) {
                $locationName = $locationNameValue
            }
            else {
                Write-Warning "The LocationName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($locationNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($locationNameValue -is [System.IFormattable]) {
                    $locationName = $locationNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $locationName = [string]$locationNameValue
                }
            }

            if ($locationName.Length -gt 250) {
                Write-Warning "The LocationName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($locationName.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $locationName = $locationName.Substring(0, 250)
            }
        }

        $locationTypeValue = $entryValue['LocationType']
        $locationType = $null
        if ($null -ne $locationTypeValue) {
            if ($locationTypeValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where an integer scalar is expected."
            }
            elseif ($locationTypeValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where an integer scalar is expected."
            }
            elseif (($locationTypeValue -is [int]) -or ($locationTypeValue -is [long])) {
                $locationType = [int]$locationTypeValue
            }
            else {
                $locationTypeText = $null
                if ($locationTypeValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($locationTypeValue)) {
                        throw "Cannot compress the Items data of the RAGS file: the LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                    }
                    $locationTypeText = $locationTypeValue
                    Write-Warning "The LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($locationTypeValue.GetType().FullName)' instead of an integer; it is parsed with the invariant culture."
                }
                else {
                    Write-Warning "The LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($locationTypeValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                    if ($locationTypeValue -is [System.IFormattable]) {
                        $locationTypeText = $locationTypeValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $locationTypeText = [string]$locationTypeValue
                    }
                }

                $parsedLocationType = 0
                if (-not [int]::TryParse($locationTypeText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedLocationType)) {
                    throw "Cannot compress the Items data of the RAGS file: the LocationType of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                }
                $locationType = $parsedLocationType
            }
        }

        # The managed reader of the expansion reads bit columns as
        # Boolean values, so the YAML counterparts are booleans; a
        # missing or null value is stored as the documented false.
        $carryableValue = $entryValue['Carryable']
        $carryable = $false
        if ($carryableValue -is [bool]) {
            $carryable = $carryableValue
        }
        elseif ($null -ne $carryableValue) {
            if (($carryableValue -is [int]) -or ($carryableValue -is [long])) {
                if ($carryableValue -eq 1) {
                    Write-Warning "The Carryable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $carryable = $true
                }
                elseif ($carryableValue -eq 0) {
                    Write-Warning "The Carryable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $carryable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Carryable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $carryableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Carryable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($carryableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $wearableValue = $entryValue['Wearable']
        $wearable = $false
        if ($wearableValue -is [bool]) {
            $wearable = $wearableValue
        }
        elseif ($null -ne $wearableValue) {
            if (($wearableValue -is [int]) -or ($wearableValue -is [long])) {
                if ($wearableValue -eq 1) {
                    Write-Warning "The Wearable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $wearable = $true
                }
                elseif ($wearableValue -eq 0) {
                    Write-Warning "The Wearable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $wearable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Wearable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $wearableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Wearable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($wearableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $openableValue = $entryValue['Openable']
        $openable = $false
        if ($openableValue -is [bool]) {
            $openable = $openableValue
        }
        elseif ($null -ne $openableValue) {
            if (($openableValue -is [int]) -or ($openableValue -is [long])) {
                if ($openableValue -eq 1) {
                    Write-Warning "The Openable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $openable = $true
                }
                elseif ($openableValue -eq 0) {
                    Write-Warning "The Openable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $openable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Openable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $openableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Openable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($openableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $lockableValue = $entryValue['Lockable']
        $lockable = $false
        if ($lockableValue -is [bool]) {
            $lockable = $lockableValue
        }
        elseif ($null -ne $lockableValue) {
            if (($lockableValue -is [int]) -or ($lockableValue -is [long])) {
                if ($lockableValue -eq 1) {
                    Write-Warning "The Lockable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $lockable = $true
                }
                elseif ($lockableValue -eq 0) {
                    Write-Warning "The Lockable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $lockable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Lockable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $lockableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Lockable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($lockableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $enterableValue = $entryValue['Enterable']
        $enterable = $false
        if ($enterableValue -is [bool]) {
            $enterable = $enterableValue
        }
        elseif ($null -ne $enterableValue) {
            if (($enterableValue -is [int]) -or ($enterableValue -is [long])) {
                if ($enterableValue -eq 1) {
                    Write-Warning "The Enterable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $enterable = $true
                }
                elseif ($enterableValue -eq 0) {
                    Write-Warning "The Enterable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $enterable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Enterable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $enterableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Enterable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($enterableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $readableValue = $entryValue['Readable']
        $readable = $false
        if ($readableValue -is [bool]) {
            $readable = $readableValue
        }
        elseif ($null -ne $readableValue) {
            if (($readableValue -is [int]) -or ($readableValue -is [long])) {
                if ($readableValue -eq 1) {
                    Write-Warning "The Readable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $readable = $true
                }
                elseif ($readableValue -eq 0) {
                    Write-Warning "The Readable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $readable = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Readable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $readableValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Readable of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($readableValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $containerValue = $entryValue['Container']
        $container = $false
        if ($containerValue -is [bool]) {
            $container = $containerValue
        }
        elseif ($null -ne $containerValue) {
            if (($containerValue -is [int]) -or ($containerValue -is [long])) {
                if ($containerValue -eq 1) {
                    Write-Warning "The Container of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $container = $true
                }
                elseif ($containerValue -eq 0) {
                    Write-Warning "The Container of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $container = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Container of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $containerValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Container of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($containerValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        # The Weight column is the only float column of the schema; the
        # expansion emits a YAML number for a present value and a YAML
        # null for a missing one. Every numeric scalar form the YAML
        # parser can produce for an emitted value (doubles, integers,
        # decimals and arbitrary-precision integers) is converted to
        # its float form without a warning, as those are re-parse forms
        # of expansion emissions (the shortest-float emission '2.5'
        # re-parses as a decimal, integer-valued floats re-parse as
        # integers); a conversion result which cannot be storable as a
        # float number aborts the whole operation. A string or any
        # other scalar is derived to its invariant text form with a
        # warning and parsed with the invariant culture.
        $weightValue = $entryValue['Weight']
        $weight = $null
        if ($null -ne $weightValue) {
            if ($weightValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a number is expected."
            }
            elseif ($weightValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a number is expected."
            }
            else {
                $weightText = $null
                if ($weightValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($weightValue)) {
                        throw "Cannot compress the Items data of the RAGS file: the Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a scalar which cannot be parsed as a number."
                    }
                    $weightText = $weightValue
                    Write-Warning "The Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a string instead of a number; it is parsed with the invariant culture."
                }
                else {
                    $weightIsNumeric = ($weightValue -is [double]) -or
                        ($weightValue -is [SByte]) -or
                        ($weightValue -is [Byte]) -or
                        ($weightValue -is [Int16]) -or
                        ($weightValue -is [UInt16]) -or
                        ($weightValue -is [int]) -or
                        ($weightValue -is [UInt32]) -or
                        ($weightValue -is [long]) -or
                        ($weightValue -is [UInt64]) -or
                        ($weightValue -is [float]) -or
                        ($weightValue -is [decimal]) -or
                        ($weightValue -is [System.Numerics.BigInteger])
                    if ($weightValue -is [System.IFormattable]) {
                        $weightText = $weightValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $weightText = [string]$weightValue
                    }
                    if (-not $weightIsNumeric) {
                        Write-Warning "The Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($weightValue.GetType().FullName)' instead of a number; it is coerced to its invariant string form and parsed with the invariant culture."
                    }
                }

                $parsedWeight = [double]0
                if (-not [double]::TryParse($weightText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedWeight)) {
                    throw "Cannot compress the Items data of the RAGS file: the Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a scalar which cannot be parsed as a number."
                }
                if ([System.Double]::IsNaN($parsedWeight) -or [System.Double]::IsInfinity($parsedWeight)) {
                    throw "Cannot compress the Items data of the RAGS file: the Weight of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is a scalar which cannot be stored as a float number."
                }
                $weight = $parsedWeight
            }
        }

        # The managed reader of the expansion reads bit columns as
        # Boolean values, so the YAML counterparts are booleans; a
        # missing or null value is stored as the documented false.
        $wornValue = $entryValue['Worn']
        $worn = $false
        if ($wornValue -is [bool]) {
            $worn = $wornValue
        }
        elseif ($null -ne $wornValue) {
            if (($wornValue -is [int]) -or ($wornValue -is [long])) {
                if ($wornValue -eq 1) {
                    Write-Warning "The Worn of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $worn = $true
                }
                elseif ($wornValue -eq 0) {
                    Write-Warning "The Worn of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $worn = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Worn of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $wornValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Worn of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($wornValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $readFlagValue = $entryValue['Read']
        $readFlag = $false
        if ($readFlagValue -is [bool]) {
            $readFlag = $readFlagValue
        }
        elseif ($null -ne $readFlagValue) {
            if (($readFlagValue -is [int]) -or ($readFlagValue -is [long])) {
                if ($readFlagValue -eq 1) {
                    Write-Warning "The Read of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $readFlag = $true
                }
                elseif ($readFlagValue -eq 0) {
                    Write-Warning "The Read of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $readFlag = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Read of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $readFlagValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Read of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($readFlagValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $lockedValue = $entryValue['Locked']
        $locked = $false
        if ($lockedValue -is [bool]) {
            $locked = $lockedValue
        }
        elseif ($null -ne $lockedValue) {
            if (($lockedValue -is [int]) -or ($lockedValue -is [long])) {
                if ($lockedValue -eq 1) {
                    Write-Warning "The Locked of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $locked = $true
                }
                elseif ($lockedValue -eq 0) {
                    Write-Warning "The Locked of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $locked = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Locked of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $lockedValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Locked of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($lockedValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $openFlagValue = $entryValue['Open']
        $openFlag = $false
        if ($openFlagValue -is [bool]) {
            $openFlag = $openFlagValue
        }
        elseif ($null -ne $openFlagValue) {
            if (($openFlagValue -is [int]) -or ($openFlagValue -is [long])) {
                if ($openFlagValue -eq 1) {
                    Write-Warning "The Open of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $openFlag = $true
                }
                elseif ($openFlagValue -eq 0) {
                    Write-Warning "The Open of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $openFlag = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Open of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $openFlagValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Open of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($openFlagValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $enteredValue = $entryValue['Entered']
        $entered = $false
        if ($enteredValue -is [bool]) {
            $entered = $enteredValue
        }
        elseif ($null -ne $enteredValue) {
            if (($enteredValue -is [int]) -or ($enteredValue -is [long])) {
                if ($enteredValue -eq 1) {
                    Write-Warning "The Entered of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $entered = $true
                }
                elseif ($enteredValue -eq 0) {
                    Write-Warning "The Entered of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $entered = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Entered of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $enteredValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Entered of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($enteredValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $visibleValue = $entryValue['Visible']
        $visible = $false
        if ($visibleValue -is [bool]) {
            $visible = $visibleValue
        }
        elseif ($null -ne $visibleValue) {
            if (($visibleValue -is [int]) -or ($visibleValue -is [long])) {
                if ($visibleValue -eq 1) {
                    Write-Warning "The Visible of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $visible = $true
                }
                elseif ($visibleValue -eq 0) {
                    Write-Warning "The Visible of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $visible = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $visibleValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($visibleValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $enterFirstTimeValue = $entryValue['EnterFirstTime']
        $enterFirstTime = $false
        if ($enterFirstTimeValue -is [bool]) {
            $enterFirstTime = $enterFirstTimeValue
        }
        elseif ($null -ne $enterFirstTimeValue) {
            if (($enterFirstTimeValue -is [int]) -or ($enterFirstTimeValue -is [long])) {
                if ($enterFirstTimeValue -eq 1) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $enterFirstTime = $true
                }
                elseif ($enterFirstTimeValue -eq 0) {
                    Write-Warning "The EnterFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $enterFirstTime = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $enterFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the EnterFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($enterFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
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
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $leaveFirstTime = $true
                }
                elseif ($leaveFirstTimeValue -eq 0) {
                    Write-Warning "The LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $leaveFirstTime = $false
                }
                else {
                    throw "Cannot compress the Items data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $leaveFirstTimeValue, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the LeaveFirstTime of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($leaveFirstTimeValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        $groupNameValue = $entryValue['GroupName']
        $groupName = ''
        if ($null -ne $groupNameValue) {
            if ($groupNameValue -is [System.Collections.IList]) {
                throw "Cannot compress the Items data of the RAGS file: the GroupName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($groupNameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the Items data of the RAGS file: the GroupName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($groupNameValue -is [string]) {
                $groupName = $groupNameValue
            }
            else {
                Write-Warning "The GroupName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($groupNameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($groupNameValue -is [System.IFormattable]) {
                    $groupName = $groupNameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $groupName = [string]$groupNameValue
                }
            }

            if ($groupName.Length -gt 255) {
                Write-Warning "The GroupName of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is $($groupName.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different value from the truncated one."
                $groupName = $groupName.Substring(0, 255)
            }
        }

        # The Important column does not allow a database null, so a
        # missing or null value is stored as the documented default of
        # the not-null column (the false the schema documents as its
        # default); an expansion never emits such an entry, which the
        # warning below notes. A present value follows the bit column
        # rules of the other bits.
        $importantValue = $entryValue['Important']
        $important = $false
        if ($importantValue -is [bool]) {
            $important = $importantValue
        }
        elseif ($null -eq $importantValue) {
            Write-Warning "The Important of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is missing or null; it is stored as the false the not-null table column documents as its default value."
        }
        elseif (($importantValue -is [int]) -or ($importantValue -is [long])) {
            if ($importantValue -eq 1) {
                Write-Warning "The Important of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                $important = $true
            }
            elseif ($importantValue -eq 0) {
                Write-Warning "The Important of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                $important = $false
            }
            else {
                throw "Cannot compress the Items data of the RAGS file: the Important of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is the integer $importantValue, which is neither 0 nor 1."
            }
        }
        else {
            throw "Cannot compress the Items data of the RAGS file: the Important of the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder is of type '$($importantValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the twenty-five column names
        # only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'UniqueID', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Description', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'SDesc', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Preposition', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LocationName', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LocationType', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Carryable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Wearable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Openable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Lockable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Enterable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Readable', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Container', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Weight', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Worn', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Read', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Locked', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Open', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Entered', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Visible', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'EnterFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'LeaveFirstTime', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'GroupName', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Important', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder for item '$uniqueId' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Soft-validate the Unique UniqueID column: an entry whose
        # stored value repeats the stored value of a previously read
        # entry (the stored values are always lowercased, so this
        # mirrors the case-insensitive unique check of the expansion),
        # is skipped with a warning naming the column values of the
        # ignored duplicate entry (the column values of the first read
        # entry win).
        $duplicate = $false
        foreach ($existingUniqueId in $admittedUniqueIds) {
            if ([string]::Equals($existingUniqueId, $uniqueId, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $nameValue) { $evidenceParts.Add('Name <null>') } else { $evidenceParts.Add('Name ''' + $name + '''') }
            if ($null -eq $descriptionValue) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            if ($null -eq $sdescValue) { $evidenceParts.Add('SDesc <null>') } else { $evidenceParts.Add('SDesc ''' + $sdesc + '''') }
            if ($null -eq $prepositionValue) { $evidenceParts.Add('Preposition <null>') } else { $evidenceParts.Add('Preposition ''' + $preposition + '''') }
            if ($null -eq $locationNameValue) { $evidenceParts.Add('LocationName <null>') } else { $evidenceParts.Add('LocationName ''' + $locationName + '''') }
            if ($null -eq $locationType) { $evidenceParts.Add('LocationType <null>') } else { $evidenceParts.Add('LocationType ' + $locationType) }
            $evidenceParts.Add('Carryable equals ' + $carryable + ' after reading')
            $evidenceParts.Add('Wearable equals ' + $wearable + ' after reading')
            $evidenceParts.Add('Openable equals ' + $openable + ' after reading')
            $evidenceParts.Add('Lockable equals ' + $lockable + ' after reading')
            $evidenceParts.Add('Enterable equals ' + $enterable + ' after reading')
            $evidenceParts.Add('Readable equals ' + $readable + ' after reading')
            $evidenceParts.Add('Container equals ' + $container + ' after reading')
            if ($null -eq $weight) { $evidenceParts.Add('Weight <null>') } else { $evidenceParts.Add('Weight ' + $weight.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
            $evidenceParts.Add('Worn equals ' + $worn + ' after reading')
            $evidenceParts.Add('Read equals ' + $readFlag + ' after reading')
            $evidenceParts.Add('Locked equals ' + $locked + ' after reading')
            $evidenceParts.Add('Open equals ' + $openFlag + ' after reading')
            $evidenceParts.Add('Entered equals ' + $entered + ' after reading')
            $evidenceParts.Add('Visible equals ' + $visible + ' after reading')
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $groupNameValue) { $evidenceParts.Add('GroupName <null>') } else { $evidenceParts.Add('GroupName ''' + $groupName + '''') }
            $evidenceParts.Add('Important equals ' + $important + ' after reading')

            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'Items.yaml' of the source folder: the UniqueID value '$uniqueId' duplicates the UniqueID value of a previously read entry (whose column values win). The ignored duplicate entry has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedUniqueIds.Add($uniqueId)

        $stagedRows.Add([pscustomobject]@{
            UniqueID       = $uniqueId
            Name           = $name
            Description    = $description
            SDesc          = $sdesc
            Preposition    = $preposition
            LocationName   = $locationName
            LocationType   = $locationType
            Carryable      = $carryable
            Wearable       = $wearable
            Openable       = $openable
            Lockable       = $lockable
            Enterable      = $enterable
            Readable       = $readable
            Container      = $container
            Weight         = $weight
            Worn           = $worn
            Read           = $readFlag
            Locked         = $locked
            Open           = $openFlag
            Entered        = $entered
            Visible        = $visible
            EnterFirstTime = $enterFirstTime
            LeaveFirstTime = $leaveFirstTime
            GroupName      = $groupName
            Important      = $important
            EntryIndex     = $entryIndex + 1
        })

        $contributingEntries.Add($entryIndex + 1)
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the Items table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and long values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) (item '$($stagedRow.UniqueID)') to the Items table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [Items] ([UniqueID], [Name], [Description], [SDesc], [Preposition], [LocationName], [LocationType], [Carryable], [Wearable], [Openable], [Lockable], [Enterable], [Readable], [Container], [Weight], [Worn], [Read], [Locked], [Open], [Entered], [Visible], [EnterFirstTime], [LeaveFirstTime], [GroupName], [Important]) VALUES (@uniqueid, @name, @description, @sdesc, @preposition, @locationname, @locationtype, @carryable, @wearable, @openable, @lockable, @enterable, @readable, @container, @weight, @worn, @read, @locked, @open, @entered, @visible, @enterfirsttime, @leavefirsttime, @groupname, @important)'

                    $uniqueIdParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@uniqueid', [System.Data.SqlDbType]::NVarChar, 250)
                    $uniqueIdParameter.Value = $stagedRow.UniqueID
                    $null = $command.Parameters.Add($uniqueIdParameter)

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 250)
                    # The staged text values of the handler are always
                    # strings, so the text parameters bind their staged
                    # values directly (a null source value stages the
                    # empty string); the LocationType and Weight
                    # parameters keep their database-null branches.
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $descriptionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@description', [System.Data.SqlDbType]::NText)
                    $descriptionParameter.Value = $stagedRow.Description
                    $null = $command.Parameters.Add($descriptionParameter)

                    $sdescParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@sdesc', [System.Data.SqlDbType]::NVarChar, 250)
                    $sdescParameter.Value = $stagedRow.SDesc
                    $null = $command.Parameters.Add($sdescParameter)

                    $prepositionParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@preposition', [System.Data.SqlDbType]::NVarChar, 250)
                    $prepositionParameter.Value = $stagedRow.Preposition
                    $null = $command.Parameters.Add($prepositionParameter)

                    $locationNameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@locationname', [System.Data.SqlDbType]::NVarChar, 250)
                    $locationNameParameter.Value = $stagedRow.LocationName
                    $null = $command.Parameters.Add($locationNameParameter)

                    $locationTypeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@locationtype', [System.Data.SqlDbType]::Int)
                    if ($null -eq $stagedRow.LocationType) {
                        $locationTypeParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $locationTypeParameter.Value = $stagedRow.LocationType
                    }
                    $null = $command.Parameters.Add($locationTypeParameter)

                    # A bit parameter requires a boolean value no matter
                    # what the column carried in the YAML file, so every
                    # bit value is bound as the boolean it normalized to
                    # (the not-null Important value included).
                    $carryableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@carryable', [System.Data.SqlDbType]::Bit)
                    $carryableParameter.Value = $stagedRow.Carryable
                    $null = $command.Parameters.Add($carryableParameter)

                    $wearableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@wearable', [System.Data.SqlDbType]::Bit)
                    $wearableParameter.Value = $stagedRow.Wearable
                    $null = $command.Parameters.Add($wearableParameter)

                    $openableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@openable', [System.Data.SqlDbType]::Bit)
                    $openableParameter.Value = $stagedRow.Openable
                    $null = $command.Parameters.Add($openableParameter)

                    $lockableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@lockable', [System.Data.SqlDbType]::Bit)
                    $lockableParameter.Value = $stagedRow.Lockable
                    $null = $command.Parameters.Add($lockableParameter)

                    $enterableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enterable', [System.Data.SqlDbType]::Bit)
                    $enterableParameter.Value = $stagedRow.Enterable
                    $null = $command.Parameters.Add($enterableParameter)

                    $readableParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@readable', [System.Data.SqlDbType]::Bit)
                    $readableParameter.Value = $stagedRow.Readable
                    $null = $command.Parameters.Add($readableParameter)

                    $containerParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@container', [System.Data.SqlDbType]::Bit)
                    $containerParameter.Value = $stagedRow.Container
                    $null = $command.Parameters.Add($containerParameter)

                    $weightParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@weight', [System.Data.SqlDbType]::Float)
                    if ($null -eq $stagedRow.Weight) {
                        $weightParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $weightParameter.Value = $stagedRow.Weight
                    }
                    $null = $command.Parameters.Add($weightParameter)

                    $wornParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@worn', [System.Data.SqlDbType]::Bit)
                    $wornParameter.Value = $stagedRow.Worn
                    $null = $command.Parameters.Add($wornParameter)

                    $readParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@read', [System.Data.SqlDbType]::Bit)
                    $readParameter.Value = $stagedRow.Read
                    $null = $command.Parameters.Add($readParameter)

                    $lockedParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@locked', [System.Data.SqlDbType]::Bit)
                    $lockedParameter.Value = $stagedRow.Locked
                    $null = $command.Parameters.Add($lockedParameter)

                    $openParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@open', [System.Data.SqlDbType]::Bit)
                    $openParameter.Value = $stagedRow.Open
                    $null = $command.Parameters.Add($openParameter)

                    $enteredParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@entered', [System.Data.SqlDbType]::Bit)
                    $enteredParameter.Value = $stagedRow.Entered
                    $null = $command.Parameters.Add($enteredParameter)

                    $visibleParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@visible', [System.Data.SqlDbType]::Bit)
                    $visibleParameter.Value = $stagedRow.Visible
                    $null = $command.Parameters.Add($visibleParameter)

                    $enterFirstTimeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@enterfirsttime', [System.Data.SqlDbType]::Bit)
                    $enterFirstTimeParameter.Value = $stagedRow.EnterFirstTime
                    $null = $command.Parameters.Add($enterFirstTimeParameter)

                    $leaveFirstTimeParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@leavefirsttime', [System.Data.SqlDbType]::Bit)
                    $leaveFirstTimeParameter.Value = $stagedRow.LeaveFirstTime
                    $null = $command.Parameters.Add($leaveFirstTimeParameter)

                    $groupNameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@groupname', [System.Data.SqlDbType]::NVarChar, 255)
                    $groupNameParameter.Value = $stagedRow.GroupName
                    $null = $command.Parameters.Add($groupNameParameter)

                    $importantParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@important', [System.Data.SqlDbType]::Bit)
                    $importantParameter.Value = $stagedRow.Important
                    $null = $command.Parameters.Add($importantParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the Items table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The Items transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the Items data of the RAGS file: the staged rows could not be appended to the Items table. "
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

    Write-Verbose "Compressed the Items data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

