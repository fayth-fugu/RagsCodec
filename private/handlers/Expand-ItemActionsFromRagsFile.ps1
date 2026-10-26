#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-ItemActionsFromRagsFile {
    <#
    .SYNOPSIS
    Expands ItemActions data from a RagsFile into YAML files.

    .DESCRIPTION
    Reads the ItemActions table of a RAGS file (schema version 2.6.1)
    through an open SQL Server Compact connection and expands the data into
    one YAML file per distinct ItemID value (always coerced to lowercase,
    as the ItemActions List column documents), written into the
    'ItemActions' subfolder of the output folder, following the
    conventions documented in docs/data-mapping.md.

    Each file is named after the ItemID value it represents, coerced to
    lowercase as the ItemActions List column documents, followed by a
    lowercase '.yaml' extension; the file contains a mapping with the
    lowercased ItemID value and the Data sequence holding one entry per
    Data row of the item. Each entry is expanded from the encoded RAGS
    action of the row (Base64-decoded, GZip-decompressed and
    pretty-printed XML) through Expand-RagsActionIntoXml. Unlike the
    CharacterActions, Media and TimerActions tables, the file name is not
    derived from a GUID of the list value; the documented List-column
    value is used directly.

    Rows with a null, empty or whitespace-only ItemID or Data value are
    skipped with a warning, as no meaningful expansion target or content
    can be derived from them. A row whose ItemID value cannot be used to
    form a valid file name (because it contains characters that are invalid
    in file names, ends with a dot or a space, or names a reserved device
    such as CON, NUL or COM1) is skipped with a warning as well, since no
    meaningful expansion target can be derived from it either.

    The List-column values of the ItemActions table are documented as
    case-insensitive and always coerced to lowercase ('Values are
    case-insensitive' / 'Always coerced to lowercase' in the ItemActions
    section of docs/data-mapping.md), so every read ItemID value is
    lowercased with ToLowerInvariant right after it is read. The file
    names and the ItemID key of every written file always carry the
    lowercased form of the value, and the skip warnings, the merge warning
    and the corrupt-payload throw all cite that lowercased form as well.
    Rows whose raw ItemID values differ only in character case therefore
    share one file (the case mate whose raw casing is read first opens
    the file, the first read row of the unsorted read result). Every
    merged row whose raw ItemID value differs from the first-read raw
    value of its case mate set is reported with a warning; its payload is
    appended to the same Data sequence. The first-read row of such a set
    and rows repeating its raw value merge without a warning.

    A row whose non-empty Data value cannot be expanded aborts the whole
    operation with an exception before any YAML file is written (all
    payloads are expanded before any file is created).

    The subfolder and its parent folders are created silently when missing,
    and written files silently overwrite existing ones. Rows of one item
    appear in the Data sequence in read order.

    .PARAMETER OutputPath
    Path of the folder to export the expanded ItemActions data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the ItemActions data has been
    expanded successfully.

    .EXAMPLE
    Expand-ItemActionsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the ItemActions data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\ItemActions' folder.
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
        throw "Cannot expand the ItemActions data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the 'ItemActions' subfolder when it is missing
    # (this also creates the output folder itself and any missing parents).
    $itemActionsFolder = Join-Path $OutputPath 'ItemActions'
    $null = New-Item -ItemType Directory -Force -Path $itemActionsFolder
    Write-Verbose "Expanding the ItemActions data into '$itemActionsFolder'."

    # Read all rows of the table in the order the database returns them
    # (no ORDER BY; the table has no documented sort). The ItemID column
    # of the database is collated case-insensitively, so rows of items
    # whose names differ only in character case may return in any relative
    # order. Contrary to character names, item names are used as file
    # names directly, so such rows must NOT be grouped case-sensitively:
    # case mates would produce the same Windows file name and silently
    # overwrite each other. They are grouped by the lowercased value below
    # (the List-column values of the ItemActions table are documented as
    # case-insensitive and always coerced to lowercase in
    # docs/data-mapping.md), keeping every row in read order and the
    # first-read value's lowercase form as the file name and ItemID key.
    Write-Verbose 'Reading the ItemActions rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [ID], [ItemID], [Data] FROM [ItemActions]')
    Write-Verbose "Read $($rows.Count) ItemActions row(s)."

    # Characters that are invalid in file names on the current file system.
    # The array includes control characters (tab and line-break characters
    # included) on both supported hosts.
    $invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()

    # Group the payloads by the lowercased ItemID value. The List-column
    # handling of the ItemActions table pins the values as case-insensitive
    # and always coerced to lowercase (docs/data-mapping.md), so every
    # value is lowercased as soon as it is read and the groups are keyed
    # by that canonical form: two raw values that differ only in character
    # case share one group and therefore one file, which also keeps
    # Windows file-name collisions impossible. Group names (canonical),
    # first-read raw names and payload lists are kept as parallel lists:
    # the canonical names name the written file and its ItemID key, the
    # raw names drive the merge warning (a row whose raw value differs
    # from the first-read raw value of its group is reported), and the
    # payload lists receive the expanded payloads. Appending each
    # expanded payload to its group as the rows arrive preserves the read
    # order within every group.
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $groupRawNames = [System.Collections.Generic.List[string]]::new()
    $groupPayloads = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $rowId = $row['ID']

        $itemId = $row['ItemID']
        if (($null -eq $itemId) -or ($itemId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$itemId)) {
            Write-Warning "Skipping the ItemActions row (ID '$rowId'): the ItemID value is null or empty, so no file name can be derived for it."
            continue
        }
        $rawItemId = [string]$itemId

        # The List-column values of the ItemActions table are documented as
        # case-insensitive and always coerced to lowercase, so the raw
        # value is lowered with ToLowerInvariant (the invariant result is
        # independent of the current culture) as soon as it is read.
        # Everything below - the file-name checks, the remaining skip
        # warnings and the merge reporting - works with and cites this
        # lowercased form; the raw value is kept only for the merge
        # reporting of the grouping.
        $itemId = $rawItemId.ToLowerInvariant()

        # The lowercased ItemID value becomes the file name, so a value
        # that cannot form a valid file name is skipped with a warning. A
        # value either contains a character that is invalid in file names,
        # ends with a dot or a space, or names one of the reserved devices
        # (which also holds when a single extension is appended by the
        # '.yaml' suffix of the file); all three forms are rejected here.
        # All three checks are case-agnostic, so running them on the
        # lowercased value changes no outcome.
        $fileNameProblem = $null
        if (-1 -lt $itemId.IndexOfAny($invalidFileNameChars)) {
            $fileNameProblem = 'it contains a character that is invalid in file names'
        }
        elseif (($itemId.EndsWith('.')) -or ($itemId.EndsWith(' '))) {
            $fileNameProblem = 'it ends with a dot or a space, which is not allowed in file names'
        }
        elseif ($itemId -match '^((CON|PRN|AUX|NUL)|COM[1-9]|LPT[1-9])(\..+)?$') {
            $fileNameProblem = 'it names a reserved device, which cannot be used as a file name'
        }
        if ($null -ne $fileNameProblem) {
            Write-Warning "Skipping the ItemActions row of item '$itemId' (ID '$rowId'): the ItemID value cannot form a valid file name because $fileNameProblem."
            continue
        }

        $data = $row['Data']
        if (($null -eq $data) -or ($data -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$data)) {
            Write-Warning "Skipping the ItemActions row of item '$itemId' (ID '$rowId'): the Data value is null or empty."
            continue
        }
        $data = [string]$data

        # Locate or create the group of the item. The lookup and the
        # canonical group names compare ordinal against the lowercased
        # value, so case mates resolve to one group. The first-read raw
        # value is kept per group, and a row whose raw value differs from
        # it is merged with a warning which cites the lowercased value on
        # both sides; the first-read row of a case mate set and rows
        # repeating its raw value merge without a warning. In both cases
        # the payload is written into the same file under the lowercased
        # name.
        $groupIndex = -1
        for ($candidateIndex = 0; $candidateIndex -lt $groupNames.Count; $candidateIndex++) {
            if ([string]::Equals($groupNames[$candidateIndex], $itemId, [System.StringComparison]::Ordinal)) {
                $groupIndex = $candidateIndex
                break
            }
        }
        if ($groupIndex -lt 0) {
            $groupIndex = $groupNames.Count
            $groupNames.Add($itemId)
            $groupRawNames.Add($rawItemId)
            $groupPayloads.Add([System.Collections.Generic.List[string]]::new())
        }
        elseif (-not [string]::Equals($groupRawNames[$groupIndex], $rawItemId, [System.StringComparison]::Ordinal)) {
            Write-Warning "Merging the ItemActions row of item '$itemId' (ID '$rowId') into the file of item '$($groupNames[$groupIndex])': the raw ItemID value differs only in character case and is merged into the lowercased file name."
        }

        Write-Verbose "Expanding the RAGS action of item '$itemId' (ID '$rowId')."
        try {
            $actionXml = Expand-RagsActionIntoXml -EncodedRagsAction $data
        }
        catch {
            $message = "Cannot expand the ItemActions data of the RAGS file: the Data payload of the row for item '$itemId' (ID '$rowId') could not be expanded as a RAGS action. "
            $message += "The expansion reported the following error: '$($_.Exception.Message)'."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # The expanded action XML is staged verbatim, exactly as
        # Expand-RagsActionIntoXml produced it; a written value's line
        # breaks are normalized to line feeds only when the written YAML
        # is read back (the literal block scalar's reading rule).
        $stagedActionXml = [string]$actionXml
        $groupPayloads[$groupIndex].Add($stagedActionXml)
    }

    # Write one YAML file per item group. Items whose every row was skipped
    # above carry no payloads and produce no file.
    for ($groupIndex = 0; $groupIndex -lt $groupNames.Count; $groupIndex++) {
        $payloads = $groupPayloads[$groupIndex].ToArray()
        if ($payloads.Count -eq 0) {
            continue
        }

        $itemId = $groupNames[$groupIndex]
        $fileName = $itemId + '.yaml'

        # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
        # the Data mapping entry is emitted indented, and repeated strings
        # are never collapsed into anchors/aliases.
        $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ ItemID = $itemId; Data = $payloads }) -Options 35

        # ConvertTo-Yaml reports .NET serialization failures by emitting the
        # error record to the output pipeline instead of throwing, so the
        # returned value is validated to guard against mistaking such a
        # failure for YAML content.
        if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
            throw "Cannot expand the ItemActions data of the RAGS file: the YAML content for item '$itemId' could not be serialized."
        }

        $filePath = Join-Path $itemActionsFolder $fileName
        Write-Verbose "Writing '$filePath' ($($payloads.Count) Data row(s) for item '$itemId')."
        [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))
    }

    Write-Verbose "Expanded the ItemActions data into $($groupNames.Count) item group(s)."
    return $true
}

