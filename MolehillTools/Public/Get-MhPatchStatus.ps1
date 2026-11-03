<#
.SYNOPSIS
    Says how far behind on patches each SQL Server and the Windows under it is, against Microsoft's
    own build data.

.DESCRIPTION
    Reads the build of every SQL Server instance it can find on each machine, and the Windows
    update revision, then compares both with Microsoft's published build lists: the SQL Server
    build numbers page and the Windows monthly security updates. Nothing is installed and nothing
    is changed.

    For SQL Server it works out which branch an instance is on - cumulative updates or the
    security-only GDR branch - and reports how far behind it is on that branch, because telling
    someone on GDR to apply a CU is how you move a server onto a branch nobody meant to be on.

    For Windows it counts the monthly security updates released since the installed revision.

    Severity is Critical, Warning, Info or OK: how far behind, tempered by how long the latest
    update has been out, since something released last week is not the same as something released
    last year. -SqlGraceDays, -SqlCuBehindCritical and -WindowsGraceDays set where those lines
    are.

    Needs the internet for the reference data, or -ReferenceFile for a copy saved earlier with
    -SaveReference, which is how this runs against servers with no route out.

.PARAMETER ComputerName
    The machines to check. Also takes a pipeline. Defaults to this machine.

.PARAMETER ServerList
    A file of machine names, one per line. Blank lines and # comments are ignored.

.PARAMETER SqlCredential
    SQL authentication. Windows authentication is used when this is left out.

.PARAMETER ReferenceFile
    Microsoft's build data saved earlier, instead of fetching it. For a machine with no internet.

.PARAMETER SaveReference
    Fetch the build data and save it to this file, then stop. Run this somewhere with internet,
    then use -ReferenceFile on the machines without.

.PARAMETER OutputPath
    Where the HTML report goes. Defaults to the current folder.

.PARAMETER CsvPath
    Write the per-component detail to this file as well.

.PARAMETER Open
    Open the report when it is written.

.PARAMETER SqlGraceDays
    How long a SQL update may have been out before being behind it counts as a Warning. Default 30.

.PARAMETER SqlCuBehindCritical
    How many cumulative updates behind counts as Critical. Default 3.

.PARAMETER WindowsGraceDays
    How long a Windows update may have been out before being behind it counts as a Warning.
    Default 14.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for each instance. Default 10.

.PARAMETER Months
    How many months of Windows security updates to read. Default 3.

.OUTPUTS
    One object per component found, with the installed build, the latest, how far behind, the
    severity and what to do about it.

.EXAMPLE
    Get-MhPatchStatus -ComputerName SQL01, SQL02

.EXAMPLE
    # once, somewhere with internet
    Get-MhPatchStatus -SaveReference .\builds.json
    # then, on the server that has none
    Get-MhPatchStatus -ComputerName SQL01 -ReferenceFile .\builds.json

.NOTES
    Molehill Data Services. Read-only: catalogue views, the registry, and Microsoft's published
    build data.
#>

function Get-MhPatchStatus {
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
        [Parameter(ParameterSetName = 'Check')] [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 10,
        [Parameter(ParameterSetName = 'Check')] [string[]] $EmailTo,
        [Parameter(ParameterSetName = 'Check')] [string] $EmailFrom,
        [Parameter(ParameterSetName = 'Check')] [string] $SmtpServer,
        [Parameter(ParameterSetName = 'Check')] [ValidateRange(1, 65535)] [int] $SmtpPort = 25,
        [Parameter(ParameterSetName = 'Check')] [switch] $SmtpUseSsl,
        [Parameter(ParameterSetName = 'Check')] [pscredential] $SmtpCredential,
        [Parameter(ParameterSetName = 'Check')] [string] $EmailSubject,
        [Parameter(ParameterSetName = 'Check')] [ValidateSet('Always', 'Critical', 'CriticalOrWarning')] [string] $EmailWhen = 'Always',
        [Parameter(ParameterSetName = 'Check')] [ValidateSet('Pdf', 'Html', 'Both')] [string] $AttachAs = 'Pdf',
        [Parameter(ParameterSetName = 'Check')] [string] $PdfPath,
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
        if ($PSCmdlet.ParameterSetName -eq 'Download') {
            $rows = @(Get-PatchSqlServerBuilds) + @(Get-PatchWindowsBuilds $Months)
            [pscustomobject]@{ Downloaded = (Get-Date).ToString('s'); Rows = $rows } | ConvertTo-Json -Depth 4 | Set-Content -Path $SaveReference -Encoding UTF8
            Write-Host "Saved $($rows.Count) builds to $SaveReference. Copy it next to Get-PatchStatus.ps1 on the server (or pass -ReferenceFile)." -ForegroundColor Green
            return
        }
        # before anything is scanned or downloaded: a report over an estate takes minutes, and
        # finding out at the end that the mail settings were wrong means running it all again
        if ($EmailTo -or $EmailFrom -or $SmtpServer) {
            $emailProblems = @(Get-PatchEmailProblem -To $EmailTo -From $EmailFrom -Server $SmtpServer)
            if ($emailProblems.Count) {
                throw ("The email settings are not usable, so nothing was scanned:`n  " + ($emailProblems -join "`n  "))
            }
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
                $reference = @(Get-PatchSqlServerBuilds) + @(Get-PatchWindowsBuilds $Months)
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
        foreach ($c in $ComputerName) {
            if ($c -and -not $allComputers.Contains($c.Trim())) { $allComputers.Add($c.Trim()) }
        }
        if ($ServerList) { Get-Content $ServerList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $allComputers.Add($_) } }
        if ($allComputers.Count -eq 0) { $allComputers.Add($env:COMPUTERNAME) }
        $results = New-Object System.Collections.Generic.List[object]
        $hostOs = @{}
        foreach ($entry in ($allComputers | Select-Object -Unique)) {
            Write-Host ''
            Write-Host "[$entry]" -ForegroundColor Cyan
            $explicit = $entry -match '[\\,]'
            $hostName = ($entry -replace '^tcp:', '' -split '[\\,]')[0]
            if (Test-PatchIsLocal $hostName) { $hostName = $env:COMPUTERNAME }

            if ($explicit) {
                $instances = @([pscustomobject]@{ Instance = $entry; Connect = $entry; Source = 'Given'; Running = $true })
            } else {
                $instances = @(Get-PatchBrowserInstances $hostName)
                $services = @(Get-PatchServiceInstances $hostName)
                foreach ($s in $services) { if ($s.Instance -notin $instances.Instance) { $instances += $s } }
                if (-not $instances) { $instances = @([pscustomobject]@{ Instance = $hostName; Connect = $hostName; Source = 'Default instance guess'; Running = $true }) }
                Write-Host "  Instances: $(($instances | ForEach-Object { "$($_.Instance) [$($_.Source)]" }) -join ', ')"
            }

            $hostKey = $hostName.ToUpperInvariant()
            foreach ($i in $instances) {
                if ($i.PSObject.Properties['Running'] -and -not $i.Running) {
                    Add-PatchResult $hostName $i.Instance 'SQL Server' '' '' ([pscustomobject]@{ Status = 'Not checked (service stopped)'; Severity = 'Info'; Action = ''; Latest = ''; LatestRelease = ''; Released = ''; Support = '' }) 'Found in the service list but not running.'
                    continue
                }
                $conn = $null
                try {
                    $conn = Open-PatchSqlConnection $i.Connect
                    $facts = Get-PatchSqlFacts $conn
                    $status = Get-PatchSqlStatus $facts.Version
                    $life = $sqlLifecycle[([version]$facts.Version).Major]
                    $product = "$(if ($life) { $life[0] } else { 'SQL Server' }) $($facts.Edition)"
                    Add-PatchResult $hostName $i.Instance 'SQL Server' $product "$($facts.Version) - $($status.InstalledUpdate)" $status ''
                    Write-Host "  $($i.Instance): SQL Server $($facts.Version) - $($status.Status)"
                    if ($facts.HostName -and "$($facts.HostName)" -ne '') { $hostKey = "$($facts.HostName)".ToUpperInvariant() }

                    if (-not $hostOs.ContainsKey($hostKey) -and $facts.IsWindows -eq 1) {
                        $os = $null
                        try { $os = Get-PatchOsFromSql $conn } catch { }
                        if (-not $os) {
                            $os = Get-PatchOsFromRegistry $hostName
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
                    Add-PatchResult $hostName $i.Instance 'SQL Server' '' '' ([pscustomobject]@{ Status = 'Could not connect'; Severity = 'Warning'; Action = 'Check the instance name, network access and that this account has a SQL login.'; Latest = ''; LatestRelease = ''; Released = ''; Support = '' }) $e.Message
                }
                finally { if ($conn) { $conn.Close() } }
            }

            # Windows for a host where no SQL connection worked
            if (-not $hostOs.ContainsKey($hostKey) -and -not ($results | Where-Object { $_.Server -eq $hostName -and $_.Component -eq 'Windows' })) {
                $os = Get-PatchOsFromRegistry $hostName
                if (-not $os) { $os = [pscustomobject]@{ Build = $null; Ubr = $null; Type = ''; Name = ''; Method = ''; Note = 'Could not read the Windows version (no SQL connection and Remote Registry unavailable).' } }
                $hostOs[$hostKey] = [pscustomobject]@{ Server = $hostName; Os = $os }
            }
        }
        foreach ($k in $hostOs.Keys) {
            $h = $hostOs[$k]; $os = $h.Os
            $status = Get-PatchWindowsStatus $os
            $installed = if ($os.Build) { "$($os.Build)$(if ($null -ne $os.Ubr) { ".$($os.Ubr)" })" } else { '' }
            $how = ''
            if ($os.Method) { $how = "Read $($os.Method)" }
            Add-PatchResult $h.Server '' 'Windows' $os.Name $installed $status $how
            Write-Host "  $($h.Server): Windows $installed - $($status.Status)"
        }
        $order = @{ Critical = 0; Warning = 1; Info = 2; OK = 3 }
        $sorted = $results | Sort-Object Server, @{ Expression = { if ($_.Component -eq 'Windows') { 0 } else { 1 } } }, Instance
        $counts = @{}; foreach ($s in 'Critical', 'Warning', 'Info', 'OK') { $counts[$s] = @($results | Where-Object { $_.Severity -eq $s }).Count }
        Write-Host ''
        $sorted | Format-Table Server, Component, Instance, Installed, Status, Severity -AutoSize | Out-String -Width 220 | Write-Host
        if ($CsvPath) { $sorted | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8; Write-Host "CSV saved: $CsvPath" }
        if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) "PatchStatus_$((Get-Date).ToString('yyyyMMdd_HHmm')).html" }
        $overall = if ($counts.Critical) { 'Critical' } elseif ($counts.Warning) { 'Warning' } else { 'OK' }
        $overallText = @{ Critical = 'Action required'; Warning = 'Attention recommended'; OK = 'No issues found' }[$overall]
        $rowsHtml = ($sorted | ForEach-Object {
            $cls = @{ Critical = 'critical'; Warning = 'warning'; Info = 'info'; OK = 'ok' }[$_.Severity]
            $latest = '-'
            if ($_.Latest) { $latest = (Get-PatchHtmlEncoded $_.Latest) + '<br /><span class="sub">' + (Get-PatchHtmlEncoded $_.LatestRelease) + '</span>' }
            $component = Get-PatchHtmlEncoded $_.Component
            if ($_.Instance) { $component += '<br /><span class="sub">' + (Get-PatchHtmlEncoded $_.Instance) + '</span>' }
            $action = Get-PatchHtmlEncoded $_.Action
            if ($_.Notes) { $action += '<br /><span class="sub">' + (Get-PatchHtmlEncoded $_.Notes) + '</span>' }
            '<tr><td>' + (Get-PatchHtmlEncoded $_.Server) + '</td><td>' + $component + '</td><td>' + (Get-PatchHtmlEncoded $_.Product) + '<br /><span class="sub">' + (Get-PatchHtmlEncoded $_.Support) + '</span></td>' +
            '<td>' + (Get-PatchHtmlEncoded $_.Installed) + '</td><td>' + $latest + '</td><td>' + (Get-PatchHtmlEncoded $_.Released) + '</td><td class="' + $cls + '">' + (Get-PatchHtmlEncoded $_.Status) + '</td><td>' + $action + '</td></tr>'
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

        # the PDF: written when it was asked for, or when it is what the email will carry
        $pdfWanted = [bool]$PdfPath -or ($EmailTo -and $AttachAs -ne 'Html')
        if ($pdfWanted) {
            if (-not $PdfPath) { $PdfPath = [System.IO.Path]::ChangeExtension($OutputPath, '.pdf') }
            try {
                [System.IO.File]::WriteAllBytes($PdfPath, (New-PatchPdf -Rows $sorted -Counts $counts -Overall $overall -ReferenceDate $referenceDate))
                Write-Host "PDF saved: $PdfPath" -ForegroundColor Green
            }
            catch {
                # the HTML is already written, so a PDF that could not be built falls back to it
                # rather than taking the whole run down with it
                Write-Warning ("Could not write the PDF ({0}); the HTML report is at {1}." -f ($_.Exception.GetBaseException().Message -split "`r?`n")[0], $OutputPath)
                $PdfPath = ''
            }
        }

        if ($EmailTo) {
            if (-not (Test-PatchEmailWanted -When $EmailWhen -Counts $counts)) {
                Write-Host "No email sent: -EmailWhen $EmailWhen, and there is nothing in that category." -ForegroundColor Gray
            }
            else {
                $serverCount = @($results | ForEach-Object { $_.Server } | Select-Object -Unique).Count
                $subject = Get-PatchEmailSubject -Counts $counts -Overall $overall -ServerCount $serverCount -Template $EmailSubject
                $attach = @()
                if ($AttachAs -ne 'Html' -and $PdfPath) { $attach += $PdfPath }
                if ($AttachAs -ne 'Pdf' -or -not $PdfPath) { $attach += $OutputPath }
                $body = Get-PatchEmailBody -Rows $sorted -Counts $counts -Overall $overall `
                                           -ReportName ((@($attach) | ForEach-Object { Split-Path -Leaf $_ }) -join ' and ') -ReferenceDate $referenceDate
                try {
                    Send-PatchEmail -To $EmailTo -From $EmailFrom -Subject $subject -Body $body `
                                    -AttachmentPath $attach -Server $SmtpServer -Port $SmtpPort `
                                    -UseSsl ([bool]$SmtpUseSsl) -Credential $SmtpCredential
                    Write-Host ("Emailed to {0} via {1}:{2}" -f (@($EmailTo) -join ', '), $SmtpServer, $SmtpPort) -ForegroundColor Green
                }
                catch {
                    # the report is already on disk, so a mail server that will not take it is worth
                    # saying loudly and is not worth throwing away a finished scan over
                    $why = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                    Write-Warning ("The report was produced but could not be emailed: {0}`nIt is saved at {1}." -f $why, $OutputPath)
                }
            }
        }
    }
}

function Get-PatchReferenceText([string]$Url, [string]$Accept) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'PatchStatusCheck')
    if ($Accept) { $wc.Headers.Add('Accept', $Accept) }
    try { return $wc.DownloadString($Url) } finally { $wc.Dispose() }
}

function ConvertFrom-PatchBigJson([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ,($Text | ConvertFrom-Json -AsHashtable) }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return ,$ser.DeserializeObject($Text)
}

<#
  Pulls the build rows out of the rendered article: one section per product, five cells per row.

  Separate from the downloading so that it can be checked against a sample of the page without a
  network, which is the only part of this that is ours to get wrong.
#>
function Get-PatchSqlBuildsFromHtml([string] $Html) {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $rows = New-Object System.Collections.Generic.List[object]

    # one section per product, from its heading to the next heading of any kind
    $headings = [regex]::Matches($Html, '<h([23])[^>]*id="sql-server-(\d{4})(-r2)?"[^>]*>')
    for ($h = 0; $h -lt $headings.Count; $h++) {
        $year = [int]$headings[$h].Groups[2].Value
        $isR2 = [bool]$headings[$h].Groups[3].Value
        $product = if ($isR2 -or $year -lt 2012) { $null } else { "SQL Server $year" }
        if (-not $product) { continue }

        $from = $headings[$h].Index + $headings[$h].Length
        $next = [regex]::Match($Html.Substring($from), '<h[23][^>]*>')
        $section = if ($next.Success) { $Html.Substring($from, $next.Index) } else { $Html.Substring($from) }

        foreach ($row in [regex]::Matches($section, '<tr>\s*<td.*?</tr>', 'Singleline')) {
            $cells = @([regex]::Matches($row.Value, '<td[^>]*>(.*?)</td>', 'Singleline') | ForEach-Object {
                ($_.Groups[1].Value -replace '<br\s*/?>', ' ' -replace '<[^>]+>', '' -replace '&amp;', '&' -replace '&nbsp;', ' ' -replace '\s+', ' ').Trim()
            })
            if ($cells.Count -lt 5 -or $cells[0] -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }

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
    }
    return $rows.ToArray()
}

function Get-PatchSqlServerBuilds {
    Write-Host 'Downloading SQL Server build list from Microsoft...'
    <#
      The markdown this used to read is gone: the article's source moved into a private authoring
      repository, so raw.githubusercontent.com returns 404 for it. The rendered article is the only
      public copy of the complete version list now, and its tables have the same five columns in
      the same order - build, service pack, update, KB, release date - so only the reading of them
      changed, not what is made of them.
    #>
    $html = Get-PatchReferenceText 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates'
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in (Get-PatchSqlBuildsFromHtml $html)) { $rows.Add($row) }

    if ($rows.Count -lt 100) { throw "Only $($rows.Count) SQL Server builds were read - the Microsoft article format may have changed." }
    Write-Host "  $($rows.Count) SQL Server builds"
    return $rows.ToArray()
}

function Get-PatchWindowsBuilds([int]$MonthCount) {
    Write-Host 'Downloading Windows security update data from MSRC...'
    $index = Get-PatchReferenceText 'https://api.msrc.microsoft.com/cvrf/v3.0/updates' 'application/json' | ConvertFrom-Json
    $releases = $index.value | Where-Object { $_.ID -match '^\d{4}-[A-Za-z]{3}$' -and [datetime]$_.InitialReleaseDate -le (Get-Date) } |
                Sort-Object { [datetime]$_.InitialReleaseDate } -Descending | Select-Object -First $MonthCount
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $releases) {
        Write-Host "  $($rel.ID)..."
        $doc = ConvertFrom-PatchBigJson (Get-PatchReferenceText "https://api.msrc.microsoft.com/cvrf/v3.0/cvrf/$($rel.ID)" 'application/json')
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

function Get-PatchSupportText([string]$ExtendedEnd) {
    if (-not $ExtendedEnd) { return 'Supported' }
    $end = [datetime]$ExtendedEnd
    if ($end -lt $today) { return "UNSUPPORTED since $($end.ToString('dd MMM yyyy'))" }
    if ($end -lt $today.AddMonths(12)) { return "Support ends $($end.ToString('dd MMM yyyy'))" }
    return "Supported until $($end.ToString('dd MMM yyyy'))"
}

function Format-PatchDate($d) { if ($d) { ([datetime]$d).ToString('dd MMM yyyy') } else { '' } }

function Get-PatchSqlStatus([string]$VersionText) {
    $ver = [version]$VersionText
    $life = $sqlLifecycle[$ver.Major]
    $result = [ordered]@{ Latest = ''; LatestRelease = ''; Released = ''; Status = 'Not checked'; Severity = 'Info'; Action = ''; InstalledUpdate = ''
                          Support = $(if ($life) { Get-PatchSupportText $life[2] } else { '' }) }
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
        $result.Latest = $latestAny.Version.ToString(); $result.LatestRelease = "$($latestAny.UpdateName) (KB$($latestAny.KB))"; $result.Released = Format-PatchDate $latestAny.ReleaseDate
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
            if ($latest) { $result.Latest = $latest.Version.ToString(); $result.LatestRelease = "$($latest.UpdateName) (KB$($latest.KB))"; $result.Released = Format-PatchDate $latest.ReleaseDate }
        } else {
            $behind = @($gdrRows | Where-Object { $_.Version -gt $ver }).Count
            $age = ($today - [datetime]$latest.ReleaseDate).TotalDays
            $result.Latest = $latest.Version.ToString(); $result.LatestRelease = "$($latest.UpdateName) (KB$($latest.KB))"; $result.Released = Format-PatchDate $latest.ReleaseDate
            $result.Status = "$behind security update$(if ($behind -ne 1) { 's' }) behind (GDR branch)"
            $result.Severity = if ($behind -ge 2) { 'Critical' } elseif ($age -gt $SqlGraceDays) { 'Warning' } else { 'Info' }
            $result.Action = "Apply KB$($latest.KB). Consider moving to the cumulative update branch."
        }
    }
    return [pscustomobject]$result
}

function Get-PatchWindowsStatus($Os) {
    $life = if ($Os -and $Os.Build) { $winLifecycle[[int]$Os.Build] } else { $null }
    $result = [ordered]@{ Latest = ''; LatestRelease = ''; Released = ''; Status = 'Not checked'; Severity = 'Info'; Action = ''
                          Support = $(if ($life) { Get-PatchSupportText $life[1] } else { '' }) }
    if (-not $Os -or -not $Os.Build) { $result.Action = $(if ($Os) { $Os.Note } else { 'Could not read the Windows version.' }); return [pscustomobject]$result }
    if ($Os.Type -and $Os.Type -notlike 'Server*') { $result.Status = 'Not checked (not Windows Server)'; return [pscustomobject]$result }
    if ([int]$Os.Build -lt 10000) { $result.Status = 'Not checked (Windows Server 2012 / 2012 R2)'; $result.Action = 'Confirm in Windows Update that the latest monthly rollup is installed.'; return [pscustomobject]$result }
    if ($null -eq $Os.Ubr) { $result.Status = 'Not checked (update revision unavailable)'; $result.Action = $Os.Note; return [pscustomobject]$result }
    $rows = @($winRef | Where-Object { $_.BuildNumber -eq [int]$Os.Build } | Sort-Object { [datetime]$_.ReleaseDate }, Revision)
    if (-not $rows) { $result.Action = "No Microsoft security data for Windows build $($Os.Build)."; return [pscustomobject]$result }
    $latest = $rows[-1]
    $missing = @($rows | Where-Object { $_.Revision -gt [int]$Os.Ubr })
    $result.Latest = "$($latest.BuildNumber).$($latest.Revision)"; $result.LatestRelease = "KB$($latest.KB) ($($latest.Source))"; $result.Released = Format-PatchDate $latest.ReleaseDate
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

function Test-PatchIsLocal([string]$HostName) {
    return $HostName -in @('.', 'localhost', '(local)', '127.0.0.1', '(localdb)', $env:COMPUTERNAME) -or $HostName -like "$env:COMPUTERNAME.*"
}

function Get-PatchBrowserInstances([string]$HostName) {
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

function Get-PatchServiceInstances([string]$HostName) {
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.ServiceProcess }
        $target = if (Test-PatchIsLocal $HostName) { '.' } else { $HostName }
        foreach ($svc in [System.ServiceProcess.ServiceController]::GetServices($target)) {
            if ($svc.ServiceName -eq 'MSSQLSERVER' -or $svc.ServiceName -like 'MSSQL$*') {
                $name = if ($svc.ServiceName -eq 'MSSQLSERVER') { $HostName } else { "$HostName\$($svc.ServiceName.Substring(6))" }
                [pscustomobject]@{ Instance = $name; Connect = $name; Source = 'Services'; Running = ($svc.Status -eq 'Running') }
            }
        }
    } catch { @() }
}

function Open-PatchSqlConnection([string]$Target) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Target; $b['Initial Catalog'] = 'master'; $b['TrustServerCertificate'] = $true
    $b['Application Name'] = 'Patch status check'; $b['Connect Timeout'] = $ConnectTimeoutSeconds
    if ($SqlCredential) { $b['User ID'] = $SqlCredential.UserName; $b['Password'] = $SqlCredential.GetNetworkCredential().Password }
    else { $b['Integrated Security'] = $true }
    $conn = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    $conn.Open()
    return $conn
}

function Get-PatchSqlFacts($Conn) {
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

function Get-PatchOsFromSql($Conn) {
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

function Get-PatchOsFromRegistry([string]$HostName) {
    try {
        $base = if (Test-PatchIsLocal $HostName) { [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Default') }
                else { [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $HostName) }
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        $ubr = $key.GetValue('UBR')
        $os = [pscustomobject]@{ Build = [int]$key.GetValue('CurrentBuild'); Ubr = $(if ($null -ne $ubr) { [int]$ubr } else { $null })
                                 Type = [string]$key.GetValue('InstallationType'); Name = [string]$key.GetValue('ProductName')
                                 Method = $(if (Test-PatchIsLocal $HostName) { 'local registry' } else { 'Remote Registry' }); Note = '' }
        $key.Close(); $base.Close()
        return $os
    } catch { return $null }
}

function Add-PatchResult($Server, $Instance, $Component, $Product, $Installed, $Status, $Extra) {
    $results.Add([pscustomobject]@{
        Server = $Server; Instance = $Instance; Component = $Component; Product = $Product; Installed = $Installed
        Latest = $Status.Latest; LatestRelease = $Status.LatestRelease; Released = $Status.Released
        Status = $Status.Status; Severity = $Status.Severity; Action = $Status.Action; Support = $Status.Support; Notes = $Extra
    })
}

function Get-PatchHtmlEncoded($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }

<#
  Everything wrong with the email settings, in one go and before the scan starts.

  Said all at once rather than one at a time, and said at the beginning: a report over an estate
  takes minutes, and finding out at the end that -SmtpServer was missing means running the whole
  thing again. The addresses are checked by the framework's own parser rather than by a regex,
  because an address is harder to describe than it looks and MailAddress already knows how.
#>
function Get-PatchEmailProblem {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $To, [string] $From, [string] $Server)

    $problems = @()
    $addresses = @(@($To) | Where-Object { $_ })
    if (-not $addresses.Count) { $problems += '-EmailTo needs at least one address.' }
    if (-not $From) { $problems += '-EmailFrom is needed: a mail server will not take mail with no sender.' }
    if (-not $Server) { $problems += '-SmtpServer is needed: this does not guess at a mail server.' }

    foreach ($address in ($addresses + @($From | Where-Object { $_ }))) {
        try { [void](New-Object System.Net.Mail.MailAddress $address) }
        catch { $problems += ("'{0}' is not an email address." -f $address) }
    }
    $problems
}

# whether this run is worth an email at all, so a nightly job can be told to speak up only when
# something is actually wrong rather than filling an inbox with good news
function Test-PatchEmailWanted {
    [CmdletBinding()]
    param([string] $When, [hashtable] $Counts)

    if ($When -eq 'Critical') { return [bool]$Counts['Critical'] }
    if ($When -eq 'CriticalOrWarning') { return [bool]($Counts['Critical'] + $Counts['Warning']) }
    $true
}

<#
  The subject line, which for most people is the whole report: it has to say the answer, not the
  question. "3 critical" belongs in the subject, not three screens into an attachment.

  -EmailSubject replaces it outright, and can carry the numbers into whatever wording it likes:
  {Critical} {Warning} {Info} {OK} {Servers} {Overall} {Date}. That matters when the recipient is a
  ticket mailbox, where the subject becomes the title of the ticket - a fixed title every night is
  either a pile of identical tickets or, worse, one that nobody notices has changed.

  A token that is not one of these is left exactly as written, because a subject is also where
  people put their own reference numbers in braces and having those eaten would be its own bug.
#>
function Get-PatchEmailSubject {
    [CmdletBinding()]
    param([hashtable] $Counts, [string] $Overall, [int] $ServerCount, [string] $Template, [datetime] $When = (Get-Date))

    if ($Template) {
        $tokens = @{
            '{Critical}' = [string]$Counts['Critical']
            '{Warning}'  = [string]$Counts['Warning']
            '{Info}'     = [string]$Counts['Info']
            '{OK}'       = [string]$Counts['OK']
            '{Servers}'  = [string]$ServerCount
            '{Overall}'  = $Overall
            '{Date}'     = $When.ToString('yyyy-MM-dd')
        }
        $subject = $Template
        foreach ($token in $tokens.Keys) { $subject = $subject.Replace($token, $tokens[$token]) }
        return $subject
    }

    $what = $(
        if ($Overall -eq 'Critical') { '{0} critical' -f $Counts['Critical'] }
        elseif ($Overall -eq 'Warning') { '{0} needing attention' -f $Counts['Warning'] }
        else { 'all up to date' }
    )
    'Patch status: {0} across {1} server{2}' -f $what, $ServerCount, $(if ($ServerCount -eq 1) { '' } else { 's' })
}

<#
  The body of the email: the things that are not fine, and nothing else.

  Styles are written on each element rather than in a stylesheet, because mail clients throw a
  <style> block away and the report's own one would come out as unstyled text. The full report goes
  along as an attachment, so this only has to be enough to decide whether to open it.
#>
function Get-PatchEmailBody {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Rows, [hashtable] $Counts, [string] $Overall,
        [string] $ReportName, [datetime] $ReferenceDate
    )

    $colour = @{ Critical = '#D64545'; Warning = '#F2A93B'; OK = '#3FA66B' }[$Overall]
    $heading = @{ Critical = 'Action required'; Warning = 'Attention recommended'; OK = 'No issues found' }[$Overall]
    $cell = 'padding:6px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top;font-size:13px'

    $interesting = @($Rows | Where-Object { $_.Severity -eq 'Critical' -or $_.Severity -eq 'Warning' })
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add('<div style="font-family:Segoe UI,Arial,sans-serif;color:#231F20">')
    $body.Add(('<p style="margin:0 0 4px 0;padding:8px 14px;background:{0};color:#fff;font-weight:700;display:inline-block">{1}</p>' -f $colour, $heading))
    $body.Add(('<p style="font-size:14px">{0} critical, {1} needing attention, {2} up to date. Microsoft update data from {3}.</p>' -f
               $Counts['Critical'], $Counts['Warning'], $Counts['OK'], $ReferenceDate.ToString('dd MMM yyyy')))

    if ($interesting.Count) {
        $body.Add('<table style="border-collapse:collapse;background:#fff">')
        $body.Add(('<tr>{0}</tr>' -f (@('Server', 'Component', 'Installed', 'Latest', 'Status') |
                   ForEach-Object { '<th style="background:#231F20;color:#fff;text-align:left;padding:6px 10px;font-size:13px">' + $_ + '</th>' }) -join ''))
        foreach ($row in $interesting) {
            $severity = $(if ($row.Severity -eq 'Critical') { 'background:#D64545;color:#fff;font-weight:600' } else { 'background:#F9D58C;font-weight:600' })
            $what = Get-PatchHtmlEncoded $row.Component
            if ($row.Instance) { $what += ' (' + (Get-PatchHtmlEncoded $row.Instance) + ')' }
            $body.Add('<tr>' +
                ('<td style="{0}">{1}</td>' -f $cell, (Get-PatchHtmlEncoded $row.Server)) +
                ('<td style="{0}">{1}</td>' -f $cell, $what) +
                ('<td style="{0}">{1}</td>' -f $cell, (Get-PatchHtmlEncoded $row.Installed)) +
                ('<td style="{0}">{1}</td>' -f $cell, (Get-PatchHtmlEncoded $row.Latest)) +
                ('<td style="{0};{1}">{2}</td>' -f $cell, $severity, (Get-PatchHtmlEncoded $row.Status)) +
                '</tr>')
        }
        $body.Add('</table>')
    }
    else { $body.Add('<p style="font-size:14px">Nothing is behind. The full report is attached anyway.</p>') }

    $body.Add(('<p style="color:#7A7473;font-size:12px">The full report is attached as {0}. Produced by Molehill Watch on {1}; nothing was changed on any server.</p>' -f
               (Get-PatchHtmlEncoded $ReportName), (Get-PatchHtmlEncoded $env:COMPUTERNAME)))
    $body.Add('</div>')
    $body -join "`n"
}

<#
  The report as a PDF, written by hand.

  Not converted from the HTML. Everything that turns HTML into PDF needs something installed -
  headless Edge is absent on Server Core, wkhtmltopdf is a download, Word is Word - and this tool's
  whole point is that it installs nothing. The rows are already structured, so they are laid out
  directly and the PDF is assembled from scratch. That also means it renders identically on a
  locked-down box as on a laptop, which an HTML-to-PDF converter cannot promise.

  PDF is a text format with a byte-offset table at the end, so the one thing that must be exact is
  where each object starts. Those offsets are recorded while writing rather than worked out
  afterwards, and the self test reads the table back and checks every one of them lands on its
  object - which is the only part of this a reader will refuse outright if it is wrong.

  The base-14 fonts are used (Helvetica and Helvetica-Bold), so nothing has to be embedded.
#>

# Helvetica character widths per 1000 units, for ASCII 32-126, so text can be wrapped to a column
# instead of running off the edge of it. Bold is measured as a little wider rather than carrying a
# second table: the only bold here is short header words.
$script:PatchHelveticaWidths = @(
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
)

function Get-PatchTextWidth {
    [CmdletBinding()]
    param([string] $Text, [double] $Size, [bool] $Bold = $false)

    $units = 0
    foreach ($char in [char[]]$Text) {
        $code = [int]$char
        # anything outside the table is measured as an average letter rather than as nothing, so a
        # name with an accent in it still pushes the wrap
        $units += $(if ($code -ge 32 -and $code -le 126) { $script:PatchHelveticaWidths[$code - 32] } else { 556 })
    }
    $width = ($units / 1000.0) * $Size
    if ($Bold) { $width * 1.08 } else { $width }
}

# a cell's text broken into lines that fit the column, on word boundaries where it can and mid-word
# where a single word is longer than the column (a file path, usually)
function Split-PatchTextToWidth {
    [CmdletBinding()]
    param([string] $Text, [double] $Width, [double] $Size, [bool] $Bold = $false)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($paragraph in ([string]$Text -split "`r?`n")) {
        $current = ''
        foreach ($word in ($paragraph -split ' ' | Where-Object { $_ -ne '' })) {

            # a word wider than the column can never fit beside anything, so it is broken on
            # character boundaries first and its pieces then treated as words. A file path is the
            # usual culprit, and left whole it runs out of the table and across the next column.
            $pieces = @($word)
            if ((Get-PatchTextWidth -Text $word -Size $Size -Bold $Bold) -gt $Width) {
                $pieces = @()
                $piece = ''
                foreach ($char in [char[]]$word) {
                    if ($piece -and (Get-PatchTextWidth -Text ($piece + $char) -Size $Size -Bold $Bold) -gt $Width) {
                        $pieces += $piece
                        $piece = [string]$char
                    }
                    else { $piece += $char }
                }
                if ($piece) { $pieces += $piece }
            }

            foreach ($part in $pieces) {
                if (-not $current) { $current = $part; continue }
                if ((Get-PatchTextWidth -Text "$current $part" -Size $Size -Bold $Bold) -le $Width) { $current = "$current $part" }
                else { $lines.Add($current); $current = $part }
            }
        }
        $lines.Add($current)
    }
    # never nothing: an empty cell still takes one line, or the row heights stop lining up
    if (-not $lines.Count) { $lines.Add('') }
    $lines.ToArray()
}

# ( ) and \ end or escape a PDF string, so they are escaped. Everything is written as Windows-1252
# later, which is what /WinAnsiEncoding on the font means.
#
# The replacement side of -replace takes backslashes literally, so '\\' there means two of them -
# which is what one backslash has to become. '\\\\' would produce four and put a stray pair into
# every Windows path in the report.
function Get-PatchPdfString {
    param([string] $Text)
    '(' + (([string]$Text) -replace '\\', '\\' -replace '\(', '\(' -replace '\)', '\)') + ')'
}

function New-PatchPdf {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Rows,
        [hashtable] $Counts,
        [string] $Overall,
        [datetime] $ReferenceDate,
        [datetime] $When = (Get-Date)
    )

    # A4 landscape: the table has eight columns and portrait makes every one of them too narrow
    $pageWidth = 842.0
    $pageHeight = 595.0
    $margin = 36.0
    $bodySize = 7.5
    $lineHeight = 9.5

    $columns = @(
        @{ Header = 'Server';    Width = 78.0;  Property = 'Server' }
        @{ Header = 'Component'; Width = 92.0;  Property = 'Component' }
        @{ Header = 'Product';   Width = 118.0; Property = 'Product' }
        @{ Header = 'Installed'; Width = 92.0;  Property = 'Installed' }
        @{ Header = 'Latest';    Width = 92.0;  Property = 'Latest' }
        @{ Header = 'Released';  Width = 56.0;  Property = 'Released' }
        @{ Header = 'Status';    Width = 102.0; Property = 'Status' }
        @{ Header = 'Action / notes'; Width = 140.0; Property = 'Action' }
    )

    $severityFill = @{
        Critical = '0.839 0.271 0.271 rg'
        Warning  = '0.976 0.835 0.549 rg'
        Info     = '0.867 0.953 0.988 rg'
        OK       = '0.835 0.933 0.867 rg'
    }
    $severityText = @{ Critical = '1 1 1 rg'; Warning = '0 0 0 rg'; Info = '0 0 0 rg'; OK = '0 0 0 rg' }
    $ragFill = @{ Critical = '0.839 0.271 0.271 rg'; Warning = '0.949 0.663 0.231 rg'; OK = '0.247 0.651 0.420 rg' }
    $ragText = @{ Critical = 'Action required'; Warning = 'Attention recommended'; OK = 'No issues found' }

    # every row measured first, so a row is never split across a page break
    $measured = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($Rows)) {
        $cells = @()
        $tallest = 1
        foreach ($column in $columns) {
            $text = [string]$row.($column.Property)
            if ($column.Property -eq 'Component' -and $row.Instance) { $text = "$text ($($row.Instance))" }
            if ($column.Property -eq 'Latest' -and -not $text) { $text = '-' }
            if ($column.Property -eq 'Action' -and $row.Notes) { $text = (("$text " + $row.Notes)).Trim() }
            $lines = @(Split-PatchTextToWidth -Text $text -Width ($column.Width - 8) -Size $bodySize)
            $cells += , $lines
            if ($lines.Count -gt $tallest) { $tallest = $lines.Count }
        }
        $measured.Add([pscustomobject]@{ Cells = $cells; Lines = $tallest
                                        Height = ($tallest * $lineHeight) + 4
                                        Severity = [string]$row.Severity })
    }

    # title block and the four counts, on the first page only. Deep enough to clear the cards: at
    # 118 the table's header bar was drawn over the bottom of them and swallowed their labels, which
    # a structural check cannot see and only looking at the page showed up.
    $headerDepth = 134.0
    $tableTop = $pageHeight - $margin - $headerDepth
    $laterTop = $pageHeight - $margin - 24.0
    $bottom = $margin + 18.0

    # split into pages
    $pages = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    $y = $tableTop
    $first = $true
    foreach ($row in $measured) {
        if (($y - $row.Height) -lt $bottom) {
            $pages.Add([pscustomobject]@{ Rows = $current.ToArray(); First = $first })
            $current = New-Object System.Collections.Generic.List[object]
            $first = $false
            $y = $laterTop
        }
        $current.Add($row)
        $y -= $row.Height
    }
    $pages.Add([pscustomobject]@{ Rows = $current.ToArray(); First = $first })

    # ---- the content stream for each page
    $contents = New-Object System.Collections.Generic.List[string]
    for ($p = 0; $p -lt $pages.Count; $p++) {
        $page = $pages[$p]
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add('0.957 0.949 0.945 rg')
        $out.Add("0 0 $pageWidth $pageHeight re f")

        $top = $(if ($page.First) { $tableTop } else { $laterTop })

        if ($page.First) {
            $out.Add('0.137 0.122 0.125 rg')
            $out.Add(("{0} {1} {2} {3} re f" -f $margin, ($pageHeight - $margin - 70), ($pageWidth - 2 * $margin), 70))
            $out.Add('1 1 1 rg')
            $out.Add(('BT /F2 17 Tf {0} {1} Td {2} Tj ET' -f ($margin + 14), ($pageHeight - $margin - 30), (Get-PatchPdfString 'SQL Server & Windows patch status')))
            $out.Add('0.749 0.733 0.729 rg')
            $out.Add(('BT /F1 8 Tf {0} {1} Td {2} Tj ET' -f ($margin + 14), ($pageHeight - $margin - 43),
                     (Get-PatchPdfString ("Run {0} on {1} as {2}\{3}  -  Microsoft update data from {4}" -f
                        $When.ToString('dddd dd MMMM yyyy HH:mm'), $env:COMPUTERNAME,
                        [Environment]::UserDomainName, [Environment]::UserName, $ReferenceDate.ToString('dd MMM yyyy')))))

            # the overall verdict, as a block of colour someone can see from across a desk
            $ragWidth = (Get-PatchTextWidth -Text $ragText[$Overall] -Size 9 -Bold $true) + 20
            $out.Add($ragFill[$Overall])
            $out.Add(("{0} {1} {2} 20 re f" -f ($margin + 14), ($pageHeight - $margin - 68), $ragWidth))
            $out.Add($(if ($Overall -eq 'Warning') { '0 0 0 rg' } else { '1 1 1 rg' }))
            $out.Add(('BT /F2 9 Tf {0} {1} Td {2} Tj ET' -f ($margin + 24), ($pageHeight - $margin - 62), (Get-PatchPdfString $ragText[$Overall])))

            # the four counts
            $cardX = $margin
            foreach ($name in 'Critical', 'Warning', 'Info', 'OK') {
                $label = $(if ($name -eq 'OK') { 'Up to date' } else { $name })
                $out.Add('1 1 1 rg')
                $out.Add(("{0} {1} 118 34 re f" -f $cardX, ($pageHeight - $margin - 112)))
                $out.Add($(switch ($name) { 'Critical' { '0.839 0.271 0.271 rg' } 'Warning' { '0.949 0.663 0.231 rg' } 'Info' { '0.267 0.784 0.961 rg' } default { '0.247 0.651 0.420 rg' } }))
                $out.Add(("{0} {1} 118 3 re f" -f $cardX, ($pageHeight - $margin - 81)))
                $out.Add('0.137 0.122 0.125 rg')
                $out.Add(('BT /F2 15 Tf {0} {1} Td {2} Tj ET' -f ($cardX + 10), ($pageHeight - $margin - 100), (Get-PatchPdfString ([string]$Counts[$name]))))
                $out.Add('0.478 0.455 0.451 rg')
                $out.Add(('BT /F1 7.5 Tf {0} {1} Td {2} Tj ET' -f ($cardX + 10), ($pageHeight - $margin - 110), (Get-PatchPdfString $label)))
                $cardX += 126
            }
        }

        # the table header, repeated on every page: a table whose columns are only labelled on page
        # one is unreadable by page three
        $out.Add('0.137 0.122 0.125 rg')
        $out.Add(("{0} {1} {2} 14 re f" -f $margin, $top, ($pageWidth - 2 * $margin)))
        $out.Add('1 1 1 rg')
        $x = $margin
        foreach ($column in $columns) {
            $out.Add(('BT /F2 7.5 Tf {0} {1} Td {2} Tj ET' -f ($x + 4), ($top + 4), (Get-PatchPdfString $column.Header)))
            $x += $column.Width
        }

        $y = $top
        foreach ($row in $page.Rows) {
            $y -= $row.Height
            $x = $margin
            for ($c = 0; $c -lt $columns.Count; $c++) {
                $column = $columns[$c]
                # the status cell is filled with the severity colour; the rest are white
                $isStatus = ($column.Property -eq 'Status')
                $out.Add($(if ($isStatus -and $severityFill.ContainsKey($row.Severity)) { $severityFill[$row.Severity] } else { '1 1 1 rg' }))
                $out.Add(("{0} {1} {2} {3} re f" -f $x, $y, $column.Width, $row.Height))
                $out.Add($(if ($isStatus -and $severityText.ContainsKey($row.Severity)) { $severityText[$row.Severity] } else { '0.137 0.122 0.125 rg' }))
                $textY = $y + $row.Height - $lineHeight + 1
                foreach ($line in $row.Cells[$c]) {
                    if ($line) {
                        $out.Add(('BT /F1 {0} Tf {1} {2} Td {3} Tj ET' -f $bodySize, ($x + 4), $textY, (Get-PatchPdfString $line)))
                    }
                    $textY -= $lineHeight
                }
                $x += $column.Width
            }
            # a hairline under each row, so the eye can follow one across eight columns
            $out.Add('0.886 0.871 0.867 RG 0.5 w')
            $out.Add(("{0} {1} m {2} {1} l S" -f $margin, $y, ($pageWidth - $margin)))
        }

        $out.Add('0.478 0.455 0.451 rg')
        $out.Add(('BT /F1 7 Tf {0} {1} Td {2} Tj ET' -f $margin, ($margin + 4),
                 (Get-PatchPdfString ("Molehill Watch  -  page {0} of {1}  -  read-only: nothing was changed on any server" -f ($p + 1), $pages.Count))))
        $contents.Add($out -join "`n")
    }

    # ---- assemble, recording where every object starts
    $encoding = [System.Text.Encoding]::GetEncoding(1252)
    $stream = New-Object System.IO.MemoryStream
    $offsets = @{}
    function Write-Raw { param($Text) $bytes = $encoding.GetBytes($Text); $stream.Write($bytes, 0, $bytes.Length) }

    $pageCount = $pages.Count
    # 1 catalog, 2 pages, 3 and 4 the fonts, then two objects per page
    $pageIds = @(1..$pageCount | ForEach-Object { 5 + (($_ - 1) * 2) })
    $totalObjects = 4 + ($pageCount * 2)

    # the second line is the conventional "this file has binary in it" marker: four bytes above 127
    # so that anything copying the file in text mode is known to have corrupted it
    Write-Raw ("%PDF-1.4`n%" + [string][char]0xE2 + [char]0xE3 + [char]0xCF + [char]0xD3 + "`n")

    $offsets[1] = $stream.Position
    Write-Raw "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"

    $offsets[2] = $stream.Position
    Write-Raw ("2 0 obj`n<< /Type /Pages /Kids [{0}] /Count {1} >>`nendobj`n" -f (($pageIds | ForEach-Object { "$_ 0 R" }) -join ' '), $pageCount)

    $offsets[3] = $stream.Position
    Write-Raw "3 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>`nendobj`n"

    $offsets[4] = $stream.Position
    Write-Raw "4 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>`nendobj`n"

    for ($i = 0; $i -lt $pageCount; $i++) {
        $pageId = $pageIds[$i]
        $contentId = $pageId + 1
        $offsets[$pageId] = $stream.Position
        Write-Raw ("{0} 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {1} {2}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents {3} 0 R >>`nendobj`n" -f
                   $pageId, $pageWidth, $pageHeight, $contentId)

        $body = $contents[$i]
        $offsets[$contentId] = $stream.Position
        # the length is the length in bytes after encoding, not in characters
        Write-Raw ("{0} 0 obj`n<< /Length {1} >>`nstream`n" -f $contentId, $encoding.GetByteCount($body))
        Write-Raw $body
        Write-Raw "`nendstream`nendobj`n"
    }

    $xrefAt = $stream.Position
    Write-Raw ("xref`n0 {0}`n" -f ($totalObjects + 1))
    Write-Raw "0000000000 65535 f `n"
    for ($id = 1; $id -le $totalObjects; $id++) {
        Write-Raw ("{0:0000000000} 00000 n `n" -f [int64]$offsets[$id])
    }
    Write-Raw ("trailer`n<< /Size {0} /Root 1 0 R >>`nstartxref`n{1}`n%%EOF`n" -f ($totalObjects + 1), [int64]$xrefAt)

    $bytes = $stream.ToArray()
    $stream.Dispose()
    , $bytes
}

# the sending itself, kept apart from everything that decides what to send so the deciding can be
# checked without a mail server in the room
function Send-PatchEmail {
    [CmdletBinding()]
    param(
        [string[]] $To, [string] $From, [string] $Subject, [string] $Body,
        [AllowEmptyCollection()] [string[]] $AttachmentPath, [string] $Server, [int] $Port,
        [bool] $UseSsl, [pscredential] $Credential
    )

    $message = New-Object System.Net.Mail.MailMessage
    $client = New-Object System.Net.Mail.SmtpClient $Server, $Port
    $attachments = New-Object System.Collections.Generic.List[object]
    try {
        $message.From = New-Object System.Net.Mail.MailAddress $From
        foreach ($one in @($To) | Where-Object { $_ }) { $message.To.Add($one.Trim()) }
        $message.Subject = $Subject
        $message.Body = $Body
        $message.IsBodyHtml = $true
        foreach ($path in @($AttachmentPath) | Where-Object { $_ }) {
            if (-not (Test-Path -LiteralPath $path)) { continue }
            # the type said out loud rather than left as application/octet-stream, which is what
            # .NET falls back to and what a mail gateway is most suspicious of
            $type = $(if ([System.IO.Path]::GetExtension($path) -eq '.pdf') { 'application/pdf' } else { 'text/html' })
            $one = New-Object System.Net.Mail.Attachment $path, $type
            $one.Name = Split-Path -Leaf $path
            $attachments.Add($one)
            $message.Attachments.Add($one)
        }
        $client.EnableSsl = $UseSsl
        if ($Credential) {
            $client.Credentials = New-Object System.Net.NetworkCredential $Credential.UserName, $Credential.GetNetworkCredential().Password
        }
        else { $client.UseDefaultCredentials = $true }
        $client.Send($message)
    }
    finally {
        # each attachment holds its file open, so they go before the message that owns them
        foreach ($one in $attachments) { $one.Dispose() }
        $message.Dispose()
        $client.Dispose()
    }
}

Register-MhSelfTest -Name 'Get-MhPatchStatus' -Test {
    # the reference data these verdicts are read against, small enough to reason about. The
    # functions read it from the caller's scope, which is how the tool itself passes it to them.
    $today = [datetime]'2026-10-15'
    $SqlGraceDays = 30
    $SqlCuBehindCritical = 3
    $WindowsGraceDays = 14
    $sqlLifecycle = @{ 16 = @('SQL Server 2022', '2028-01-11', '2033-01-11') }
    $winLifecycle = @{ 20348 = @('Windows Server 2022', '2031-10-14') }
    $sqlRef = @(
        [pscustomobject]@{ Major = 16; Version = [version]'16.0.1000.6'; ServicePack = $null; CuNumber = $null
                           UpdateName = 'RTM'; KB = '0'; ReleaseDate = '2022-11-16' }
        [pscustomobject]@{ Major = 16; Version = [version]'16.0.4100.1'; ServicePack = $null; CuNumber = 10
                           UpdateName = 'CU10'; KB = '5031778'; ReleaseDate = '2026-01-15' }
        [pscustomobject]@{ Major = 16; Version = [version]'16.0.4150.1'; ServicePack = $null; CuNumber = 12
                           UpdateName = 'CU12'; KB = '5035000'; ReleaseDate = '2026-09-20' }
        [pscustomobject]@{ Major = 16; Version = [version]'16.0.4200.1'; ServicePack = $null; CuNumber = 13
                           UpdateName = 'CU13'; KB = '5040000'; ReleaseDate = '2026-10-01' }
    )
    $winRef = @(
        [pscustomobject]@{ BuildNumber = 20348; Revision = 2000; KB = '5030000'; Source = 'Security'; ReleaseDate = '2026-08-12' }
        [pscustomobject]@{ BuildNumber = 20348; Revision = 2100; KB = '5035000'; Source = 'Security'; ReleaseDate = '2026-09-09' }
        [pscustomobject]@{ BuildNumber = 20348; Revision = 2200; KB = '5040000'; Source = 'Security'; ReleaseDate = '2026-10-14' }
    )

    Test-MhSection 'how far behind a SQL Server build is'
    $current = Get-PatchSqlStatus '16.0.4200.1'
    Test-MhCheck 'the newest build is up to date' ($current.Severity -eq 'OK') $current.Status
    Test-MhCheck 'and it names what it compared against' ($current.Latest -eq '16.0.4200.1')

    $oneBehind = Get-PatchSqlStatus '16.0.4150.1'
    Test-MhCheck 'one CU behind says so' ($oneBehind.Status -match '1 CU behind') $oneBehind.Status
    Test-MhCheck 'and tells you what to apply' ($oneBehind.Action -match 'CU13')

    $threeBehind = Get-PatchSqlStatus '16.0.4100.1'
    Test-MhCheck 'three CUs behind is critical' ($threeBehind.Severity -eq 'Critical') $threeBehind.Severity
    Test-MhCheck 'and says how many, plural' ($threeBehind.Status -match '3 CUs behind')

    $rtm = Get-PatchSqlStatus '16.0.1000.6'
    Test-MhCheck 'no CU at all is called that rather than counted' ($rtm.Status -eq 'No cumulative update installed') $rtm.Status

    $unlisted = Get-PatchSqlStatus '16.0.4160.5'
    Test-MhCheck 'a build between two listed ones is reported as unlisted' ($unlisted.InstalledUpdate -match 'unlisted')
    Test-MhCheck 'and still compared with the latest' ($unlisted.Latest -eq '16.0.4200.1')

    $unknown = Get-PatchSqlStatus '13.0.5026.0'
    Test-MhCheck 'a version with no data says so rather than guessing' ($unknown.Action -match 'No Microsoft build data')
    Test-MhCheck 'and reaches no verdict' ($unknown.Status -eq 'Not checked')

    Test-MhSection 'and the Windows under it'
    $winCurrent = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 20348; Ubr = 2200; Type = 'Server'; Note = '' })
    Test-MhCheck 'the newest revision is up to date' ($winCurrent.Severity -eq 'OK') $winCurrent.Status
    $winOne = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 20348; Ubr = 2100; Type = 'Server'; Note = '' })
    Test-MhCheck 'one missing update is one, singular' ($winOne.Status -match '1 monthly security update missing') $winOne.Status
    $winTwo = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 20348; Ubr = 2000; Type = 'Server'; Note = '' })
    Test-MhCheck 'two missing is critical' ($winTwo.Severity -eq 'Critical') $winTwo.Severity
    Test-MhCheck 'and plural' ($winTwo.Status -match 'updates missing')
    $client = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 26100; Ubr = 1; Type = 'Client'; Note = '' })
    Test-MhCheck 'a workstation is not judged against server updates' ($client.Status -match 'not Windows Server')
    $old = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 9600; Ubr = 1; Type = 'Server'; Note = '' })
    Test-MhCheck '2012 R2 is left to Windows Update rather than guessed at' ($old.Status -match '2012')
    $noUbr = Get-PatchWindowsStatus ([pscustomobject]@{ Build = 20348; Ubr = $null; Type = 'Server'; Note = 'no remote registry' })
    Test-MhCheck 'no revision means no verdict, with the reason' (
        ($noUbr.Status -match 'update revision unavailable') -and ($noUbr.Action -eq 'no remote registry'))
    $nothing = Get-PatchWindowsStatus $null
    Test-MhCheck 'and nothing at all is admitted to' ($nothing.Action -match 'Could not read')

    Test-MhSection 'reading the build table out of the article'

    # the shape of the real page, cut down to what the parser cares about. The pre-2012 section is
    # here because those versions are out of support and are meant to be left out.
    $sample = @'
<h2 id="sql-server-complete-version-list-tables">SQL Server complete version list tables</h2>
<h3 id="sql-server-2022">SQL Server 2022</h3>
<table><thead><tr><th>Build number or version</th><th>Service pack</th><th>Update</th><th>Knowledge Base number</th><th>Release date</th></tr></thead>
<tbody>
<tr> <td>16.0.4305.5</td> <td>None</td> <td><a href="/en-us/help/5126934">CU27 &amp; GDR</a></td> <td><a href="/en-us/help/5126934">KB5126934</a></td> <td>October 13, 2026</td> </tr>
<tr> <td>16.0.4295.3</td> <td>None</td> <td><a href="/x">CU27</a></td> <td>KB5104824</td> <td>September 9, 2026</td> </tr>
<tr> <td>not a build</td> <td>None</td> <td>Nothing</td> <td>None</td> <td>None</td> </tr>
</tbody></table>
<h3 id="sql-server-2008-r2">SQL Server 2008 R2</h3>
<table><tbody>
<tr> <td>10.50.6000.34</td> <td>SP3</td> <td>SP3</td> <td>KB2979597</td> <td>September 30, 2014</td> </tr>
</tbody></table>
<h3 id="sql-server-2005">SQL Server 2005</h3>
<table><tbody>
<tr> <td>9.0.5324</td> <td>SP4</td> <td>CU3</td> <td>KB2507769</td> <td>March 17, 2011</td> </tr>
</tbody></table>
'@

    $parsed = @(Get-PatchSqlBuildsFromHtml $sample)
    Test-MhCheck 'the rows of a supported version are read' ($parsed.Count -eq 2) ("$($parsed.Count) rows")
    Test-MhCheck 'a version out of support is left out' (-not @($parsed | Where-Object { $_.ProductName -notlike '*2022' }).Count)
    $newest = $parsed[0]
    Test-MhCheck 'the build number is split into its four parts' ($newest.Major -eq 16 -and $newest.Minor -eq 0 -and $newest.BuildNumber -eq 4305 -and $newest.Revision -eq 5)
    Test-MhCheck 'the update name comes through without its link' ($newest.UpdateName -eq 'CU27 & GDR') $newest.UpdateName
    Test-MhCheck 'the CU number is taken from it' ($newest.CuNumber -eq 27) "$($newest.CuNumber)"
    Test-MhCheck 'the KB number loses its KB and its link' ($newest.KB -eq '5126934') $newest.KB
    Test-MhCheck 'the date is read the one way round, whatever this machine is set to' ($newest.ReleaseDate -eq '2026-10-13') $newest.ReleaseDate
    Test-MhCheck 'and a row that is not a build is skipped rather than guessed at' (-not @($parsed | Where-Object { $_.UpdateName -eq 'Nothing' }).Count)
    Test-MhCheck 'a KB with no prefix is still read' ($parsed[1].KB -eq '5104824') $parsed[1].KB
    Test-MhCheck 'and nothing at all parses to nothing' (@(Get-PatchSqlBuildsFromHtml '').Count -eq 0)

    Test-MhSection 'emailing the report'

    # everything that is wrong with the settings, said at once and before the scan rather than after
    Test-MhCheck 'nothing missing is no complaint' (
        -not @(Get-PatchEmailProblem -To @('ops@example.com') -From 'reports@example.com' -Server 'smtp.example.com').Count)
    $none = @(Get-PatchEmailProblem -To @() -From '' -Server '')
    Test-MhCheck 'all three missing are reported together, not one per run' ($none.Count -eq 3) ($none -join ' | ')
    Test-MhCheck 'a missing recipient is named' (@($none | Where-Object { $_ -match '-EmailTo' }).Count -eq 1)
    Test-MhCheck 'a missing sender is named, and says why one is needed' (
        @($none | Where-Object { $_ -match '-EmailFrom' -and $_ -match 'no sender' }).Count -eq 1)
    Test-MhCheck 'a missing mail server is named' (@($none | Where-Object { $_ -match '-SmtpServer' }).Count -eq 1)
    $bad = @(Get-PatchEmailProblem -To @('ops@example.com', 'not an address') -From 'reports@example.com' -Server 'smtp')
    Test-MhCheck 'an address that is not one is caught' ($bad.Count -eq 1 -and $bad[0] -match 'not an email address') ($bad -join ' | ')
    Test-MhCheck 'and the good ones beside it are not' ($bad[0] -notmatch 'ops@example.com') $bad[0]
    # -join, not -match against the array: -match on a list hands back the matching items, which is
    # an array, and Test-MhCheck wants a yes or no
    Test-MhCheck 'a sender that is not an address is caught too' (
        (@(Get-PatchEmailProblem -To @('ops@example.com') -From 'nope' -Server 'smtp') -join ' ') -match "'nope' is not an email address")

    # whether a run is worth an email: a nightly job should be able to stay quiet when all is well
    $clean = @{ Critical = 0; Warning = 0; Info = 2; OK = 9 }
    $warned = @{ Critical = 0; Warning = 3; Info = 0; OK = 6 }
    $urgent = @{ Critical = 2; Warning = 1; Info = 0; OK = 4 }
    Test-MhCheck 'Always sends when all is well' (Test-PatchEmailWanted -When 'Always' -Counts $clean)
    Test-MhCheck 'Critical stays quiet when all is well' (-not (Test-PatchEmailWanted -When 'Critical' -Counts $clean))
    Test-MhCheck 'and stays quiet for warnings alone' (-not (Test-PatchEmailWanted -When 'Critical' -Counts $warned))
    Test-MhCheck 'but speaks up for something critical' (Test-PatchEmailWanted -When 'Critical' -Counts $urgent)
    Test-MhCheck 'CriticalOrWarning speaks up for a warning' (Test-PatchEmailWanted -When 'CriticalOrWarning' -Counts $warned)
    Test-MhCheck 'and stays quiet when there is neither' (-not (Test-PatchEmailWanted -When 'CriticalOrWarning' -Counts $clean))

    # the subject line, which for most people is the whole report
    $subject = Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4
    Test-MhCheck 'the subject leads with the number that matters' ($subject -match '^Patch status: 2 critical') $subject
    Test-MhCheck 'and says how many servers it covers' ($subject -match '4 servers') $subject
    Test-MhCheck 'one server is not "1 servers"' (
        (Get-PatchEmailSubject -Counts $clean -Overall 'OK' -ServerCount 1) -match '1 server$') (Get-PatchEmailSubject -Counts $clean -Overall 'OK' -ServerCount 1)
    Test-MhCheck 'a clean run says so in the subject' (
        (Get-PatchEmailSubject -Counts $clean -Overall 'OK' -ServerCount 3) -match 'all up to date')
    Test-MhCheck 'and a warning run does not call itself critical' (
        (Get-PatchEmailSubject -Counts $warned -Overall 'Warning' -ServerCount 3) -match '3 needing attention')

    # a subject of your own, which matters when the recipient is a ticket mailbox and the subject
    # becomes the title of the ticket
    Test-MhCheck 'a given subject replaces the built-in one' (
        (Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4 -Template 'SQL patching review') -ceq 'SQL patching review')
    $filled = Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4 `
                                    -Template '[SQL] {Critical} critical, {Warning} warning on {Servers} servers - {Overall} - {Date}' `
                                    -When ([datetime]'2026-11-03')
    Test-MhCheck 'and can still carry the numbers into its own wording' (
        $filled -ceq '[SQL] 2 critical, 1 warning on 4 servers - Critical - 2026-11-03') $filled
    Test-MhCheck 'no token is left behind unfilled' ($filled -notmatch '\{(Critical|Warning|Info|OK|Servers|Overall|Date)\}') $filled
    Test-MhCheck 'the up-to-date and info counts are available too' (
        (Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4 -Template '{OK} fine, {Info} noted') -ceq '4 fine, 0 noted')
    # someone's own reference in braces must survive: a subject is exactly where those get put
    Test-MhCheck 'a brace that is not one of ours is left exactly as written' (
        (Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4 -Template 'Ticket {REF-1234}: {Critical} critical') -ceq 'Ticket {REF-1234}: 2 critical')
    Test-MhCheck 'and with no subject given the default still says the answer' (
        (Get-PatchEmailSubject -Counts $urgent -Overall 'Critical' -ServerCount 4 -Template '') -match '^Patch status: 2 critical')

    # the body: what is wrong, and nothing else
    $rows = @(
        [pscustomobject]@{ Server = 'SQL01'; Component = 'SQL Server'; Instance = 'SQL01\PROD'; Installed = '16.0.4100.1'
                           Latest = '16.0.4305.5'; Status = '3 CUs behind'; Severity = 'Critical' }
        [pscustomobject]@{ Server = 'SQL01'; Component = 'Windows'; Instance = ''; Installed = '20348.2700'
                           Latest = '20348.2966'; Status = 'One update behind'; Severity = 'Warning' }
        [pscustomobject]@{ Server = 'SQL02'; Component = 'SQL Server'; Instance = 'SQL02'; Installed = '16.0.4305.5'
                           Latest = '16.0.4305.5'; Status = 'Up to date'; Severity = 'OK' }
    )
    $body = Get-PatchEmailBody -Rows $rows -Counts $urgent -Overall 'Critical' -ReportName 'PatchStatus.html' -ReferenceDate ([datetime]'2026-10-15')
    Test-MhCheck 'the critical row is in the body' ($body -match 'SQL01\\PROD' -and $body -match '3 CUs behind')
    Test-MhCheck 'so is the warning' ($body -match 'One update behind')
    Test-MhCheck 'the one that is fine is left out' ($body -notmatch 'SQL02')
    Test-MhCheck 'the attachment is named so it can be found' ($body -match 'PatchStatus\.html')
    Test-MhCheck 'and it says nothing was changed' ($body -match 'nothing was changed')
    # a <style> block would be thrown away by mail clients, so the styling has to be on the elements
    Test-MhCheck 'the styling is inline, because mail clients discard a stylesheet' (
        $body -notmatch '<style' -and $body -match 'style="[^"]+"')
    $allWell = Get-PatchEmailBody -Rows @($rows[2]) -Counts $clean -Overall 'OK' -ReportName 'P.html' -ReferenceDate ([datetime]'2026-10-15')
    Test-MhCheck 'a clean run says so rather than showing an empty table' (
        $allWell -match 'Nothing is behind' -and $allWell -notmatch '<table') $allWell
    # the report's own data is server names and version numbers, but it is still put through the
    # encoder: a server named with an ampersand must not break the email
    $odd = @([pscustomobject]@{ Server = 'SQL&<01>'; Component = 'SQL Server'; Instance = ''; Installed = '1'
                                Latest = '2'; Status = 'behind'; Severity = 'Critical' })
    $encoded = Get-PatchEmailBody -Rows $odd -Counts $urgent -Overall 'Critical' -ReportName 'P.html' -ReferenceDate ([datetime]'2026-10-15')
    Test-MhCheck 'a name with markup in it is encoded, not pasted in' (
        $encoded -match 'SQL&amp;&lt;01&gt;' -and $encoded -notmatch 'SQL&<01>')

    Test-MhSection 'the report as a PDF'

    Test-MhCheck 'the width table has one entry per printable character' ($script:PatchHelveticaWidths.Count -eq 95) "$($script:PatchHelveticaWidths.Count)"
    Test-MhCheck 'a wider string measures wider' (
        (Get-PatchTextWidth -Text 'WWWWW' -Size 10) -gt (Get-PatchTextWidth -Text 'iiiii' -Size 10))
    $wrapped = @(Split-PatchTextToWidth -Text 'Apply cumulative update CU27 to bring this instance up to date' -Width 80 -Size 7.5)
    Test-MhCheck 'a sentence wraps onto several lines' ($wrapped.Count -gt 1) "$($wrapped.Count)"
    Test-MhCheck 'every wrapped line fits its column' (
        -not @($wrapped | Where-Object { (Get-PatchTextWidth -Text $_ -Size 7.5) -gt 80.01 }).Count)
    Test-MhCheck 'and no word is lost in the wrapping' (
        (($wrapped -join ' ') -replace '\s+', ' ') -ceq 'Apply cumulative update CU27 to bring this instance up to date')
    # a path is one long word, and left whole it runs out of the table and over the next column
    Test-MhCheck 'a word too wide for the column is cut rather than overflowing' (
        -not @(Split-PatchTextToWidth -Text 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA' -Width 50 -Size 7.5 |
               Where-Object { (Get-PatchTextWidth -Text $_ -Size 7.5) -gt 50.01 }).Count)
    Test-MhCheck 'an empty cell is still one line, so rows line up' ((@(Split-PatchTextToWidth -Text '' -Width 50 -Size 7.5)).Count -eq 1)
    # the replacement side of -replace takes backslashes literally, so one must become exactly two
    Test-MhCheck 'a backslash becomes two, not four' ((Get-PatchPdfString 'SQL01\PROD') -ceq '(SQL01\\PROD)') (Get-PatchPdfString 'SQL01\PROD')
    Test-MhCheck 'and a bracket cannot end the string early' (
        (Get-PatchPdfString 'Standard Edition (64-bit)') -ceq '(Standard Edition \(64-bit\))') (Get-PatchPdfString 'Standard Edition (64-bit)')

    $pdfRows = @(
        [pscustomobject]@{ Server = 'SQL01'; Instance = 'SQL01\PROD'; Component = 'SQL Server'; Product = 'SQL Server 2022 Standard Edition (64-bit)'
                           Installed = '16.0.4100.1 - CU10'; Latest = '16.0.4305.5'; LatestRelease = ''; Released = '13 Oct 2026'
                           Status = '3 CUs behind'; Severity = 'Critical'; Action = 'Apply CU27.'; Support = ''; Notes = '' }
        [pscustomobject]@{ Server = 'SQL02'; Instance = ''; Component = 'Windows'; Product = 'Windows Server 2022'
                           Installed = '20348.2966'; Latest = '20348.2966'; LatestRelease = ''; Released = '14 Oct 2026'
                           Status = 'Up to date'; Severity = 'OK'; Action = ''; Support = ''; Notes = '' }
    )
    $pdfBytes = New-PatchPdf -Rows $pdfRows -Counts $urgent -Overall 'Critical' -ReferenceDate ([datetime]'2026-10-15')
    $pdfText = [System.Text.Encoding]::GetEncoding(1252).GetString($pdfBytes)
    Test-MhCheck 'it starts and ends the way a PDF must' ($pdfText.StartsWith('%PDF-1.4') -and $pdfText.TrimEnd().EndsWith('%%EOF'))
    Test-MhCheck 'with a catalog, a page tree and both base fonts' (
        $pdfText -match '/Type /Catalog' -and $pdfText -match '/Type /Pages' -and
        $pdfText -match '/BaseFont /Helvetica\b' -and $pdfText -match '/BaseFont /Helvetica-Bold')
    Test-MhCheck 'and the report inside it' ($pdfText -match 'SQL01\\\\PROD' -and $pdfText -match '3 CUs behind')

    # the cross-reference table is the one part a reader refuses outright if it is wrong: every
    # entry is a byte offset, and one wrong number makes the file unopenable. Read back and checked.
    $startXref = [regex]::Match($pdfText, 'startxref\s+(\d+)\s+%%EOF')
    Test-MhCheck 'the trailer points at the cross-reference table' (
        $startXref.Success -and $pdfText.Substring([int]$startXref.Groups[1].Value, 4) -ceq 'xref')
    $xrefEntries = [regex]::Matches($pdfText.Substring([int]$startXref.Groups[1].Value), '(?m)^(\d{10}) (\d{5}) ([nf]) $')
    Test-MhCheck 'it has one entry per object plus the free head' (
        $xrefEntries.Count -eq [int]([regex]::Match($pdfText, 'xref\s+0 (\d+)').Groups[1].Value)) "$($xrefEntries.Count)"
    $badOffsets = @()
    for ($i = 1; $i -lt $xrefEntries.Count; $i++) {
        $at = [int]$xrefEntries[$i].Groups[1].Value
        $expect = "$i 0 obj"
        if ($at -le 0 -or ($at + $expect.Length) -gt $pdfText.Length -or $pdfText.Substring($at, $expect.Length) -cne $expect) {
            $badOffsets += "object $i"
        }
    }
    Test-MhCheck 'and every offset lands exactly on its object' (-not $badOffsets.Count) ($badOffsets -join ', ')
    $badStreams = @()
    foreach ($m in [regex]::Matches($pdfText, '<< /Length (\d+) >>\s*stream\r?\n')) {
        $from = $m.Index + $m.Length
        if (($pdfText.IndexOf("`nendstream", $from) - $from) -ne [int]$m.Groups[1].Value) { $badStreams += $m.Groups[1].Value }
    }
    Test-MhCheck 'every stream declares the length it really is' (-not $badStreams.Count) ($badStreams -join ', ')

    # a report longer than a page, where the offsets are easiest to get wrong
    $longRows = @(1..40 | ForEach-Object {
        [pscustomobject]@{ Server = "SQL$_"; Instance = "SQL$_\INST"; Component = 'SQL Server'; Product = 'SQL Server 2022 Standard Edition (64-bit)'
                           Installed = '16.0.4100.1 - CU10'; Latest = '16.0.4305.5'; LatestRelease = ''; Released = '13 Oct 2026'
                           Status = '3 CUs behind'; Severity = 'Critical'; Action = 'Apply CU27 before the next maintenance window.'; Support = ''; Notes = '' }
    })
    $longText = [System.Text.Encoding]::GetEncoding(1252).GetString((New-PatchPdf -Rows $longRows -Counts $urgent -Overall 'Critical' -ReferenceDate ([datetime]'2026-10-15')))
    $longPages = [int]([regex]::Match($longText, '/Count (\d+)').Groups[1].Value)
    Test-MhCheck 'forty rows run onto more than one page' ($longPages -gt 1) "$longPages pages"
    Test-MhCheck 'the page objects match the count the tree declares' (
        ([regex]::Matches($longText, '/Type /Page[^s]')).Count -eq $longPages)
    # a table whose columns are only labelled on page one is unreadable by page three
    Test-MhCheck 'and the column headers are repeated on every page' (
        ([regex]::Matches($longText, '\(Action / notes\)')).Count -eq $longPages) `
        ("$(([regex]::Matches($longText, '\(Action / notes\)')).Count) for $longPages pages")
    $longBad = @()
    $longEntries = [regex]::Matches($longText.Substring([int][regex]::Match($longText, 'startxref\s+(\d+)\s+%%EOF').Groups[1].Value), '(?m)^(\d{10}) (\d{5}) ([nf]) $')
    for ($i = 1; $i -lt $longEntries.Count; $i++) {
        $at = [int]$longEntries[$i].Groups[1].Value
        if ($pdfText.Length -gt 0 -and $longText.Substring($at, "$i 0 obj".Length) -cne "$i 0 obj") { $longBad += "object $i" }
    }
    Test-MhCheck 'a multi-page file still has every offset right' (-not $longBad.Count) ($longBad -join ', ')

    $emptyText = [System.Text.Encoding]::GetEncoding(1252).GetString((New-PatchPdf -Rows @() -Counts @{ Critical = 0; Warning = 0; Info = 0; OK = 0 } -Overall 'OK' -ReferenceDate ([datetime]'2026-10-15')))
    Test-MhCheck 'and a report with nothing in it is still one valid page' (
        $emptyText.StartsWith('%PDF') -and $emptyText -match '/Count 1' -and $emptyText -match 'No issues found')
}
