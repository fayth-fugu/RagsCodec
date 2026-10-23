#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-PlayerActionsFromRagsFile {
    <#
    .SYNOPSIS
    Expands PlayerActions data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the PlayerActions table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data
    into the single 'PlayerActions.yaml' file in the output folder,
    following the conventions documented in docs/data-mapping.md.

    The written YAML file holds a bare top-level mapping whose Data key
    wraps the sequence of the expanded payloads (the documented sample
    structure of a 'PlayerActions.yaml' file), one entry per Data row of
    the table, in ascending row ID order — 'Table is sorted by ID
    ascending' (docs/data-mapping.md, PlayerActions section). Each entry
    is expanded from the encoded RAGS action of the row (Base64-decoded,
    GZip-decompressed and pretty-printed XML) through
    Expand-RagsActionIntoXml, per the documented 'All Data rows are
    extracted using RagsAction expansion' handling. The expansions are
    staged verbatim: a written value's line breaks are normalized to
    line feeds only when the written YAML is read back (the literal
    block scalar's reading rule).

    Rows with a null, empty or whitespace-only Data value are skipped
    with a warning, as no meaningful payload can be derived from them.
    A row whose non-empty Data value cannot be expanded aborts the whole
    operation with an exception before the file is written (all payloads
    are expanded before the file is created).

    The PlayerActions table carries no List, Unique or Exclude column
    besides its Exclude identity column, so no grouping, name handling
    or duplicate rule applies: every meaningful row contributes one
    entry to the Data sequence. When the table is empty altogether (e.g.
    in a formatted RAGS file), the file is still written, holding the
    empty Data sequence.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one.

    .PARAMETER OutputPath
    Path of the folder to export the expanded PlayerActions data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the PlayerActions data has been
    expanded successfully.

    .EXAMPLE
    Expand-PlayerActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the PlayerActions data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\PlayerActions.yaml'
    file.
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
        throw "Cannot expand the PlayerActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the PlayerActions data into '$OutputPath'."

    # Read all rows of the table, ordered by row ID, as documented for
    # the PlayerActions table ('Table is sorted by ID ascending', see
    # docs/data-mapping.md, PlayerActions section).
    Write-Verbose 'Reading the PlayerActions rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [Data] FROM [PlayerActions] ORDER BY [ID] ASC')
    Write-Verbose "Read $($rows.Count) PlayerActions row(s)."

    # The expanded payloads accumulate into one sequence, in ascending
    # row ID order: the SQL sort is a total order over the ID identity
    # column, so appending each expanded payload as the rows arrive
    # preserves the documented row order.
    $payloads = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the PlayerActions row (ID '$rowId'): the Data value is null or empty."
            continue
        }
        $data = [string]$data

        Write-Verbose "Expanding the RAGS action of the PlayerActions row (ID '$rowId')."
        try {
            $actionXml = Expand-RagsActionIntoXml -EncodedRagsAction $data
        }
        catch {
            $message = "Cannot expand the PlayerActions data of the RAGS file: the Data payload of the row (ID '$rowId') could not be expanded as a RAGS action. "
            $message += "The expansion reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # The expanded action XML is staged verbatim, exactly as
        # Expand-RagsActionIntoXml produced it; a written value's line
        # breaks are normalized to line feeds only when the written YAML
        # is read back (the literal block scalar's reading rule).
        $stagedActionXml = [string]$actionXml
        $payloads.Add($stagedActionXml)
    }

    # Write the single PlayerActions.yaml file. The expanded payloads
    # form the documented bare Data sequence; an empty table (or one
    # whose every row was skipped) emits the empty Data sequence.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ Data = $payloads.ToArray() }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a
    # failure for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw "Cannot expand the PlayerActions data of the RAGS file: the YAML content of the file could not be serialized."
    }

    $filePath = Join-Path $OutputPath 'PlayerActions.yaml'
    if ($payloads.Count -eq 0) {
        Write-Verbose "Writing '$filePath' from an empty PlayerActions table (the empty Data sequence)."
    }
    else {
        Write-Verbose "Writing '$filePath' ($($payloads.Count) Data row(s))."
    }
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the PlayerActions data into '$filePath'."
    return $true
}

