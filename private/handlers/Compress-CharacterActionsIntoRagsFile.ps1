#Requires -Version 5.1
Set-StrictMode -Version Latest

function Compress-CharacterActionsIntoRagsFile {
    <#
    .SYNOPSIS
    Compresses CharacterActions data into a RagsFile.

    .DESCRIPTION
    Compiles the expanded CharacterActions data of a source folder back into
    the CharacterActions table of a RAGS file (schema version 2.6.1) through
    an open SQL Server Compact connection, appending the compressed rows as
    the inverse of Expand-CharacterActionsFromRagsFile and following the
    conventions documented in docs/data-mapping.md.

    Every '.yaml' file of the 'CharacterActions' subfolder of the source
    folder is read as a YAML document mapping a Charname value to a Data
    sequence of RAGS action expansions. Each sequence entry is converted
    from the pretty-printed XML of the entry into its encoded RAGS action
    form (four padding bytes followed by a GZip stream, Base64-encoded)
    through Compress-RagsActionFromXml. One table row is appended per entry
    (the Identity column value is supplied by the database), replicating the
    row order of the original expansion: source files are read in file name
    order, the entries of each file keep their YAML sequence order, and the
    Identity values of the appended rows grow in insertion order, so
    re-expanding the file restores each character's entries in ascending
    row ID order.

    The YAML files of the subfolder are consumed as follows:
    - A file whose Charname value is missing, null, empty or whitespace-only
      is skipped in its entirety with a warning, as no meaningful expansion
      target could be derived from it (its rows may therefore not survive a
      compress/expand cycle and its Data values are discarded).
    - A file whose Data value is missing, null, empty or whitespace-only,
      or whose Data sequence is empty, contributes no rows and is skipped
      with a warning.
    - A Data value which is a scalar (instead of a sequence) is accepted as
      the single entry of the sequence with a warning; a scalar Data value
      which is empty or whitespace-only is treated like a missing Data
      value. Note that a Data value cast to a non-string scalar (for
      example an unquoted number) is still rejected, as no RAGS action can
      be derived from it.
    - Individual entries which are null, empty or whitespace-only are
      skipped with a warning.
    - A Data value which is neither a scalar nor a sequence (for example a
      YAML mapping), a Data entry which is not a string, a file which is
      not a single YAML mapping document, and a non-empty Data entry whose
      content is not well-formed XML abort the whole operation with an
      exception, as no meaningful RAGS action can be derived from them.

    Every file of the subfolder is read, validated and encoded before the
    first row is appended, so the table remains empty when the source
    folder carries invalid content. The appended rows are then written
    inside a transaction, so a failure while appending leaves no partially
    appended data behind.

    The CharacterActions subfolder is read silently; a missing source folder
    or subfolder is not an error and compresses nothing. Files of any other
    extension are skipped with a warning; YAML file names are not
    interpreted, as the character names and file order are re-derived from
    the Charname mapping values of the contents (the file names used by an
    expansion are silently overwritten). A Charname value longer than the
    250 characters of the table column is truncated with a warning; note
    that re-expansion then derives a different file name GUID from the
    truncated value, so such an entry may not survive a compress/expand
    cycle either.

    Compressed rows are appended to the CharacterActions table, which is
    expected to receive them (the RAGS Designer workflow of compressing
    expanded data keeps the convention of fmt:expanded: starting from the
    template file, or a blank/formatted RAGS file at the caller's
    discretion). A source folder compressed more than once into the same
    RAGS file therefore appends the table once per run.

    .PARAMETER SourcePath
    Path of the folder to compress the CharacterActions data from.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the CharacterActions data has been
    compressed successfully.

    .EXAMPLE
    Compress-CharacterActionsIntoRagsFile -SourcePath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Appends the CharacterActions data of the 'C:\Export\MyGame' folder to
    the RAGS file connected through $openRagsConnection.
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
        throw "Cannot compress the CharacterActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently accept a missing source folder or 'CharacterActions'
    # subfolder: no expansion may have happened yet, in which case there is
    # nothing to compress.
    $characterActionsFolder = Join-Path $SourcePath 'CharacterActions'
    if (-not (Test-Path -LiteralPath $characterActionsFolder -PathType Container)) {
        Write-Verbose "The source folder carries no 'CharacterActions' subfolder, so there is no CharacterActions data to compress."
        return $true
    }
    Write-Verbose "Compressing the CharacterActions data of the RAGS file from '$characterActionsFolder'."

    # Collect the files of the subfolder in file name order, so that a given
    # exact character name always receives its rows in a stable and
    # reproducible order. The expansion writes everything as '.yaml' files;
    # anything else is skipped with a warning.
    Write-Verbose "Reading the YAML files of '$characterActionsFolder'."
    $yamlFiles = @(Get-ChildItem -LiteralPath $characterActionsFolder -File |
        Sort-Object -Property Name)
    Write-Verbose "Found $($yamlFiles.Count) file(s) in the 'CharacterActions' subfolder."

    # Stage one row per Data entry before appending anything, so that
    # nothing is written when any source file carries invalid content
    # (all-or-nothing, like every file of the expansion). Every staged value
    # carries the character name, the source file name and the 1-based entry
    # index which produced it for the messages of the append phase, and the
    # Base64-encoded RAGS action payload. The validation of every entry is
    # performed inline below, so that each file is fully validated (and
    # every failure reported) before any file contributes rows.
    $stagedRows = [System.Collections.Generic.List[object]]::new()
    $contributingFileNames = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $yamlFiles) {
        if (-not [System.String]::Equals($file.Extension, '.yaml', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "Skipping the file '$($file.Name)' of the CharacterActions subfolder: it does not have a '.yaml' extension."
            continue
        }

        # Read the whole file as text ([System.IO.File]::ReadAllText
        # auto-detects the UTF-8/UTF-16 byte-order marks and defaults to
        # UTF-8, which matches the encoding the expansion writes).
        try {
            $fileText = [System.IO.File]::ReadAllText($file.FullName)
        }
        catch {
            $message = "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder could not be read. "
            $message += "The file system reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        if ([string]::IsNullOrWhiteSpace($fileText)) {
            throw "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder is empty."
        }

        # Parse the file as a YAML multi-document stream, rejecting files
        # which define more than one document (the expansion writes exactly
        # one mapping per file, and an ambiguity about which mapping to
        # apply cannot be resolved from the file name in general).
        try {
            $parsedDocuments = @(ConvertFrom-Yaml -Yaml $fileText -AllDocuments)
        }
        catch {
            $message = "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder is not a valid YAML document. "
            $message += "The YAML parser reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # ConvertFrom-Yaml returns the parsed value of a single document
        # directly (a mapping, a sequence or a scalar, as read), the values
        # of multiple documents as an object array, and no value at all for
        # an empty stream. An object array is therefore always the sign of
        # a multi-document file (a single-document file can never produce
        # one).
        if ($parsedDocuments.Count -gt 1) {
            throw "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder defines $($parsedDocuments.Count) YAML documents where a single mapping document is expected."
        }

        $mapping = $parsedDocuments[0]
        if ($null -eq $mapping) {
            throw "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder carries no YAML document."
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

            throw "Cannot compress the CharacterActions data of the RAGS file: the file '$($file.Name)' of the CharacterActions subfolder carries $actualType where a mapping is expected."
        }

        # Locate and validate the Charname value of the mapping, which is
        # expected to be the string scalar the expansion wrote.
        $charnameValue = $mapping['Charname']
        if ($null -eq $charnameValue) {
            Write-Warning "Skipping the file '$($file.Name)' of the CharacterActions subfolder: the Charname value is missing or null, so no character can be derived for it."
            continue
        }
        if ($charnameValue -isnot [string]) {
            throw "Cannot compress the CharacterActions data of the RAGS file: the Charname value of the file '$($file.Name)' is of type '$($charnameValue.GetType().FullName)' instead of a string."
        }
        if ([string]::IsNullOrWhiteSpace($charnameValue)) {
            Write-Warning "Skipping the file '$($file.Name)' of the CharacterActions subfolder: the Charname value is empty, so no character can be derived for it."
            continue
        }

        # Truncate the Charname value to the length of the table column, as
        # a longer value could not be stored.
        $charname = $charnameValue
        if ($charname.Length -gt 250) {
            Write-Warning "The Charname value of the file '$($file.Name)' is $($charname.Length) characters long, which exceeds the 250 characters of the table column; the value is truncated. Note that re-expanding the appended data then derives a different file name from the truncated value."
            $charname = $charname.Substring(0, 250)
        }

        # Locate and validate the Data value of the mapping, which is a
        # sequence of pretty-printed XML action expansions. A scalar value
        # is accepted as the single entry of the sequence with a warning,
        # as single-entry sequences are commonly written without their
        # leading sequence dash.
        $dataValue = $mapping['Data']
        if ($null -eq $dataValue) {
            Write-Warning "Skipping the file '$($file.Name)' of character '$charname': the Data value is missing or null, so no data can be derived from it."
            continue
        }

        if ($dataValue -is [System.Collections.IList]) {
            if ($dataValue.Count -eq 0) {
                Write-Warning "Skipping the file '$($file.Name)' of character '$charname': the Data value is an empty sequence, so no data can be derived from it."
                continue
            }
        }
        elseif ($dataValue -is [string]) {
            if ([string]::IsNullOrWhiteSpace($dataValue)) {
                Write-Warning "Skipping the file '$($file.Name)' of character '$charname': the Data value is empty, so no data can be derived from it."
                continue
            }

            Write-Warning "The Data value of the file '$($file.Name)' of character '$charname' is a scalar, not a sequence; it is treated as the single entry of the sequence."
            $coercedEntries = [System.Collections.Generic.List[object]]::new()
            $coercedEntries.Add($dataValue)
            $dataValue = $coercedEntries
        }
        else {
            throw "Cannot compress the CharacterActions data of the RAGS file: the Data value of the file '$($file.Name)' of character '$charname' is of type '$($dataValue.GetType().FullName)', which is neither a scalar nor a sequence."
        }

        # Every Data entry is validated and encoded before any row of the
        # file is staged.
        $fileRowsBefore = $stagedRows.Count
        for ($entryIndex = 0; $entryIndex -lt $dataValue.Count; $entryIndex++) {
            $entryValue = $dataValue[$entryIndex]

            if ($null -eq $entryValue) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for character '$charname': the entry is null."
                continue
            }
            if ($entryValue -isnot [string]) {
                throw "Cannot compress the CharacterActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for character '$charname' is of type '$($entryValue.GetType().FullName)' instead of a string."
            }
            if ([string]::IsNullOrWhiteSpace($entryValue)) {
                Write-Warning "Skipping the entry $($entryIndex + 1) of the file '$($file.Name)' for character '$charname': the entry is empty."
                continue
            }

            # Compress the pretty-printed XML snippet into its encoded RAGS
            # action form; the snippet is linearized (and its line endings
            # normalized) by the compressor, as the payload is usually
            # stored linearized.
            try {
                $encodedAction = Compress-RagsActionFromXml -XmlRagsAction $entryValue
            }
            catch {
                $message = "Cannot compress the CharacterActions data of the RAGS file: the entry $($entryIndex + 1) of the file '$($file.Name)' for character '$charname' could not be compressed as a RAGS action. "
                $message += "The compression reported the following error: '$($_.Exception.Message)'."
                throw [System.Exception]::new($message, $_.Exception)
            }

            $stagedRows.Add([pscustomobject]@{
                Charname = $charname
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
        # Append every staged row to the CharacterActions table inside one
        # transaction, so that a failed INSERT leaves no partially appended
        # data behind. The values are bound through provider parameters
        # throughout, as the text values are not SQL literals (and the
        # payloads are far beyond any quoting limit).
        $transaction = $null
        try {
            $transaction = $RagsConnection.BeginTransaction()

            foreach ($stagedRow in $stagedRows) {
                Write-Verbose "Appending the entry $($stagedRow.EntryIndex) of the file '$($stagedRow.FileName)' for character '$($stagedRow.Charname)' to the CharacterActions table."

                $command = $RagsConnection.CreateCommand()
                try {
                    $command.Transaction = $transaction
                    $command.CommandText = 'INSERT INTO [CharacterActions] ([Charname], [Data]) VALUES (@charname, @data)'

                    $nameParameter = [System.Data.SqlServerCe.SqlCeParameter]::new('@charname', [System.Data.SqlDbType]::NVarChar, 250)
                    $nameParameter.Value = $stagedRow.Charname
                    $null = $command.Parameters.Add($nameParameter)

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
            Write-Verbose "Appended $($stagedRows.Count) row(s) to the CharacterActions table."
        }
        catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                }
                catch {
                    Write-Warning "The CharacterActions transaction of the RAGS file could not be rolled back: $($_.Exception.Message)"
                }
            }

            $message = "Cannot compress the CharacterActions data of the RAGS file: the staged rows could not be appended to the CharacterActions table. "
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

    Write-Verbose "Compressed the CharacterActions data of the RAGS file: $($stagedRows.Count) row(s) appended from $($contributingFileNames.Count) file(s)."
    return $true
}

