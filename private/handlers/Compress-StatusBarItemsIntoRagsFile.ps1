#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-StatusBarItemsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses StatusBarItems data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded StatusBarItems data of a source folder back into
    the StatusBarItems table of a RAGS file (schema version 2.6.1) through
    an open SQL Server Compact connection, appending the compressed rows as
    the inverse of Expand-StatusBarItemsFromRagsFile and following the
    conventions documented in docs/data-mapping.md.

    The single 'StatusBarItems.yaml' file of the source folder is read as a
    YAML document holding a top-level 'StatusBarItems' mapping whose value
    is a sequence with one entry per status bar item, each mapping the four
    non-id columns of the StatusBarItems table: the Name key (the
    documented Unique column), the Text value, the Width value and the
    Visible value. One table row is appended per status bar item entry,
    replicating the row order of the original expansion: entries keep
    their YAML sequence order, which is the ascending ID order of the
    original table read, as documented for the 'StatusBarItems' table in
    docs/data-mapping.md (the new rows receive freshly generated identity
    IDs, as the ID column is excluded from the expansion).

    The 'StatusBarItems.yaml' file is consumed as follows:

    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping aborts the whole operation
      with an exception (the expansion writes the 'StatusBarItems'
      envelope around the entry sequence, so a non-mapping document
      predates this layout). Keys of the document other than the
      'StatusBarItems' envelope key are ignored with a warning.
    - A document whose StatusBarItems value is missing, null, empty or
      whitespace-only contributes no rows and is skipped with a warning.
      A StatusBarItems value which is an empty sequence is treated like
      the empty sequence an expansion writes for an empty table and
      contributes no rows without a warning.
    - A StatusBarItems value which is a scalar or a single mapping (as
      hand-edited files omitting the trailing sequence dash commonly are)
      is accepted as the single entry of the sequence with a warning; the
      single entry is then validated like any other entry, so a scalar
      single entry aborts the whole operation with an exception (no
      meaningful row can be derived from it). A StatusBarItems value
      which is a scalar but not a string is first coerced to its string
      form with a warning, the string form of format-sensitive values
      being derived with the invariant culture.
    - Entries which are null are skipped with a warning. An entry which
      is not a mapping aborts the whole operation with an exception, as
      no meaningful row can be derived from it.
    - A Name value which is missing or null is stored as the empty
      string WITHOUT a warning, mirroring the null-string emission rule
      of this table's expansion (which emits an entry for a row with a
      null, empty or whitespace-only Name value instead of skipping
      it, writing a null Name value as the empty string). Such an entry
      is therefore compressed back verbatim: its Name is the empty
      string (missing, null or empty value) or the verbatim
      whitespace-only string, the empty string and a whitespace-only
      string being distinct from each other (no value is trimmed or
      otherwise normalized). A Name value which is a sequence or a
      mapping aborts the whole operation with an exception; a Name value
      which is a scalar but not a string (a hand-edited unquoted number,
      for example) is coerced to its string form with a warning, the
      string form of format-sensitive values being derived with the
      invariant culture.
    - A Name value longer than the 255 characters of the table column is
      truncated with a warning; note that re-expanding the appended data
      then derives a different entry from the truncated value.
    - The Text value is stored with the same scalar coercion as the Name
      value, verbatim and without a length limit (ntext): no truncation
      is applied and no line-ending normalization is performed (the
      expansion family's verbatim contract — a multi-line value re-emits
      through a YAML literal block whose re-read normalizes the written
      breaks to line feeds, while a parsed carriage return from a
      double-quoted '\r' escape arrives as-is). A Text value which is
      missing or null is stored as the empty string without a warning,
      mirroring the null-string emission rule of the expansion (a null
      Text value is emitted as the empty string). A Text value which is
      a sequence or a mapping aborts the whole operation with an
      exception.
    - A Width value which is missing or null is stored as a database null
      without a warning, as the expansion emits a YAML null for a null
      Width column. A Width value which is an integer scalar is stored as
      read, through a 64-bit intermediate before the 32-bit assign so
      that an integer beyond the range of the int table column is
      rejected with the same message as any other unparseable value.
      Any other scalar is parsed with the invariant culture with a
      warning; a value which cannot be parsed aborts the whole operation
      with an exception.
    - The Visible column does not allow a database null, so an entry
      whose Visible value is missing or null is stored as the true the
      table documents as its default value, with a warning. A Visible
      value which is a boolean is stored as read; an integer scalar of 1
      or 0 is accepted with a warning (conversions run through a 64-bit
      intermediate, so an integer beyond the 32-bit range is rejected
      below instead of failing a cast); a value of any other type or
      content aborts the whole operation with an exception.
    - Keys of an entry other than the four column names are ignored with
      a warning.
    - An entry which repeats the Name value of a previously read entry is
      skipped with a warning which names the column values of the ignored
      duplicate entry (the column values of the first read entry win).
      The duplicate comparison ignores character case and treats a null
      Name value (which stages the empty string) as equal to the
      empty-Name string, per the documented Unique rule for the
      'StatusBarItems' table in docs/data-mapping.md ('Values are
      case-insensitive'; 'Only the first detected casing will be read')
      and the 'StatusBarItems.Name' breaking-change convention which
      keeps the first instance of any status bar item name stored
      verbatim and discards every subsequent repeat. No value is trimmed,
      so the empty string and a whitespace-only string stay distinct.
      The duplicate comparison never reads the rows already present in
      the table, so appending the data of a folder multiple times into
      the same RAGS file appends the entries again in full.

    The 'StatusBarItems.yaml' file is read, validated and fully staged
    before the first row is appended, so the table remains empty when the
    source folder carries invalid content. The appended rows are then
    written inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The 'StatusBarItems.yaml' file is read silently; a missing source
    folder or file is not an error and compresses nothing.

    Compressed rows are appended to the StatusBarItems table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source folder compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the StatusBarItems data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the StatusBarItems data has been
    compressed successfully into the RAGS file.

    .EXAMPLE
    Compress-StatusBarItemsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded StatusBarItems data of the 'C:\Export\MyGame'
    folder to the StatusBarItems table of the RAGS file connected through
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
        throw "Cannot compress the StatusBarItems data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'StatusBarItems.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'StatusBarItems.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'StatusBarItems.yaml' file, so there is no StatusBarItems data to compress."
        return $true
    }
    Write-Verbose "Compressing the StatusBarItems data of the RAGS file from '$filePath'."

    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the StatusBarItems data of the RAGS file: the file 'StatusBarItems.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the StatusBarItems data of the RAGS file: the file 'StatusBarItems.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the StatusBarItems data of the RAGS file: the file 'StatusBarItems.yaml' of the source folder is not a valid YAML document. "
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
        Write-Warning "The file 'StatusBarItems.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
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
        throw "Cannot compress the StatusBarItems data of the RAGS file: the file 'StatusBarItems.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the StatusBarItems data of the RAGS file: the file 'StatusBarItems.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Ignore any unexpected key of the document with a warning, as the
    # expansion writes the document as a single 'StatusBarItems' envelope
    # mapping.
    $envelopeExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if (-not [string]::Equals($documentKeyText, 'StatusBarItems', [System.StringComparison]::Ordinal)) {
            $envelopeExtraKeys.Add($documentKeyText)
        }
    }
    if ($envelopeExtraKeys.Count -gt 0) {
        $envelopeExtraKeyText = ($envelopeExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'StatusBarItems.yaml' of the source folder defines the unexpected key(s) $envelopeExtraKeyText; they are ignored."
    }

    # Locate the envelope of the expansion, whose value is the entry
    # sequence. The envelope value starts as an empty sequence, so that a
    # missing or empty envelope contributes no rows. A scalar or
    # single-mapping envelope is accepted as the single entry of the
    # sequence with a warning, as hand-edited files commonly omit the
    # trailing sequence dash.
    $entriesValue = [System.Collections.Generic.List[object]]::new()
    $envelopeValue = $rootDocument['StatusBarItems']
    if ($null -eq $envelopeValue) {
        Write-Warning "Skipping the file 'StatusBarItems.yaml' of the source folder: the StatusBarItems value is missing or null, so no status bar item data can be derived from it."
    }
    elseif ($envelopeValue -is [System.Collections.IList]) {
        $entriesValue = $envelopeValue
    }
    elseif ($envelopeValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($envelopeValue)) {
            Write-Warning "Skipping the file 'StatusBarItems.yaml' of the source folder: the StatusBarItems value is empty, so no status bar item data can be derived from it."
        }
        else {
            Write-Warning "The StatusBarItems value of the file 'StatusBarItems.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($envelopeValue)
            $entriesValue = $coercedEntries
        }
    }
    elseif ($envelopeValue -is [System.Collections.IDictionary]) {
        Write-Warning "The StatusBarItems value of the file 'StatusBarItems.yaml' of the source folder is a single mapping, not a sequence; it is treated as the single entry of the sequence."
        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }
    else {
        # A scalar envelope value of any kind is accepted as the single
        # entry of the sequence (the dispatch above leaves only scalars
        # here, so the classification can no longer fail); the single
        # entry is validated like any other entry below, which is what
        # a scalar single entry eventually fails with.
        Write-Warning "The StatusBarItems value of the file 'StatusBarItems.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
        if ($envelopeValue -isnot [string]) {
            # A non-string scalar (a hand-edited unquoted number, for
            # example) is coerced to its string form with a warning; a
            # number, a boolean or another format-sensitive form never
            # coerces to a whitespace-only string, so no empty-value
            # skip applies here.
            Write-Warning "The StatusBarItems value of the file 'StatusBarItems.yaml' of the source folder is of type '$($envelopeValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
            if ($envelopeValue -is [System.IFormattable]) {
                $envelopeValue = $envelopeValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                $envelopeValue = [string]$envelopeValue
            }
        }

        $coercedEntries = [System.Collections.Generic.List[object]]::new()
        $coercedEntries.Add($envelopeValue)
        $entriesValue = $coercedEntries
    }

    # Stage one row per status bar item entry before appending anything,
    # so that nothing is written when the source file carries invalid
    # content (all-or-nothing, like every file of the expansion). Every
    # staged value carries the four column values of the row and the
    # 1-based entry index which produced it for the messages of the
    # append phase. The validation of every entry is performed inline
    # below, so that the file is fully validated (and every failure
    # reported) before any row is staged.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingEntries = [System.Collections.Generic.List[int]]::new()

    # The Name values of the entries whose rows were staged are kept in a
    # separately typed list so that the duplicate check below can compare
    # them case-insensitively (the documented Unique handling of the
    # table — "If multiple identical Names exist, then only the first
    # row's column values will be read" with "Values are
    # case-insensitive", see the StatusBarItems section of
    # docs/data-mapping.md). The list is typed for objects because the
    # elected contract of this table also admits entries with a null Name
    # value, which participate in the duplicate check as their own value:
    # after the first read null Name, every further null Name entry is a
    # duplicate of it.
    $admittedValues = [System.Collections.Generic.List[object]]::new()

    for ($entryIndex = 0; $entryIndex -lt $entriesValue.Count; $entryIndex++) {
        $entryValue = $entriesValue[$entryIndex]
        if ($null -eq $entryValue) {
            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder: the entry is null."
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

            throw "Cannot compress the StatusBarItems data of the RAGS file: the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries $entryType where a mapping is expected."
        }

        # The Name value of the entry, which is expected to be the string
        # scalar the expansion wrote. Contrary to the key column of the
        # other unique-keyed handlers, a missing or null Name value does
        # NOT skip the entry: the elected contract of the expansion
        # emits an entry for a row with a null, empty or whitespace-only
        # Name value instead of skipping it, so such an entry is
        # compressed back verbatim (a database null for a missing or
        # null value, the empty string or the verbatim whitespace-only
        # string otherwise, with no value normalized or trimmed). A
        # sequence or a mapping value aborts the whole operation, and a
        # non-string scalar is coerced to its string form with a
        # warning, mirroring the tolerant scalar ladder of the other
        # text columns.
        $nameValue = $entryValue['Name']
        $name = ''
        if ($null -ne $nameValue) {
            if ($nameValue -is [System.Collections.IList]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($nameValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Name of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($nameValue -is [string]) {
                $name = $nameValue
            }
            else {
                Write-Warning "The Name of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is of type '$($nameValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($nameValue -is [System.IFormattable]) {
                    $name = $nameValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $name = [string]$nameValue
                }
            }

            # Truncate the Name value to the length of the table column,
            # as a longer value could not be stored. The truncation runs
            # before the duplicate check below, so the stored value is
            # what the check validates (a truncated entry may therefore
            # duplicate a previously read entry whose raw value only
            # shared the truncation of this one).
            if ($name.Length -gt 255) {
                Write-Warning "The Name value of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is $($name.Length) characters long, which exceeds the 255 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different entry from the truncated value."
                $name = $name.Substring(0, 255)
            }
        }

        # The multi-line Text value is staged verbatim (its line breaks
        # are kept; a parsed carriage return from a double-quoted '\r'
        # escape reaches the table verbatim, while the line breaks the
        # expansion wrote through a literal block are re-read as line
        # feeds by the YAML parser). Like every ntext column it holds no
        # length limit to truncate to, and the value is derived BEFORE
        # the duplicate check below so that the warning of the check
        # reports the normalized value of the ignored duplicate entry
        # (the evidence tests this raw parsed value, not the staged
        # one).
        $textValue = $entryValue['Text']
        $text = ''
        if ($null -ne $textValue) {
            if ($textValue -is [System.Collections.IList]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Text of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a sequence where a scalar value is expected."
            }
            elseif ($textValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Text of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a mapping where a scalar value is expected."
            }
            elseif ($textValue -is [string]) {
                $text = $textValue
            }
            else {
                Write-Warning "The Text of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is of type '$($textValue.GetType().FullName)' instead of a string; it is coerced to its invariant string form."
                if ($textValue -is [System.IFormattable]) {
                    $text = $textValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $text = [string]$textValue
                }
            }
        }

        # The Width value of the entry, which the expansion writes as an
        # integer scalar read from the nullable int column. A missing or
        # null value is stored as a database null without a warning. An
        # integer scalar is stored as read — it is converted through a
        # 64-bit intermediate before the 32-bit assign, so an integer
        # beyond the range of the int table column is rejected with the
        # same message as any other unparseable value instead of a raw
        # cast failure. Any other scalar is parsed with the invariant
        # culture with a warning; a value which cannot be parsed aborts
        # the whole operation with an exception.
        $widthValue = $entryValue['Width']
        $width = $null
        if ($null -ne $widthValue) {
            if ($widthValue -is [System.Collections.IList]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a sequence where an integer scalar is expected."
            }
            elseif ($widthValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a mapping where an integer scalar is expected."
            }
            elseif (($widthValue -is [int]) -or ($widthValue -is [long])) {
                # The value is converted through a 64-bit intermediate
                # before the 32-bit assign, so that an integer beyond the
                # range of the int table column reports the contextual
                # rejection instead of a raw cast failure.
                $widthLong = [System.Convert]::ToInt64($widthValue)
                if (($widthLong -lt [int]::MinValue) -or ($widthLong -gt [int]::MaxValue)) {
                    throw "Cannot compress the StatusBarItems data of the RAGS file: the Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                }
                $width = [int]$widthLong
            }
            else {
                $widthText = $null
                if ($widthValue -is [string]) {
                    if ([string]::IsNullOrWhiteSpace($widthValue)) {
                        throw "Cannot compress the StatusBarItems data of the RAGS file: the Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                    }
                    $widthText = $widthValue
                    Write-Warning "The Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is of type '$($widthValue.GetType().FullName)' instead of an integer; it is parsed with the invariant culture."
                }
                else {
                    Write-Warning "The Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is of type '$($widthValue.GetType().FullName)' instead of an integer; it is coerced to its invariant string form and parsed with the invariant culture."
                    if ($widthValue -is [System.IFormattable]) {
                        $widthText = $widthValue.ToString([string]::Empty, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    else {
                        $widthText = [string]$widthValue
                    }
                }

                $parsedWidth = 0
                if (-not [int]::TryParse($widthText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedWidth)) {
                    throw "Cannot compress the StatusBarItems data of the RAGS file: the Width of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is a scalar which cannot be parsed as an integer."
                }
                $width = $parsedWidth
            }
        }

        # The Visible value of the entry, which the expansion writes as a
        # boolean scalar read from the two-state column. The column does
        # not allow a database null, so a missing or null value is stored
        # as the true the table documents as its default value, with a
        # warning. A boolean value is read as is, and an integer value
        # which is 0 or 1 is read as the matching boolean with a warning
        # (the conversion runs through a 64-bit intermediate, so an
        # integer beyond the range of the int table column cannot
        # overflow the two-state comparison below); a value of any other
        # type or content aborts the whole operation with an exception.
        $visibleValue = $entryValue['Visible']
        $visible = $true
        if ($visibleValue -is [bool]) {
            $visible = $visibleValue
        }
        elseif ($null -eq $visibleValue) {
            Write-Warning "The Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is missing or null; it is stored as the true the not-null table column documents as its default value."
        }
        else {
            if ($visibleValue -is [System.Collections.IList]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a sequence where a boolean scalar is expected."
            }
            elseif ($visibleValue -is [System.Collections.IDictionary]) {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder carries a mapping where a boolean scalar is expected."
            }
            elseif (($visibleValue -is [int]) -or ($visibleValue -is [long])) {
                # The value is converted to a 64-bit integer before the
                # two-state comparison, so that an integer beyond the
                # range of the 32-bit column cannot overflow the
                # comparison and instead reports the contextual
                # rejection below.
                $visibleNumber = [System.Convert]::ToInt64($visibleValue)
                if ($visibleNumber -eq 1) {
                    Write-Warning "The Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is the integer 1 instead of a boolean; it is stored as the boolean true."
                    $visible = $true
                }
                elseif ($visibleNumber -eq 0) {
                    Write-Warning "The Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is the integer 0 instead of a boolean; it is stored as the boolean false."
                    $visible = $false
                }
                else {
                    throw "Cannot compress the StatusBarItems data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is the integer $visibleNumber, which is neither 0 nor 1."
                }
            }
            else {
                throw "Cannot compress the StatusBarItems data of the RAGS file: the Visible of the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder is of type '$($visibleValue.GetType().FullName)', which is neither a boolean nor the integer 0 or 1."
            }
        }

        # Ignore any unexpected key of the entry with a warning, as the
        # expansion writes entries with the four column names only.
        $entryExtraKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($entryKey in $entryValue.Keys) {
            $entryKeyText = [string]$entryKey
            if ((-not [string]::Equals($entryKeyText, 'Name', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Text', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Width', [System.StringComparison]::Ordinal)) -and
                (-not [string]::Equals($entryKeyText, 'Visible', [System.StringComparison]::Ordinal))) {
                $entryExtraKeys.Add($entryKeyText)
            }
        }
        if ($entryExtraKeys.Count -gt 0) {
            $entryExtraKeyText = ($entryExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
            Write-Warning "The entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder for status bar item '$name' defines the unexpected key(s) $entryExtraKeyText; they are ignored."
        }

        # Soft-validate the Unique Name column: an entry whose value
        # compares equal to a previously read entry's value — ignoring
        # character case, and treating two null values as equal — is
        # skipped with a warning naming the column values of the ignored
        # duplicate entry (the column values of the first read entry
        # win). No value is trimmed: the empty string and a
        # whitespace-only string are NOT duplicates of each other, and
        # every admitted Name value keeps the verbatim casing of the
        # first read entry.
        $isDuplicate = $false
        foreach ($existingValue in $admittedValues) {
            if ($null -eq $existingValue) {
                if ($null -eq $name) {
                    $isDuplicate = $true
                    break
                }
            }
            elseif ($null -ne $name) {
                if ([string]::Equals([string]$existingValue, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isDuplicate = $true
                    break
                }
            }
        }
        if ($isDuplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            $evidenceParts.Add("Name '$name'")
            if ($null -eq $textValue) { $evidenceParts.Add('Text <null>') } else { $evidenceParts.Add('Text ' + $text) }
            if ($null -eq $width) { $evidenceParts.Add('Width <null>') } else { $evidenceParts.Add('Width ' + [string]$width) }
            if ($visible) { $evidenceParts.Add('Visible True') } else { $evidenceParts.Add('Visible False') }

            Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'StatusBarItems.yaml' of the source folder: the Name value '$name' duplicates the Name value of a previously read entry (whose column values win). The ignored duplicate entry has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedValues.Add($name)

        $stagedRows.Add([pscustomobject]@{
            Name       = $name
            Text       = $text
            Width      = $width
            Visible    = $visible
            EntryIndex = $entryIndex + 1
        })

        $contributingEntries.Add($entryIndex + 1)
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the StatusBarItems table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The values are bound through provider
        # parameters throughout, as the text values are not SQL literals
        # (and multi-line values are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) (status bar item '$($stagedRow.Name)') to the StatusBarItems table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [StatusBarItems] ([Name], [Text], [Width], [Visible]) VALUES (@name, @text, @width, @visible)'

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@name', [System.Data.SqlDbType]::NVarChar, 255)
                    # The staged Name and Text values are always strings
                    # (a null source value stages the empty string), so
                    # the text parameters bind their staged values
                    # directly; the Width parameter keeps its
                    # database-null branch.
                    $nameParameter.Value = $stagedRow.Name
                    $null = $command.Parameters.Add($nameParameter)

                    $textParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@text', [System.Data.SqlDbType]::NText)
                    $textParameter.Value = $stagedRow.Text
                    $null = $command.Parameters.Add($textParameter)

                    $widthParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@width', [System.Data.SqlDbType]::Int)
                    if ($null -eq $stagedRow.Width) {
                        $widthParameter.Value = [System.DBNull]::Value
                    }
                    else {
                        $widthParameter.Value = $stagedRow.Width
                    }
                    $null = $command.Parameters.Add($widthParameter)

                    # A bit parameter requires a boolean value no matter
                    # what the column carried in the YAML file, so the
                    # normalized value is bound as the boolean it is.
                    $visibleParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@visible', [System.Data.SqlDbType]::Bit)
                    $visibleParameter.Value = $stagedRow.Visible
                    $null = $command.Parameters.Add($visibleParameter)

                    $null = $command.ExecuteNonQuery()
                }
                finally {
                    $command.Dispose()
                }
            }

            $transaction.Commit()
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the StatusBarItems table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The StatusBarItems transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the StatusBarItems data of the RAGS file: the staged rows could not be appended to the StatusBarItems table. "
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

    Write-Verbose "Compressed the StatusBarItems data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingEntries.Count) entr$(if ($contributingEntries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

