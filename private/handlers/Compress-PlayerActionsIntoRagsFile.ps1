#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-PlayerActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses PlayerActions data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded PlayerActions data of a source folder back into
    the PlayerActions table of a RAGS file (schema version 2.6.1) through
    an open SQL Server Compact connection, appending the compressed rows as
    the inverse of Expand-PlayerActionsFromRagsFile and following the
    conventions documented in docs/data-mapping.md.

    The single 'PlayerActions.yaml' file of the source folder is read as
    a YAML document mapping a 'Data' key to a sequence of RAGS action
    expansions ('Expanded into a single file' handling, docs/data-mapping.md,
    PlayerActions section). Each sequence entry is converted from the
    pretty-printed XML of the entry into its encoded RAGS action form
    (four padding bytes followed by a GZip stream, Base64-encoded)
    through Compress-RagsActionFromXml, per the documented RagsAction
    expansion handling. One table row is appended per entry (the Identity
    column value is supplied by the database), replicating the row order
    of the original expansion: the entries of the file keep their YAML
    sequence order and the Identity values of the appended rows grow in
    insertion order, so re-expanding the appended data restores the
    entries in the documented ascending row ID order.

    The YAML file is consumed as follows:
    - A mapping defining keys other than 'Data' is accepted with one
      warning naming the unexpected keys; the unexpected keys are
      ignored.
    - A file whose Data value is missing or null is skipped in its
      entirety with a warning, as no meaningful entry could be derived
      from it.
    - A Data value which is a scalar (instead of a sequence) is accepted
      as the single entry of the sequence with a warning; a scalar Data
      value which is empty or whitespace-only is treated like a missing
      Data value. Note that a scalar of any other type than a string (a
      hand-edited unquoted number, for example) is still rejected, as no
      RAGS action can be derived from it.
    - A Data value which is an empty sequence contributes no rows
      silently, as this is exactly the content the expansion writes for
      an empty table (or for one whose every row was previously
      skipped), so the empty state round-trips without complaint.
    - A Data value which is neither a scalar nor a sequence (a YAML
      mapping, for example) aborts the whole operation with an
      exception.
    - Individual entries which are null, empty or whitespace-only are
      skipped with a warning.
    - A Data entry which is not a string scalar aborts the whole
      operation with an exception.
    - A file which defines more than one YAML document is consumed from
      its first document only, with a warning naming the file and the
      number of ignored extra documents.
    - A YAML document which is not a mapping, and a non-empty Data entry
      whose content is not well-formed XML abort the whole operation
      with an exception, as no meaningful RAGS action can be derived
      from them.

    Every entry of the file is read, validated and encoded before the
    first row is appended, so the table remains empty when the source
    file carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no
    partially appended data behind.

    The documented expansion sorts the table by ID ascending and writes
    its payloads into one bare Data sequence; no other machinery applies.
    The PlayerActions table carries no List, Unique or Exclude column
    besides its Exclude identity column, so no grouping, name handling,
    duplicate rule, casing rule or truncation exists: every meaningful
    entry contributes one row under its own payload value, and every
    duplicate payload is appended as another row, mirroring the
    non-deduplicated sequence the expansion writes.

    Compressed rows are appended to the PlayerActions table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of starting from the template
    file, or a blank/formatted RAGS file at the caller's discretion). A
    source file compressed more than once into the same RAGS file
    therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the PlayerActions data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the PlayerActions data has been
    compressed successfully.

    .EXAMPLE
    Compress-PlayerActionsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the expanded PlayerActions data of the 'C:\Export\MyGame'
    folder to the RAGS file connected through $openRagsConnection.
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
        throw "Cannot compress the PlayerActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'PlayerActions.yaml'
    # file: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $filePath = Join-Path $SourcePath 'PlayerActions.yaml'
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Verbose "The source folder carries no 'PlayerActions.yaml' file, so there is no PlayerActions data to compress."
        return $true
    }
    Write-Verbose "Compressing the PlayerActions data of the RAGS file from '$filePath'."

    # Read the whole file as text ([System.IO.File]::ReadAllText
    # auto-detects the UTF-8/UTF-16 byte-order marks and defaults to
    # UTF-8, which matches the encoding the expansion writes).
    try {
        $fileText = [System.IO.File]::ReadAllText($filePath)
    }
    catch {
        $message = "Cannot compress the PlayerActions data of the RAGS file: the file 'PlayerActions.yaml' of the source folder could not be read. "
        $message += "The file system reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ([string]::IsNullOrWhiteSpace($fileText)) {
        throw "Cannot compress the PlayerActions data of the RAGS file: the file 'PlayerActions.yaml' of the source folder is empty."
    }

    # Parse the file as a YAML multi-document stream, consuming a
    # multi-document file from its first document only.
    try {
        $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
    }
    catch {
        $message = "Cannot compress the PlayerActions data of the RAGS file: the file 'PlayerActions.yaml' of the source folder is not a valid YAML document. "
        $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
        throw [System.Exception]::new($message, $_.Exception)
    }

    # ConvertFrom-Yaml returns the parsed value of a multi-document
    # stream as one value per document, so a count above one still is
    # the sign of extra documents (the array wrap can inflate the count
    # when a document itself is a sequence, but the warning below only
    # dismisses trailing content, so the read below cannot be
    # misdirected).
    if ($parsedDocuments.Count -gt 1) {
        Write-Warning "The file 'PlayerActions.yaml' of the source folder defines $($parsedDocuments.Count) YAML documents; only the first document is used and the remaining $($parsedDocuments.Count - 1) document(s) are ignored."
    }

    # ConvertFrom-Yaml returns the parsed value of a single document
    # directly (a mapping, a sequence or a scalar, as read), the values
    # of multiple documents as an object array, and no value at all for
    # an empty stream - including a stream which carries comments only,
    # which yields nothing at all. A missing value after the parse is
    # therefore reported like a missing document; the count is guarded
    # first, so that a comment-only stream reaches the contextual throw
    # below instead of a raw array-index error under strict mode.
    $rootDocument = $null
    if ($parsedDocuments.Count -gt 0) {
        $rootDocument = $parsedDocuments[0]
    }
    if ($null -eq $rootDocument) {
        throw "Cannot compress the PlayerActions data of the RAGS file: the file 'PlayerActions.yaml' of the source folder carries no YAML document."
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

        throw "Cannot compress the PlayerActions data of the RAGS file: the file 'PlayerActions.yaml' of the source folder carries $rootType where a mapping is expected."
    }

    # Resolve the Data value of the document mapping by key, so that the
    # key comparison does not depend on the dictionary semantics of the
    # YAML reader: the expansion writes 'Data' exactly, and any other
    # key (a case variant included) counts as unexpected.
    $dataValue = $null
    $documentExtraKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($documentKey in $rootDocument.Keys) {
        $documentKeyText = [string]$documentKey
        if ([string]::Equals($documentKeyText, 'Data', [System.StringComparison]::Ordinal)) {
            $dataValue = $rootDocument[$documentKey]
        }
        else {
            $documentExtraKeys.Add($documentKeyText)
        }
    }
    if ($documentExtraKeys.Count -gt 0) {
        $documentExtraKeyText = ($documentExtraKeys | ForEach-Object { "'" + $_ + "'" }) -join ', '
        Write-Warning "The file 'PlayerActions.yaml' of the source folder defines the unexpected key(s) $documentExtraKeyText; they are ignored."
    }

    # The Data value of the document is a sequence of pretty-printed XML
    # action expansions exactly as the expansion wrote them. A missing or
    # null value skips the file with a warning (there is nothing to
    # append). An empty sequence is accepted silently: the expansion
    # writes it for an empty table (or for one whose every row was
    # previously skipped), so the empty state round-trips without
    # complaint. A scalar value is accepted as the single entry of the
    # sequence with a warning, as single-entry sequences are commonly
    # written without their leading sequence dash; a scalar value which
    # is empty or whitespace-only is treated like a missing Data value.
    # Any other Data value aborts the operation, as no RAGS action can
    # be derived from it.
    if ($null -eq $dataValue) {
        Write-Warning "Skipping the file 'PlayerActions.yaml' of the source folder: the Data value is missing or null, so no data can be derived from it."
    }
    elseif ($dataValue -is [System.Collections.IList]) {
        if ($dataValue.Count -eq 0) {
            Write-Verbose "The Data value of the file 'PlayerActions.yaml' of the source folder is an empty sequence, so no row is appended from it."
        }
    }
    elseif ($dataValue -is [string]) {
        if ([string]::IsNullOrWhiteSpace($dataValue)) {
            Write-Warning "Skipping the file 'PlayerActions.yaml' of the source folder: the Data value is empty, so no data can be derived from it."
        }
        else {
            Write-Warning "The Data value of the file 'PlayerActions.yaml' of the source folder is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($dataValue)
            $dataValue = $coercedEntries
        }
    }
    else {
        throw "Cannot compress the PlayerActions data of the RAGS file: the Data value of the file 'PlayerActions.yaml' of the source folder is of type '$($dataValue.GetType().FullName)', which is neither a scalar nor a sequence."
    }

    # Stage one row per Data entry before appending anything, so that
    # nothing is written when the source file carries invalid content
    # (all-or-nothing). Only a sequence (or a previously coerced scalar)
    # carries entries; a missing, null or scalar-but-empty Data value
    # left no sequence behind and never enters the loop below.
    $stagedRows = [System.Collections.Generic.List[object]]::new()

    if ($dataValue -is [System.Collections.IList]) {
        for ($entryIndex = 0; $entryIndex -lt $dataValue.Count; $entryIndex++) {
            $entryValue = $dataValue[$entryIndex]

            if ($null -eq $entryValue) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'PlayerActions.yaml' of the source folder: the entry is null."
                continue
            }
            if ($entryValue -isnot [string]) {
                throw "Cannot compress the PlayerActions data of the RAGS file: the entry $($entryIndex + 1) of the file 'PlayerActions.yaml' of the source folder is of type '$($entryValue.GetType().FullName)' instead of a string."
            }
            if ([string]::IsNullOrWhiteSpace($entryValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file 'PlayerActions.yaml' of the source folder: the entry is empty."
                continue
            }

            # Compress the pretty-printed XML snippet into its encoded
            # RAGS action form; the snippet is linearized (its line
            # breaks stripped by the XML writer) by the compressor, as
            # the payload is usually stored linearized.
            try {
                $encodedAction = Compress-RagsActionFromXml -XmlRagsAction $entryValue
            }
            catch {
                $message = "Cannot compress the PlayerActions data of the RAGS file: the entry $($entryIndex + 1) of the file 'PlayerActions.yaml' of the source folder could not be compressed as a RAGS action. "
                $message += "The compression reported the following error: '$($_.Exception.Message)'."
                throw [System.Exception]::new($message, $_.Exception)
            }

            $stagedRows.Add([pscustomobject]@{
                FileName = 'PlayerActions.yaml'
                EntryIndex = $entryIndex + 1
                Payload = $encodedAction
            })
        }
    }

    if ($stagedRows.Count -gt 0) {
        # Append every staged row to the PlayerActions table inside one
        # transaction, so that a failed INSERT leaves no partially
        # appended data behind. The payload is bound through a provider
        # parameter throughout, as it is not an SQL literal (and the
        # payloads are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) of the file 'PlayerActions.yaml' of the source folder to the PlayerActions table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [PlayerActions] ([Data]) VALUES (@data)'

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
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the PlayerActions table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The PlayerActions transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the PlayerActions data of the RAGS file: the staged rows could not be appended to the PlayerActions table. "
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

    Write-Verbose "Compressed the PlayerActions data of the RAGS file: $($stagedRows.Count) row(s) appended from the file 'PlayerActions.yaml' of the source folder."
    return $true
}

