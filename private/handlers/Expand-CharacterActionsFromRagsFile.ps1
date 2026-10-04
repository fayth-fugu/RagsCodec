#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-CharacterActionsFromRagsFile {
    <#
    .SYNOPSIS
    Expands CharacterActions data from a RagsFile into YAML files.

    .DESCRIPTION
    Reads the CharacterActions table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    one YAML file per distinct Charname value, written into the
    'CharacterActions' subfolder of the output folder, following the
    conventions documented in docs/data-mapping.md.

    Each file is named by the GUID derived from the Charname value (see
    ConvertTo-RagsFilenameGuid) with a lowercase '.yaml' extension and
    contains a mapping with the Charname value and the Data sequence holding
    one entry per Data row of the character. Each entry is expanded from the
    encoded RAGS action of the row (Base64-decoded, GZip-decompressed and
    pretty-printed XML) through Expand-RagsActionIntoXml.

    Rows with a null, empty or whitespace-only Charname or Data value are
    skipped with a warning, as no meaningful expansion target or content can
    be derived from them. A row whose non-empty Data value cannot be expanded
    aborts the whole operation with an exception before any YAML file is
    written (all payloads are expanded before any file is created).

    The subfolder and its parent folders are created silently when missing,
    and written files silently overwrite existing ones. Rows of one character
    appear in the Data sequence in ascending row ID order (rows of
    intermingled characters whose names differ only in character case are
    grouped case-sensitively, keeping each character's rows ID-ordered);
    such characters are expanded into separate files.

    .PARAMETER OutputPath
    Path of the folder to export the expanded CharacterActions data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the CharacterActions data has been
    expanded successfully.

    .EXAMPLE
    Expand-CharacterActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the CharacterActions data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\CharacterActions' folder.
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
        throw "Cannot expand the CharacterActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the 'CharacterActions' subfolder when it is missing
    # (this also creates the output folder itself and any missing parents).
    $characterActionsFolder = Join-Path $OutputPath 'CharacterActions'
    $null = New-Item -ItemType Directory -Force -Path $characterActionsFolder
    Write-Verbose "Expanding the CharacterActions data into '$characterActionsFolder'."

    # Read all rows of the table, ordered first by Charname and then by row
    # ID, as documented. The Charname column of the database is collated
    # case-insensitively, so rows of characters whose names differ only in
    # character case may interleave here; they are grouped case-sensitively
    # below.
    Write-Verbose 'Reading the CharacterActions rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [Charname], [Data] FROM [CharacterActions] ORDER BY [Charname] ASC, [ID] ASC')
    Write-Verbose "Read $($rows.Count) CharacterActions row(s)."

    # Group the expanded payloads by the Charname value, case-sensitively by
    # ordinal comparison (the grouping happens here because SQL Server
    # Compact orders values case-insensitively, and PowerShell hashtables
    # normalize keys case-insensitively as well). Names and payload lists are
    # kept as parallel lists so that the name lookup below can compare
    # ordinally. For a fixed exact name the rows arrive in ascending ID
    # order (the SQL sort is a total order and equal exact names are only
    # separated by their row IDs), so appending each expanded payload to its
    # group as the rows arrive preserves the documented row order within
    # every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupPayloads = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $charname = $row['Charname']
        if (($null -eq $charname) -or ($charname -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$charname)) {
            Write-Warning "Skipping the CharacterActions row (ID '$rowId'): the Charname value is null or empty, so no file name can be derived for it."
            continue
        }
        $charname = [string]$charname

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the CharacterActions row of character '$charname' (ID '$rowId'): the Data value is null or empty."
            continue
        }
        $data = [string]$data

        # Locate or create the case-sensitive group of the character.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $charname, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($charname)
            $groupPayloads.Add([System.Collections.Generic.List[string]]::new())
        }

        Write-Verbose "Expanding the RAGS action of character '$charname' (ID '$rowId')."
        try {
            $actionXml = Expand-RagsActionIntoXml -EncodedRagsAction $data
        }
        catch {
            $message = "Cannot expand the CharacterActions data of the RAGS file: the Data payload of the row for character '$charname' (ID '$rowId') could not be expanded as a RAGS action. "
            $message += "The expansion reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # A YAML literal block scalar normalizes line breaks to line-feed
        # characters when the written YAML is read back, so carriage returns
        # are normalized away beforehand to keep the round-trip byte-exact.
        $groupPayloads[$groupIndex].Add(($actionXml -replace '\r\n?', "`n"))
    }

    # Write one YAML file per character group. Characters whose every row was
    # skipped above carry no payloads and produce no file.
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $payloads = $groupPayloads[$groupIndex].ToArray()
        if ($payloads.Count -eq 0) {
            continue
        }

        $charname = $groupNames[$groupIndex]
        $fileName = (ConvertTo-RagsFilenameGuid -Value $charname) + '.yaml'

        # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
        # the Data mapping entry is emitted indented, and repeated strings
        # are never collapsed into anchors/aliases.
        $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ Charname = $charname; Data = $payloads }) -Options 35

        # ConvertTo-Yaml reports .NET serialization failures by emitting the
        # error record to the output pipeline instead of throwing, so the
        # returned value is validated to guard against mistaking such a
        # failure for YAML content.
        if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
            throw "Cannot expand the CharacterActions data of the RAGS file: the YAML content for character '$charname' could not be serialized."
        }

        $filePath = Join-Path $characterActionsFolder $fileName
        Write-Verbose "Writing '$filePath' ($($payloads.Count) Data row(s) for character '$charname')."
        [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Verbose "Expanded the CharacterActions data into $($groupNames.Count) character group(s)."
    return $true
}

