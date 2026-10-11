#Requires -Version 5.1
Set-StrictMode -Version Latest

function Expand-ItemsFromRagsFile {
    <#
    .SYNOPSIS
    Expands Items data from a RagsFile into a YAML file.

    .DESCRIPTION
    Reads the Items table of a RAGS file (schema version 2.6.1) through an
    open SQL Server Compact connection and expands the data into the single
    'Items.yaml' file in the output folder, following the conventions
    documented in docs/data-mapping.md.

    The written YAML file holds a top-level 'Items' mapping whose value is a
    sequence with one entry per item, each mapping the twenty-five columns
    of the Items table. Item weights are emitted as YAML numbers, item
    locations are emitted as YAML integers and the flag columns are emitted
    as YAML booleans where a missing value is read as false (the documented
    flag mapping). The Description column is emitted as a multi-line literal
    block scalar whose line breaks were normalized to line-feed characters
    (YAML normalizes line breaks to line feeds when a literal block is read
    back, so carriage returns are normalized beforehand to keep the
    round-trip byte-exact). Every other null column value is emitted as a
    YAML null.

    Rows are expected to hold distinct UniqueID values: the table is sorted
    by UniqueID before it is read, so for every item after the first whose
    UniqueID compares equal (ignoring character case, mirroring the
    case-insensitive database collation) to a previously read item the
    second and later rows are skipped with a warning naming the column
    values of the ignored duplicate row — the column values of the first
    read row win. As documented, UniqueID values are always coerced to
    lowercase, so the emitted entries are keyed by the lowercased UniqueID
    values. Rows with a null, empty or whitespace-only UniqueID value are
    also skipped with a warning, as no item entry key can be derived from
    them.

    The output folder is silently created when it is missing and the
    written file silently overwrites any existing one. An empty table
    expands to a top-level empty 'Items' sequence.

    .PARAMETER OutputPath
    Path of the folder to export the expanded Items data into.

    .PARAMETER RagsConnection
    An open SQL Server Compact connection to the RAGS file,
    as returned by Open-RagsFileConnection.

    .OUTPUTS
    System.Boolean. Returns $true when the Items data has been expanded
    successfully.

    .EXAMPLE
    Expand-ItemsFromRagsFile -OutputPath 'C:\Export\MyGame' -RagsConnection $openRagsConnection

    Expands the Items data of the RAGS file connected through
    $openRagsConnection into the 'C:\Export\MyGame\Items.yaml' file.
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
        throw "Cannot expand the Items data of the RAGS file: the given SQL Server Compact connection is not open (state '$($RagsConnection.State)'). Open a connection with Open-RagsFileConnection first."
    }

    # Silently create the output folder when it is missing (this also
    # creates any missing parent folders, and always happens because the
    # expanded file is written even for an empty table).
    $null = New-Item -ItemType Directory -Force -Path $OutputPath
    Write-Verbose "Expanding the Items data into '$OutputPath'."

    # Read all rows of the table, ordered by UniqueID, as documented. The
    # UniqueID column of the database is collated case-insensitively, so
    # rows of items whose UniqueID values differ only in character case
    # sort next to each other here; duplicates among them are dropped
    # case-insensitively below, in the read order of the rows.
    Write-Verbose 'Reading the Items rows of the RAGS file.'
    $rows = @(Get-RagsSchemaRowSet -RagsConnection $RagsConnection -Sql 'SELECT [UniqueID], [Name], [Description], [SDesc], [Preposition], [LocationName], [LocationType], [Carryable], [Wearable], [Openable], [Lockable], [Enterable], [Readable], [Container], [Weight], [Worn], [Read], [Locked], [Open], [Entered], [Visible], [EnterFirstTime], [LeaveFirstTime], [GroupName], [Important] FROM [Items] ORDER BY [UniqueID] ASC')
    Write-Verbose "Read $($rows.Count) Items row(s)."

    # The Items table has no identity column which could label the rows of
    # a duplicate or null-UniqueID warning, so such warnings refer to the
    # position of the row in the read result instead.
    $readRowNumber = 0

    # The UniqueID values of the items whose entries were built, kept in a
    # separate list so that the duplicate check below can compare
    # case-insensitively (the Unique semantics follow the case-insensitive
    # database collation, as documented).
    $admittedUniqueIds = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $readRowNumber++

        $uniqueId = $row['UniqueID']
        if (($null -eq $uniqueId) -or ($uniqueId -is [System.DBNull]) -or [string]::IsNullOrWhiteSpace([string]$uniqueId)) {
            Write-Warning "Skipping the Items row $($readRowNumber) of the read result: the UniqueID value is null or empty, so no item entry can be derived for it."
            continue
        }

        # The documented Unique handling of this table always coerces the
        # UniqueID values to lowercase: entries are keyed by the lowercased
        # value, and the duplicate check below therefore compares the
        # normalized values with ordinal comparisons.
        $uniqueId = ([string]$uniqueId).ToLowerInvariant()

        # A null column value is written as a YAML null, except for the
        # bit columns, where a null is written as a YAML false (documented
        # flag mapping). The Description value is normalized to line feeds
        # beforehand, both because a YAML literal block scalar normalizes
        # line breaks that way when read back and so that the duplicate
        # warning below can report the value of the ignored row as it
        # would have been written. Every value is computed before the
        # duplicate check so that the warnings below never read a value of
        # a previous iteration (the stale-variable rule).
        $name = $row['Name']
        if (($null -eq $name) -or ($name -is [System.DBNull])) {
            $name = $null
        }
        else {
            $name = [string]$name
        }

        $description = $row['Description']
        if (($null -eq $description) -or ($description -is [System.DBNull])) {
            $description = $null
        }
        else {
            $description = ([string]$description) -replace '\r\n?', "`n"
        }

        $sdesc = $row['SDesc']
        if (($null -eq $sdesc) -or ($sdesc -is [System.DBNull])) {
            $sdesc = $null
        }
        else {
            $sdesc = [string]$sdesc
        }

        $preposition = $row['Preposition']
        if (($null -eq $preposition) -or ($preposition -is [System.DBNull])) {
            $preposition = $null
        }
        else {
            $preposition = [string]$preposition
        }

        $locationName = $row['LocationName']
        if (($null -eq $locationName) -or ($locationName -is [System.DBNull])) {
            $locationName = $null
        }
        else {
            $locationName = [string]$locationName
        }

        # A nullable integer column is written as a YAML null when the
        # value is missing, and as a YAML integer otherwise.
        $locationType = $row['LocationType']
        if (($null -eq $locationType) -or ($locationType -is [System.DBNull])) {
            $locationType = $null
        }

        # The Weight column is the only float column of the schema; a
        # missing value is written as a YAML null like the other nullable
        # non-bit columns, and a present value is written as a YAML number
        # (the managed reader returns it as a System.Double).
        $weight = $row['Weight']
        if (($null -eq $weight) -or ($weight -is [System.DBNull])) {
            $weight = $null
        }

        # The managed reader returns bit columns as Boolean values; a
        # missing value is read as the documented false.
        $carryable = $row['Carryable']
        if (($null -eq $carryable) -or ($carryable -is [System.DBNull])) {
            $carryable = $false
        }

        $wearable = $row['Wearable']
        if (($null -eq $wearable) -or ($wearable -is [System.DBNull])) {
            $wearable = $false
        }

        $openable = $row['Openable']
        if (($null -eq $openable) -or ($openable -is [System.DBNull])) {
            $openable = $false
        }

        $lockable = $row['Lockable']
        if (($null -eq $lockable) -or ($lockable -is [System.DBNull])) {
            $lockable = $false
        }

        $enterable = $row['Enterable']
        if (($null -eq $enterable) -or ($enterable -is [System.DBNull])) {
            $enterable = $false
        }

        $readable = $row['Readable']
        if (($null -eq $readable) -or ($readable -is [System.DBNull])) {
            $readable = $false
        }

        $container = $row['Container']
        if (($null -eq $container) -or ($container -is [System.DBNull])) {
            $container = $false
        }

        $worn = $row['Worn']
        if (($null -eq $worn) -or ($worn -is [System.DBNull])) {
            $worn = $false
        }

        $readFlag = $row['Read']
        if (($null -eq $readFlag) -or ($readFlag -is [System.DBNull])) {
            $readFlag = $false
        }

        $locked = $row['Locked']
        if (($null -eq $locked) -or ($locked -is [System.DBNull])) {
            $locked = $false
        }

        $openFlag = $row['Open']
        if (($null -eq $openFlag) -or ($openFlag -is [System.DBNull])) {
            $openFlag = $false
        }

        $entered = $row['Entered']
        if (($null -eq $entered) -or ($entered -is [System.DBNull])) {
            $entered = $false
        }

        $visible = $row['Visible']
        if (($null -eq $visible) -or ($visible -is [System.DBNull])) {
            $visible = $false
        }

        $enterFirstTime = $row['EnterFirstTime']
        if (($null -eq $enterFirstTime) -or ($enterFirstTime -is [System.DBNull])) {
            $enterFirstTime = $false
        }

        $leaveFirstTime = $row['LeaveFirstTime']
        if (($null -eq $leaveFirstTime) -or ($leaveFirstTime -is [System.DBNull])) {
            $leaveFirstTime = $false
        }

        $groupName = $row['GroupName']
        if (($null -eq $groupName) -or ($groupName -is [System.DBNull])) {
            $groupName = $null
        }
        else {
            $groupName = [string]$groupName
        }

        # The Important column is not nullable, so the reader always
        # returns a Boolean value for it.
        $important = [bool]$row['Important']

        # Soft-validate the Unique UniqueID column: a row whose value
        # compares equal to a previously read row's value, ignoring
        # character case (the values are already normalized to lowercase
        # above), is skipped with a warning naming the column values of
        # the ignored duplicate row (the column values of the first read
        # row win).
        $duplicate = $false
        foreach ($existingUniqueId in $admittedUniqueIds) {
            if ([string]::Equals($existingUniqueId, $uniqueId, [System.StringComparison]::Ordinal)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) {
            $evidenceParts = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $name) { $evidenceParts.Add('Name <null>') } else { $evidenceParts.Add('Name ''' + $name + '''') }
            if ($null -eq $description) { $evidenceParts.Add('Description <null>') } else { $evidenceParts.Add('Description ' + $description) }
            if ($null -eq $sdesc) { $evidenceParts.Add('SDesc <null>') } else { $evidenceParts.Add('SDesc ''' + $sdesc + '''') }
            if ($null -eq $preposition) { $evidenceParts.Add('Preposition <null>') } else { $evidenceParts.Add('Preposition ''' + $preposition + '''') }
            if ($null -eq $locationName) { $evidenceParts.Add('LocationName <null>') } else { $evidenceParts.Add('LocationName ''' + $locationName + '''') }
            if ($null -eq $locationType) { $evidenceParts.Add('LocationType <null>') } else { $evidenceParts.Add('LocationType ' + $locationType) }
            $evidenceParts.Add('Carryable equals ' + $carryable + ' after reading')
            $evidenceParts.Add('Wearable equals ' + $wearable + ' after reading')
            $evidenceParts.Add('Openable equals ' + $openable + ' after reading')
            $evidenceParts.Add('Lockable equals ' + $lockable + ' after reading')
            $evidenceParts.Add('Enterable equals ' + $enterable + ' after reading')
            $evidenceParts.Add('Readable equals ' + $readable + ' after reading')
            $evidenceParts.Add('Container equals ' + $container + ' after reading')
            if ($null -eq $weight) { $evidenceParts.Add('Weight <null>') } else { $evidenceParts.Add('Weight ' + $weight) }
            $evidenceParts.Add('Worn equals ' + $worn + ' after reading')
            $evidenceParts.Add('Read equals ' + $readFlag + ' after reading')
            $evidenceParts.Add('Locked equals ' + $locked + ' after reading')
            $evidenceParts.Add('Open equals ' + $openFlag + ' after reading')
            $evidenceParts.Add('Entered equals ' + $entered + ' after reading')
            $evidenceParts.Add('Visible equals ' + $visible + ' after reading')
            $evidenceParts.Add('EnterFirstTime equals ' + $enterFirstTime + ' after reading')
            $evidenceParts.Add('LeaveFirstTime equals ' + $leaveFirstTime + ' after reading')
            if ($null -eq $groupName) { $evidenceParts.Add('GroupName <null>') } else { $evidenceParts.Add('GroupName ''' + $groupName + '''') }
            $evidenceParts.Add('Important equals ' + $important + ' after reading')

            Write-Warning "Skipping the Items row $($readRowNumber) of the read result: the UniqueID value '$uniqueId' duplicates the UniqueID value of a previously read row (whose column values win). The ignored duplicate row has the column values $($evidenceParts -join ', ')."
            continue
        }

        $admittedUniqueIds.Add($uniqueId)

        # The entry mapping is kept as an ordered hashtable (which
        # serializes its keys in the given order, the column order of the
        # documented sample structure).
        $entries.Add([ordered]@{
            UniqueID        = $uniqueId
            Name            = $name
            Description     = $description
            SDesc           = $sdesc
            Preposition     = $preposition
            LocationName    = $locationName
            LocationType    = $locationType
            Carryable       = $carryable
            Wearable        = $wearable
            Openable        = $openable
            Lockable        = $lockable
            Enterable       = $enterable
            Readable        = $readable
            Container       = $container
            Weight          = $weight
            Worn            = $worn
            Read            = $readFlag
            Locked          = $locked
            Open            = $openFlag
            Entered         = $entered
            Visible         = $visible
            EnterFirstTime  = $enterFirstTime
            LeaveFirstTime  = $leaveFirstTime
            GroupName       = $groupName
            Important       = $important
        })
    }

    # Roundtrip + DisableAliases + WithIndentedSequences: the sequence of
    # item entries is emitted indented, and repeated strings are never
    # collapsed into anchors/aliases. The sequence is wrapped in a
    # top-level 'Items' mapping key, as documented.
    $fileYaml = ConvertTo-Yaml -Data ([ordered]@{ Items = $entries }) -Options 35

    # ConvertTo-Yaml reports .NET serialization failures by emitting the
    # error record to the output pipeline instead of throwing, so the
    # returned value is validated to guard against mistaking such a
    # failure for YAML content.
    if (($fileYaml -isnot [string]) -or [string]::IsNullOrEmpty($fileYaml)) {
        throw 'Cannot expand the Items data of the RAGS file: the YAML content of the Items data could not be serialized.'
    }

    $filePath = Join-Path $OutputPath 'Items.yaml'
    Write-Verbose "Writing '$filePath' ($($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) for $($rows.Count) Items row(s))."
    [System.IO.File]::WriteAllText($filePath, $fileYaml, [System.Text.UTF8Encoding]::new($false))

    Write-Verbose "Expanded the Items data into $($entries.Count) entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' })."
    return $true
}

