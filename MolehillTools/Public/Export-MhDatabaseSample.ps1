<#
.SYNOPSIS
    Exports a random sample of rows from every user table in a database to CSV, then zips the lot.

.DESCRIPTION
    For handing a developer realistically shaped data, reproducing a problem somewhere safe, or
    seeing what is actually in a database you have just been given.

    SELECT TOP (n) ... ORDER BY NEWID() per table, to <OutputPath>\<Database>\<schema>.<table>.csv
    and then into <Database>.zip. Every file has a header row, including the ones for empty tables.

    The awkward columns are handled: geography, geometry and hierarchyid are converted server side
    so no client assemblies are needed, binary and rowversion come out as 0x hex, dates are ISO
    8601 and numbers invariant, and the files are UTF-8 with a BOM and CRLF so Excel opens them
    without a fight. Values are quoted per RFC 4180 only where they need to be.

    It keeps going: a table whose column list fails - a graph table, say - is retried once with
    SELECT *, external and diagram tables are skipped, and a failure is reported per table rather
    than stopping the run.

    IT COPIES REAL DATA OUT OF A DATABASE. Where that data is personal or confidential, a sample
    of it is still personal or confidential: mind where the zip goes, and whether masked or
    synthetic data would do instead.

.PARAMETER SqlInstance
    Server or instance name. Examples: SQLPROD01, SQLPROD01\INST2, myserver.database.windows.net,
    mymi.public.abc123.database.windows.net,3342

.PARAMETER Database
    The database to sample. Also used as the output folder and zip file name.

.PARAMETER ConnectionString
    Use this connection string instead of building one. Get-MhSqlConnectionString hands over the
    string it showed you, so what runs is exactly what you saw. -Database is taken from its
    Initial Catalog unless given separately.

.PARAMETER UseMicrosoftDataSqlClient
    Connect with Microsoft.Data.SqlClient rather than System.Data.SqlClient. It comes with the
    SqlServer module and is the one that can do Entra service principal, managed identity, device
    code and default authentication, and Encrypt = Strict.

.PARAMETER Top
    Rows to sample per table. Default 200.

.PARAMETER OutputPath
    An existing folder to receive the <Database> folder and <Database>.zip. Default: here.

.PARAMETER SqlCredential
    SQL authentication. Omit every authentication parameter for Windows authentication.

.PARAMETER UseEntraId
    Microsoft Entra ID authentication with a token from Get-AzAccessToken. Needs Az.Accounts and
    Connect-AzAccount first - or use -ConnectionString from the connect screen, which needs
    neither.

.PARAMETER AccessToken
    Your own Entra ID access token for https://database.windows.net/

.PARAMETER IncludeTable
    Export only these tables: schema.table, a bare table name, or a wildcard - 'dbo.Orders',
    'Orders', 'dbo.*', '*Audit*'. Brackets are allowed and ignored. A pattern that matches nothing
    is reported rather than passed over.

.PARAMETER ExcludeTable
    Export everything except these, in the same forms. Applied after -IncludeTable.

.PARAMETER TrustServerCertificate
    Skip certificate validation, which an on-premises instance with a self-signed one needs.

.PARAMETER ReadUncommitted
    Sample under READ UNCOMMITTED, so no shared locks are taken on a busy production table.

.PARAMETER CommandTimeout
    Per-table query timeout in seconds. Default 600. 0 means no timeout.

.PARAMETER RemoveFolderAfterZip
    Delete the folder once the zip is made, leaving just the zip.

.PARAMETER Force
    Replace an existing folder and zip of the same name.

.OUTPUTS
    A summary object with Exported, Failed, TotalRows, ZipPath and the per-table detail.

.EXAMPLE
    Export-MhDatabaseSample -SqlInstance SQLPROD01 -Database Sales -TrustServerCertificate

.EXAMPLE
    Export-MhDatabaseSample -SqlInstance SQLPROD01 -Database Sales -ExcludeTable '*Audit*', 'staging.*'

.EXAMPLE
    Export-MhDatabaseSample -ConnectionString (Get-MhSqlConnectionString) -Top 500

.NOTES
    Molehill Data Services. It reads data and writes files locally; nothing on the server changes.
#>

function Export-MhDatabaseSample {
    [CmdletBinding(DefaultParameterSetName = 'Windows')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Windows')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'SqlAuth')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Entra')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Token')]
        [ValidateNotNullOrEmpty()]
        [string]$SqlInstance,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Windows')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'SqlAuth')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Entra')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Token')]
        [Parameter(ParameterSetName = 'ConnectionString')]
        [string]$Database,

        [Parameter(Mandatory, ParameterSetName = 'ConnectionString')]
        [ValidateNotNullOrEmpty()]
        [string]$ConnectionString,

        [switch]$UseMicrosoftDataSqlClient,

        [string[]]$IncludeTable,
        [string[]]$ExcludeTable,

        [Alias('n')]
        [ValidateRange(1, 2147483647)]
        [int]$Top = 200,

        [string]$OutputPath = (Get-Location).ProviderPath,

        [Parameter(Mandatory, ParameterSetName = 'SqlAuth')]
        [System.Management.Automation.PSCredential]$SqlCredential,

        [Parameter(Mandatory, ParameterSetName = 'Entra')]
        [switch]$UseEntraId,

        [Parameter(Mandatory, ParameterSetName = 'Token')]
        [Parameter(ParameterSetName = 'ConnectionString')]
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
    $Invariant        = [System.Globalization.CultureInfo]::InvariantCulture
    $CsvSpecialChars  = [char[]]@(',', '"', "`r", "`n")
    $InvalidFileChars = [System.IO.Path]::GetInvalidFileNameChars()
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        throw "OutputPath '$OutputPath' does not exist or is not a folder."
    }
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
    $clientNamespace = 'System.Data.SqlClient'
    if ($UseMicrosoftDataSqlClient) {
        $clientNamespace = Get-MhSqlClientNamespace -Microsoft
        if (-not $clientNamespace) {
            throw ("Microsoft.Data.SqlClient needs the SqlServer module, and it could not be loaded in this PowerShell ({0} {1}). Run: Install-Module SqlServer -Scope CurrentUser - in this edition, because the two editions look in different module folders." -f
                   $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
        }
    }
    if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') {
        $parsed = New-Object "$clientNamespace.SqlConnectionStringBuilder" $ConnectionString
        if (-not $Database) { $Database = [string]$parsed['Initial Catalog'] }
        if (-not $Database) {
            throw 'The connection string names no database (Initial Catalog), so pass -Database as well: it is what the folder and the zip are named after.'
        }
        $SqlInstance = [string]$parsed['Data Source']
    }
    if (-not $Database) { throw 'No database to sample.' }
    $serverLabel = $SqlInstance.ToUpperInvariant()
    $exportDir   = Join-Path $OutputPath (Get-SampleSafeFileName $Database)
    $zipPath     = "$exportDir.zip"
    foreach ($existing in @($exportDir, $zipPath)) {
        if ((Test-Path -LiteralPath $existing) -and -not $Force) {
            throw "'$existing' already exists. Use -Force to replace it."
        }
    }
    if ($PSCmdlet.ParameterSetName -eq 'ConnectionString') {
        $conn = New-Object "$clientNamespace.SqlConnection" $ConnectionString
        if ($AccessToken) { $conn.AccessToken = $AccessToken }
    }
    else {
        $csb = New-Object "$clientNamespace.SqlConnectionStringBuilder"
        $csb['Data Source']            = $SqlInstance
        $csb['Initial Catalog']        = $Database
        $csb['Application Name']       = 'Molehill Export-DatabaseSample'
        $csb['Encrypt']                = $true
        $csb['TrustServerCertificate'] = [bool]$TrustServerCertificate
        $csb['Connect Timeout']        = 30
        if ($PSCmdlet.ParameterSetName -eq 'Windows') { $csb['Integrated Security'] = $true }

        $conn = New-Object "$clientNamespace.SqlConnection" $csb.ConnectionString

        switch ($PSCmdlet.ParameterSetName) {
            'SqlAuth' {
                $pw = $SqlCredential.Password.Copy()
                $pw.MakeReadOnly()
                $conn.Credential = New-Object "$clientNamespace.SqlCredential" $SqlCredential.UserName, $pw
            }
            'Entra' { $conn.AccessToken = Get-SampleEntraToken }
            'Token' { $conn.AccessToken = $AccessToken }
        }
    }
    $runTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $results  = [System.Collections.Generic.List[object]]::new()
    $includePatterns = @($IncludeTable | Where-Object { $null -ne $_ -and ([string]$_).Trim() })
    $excludePatterns = @($ExcludeTable | Where-Object { $null -ne $_ -and ([string]$_).Trim() })
    try {
        Write-SampleStatus "Connecting to $serverLabel, database [$Database] ($($PSCmdlet.ParameterSetName) authentication, $clientNamespace)" Cyan
        $conn.Open()

        $info = Invoke-SampleQuery -Connection $conn -Query @"
SELECT  EngineEdition = CAST(SERVERPROPERTY('EngineEdition') AS int),
        ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
        CurrentDb = DB_NAME();
"@
        $platform = switch ([int]$info.Rows[0].EngineEdition) {
            5       { 'Azure SQL Database' }
            8       { 'Azure SQL Managed Instance' }
            default { 'SQL Server' }
        }
        Write-SampleStatus "Connected: $platform $($info.Rows[0].ProductVersion), database [$($info.Rows[0].CurrentDb)]" Cyan

        #endregion Connect

        #region Discover tables

        # sys.objects type 'U' excludes external tables (type 'ET') on every version
        $columnRows = Invoke-SampleQuery -Connection $conn -Query @"
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

        $found = $tables.Count
        if ($includePatterns.Count -gt 0 -or $excludePatterns.Count -gt 0) {
            $choice = Select-SampleTable -Tables @($tables.Values) -Include $includePatterns -Exclude $excludePatterns
            foreach ($idle in $choice.Unmatched) {
                Write-SampleStatus "  '$idle' matched no table in [$Database]. Check the spelling: nothing was exported for it." Yellow
            }
            $keptKeys = @{}
            foreach ($t in $choice.Kept) { $keptKeys["$($t.Schema).$($t.Table)"] = $true }
            $filtered = [ordered]@{}
            foreach ($entry in $tables.GetEnumerator()) {
                if ($keptKeys.ContainsKey("$($entry.Value.Schema).$($entry.Value.Table)")) { $filtered[$entry.Key] = $entry.Value }
            }
            $tables = $filtered
            Write-SampleStatus ("Found {0} user table(s); {1} after the include and exclude lists." -f $found, $tables.Count) Cyan
        }

        $tableCount = $tables.Count
        Write-SampleStatus "Sampling TOP ($Top) rows per table, $tableCount table(s)." Cyan
        if ($tableCount -eq 0) { Write-SampleStatus 'Nothing to export.' Yellow }

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
            $filePath    = Join-Path $exportDir (Get-SampleSafeFileName "$displayName.csv")
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
                    if ($a -eq 0) { Write-SampleStatus "  $displayName : column list failed, retrying with SELECT *. $err" Yellow }
                }
            }
            $timer.Stop()

            if ($null -eq $err) {
                Write-SampleStatus ("[{0}/{1}] {2} : {3} row(s) in {4:N1}s" -f $i, $tableCount, $displayName, $rows, $timer.Elapsed.TotalSeconds) Green
            }
            else {
                Write-SampleStatus ("[{0}/{1}] {2} : FAILED. {3}" -f $i, $tableCount, $displayName, $err) Red
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

        Write-SampleStatus "Creating $zipPath" Cyan
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $exportDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)

        if ($RemoveFolderAfterZip) {
            Remove-Item -LiteralPath $exportDir -Recurse -Force
            Write-SampleStatus "Removed working folder $exportDir" Gray
        }

        #endregion Zip
    }
    finally {
        $conn.Dispose()
    }
    $runTimer.Stop()
    $failed  = @($results | Where-Object { $null -ne $_.Error })
    $okCount = $results.Count - $failed.Count
    $rowSum = 0
    if ($results.Count -gt 0) {
        $measured = $results | Measure-Object -Property Rows -Sum
        if ($null -ne $measured -and $null -ne $measured.Sum) { $rowSum = $measured.Sum }
    }
    Write-Host ''
    Write-SampleStatus '===== Run summary =====' Cyan
    Write-SampleStatus "Server      : $serverLabel ($platform)"
    Write-SampleStatus "Database    : $Database"
    Write-SampleStatus "Tables      : $okCount exported, $($failed.Count) failed, $tableCount selected"
    if ($includePatterns.Count -gt 0) { Write-SampleStatus ("Included    : " + ($includePatterns -join ', ')) }
    if ($excludePatterns.Count -gt 0) { Write-SampleStatus ("Excluded    : " + ($excludePatterns -join ', ')) }
    Write-SampleStatus "Rows        : $rowSum"
    Write-SampleStatus "Zip         : $zipPath"
    Write-SampleStatus ("Elapsed     : {0:hh\:mm\:ss}" -f $runTimer.Elapsed)
    if ($failed.Count -gt 0) {
        Write-SampleStatus 'Failed tables:' Red
        foreach ($f in $failed) { Write-SampleStatus "  $($f.Table) : $($f.Error)" Red }
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
}

function Write-SampleStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Colour = [ConsoleColor]::Gray
    )
    Write-Host ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message) -ForegroundColor $Colour
}

function Get-SampleSafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($c in $InvalidFileChars) { $Name = $Name.Replace($c, '_') }
    return $Name
}

function Format-SampleCsvField {
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

function Test-SampleTableMatch {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Schema,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Table,
        [AllowEmptyCollection()][string[]]$Patterns = @()
    )

    $qualified = "$Schema.$Table"
    foreach ($raw in $Patterns) {
        if ($null -eq $raw) { continue }
        $pattern = ([string]$raw).Trim().Replace('[', '').Replace(']', '')
        if (-not $pattern) { continue }

        # an exact name wins before anything is treated as a wildcard, so a table whose name
        # contains a bracket or a dot can still be asked for by name
        if ($pattern -eq $qualified -or $pattern -eq $Table) { return $true }
        if ($qualified -like $pattern) { return $true }
        if ($pattern -notlike '*.*' -and $Table -like $pattern) { return $true }
    }
    return $false
}

function Select-SampleTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tables,
        [AllowEmptyCollection()][string[]]$Include = @(),
        [AllowEmptyCollection()][string[]]$Exclude = @()
    )

    # @($null).Count is 1, not 0, so an unsupplied list has to be emptied properly or it reads as
    # a filter of one blank pattern - which quietly keeps nothing at all
    $wantedPatterns = @($Include | Where-Object { $null -ne $_ -and ([string]$_).Trim() })
    $unwantedPatterns = @($Exclude | Where-Object { $null -ne $_ -and ([string]$_).Trim() })

    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Tables) {
        $wanted = $true
        if ($wantedPatterns.Count -gt 0) { $wanted = Test-SampleTableMatch -Schema $t.Schema -Table $t.Table -Patterns $wantedPatterns }
        if ($wanted -and $unwantedPatterns.Count -gt 0 -and (Test-SampleTableMatch -Schema $t.Schema -Table $t.Table -Patterns $unwantedPatterns)) {
            $wanted = $false
        }
        if ($wanted) { $kept.Add($t) }
    }

    $idle = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in ($wantedPatterns + $unwantedPatterns)) {
        if ($null -eq $pattern -or -not ([string]$pattern).Trim()) { continue }
        $hit = $false
        foreach ($t in $Tables) {
            if (Test-SampleTableMatch -Schema $t.Schema -Table $t.Table -Patterns @($pattern)) { $hit = $true; break }
        }
        if (-not $hit) { $idle.Add(([string]$pattern).Trim()) }
    }

    return [pscustomobject]@{ Kept = $kept.ToArray(); Unmatched = $idle.ToArray() }
}

function Get-SampleEntraToken {
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

function Invoke-SampleQuery {
    # DbConnection rather than SqlConnection: both drivers derive from it, so the same code runs
    # whichever one the connection came from
    param(
        [Parameter(Mandatory)][System.Data.Common.DbConnection]$Connection,
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
        [Parameter(Mandatory)][System.Data.Common.DbConnection]$Connection,
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
    # built through the generic factory so it works on either driver. Not called $top: variable
    # names are case-insensitive, so that shadows the script's own $Top and the parameter ends up
    # being handed itself as its value.
    $topParam = $cmd.CreateParameter()
    $topParam.ParameterName = '@Top'
    $topParam.DbType = [System.Data.DbType]::Int32
    $topParam.Value = $Top
    $null = $cmd.Parameters.Add($topParam)

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
        for ($c = 0; $c -lt $fieldCount; $c++) { $fields[$c] = Format-SampleCsvField $reader.GetName($c) }
        $writer.WriteLine([string]::Join(',', $fields))

        while ($reader.Read()) {
            for ($c = 0; $c -lt $fieldCount; $c++) { $fields[$c] = Format-SampleCsvField $reader.GetValue($c) }
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

Register-MhSelfTest -Name 'Export-MhDatabaseSample' -Test {
    function T([string]$Schema, [string]$Table) { [pscustomobject]@{ Schema = $Schema; Table = $Table } }
    $all = @(
        (T 'dbo' 'Orders'), (T 'dbo' 'OrderLines'), (T 'dbo' 'CustomerAudit'),
        (T 'sales' 'Orders'), (T 'sales' 'Targets'), (T 'staging' 'Load'), (T 'ref' 'Currency')
    )
    function Names($result) { (@($result.Kept | ForEach-Object { "$($_.Schema).$($_.Table)" }) -join ',') }

    Test-MhSection 'the ways a table can be named'
    Test-MhCheck 'schema and table' (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('dbo.Orders'))
    Test-MhCheck 'the table on its own' (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('Orders'))
    Test-MhCheck 'in brackets' (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('[dbo].[Orders]'))
    Test-MhCheck 'case does not matter' (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('DBO.orders'))
    Test-MhCheck 'a whole schema' (Test-SampleTableMatch -Schema 'staging' -Table 'Load' -Patterns @('staging.*'))
    Test-MhCheck 'a wildcard on the name' (Test-SampleTableMatch -Schema 'dbo' -Table 'CustomerAudit' -Patterns @('*Audit*'))
    Test-MhCheck 'and one that does not match' (-not (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('dbo.Invoices')))
    Test-MhCheck 'a bare name does not reach into another schema' (-not (Test-SampleTableMatch -Schema 'sales' -Table 'Targets' -Patterns @('dbo.Targets')))
    Test-MhCheck 'the same name in two schemas matches both' (
        (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('Orders')) -and
        (Test-SampleTableMatch -Schema 'sales' -Table 'Orders' -Patterns @('Orders')))
    Test-MhCheck 'nothing asked for matches nothing' (-not (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @()))
    Test-MhCheck 'and an empty pattern is ignored rather than matching everything' (-not (Test-SampleTableMatch -Schema 'dbo' -Table 'Orders' -Patterns @('', '   ')))

    Test-MhSection 'choosing the set to export'
    Test-MhCheck 'no filter keeps every table' ((Select-SampleTable -Tables $all).Kept.Count -eq 7)
    Test-MhCheck 'include keeps only what was named' ((Names (Select-SampleTable -Tables $all -Include @('dbo.Orders', 'ref.Currency'))) -eq 'dbo.Orders,ref.Currency')
    Test-MhCheck 'include keeps the order they came in' ((Names (Select-SampleTable -Tables $all -Include @('ref.Currency', 'dbo.Orders'))) -eq 'dbo.Orders,ref.Currency')
    Test-MhCheck 'exclude drops what was named' ((Select-SampleTable -Tables $all -Exclude @('staging.*', '*Audit*')).Kept.Count -eq 5)
    Test-MhCheck 'and keeps everything else' ((Names (Select-SampleTable -Tables $all -Exclude @('staging.*', '*Audit*'))) -eq 'dbo.Orders,dbo.OrderLines,sales.Orders,sales.Targets,ref.Currency')
    Test-MhCheck 'the two together, exclude last' ((Names (Select-SampleTable -Tables $all -Include @('dbo.*') -Exclude @('*Audit*'))) -eq 'dbo.Orders,dbo.OrderLines')
    Test-MhCheck 'excluding everything leaves nothing' ((Select-SampleTable -Tables $all -Exclude @('*')).Kept.Count -eq 0)
    Test-MhCheck 'a pattern that matches nothing is named' (((Select-SampleTable -Tables $all -Include @('dbo.Orders', 'dbo.Nope')).Unmatched -join ',') -eq 'dbo.Nope')
    Test-MhCheck 'and one that matches is not' ((Select-SampleTable -Tables $all -Include @('dbo.Orders')).Unmatched.Count -eq 0)
    Test-MhCheck 'an unmatched exclude is reported too' (((Select-SampleTable -Tables $all -Exclude @('nosuch.*')).Unmatched -join ',') -eq 'nosuch.*')

    Test-MhCheck 'an unsupplied list is not a filter of one blank pattern' ((Select-SampleTable -Tables $all -Include $null -Exclude $null).Kept.Count -eq 7)
    Test-MhCheck 'nor is a list of blanks' ((Select-SampleTable -Tables $all -Include @($null, '', '  ')).Kept.Count -eq 7)
    Test-MhCheck 'and a blank among real patterns is just ignored' ((Names (Select-SampleTable -Tables $all -Include @('', 'ref.Currency'))) -eq 'ref.Currency')

    Test-MhSection 'which driver'
    # this tool used to carry its own copy of the driver lookup; the module's is the one now
    Test-MhCheck 'the framework one needs nothing installed' ((Get-MhSqlClientNamespace) -eq 'System.Data.SqlClient')
    Test-MhCheck 'and it has a connection string builder' ($null -ne ('System.Data.SqlClient.SqlConnectionStringBuilder' -as [type]))

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    return
}
