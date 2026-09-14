<#
.SYNOPSIS
    Saves the latest Molehill Watch weekly report from each covered instance as HTML,
    and checks SQL Agent job and login parity between Availability Group replicas.

.DESCRIPTION
    Run this from the client's jump box (or any machine with access to the SQL Servers).
    Output stays on the client's infrastructure, in line with the support agreement.

    Creates in -OutputFolder:
      index.html                         summary of every instance (RAG status, counts, links)
      <Client>_<Instance>_<date>.html    the weekly report for each instance
      AG-Parity_<AG>_<date>.html         job/login differences between replicas (where applicable)

    index.html also shows the live SQL Server and Windows patch status of every instance.
    Use -UpdatePatchReference to refresh Microsoft's build data first (needs internet access).

    Needs only read access (the MolehillWatchReader role granted by the installer),
    unless -BuildNew is used, which requires sysadmin.

.EXAMPLE
    .\Export-WeeklyReports.ps1 -ServerList .\servers.txt

.EXAMPLE
    .\Export-WeeklyReports.ps1 -SqlInstance SQL01,SQL02 -OutputFolder D:\MolehillReports -BuildNew
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Instances', Mandatory)] [string[]] $SqlInstance,
    [Parameter(ParameterSetName = 'List')] [string] $ServerList,
    [string] $OutputFolder,
    [switch] $BuildNew,
    [switch] $UpdatePatchReference,   # download Microsoft's latest build data and load it before exporting
    [pscredential] $SqlCredential,
    [string] $Database = 'MolehillWatch'   # the database Molehill Watch was installed into
)

$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'List') {
    if (-not $ServerList) { $ServerList = Join-Path $PSScriptRoot 'servers.txt' }
    if (-not (Test-Path $ServerList)) { throw "Server list not found: $ServerList (one instance per line, # for comments)." }
    $SqlInstance = Get-Content $ServerList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}
$today = Get-Date -Format 'yyyy-MM-dd'
if (-not $OutputFolder) { $OutputFolder = Join-Path (Get-Location) "MolehillReports\$today" }
New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null

function Get-Data([string]$Instance, [string]$Sql) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Instance; $b['Initial Catalog'] = $Database; $b['TrustServerCertificate'] = $true
    $b['Application Name'] = 'Molehill Watch Export'; $b['Connect Timeout'] = 15
    if ($SqlCredential) { $b['User ID'] = $SqlCredential.UserName; $b['Password'] = $SqlCredential.GetNetworkCredential().Password }
    else { $b['Integrated Security'] = $true }
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 600
        $ds = New-Object System.Data.DataSet
        [void](New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($ds)
        return ,$ds
    } finally { $conn.Close() }
}

function Enc([object]$s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
function SafeName([string]$s) { ($s -replace '[^A-Za-z0-9.-]+', '_').Trim('_') }

$css = @'
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.5}
.wrap{max-width:1040px;margin:0 auto;padding:24px}
.hero{background:#231F20;color:#fff;padding:24px 30px}.brand{font-size:26px;font-weight:700}.tag{color:#44C8F5}
.meta{color:#BFBBBA;font-size:13px;margin-top:12px}
h2{font-size:18px;border-bottom:3px solid #44C8F5;padding-bottom:6px;margin:30px 0 12px}
table{width:100%;border-collapse:collapse;background:#fff;font-size:13px}
th{background:#231F20;color:#fff;text-align:left;padding:8px 10px}td{padding:7px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}
td.Red,td.critical{background:#D64545;color:#fff;font-weight:600}td.Amber,td.warning{background:#F9D58C;font-weight:600}
td.Green,td.ok{background:#D5EEDD}td.info{background:#DDF3FC}.note{color:#7A7473;font-size:12px}a{color:#1B9BCB}
'@
function Page([string]$Title, [string]$Body) {
    "<html><head><meta charset=`"utf-8`" /><title>$(Enc $Title)</title><style>$css</style></head><body><div class=`"wrap`">" +
    "<div class=`"hero`"><div class=`"brand`">Molehill Watch</div><div class=`"tag`">Catching molehills before they're mountains</div>" +
    "<div class=`"meta`">$(Enc $Title) &#183; exported $(Get-Date -Format 'dd MMM yyyy HH:mm')</div></div>$Body" +
    "<p class=`"note`" style=`"margin-top:30px`">Molehill Data Services &#183; jay@jayparry.co.uk &#183; molehilldataservices.com</p></div></body></html>"
}

if ($UpdatePatchReference) {
    $refArgs = @{ SqlInstance = $SqlInstance; Database = $Database }
    if ($SqlCredential) { $refArgs.SqlCredential = $SqlCredential }
    try { & (Join-Path $PSScriptRoot 'Update-PatchReference.ps1') @refArgs }
    catch { Write-Warning "Patch reference not refreshed: $($_.Exception.Message)" }
    Write-Host ''
}

$summary = @()
$inventory = @{}
$patching = @{}

foreach ($instance in $SqlInstance) {
    Write-Host "[$instance] " -NoNewline
    try {
        $pre = if ($BuildNew) { 'EXEC mw.usp_BuildWeeklyReport @ReturnResults = 0;' } else { '' }
        $ds = Get-Data $instance "$pre SELECT TOP (1) ReportId, GeneratedAt, ClientName, InstanceName, OverallStatus, CriticalCount, WarningCount, InfoCount, Html FROM mw.WeeklyReport ORDER BY ReportId DESC;"
        if ($ds.Tables[0].Rows.Count -eq 0) { throw 'No weekly report found yet. Run with -BuildNew or wait for the Monday job.' }
        $r = $ds.Tables[0].Rows[0]
        $file = "$(SafeName $r.ClientName)_$(SafeName $r.InstanceName)_$($r.GeneratedAt.ToString('yyyy-MM-dd')).html"
        [System.IO.File]::WriteAllText((Join-Path $OutputFolder $file), [string]$r.Html, [System.Text.Encoding]::UTF8)
        $age = ((Get-Date) - $r.GeneratedAt).TotalDays
        $summary += [pscustomobject]@{ Instance = $instance; Client = $r.ClientName; Status = $r.OverallStatus; Critical = $r.CriticalCount; Warnings = $r.WarningCount; Info = $r.InfoCount; Generated = $r.GeneratedAt; File = $file; Stale = ($age -gt 8); Error = $null }
        Write-Host "$($r.OverallStatus) ($($r.CriticalCount) critical, $($r.WarningCount) warnings)" -ForegroundColor @{ Red = 'Red'; Amber = 'Yellow'; Green = 'Green' }[[string]$r.OverallStatus]
        if ($age -gt 8) { Write-Warning "  Latest report is $([int]$age) days old - check the Weekly Report job." }

        $inv = Get-Data $instance 'EXEC mw.usp_Inventory;'
        $inventory[$instance] = $inv
        try { $patching[$instance] = (Get-Data $instance 'EXEC mw.usp_PatchStatus;').Tables[0] }
        catch { Write-Warning "  Patch status unavailable (re-run Install-MolehillWatch.ps1 to upgrade): $($_.Exception.Message)" }
    }
    catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $summary += [pscustomobject]@{ Instance = $instance; Client = ''; Status = 'Error'; Critical = ''; Warnings = ''; Info = ''; Generated = $null; File = $null; Stale = $false; Error = $_.Exception.Message }
    }
}

# ---- Availability Group parity -------------------------------------------------------------
$agMembers = @{}
foreach ($inst in $inventory.Keys) {
    foreach ($row in $inventory[$inst].Tables[0].Rows) {
        if (-not $agMembers.ContainsKey($row.AgName)) { $agMembers[$row.AgName] = @() }
        $agMembers[$row.AgName] += [pscustomobject]@{ Instance = $inst; Server = $row.ServerName; Role = $row.LocalRole; Replicas = $row.Replicas }
    }
}
$parityLinks = @()
foreach ($ag in $agMembers.Keys) {
    $members = $agMembers[$ag]
    $expected = ([string]$members[0].Replicas).Split(',') | Where-Object { $_ }
    $missingReplicas = $expected | Where-Object { $_ -notin $members.Server }
    $rows = New-Object System.Text.StringBuilder
    $issues = 0

    if ($members.Count -gt 1) {
        $jobNames = $members | ForEach-Object { $inventory[$_.Instance].Tables[1].Rows | ForEach-Object { $_.JobName } } | Sort-Object -Unique
        foreach ($job in $jobNames) {
            $cells = foreach ($m in $members) { $inventory[$m.Instance].Tables[1].Rows | Where-Object { $_.JobName -eq $job } | Select-Object -First 1 }
            $present = @($cells | Where-Object { $_ }).Count
            $fingerprints = @($cells | Where-Object { $_ } | ForEach-Object { "$($_.StepFingerprint)" } | Sort-Object -Unique).Count
            $enabledStates = @($cells | Where-Object { $_ } | ForEach-Object { $_.IsEnabled } | Sort-Object -Unique).Count
            $problem = if ($present -lt $members.Count) { 'Missing on a replica' } elseif ($fingerprints -gt 1) { 'Steps differ' } elseif ($enabledStates -gt 1) { 'Enabled state differs' } else { $null }
            if ($problem) {
                $issues++
                $cls = if ($problem -eq 'Enabled state differs') { 'info' } else { 'warning' }
                $detail = ($members | ForEach-Object { $c = $inventory[$_.Instance].Tables[1].Rows | Where-Object { $_.JobName -eq $job } | Select-Object -First 1
                    "$($_.Server): " + $(if ($c) { if ($c.IsEnabled -eq 1) { 'enabled' } else { 'disabled' } } else { 'MISSING' }) }) -join '; '
                [void]$rows.Append("<tr><td class=`"$cls`">Job</td><td>$(Enc $job)</td><td>$problem</td><td>$(Enc $detail)</td></tr>")
            }
        }
        $loginNames = $members | ForEach-Object { $inventory[$_.Instance].Tables[2].Rows | ForEach-Object { $_.LoginName } } | Sort-Object -Unique
        foreach ($login in $loginNames) {
            if ($login -match '^NT (SERVICE|AUTHORITY)\\') { continue }
            $cells = foreach ($m in $members) { $inventory[$m.Instance].Tables[2].Rows | Where-Object { $_.LoginName -eq $login } | Select-Object -First 1 }
            $found = @($cells | Where-Object { $_ })
            $problem = if ($found.Count -lt $members.Count) { 'Missing on a replica' }
                       elseif ($found[0].LoginType -eq 'SQL_LOGIN' -and @($found | ForEach-Object { $_.Sid } | Sort-Object -Unique).Count -gt 1) { 'SQL login SID differs (orphaned users after failover)' }
                       else { $null }
            if ($problem) {
                $issues++
                $where = ($members | Where-Object { -not ($inventory[$_.Instance].Tables[2].Rows | Where-Object { $_.LoginName -eq $login }) } | ForEach-Object { $_.Server }) -join ', '
                [void]$rows.Append("<tr><td class=`"warning`">Login</td><td>$(Enc $login)</td><td>$problem</td><td>$(if ($where) { 'Missing on: ' + (Enc $where) })</td></tr>")
            }
        }
    }

    $intro = "<p>Replicas compared: $(Enc (($members | ForEach-Object { "$($_.Server) ($($_.Role))" }) -join ', ')).</p>"
    if ($missingReplicas) { $intro += "<p class=`"note`">Not in the export list, so not compared: $(Enc ($missingReplicas -join ', ')). Add them to the server list for a full comparison.</p>" }
    if ($members.Count -lt 2) {
        $body = "$intro<p>Only one replica of this Availability Group was exported, so parity could not be checked.</p>"
    } elseif ($issues -eq 0) {
        $body = "$intro<table><tr><td class=`"ok`">No job or login differences found between replicas.</td></tr></table>"
    } else {
        $body = "$intro<table><tr><th>Type</th><th>Name</th><th>Difference</th><th>Detail</th></tr>$rows</table><p class=`"note`">Jobs on AG replicas normally exist on every replica and check the replica role in their first step. Differences in enabled state can be deliberate.</p>"
    }
    $file = "AG-Parity_$(SafeName $ag)_$today.html"
    [System.IO.File]::WriteAllText((Join-Path $OutputFolder $file), (Page "Availability Group parity - $ag" "<h2>Job and login parity: $(Enc $ag)</h2>$body"), [System.Text.Encoding]::UTF8)
    $parityLinks += [pscustomobject]@{ Ag = $ag; File = $file; Issues = $issues; Compared = $members.Count }
    Write-Host "[AG $ag] $issues parity difference(s) across $($members.Count) replica(s)"
}

# ---- Index ---------------------------------------------------------------------------------
$tr = ($summary | ForEach-Object {
    $link = if ($_.File) { "<a href=`"$(Enc $_.File)`">Open report</a>" } else { Enc $_.Error }
    $gen = if ($_.Generated) { $_.Generated.ToString('dd MMM yyyy HH:mm') + $(if ($_.Stale) { ' (STALE)' }) } else { '' }
    "<tr><td>$(Enc $_.Client)</td><td>$(Enc $_.Instance)</td><td class=`"$($_.Status)`">$($_.Status)</td><td>$($_.Critical)</td><td>$($_.Warnings)</td><td>$($_.Info)</td><td>$gen</td><td>$link</td></tr>"
}) -join ''
$body = "<h2>Instances</h2><table><tr><th>Client</th><th>Instance</th><th>Status</th><th>Critical</th><th>Warnings</th><th>Info</th><th>Generated</th><th></th></tr>$tr</table>"
if ($patching.Count) {
    $sevClass = @{ Critical = 'critical'; Warning = 'warning'; OK = 'ok'; Info = 'info' }
    $pr = foreach ($inst in $SqlInstance) {
        if (-not $patching.ContainsKey($inst)) { continue }
        foreach ($row in $patching[$inst].Rows) {
            $installed = "$($row.Installed)" + $(if ("$($row.InstalledUpdate)") { " - $($row.InstalledUpdate)" })
            $latest = if ("$($row.Latest)") { "$($row.Latest)" + $(if ("$($row.LatestUpdate)") { " - $($row.LatestUpdate)" }) } else { '-' }
            "<tr><td>$(Enc $inst)</td><td>$(Enc $row.Component)</td><td>$(Enc $installed)</td><td>$(Enc $latest)</td><td class=`"$($sevClass[[string]$row.Severity])`">$(Enc $row.Status)</td><td>$(Enc $row.Recommendation)</td></tr>"
        }
    }
    $body += "<h2>Patching</h2><table><tr><th>Instance</th><th>Component</th><th>Installed</th><th>Latest available</th><th>Status</th><th>Action</th></tr>$($pr -join '')</table>" +
             "<p class=`"note`">Windows: latest monthly security update for the OS. SQL Server: latest cumulative update on the branch in use. Live status at export time.</p>"
}
if ($parityLinks) {
    $pr = ($parityLinks | ForEach-Object { "<tr><td>$(Enc $_.Ag)</td><td>$($_.Compared)</td><td class=`"$(if ($_.Issues) { 'warning' } else { 'ok' })`">$($_.Issues)</td><td><a href=`"$(Enc $_.File)`">Open</a></td></tr>" }) -join ''
    $body += "<h2>Availability Group parity</h2><table><tr><th>Availability Group</th><th>Replicas compared</th><th>Differences</th><th></th></tr>$pr</table>"
}
[System.IO.File]::WriteAllText((Join-Path $OutputFolder 'index.html'), (Page "Weekly reports - $today" $body), [System.Text.Encoding]::UTF8)

Write-Host ''
Write-Host "Reports saved to $OutputFolder" -ForegroundColor Green
Write-Host "Open: $(Join-Path $OutputFolder 'index.html')"
