#Requires -Version 5.1
Set-StrictMode -Version Latest

function Open-RagsFileConnection {
    <#
    .SYNOPSIS
    Opens an OLE DB connection to a RAGS file.

    .DESCRIPTION
    Opens an OLE DB connection to the SQL Server Compact 3.5 database backing a
    RAGS file, using the 'Microsoft.SQLSERVER.CE.OLEDB.3.5' provider. The file
    path is passed to the provider through the 'Data Source' connection string
    parameter and the plaintext password through the 'SSCE:Database Password'
    connection string parameter.

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
    System.Data.OleDb.OleDbConnection. The opened OLE DB connection.

    .EXAMPLE
    $connection = Open-RagsFileConnection -Path 'C:\Games\MyGame.rag'

    Opens a connection to the RAGS file.
    #>
    [CmdletBinding()]
    [OutputType('System.Data.OleDb.OleDbConnection')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Plaintext password of the RAGS file database, required by the OLE DB
    # connection string.
    $Password = 'Ç°¥àòÅÅÇÉàññø'

    # Formats a connection string value, quoting it when it contains characters
    # that would otherwise terminate or corrupt the token (';' or quotes).
    # Embedded quotes are doubled, per OLE DB connection string rules.
    function Format-OleDbConnectionStringValue {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value) -or ($Value -match '[;''"]')) {
            return "'$($Value.Replace("'", "''"))'"
        }

        return $Value
    }

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

    # Build the OLE DB connection string. Values are formatted so that paths
    # and passwords containing reserved characters cannot break the string.
    $provider = 'Microsoft.SQLSERVER.CE.OLEDB.3.5'
    $dataSource = Format-OleDbConnectionStringValue -Value $ragsFile.FullName
    $databasePassword = Format-OleDbConnectionStringValue -Value $Password
    $connectionString = "Provider=$provider;Data Source=$dataSource;SSCE:Database Password=$databasePassword"

    # Open the connection, wrapping any failure in an informative exception.
    $connection = $null
    try {
        $connection = New-Object -TypeName System.Data.OleDb.OleDbConnection -ArgumentList $connectionString
        Write-Verbose "Opening an OLE DB connection to '$($ragsFile.FullName)' with the provider '$provider'."
        $connection.Open()
    }
    catch {
        if ($null -ne $connection) {
            $connection.Dispose()
        }

        $message = "Failed to open a connection to the RAGS file '$($ragsFile.FullName)'. "
        $message += "The OLE DB provider '$provider' reported the following error: '$($_.Exception.Message)'. "
        $message += 'Verify that the file is a RAGS game file (a SQL Server Compact 3.5 database), '
        $message += 'that the database password is correct, and that the SQL Server Compact 3.5 '
        $message += 'OLE DB provider is installed on this machine.'

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
