#Requires -Version 5.1
Set-StrictMode -Version Latest

function Open-RagsFileConnection {
    <#
    .SYNOPSIS
    Opens a SQL Server Compact connection to a RAGS file.

    .DESCRIPTION
    Opens a SQL Server Compact connection to the SQL Server Compact 3.5
    database backing a RAGS file, through the managed provider
    System.Data.SqlServerCe. The vendored dependency under
    'deps\sql-server-compact' is loaded lazily, immediately before the
    connection is constructed. The file path is passed to the provider
    through the 'Data Source' connection string parameter, and the plaintext
    password through the 'Password' connection string parameter, built
    through a DbConnectionStringBuilder so that reserved characters in both
    values are quoted correctly.

    After the connection is opened, the database structure of the file is
    validated against the expected RAGS file schema (version 2.6.1) by the
    Assert-RagsFileStructure function. When the structure does not conform to
    the expected schema, the connection is closed and disposed and an
    exception is thrown. The connection is only returned to the caller after
    successful validation; the caller is responsible for closing and
    disposing it.

    .PARAMETER Path
    Path to the RAGS file to open. The path must point to an existing file; a
    path that points to a directory is rejected. A warning is emitted when the
    file does not have a '.rag' extension.

    .OUTPUTS
    System.Data.SqlServerCe.SqlCeConnection. The opened SQL Server Compact
    connection.

    .EXAMPLE
    $connection = Open-RagsFileConnection -Path 'C:\Games\MyGame.rag'

    Opens a connection to the RAGS file.
    #>
    [CmdletBinding()]
    [OutputType('System.Data.SqlServerCe.SqlCeConnection')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Plaintext password of the RAGS file database, required by the SQL Server
    # Compact connection string.
    $Password = 'Ç°¥àòÅÅÇÉàññø'

    # Validate that the path points to an existing file on the file system.
    $ragsFile = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $ragsFile) {
        throw "Cannot open a RAGS file: no file exists at the path '$Path'."
    }
    if ($ragsFile.PSProvider.Name -ne 'FileSystem') {
        throw "Cannot open a RAGS file: the path '$Path' does not point to a location on the file system."
    }
    if ($ragsFile.PSIsContainer) {
        throw "Cannot open a RAGS file: the path '$Path' points to a directory ('$($ragsFile.FullName)'), not to a file."
    }

    # RAGS files are expected to use the '.rag' extension.
    if ($ragsFile.Extension -ne '.rag') {
        Write-Warning "The file '$($ragsFile.FullName)' does not have a '.rag' extension and may not be a RAGS game file."
    }

    # Load the vendored SQL Server Compact 3.5 dependency (managed assembly
    # plus native DLLs) before the connection is constructed.
    #
    # The dependency is vendored with the module under
    # 'deps\sql-server-compact', in separate x86 and x64 builds; the build
    # matching the bitness of the current process is selected. Loading is
    # idempotent: when the System.Data.SqlServerCe assembly is already
    # loaded in the process (by a previous call or by the host application),
    # the loading steps are skipped.
    if ($null -eq ('System.Data.SqlServerCe.SqlCeConnection' -as [type])) {
        # Locate the module root from this file's location (private\utils).
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        # The dependency is vendored per architecture; select the build which
        # matches the bitness of the current process. A 64-bit process cannot
        # load the 32-bit native DLLs and vice versa (BadImageFormat errors).
        $architectureFolderName = if ([System.Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
        $dependencyRoot = Join-Path $moduleRoot 'deps\sql-server-compact'
        $architectureDirectory = Join-Path $dependencyRoot $architectureFolderName
        $managedAssemblyPath = Join-Path $architectureDirectory 'System.Data.SqlServerCe.dll'

        if (-not (Test-Path -LiteralPath $managedAssemblyPath -PathType Leaf)) {
            throw "Cannot load the vendored SQL Server Compact 3.5 dependency: the managed assembly is missing. Expected it at '$managedAssemblyPath'. Verify that the 'deps\sql-server-compact' folder (with the '$architectureFolderName' build for this process bitness) ships together with the module code."
        }

        # Make the native SQL Server Compact DLLs (sqlceme35.dll, sqlcese35.dll,
        # sqlceqp35.dll, and the rest) resolvable for the Windows loader: the
        # managed assembly locates its native counterparts through the standard
        # DLL search path, so prepending the architecture folder to the process
        # PATH is sufficient. Prepending is skipped when the folder is already
        # on the PATH; the comparison is case-insensitive.
        $pathEntries = @($env:PATH -split ';' | Where-Object { $_ -ne '' })
        if ($pathEntries -notcontains $architectureDirectory) {
            $env:PATH = "$architectureDirectory;$env:PATH"
            Write-Verbose "Prepended '$architectureDirectory' to the process PATH so that the native SQL Server Compact 3.5 DLLs can be resolved."
        }

        try {
            Write-Verbose "Loading the SQL Server Compact 3.5 managed assembly from '$managedAssemblyPath'."
            Add-Type -Path $managedAssemblyPath -ErrorAction Stop
        }
        catch {
            $message = "Failed to load the vendored SQL Server Compact 3.5 managed assembly '$managedAssemblyPath': '$($_.Exception.Message)'. "
            $message += 'Verify that the native SQL Server Compact 3.5 DLLs (sqlceme35.dll and its dependencies, including the Visual C++ 8.0 runtime DLLs) '
            $message += "are present next to the managed assembly in '$architectureDirectory' and that they match the bitness of the current process "
            $message += "($architectureFolderName)."
            throw [System.Exception]::new($message, $_.Exception)
        }

        # Confirm that the assembly load actually made the managed provider
        # usable.
        if ($null -eq ('System.Data.SqlServerCe.SqlCeConnection' -as [type])) {
            throw "The SQL Server Compact 3.5 managed assembly '$managedAssemblyPath' was loaded, but the type 'System.Data.SqlServerCe.SqlCeConnection' could not be resolved afterwards."
        }

        Write-Verbose 'The SQL Server Compact 3.5 managed dependency is available.'
    }
    else {
        Write-Verbose 'The SQL Server Compact 3.5 managed assembly is already loaded.'
    }

    # Build the SQL Server Compact connection string. The
    # DbConnectionStringBuilder quotes values which contain reserved
    # characters (such as the database password) automatically, so that paths
    # and passwords with special characters cannot break the string.
    $connectionStringBuilder = New-Object System.Data.Common.DbConnectionStringBuilder
    $connectionStringBuilder['Data Source'] = $ragsFile.FullName
    $connectionStringBuilder['Password'] = $Password
    $connectionString = $connectionStringBuilder.ConnectionString

    # Open the connection, wrapping any failure in an informative exception.
    $connection = $null
    try {
        $connection = New-Object -TypeName System.Data.SqlServerCe.SqlCeConnection -ArgumentList $connectionString
        Write-Verbose "Opening a SQL Server Compact connection to '$($ragsFile.FullName)'."
        $connection.Open()
    }
    catch {
        if ($null -ne $connection) {
            $connection.Dispose()
        }

        $message = "Failed to open a connection to the RAGS file '$($ragsFile.FullName)'. "
        $message += 'The SQL Server Compact 3.5 managed provider reported the following error: '
        $message += "'$($_.Exception.Message)'. "
        $message += 'Verify that the file is a RAGS game file (a SQL Server Compact 3.5 database), '
        $message += 'that the database password is correct, and that the vendored SQL Server Compact 3.5 '
        $message += "dependency under 'deps\sql-server-compact' is intact and matches the bitness of the current process."

        throw [System.Exception]::new($message, $_.Exception)
    }

    # Validate the database structure of the opened connection so that a
    # connection is only returned when the database conforms to the expected
    # RAGS file schema. The success output of the assertion is discarded.
    try {
        Write-Verbose "Validating the database structure of '$($ragsFile.FullName)' against the expected RAGS file schema."
        $null = Assert-RagsFileStructure -RagsConnection $connection
    }
    catch {
        $connection.Dispose()

        $message = "The connection to the RAGS file '$($ragsFile.FullName)' was opened, but the database "
        $message += 'structure of the file does not conform to the expected RAGS file schema (version 2.6.1): '
        $message += "'$($_.Exception.Message)'"

        throw [System.Exception]::new($message, $_.Exception)
    }

    return $connection
}
