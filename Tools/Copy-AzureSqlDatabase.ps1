#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'SqlServer'; ModuleVersion = '22.0.0' }

<#
.SYNOPSIS
    Copies an Azure SQL Database to one or more target logical servers and swaps it in
    place of the existing database on each.

.DESCRIPTION
    Molehill Data Services

    For each target server (all copies run in parallel server-side):
      1. Starts CREATE DATABASE ... AS COPY OF on the target server's master database.
      2. Polls until the copy is ONLINE, fails, or times out.
      3. Renames the existing target database to <TargetDatabase>-prev-<stamp>.
      4. Renames the copy to <TargetDatabase>.
      5. Drops the previous database (unless -KeepPrevious).

    If step 4 fails, step 3 is rolled back so the environment keeps its original database.

    Safe by default: without -Execute, preflight checks run (read-only) and the planned
    SQL is printed. Nothing is created, renamed or dropped.

.PARAMETER SourceServer
    Source logical server. Short name (sql-my-ser) or FQDN (sql-my-ser.database.windows.net).

.PARAMETER SourceDatabase
    Database to copy.

.PARAMETER TargetServer
    One or more target logical servers, one per environment.

.PARAMETER TargetDatabase
    Name the database should have on each target. Defaults to SourceDatabase.

.PARAMETER ServiceObjective
    Optional service objective for the copy, e.g. S2, GP_Gen5_2. Defaults to the source's.

.PARAMETER ElasticPool
    Optional elastic pool name on the target server. Cannot be combined with ServiceObjective.

.PARAMETER SqlCredential
    SQL authentication credential. If omitted, a Microsoft Entra ID access token from the
    current Az context is used (run Connect-AzAccount first).

.PARAMETER PollSeconds
    Seconds between status checks. Default 30.

.PARAMETER TimeoutMinutes
    Maximum wait for all copies. Default 240.

.PARAMETER KeepPrevious
    Keep the replaced database as <TargetDatabase>-prev-<stamp> instead of dropping it.

.PARAMETER Execute
    Actually run the copy, rename and drop. Without it the script is a dry run.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test, sql-oof-uat -TargetDatabase oof-web

    Dry run against three environments.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test -TargetDatabase oof-web `
        -ElasticPool pool-nonprod -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceServer,
    [Parameter(Mandatory)][string]$SourceDatabase,
    [Parameter(Mandatory)][string[]]$TargetServer,
    [string]$TargetDatabase = $SourceDatabase,
    [string]$ServiceObjective,
    [string]$ElasticPool,
    [pscredential]$SqlCredential,
    [ValidateRange(5, 600)][int]$PollSeconds = 30,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 240,
    [switch]$KeepPrevious,
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host ('{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}' -f (Get-Date), $Level, $Message) -ForegroundColor $colour
}

function Resolve-ServerName {
    param([string]$Name)
    $short = ($Name -split '\.')[0].ToLowerInvariant()
    $fqdn  = if ($Name -like '*.*') { $Name.ToLowerInvariant() } else { "$short.database.windows.net" }
    [pscustomobject]@{ Short = $short; Fqdn = $fqdn }
}

function ConvertTo-QuotedName {
    param([string]$Name)
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Get-SqlAccessToken {
    # Fetched per call so long-running copies outlive the token lifetime safely.
    $t = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($t.Token -is [securestring]) {
        ConvertFrom-SecureString -SecureString $t.Token -AsPlainText
    }
    else {
        $t.Token
    }
}

function Invoke-MasterQuery {
    param(
        [string]$Server,
        [string]$Query,
        [int]$Timeout = 60
    )
    $p = @{
        ServerInstance = $Server
        Database       = 'master'
        Query          = $Query
        QueryTimeout   = $Timeout
        Encrypt        = 'Mandatory'
        ErrorAction    = 'Stop'
    }
    if ($SqlCredential) { $p.Credential = $SqlCredential } else { $p.AccessToken = Get-SqlAccessToken }
    Invoke-Sqlcmd @p
}

function Test-DatabaseExists {
    param([string]$Server, [string]$Name)
    $r = Invoke-MasterQuery -Server $Server -Query "SELECT COUNT(*) AS n FROM sys.databases WHERE name = $(ConvertTo-SqlLiteral $Name);"
    [int]$r.n -gt 0
}

#endregion

#region Setup

$stamp    = Get-Date -Format 'yyyyMMddHHmm'
$source   = Resolve-ServerName $SourceServer
$copyName = "$TargetDatabase-copy-$stamp"
$prevName = "$TargetDatabase-prev-$stamp"

$qSource = '{0}.{1}' -f (ConvertTo-QuotedName $source.Short), (ConvertTo-QuotedName $SourceDatabase)
$qCopy   = ConvertTo-QuotedName $copyName
$qTarget = ConvertTo-QuotedName $TargetDatabase
$qPrev   = ConvertTo-QuotedName $prevName

if ($ServiceObjective -and $ElasticPool) {
    throw 'Specify either -ServiceObjective or -ElasticPool, not both.'
}

$withClause = ''
if ($ServiceObjective) {
    $withClause = " ( SERVICE_OBJECTIVE = '$($ServiceObjective.Replace("'", "''"))' )"
}
elseif ($ElasticPool) {
    $withClause = " ( SERVICE_OBJECTIVE = ELASTIC_POOL( name = $(ConvertTo-QuotedName $ElasticPool) ) )"
}

$createSql = "CREATE DATABASE $qCopy AS COPY OF $qSource$withClause;"

if (-not $SqlCredential -and -not (Get-AzContext)) {
    throw 'No -SqlCredential supplied and no Az context found. Run Connect-AzAccount first.'
}

$targets = $TargetServer |
    ForEach-Object { Resolve-ServerName $_ } |
    Sort-Object Fqdn -Unique |
    ForEach-Object {
        if ($_.Fqdn -eq $source.Fqdn -and $TargetDatabase -eq $SourceDatabase) {
            throw "Target $($_.Fqdn) / $TargetDatabase is the source database. Refusing to overwrite the source."
        }
        [pscustomobject]@{
            Server       = $_.Short
            Fqdn         = $_.Fqdn
            TargetExists = $false
            Status       = 'Pending'
            Message      = ''
            Started      = $null
            Finished     = $null
        }
    }

Write-Log ("Mode: {0}" -f ($Execute ? 'EXECUTE' : 'DRY RUN')) ($Execute ? 'WARN' : 'INFO')
Write-Log "Source: $($source.Fqdn) / $SourceDatabase"
Write-Log "Targets: $(($targets.Fqdn) -join ', ')  ->  $TargetDatabase"

#endregion

#region Preflight

Write-Log 'Preflight checks'

if (-not (Test-DatabaseExists -Server $source.Fqdn -Name $SourceDatabase)) {
    throw "Source database $SourceDatabase not found on $($source.Fqdn)."
}

foreach ($t in $targets) {
    try {
        if (Test-DatabaseExists -Server $t.Fqdn -Name $copyName) {
            throw "Copy name $copyName already exists."
        }
        $t.TargetExists = Test-DatabaseExists -Server $t.Fqdn -Name $TargetDatabase
        Write-Log ('{0}: reachable; {1} {2}' -f $t.Fqdn, $TargetDatabase,
            ($t.TargetExists ? 'exists and will be replaced' : 'does not exist and will be created'))
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Preflight: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Dry run

if (-not $Execute) {
    foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
        Write-Log "Planned SQL on $($t.Fqdn) (master):"
        $plan = @($createSql, '-- poll sys.databases / sys.dm_database_copies until ONLINE')
        if ($t.TargetExists) { $plan += "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" }
        $plan += "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;"
        if ($t.TargetExists -and -not $KeepPrevious) { $plan += "DROP DATABASE $qPrev;" }
        $plan | ForEach-Object { Write-Host "    $_" }
    }
    Write-Log 'Dry run complete. Re-run with -Execute to apply.' WARN
    return
}

#endregion

#region Start copies

foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
    try {
        Write-Log "$($t.Fqdn): starting copy as $copyName"
        Invoke-MasterQuery -Server $t.Fqdn -Query $createSql -Timeout 600 | Out-Null
        $t.Status  = 'Copying'
        $t.Started = Get-Date
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Start copy: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Wait for copies

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$pollSql  = @"
SELECT d.state_desc, c.percent_complete, c.error_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_copies AS c ON c.database_id = d.database_id
WHERE d.name = $(ConvertTo-SqlLiteral $copyName);
"@
$opSql = @"
SELECT TOP (1) operation, state_desc, error_desc
FROM sys.dm_operation_status
WHERE major_resource_id = $(ConvertTo-SqlLiteral $copyName)
ORDER BY start_time DESC;
"@

while ($targets | Where-Object Status -eq 'Copying') {

    foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
        try {
            $r = Invoke-MasterQuery -Server $t.Fqdn -Query $pollSql

            if (-not $r) {
                # Failed copies are dropped by Azure; look for the reason.
                $op     = Invoke-MasterQuery -Server $t.Fqdn -Query $opSql
                $detail = if ($op) { "$($op.operation) $($op.state_desc): $([string]$op.error_desc)" } else { 'no operation status recorded' }
                $t.Status  = 'Failed'
                $t.Message = "Copy database disappeared. $detail"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            elseif ($r.state_desc -eq 'ONLINE') {
                $t.Status   = 'Copied'
                $t.Finished = Get-Date
                Write-Log ('{0}: copy ONLINE after {1:hh\:mm\:ss}' -f $t.Fqdn, ($t.Finished - $t.Started)) OK
            }
            elseif ([string]$r.error_desc) {
                $t.Status  = 'Failed'
                $t.Message = "Copy error: $([string]$r.error_desc)"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            else {
                $pct = if ($r.percent_complete -is [DBNull]) { 'n/a' } else { '{0:N1}%' -f $r.percent_complete }
                Write-Log "$($t.Fqdn): $($r.state_desc)  $pct"
            }
        }
        catch {
            Write-Log "$($t.Fqdn): poll error, will retry: $($_.Exception.Message)" WARN
        }
    }

    if ((Get-Date) -gt $deadline) {
        foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
            $t.Status  = 'Failed'
            $t.Message = "Timed out after $TimeoutMinutes minutes. Copy $copyName may still be running server-side."
            Write-Log "$($t.Fqdn): $($t.Message)" ERROR
        }
        break
    }

    if ($targets | Where-Object Status -eq 'Copying') { Start-Sleep -Seconds $PollSeconds }
}

#endregion

#region Swap

foreach ($t in ($targets | Where-Object Status -eq 'Copied')) {
    $renamedOld = $false
    try {
        if ($t.TargetExists) {
            Write-Log "$($t.Fqdn): renaming $TargetDatabase to $prevName"
            Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" -Timeout 300 | Out-Null
            $renamedOld = $true
        }

        Write-Log "$($t.Fqdn): renaming $copyName to $TargetDatabase"
        Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null

        if ($renamedOld -and -not $KeepPrevious) {
            try {
                Write-Log "$($t.Fqdn): dropping $prevName"
                Invoke-MasterQuery -Server $t.Fqdn -Query "DROP DATABASE $qPrev;" -Timeout 600 | Out-Null
                $t.Message = 'Replaced; previous database dropped.'
            }
            catch {
                $t.Message = "Replaced, but drop of $prevName failed: $($_.Exception.Message)"
                Write-Log "$($t.Fqdn): $($t.Message)" WARN
            }
        }
        elseif ($renamedOld) {
            $t.Message = "Replaced; previous database kept as $prevName."
        }
        else {
            $t.Message = 'Created.'
        }

        $t.Status = 'Done'
        Write-Log "$($t.Fqdn): $($t.Message)" OK
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Swap: $($_.Exception.Message)"
        if ($renamedOld) {
            try {
                Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qPrev MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null
                $t.Message += " Original rename rolled back; $copyName left in place."
            }
            catch {
                $t.Message += " ROLLBACK FAILED: original database is currently named $prevName."
            }
        }
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Summary

Write-Log 'Run summary'
$targets |
    Select-Object Fqdn, Status,
        @{ n = 'CopyTime'; e = { if ($_.Started -and $_.Finished) { '{0:hh\:mm\:ss}' -f ($_.Finished - $_.Started) } } },
        Message |
    Format-Table -AutoSize -Wrap

if ($targets | Where-Object Status -ne 'Done') { exit 1 }

#endregion
