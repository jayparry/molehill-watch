#Requires -Version 5.1
<#
.SYNOPSIS
    Exports a random sample of rows from every user table in a database to CSV, then zips the output.

.DESCRIPTION
    Molehill Data Services | Export-DatabaseSample

    For each user table, runs SELECT TOP (n) ... ORDER BY NEWID() and writes the result to
    <OutputPath>\<Database>\<schema>.<table>.csv. Every file has a header row, including files
    for empty tables. When all tables are processed, the <Database> folder is zipped to
    <OutputPath>\<Database>.zip.

    Supported targets:
      - SQL Server on-premises or on an IaaS (Infrastructure as a Service) virtual machine
      - Azure SQL Managed Instance
      - Azure SQL Database
    The script connects straight to the target database, so no USE statement is needed
    (Azure SQL Database does not support one).

    No modules are required. ADO.NET (System.Data.SqlClient) is used directly, which ships with
    both Windows PowerShell 5.1 and PowerShell 7. Az.Accounts is only needed for -UseEntraId.

    Column handling:
      - CLR (Common Language Runtime) types such as geography, geometry and hierarchyid are
        converted server side with .ToString(), so no client assemblies are needed
      - Binary and rowversion columns are written as 0x hex strings
      - Dates use ISO 8601 style formatting; numbers use invariant culture
      - Files are UTF-8 with a BOM (byte order mark) and CRLF line endings, so Excel opens them cleanly
      - Values are quoted per RFC 4180 only where needed (commas, quotes, line breaks)

    External tables and SSMS (SQL Server Management Studio) diagram support tables are skipped.
    If the explicit column list fails for a table (graph tables, for example), the script retries
    that table once with SELECT *.

.PARAMETER SqlInstance
    Server or instance name. Examples: SQLPROD01, SQLPROD01\INST2, myserver.database.windows.net,
    mymi.public.abc123.database.windows.net,3342

.PARAMETER Database
    Database to sample. Also used as the output folder and zip file name.

.PARAMETER Top
    Rows to sample per table. Default 200. Alias: -n

.PARAMETER OutputPath
    Existing folder that will receive the <Database> folder and <Database>.zip. Default: current location.

.PARAMETER SqlCredential
    SQL authentication login. Omit all authentication parameters to use Windows authentication.

.PARAMETER UseEntraId
    Use Microsoft Entra ID authentication with a token from Get-AzAccessToken.
    Run Connect-AzAccount first.

.PARAMETER AccessToken
    Supply your own Entra ID access token for https://database.windows.net/

.PARAMETER TrustServerCertificate
    Skip server certificate validation. Usually needed for on-premises servers using a self-signed
    certificate, because the connection always requests encryption.

.PARAMETER ReadUncommitted
    Sample under READ UNCOMMITTED to avoid taking shared locks on busy production tables.

.PARAMETER CommandTimeout
    Per-table query timeout in seconds. Default 600. 0 means no timeout.

.PARAMETER RemoveFolderAfterZip
    Delete the <Database> folder once the zip has been created.

.PARAMETER Force
    Replace an existing <Database> folder and <Database>.zip in OutputPath.

.EXAMPLE
    .\Export-DatabaseSample.ps1 -SqlInstance SQLPROD01 -Database Sales -TrustServerCertificate

.EXAMPLE
    .\Export-DatabaseSample.ps1 -SqlInstance myserver.database.windows.net -Database Sales -SqlCredential (Get-Credential) -Top 500

.EXAMPLE
    Connect-AzAccount
    .\Export-DatabaseSample.ps1 -SqlInstance mymi.public.abc123.database.windows.net,3342 -Database Sales -UseEntraId -OutputPath D:\Samples -Force
#>
[CmdletBinding(DefaultParameterSetName = 'Windows')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlInstance,

    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$Database,

    [Alias('n')]
    [ValidateRange(1, 2147483647)]
    [int]$Top = 200,

    [string]$OutputPath = (Get-Location).ProviderPath,

    [Parameter(Mandatory, ParameterSetName = 'SqlAuth')]
    [System.Management.Automation.PSCredential]$SqlCredential,

    [Parameter(Mandatory, ParameterSetName = 'Entra')]
    [switch]$UseEntraId,

    [Parameter(Mandatory, ParameterSetName = 'Token')]
    [ValidateNotNullOrEmpty()]
    [string]$AccessToken,

    [switch]$TrustServerCertificate,

    [switch]$ReadUncommitted,

    [ValidateRange(0, 86400)]
    [int]$CommandTimeout = 600,

    [switch]$RemoveFolderAfterZip,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

$Invariant        = [System.Globalization.CultureInfo]::InvariantCulture
$CsvSpecialChars  = [char[]]@(',', '"', "`r", "`n")
$InvalidFileChars = [System.IO.Path]::GetInvalidFileNameChars()

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Colour = [ConsoleColor]::Gray
    )
    Write-Host ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message) -ForegroundColor $Colour
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($c in $InvalidFileChars) { $Name = $Name.Replace($c, '_') }
    return $Name
}

function Format-CsvField {
    param([object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return '' }

    if     ($Value -is [byte[]])           { $text = '0x' + [System.BitConverter]::ToString($Value).Replace('-', '') }
    elseif ($Value -is [datetime])         { $text = $Value.ToString('yyyy-MM-dd HH:mm:ss.fffffff', $Invariant) }
    elseif ($Value -is [datetimeoffset])   { $text = $Value.ToString('yyyy-MM-dd HH:mm:ss.fffffff zzz', $Invariant) }
    elseif ($Value -is [timespan])         { $text = $Value.ToString('c', $Invariant) }
    elseif ($Value -is [bool])             { $text = if ($Value) { '1' } else { '0' } }
    elseif ($Value -is [double] -or $Value -is [single]) { $text = $Value.ToString('R', $Invariant) }
    elseif ($Value -is [System.IFormattable]) { $text = $Value.ToString($null, $Invariant) }
    else                                   { $text = [string]$Value }

    if ($text.IndexOfAny($CsvSpecialChars) -ge 0) {
        return '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function Get-EntraSqlToken {
    if (-not (Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        throw 'Az.Accounts is required for -UseEntraId. Run: Install-Module Az.Accounts -Scope CurrentUser; Connect-AzAccount'
    }
    $tokenInfo = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    # Az.Accounts 14+ returns a SecureString; older versions return plain text
    if ($tokenInfo.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenInfo.Token).Password
    }
    return [string]$tokenInfo.Token
}

function Invoke-SqlQuery {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Query
    )
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = $CommandTimeout
    $table  = [System.Data.DataTable]::new()
    $reader = $null
    try {
        $reader = $cmd.ExecuteReader()
        $table.Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $cmd.Dispose()
    }
    return , $table
}

function Export-TableSample {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$FilePath
    )

    if ($Connection.State -ne [System.Data.ConnectionState]::Open) {
        $Connection.Close()
        $Connection.Open()
    }

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = $CommandTimeout
    $null = $cmd.Parameters.Add('@Top', [System.Data.SqlDbType]::Int)
    $cmd.Parameters['@Top'].Value = $Top

    $reader = $null
    $writer = $null
    $rows   = 0
    try {
        $reader = $cmd.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)

        $writer = [System.IO.StreamWriter]::new($FilePath, $false, [System.Text.UTF8Encoding]::new($true))
        $writer.NewLine = "`r`n"

        $fieldCount = $reader.FieldCount
        $fields     = [string[]]::new($fieldCount)

        # Header row, written even when the table is empty
        for ($c = 0; $c -lt $fieldCount; $c++) { $fields[$c] = Format-CsvField $reader.GetName($c) }
        $writer.WriteLine([string]::Join(',', $fields))

        while ($reader.Read()) {
            for ($c = 0; $c -lt $fieldCount; $c++) { $fields[$c] = Format-CsvField $reader.GetValue($c) }
            $writer.WriteLine([string]::Join(',', $fields))
            $rows++
        }
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
        $cmd.Dispose()
    }
    return $rows
}

#endregion Helpers

#region Validate output location

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    throw "OutputPath '$OutputPath' does not exist or is not a folder."
}
$OutputPath  = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
$serverLabel = $SqlInstance.ToUpperInvariant()
$exportDir   = Join-Path $OutputPath (Get-SafeFileName $Database)
$zipPath     = "$exportDir.zip"

foreach ($existing in @($exportDir, $zipPath)) {
    if ((Test-Path -LiteralPath $existing) -and -not $Force) {
        throw "'$existing' already exists. Use -Force to replace it."
    }
}

#endregion Validate output location

#region Connect

$csb = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$csb['Data Source']              = $SqlInstance
$csb['Initial Catalog']          = $Database
$csb['Application Name']         = 'Molehill Export-DatabaseSample'
$csb['Encrypt']                  = $true
$csb['TrustServerCertificate']   = [bool]$TrustServerCertificate
$csb['Connect Timeout']          = 30
if ($PSCmdlet.ParameterSetName -eq 'Windows') { $csb['Integrated Security'] = $true }

$conn = [System.Data.SqlClient.SqlConnection]::new($csb.ConnectionString)

switch ($PSCmdlet.ParameterSetName) {
    'SqlAuth' {
        $pw = $SqlCredential.Password.Copy()
        $pw.MakeReadOnly()
        $conn.Credential = [System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName, $pw)
    }
    'Entra' { $conn.AccessToken = Get-EntraSqlToken }
    'Token' { $conn.AccessToken = $AccessToken }
}

$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
$results  = [System.Collections.Generic.List[object]]::new()

try {
    Write-Status "Connecting to $serverLabel, database [$Database] ($($PSCmdlet.ParameterSetName) authentication)" Cyan
    $conn.Open()

    $info = Invoke-SqlQuery -Connection $conn -Query @"
SELECT  EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int),
        ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
        CurrentDb = DB_NAME();
"@
    $platform = switch ([int]$info.Rows[0].EngineEdition) {
        5       { 'Azure SQL Database' }
        8       { 'Azure SQL Managed Instance' }
        default { 'SQL Server' }
    }
    Write-Status "Connected: $platform $($info.Rows[0].ProductVersion), database [$($info.Rows[0].CurrentDb)]" Cyan

    #endregion Connect

    #region Discover tables

    # sys.objects type 'U' excludes external tables (type 'ET') on every version
    $columnRows = Invoke-SqlQuery -Connection $conn -Query @"
SELECT  ObjectKey    = CAST(o.object_id AS varchar(20)),
        SchemaName   = s.name,
        TableName    = o.name,
        QuotedSchema = QUOTENAME(s.name),
        QuotedTable  = QUOTENAME(o.name),
        QuotedColumn = QUOTENAME(c.name),
        IsClrType    = CAST(CASE WHEN c.system_type_id = 240 THEN 1 ELSE 0 END AS bit)
FROM    sys.objects AS o
JOIN    sys.schemas AS s ON s.schema_id = o.schema_id
JOIN    sys.columns AS c ON c.object_id = o.object_id
WHERE   o.type = 'U'
AND     o.is_ms_shipped = 0
AND     NOT EXISTS (SELECT 1
                    FROM   sys.extended_properties AS ep
                    WHERE  ep.class = 1
                    AND    ep.major_id = o.object_id
                    AND    ep.minor_id = 0
                    AND    ep.name = N'microsoft_database_tools_support')
ORDER BY s.name, o.name, c.column_id;
"@

    $tables = [ordered]@{}
    foreach ($row in $columnRows.Rows) {
        $key = [string]$row.ObjectKey
        if (-not $tables.Contains($key)) {
            $tables[$key] = [pscustomobject]@{
                Schema       = [string]$row.SchemaName
                Table        = [string]$row.TableName
                QuotedSchema = [string]$row.QuotedSchema
                QuotedTable  = [string]$row.QuotedTable
                Columns      = [System.Collections.Generic.List[string]]::new()
            }
        }
        $col = [string]$row.QuotedColumn
        if ([bool]$row.IsClrType) {
            $tables[$key].Columns.Add("CAST($col.ToString() AS nvarchar(max)) AS $col")
        }
        else {
            $tables[$key].Columns.Add($col)
        }
    }

    $tableCount = $tables.Count
    Write-Status "Found $tableCount user table(s). Sampling TOP ($Top) rows per table." Cyan
    if ($tableCount -eq 0) { Write-Status 'Nothing to export.' Yellow }

    #endregion Discover tables

    #region Prepare output

    foreach ($existing in @($exportDir, $zipPath)) {
        if (Test-Path -LiteralPath $existing) { Remove-Item -LiteralPath $existing -Recurse -Force }
    }
    $null = New-Item -ItemType Directory -Path $exportDir

    $isolation = if ($ReadUncommitted) { 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED; ' } else { '' }

    #endregion Prepare output

    #region Export

    $i = 0
    foreach ($t in $tables.Values) {
        $i++
        $displayName = "$($t.Schema).$($t.Table)"
        $filePath    = Join-Path $exportDir (Get-SafeFileName "$displayName.csv")
        $from        = "$($t.QuotedSchema).$($t.QuotedTable)"

        Write-Progress -Activity "Sampling [$Database] on $serverLabel" -Status "$i of $tableCount : $displayName" `
            -PercentComplete ([int](($i - 1) / [math]::Max($tableCount, 1) * 100))

        $attempts = @(
            "${isolation}SELECT TOP (@Top) $($t.Columns -join ', ') FROM $from ORDER BY NEWID();",
            "${isolation}SELECT TOP (@Top) * FROM $from ORDER BY NEWID();"
        )

        $timer  = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'Failed'
        $rows   = 0
        $err    = $null

        for ($a = 0; $a -lt $attempts.Count; $a++) {
            try {
                $rows   = Export-TableSample -Connection $conn -Query $attempts[$a] -FilePath $filePath
                $status = if ($a -eq 0) { 'OK' } else { 'OK (SELECT *)' }
                $err    = $null
                break
            }
            catch {
                $err = $_.Exception.GetBaseException().Message
                if (Test-Path -LiteralPath $filePath) { Remove-Item -LiteralPath $filePath -Force }
                if ($a -eq 0) { Write-Status "  $displayName : column list failed, retrying with SELECT *. $err" Yellow }
            }
        }
        $timer.Stop()

        if ($null -eq $err) {
            Write-Status ("[{0}/{1}] {2} : {3} row(s) in {4:N1}s" -f $i, $tableCount, $displayName, $rows, $timer.Elapsed.TotalSeconds) Green
        }
        else {
            Write-Status ("[{0}/{1}] {2} : FAILED. {3}" -f $i, $tableCount, $displayName, $err) Red
        }

        $results.Add([pscustomobject]@{
            Table   = $displayName
            Rows    = $rows
            Status  = $status
            Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
            Error   = $err
        })
    }
    Write-Progress -Activity "Sampling [$Database] on $serverLabel" -Completed

    #endregion Export

    #region Zip

    Write-Status "Creating $zipPath" Cyan
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $exportDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)

    if ($RemoveFolderAfterZip) {
        Remove-Item -LiteralPath $exportDir -Recurse -Force
        Write-Status "Removed working folder $exportDir" Gray
    }

    #endregion Zip
}
finally {
    $conn.Dispose()
}

#region Summary

$runTimer.Stop()
$failed  = @($results | Where-Object { $null -ne $_.Error })
$okCount = $results.Count - $failed.Count
$rowSum  = ($results | Measure-Object -Property Rows -Sum).Sum
if ($null -eq $rowSum) { $rowSum = 0 }

Write-Host ''
Write-Status '===== Run summary =====' Cyan
Write-Status "Server      : $serverLabel ($platform)"
Write-Status "Database    : $Database"
Write-Status "Tables      : $okCount exported, $($failed.Count) failed, $tableCount total"
Write-Status "Rows        : $rowSum"
Write-Status "Zip         : $zipPath"
Write-Status ("Elapsed     : {0:hh\:mm\:ss}" -f $runTimer.Elapsed)

if ($failed.Count -gt 0) {
    Write-Status 'Failed tables:' Red
    foreach ($f in $failed) { Write-Status "  $($f.Table) : $($f.Error)" Red }
}

[pscustomobject]@{
    SqlInstance = $serverLabel
    Platform    = $platform
    Database    = $Database
    Top         = $Top
    Exported    = $okCount
    Failed      = $failed.Count
    TotalRows   = $rowSum
    ZipPath     = $zipPath
    Elapsed     = $runTimer.Elapsed
    Tables      = $results
}

#endregion Summary
