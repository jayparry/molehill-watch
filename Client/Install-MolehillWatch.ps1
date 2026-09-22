<#
.SYNOPSIS
    Installs Molehill Watch monitoring on one or more SQL Server instances.

.DESCRIPTION
    Molehill Watch - SQL Server Support Package (Molehill Data Services).
    For each instance this script:
      1. checks the connection, version and sysadmin rights
      2. prepares the target database - MolehillWatch by default (created if missing), or an existing
         DBA database given with -Database (never created or reconfigured) - and runs
         MolehillWatch_Install.sql into its "mw" schema (collectors, report, Agent jobs)
      3. sets the client name / report e-mail settings
      4. optionally grants read access to the Molehill Data Services login
      5. loads Microsoft's latest SQL Server / Windows Server build data for the patching checks
      6. optionally schedules collection with Windows Task Scheduler (Express edition)
      7. runs a first collection and builds a baseline weekly report

    No modules required - works in Windows PowerShell 5.1 and PowerShell 7.
    Safe to re-run (upgrades in place and keeps collected data).

.EXAMPLE
    .\Install-MolehillWatch.ps1 -SqlInstance SQL01 -ClientName "Contoso Ltd"

.EXAMPLE
    .\Install-MolehillWatch.ps1 -SqlInstance SQL01,SQL02\SALES -ClientName "Contoso Ltd" `
        -MolehillLogin "CONTOSO\svc-molehill" -ReportEmailProfile "DBA Mail" -ReportEmailRecipients "it@contoso.co.uk"

.EXAMPLE
    # The client already has a DBA database: install into it instead of creating MolehillWatch
    .\Install-MolehillWatch.ps1 -SqlInstance SQL01 -ClientName "Contoso Ltd" -Database DBA

.EXAMPLE
    # SQL authentication instead of Windows authentication
    .\Install-MolehillWatch.ps1 -SqlInstance 10.0.0.5 -ClientName "Contoso Ltd" -SqlCredential (Get-Credential)

.EXAMPLE
    # No domain: create a SQL login for Molehill Data Services on every instance.
    # The password is prompted for securely; the login gets the same SID everywhere so AG replicas match.
    .\Install-MolehillWatch.ps1 -SqlInstance 10.0.0.4,10.0.0.5 -ClientName "Contoso Ltd" -SqlCredential (Get-Credential) `
        -MolehillLogin molehill_support -MolehillLoginPassword (Read-Host "Password for molehill_support" -AsSecureString)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $SqlInstance,
    [Parameter(Mandatory)] [string]   $ClientName,
    [string] $Database = 'MolehillWatch',     # an existing DBA database to use instead; only MolehillWatch is ever created
    [string] $MolehillLogin,
    [securestring] $MolehillLoginPassword,   # SQL logins only: create the login if missing
    [string] $ReportEmailProfile,
    [string] $ReportEmailRecipients,
    [string] $UnsupportedRiskAccepted,
    [pscredential] $SqlCredential,
    [switch] $UseTaskScheduler,
    [switch] $SkipInitialCollection,
    [switch] $SkipPatchReference    # no internet here: load it later with Update-PatchReference.ps1 -InFile
)

$ErrorActionPreference = 'Stop'
$scriptRoot  = $PSScriptRoot
$installFile = Join-Path $scriptRoot 'MolehillWatch_Install.sql'
if (-not (Test-Path $installFile)) { throw "Cannot find $installFile - keep this script next to MolehillWatch_Install.sql." }
if ($MolehillLoginPassword -and -not $MolehillLogin) { throw '-MolehillLoginPassword needs -MolehillLogin.' }
if ($MolehillLoginPassword -and $MolehillLogin -like '*\*') {
    Write-Warning "-MolehillLoginPassword is ignored for Windows login $MolehillLogin."
    $MolehillLoginPassword = $null
}
$molehillSid = $null   # SID of the SQL login on the first instance, reused on the rest

function New-SqlConnection([string]$Instance, [string]$Catalog = 'master') {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Instance
    $b['Initial Catalog'] = $Catalog
    $b['Application Name'] = 'Molehill Watch Installer'
    $b['TrustServerCertificate'] = $true
    $b['Connect Timeout'] = 15
    if ($SqlCredential) {
        $b['User ID'] = $SqlCredential.UserName
        $b['Password'] = $SqlCredential.GetNetworkCredential().Password
    } else {
        $b['Integrated Security'] = $true
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $conn.add_InfoMessage({ param($s, $e) foreach ($m in $e.Errors) {
        if ($m.Message -and $m.Message -notmatch 'Null value is eliminated|Changed database context') {
            $colour = if ($m.Message -like 'WARNING*') { 'Yellow' } else { 'DarkGray' }
            Write-Host "    $($m.Message)" -ForegroundColor $colour
        } } })
    $conn.Open()
    return $conn
}

function Invoke-Sql($Conn, [string]$Sql, [hashtable]$Parameters = @{}, [switch]$Scalar, [switch]$Table) {
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 0
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]; if ($null -eq $v) { $v = [DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue("@$k", $v)
    }
    if ($Scalar) { return $cmd.ExecuteScalar() }
    if ($Table)  { $dt = New-Object System.Data.DataTable; $dt.Load($cmd.ExecuteReader()); return ,$dt }
    [void]$cmd.ExecuteNonQuery()
}

function Get-SqlError($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    return $e.Message
}

function Invoke-SqlFile($Conn, [string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    $batches = [regex]::Split($text, '^\s*GO\s*$', [System.Text.RegularExpressions.RegexOptions]'Multiline, IgnoreCase')
    foreach ($batch in $batches) {
        if ($batch.Trim().Length -gt 0) { Invoke-Sql $Conn $batch }
    }
}

# Creates the default database if needed, or checks an existing one is suitable. Never changes an existing database.
function Initialize-TargetDatabase($Conn, [bool]$IsManagedInstance) {
    $info = Invoke-Sql $Conn @'
SELECT d.name, d.state_desc, d.is_read_only, InAg = CASE WHEN d.replica_id IS NULL THEN 0 ELSE 1 END, d.recovery_model_desc,
       Collation = CONVERT(sysname, DATABASEPROPERTYEX(d.name, 'Collation')), ServerCollation = CONVERT(sysname, SERVERPROPERTY('Collation'))
FROM sys.databases d WHERE d.name = @Db;
'@ @{ Db = $Database } -Table

    if ($info.Rows.Count -eq 0) {
        if ($Database -ne 'MolehillWatch') {
            throw "Database [$Database] does not exist on this instance. Give the name of an existing database, or leave out -Database to create the default MolehillWatch database."
        }
        # Azure SQL Managed Instance only supports FULL recovery (its log backups are automatic)
        $recovery = if ($IsManagedInstance) { '' } else { 'ALTER DATABASE MolehillWatch SET RECOVERY SIMPLE;' }
        Invoke-Sql $Conn @"
CREATE DATABASE MolehillWatch;
$recovery
ALTER DATABASE MolehillWatch SET AUTO_CLOSE OFF;
IF SUSER_SNAME(0x01) IS NOT NULL
BEGIN
    DECLARE @owner nvarchar(300) = N'ALTER AUTHORIZATION ON DATABASE::MolehillWatch TO ' + QUOTENAME(SUSER_SNAME(0x01)) + N';';
    EXEC (@owner);
END
"@
        Write-Host "    Created database MolehillWatch ($(if ($IsManagedInstance) { 'FULL recovery, as Managed Instance requires' } else { 'SIMPLE recovery' }))"
        return
    }

    $d = $info.Rows[0]
    if ($d.name -in 'master', 'model', 'msdb', 'tempdb') { throw "Molehill Watch can't be installed into the system database [$($d.name)]." }
    if ($d.state_desc -ne 'ONLINE') { throw "Database [$Database] is $($d.state_desc)." }
    if ($d.is_read_only) { throw "Database [$Database] is read-only." }
    if ($d.InAg -eq 1) { throw "Database [$Database] is in an Availability Group. Molehill Watch keeps separate history on each replica, so use a database that is not in the AG (or the default MolehillWatch)." }
    # read the collation from inside the database: a closed (AUTO_CLOSE) database reports none in sys.databases
    $Conn.ChangeDatabase($Database)
    $dbCollation = Invoke-Sql $Conn "SELECT CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation'));" -Scalar
    $Conn.ChangeDatabase('master')
    if ("$dbCollation" -ne "$($d.ServerCollation)") { throw "Database [$Database] uses collation $dbCollation but the server uses $($d.ServerCollation), which would cause collation conflicts. Use a database with the server collation (or the default MolehillWatch)." }
    if ($Database -ne 'MolehillWatch') {
        Write-Host "    Using existing database [$Database] ($($d.recovery_model_desc) recovery; its settings are left unchanged)"
        if ($d.recovery_model_desc -ne 'SIMPLE' -and -not $IsManagedInstance) { Write-Host '    Note: not in SIMPLE recovery, so Molehill Watch history adds a little to its log backups.' -ForegroundColor DarkGray }
    } else {
        Write-Host '    Database MolehillWatch already exists'
    }
}

function Register-MolehillTasks([string]$Instance) {
    $dir = Join-Path $env:ProgramData 'MolehillWatch'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $scriptRoot 'Invoke-MolehillCollect.ps1') $dir -Force
    $safe = ($Instance -replace '[\\/:*?"<>|]', '_')
    $runner = Join-Path $dir 'Invoke-MolehillCollect.ps1'
    $defs = @(
        @{ Type = 'Frequent'; Trigger = (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5)) },
        @{ Type = 'Hourly';   Trigger = (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1)) },
        @{ Type = 'Daily';    Trigger = (New-ScheduledTaskTrigger -Daily -At '05:30') },
        @{ Type = 'Weekly';   Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '06:30') }
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    foreach ($d in $defs) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -SqlInstance `"$Instance`" -Database `"$Database`" -Type $($d.Type)"
        Register-ScheduledTask -TaskPath '\Molehill Watch\' -TaskName "$safe - $($d.Type)" -Action $action -Trigger $d.Trigger -Principal $principal -Force | Out-Null
        Write-Host "    Scheduled task: \Molehill Watch\$safe - $($d.Type)"
    }
}

Write-Host ''
Write-Host 'Molehill Watch installer' -ForegroundColor Cyan
Write-Host 'Catching molehills before they''re mountains' -ForegroundColor DarkCyan
Write-Host ''

# Download the patch reference once for all instances
$patchFile = $null
if (-not $SkipPatchReference) {
    $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) "molehill-patch-reference-$PID.json"
    try {
        & (Join-Path $scriptRoot 'Update-PatchReference.ps1') -OutFile $patchFile | Out-Null
        if (-not (Test-Path $patchFile)) { throw 'no data saved' }
    }
    catch {
        Write-Warning "Could not download patch reference data ($($_.Exception.Message)). Patching checks will show 'Not checked' until you run Update-PatchReference.ps1 from a machine with internet access."
        $patchFile = $null
    }
    Write-Host ''
}

$results = @()
foreach ($instance in $SqlInstance) {
    Write-Host "[$instance]" -ForegroundColor Cyan
    $conn = $null
    $warnings = 0
    try {
        Write-Host '  1/7 Checking connection and permissions'
        $conn = New-SqlConnection $instance
        $info = Invoke-Sql $conn "SELECT Version = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')), Edition = CONVERT(nvarchar(200), SERVERPROPERTY('Edition')), EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')), IsSysadmin = IS_SRVROLEMEMBER('sysadmin'), ServerName = @@SERVERNAME" -Table
        $row = $info.Rows[0]
        $isManagedInstance = ($row.EngineEdition -eq 8)
        if ($isManagedInstance) { Write-Host "    $($row.ServerName): Azure SQL Managed Instance (patching, backups and HA are Microsoft's)" }
        else { Write-Host "    $($row.ServerName): SQL Server $($row.Version) $($row.Edition)" }
        if ([int]($row.Version.Split('.')[0]) -lt 11) { throw 'SQL Server 2012 or later is required.' }
        if ($row.IsSysadmin -ne 1) { throw 'The installing account must be a member of sysadmin.' }
        $isExpress = ($row.EngineEdition -eq 4)

        Write-Host "  2/7 Installing into database [$Database] (schema mw): procedures, report and jobs"
        Initialize-TargetDatabase $conn $isManagedInstance
        $conn.ChangeDatabase($Database)
        Invoke-SqlFile $conn $installFile

        Write-Host '  3/7 Applying settings'
        Invoke-Sql $conn @'
EXEC mw.usp_Configure @ClientName = @ClientName, @ReportEmailProfile = @Profile,
     @ReportEmailRecipients = @Recipients, @UnsupportedRiskAccepted = @Risk;
'@ @{ ClientName = $ClientName
      Profile    = $(if ($PSBoundParameters.ContainsKey('ReportEmailProfile')) { $ReportEmailProfile } else { $null })
      Recipients = $(if ($PSBoundParameters.ContainsKey('ReportEmailRecipients')) { $ReportEmailRecipients } else { $null })
      Risk       = $(if ($PSBoundParameters.ContainsKey('UnsupportedRiskAccepted')) { $UnsupportedRiskAccepted } else { $null }) }

        Write-Host '  4/7 Molehill Data Services access'
        if ($MolehillLogin) {
            try {
                # Parameter values are set with plain if-blocks: an if-expression would unroll the SID byte[] into object[]
                $grant = $conn.CreateCommand()
                $grant.CommandText = 'EXEC mw.usp_GrantMolehillAccess @LoginName = @Login, @Password = @Password, @Sid = @Sid;'
                [void]$grant.Parameters.AddWithValue('@Login', $MolehillLogin)
                $pwParam = $grant.Parameters.Add('@Password', [System.Data.SqlDbType]::NVarChar, 128)
                $pwParam.Value = [DBNull]::Value
                if ($MolehillLoginPassword) { $pwParam.Value = (New-Object System.Net.NetworkCredential('', $MolehillLoginPassword)).Password }
                $sidParam = $grant.Parameters.Add('@Sid', [System.Data.SqlDbType]::VarBinary, 85)
                $sidParam.Value = [DBNull]::Value
                if ($null -ne $molehillSid) { $sidParam.Value = $molehillSid }
                [void]$grant.ExecuteNonQuery()
                $pwParam.Value = [DBNull]::Value
                if ($null -eq $molehillSid -and $MolehillLogin -notlike '*\*') {
                    $sidCmd = $conn.CreateCommand()
                    $sidCmd.CommandText = 'SELECT SUSER_SID(@Login);'
                    [void]$sidCmd.Parameters.AddWithValue('@Login', $MolehillLogin)
                    $sid = $sidCmd.ExecuteScalar()
                    if ($sid -is [byte[]]) { $molehillSid = [byte[]]$sid }
                }
            }
            catch { Write-Warning "    Access not granted: $(Get-SqlError $_)"; $warnings++ }
        } else {
            Write-Host '    Skipped (no -MolehillLogin given)' -ForegroundColor DarkGray
        }

        Write-Host '  5/7 Patch reference data'
        if ($patchFile) {
            $refArgs = @{ InFile = $patchFile; SqlInstance = $instance; Database = $Database }
            if ($SqlCredential) { $refArgs.SqlCredential = $SqlCredential }
            $global:LASTEXITCODE = 0
            & (Join-Path $scriptRoot 'Update-PatchReference.ps1') @refArgs *>&1 | Where-Object { "$_" -match 'loaded|FAILED' } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -eq 1) { $warnings++ }
        } else {
            Write-Host '    Skipped' -ForegroundColor DarkGray
        }

        Write-Host '  6/7 Scheduling'
        if ($isExpress) {
            if ($UseTaskScheduler) {
                # SYSTEM runs the collection; on Express it needs sysadmin to read the error log, DMVs and msdb.
                Invoke-Sql $conn @'
IF SUSER_ID(N'NT AUTHORITY\SYSTEM') IS NULL CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
IF IS_SRVROLEMEMBER('sysadmin', N'NT AUTHORITY\SYSTEM') = 0 ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];
'@
                Register-MolehillTasks $instance
            } else {
                Write-Warning 'Express edition has no SQL Agent. Re-run on the SQL Server itself with -UseTaskScheduler to schedule collection.'
            }
        } else {
            $jobs = Invoke-Sql $conn "SELECT COUNT(*) FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id WHERE c.name = N'Molehill Watch'" -Scalar
            Write-Host "    $jobs SQL Agent jobs in place"
        }

        if (-not $SkipInitialCollection) {
            Write-Host '  7/7 First collection and baseline report (can take a minute)'
            try { Invoke-Sql $conn "EXEC mw.usp_Collect @Type = 'All';" }
            catch { Write-Warning "    Some collection steps failed: $(Get-SqlError $_)"; $warnings++ }
            $summary = Invoke-Sql $conn @'
EXEC mw.usp_BuildWeeklyReport @ReturnResults = 0;
SELECT TOP (1) ReportId, OverallStatus, CriticalCount, WarningCount, InfoCount FROM mw.WeeklyReport ORDER BY ReportId DESC;
'@ -Table
            $r = $summary.Rows[0]
            $colour = @{ Red = 'Red'; Amber = 'Yellow'; Green = 'Green' }[$r.OverallStatus]
            Write-Host "    Baseline report #$($r.ReportId): $($r.OverallStatus) ($($r.CriticalCount) critical, $($r.WarningCount) warnings, $($r.InfoCount) info)" -ForegroundColor $colour
        } else {
            Write-Host '  7/7 Skipped first collection'
        }

        $status = if ($warnings) { "Installed with $warnings warning(s)" } else { 'Installed' }
        $results += [pscustomobject]@{ Instance = $instance; Result = $status }
        Write-Host "  $status." -ForegroundColor Green
    }
    catch {
        $msg = Get-SqlError $_
        Write-Host "  FAILED: $msg" -ForegroundColor Red
        $results += [pscustomobject]@{ Instance = $instance; Result = "Failed: $msg" }
    }
    finally {
        if ($conn) { $conn.Close() }
    }
    Write-Host ''
}

if ($patchFile) { Remove-Item $patchFile -ErrorAction SilentlyContinue }
$results | Format-Table -AutoSize
Write-Host "View the latest findings in SSMS:  USE [$Database]; EXEC mw.usp_ShowReport;"
$dbArg = ''
if ($Database -ne 'MolehillWatch') { $dbArg = " -Database $Database" }
Write-Host "Export HTML reports:               .\Export-WeeklyReports.ps1 -SqlInstance <instance>$dbArg -OutputFolder <folder>"
if ($results.Result -match '^Failed') { exit 1 }
