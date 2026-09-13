<#
.SYNOPSIS
    Installs Molehill Watch monitoring on one or more SQL Server instances.

.DESCRIPTION
    Molehill Watch - SQL Server Support Package (Molehill Data Services).
    For each instance this script:
      1. checks the connection, version and sysadmin rights
      2. runs MolehillWatch_Install.sql (database, collectors, report, Agent jobs)
      3. sets the client name / report e-mail settings
      4. optionally grants read access to the Molehill Data Services login
      5. optionally schedules collection with Windows Task Scheduler (Express edition)
      6. runs a first collection and builds a baseline weekly report

    No modules required - works in Windows PowerShell 5.1 and PowerShell 7.
    Safe to re-run (upgrades in place and keeps collected data).

.EXAMPLE
    .\Install-MolehillWatch.ps1 -SqlInstance SQL01 -ClientName "Contoso Ltd"

.EXAMPLE
    .\Install-MolehillWatch.ps1 -SqlInstance SQL01,SQL02\SALES -ClientName "Contoso Ltd" `
        -MolehillLogin "CONTOSO\svc-molehill" -ReportEmailProfile "DBA Mail" -ReportEmailRecipients "it@contoso.co.uk"

.EXAMPLE
    # SQL authentication instead of Windows authentication
    .\Install-MolehillWatch.ps1 -SqlInstance 10.0.0.5 -ClientName "Contoso Ltd" -SqlCredential (Get-Credential)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $SqlInstance,
    [Parameter(Mandatory)] [string]   $ClientName,
    [string] $MolehillLogin,
    [string] $ReportEmailProfile,
    [string] $ReportEmailRecipients,
    [string] $UnsupportedRiskAccepted,
    [pscredential] $SqlCredential,
    [switch] $UseTaskScheduler,
    [switch] $SkipInitialCollection
)

$ErrorActionPreference = 'Stop'
$scriptRoot  = $PSScriptRoot
$installFile = Join-Path $scriptRoot 'MolehillWatch_Install.sql'
if (-not (Test-Path $installFile)) { throw "Cannot find $installFile - keep this script next to MolehillWatch_Install.sql." }

function New-SqlConnection([string]$Instance, [string]$Database = 'master') {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Instance
    $b['Initial Catalog'] = $Database
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
    $conn.add_InfoMessage({ param($s, $e) foreach ($m in $e.Errors) { if ($m.Message -and $m.Message -notmatch 'Null value is eliminated|Changed database context') { Write-Host "    $($m.Message)" -ForegroundColor DarkGray } } })
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
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" -SqlInstance `"$Instance`" -Type $($d.Type)"
        Register-ScheduledTask -TaskPath '\Molehill Watch\' -TaskName "$safe - $($d.Type)" -Action $action -Trigger $d.Trigger -Principal $principal -Force | Out-Null
        Write-Host "    Scheduled task: \Molehill Watch\$safe - $($d.Type)"
    }
}

Write-Host ''
Write-Host 'Molehill Watch installer' -ForegroundColor Cyan
Write-Host 'Catching molehills before they''re mountains' -ForegroundColor DarkCyan
Write-Host ''

$results = @()
foreach ($instance in $SqlInstance) {
    Write-Host "[$instance]" -ForegroundColor Cyan
    $conn = $null
    $warnings = 0
    try {
        Write-Host '  1/6 Checking connection and permissions'
        $conn = New-SqlConnection $instance
        $info = Invoke-Sql $conn "SELECT Version = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')), Edition = CONVERT(nvarchar(200), SERVERPROPERTY('Edition')), EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')), IsSysadmin = IS_SRVROLEMEMBER('sysadmin'), ServerName = @@SERVERNAME" -Table
        $row = $info.Rows[0]
        Write-Host "    $($row.ServerName): SQL Server $($row.Version) $($row.Edition)"
        if ([int]($row.Version.Split('.')[0]) -lt 11) { throw 'SQL Server 2012 or later is required.' }
        if ($row.IsSysadmin -ne 1) { throw 'The installing account must be a member of sysadmin.' }
        $isExpress = ($row.EngineEdition -eq 4)

        Write-Host '  2/6 Installing MolehillWatch database, procedures and jobs'
        Invoke-SqlFile $conn $installFile

        Write-Host '  3/6 Applying settings'
        Invoke-Sql $conn @'
EXEC MolehillWatch.dbo.usp_Configure @ClientName = @ClientName, @ReportEmailProfile = @Profile,
     @ReportEmailRecipients = @Recipients, @UnsupportedRiskAccepted = @Risk;
'@ @{ ClientName = $ClientName
      Profile    = $(if ($PSBoundParameters.ContainsKey('ReportEmailProfile')) { $ReportEmailProfile } else { $null })
      Recipients = $(if ($PSBoundParameters.ContainsKey('ReportEmailRecipients')) { $ReportEmailRecipients } else { $null })
      Risk       = $(if ($PSBoundParameters.ContainsKey('UnsupportedRiskAccepted')) { $UnsupportedRiskAccepted } else { $null }) }

        Write-Host '  4/6 Molehill Data Services access'
        if ($MolehillLogin) {
            try { Invoke-Sql $conn 'EXEC MolehillWatch.dbo.usp_GrantMolehillAccess @LoginName = @Login;' @{ Login = $MolehillLogin } }
            catch { Write-Warning "    Access not granted: $(Get-SqlError $_)"; $warnings++ }
        } else {
            Write-Host '    Skipped (no -MolehillLogin given)' -ForegroundColor DarkGray
        }

        Write-Host '  5/6 Scheduling'
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
            Write-Host '  6/6 First collection and baseline report (can take a minute)'
            try { Invoke-Sql $conn "EXEC MolehillWatch.dbo.usp_Collect @Type = 'All';" }
            catch { Write-Warning "    Some collection steps failed: $(Get-SqlError $_)"; $warnings++ }
            $summary = Invoke-Sql $conn @'
EXEC MolehillWatch.dbo.usp_BuildWeeklyReport @ReturnResults = 0;
SELECT TOP (1) ReportId, OverallStatus, CriticalCount, WarningCount, InfoCount FROM MolehillWatch.dbo.WeeklyReport ORDER BY ReportId DESC;
'@ -Table
            $r = $summary.Rows[0]
            $colour = @{ Red = 'Red'; Amber = 'Yellow'; Green = 'Green' }[$r.OverallStatus]
            Write-Host "    Baseline report #$($r.ReportId): $($r.OverallStatus) ($($r.CriticalCount) critical, $($r.WarningCount) warnings, $($r.InfoCount) info)" -ForegroundColor $colour
        } else {
            Write-Host '  6/6 Skipped first collection'
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

$results | Format-Table -AutoSize
Write-Host 'View the latest findings in SSMS:  EXEC MolehillWatch.dbo.usp_ShowReport;'
Write-Host 'Export HTML reports:               .\Export-WeeklyReports.ps1 -SqlInstance <instance> -OutputFolder <folder>'
if ($results.Result -match '^Failed') { exit 1 }
