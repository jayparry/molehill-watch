<#
.SYNOPSIS
    Weekly status report for Azure SQL Database logical servers and elastic pools (Molehill Watch).

.DESCRIPTION
    Azure SQL Database has no SQL Agent and nowhere to install Molehill Watch, so this script is run
    from the jump box instead. It is READ-ONLY: it creates nothing in Azure and nothing on the server,
    and the report is written to a local folder (client data stays on client infrastructure).

    It covers the areas the support agreement lists for Azure SQL Database:
      - Backup retention (earliest restore point, and the retention / LTR policies with -AzurePlatformChecks)
      - Compute utilisation (DTU or vCore), storage headroom against the service tier limit, throttling
      - Top queries by CPU from Query Store (the data behind Query Performance Insight)
      - Elastic job failures (with -ElasticJobServer / -ElasticJobDatabase)
      - Geo-replication and failover group health
      - Security: firewall rules, TDE, auditing and Microsoft Defender for SQL (the last two with -AzurePlatformChecks)
      - Cost and service tier observations (over-provisioned databases, pooling, serverless, reserved capacity)

    Sign-in (first that applies):
      -SqlCredential      SQL authentication
      -AccessToken        a token you already have for https://database.windows.net/
      Azure CLI           if 'az' is installed and signed in (az login)
      Az PowerShell       if Connect-AzAccount has been run
    The account needs VIEW DATABASE STATE in each database and access to master (server admin, or
    a login with the ##MS_ServerStateReader## role, sees everything).

    -AzurePlatformChecks also reads settings that only exist in Azure Resource Manager (retention
    policies, auditing, Defender, failover groups, paused serverless databases) through the Azure CLI,
    with Reader access to the subscription. It also skips auto-paused serverless databases, which
    would otherwise be woken (and billed) by connecting to them.

.EXAMPLE
    .\Get-AzureSqlDatabaseReport.ps1 -Server contoso-sql -ClientName 'Contoso Ltd'

.EXAMPLE
    .\Get-AzureSqlDatabaseReport.ps1 -Server contoso-sql,contoso-sql-dr -ClientName 'Contoso Ltd' -AzurePlatformChecks `
        -ElasticJobServer contoso-jobs -ElasticJobDatabase jobagent -OutputFolder D:\Reports
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string[]] $Server,
    [string]       $ClientName = '',
    [string[]]     $Database,
    [string[]]     $ExcludeDatabase,
    [pscredential] $SqlCredential,
    [string]       $AccessToken,
    [string]       $OutputFolder = (Join-Path (Get-Location).Path 'AzureSqlReports'),
    [ValidateRange(1, 14)] [int] $DaysBack = 7,
    [string]       $ElasticJobServer,
    [string]       $ElasticJobDatabase,
    [switch]       $IncludeQueryText,
    [switch]       $AzurePlatformChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# arrays do not bind through powershell.exe -File, so accept "a,b" as well
function Split-List([string[]]$Values) { @($Values | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$Server = @(Split-List $Server)
$Database = @(Split-List $Database)
$ExcludeDatabase = @(Split-List $ExcludeDatabase)

function Get-FullServerName([string]$Name) {
    if ($Name -match '[.,:\\]' -or $Name -match '^\(localdb\)') { return $Name }   # already qualified (or a local test instance)
    return "$Name.database.windows.net"
}

function Encode([object]$Value) { if ($null -eq $Value -or $Value -is [DBNull]) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$Value) } }

function Format-Date($Value) {
    if ($null -eq $Value -or $Value -is [DBNull]) { return 'never' }
    return ([datetime]$Value).ToString('dd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' UTC'
}

function Get-SqlError($ErrorRecord) {
    $ex = $ErrorRecord.Exception
    $parts = @()
    while ($ex) {
        if ($ex -is [System.Data.SqlClient.SqlException]) { foreach ($e in $ex.Errors) { $parts += $e.Message } }
        elseif ($ex.Message -and $ex.Message -notlike 'Exception calling*') { $parts += $ex.Message }
        $ex = $ex.InnerException
    }
    if ($parts.Count -eq 0) { $parts = @($ErrorRecord.Exception.Message) }
    return (($parts | Select-Object -Unique) -join ' ')
}

# ------------------------------------------------------------------ sign-in
$script:token = $null
function Get-Token {
    if ($SqlCredential) { return $null }
    if ($AccessToken) { return $AccessToken }
    if ($script:token) { return $script:token }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $t = & az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $t) { $script:token = "$t".Trim(); return $script:token }
    }
    if (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue) {
        try {
            $t = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
            $value = $t.Token
            if ($value -is [securestring]) { $value = (New-Object System.Net.NetworkCredential('', $value)).Password }
            $script:token = $value
            return $script:token
        } catch { }
    }
    throw 'No way to sign in: pass -SqlCredential, or sign in first with "az login" (Azure CLI) or Connect-AzAccount (Az PowerShell), or pass -AccessToken.'
}

function Open-Connection([string]$ServerName, [string]$DatabaseName) {
    $full = Get-FullServerName $ServerName
    $local = $full -match '^\(localdb\)'
    $cs = if ($local) { "Data Source=$full;Initial Catalog=$DatabaseName;Integrated Security=True;Connect Timeout=30;Application Name=Molehill Watch Azure report" }
          else { "Server=tcp:$full,1433;Initial Catalog=$DatabaseName;Encrypt=True;TrustServerCertificate=False;Connect Timeout=30;Application Name=Molehill Watch Azure report" }
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    if (-not $local) {
        if ($SqlCredential) {
            $pw = $SqlCredential.Password.Copy(); $pw.MakeReadOnly()
            $conn.Credential = New-Object System.Data.SqlClient.SqlCredential($SqlCredential.UserName, $pw)
        } else {
            $conn.AccessToken = Get-Token
        }
    }
    $conn.Open()
    return $conn
}

function Invoke-Query($Conn, [string]$Sql, [hashtable]$Parameters = @{}) {
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 120
    foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $(if ($null -eq $Parameters[$k]) { [DBNull]::Value } else { $Parameters[$k] })) }
    $table = New-Object System.Data.DataTable
    $reader = $cmd.ExecuteReader()
    try { $table.Load($reader) } finally { $reader.Close() }
    return ,$table
}

# ------------------------------------------------------------------ Azure Resource Manager (optional)
$script:azOk = $false
if ($AzurePlatformChecks) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Warning '-AzurePlatformChecks needs the Azure CLI (az). Continuing without it.' }
    else {
        & az account show -o none 2>$null
        if ($LASTEXITCODE -eq 0) { $script:azOk = $true } else { Write-Warning 'The Azure CLI is not signed in (run az login). Continuing without Azure platform checks.' }
    }
}

function Invoke-Az([string[]]$Arguments) {
    $out = & az @Arguments -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($out | ForEach-Object { "$_" }) -join ' ') }
    $json = ($out | ForEach-Object { "$_" }) -join "`n"
    if (-not $json.Trim()) { return $null }
    $parsed = $json | ConvertFrom-Json
    return $parsed   # unrolled: a JSON array comes back as its items
}

function Get-Prop($Object, [string[]]$Names) {
    foreach ($n in $Names) {
        $o = $Object
        foreach ($part in $n.Split('.')) {
            if ($null -eq $o) { break }
            $p = $o.PSObject.Properties[$part]
            $o = if ($p) { $p.Value } else { $null }
        }
        if ($null -ne $o) { return $o }
    }
    return $null
}

# ------------------------------------------------------------------ SQL
$sqlDatabases = @'
SELECT name, state_desc FROM sys.databases WHERE name NOT IN (N'master', N'tempdb', N'model', N'msdb') AND state_desc = N'ONLINE' ORDER BY name;
'@

$sqlResourceStats = @'
WITH s AS (
    SELECT database_name, sku, dtu_limit, cpu_limit, storage_in_megabytes, avg_cpu_percent, avg_data_io_percent, avg_log_write_percent,
           max_worker_percent, max_session_percent, end_time,
           Peak = (SELECT MAX(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) x (v))
    FROM sys.resource_stats WHERE end_time >= DATEADD(day, -@Days, SYSUTCDATETIME())),
p AS (SELECT *, P95 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY Peak) OVER (PARTITION BY database_name) FROM s)
SELECT DatabaseName = database_name, Samples = COUNT(*), Sku = MAX(sku), DtuLimit = MAX(dtu_limit), CpuLimit = MAX(cpu_limit),
       AvgCpu = CAST(AVG(avg_cpu_percent) AS decimal(5,1)), MaxCpu = CAST(MAX(avg_cpu_percent) AS decimal(5,1)),
       AvgIo = CAST(AVG(avg_data_io_percent) AS decimal(5,1)), AvgLog = CAST(AVG(avg_log_write_percent) AS decimal(5,1)),
       P95Peak = CAST(MAX(P95) AS decimal(5,1)), MaxWorkers = CAST(MAX(max_worker_percent) AS decimal(5,1)), MaxSessions = CAST(MAX(max_session_percent) AS decimal(5,1)),
       HotSamples = SUM(CASE WHEN Peak >= 95 THEN 1 ELSE 0 END)
FROM p GROUP BY database_name;
'@

$sqlPoolStats = @'
WITH s AS (
    SELECT elastic_pool_name, avg_cpu_percent, avg_data_io_percent, avg_log_write_percent, avg_storage_percent, max_worker_percent, max_session_percent,
           elastic_pool_dtu_limit, elastic_pool_cpu_limit, elastic_pool_storage_limit_mb,
           Peak = (SELECT MAX(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) x (v))
    FROM sys.elastic_pool_resource_stats WHERE end_time >= DATEADD(day, -@Days, SYSUTCDATETIME())),
p AS (SELECT *, P95 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY Peak) OVER (PARTITION BY elastic_pool_name) FROM s)
SELECT PoolName = elastic_pool_name, Samples = COUNT(*), DtuLimit = MAX(elastic_pool_dtu_limit), CpuLimit = MAX(elastic_pool_cpu_limit),
       StorageLimitMB = MAX(elastic_pool_storage_limit_mb),
       AvgCpu = CAST(AVG(avg_cpu_percent) AS decimal(5,1)), MaxCpu = CAST(MAX(avg_cpu_percent) AS decimal(5,1)),
       P95Peak = CAST(MAX(P95) AS decimal(5,1)), MaxStoragePct = CAST(MAX(avg_storage_percent) AS decimal(5,1)),
       MaxWorkers = CAST(MAX(max_worker_percent) AS decimal(5,1)), MaxSessions = CAST(MAX(max_session_percent) AS decimal(5,1)),
       HotSamples = SUM(CASE WHEN Peak >= 95 THEN 1 ELSE 0 END)
FROM p GROUP BY elastic_pool_name;
'@

$sqlFirewall = 'SELECT name, start_ip_address, end_ip_address FROM sys.firewall_rules ORDER BY name;'

$sqlDbProps = @'
SELECT Edition = CONVERT(nvarchar(60), DATABASEPROPERTYEX(DB_NAME(), 'Edition')),
       ServiceObjective = CONVERT(nvarchar(60), DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective')),
       MaxSizeMB = CONVERT(bigint, DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes')) / 1048576,
       UsedMB = (SELECT SUM(CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint)) * 8 / 1024 FROM sys.database_files WHERE type_desc = N'ROWS'),
       AllocatedMB = (SELECT SUM(CAST(size AS bigint)) * 8 / 1024 FROM sys.database_files WHERE type_desc = N'ROWS'),
       CompatLevel = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()),
       IsEncrypted = (SELECT is_encrypted FROM sys.databases WHERE database_id = DB_ID());
'@
$sqlPool = 'SELECT elastic_pool_name FROM sys.database_service_objectives WHERE database_id = DB_ID();'

$sqlLastHour = @'
SELECT Samples = COUNT(*), MaxCpu = MAX(avg_cpu_percent), MaxIo = MAX(avg_data_io_percent), MaxLog = MAX(avg_log_write_percent),
       MaxWorkers = MAX(max_worker_percent), MaxSessions = MAX(max_session_percent)
FROM sys.dm_db_resource_stats;
'@

$sqlBackups = @'
SELECT backup_type, LastFinish = MAX(backup_finish_date), EarliestStart = MIN(backup_start_date), Backups = COUNT(*)
FROM sys.dm_database_backups WHERE in_retention = 1 GROUP BY backup_type;
'@

$sqlGeo = @'
SELECT partner_server, partner_database, replication_state_desc, role_desc, replication_lag_sec, last_replication, secondary_allow_connections_desc
FROM sys.dm_geo_replication_link_status;
'@

$sqlQueryStoreState = @'
SELECT actual_state_desc, desired_state_desc, readonly_reason, current_storage_size_mb, max_storage_size_mb FROM sys.database_query_store_options;
'@

$sqlTopQueries = @'
DECLARE @since datetimeoffset = DATEADD(day, -@Days, SYSDATETIMEOFFSET());
WITH r AS (
    SELECT q.query_id, q.object_id,
           Executions = SUM(rs.count_executions),
           TotalCpuMs = SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0,
           TotalDurationMs = SUM(rs.avg_duration * rs.count_executions) / 1000.0,
           LogicalReads = SUM(rs.avg_logical_io_reads * rs.count_executions)
    FROM sys.query_store_runtime_stats rs
    JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
    JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
    JOIN sys.query_store_query q ON q.query_id = p.query_id
    WHERE i.start_time >= @since
    GROUP BY q.query_id, q.object_id)
SELECT TOP (5) r.query_id, ObjectName = OBJECT_NAME(r.object_id), r.Executions,
       TotalCpuMs = CAST(r.TotalCpuMs AS bigint),
       AvgDurationMs = CAST(r.TotalDurationMs / NULLIF(r.Executions, 0) AS decimal(18,1)),
       LogicalReads = CAST(r.LogicalReads AS bigint),
       QueryText = CASE WHEN @IncludeText = 1 THEN LEFT(qt.query_sql_text, 400) END
FROM r
JOIN sys.query_store_query q ON q.query_id = r.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
ORDER BY r.TotalCpuMs DESC;
'@

$sqlSecurity = @'
SELECT PasswordUsers = (SELECT COUNT(*) FROM sys.database_principals WHERE authentication_type_desc = N'DATABASE'),
       DbOwners = STUFF((SELECT N', ' + m.name FROM sys.database_role_members rm
                         JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id AND r.name = N'db_owner'
                         JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
                         WHERE m.name <> N'dbo' ORDER BY m.name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
       GuestConnect = (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'guest')
                       AND permission_name = N'CONNECT' AND state_desc IN (N'GRANT', N'GRANT_WITH_GRANT_OPTION'));
'@
$sqlDbFirewall = 'SELECT name, start_ip_address, end_ip_address FROM sys.database_firewall_rules ORDER BY name;'
$sqlTuning = @'
SELECT Options = STUFF((SELECT N', ' + name + N' ' + actual_state_desc FROM sys.database_automatic_tuning_options ORDER BY name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
       Recommendations = (SELECT COUNT(*) FROM sys.dm_db_tuning_recommendations WHERE JSON_VALUE(state, '$.currentValue') = 'Active');
'@

$sqlElasticJobs = @'
SELECT job_name, lifecycle, Failures = COUNT(*), LastFailure = MAX(start_time),
       LastMessage = (SELECT TOP (1) LEFT(x.last_message, 400) FROM jobs.job_executions x
                      WHERE x.job_name = e.job_name AND x.lifecycle = e.lifecycle ORDER BY x.start_time DESC),
       Targets = STUFF((SELECT DISTINCT N', ' + ISNULL(y.target_server_name + N'/', N'') + ISNULL(y.target_database_name, N'')
                        FROM jobs.job_executions y WHERE y.job_name = e.job_name AND y.lifecycle = e.lifecycle AND y.start_time >= DATEADD(day, -@Days, SYSUTCDATETIME())
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'')
FROM jobs.job_executions e
WHERE e.is_active = 0 AND e.lifecycle IN (N'Failed', N'TimedOut', N'Canceled', N'SucceededWithSkipped', N'WaitingForRetry')
  AND e.start_time >= DATEADD(day, -@Days, SYSUTCDATETIME())
GROUP BY job_name, lifecycle;
'@

# ------------------------------------------------------------------ report
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
$now = [datetime]::UtcNow
$summary = @()

foreach ($srv in $Server) {
    $full = Get-FullServerName $srv
    $short = ($full -split '\.')[0]
    Write-Host "[$full]" -ForegroundColor Cyan
    $findings = New-Object System.Collections.Generic.List[object]
    function Add-Finding([string]$Section, [string]$Severity, [string]$Item, [string]$Detail, [string]$Recommendation = '') {
        $findings.Add([pscustomobject]@{ Section = $Section; Severity = $Severity; Item = $Item; Detail = $Detail; Recommendation = $Recommendation })
    }
    function Add-NotChecked([string]$What, $ErrorRecord) {
        $msg = Get-SqlError $ErrorRecord
        $advice = if ($msg -match 'Invalid object name|Could not find') { 'Not available on this server: is it an Azure SQL Database?' } else { 'Usually a missing permission. Molehill Data Services will review.' }
        Add-Finding 'Monitoring' 'Info' "Could not check: $What" $msg $advice
    }

    $dbRows = New-Object System.Collections.Generic.List[object]
    $queries = New-Object System.Collections.Generic.List[object]
    $geoRows = New-Object System.Collections.Generic.List[object]
    $firewall = $null; $poolStats = $null; $resStats = $null
    $arm = @{}          # database name -> ARM database object
    $armServer = $null

    # ---- Azure Resource Manager: paused databases, retention, auditing, Defender, failover groups
    if ($script:azOk) {
        try {
            $list = @(Invoke-Az @('sql', 'server', 'list', '--query', "[?fullyQualifiedDomainName=='$full']"))
            if ($list.Count -gt 0 -and $list[0]) {
                $armServer = $list[0]
                foreach ($d in @(Invoke-Az @('sql', 'db', 'list', '-g', $armServer.resourceGroup, '-s', $armServer.name))) { if ($d) { $arm[$d.name] = $d } }
            } else {
                Add-Finding 'Monitoring' 'Info' 'Azure platform checks skipped' "The signed-in Azure CLI account cannot see $full (wrong subscription? az account set -s <subscription>)."
            }
        } catch { Add-NotChecked 'Azure Resource Manager (az sql server list)' $_ }
    }

    # ---- master: databases, 7-day utilisation, pools, firewall
    $master = $null
    try {
        $master = Open-Connection $full 'master'
    } catch {
        $msg = Get-SqlError $_
        Write-Warning "  Cannot connect: $msg"
        Add-Finding 'Monitoring' 'Critical' 'Could not connect to the server' $msg 'Check the server name, the sign-in and that the jump box IP is allowed through the server firewall.'
    }

    $names = @()
    if ($master) {
        try {
            $names = @((Invoke-Query $master $sqlDatabases).Rows | ForEach-Object { $_.name })
        } catch { Add-NotChecked 'database list (master)' $_ }
        try { $resStats = Invoke-Query $master $sqlResourceStats @{ Days = $DaysBack } } catch { Add-NotChecked 'compute history (sys.resource_stats)' $_ }
        try { $poolStats = Invoke-Query $master $sqlPoolStats @{ Days = $DaysBack } } catch { Add-NotChecked 'elastic pool history (sys.elastic_pool_resource_stats)' $_ }
        try { $firewall = Invoke-Query $master $sqlFirewall } catch { Add-NotChecked 'server firewall rules' $_ }
        $master.Close()
    }
    if ($Database.Count -gt 0) { $names = @($names | Where-Object { $Database -contains $_ }) }
    if ($ExcludeDatabase.Count -gt 0) { $names = @($names | Where-Object { $ExcludeDatabase -notcontains $_ }) }

    # ---- each database
    foreach ($db in $names) {
        $a = $arm[$db]
        $status = if ($a) { Get-Prop $a @('status') } else { $null }
        if ($status -eq 'Paused') {
            Write-Host "  $db - paused (serverless), not woken" -ForegroundColor DarkGray
            $dbRows.Add([pscustomobject]@{ Database = $db; Pool = ''; Objective = "$(Get-Prop $a @('currentServiceObjectiveName'))"; Edition = ''; UsedMB = $null; MaxSizeMB = $null
                                           AllocatedMB = $null; CompatLevel = $null; Stats = $null; LastHour = $null; Backups = @{}
                                           Note = 'Paused (serverless auto-pause); not connected to avoid resuming it' })
            continue
        }
        Write-Host "  $db"
        $row = [ordered]@{ Database = $db; Pool = ''; Objective = ''; Edition = ''; UsedMB = $null; MaxSizeMB = $null; AllocatedMB = $null; CompatLevel = $null
                           Stats = $null; LastHour = $null; Backups = @{}; Note = '' }
        $conn = $null
        try { $conn = Open-Connection $full $db }
        catch { Add-NotChecked "database $db (connect)" $_; $row.Note = 'Could not connect'; $dbRows.Add([pscustomobject]$row); continue }
        try {
            try {
                $p = (Invoke-Query $conn $sqlDbProps).Rows[0]
                $row.Edition = "$($p.Edition)"; $row.Objective = "$($p.ServiceObjective)"
                if ($p.MaxSizeMB -isnot [DBNull]) { $row.MaxSizeMB = [long]$p.MaxSizeMB }
                if ($p.UsedMB -isnot [DBNull]) { $row.UsedMB = [long]$p.UsedMB }
                if ($p.AllocatedMB -isnot [DBNull]) { $row.AllocatedMB = [long]$p.AllocatedMB }
                $row.CompatLevel = $p.CompatLevel
                if ($p.IsEncrypted -is [bool] -and -not $p.IsEncrypted) {
                    Add-Finding 'Security' 'Critical' "Transparent data encryption is off: $db" 'The database files and backups are not encrypted at rest.' 'Turn TDE back on (it is on by default in Azure SQL Database) unless there is a documented reason.'
                }
                if ($p.CompatLevel -is [int] -and $p.CompatLevel -lt 150) {
                    Add-Finding 'Service' 'Info' "Old compatibility level: $db ($($p.CompatLevel))" 'Newer query optimiser features are not being used.' 'Test at a newer compatibility level (Query Store makes it easy to spot and fix regressions).'
                }
            } catch { Add-NotChecked "size and service objective of $db" $_ }
            try { $pool = Invoke-Query $conn $sqlPool; if ($pool.Rows.Count -gt 0 -and $pool.Rows[0][0] -isnot [DBNull]) { $row.Pool = "$($pool.Rows[0][0])" } } catch { }
            try { $row.LastHour = (Invoke-Query $conn $sqlLastHour).Rows[0] } catch { Add-NotChecked "recent utilisation of $db (sys.dm_db_resource_stats)" $_ }

            # backups: what Azure has taken and still holds (point-in-time restore window)
            try {
                foreach ($b in (Invoke-Query $conn $sqlBackups).Rows) { $row.Backups["$($b.backup_type)"] = $b }
            } catch { Add-NotChecked "automated backups of $db (sys.dm_database_backups)" $_ }

            try {
                foreach ($g in (Invoke-Query $conn $sqlGeo).Rows) {
                    $geoRows.Add([pscustomobject]@{ Database = $db; Partner = "$($g.partner_server)/$($g.partner_database)"; Role = "$($g.role_desc)"
                                                    State = "$($g.replication_state_desc)"; LagSec = $g.replication_lag_sec; Last = $g.last_replication
                                                    Readable = "$($g.secondary_allow_connections_desc)" })
                }
            } catch { Add-NotChecked "geo-replication of $db" $_ }

            try {
                $qs = Invoke-Query $conn $sqlQueryStoreState
                if ($qs.Rows.Count -gt 0) {
                    $q = $qs.Rows[0]
                    if ("$($q.actual_state_desc)" -ne 'READ_WRITE') {
                        Add-Finding 'Queries' 'Warning' "Query Store not capturing: $db" "Query Store is $($q.actual_state_desc) (wanted $($q.desired_state_desc); reason code $($q.readonly_reason); $($q.current_storage_size_mb) of $($q.max_storage_size_mb) MB used)." 'Query Performance Insight and automatic tuning depend on Query Store. Raise its max size or clean it up, and set it back to READ_WRITE.'
                    }
                }
                foreach ($t in (Invoke-Query $conn $sqlTopQueries @{ Days = $DaysBack; IncludeText = [int][bool]$IncludeQueryText }).Rows) {
                    $queries.Add([pscustomobject]@{ Database = $db; QueryId = $t.query_id; Object = "$($t.ObjectName)"; Executions = $t.Executions
                                                    CpuMs = [long]$t.TotalCpuMs; AvgMs = $t.AvgDurationMs; Reads = $t.LogicalReads; Text = "$($t.QueryText)" })
                }
            } catch { Add-NotChecked "Query Store in $db" $_ }

            try {
                $s = (Invoke-Query $conn $sqlSecurity).Rows[0]
                if ([int]$s.GuestConnect -gt 0) { Add-Finding 'Security' 'Warning' "Guest user enabled: $db" 'The guest user has CONNECT, so any login on the server can use this database.' 'REVOKE CONNECT FROM guest in this database.' }
                if ("$($s.DbOwners)") { Add-Finding 'Security' 'Info' "db_owner members: $db" "$($s.DbOwners)" 'Confirm each still needs full control of the database.' }
                if ([int]$s.PasswordUsers -gt 0) { Add-Finding 'Security' 'Info' "Contained users with passwords: $db ($($s.PasswordUsers))" 'Users that sign in with a database password are managed per database, outside Microsoft Entra ID.' 'Prefer Entra ID users where possible, so leavers are removed centrally.' }
            } catch { Add-NotChecked "security settings of $db" $_ }
            try {
                foreach ($r in (Invoke-Query $conn $sqlDbFirewall).Rows) {
                    Add-Finding 'Security' 'Info' "Database-level firewall rule: $db / $($r.name)" "$($r.start_ip_address) - $($r.end_ip_address)" 'Database-level rules are easy to overlook; confirm it is still needed.'
                }
            } catch { Add-NotChecked "database firewall rules of $db" $_ }

            try {
                $tu = (Invoke-Query $conn $sqlTuning).Rows[0]
                if ($tu.Recommendations -isnot [DBNull] -and [int]$tu.Recommendations -gt 0) {
                    Add-Finding 'Queries' 'Info' "Automatic tuning recommendations: $db ($($tu.Recommendations))" "Automatic tuning: $($tu.Options)." 'Review the recommendations (Azure portal > Performance recommendations) or enable FORCE_LAST_GOOD_PLAN.'
                }
            } catch { }
        }
        finally { $conn.Close() }

        if ($resStats) { $row.Stats = @($resStats.Rows | Where-Object { $_.DatabaseName -eq $db }) | Select-Object -First 1 }
        $dbRows.Add([pscustomobject]$row)
    }

    # ---- findings from the numbers
    $reservedHint = $false
    $poolCandidates = @()
    foreach ($d in $dbRows) {
        $st = $d.Stats
        $label = $d.Database + $(if ($d.Pool) { " (pool $($d.Pool))" } else { '' })
        if ($d.UsedMB -and $d.MaxSizeMB -and $d.MaxSizeMB -gt 0) {
            $pct = [math]::Round(100.0 * $d.UsedMB / $d.MaxSizeMB, 1)
            if ($pct -ge 90) { Add-Finding 'Storage' 'Critical' "Database close to its size limit: $($d.Database)" "$pct% used ($([math]::Round($d.UsedMB / 1024, 1)) of $([math]::Round($d.MaxSizeMB / 1024, 1)) GB). At the limit, inserts and updates fail." 'Raise the max size (or the service tier), or archive data.' }
            elseif ($pct -ge 80) { Add-Finding 'Storage' 'Warning' "Database storage above 80%: $($d.Database)" "$pct% used ($([math]::Round($d.UsedMB / 1024, 1)) of $([math]::Round($d.MaxSizeMB / 1024, 1)) GB)." 'Plan a max size increase before it fills.' }
        }
        if ($st -and -not $d.Pool) {
            $hotPct = if ($st.Samples -gt 0) { 100.0 * $st.HotSamples / $st.Samples } else { 0 }
            if ($hotPct -ge 10) { Add-Finding 'Compute' 'Critical' "Throttled often: $label" "At its limit (95%+ CPU, data IO or log write) for $([math]::Round($hotPct, 0))% of the week ($($st.HotSamples) five-minute intervals)." 'Queries are being slowed by the service tier. Tune the top queries or scale up.' }
            elseif ($st.HotSamples -ge 6) { Add-Finding 'Compute' 'Warning' "Hit its compute limit: $label" "At 95%+ CPU, data IO or log write for $($st.HotSamples * 5) minutes during the week (peak CPU $($st.MaxCpu)%)." 'Check what was running at those times; scale up if it recurs.' }
            if ($st.MaxWorkers -isnot [DBNull] -and $st.MaxWorkers -ge 80) { Add-Finding 'Compute' 'Warning' "Worker threads near the limit: $label" "Peak $($st.MaxWorkers)% of the tier's worker limit. At 100%, new requests are rejected." 'Look for blocking or long-running queries; a higher tier raises the limit.' }
            if ($st.MaxSessions -isnot [DBNull] -and $st.MaxSessions -ge 80) { Add-Finding 'Compute' 'Warning' "Sessions near the limit: $label" "Peak $($st.MaxSessions)% of the tier's session limit." 'Check application connection pooling.' }

            $serverless = $d.Objective -match '_S_'
            if (-not $serverless -and $st.Samples -ge 288 -and $st.P95Peak -isnot [DBNull] -and $st.P95Peak -lt 20 -and $d.Objective -notin @('Basic', 'S0', 'GP_S_Gen5_1')) {
                Add-Finding 'Cost' 'Info' "Appears over-provisioned: $($d.Database) ($($d.Objective))" "95% of the time it used under $($st.P95Peak)% of its compute (average CPU $($st.AvgCpu)%)." 'A smaller tier, serverless (if it has idle periods) or an elastic pool could cost less. Molehill Data Services can model the options.'
                $poolCandidates += $d.Database
            }
            if ($serverless -and $st.AvgCpu -isnot [DBNull] -and $st.AvgCpu -ge 50) {
                Add-Finding 'Cost' 'Info' "Serverless database busy most of the time: $($d.Database)" "Average CPU $($st.AvgCpu)% of its maximum; it rarely pauses." 'Provisioned compute is usually cheaper for a database that is busy all day.'
            }
            if (-not $serverless -and $d.Objective -match '^(GP|BC|HS)_') { $reservedHint = $true }
        }
        # backups (Azure-managed)
        # (nothing visible means Hyperscale, which uses snapshots, or no permission - reported under Monitoring)
        $fullBk = $d.Backups['D']; $logBk = $d.Backups['L']
        if ($fullBk -and ([datetime]$fullBk.LastFinish) -lt $now.AddDays(-8)) {
            Add-Finding 'Backups' 'Warning' "No recent automated full backup: $($d.Database)" "Last full backup finished $(Format-Date $fullBk.LastFinish)." 'Azure normally takes a full backup weekly. Raise a support case with Microsoft if this continues.'
        }
        if ($logBk -and ([datetime]$logBk.LastFinish) -lt $now.AddHours(-2)) {
            Add-Finding 'Backups' 'Warning' "No recent log backup: $($d.Database)" "Last log backup finished $(Format-Date $logBk.LastFinish)." 'Azure takes log backups every 5-10 minutes; point-in-time restore may be limited.'
        }
    }
    if ($poolCandidates.Count -ge 2) {
        Add-Finding 'Cost' 'Info' 'Candidates for an elastic pool' "Lightly used single databases on this server: $($poolCandidates -join ', ')." 'Databases whose busy times do not overlap can share an elastic pool, often for less than their separate tiers.'
    }
    if ($reservedHint) {
        Add-Finding 'Cost' 'Info' 'Reserved capacity' 'This server has provisioned vCore databases.' 'Compute that runs all month can be bought as 1- or 3-year Azure reserved capacity at a substantial discount.'
    }

    if ($poolStats) {
        foreach ($p in $poolStats.Rows) {
            $hotPct = if ($p.Samples -gt 0) { 100.0 * $p.HotSamples / $p.Samples } else { 0 }
            if ($hotPct -ge 10) { Add-Finding 'Compute' 'Critical' "Elastic pool throttled often: $($p.PoolName)" "At its limit for $([math]::Round($hotPct, 0))% of the week." 'Tune the busiest databases in the pool or add eDTUs / vCores.' }
            elseif ($p.HotSamples -ge 6) { Add-Finding 'Compute' 'Warning' "Elastic pool hit its compute limit: $($p.PoolName)" "At 95%+ for $($p.HotSamples * 5) minutes during the week." 'Check which databases were busy at those times.' }
            if ($p.MaxStoragePct -isnot [DBNull] -and $p.MaxStoragePct -ge 90) { Add-Finding 'Storage' 'Critical' "Elastic pool storage nearly full: $($p.PoolName)" "Peak $($p.MaxStoragePct)% of $([math]::Round($p.StorageLimitMB / 1024, 0)) GB." 'Increase the pool max size before databases stop accepting writes.' }
            elseif ($p.MaxStoragePct -isnot [DBNull] -and $p.MaxStoragePct -ge 80) { Add-Finding 'Storage' 'Warning' "Elastic pool storage above 80%: $($p.PoolName)" "Peak $($p.MaxStoragePct)% of $([math]::Round($p.StorageLimitMB / 1024, 0)) GB." 'Plan a pool max size increase.' }
            if ($p.MaxWorkers -isnot [DBNull] -and $p.MaxWorkers -ge 80) { Add-Finding 'Compute' 'Warning' "Elastic pool worker threads near the limit: $($p.PoolName)" "Peak $($p.MaxWorkers)%." 'Look for blocking or long-running queries in the pool.' }
            if ($p.Samples -ge 288 -and $p.P95Peak -isnot [DBNull] -and $p.P95Peak -lt 20) { Add-Finding 'Cost' 'Info' "Elastic pool appears over-provisioned: $($p.PoolName)" "95% of the time it used under $($p.P95Peak)% of its compute." 'A smaller pool could cost less.' }
        }
    }

    foreach ($g in $geoRows) {
        if ($g.State -notin @('CATCH_UP', 'SEEDING')) { Add-Finding 'Replication' 'Critical' "Geo-replication not healthy: $($g.Database)" "Link to $($g.Partner) ($($g.Role)) is $($g.State)." 'A failover now could lose data or fail. Check the link in the Azure portal.' }
        elseif ($g.LagSec -isnot [DBNull] -and $null -ne $g.LagSec -and [int]$g.LagSec -gt 60) { Add-Finding 'Replication' 'Warning' "Geo-replication lag: $($g.Database)" "$($g.LagSec) seconds behind on the link to $($g.Partner)." 'Sustained lag means more data lost in an unplanned failover; check log write rate and the secondary''s tier.' }
    }

    if ($firewall) {
        foreach ($r in $firewall.Rows) {
            $range = "$($r.start_ip_address) - $($r.end_ip_address)"
            if ($r.start_ip_address -eq '0.0.0.0' -and $r.end_ip_address -eq '0.0.0.0') {
                Add-Finding 'Security' 'Warning' "Firewall allows all Azure services ($($r.name))" 'The "Allow Azure services and resources to access this server" rule lets connections in from any Azure subscription, not just the client''s.' 'Prefer private endpoints or specific rules; if it must stay, rely on strong authentication (Entra ID).'
            } elseif ($r.start_ip_address -eq '0.0.0.0' -and $r.end_ip_address -eq '255.255.255.255') {
                Add-Finding 'Security' 'Critical' "Firewall open to the whole internet ($($r.name))" "Rule $range allows every IP address." 'Remove it and allow only the addresses that need access.'
            } else {
                try {
                    $s = [System.Net.IPAddress]::Parse($r.start_ip_address).GetAddressBytes(); [array]::Reverse($s)
                    $e = [System.Net.IPAddress]::Parse($r.end_ip_address).GetAddressBytes(); [array]::Reverse($e)
                    $size = [BitConverter]::ToUInt32($e, 0) - [BitConverter]::ToUInt32($s, 0) + 1
                    if ($size -gt 65536) { Add-Finding 'Security' 'Warning' "Wide firewall rule ($($r.name))" "$range covers $size addresses." 'Narrow it to the addresses that need access.' }
                } catch { }
            }
        }
    }

    # ---- elastic jobs
    $jobRows = $null
    if ($ElasticJobServer -and $ElasticJobDatabase) {
        try {
            $jc = Open-Connection $ElasticJobServer $ElasticJobDatabase
            try { $jobRows = Invoke-Query $jc $sqlElasticJobs @{ Days = $DaysBack } } finally { $jc.Close() }
            foreach ($j in $jobRows.Rows) {
                Add-Finding 'Jobs' 'Warning' "Elastic job $($j.lifecycle): $($j.job_name)" "$($j.Failures) execution(s), last $(Format-Date $j.LastFailure) on $($j.Targets). $($j.LastMessage)" 'Review the job execution history in the job database.'
            }
        } catch { Add-NotChecked "elastic jobs ($ElasticJobServer/$ElasticJobDatabase)" $_ }
    }

    # ---- Azure Resource Manager checks
    $armNotes = New-Object System.Collections.Generic.List[string]
    if ($armServer) {
        $rg = $armServer.resourceGroup; $sn = $armServer.name
        foreach ($d in $dbRows) {
            try {
                $str = Invoke-Az @('sql', 'db', 'str-policy', 'show', '-g', $rg, '-s', $sn, '-n', $d.Database)
                $days = Get-Prop $str @('retentionDays')
                $d | Add-Member -NotePropertyName RetentionDays -NotePropertyValue $days -Force
                if ($days -and [int]$days -lt 7) { Add-Finding 'Backups' 'Warning' "Short point-in-time retention: $($d.Database)" "Point-in-time restore goes back $days days." 'The default is 7 days. Confirm this matches how far back the client may need to restore.' }
            } catch { $armNotes.Add("Retention policy of $($d.Database): $_") }
            try {
                $ltr = Invoke-Az @('sql', 'db', 'ltr-policy', 'show', '-g', $rg, '-s', $sn, '-n', $d.Database)
                $w = Get-Prop $ltr @('weeklyRetention'); $m = Get-Prop $ltr @('monthlyRetention'); $y = Get-Prop $ltr @('yearlyRetention')
                $parts = @(); if ($w -and $w -ne 'PT0S') { $parts += "weekly $w" }; if ($m -and $m -ne 'PT0S') { $parts += "monthly $m" }; if ($y -and $y -ne 'PT0S') { $parts += "yearly $y" }
                $d | Add-Member -NotePropertyName Ltr -NotePropertyValue $(if ($parts.Count) { $parts -join ', ' } else { 'none' }) -Force
            } catch { $armNotes.Add("Long-term retention of $($d.Database): $_") }
        }
        if (@($dbRows | Where-Object { $_.PSObject.Properties['Ltr'] -and $_.Ltr -eq 'none' }).Count -gt 0) {
            Add-Finding 'Backups' 'Info' 'No long-term retention on some databases' (@($dbRows | Where-Object { $_.PSObject.Properties['Ltr'] -and $_.Ltr -eq 'none' } | ForEach-Object { $_.Database }) -join ', ') 'Fine unless backups must be kept beyond the point-in-time window (e.g. monthly or yearly for compliance).'
        }
        try {
            $audit = Invoke-Az @('sql', 'server', 'audit-policy', 'show', '-g', $rg, '-n', $sn)
            if ((Get-Prop $audit @('state')) -ne 'Enabled') { Add-Finding 'Security' 'Warning' 'Server auditing is off' 'No audit trail of who did what on this server.' 'Enable auditing to Log Analytics or a storage account (Azure portal > Auditing).' }
        } catch { $armNotes.Add("Auditing: $_") }
        try {
            $atp = Invoke-Az @('sql', 'server', 'advanced-threat-protection-setting', 'show', '-g', $rg, '-n', $sn)
            if ((Get-Prop $atp @('state')) -ne 'Enabled') { Add-Finding 'Security' 'Warning' 'Microsoft Defender for SQL is off' 'Threat detection (SQL injection, unusual access, brute force) is not running for this server.' 'Enable Microsoft Defender for SQL (billed by Azure per server).' }
        } catch { $armNotes.Add("Defender for SQL: $_") }
        try {
            $alerts = @(Invoke-Az @('security', 'alert', 'list')) | Where-Object { $_ -and (($_ | ConvertTo-Json -Depth 6 -Compress) -match [regex]::Escape($sn)) }
            foreach ($al in $alerts) {
                $when = Get-Prop $al @('timeGeneratedUtc', 'properties.timeGeneratedUtc', 'startTimeUtc', 'properties.startTimeUtc')
                $state = Get-Prop $al @('status', 'properties.status', 'state', 'properties.state')
                if ($when -and ([datetime]$when) -lt $now.AddDays(-$DaysBack)) { continue }
                if ($state -and "$state" -in @('Dismissed', 'Resolved')) { continue }
                $sev = Get-Prop $al @('severity', 'properties.severity', 'reportedSeverity', 'properties.reportedSeverity')
                $name = Get-Prop $al @('alertDisplayName', 'properties.alertDisplayName', 'displayName')
                Add-Finding 'Security' $(if ("$sev" -eq 'High') { 'Critical' } else { 'Warning' }) "Defender for SQL alert: $name" "$sev severity, $when. $(Get-Prop $al @('description', 'properties.description'))" 'Investigate in Microsoft Defender for Cloud; raise a Critical ticket if it looks genuine.'
            }
        } catch { $armNotes.Add("Defender alerts: $_") }
        try {
            foreach ($fg in @(Invoke-Az @('sql', 'failover-group', 'list', '-g', $rg, '-s', $sn))) {
                if (-not $fg) { continue }
                $partners = @(Get-Prop $fg @('partnerServers')) | ForEach-Object { "$(($_.id -split '/')[-1]) ($($_.replicationRole))" }
                $geoRows.Add([pscustomobject]@{ Database = "Failover group $($fg.name)"; Partner = ($partners -join ', '); Role = "$(Get-Prop $fg @('replicationRole'))"
                                                State = "$(Get-Prop $fg @('replicationState'))"; LagSec = $null; Last = $null
                                                Readable = "Failover policy: $(Get-Prop $fg @('readWriteEndpoint.failoverPolicy'))" })
            }
        } catch { $armNotes.Add("Failover groups: $_") }
        if ($armNotes.Count -gt 0) { Add-Finding 'Monitoring' 'Info' 'Some Azure platform checks could not run' (($armNotes | Select-Object -First 5) -join ' | ') 'Usually the signed-in account needs Reader on the resource group.' }
    } elseif (-not $AzurePlatformChecks) {
        Add-Finding 'Monitoring' 'Info' 'Azure platform settings not checked this week' 'Retention policies, auditing, Defender for SQL and failover groups are Azure settings, read with -AzurePlatformChecks (Azure CLI).' 'Run with -AzurePlatformChecks from a machine signed in to the Azure CLI.'
    }

    # ---- HTML
    $sevRank = @{ Critical = 1; Warning = 2; Info = 3 }
    $sorted = @($findings | Sort-Object @{ Expression = { $sevRank[$_.Severity] } }, Section, Item)
    $crit = @($findings | Where-Object Severity -eq 'Critical').Count
    $warn = @($findings | Where-Object Severity -eq 'Warning').Count
    $info = @($findings | Where-Object Severity -eq 'Info').Count
    $rag = if ($crit) { 'Red' } elseif ($warn) { 'Amber' } else { 'Green' }
    $ragText = @{ Red = 'Action required'; Amber = 'Attention recommended'; Green = 'No issues found' }[$rag]
    $sections = 'Service', 'Compute', 'Storage', 'Backups', 'Queries', 'Replication', 'Security', 'Jobs', 'Cost', 'Monitoring'

    $sb = New-Object System.Text.StringBuilder
    function W([string]$s) { [void]$sb.Append($s) }
    W @'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Molehill Watch - Azure SQL Database</title><style>
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.5}
.wrap{max-width:1040px;margin:0 auto;padding:24px}
.hero{background:#231F20;color:#FFFFFF;padding:28px 32px}
.brand{font-size:28px;font-weight:700;letter-spacing:-0.01em}
.tag{color:#44C8F5;font-size:14px}
.hero h1{font-size:20px;margin:20px 0 4px;font-weight:600}
.meta{color:#BFBBBA;font-size:13px}
.rag{display:inline-block;margin-top:16px;padding:8px 16px;font-weight:700;font-size:15px}
.rag-red{background:#D64545;color:#FFFFFF}.rag-amber{background:#F2A93B;color:#231F20}.rag-green{background:#3FA66B;color:#FFFFFF}
h2{font-size:18px;border-bottom:3px solid #44C8F5;padding-bottom:6px;margin:34px 0 12px}
table{width:100%;border-collapse:collapse;background:#FFFFFF;font-size:13px;margin-bottom:10px}
th{background:#231F20;color:#FFFFFF;text-align:left;padding:8px 10px;font-weight:600}
td{padding:7px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}
td.critical{background:#D64545;color:#FFFFFF;font-weight:600;white-space:nowrap}
td.warning{background:#F9D58C;font-weight:600;white-space:nowrap}
td.info{background:#DDF3FC;white-space:nowrap}
td.ok{background:#D5EEDD;white-space:nowrap}
td.num{text-align:right;white-space:nowrap}
td.code{font-family:Consolas,monospace;font-size:12px;color:#55504F;word-break:break-word}
.note{color:#7A7473;font-size:12px}
.foot{margin-top:40px;padding-top:12px;border-top:1px solid #E2DEDD;color:#7A7473;font-size:12px}
</style></head><body><div class="wrap">
<div class="hero"><div class="brand">Molehill Watch</div><div class="tag">Catching molehills before they're mountains</div>
<h1>Weekly Azure SQL Database Status Report</h1>
'@
    $period = "$($now.AddDays(-$DaysBack).ToString('dd MMM yyyy', [Globalization.CultureInfo]::InvariantCulture)) to $($now.ToString('dd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)) UTC"
    W "<div class=""meta"">$(Encode $(if ($ClientName) { $ClientName } else { '(client name not set)' })) &#183; $(Encode $full) &#183; $period</div>"
    W "<div class=""rag rag-$($rag.ToLower())"">$($rag): $ragText &#8212; $crit critical, $warn warning(s)</div></div>"

    W '<h2>At a glance</h2><table><tr><th>Area</th><th>Status</th><th>Critical</th><th>Warnings</th><th>Info</th></tr>'
    foreach ($sec in $sections) {
        $c = @($findings | Where-Object { $_.Section -eq $sec -and $_.Severity -eq 'Critical' }).Count
        $w = @($findings | Where-Object { $_.Section -eq $sec -and $_.Severity -eq 'Warning' }).Count
        $i = @($findings | Where-Object { $_.Section -eq $sec -and $_.Severity -eq 'Info' }).Count
        $st = if ($c) { '<td class="critical">Red</td>' } elseif ($w) { '<td class="warning">Amber</td>' } else { '<td class="ok">Green</td>' }
        W "<tr><td>$sec</td>$st<td class=""num"">$c</td><td class=""num"">$w</td><td class=""num"">$i</td></tr>"
    }
    W '</table>'

    W '<h2>Findings and recommendations</h2><table><tr><th>Severity</th><th>Area</th><th>Finding</th><th>Detail</th><th>Recommendation</th></tr>'
    if ($sorted.Count -eq 0) { W '<tr><td colspan="5" class="ok">No issues found this week.</td></tr>' }
    foreach ($f in $sorted) { W "<tr><td class=""$($f.Severity.ToLower())"">$($f.Severity)</td><td>$($f.Section)</td><td>$(Encode $f.Item)</td><td>$(Encode $f.Detail)</td><td>$(Encode $f.Recommendation)</td></tr>" }
    W '</table><p class="note">Where remediation is recommended, any work beyond the included monthly support time will be scoped and agreed with you before it is carried out.</p>'

    W '<h2>Databases</h2><table><tr><th>Database</th><th>Tier</th><th>Storage used</th><th>CPU avg / peak</th><th>At limit</th><th>Last full backup</th><th>Last log backup</th><th>Earliest restore point</th><th>Note</th></tr>'
    foreach ($d in $dbRows) {
        $st = $d.Stats
        $storage = if ($d.UsedMB -and $d.MaxSizeMB) { "$([math]::Round($d.UsedMB / 1024, 1)) of $([math]::Round($d.MaxSizeMB / 1024, 1)) GB ($([math]::Round(100.0 * $d.UsedMB / $d.MaxSizeMB, 0))%)" } elseif ($d.UsedMB) { "$([math]::Round($d.UsedMB / 1024, 1)) GB" } else { '' }
        $cpu = if ($st) { "$($st.AvgCpu)% / $($st.MaxCpu)%" } else { '' }
        $hot = if ($st) { "$($st.HotSamples * 5) min" } else { '' }
        $tier = $d.Objective + $(if ($d.Pool) { " (pool $($d.Pool))" } else { '' })
        $fullB = $d.Backups['D']; $logB = $d.Backups['L']
        $earliest = if ($fullB) { Format-Date $fullB.EarliestStart } else { '' }
        if ($d.PSObject.Properties['RetentionDays'] -and $d.RetentionDays) { $earliest += " (PITR $($d.RetentionDays) days)" }
        if ($d.PSObject.Properties['Ltr'] -and $d.Ltr -and $d.Ltr -ne 'none') { $earliest += "; LTR $($d.Ltr)" }
        W "<tr><td>$(Encode $d.Database)</td><td>$(Encode $tier)</td><td>$storage</td><td class=""num"">$cpu</td><td class=""num"">$hot</td>"
        W "<td>$(if ($fullB) { Format-Date $fullB.LastFinish } else { '' })</td><td>$(if ($logB) { Format-Date $logB.LastFinish } else { '' })</td><td>$(Encode $earliest)</td><td>$(Encode $d.Note)</td></tr>"
    }
    if ($dbRows.Count -eq 0) { W '<tr><td colspan="9">No databases were read.</td></tr>' }
    W "</table><p class=""note"">CPU and 'at limit' cover the last $DaysBack days in five-minute intervals (sys.resource_stats); 'at limit' is time at 95%+ of CPU, data IO or log write. Backups are the automated backups Azure holds for point-in-time restore.</p>"

    if ($poolStats -and $poolStats.Rows.Count -gt 0) {
        W '<h2>Elastic pools</h2><table><tr><th>Pool</th><th>Limit</th><th>CPU avg / peak</th><th>95th percentile</th><th>Peak storage</th><th>At limit</th></tr>'
        foreach ($p in $poolStats.Rows) {
            $limit = if ($p.DtuLimit -isnot [DBNull] -and $p.DtuLimit) { "$($p.DtuLimit) eDTU" } elseif ($p.CpuLimit -isnot [DBNull]) { "$($p.CpuLimit) vCores" } else { '' }
            W "<tr><td>$(Encode $p.PoolName)</td><td>$limit</td><td class=""num"">$($p.AvgCpu)% / $($p.MaxCpu)%</td><td class=""num"">$($p.P95Peak)%</td><td class=""num"">$($p.MaxStoragePct)%</td><td class=""num"">$($p.HotSamples * 5) min</td></tr>"
        }
        W '</table>'
    }

    W '<h2>Top queries by CPU (Query Store)</h2><table><tr><th>Database</th><th>Query</th><th>Executions</th><th>Total CPU</th><th>Avg duration</th><th>Logical reads</th></tr>'
    $top = @($queries | Sort-Object CpuMs -Descending | Select-Object -First 10)
    if ($top.Count -eq 0) { W '<tr><td colspan="6">No Query Store data for the period.</td></tr>' }
    foreach ($q in $top) {
        $what = "query_id $($q.QueryId)" + $(if ($q.Object) { " in $($q.Object)" } else { '' })
        $textCell = if ($IncludeQueryText -and $q.Text) { "<br><span class=""note"">$(Encode $q.Text)</span>" } else { '' }
        W "<tr><td>$(Encode $q.Database)</td><td class=""code"">$(Encode $what)$textCell</td><td class=""num"">$('{0:N0}' -f $q.Executions)</td><td class=""num"">$('{0:N1}' -f ($q.CpuMs / 1000.0)) s</td><td class=""num"">$($q.AvgMs) ms</td><td class=""num"">$('{0:N0}' -f $q.Reads)</td></tr>"
    }
    W '</table><p class="note">The same data drives Query Performance Insight in the Azure portal. Query text is left out unless the report is run with -IncludeQueryText, because it can contain personal data.</p>'

    W '<h2>Geo-replication and failover groups</h2><table><tr><th>Database / group</th><th>Partner</th><th>Role</th><th>State</th><th>Lag</th><th>Readable secondary / policy</th></tr>'
    if ($geoRows.Count -eq 0) { W '<tr><td colspan="6">No geo-replication links.</td></tr>' }
    foreach ($g in $geoRows) {
        $lag = if ($null -ne $g.LagSec -and $g.LagSec -isnot [DBNull]) { "$($g.LagSec) s" } else { '' }
        W "<tr><td>$(Encode $g.Database)</td><td>$(Encode $g.Partner)</td><td>$(Encode $g.Role)</td><td>$(Encode $g.State)</td><td class=""num"">$lag</td><td>$(Encode $g.Readable)</td></tr>"
    }
    W '</table>'

    W '<h2>Server firewall rules</h2><table><tr><th>Rule</th><th>From</th><th>To</th></tr>'
    if (-not $firewall -or $firewall.Rows.Count -eq 0) { W '<tr><td colspan="3">None (or not visible to this account).</td></tr>' }
    else { foreach ($r in $firewall.Rows) { W "<tr><td>$(Encode $r.name)</td><td>$(Encode $r.start_ip_address)</td><td>$(Encode $r.end_ip_address)</td></tr>" } }
    W '</table>'

    if ($ElasticJobServer) {
        W '<h2>Elastic jobs</h2><table><tr><th>Job</th><th>Outcome</th><th>Count</th><th>Last</th><th>Targets</th></tr>'
        if (-not $jobRows -or $jobRows.Rows.Count -eq 0) { W '<tr><td colspan="5" class="ok">No failed job executions this period.</td></tr>' }
        else { foreach ($j in $jobRows.Rows) { W "<tr><td>$(Encode $j.job_name)</td><td>$(Encode $j.lifecycle)</td><td class=""num"">$($j.Failures)</td><td>$(Format-Date $j.LastFailure)</td><td>$(Encode $j.Targets)</td></tr>" } }
        W '</table>'
    }

    W "<div class=""foot"">Molehill Watch &#183; Azure SQL Database report generated $($now.ToString('dd MMM yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)) UTC by $(Encode $env:USERNAME) on $(Encode $env:COMPUTERNAME). Read-only: nothing was changed in Azure. Patching and platform maintenance are handled by Microsoft.</div>"
    W '</div></body></html>'

    $file = Join-Path $OutputFolder ("{0}_{1}.html" -f ($short -replace '[\\/:*?"<>|()]', '_'), $now.ToString('yyyy-MM-dd'))
    [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  $rag - $crit critical, $warn warning(s), $info info -> $file" -ForegroundColor $(@{ Red = 'Red'; Amber = 'Yellow'; Green = 'Green' }[$rag])
    $summary += [pscustomobject]@{ Server = $full; Databases = $dbRows.Count; Status = $rag; Critical = $crit; Warnings = $warn; Report = $file }
}

$summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if (@($summary | Where-Object Status -eq 'Red').Count -gt 0) { exit 2 }
exit 0
