<#
.SYNOPSIS
    Quick, standalone check of how up to date the SQL Server instances and Windows Server security
    updates are on one or more servers. Produces an HTML report (and optionally CSV).

.DESCRIPTION
    No installation, no modules and no WinRM. Nothing is created or changed on the servers: it only runs
    read-only queries.

    For each server it:
      1. Finds the SQL Server instances: SQL Browser (UDP 1434), then the Windows service list (RPC),
         then the default instance. You can also list instances directly: SERVER\INSTANCE or SERVER,1433.
      2. Reads each instance's version (SERVERPROPERTY) over a normal SQL connection.
      3. Reads the Windows build and update revision (CurrentBuild.UBR) through SQL Server (xp_regread,
         needs sysadmin), else Remote Registry, else the local registry when run on the server itself.
      4. Compares them with Microsoft's published data:
           * SQL Server: every CU/GDR build (Microsoft "Latest updates and version history for SQL Server")
           * Windows Server 2016-2025: the build containing each month's security update (MSRC security API)

    Locked-down server without internet? Download the reference data somewhere with internet first:
        .\Get-PatchStatus.ps1 -SaveReference patch-reference.json
    then copy both files to the server and run:
        .\Get-PatchStatus.ps1 -ReferenceFile patch-reference.json
    (patch-reference.json next to the script is picked up automatically. Files from Molehill Watch's
    Update-PatchReference.ps1 -OutFile work too.)

    Exit code: 0 = everything up to date or informational, 1 = warnings, 2 = critical findings.

.EXAMPLE
    .\Get-PatchStatus.ps1
    # checks the server it is run on

.EXAMPLE
    .\Get-PatchStatus.ps1 -ComputerName SQL01, SQL02, 'SQL03\SALES', 'SQL04,14330' -OutputPath C:\Temp\patching.html

.EXAMPLE
    .\Get-PatchStatus.ps1 -ServerList .\servers.txt -SqlCredential (Get-Credential) -CsvPath .\patching.csv
#>
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check', Position = 0, ValueFromPipeline)] [string[]] $ComputerName,
    [Parameter(ParameterSetName = 'Check')] [string] $ServerList,
    [Parameter(ParameterSetName = 'Check')] [pscredential] $SqlCredential,
    [Parameter(ParameterSetName = 'Check')] [string] $ReferenceFile,
    [Parameter(ParameterSetName = 'Check')] [string] $OutputPath,
    [Parameter(ParameterSetName = 'Check')] [string] $CsvPath,
    [Parameter(ParameterSetName = 'Check')] [switch] $Open,
    [Parameter(ParameterSetName = 'Check')] [int] $SqlGraceDays = 30,
    [Parameter(ParameterSetName = 'Check')] [int] $SqlCuBehindCritical = 3,
    [Parameter(ParameterSetName = 'Check')] [int] $WindowsGraceDays = 14,
    [Parameter(ParameterSetName = 'Check')] [int] $ConnectTimeoutSeconds = 10,
    [Parameter(ParameterSetName = 'Download', Mandatory)] [string] $SaveReference,
    [ValidateRange(2, 12)] [int] $Months = 3
)

begin {
    $ErrorActionPreference = 'Stop'
    $allComputers = New-Object System.Collections.Generic.List[string]
}
process {
    foreach ($c in $ComputerName) { if ($c) { $allComputers.Add($c.Trim()) } }
}
end {
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$today = (Get-Date).Date

# =============================================================================================
#  Reference data (Microsoft)
# =============================================================================================
function Get-Text([string]$Url, [string]$Accept) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'PatchStatusCheck')
    if ($Accept) { $wc.Headers.Add('Accept', $Accept) }
    try { return $wc.DownloadString($Url) } finally { $wc.Dispose() }
}

function ConvertFrom-BigJson([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ,($Text | ConvertFrom-Json -AsHashtable) }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return ,$ser.DeserializeObject($Text)
}

function Get-SqlServerBuilds {
    Write-Host 'Downloading SQL Server build list from Microsoft...'
    $lines = (Get-Text 'https://raw.githubusercontent.com/MicrosoftDocs/SupportArticles-docs/main/support/sql/releases/download-and-install-latest-updates.md') -split "`r?`n"
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $product = $null
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -match '^###\s+SQL Server (\d{4})(\s+R2)?\s*$') {
            $product = if ($Matches[2] -or [int]$Matches[1] -lt 2012) { $null } else { "SQL Server $($Matches[1])" }
            continue
        }
        if ($line -match '^##\s') { $product = $null; continue }
        if (-not $product -or $line -notmatch '^\|\s*(\d+)\.(\d+)\.(\d+)\.(\d+)\s*\|') { continue }
        $cells = $line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 5) { continue }
        $v = $cells[0].Split('.')
        $update = $cells[2] -replace '\[([^\]]*)\]\([^)]*\)', '$1'
        $kb = if ($cells[3] -match 'KB\s*(\d+)') { $Matches[1] } elseif ($cells[3] -match '(\d{6,7})') { $Matches[1] } else { $null }
        $date = $null; $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(($cells[4] -replace '\s+', ' '), [string[]]@('MMMM dd, yyyy', 'MMMM d, yyyy'), $culture, 'None', [ref]$parsed)) { $date = $parsed.ToString('yyyy-MM-dd') }
        $cu = if ($update -match '\bCU\s*(\d+)') { [int]$Matches[1] } else { $null }
        $rows.Add([pscustomobject]@{
            Product = 'SQL Server'; ProductName = $product; Major = [int]$v[0]; Minor = [int]$v[1]; BuildNumber = [int]$v[2]; Revision = [int]$v[3]
            ServicePack = $cells[1]; UpdateName = $update; CuNumber = $cu; KB = $kb; ReleaseDate = $date; Source = 'Microsoft SQL Server build list'
        })
    }
    if ($rows.Count -lt 100) { throw "Only $($rows.Count) SQL Server builds were read - the Microsoft article format may have changed." }
    Write-Host "  $($rows.Count) SQL Server builds"
    return $rows.ToArray()
}

function Get-WindowsSecurityBuilds([int]$MonthCount) {
    Write-Host 'Downloading Windows security update data from MSRC...'
    $index = Get-Text 'https://api.msrc.microsoft.com/cvrf/v3.0/updates' 'application/json' | ConvertFrom-Json
    $releases = $index.value | Where-Object { $_.ID -match '^\d{4}-[A-Za-z]{3}$' -and [datetime]$_.InitialReleaseDate -le (Get-Date) } |
                Sort-Object { [datetime]$_.InitialReleaseDate } -Descending | Select-Object -First $MonthCount
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $releases) {
        Write-Host "  $($rel.ID)..."
        $doc = ConvertFrom-BigJson (Get-Text "https://api.msrc.microsoft.com/cvrf/v3.0/cvrf/$($rel.ID)" 'application/json')
        $names = @{}
        $stack = New-Object System.Collections.Stack
        $stack.Push($doc['ProductTree'])
        while ($stack.Count) {
            $node = $stack.Pop()
            foreach ($p in @($node['FullProductName'])) { if ($p) { $names[[string]$p['ProductID']] = [string]$p['Value'] } }
            foreach ($b in @($node['Branch'])) { if ($b) { $stack.Push($b) } }
        }
        $best = @{}
        foreach ($vuln in @($doc['Vulnerability'])) {
            foreach ($r in @($vuln['Remediations'])) {
                if (-not $r -or $r['SubType'] -ne 'Security Update' -or -not $r['FixedBuild']) { continue }
                if ([string]$r['FixedBuild'] -notmatch '^10\.0\.(\d+)\.(\d+)$') { continue }
                $build = [int]$Matches[1]; $ubr = [int]$Matches[2]
                $product = @($r['ProductID']) | ForEach-Object { $names[[string]$_] } | Where-Object { $_ -match '^Windows Server (2016|2019|2022|2025)' } | Select-Object -First 1
                if (-not $product) { continue }
                if (-not $best.ContainsKey($build) -or $best[$build].Revision -lt $ubr) {
                    $kb = if ($r['Description'] -and $r['Description']['Value']) { [string]$r['Description']['Value'] } else { $null }
                    $best[$build] = [pscustomobject]@{
                        Product = 'Windows Server'; ProductName = ($product -replace '\s*\(Server Core installation\)', ''); Major = 10; Minor = 0
                        BuildNumber = $build; Revision = $ubr; ServicePack = $null; UpdateName = 'Security Update'; CuNumber = $null; KB = $kb
                        ReleaseDate = ([datetime]$rel.InitialReleaseDate).ToString('yyyy-MM-dd'); Source = $rel.ID
                    }
                }
            }
        }
        foreach ($k in $best.Keys) { $rows.Add($best[$k]) }
        $doc = $null
    }
    if ($rows.Count -eq 0) { throw 'No Windows Server security builds were read from MSRC - the API format may have changed.' }
    return $rows.ToArray()
}

if ($PSCmdlet.ParameterSetName -eq 'Download') {
    $rows = @(Get-SqlServerBuilds) + @(Get-WindowsSecurityBuilds $Months)
    [pscustomobject]@{ Downloaded = (Get-Date).ToString('s'); Rows = $rows } | ConvertTo-Json -Depth 4 | Set-Content -Path $SaveReference -Encoding UTF8
    Write-Host "Saved $($rows.Count) builds to $SaveReference. Copy it next to Get-PatchStatus.ps1 on the server (or pass -ReferenceFile)." -ForegroundColor Green
    return
}

if (-not $ReferenceFile) {
    $besideScript = Join-Path $PSScriptRoot 'patch-reference.json'
    if (Test-Path $besideScript) { $ReferenceFile = $besideScript }
}
if ($ReferenceFile) {
    $data = Get-Content -Raw -Path $ReferenceFile | ConvertFrom-Json
    $reference = @($data.Rows)
    $referenceDate = [datetime]$data.Downloaded
    Write-Host "Using reference data from $ReferenceFile (downloaded $($referenceDate.ToString('dd MMM yyyy HH:mm')))"
    if (($today - $referenceDate.Date).TotalDays -gt 40) {
        Write-Warning "The reference data is $([int]($today - $referenceDate.Date).TotalDays) days old - newer updates will not be taken into account. Refresh it with -SaveReference."
    }
} else {
    try {
        $reference = @(Get-SqlServerBuilds) + @(Get-WindowsSecurityBuilds $Months)
        $referenceDate = Get-Date
    }
    catch {
        throw "Could not download Microsoft's update data ($($_.Exception.Message)).`nThis machine probably has no internet access. On a machine that does, run:`n  .\Get-PatchStatus.ps1 -SaveReference patch-reference.json`nthen copy patch-reference.json next to this script and run it again."
    }
}
$sqlRef = @($reference | Where-Object { $_.Product -eq 'SQL Server' } | ForEach-Object {
    $_ | Add-Member -NotePropertyName Version -NotePropertyValue ([version]"$($_.Major).$($_.Minor).$($_.BuildNumber).$($_.Revision)") -Force -PassThru })
$winRef = @($reference | Where-Object { $_.Product -eq 'Windows Server' })

$sqlLifecycle = @{
    11 = @('SQL Server 2012', '2017-07-11', '2022-07-12'); 12 = @('SQL Server 2014', '2019-07-09', '2024-07-09')
    13 = @('SQL Server 2016', '2021-07-13', '2026-07-14'); 14 = @('SQL Server 2017', '2022-10-11', '2027-10-12')
    15 = @('SQL Server 2019', '2025-02-28', '2030-01-08'); 16 = @('SQL Server 2022', '2028-01-11', '2033-01-11')
    17 = @('SQL Server 2025', $null, $null)
}
$winLifecycle = @{
    9200 = @('Windows Server 2012', '2023-10-10'); 9600 = @('Windows Server 2012 R2', '2023-10-10'); 14393 = @('Windows Server 2016', '2027-01-12')
    17763 = @('Windows Server 2019', '2029-01-09'); 20348 = @('Windows Server 2022', '2031-10-14'); 26100 = @('Windows Server 2025', '2034-10-10')
}

function Get-SupportText([string]$ExtendedEnd) {
    if (-not $ExtendedEnd) { return 'Supported' }
    $end = [datetime]$ExtendedEnd
    if ($end -lt $today) { return "UNSUPPORTED since $($end.ToString('dd MMM yyyy'))" }
    if ($end -lt $today.AddMonths(12)) { return "Support ends $($end.ToString('dd MMM yyyy'))" }
    return "Supported until $($end.ToString('dd MMM yyyy'))"
}

function Format-Date($d) { if ($d) { ([datetime]$d).ToString('dd MMM yyyy') } else { '' } }

# =============================================================================================
#  Evaluation (same rules as Molehill Watch usp_PatchStatus)
# =============================================================================================
function Get-SqlStatus([string]$VersionText) {
    $ver = [version]$VersionText
    $life = $sqlLifecycle[$ver.Major]
    $result = [ordered]@{ Latest = ''; LatestRelease = ''; Released = ''; Status = 'Not checked'; Severity = 'Info'; Action = ''; InstalledUpdate = ''
                          Support = $(if ($life) { Get-SupportText $life[2] } else { '' }) }
    $rows = @($sqlRef | Where-Object { $_.Major -eq $ver.Major } | Sort-Object Version)
    if (-not $rows) { $result.Action = "No Microsoft build data for SQL Server version $($ver.Major)."; return [pscustomobject]$result }

    $inst = $rows | Where-Object { $_.Version -le $ver } | Select-Object -Last 1
    $exact = $inst -and $inst.Version -eq $ver
    $sp = if ($inst -and $inst.ServicePack) { $inst.ServicePack } else { 'None' }
    $spRows = @($rows | Where-Object { $(if ($_.ServicePack) { $_.ServicePack } else { 'None' }) -eq $sp })
    $result.InstalledUpdate = if (-not $inst) { 'Unlisted build' } elseif ($exact) { $inst.UpdateName } else { "$($inst.UpdateName) (or later, unlisted build)" }

    $newerCu = @($spRows | Where-Object { $_.CuNumber -and $_.Version -gt $ver })
    $track = if ($inst -and $inst.UpdateName -match 'CU') { 'CU' } elseif ($newerCu -and -not ($inst -and $inst.UpdateName -match 'GDR')) { 'CU' } else { 'GDR' }

    if ($track -eq 'CU') {
        $cuRows = @($spRows | Where-Object { $_.CuNumber })
        $latestCu = $cuRows | Where-Object { $_.UpdateName -notmatch 'GDR' } | Select-Object -Last 1
        $latestAny = $cuRows | Select-Object -Last 1
        if (-not $latestCu) { $latestCu = $latestAny }
        $result.Latest = $latestAny.Version.ToString(); $result.LatestRelease = "$($latestAny.UpdateName) (KB$($latestAny.KB))"; $result.Released = Format-Date $latestAny.ReleaseDate
        if ($ver -ge $latestAny.Version) {
            $result.Status = 'Up to date'; $result.Severity = 'OK'
        } elseif ($ver -ge $latestCu.Version) {
            $result.Status = 'Latest CU - security update available'; $result.Severity = 'Info'
            $result.Action = "Apply $($latestAny.UpdateName) (KB$($latestAny.KB)) at the next maintenance window."
        } else {
            $instCu = if ($inst -and $inst.CuNumber) { [int]$inst.CuNumber } else { 0 }
            $behind = [int]$latestCu.CuNumber - $instCu
            $age = ($today - [datetime]$latestCu.ReleaseDate).TotalDays
            $result.Status = if ($instCu -eq 0) { 'No cumulative update installed' } else { "$behind CU$(if ($behind -ne 1) { 's' }) behind" }
            $result.Severity = if ($behind -ge $SqlCuBehindCritical) { 'Critical' } elseif ($age -gt $SqlGraceDays) { 'Warning' } else { 'Info' }
            $result.Action = "Apply $($latestAny.UpdateName) (KB$($latestAny.KB)) after testing."
        }
    } else {
        $family = if ($inst -and $inst.UpdateName -match 'Azure Connect') { $true } else { $false }
        $gdrRows = @($spRows | Where-Object { -not $_.CuNumber -and $_.UpdateName -match 'GDR|Security' -and (($_.UpdateName -match 'Azure Connect') -eq $family) })
        $latest = $gdrRows | Select-Object -Last 1
        if (-not $latest -or $ver -ge $latest.Version) {
            $result.Status = 'Up to date (GDR branch)'; $result.Severity = 'OK'
            if ($latest) { $result.Latest = $latest.Version.ToString(); $result.LatestRelease = "$($latest.UpdateName) (KB$($latest.KB))"; $result.Released = Format-Date $latest.ReleaseDate }
        } else {
            $behind = @($gdrRows | Where-Object { $_.Version -gt $ver }).Count
            $age = ($today - [datetime]$latest.ReleaseDate).TotalDays
            $result.Latest = $latest.Version.ToString(); $result.LatestRelease = "$($latest.UpdateName) (KB$($latest.KB))"; $result.Released = Format-Date $latest.ReleaseDate
            $result.Status = "$behind security update$(if ($behind -ne 1) { 's' }) behind (GDR branch)"
            $result.Severity = if ($behind -ge 2) { 'Critical' } elseif ($age -gt $SqlGraceDays) { 'Warning' } else { 'Info' }
            $result.Action = "Apply KB$($latest.KB). Consider moving to the cumulative update branch."
        }
    }
    return [pscustomobject]$result
}

function Get-WindowsStatus($Os) {
    $life = if ($Os -and $Os.Build) { $winLifecycle[[int]$Os.Build] } else { $null }
    $result = [ordered]@{ Latest = ''; LatestRelease = ''; Released = ''; Status = 'Not checked'; Severity = 'Info'; Action = ''
                          Support = $(if ($life) { Get-SupportText $life[1] } else { '' }) }
    if (-not $Os -or -not $Os.Build) { $result.Action = $(if ($Os) { $Os.Note } else { 'Could not read the Windows version.' }); return [pscustomobject]$result }
    if ($Os.Type -and $Os.Type -notlike 'Server*') { $result.Status = 'Not checked (not Windows Server)'; return [pscustomobject]$result }
    if ([int]$Os.Build -lt 10000) { $result.Status = 'Not checked (Windows Server 2012 / 2012 R2)'; $result.Action = 'Confirm in Windows Update that the latest monthly rollup is installed.'; return [pscustomobject]$result }
    if ($null -eq $Os.Ubr) { $result.Status = 'Not checked (update revision unavailable)'; $result.Action = $Os.Note; return [pscustomobject]$result }
    $rows = @($winRef | Where-Object { $_.BuildNumber -eq [int]$Os.Build } | Sort-Object { [datetime]$_.ReleaseDate }, Revision)
    if (-not $rows) { $result.Action = "No Microsoft security data for Windows build $($Os.Build)."; return [pscustomobject]$result }
    $latest = $rows[-1]
    $missing = @($rows | Where-Object { $_.Revision -gt [int]$Os.Ubr })
    $result.Latest = "$($latest.BuildNumber).$($latest.Revision)"; $result.LatestRelease = "KB$($latest.KB) ($($latest.Source))"; $result.Released = Format-Date $latest.ReleaseDate
    if ($missing.Count -eq 0) {
        $result.Status = 'Up to date'; $result.Severity = 'OK'
    } else {
        $age = ($today - [datetime]$latest.ReleaseDate).TotalDays
        $result.Status = "$($missing.Count) monthly security update$(if ($missing.Count -ne 1) { 's' }) missing"
        $result.Severity = if ($missing.Count -ge 2) { 'Critical' } elseif ($age -gt $WindowsGraceDays) { 'Warning' } else { 'Info' }
        $result.Action = "Install the latest cumulative security update KB$($latest.KB) and restart (includes all earlier security fixes)."
    }
    return [pscustomobject]$result
}

# =============================================================================================
#  Discovery and collection (read-only)
# =============================================================================================
function Test-IsLocal([string]$HostName) {
    return $HostName -in @('.', 'localhost', '(local)', '127.0.0.1', '(localdb)', $env:COMPUTERNAME) -or $HostName -like "$env:COMPUTERNAME.*"
}

function Get-BrowserInstances([string]$HostName) {
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 2000
        $udp.Connect($HostName, 1434)
        [void]$udp.Send([byte[]]@(2), 1)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $bytes = $udp.Receive([ref]$remote)
        if ($bytes.Length -le 3) { return @() }
        $text = [System.Text.Encoding]::ASCII.GetString($bytes, 3, $bytes.Length - 3)
        foreach ($entry in ($text -split ';;' | Where-Object { $_ })) {
            $parts = $entry -split ';'; $h = @{}
            for ($i = 0; $i -lt $parts.Count - 1; $i += 2) { $h[$parts[$i]] = $parts[$i + 1] }
            if ($h['InstanceName']) {
                $name = if ($h['InstanceName'] -eq 'MSSQLSERVER') { $HostName } else { "$HostName\$($h['InstanceName'])" }
                $connect = if ($h['tcp']) { "$HostName,$($h['tcp'])" } else { $name }
                [pscustomobject]@{ Instance = $name; Connect = $connect; Source = 'SQL Browser' }
            }
        }
    } catch { @() } finally { $udp.Close() }
}

function Get-ServiceInstances([string]$HostName) {
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.ServiceProcess }
        $target = if (Test-IsLocal $HostName) { '.' } else { $HostName }
        foreach ($svc in [System.ServiceProcess.ServiceController]::GetServices($target)) {
            if ($svc.ServiceName -eq 'MSSQLSERVER' -or $svc.ServiceName -like 'MSSQL$*') {
                $name = if ($svc.ServiceName -eq 'MSSQLSERVER') { $HostName } else { "$HostName\$($svc.ServiceName.Substring(6))" }
                [pscustomobject]@{ Instance = $name; Connect = $name; Source = 'Services'; Running = ($svc.Status -eq 'Running') }
            }
        }
    } catch { @() }
}

function Open-Sql([string]$Target) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Target; $b['Initial Catalog'] = 'master'; $b['TrustServerCertificate'] = $true
    $b['Application Name'] = 'Patch status check'; $b['Connect Timeout'] = $ConnectTimeoutSeconds
    if ($SqlCredential) { $b['User ID'] = $SqlCredential.UserName; $b['Password'] = $SqlCredential.GetNetworkCredential().Password }
    else { $b['Integrated Security'] = $true }
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $conn.Open()
    return $conn
}

function Get-SqlFacts($Conn) {
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = @"
SELECT Version = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')),
       Edition = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
       UpdateLevel = CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateLevel')),
       ServerName = @@SERVERNAME,
       HostName = CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')),
       IsSysadmin = IS_SRVROLEMEMBER('sysadmin'),
       IsWindows = CASE WHEN @@VERSION LIKE '% on Linux%' THEN 0 ELSE 1 END;
"@
    $dt = New-Object System.Data.DataTable; $dt.Load($cmd.ExecuteReader()); return $dt.Rows[0]
}

function Get-OsFromSql($Conn) {
    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = @"
DECLARE @k nvarchar(200) = N'SOFTWARE\Microsoft\Windows NT\CurrentVersion', @b nvarchar(50), @u int, @t nvarchar(50), @p nvarchar(200);
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @k, @value_name = N'CurrentBuild', @value = @b OUTPUT;
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @k, @value_name = N'UBR', @value = @u OUTPUT;
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @k, @value_name = N'InstallationType', @value = @t OUTPUT;
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @k, @value_name = N'ProductName', @value = @p OUTPUT;
SELECT Build = @b, Ubr = @u, Type = @t, Name = @p;
"@
    $dt = New-Object System.Data.DataTable; $dt.Load($cmd.ExecuteReader())
    $r = $dt.Rows[0]
    if ($r.Build -is [DBNull] -or -not "$($r.Build)") { return $null }
    return [pscustomobject]@{ Build = [int]$r.Build; Ubr = $(if ($r.Ubr -is [DBNull]) { $null } else { [int]$r.Ubr }); Type = "$($r.Type)"; Name = "$($r.Name)"; Method = 'via SQL Server'; Note = '' }
}

function Get-OsFromRegistry([string]$HostName) {
    try {
        $base = if (Test-IsLocal $HostName) { [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Default') }
                else { [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $HostName) }
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        $ubr = $key.GetValue('UBR')
        $os = [pscustomobject]@{ Build = [int]$key.GetValue('CurrentBuild'); Ubr = $(if ($null -ne $ubr) { [int]$ubr } else { $null })
                                 Type = [string]$key.GetValue('InstallationType'); Name = [string]$key.GetValue('ProductName')
                                 Method = $(if (Test-IsLocal $HostName) { 'local registry' } else { 'Remote Registry' }); Note = '' }
        $key.Close(); $base.Close()
        return $os
    } catch { return $null }
}

# =============================================================================================
#  Run
# =============================================================================================
if ($ServerList) { Get-Content $ServerList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $allComputers.Add($_) } }
if ($allComputers.Count -eq 0) { $allComputers.Add($env:COMPUTERNAME) }

$results = New-Object System.Collections.Generic.List[object]
$hostOs = @{}

function Add-Result($Server, $Instance, $Component, $Product, $Installed, $Status, $Extra) {
    $results.Add([pscustomobject]@{
        Server = $Server; Instance = $Instance; Component = $Component; Product = $Product; Installed = $Installed
        Latest = $Status.Latest; LatestRelease = $Status.LatestRelease; Released = $Status.Released
        Status = $Status.Status; Severity = $Status.Severity; Action = $Status.Action; Support = $Status.Support; Notes = $Extra
    })
}

foreach ($entry in ($allComputers | Select-Object -Unique)) {
    Write-Host ''
    Write-Host "[$entry]" -ForegroundColor Cyan
    $explicit = $entry -match '[\\,]'
    $hostName = ($entry -replace '^tcp:', '' -split '[\\,]')[0]
    if (Test-IsLocal $hostName) { $hostName = $env:COMPUTERNAME }

    if ($explicit) {
        $instances = @([pscustomobject]@{ Instance = $entry; Connect = $entry; Source = 'Given'; Running = $true })
    } else {
        $instances = @(Get-BrowserInstances $hostName)
        $services = @(Get-ServiceInstances $hostName)
        foreach ($s in $services) { if ($s.Instance -notin $instances.Instance) { $instances += $s } }
        if (-not $instances) { $instances = @([pscustomobject]@{ Instance = $hostName; Connect = $hostName; Source = 'Default instance guess'; Running = $true }) }
        Write-Host "  Instances: $(($instances | ForEach-Object { "$($_.Instance) [$($_.Source)]" }) -join ', ')"
    }

    $hostKey = $hostName.ToUpperInvariant()
    foreach ($i in $instances) {
        if ($i.PSObject.Properties['Running'] -and -not $i.Running) {
            Add-Result $hostName $i.Instance 'SQL Server' '' '' ([pscustomobject]@{ Status = 'Not checked (service stopped)'; Severity = 'Info'; Action = ''; Latest = ''; LatestRelease = ''; Released = ''; Support = '' }) 'Found in the service list but not running.'
            continue
        }
        $conn = $null
        try {
            $conn = Open-Sql $i.Connect
            $facts = Get-SqlFacts $conn
            $status = Get-SqlStatus $facts.Version
            $life = $sqlLifecycle[([version]$facts.Version).Major]
            $product = "$(if ($life) { $life[0] } else { 'SQL Server' }) $($facts.Edition)"
            Add-Result $hostName $i.Instance 'SQL Server' $product "$($facts.Version) - $($status.InstalledUpdate)" $status ''
            Write-Host "  $($i.Instance): SQL Server $($facts.Version) - $($status.Status)"
            if ($facts.HostName -and "$($facts.HostName)" -ne '') { $hostKey = "$($facts.HostName)".ToUpperInvariant() }

            if (-not $hostOs.ContainsKey($hostKey) -and $facts.IsWindows -eq 1) {
                $os = $null
                try { $os = Get-OsFromSql $conn } catch { }
                if (-not $os) {
                    $os = Get-OsFromRegistry $hostName
                    if (-not $os) {
                        $why = if ($facts.IsSysadmin -ne 1) { 'Not sysadmin on SQL Server (needed to read the registry through SQL)' } else { 'Registry read through SQL Server failed' }
                        $os = [pscustomobject]@{ Build = $null; Ubr = $null; Type = ''; Name = ''; Method = ''; Note = "$why, and Remote Registry is unavailable. Run the script on the server itself to check Windows." }
                    }
                }
                $hostOs[$hostKey] = [pscustomobject]@{ Server = $hostName; Os = $os }
            }
        }
        catch {
            $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
            Write-Host "  $($i.Instance): could not connect - $($e.Message)" -ForegroundColor Yellow
            Add-Result $hostName $i.Instance 'SQL Server' '' '' ([pscustomobject]@{ Status = 'Could not connect'; Severity = 'Warning'; Action = 'Check the instance name, network access and that this account has a SQL login.'; Latest = ''; LatestRelease = ''; Released = ''; Support = '' }) $e.Message
        }
        finally { if ($conn) { $conn.Close() } }
    }

    # Windows for a host where no SQL connection worked
    if (-not $hostOs.ContainsKey($hostKey) -and -not ($results | Where-Object { $_.Server -eq $hostName -and $_.Component -eq 'Windows' })) {
        $os = Get-OsFromRegistry $hostName
        if (-not $os) { $os = [pscustomobject]@{ Build = $null; Ubr = $null; Type = ''; Name = ''; Method = ''; Note = 'Could not read the Windows version (no SQL connection and Remote Registry unavailable).' } }
        $hostOs[$hostKey] = [pscustomobject]@{ Server = $hostName; Os = $os }
    }
}

foreach ($k in $hostOs.Keys) {
    $h = $hostOs[$k]; $os = $h.Os
    $status = Get-WindowsStatus $os
    $installed = if ($os.Build) { "$($os.Build)$(if ($null -ne $os.Ubr) { ".$($os.Ubr)" })" } else { '' }
    $how = ''
    if ($os.Method) { $how = "Read $($os.Method)" }
    Add-Result $h.Server '' 'Windows' $os.Name $installed $status $how
    Write-Host "  $($h.Server): Windows $installed - $($status.Status)"
}

# =============================================================================================
#  Report
# =============================================================================================
$order = @{ Critical = 0; Warning = 1; Info = 2; OK = 3 }
$sorted = $results | Sort-Object Server, @{ Expression = { if ($_.Component -eq 'Windows') { 0 } else { 1 } } }, Instance
$counts = @{}; foreach ($s in 'Critical', 'Warning', 'Info', 'OK') { $counts[$s] = @($results | Where-Object { $_.Severity -eq $s }).Count }

Write-Host ''
$sorted | Format-Table Server, Component, Instance, Installed, Status, Severity -AutoSize | Out-String -Width 220 | Write-Host

if ($CsvPath) { $sorted | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8; Write-Host "CSV saved: $CsvPath" }

if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) "PatchStatus_$((Get-Date).ToString('yyyyMMdd_HHmm')).html" }
function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
$overall = if ($counts.Critical) { 'Critical' } elseif ($counts.Warning) { 'Warning' } else { 'OK' }
$overallText = @{ Critical = 'Action required'; Warning = 'Attention recommended'; OK = 'No issues found' }[$overall]
$rowsHtml = ($sorted | ForEach-Object {
    $cls = @{ Critical = 'critical'; Warning = 'warning'; Info = 'info'; OK = 'ok' }[$_.Severity]
    $latest = '-'
    if ($_.Latest) { $latest = (Enc $_.Latest) + '<br /><span class="sub">' + (Enc $_.LatestRelease) + '</span>' }
    $component = Enc $_.Component
    if ($_.Instance) { $component += '<br /><span class="sub">' + (Enc $_.Instance) + '</span>' }
    $action = Enc $_.Action
    if ($_.Notes) { $action += '<br /><span class="sub">' + (Enc $_.Notes) + '</span>' }
    '<tr><td>' + (Enc $_.Server) + '</td><td>' + $component + '</td><td>' + (Enc $_.Product) + '<br /><span class="sub">' + (Enc $_.Support) + '</span></td>' +
    '<td>' + (Enc $_.Installed) + '</td><td>' + $latest + '</td><td>' + (Enc $_.Released) + '</td><td class="' + $cls + '">' + (Enc $_.Status) + '</td><td>' + $action + '</td></tr>'
}) -join "`n"

$html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Patch status - $(Get-Date -Format 'dd MMM yyyy')</title>
<style>
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.45}
.wrap{max-width:1200px;margin:0 auto;padding:24px}
.hero{background:#231F20;color:#fff;padding:22px 28px}.hero h1{margin:0;font-size:24px}.meta{color:#BFBBBA;font-size:13px;margin-top:6px}
.rag{display:inline-block;margin-top:14px;padding:7px 14px;font-weight:700}.rag-Critical{background:#D64545;color:#fff}.rag-Warning{background:#F2A93B}.rag-OK{background:#3FA66B;color:#fff}
.cards{display:flex;gap:12px;margin:18px 0;flex-wrap:wrap}.card{background:#fff;padding:12px 18px;min-width:110px;border-top:4px solid #BFBBBA}
.card b{display:block;font-size:24px}.c-critical{border-color:#D64545}.c-warning{border-color:#F2A93B}.c-info{border-color:#44C8F5}.c-ok{border-color:#3FA66B}
table{width:100%;border-collapse:collapse;background:#fff;font-size:13px}th{background:#231F20;color:#fff;text-align:left;padding:8px 10px}
td{padding:8px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}.sub{color:#7A7473;font-size:12px}
td.critical{background:#D64545;color:#fff;font-weight:600}td.warning{background:#F9D58C;font-weight:600}td.info{background:#DDF3FC}td.ok{background:#D5EEDD}
.note{color:#7A7473;font-size:12px;margin-top:16px}
</style></head><body><div class="wrap">
<div class="hero"><h1>SQL Server &amp; Windows patch status</h1>
<div class="meta">Run $(Get-Date -Format 'dddd dd MMMM yyyy HH:mm') on $env:COMPUTERNAME as $([Environment]::UserDomainName)\$([Environment]::UserName) &#183; Microsoft update data from $($referenceDate.ToString('dd MMM yyyy'))</div>
<div class="rag rag-$overall">$overallText</div></div>
<div class="cards"><div class="card c-critical"><b>$($counts.Critical)</b>Critical</div><div class="card c-warning"><b>$($counts.Warning)</b>Warning</div><div class="card c-info"><b>$($counts.Info)</b>Info</div><div class="card c-ok"><b>$($counts.OK)</b>Up to date</div></div>
<table><tr><th>Server</th><th>Component</th><th>Product / support</th><th>Installed</th><th>Latest available</th><th>Released</th><th>Status</th><th>Action / notes</th></tr>
$rowsHtml
</table>
<p class="note"><b>Windows</b>: the installed OS build (CurrentBuild.UBR) is compared with the build that contains each monthly security update published by Microsoft (last $Months months). Feature and optional preview updates are ignored; other software (.NET, drivers) is not covered. Critical once two monthly updates are missed; Warning when the latest is missing more than $WindowsGraceDays days after release.<br />
<b>SQL Server</b>: compared with Microsoft's published cumulative updates (CU) and security updates (GDR) on the branch the instance uses. Critical at $SqlCuBehindCritical or more CUs behind; Warning when a newer CU has been available for more than $SqlGraceDays days.</p>
</div></body></html>
"@
[System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
Write-Host "Report saved: $OutputPath" -ForegroundColor Green
if ($Open) { Start-Process $OutputPath }

if ($counts.Critical) { exit 2 } elseif ($counts.Warning) { exit 1 } else { exit 0 }
}
