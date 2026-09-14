<#
.SYNOPSIS
    Downloads Microsoft's latest SQL Server and Windows Server security build data and loads it into
    Molehill Watch on each instance, so the weekly report can check patch levels.

.DESCRIPTION
    Sources (both published by Microsoft):
      * SQL Server: every CU and GDR build, KB and release date, from the "Latest updates and version
        history for SQL Server" article (MicrosoftDocs/SupportArticles-docs on GitHub).
      * Windows Server 2016/2019/2022/2025: the OS build that contains each month's security update,
        from the Microsoft Security Response Center (MSRC) CVRF API.

    SQL Server can't reach the internet from an Agent job, so run this from a machine that can: the jump box,
    or your own PC. If no single machine has both internet access and SQL access:
      1. On a PC with internet:      .\Update-PatchReference.ps1 -OutFile patch-reference.json
      2. Copy the file to the jump box
      3. On the jump box:            .\Update-PatchReference.ps1 -InFile patch-reference.json -ServerList .\servers.txt

    Needs only the Molehill Data Services read-only login (it can refresh this reference table and nothing else).
    Install-MolehillWatch.ps1 and Export-WeeklyReports.ps1 -UpdatePatchReference call this for you.

.EXAMPLE
    .\Update-PatchReference.ps1 -ServerList .\servers.txt

.EXAMPLE
    .\Update-PatchReference.ps1 -SqlInstance 10.0.0.4,10.0.0.5 -SqlCredential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string[]] $SqlInstance,
    [string] $ServerList,
    [pscredential] $SqlCredential,
    [string] $OutFile,
    [string] $InFile,
    [ValidateRange(2, 12)] [int] $Months = 3
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($ServerList) { $SqlInstance = Get-Content $ServerList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } }
if (-not $SqlInstance -and -not $OutFile) { throw 'Give -SqlInstance or -ServerList to load the data, and/or -OutFile to save it.' }

function Get-Text([string]$Url, [string]$Accept) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'MolehillWatch-PatchReference')
    if ($Accept) { $wc.Headers.Add('Accept', $Accept) }
    try { return $wc.DownloadString($Url) } finally { $wc.Dispose() }
}

function ConvertFrom-BigJson([string]$Text) {
    # Windows PowerShell 5.1's ConvertFrom-Json can't handle the 15 MB MSRC documents; both paths return dictionaries.
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ,($Text | ConvertFrom-Json -AsHashtable) }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return ,$ser.DeserializeObject($Text)
}

function Get-SqlServerBuilds {
    $url = 'https://raw.githubusercontent.com/MicrosoftDocs/SupportArticles-docs/main/support/sql/releases/download-and-install-latest-updates.md'
    Write-Host "Downloading SQL Server build list from Microsoft..."
    $lines = (Get-Text $url) -split "`r?`n"
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $product = $null
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -match '^###\s+SQL Server (\d{4})(\s+R2)?\s*$') {
            $product = if ($Matches[2] -or [int]$Matches[1] -lt 2012) { $null } else { "SQL Server $($Matches[1])" }
            continue
        }
        if ($line -match '^##\s' ) { $product = $null; continue }
        if (-not $product -or $line -notmatch '^\|\s*(\d+)\.(\d+)\.(\d+)\.(\d+)\s*\|') { continue }
        $cells = $line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() }
        if ($cells.Count -lt 5) { continue }
        $v = $cells[0].Split('.')
        $update = $cells[2] -replace '\[([^\]]*)\]\([^)]*\)', '$1'
        $kb = if ($cells[3] -match 'KB\s*(\d+)') { $Matches[1] } elseif ($cells[3] -match '(\d{6,7})') { $Matches[1] } else { $null }
        $date = $null
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(($cells[4] -replace '\s+', ' '), [string[]]@('MMMM dd, yyyy', 'MMMM d, yyyy'), $culture, 'None', [ref]$parsed)) { $date = $parsed.ToString('yyyy-MM-dd') }
        $cu = if ($update -match '\bCU\s*(\d+)') { [int]$Matches[1] } else { $null }
        $rows.Add([pscustomobject]@{
            Product = 'SQL Server'; ProductName = $product; Major = [int]$v[0]; Minor = [int]$v[1]; BuildNumber = [int]$v[2]; Revision = [int]$v[3]
            ServicePack = $cells[1]; UpdateName = $update; CuNumber = $cu; KB = $kb; ReleaseDate = $date; Source = 'Microsoft SQL Server build list'
        })
    }
    if ($rows.Count -lt 100) { throw "Only $($rows.Count) SQL Server builds were read - the Microsoft article format may have changed." }
    Write-Host "  $($rows.Count) SQL Server builds (2012 onwards)"
    return $rows.ToArray()
}

function Get-WindowsSecurityBuilds([int]$MonthCount) {
    Write-Host "Downloading Windows security update data from MSRC..."
    $index = Get-Text 'https://api.msrc.microsoft.com/cvrf/v3.0/updates' 'application/json' | ConvertFrom-Json
    $releases = $index.value | Where-Object { $_.ID -match '^\d{4}-[A-Za-z]{3}$' -and [datetime]$_.InitialReleaseDate -le (Get-Date) } |
                Sort-Object { [datetime]$_.InitialReleaseDate } -Descending | Select-Object -First $MonthCount
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $releases) {
        Write-Host "  $($rel.ID) security release..."
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
                $product = $product -replace '\s*\(Server Core installation\)', ''
                if (-not $best.ContainsKey($build) -or $best[$build].Revision -lt $ubr) {
                    $kb = if ($r['Description'] -and $r['Description']['Value']) { [string]$r['Description']['Value'] } else { $null }
                    $best[$build] = [pscustomobject]@{
                        Product = 'Windows Server'; ProductName = $product; Major = 10; Minor = 0; BuildNumber = $build; Revision = $ubr
                        ServicePack = $null; UpdateName = 'Security Update'; CuNumber = $null; KB = $kb
                        ReleaseDate = ([datetime]$rel.InitialReleaseDate).ToString('yyyy-MM-dd'); Source = $rel.ID
                    }
                }
            }
        }
        foreach ($k in $best.Keys) { $rows.Add($best[$k]) }
        $doc = $null
    }
    if ($rows.Count -eq 0) { throw 'No Windows Server security builds were read from MSRC - the API format may have changed.' }
    foreach ($g in ($rows | Group-Object ProductName | Sort-Object Name)) {
        $latest = $g.Group | Sort-Object ReleaseDate -Descending | Select-Object -First 1
        Write-Host "  $($g.Name): latest security build $($latest.BuildNumber).$($latest.Revision) (KB$($latest.KB), $($latest.Source))"
    }
    return $rows.ToArray()
}

# ---- get the data ---------------------------------------------------------------------------
if ($InFile) {
    Write-Host "Reading $InFile"
    $data = Get-Content -Raw -Path $InFile | ConvertFrom-Json
    $reference = @($data.Rows)
    Write-Host "  $($reference.Count) builds, downloaded $($data.Downloaded)"
} else {
    $reference = @(Get-SqlServerBuilds) + @(Get-WindowsSecurityBuilds $Months)
}

if ($OutFile) {
    [pscustomobject]@{ Downloaded = (Get-Date).ToString('s'); Rows = $reference } | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host "Saved $($reference.Count) builds to $OutFile" -ForegroundColor Green
}

# ---- load into each instance ------------------------------------------------------------------
$failed = 0
foreach ($instance in $SqlInstance) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $instance; $b['Initial Catalog'] = 'MolehillWatch'; $b['TrustServerCertificate'] = $true
    $b['Application Name'] = 'Molehill Watch Patch Reference'; $b['Connect Timeout'] = 15
    if ($SqlCredential) { $b['User ID'] = $SqlCredential.UserName; $b['Password'] = $SqlCredential.GetNetworkCredential().Password }
    else { $b['Integrated Security'] = $true }
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    try {
        $conn.Open()
        $tran = $conn.BeginTransaction()
        foreach ($product in ($reference | Select-Object -ExpandProperty Product -Unique)) {
            $clear = $conn.CreateCommand(); $clear.Transaction = $tran
            $clear.CommandText = 'EXEC dbo.usp_PatchReference_Clear @Product = @Product;'
            [void]$clear.Parameters.AddWithValue('@Product', $product)
            [void]$clear.ExecuteNonQuery()
        }
        $cmd = $conn.CreateCommand(); $cmd.Transaction = $tran
        $cmd.CommandText = 'EXEC dbo.usp_PatchReference_Add @Product, @ProductName, @Major, @Minor, @BuildNumber, @Revision, @ServicePack, @UpdateName, @CuNumber, @KB, @ReleaseDate, @Source;'
        foreach ($name in 'Product', 'ProductName', 'Major', 'Minor', 'BuildNumber', 'Revision', 'ServicePack', 'UpdateName', 'CuNumber', 'KB', 'ReleaseDate', 'Source') {
            [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter("@$name", [System.Data.SqlDbType]::NVarChar, 200)))
        }
        foreach ($row in $reference) {
            foreach ($name in 'Product', 'ProductName', 'Major', 'Minor', 'BuildNumber', 'Revision', 'ServicePack', 'UpdateName', 'CuNumber', 'KB', 'ReleaseDate', 'Source') {
                $value = $row.$name
                $cmd.Parameters["@$name"].Value = if ($null -eq $value -or "$value" -eq '') { [DBNull]::Value } else { [string]$value }
            }
            [void]$cmd.ExecuteNonQuery()
        }
        $tran.Commit()
        Write-Host "[$instance] loaded $($reference.Count) builds" -ForegroundColor Green
    }
    catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        Write-Host "[$instance] FAILED: $($e.Message)" -ForegroundColor Red
        $failed++
    }
    finally { $conn.Close() }
}
if ($failed) { exit 1 }
