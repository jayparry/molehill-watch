$script:LicensingComponentQuery = @"
SELECT  HasSsisCatalog   = CONVERT(bit, CASE WHEN DB_ID('SSISDB') IS NOT NULL THEN 1 ELSE 0 END),
        HasReportServer  = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'ReportServer%') THEN 1 ELSE 0 END),
        HasPowerBiRs     = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'PowerBIReportServer%') THEN 1 ELSE 0 END),
        HasMds           = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'MDS%') THEN 1 ELSE 0 END),
        HasDqs           = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'DQS%') THEN 1 ELSE 0 END);
"@

$script:LicensingHadrQuery = @"
SELECT  Role          = rs.role_desc,
        AllowReads    = ar.secondary_role_allow_connections_desc,
        BackupPref    = ag.automated_backup_preference_desc,
        AgName        = ag.name
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE rs.is_local = 1;
"@

$script:LicensingStandbyQuery = @"
SELECT  UserDbs   = COUNT(*),
        Restoring = SUM(CASE WHEN state_desc IN ('RESTORING', 'OFFLINE') OR is_in_standby = 1 THEN 1 ELSE 0 END)
FROM sys.databases WHERE database_id > 4;
"@

$script:LicensingMirrorQuery = @"
SELECT Mirrors = COUNT(*) FROM sys.database_mirroring WHERE mirroring_role = 2;
"@

$script:LicensingClusterQuery = @"
SELECT NodeName = NodeName, Status = status_description FROM sys.dm_os_cluster_nodes;
"@

<#
.SYNOPSIS
    Takes a list of SQL Servers and works out what has to be licensed to cover them, with the
    reasoning shown.

.DESCRIPTION
    Every licensable product it can see on each instance, totalled into two-core packs, with the
    hosts grouped so that a VM and the box under it are not counted twice. Free editions are
    listed and never totalled. Where a price is given it is costed; where it is not, the pack
    count is the answer.

    Hardware facts come from the best source available, in this order: -HardwareOverride, then
    Windows itself, then SQL Server, then inference from what SQL Server does say. Which one was
    used is reported per host, because a core count inferred from a logical processor count is a
    lower bound rather than a fact - the mistake that made this script necessary was reading
    cpu_count / hyperthread_ratio as cores per socket when it is the socket count.

    What it cannot know is what you already own: Software Assurance, agreement terms, licence
    mobility, packs on the shelf and CAL counts are not readable from a server. This is an
    inventory to inform a licensing conversation, not licensing advice.

.PARAMETER SqlInstance
    The instances to audit. Also takes a pipeline.

.PARAMETER ServerList
    A file of instance names, one per line. Blank lines and # comments are ignored.

.PARAMETER SqlCredential
    SQL authentication. Windows authentication is used when this is left out.

.PARAMETER SoftwareAssurance
    Take passive failover replicas out of the total, which Software Assurance allows for one
    passive replica per licensed primary.

.PARAMETER IncludeHostInventory
    Also list what else is installed on each host - Reporting Services, Integration Services and
    the rest - which may be licensable in its own right.

.PARAMETER HardwareOverride
    Hardware facts you know and the server will not say, as @{ 'SQL01' = @{ Sockets = 2;
    CoresPerSocket = 8; IsVirtual = $false } }. Trusted over anything read from the machine.

.PARAMETER UserCount
    How many users or devices there are, for the server-plus-CAL comparison.

.PARAMETER CorePackPrice
    What a two-core pack costs. One number for all editions, or @{ Enterprise = 12000; Standard = 3500 }.

.PARAMETER ServerLicencePrice
    What a server licence costs, for the server-plus-CAL comparison.

.PARAMETER CalPrice
    What one CAL costs.

.PARAMETER OutputPath
    Where the HTML report goes. Defaults to the current folder.

.PARAMETER CsvPath
    Write the per-instance detail to this file as well.

.PARAMETER NoHtml
    Skip the HTML report; print to the console only.

.PARAMETER Open
    Open the report when it is written.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for each instance. Default 10.

.OUTPUTS
    The audit, with Instances, Hosts, Totals, Findings and Unreachable, so it can be used as well
    as read.

.EXAMPLE
    Get-MhSqlLicensingAudit -SqlInstance SQL01, SQL02\SALES

.EXAMPLE
    Get-MhSqlLicensingAudit -ServerList .\servers.txt -SoftwareAssurance -CorePackPrice @{ Enterprise = 12000; Standard = 3500 }

.NOTES
    Molehill Data Services. Read-only throughout: it reads catalogue views, and WMI where it can.
#>

function Get-MhSqlLicensingAudit {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)] [Alias('ComputerName')] [string[]] $SqlInstance,
        [string] $ServerList,
        [pscredential] $SqlCredential,
        [switch] $SoftwareAssurance,
        [switch] $IncludeHostInventory,
        [hashtable] $HardwareOverride,
        [int] $UserCount,
        $CorePackPrice,
        [decimal] $ServerLicencePrice,
        [decimal] $CalPrice,
        [string] $OutputPath,
        [string] $CsvPath,
        [switch] $NoHtml,
        [switch] $Open,
        [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 10
    )

    begin {
            $ErrorActionPreference = 'Stop'
            $script:targets = New-Object System.Collections.Generic.List[string]
    }
    process {
            foreach ($t in $SqlInstance) { if ($t) { $script:targets.Add($t.Trim()) } }
    }
    end {
        if ($script:targets.Count -eq 0 -and $SqlInstance) { Add-LicensingTarget $SqlInstance }
        if ($ServerList) {
            if (-not (Test-Path -LiteralPath $ServerList)) { Write-Host "  No such list: $ServerList" -ForegroundColor Red; return }
            foreach ($line in (Get-Content -LiteralPath $ServerList)) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $script:targets.Add($t) }
            }
        }
        if ($script:targets.Count -eq 0) {
            Write-Host ''
            Write-Host '  SQL Server licensing audit' -ForegroundColor Cyan
            Write-Host '  Counts what needs licensing across a list of instances.' -ForegroundColor Gray
            Write-Host ''
            $answer = Read-Host '  Instances (comma separated), or the path to a list'
            if ($answer -and (Test-Path -LiteralPath $answer)) {
                foreach ($line in (Get-Content -LiteralPath $answer)) {
                    $t = $line.Trim(); if ($t -and -not $t.StartsWith('#')) { $script:targets.Add($t) }
                }
            }
            elseif ($answer) { Add-LicensingTarget $answer }
        }
        if ($script:targets.Count -eq 0) { Write-Host '  Nothing to audit.' -ForegroundColor Yellow; return }
        $runAt = Get-Date
        Write-Host ''
        Write-Host '  SQL Server licensing audit  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
        Write-Host ("  {0} instance(s)   {1}" -f $script:targets.Count, $runAt.ToString('ddd dd MMM yyyy HH:mm'))
        Write-Host ''
        $instances = New-Object System.Collections.Generic.List[object]
        $unreachable = New-Object System.Collections.Generic.List[object]
        $hostInventory = @{}
        $hostHardware = @{}
        foreach ($target in ($script:targets | Select-Object -Unique)) {
            try {
                $row = Get-LicensingInstanceFacts -Server $target

                $edition = [string]$row['Edition']
                $facts = Get-LicensingEditionFacts $edition ([int]$row['EngineEdition'])
                $isVirtual = $false
                if (-not ($row['VmType'] -is [DBNull])) { $isVirtual = ([string]$row['VmType'] -ne 'NONE') }
                $reportedSockets = if ($row['SocketCount'] -is [DBNull]) { 0 } else { [int]$row['SocketCount'] }
                $reportedPerSocket = if ($row['CoresPerSocket'] -is [DBNull]) { 0 } else { [int]$row['CoresPerSocket'] }
                $logical = [int]$row['CpuCount']
                $hostName = [string]$row['HostName']

                # Where SQL Server cannot give the processor layout - 2008 R2 and older - ask Windows, because
                # guessing it is how a four socket server gets counted as one. Also asked for every host when
                # -IncludeHostInventory is on, since Windows is the better answer wherever it is available.
                $windows = $null
                if (($reportedPerSocket -le 0 -or $IncludeHostInventory) -and -not (Get-LicensingOverride $hostName)) {
                    if (-not $hostHardware.ContainsKey($hostName)) { $hostHardware[$hostName] = Get-LicensingHostHardware -HostName $hostName }
                    if ($hostHardware[$hostName].Ok) { $windows = $hostHardware[$hostName] }
                }

                $hw = Get-LicensingHardwareFacts -ReportedSockets $reportedSockets -ReportedCoresPerSocket $reportedPerSocket `
                                        -LogicalCpus $logical -HyperthreadRatio ([int]$row['HyperthreadRatio']) -IsVirtual $isVirtual `
                                        -WindowsSockets $(if ($windows) { $windows.Sockets } else { 0 }) `
                                        -WindowsCores $(if ($windows) { $windows.Cores } else { 0 }) `
                                        -WindowsLogical $(if ($windows) { $windows.Logical } else { 0 }) `
                                        -Override (Get-LicensingOverride $hostName) -HostName $hostName
                $sockets = $hw.Sockets
                $perSocket = $hw.CoresPerSocket
                $physicalCores = $hw.PhysicalCores
                if ($hw.Source -eq 'Windows') { $logical = $hw.LogicalCpus }
                if ($hw.Source -eq 'you' -and $isVirtual) { $logical = $hw.LogicalCpus }
                $assumed = $hw.Note
                if ($hw.Source -eq 'inferred' -and $hostHardware.ContainsKey($hostName) -and -not $hostHardware[$hostName].Ok) {
                    $assumed += ('. Windows was asked on this host as well and could not answer: {0}' -f $hostHardware[$hostName].Error)
                }
                if ($windows -and $null -ne $windows.IsVirtual -and $row['VmType'] -is [DBNull]) {
                    # old versions may not say, and a VM counted as physical is counted wrong
                    $isVirtual = [bool]$windows.IsVirtual
                }

                $notes = New-Object System.Collections.Generic.List[string]
                if ($facts.Note) { $notes.Add($facts.Note) }
                if ($assumed) { $notes.Add($assumed) }

                # passive? AG secondary that allows no connections, a mirror, or everything mid-restore
                $looksPassive = $false
                $role = if ([int]$row['IsClustered'] -eq 1) { 'Clustered instance' } else { 'Standalone' }
                if ([int]$row['IsHadrEnabled'] -eq 1) {
                    try {
                        $hadr = Invoke-LicensingSql -Server $target -Query $script:LicensingHadrQuery
                        if ($hadr.Rows.Count) {
                            $r = $hadr.Rows[0]
                            $role = 'Availability Group {0} ({1})' -f [string]$r['Role'], [string]$r['AgName']
                            if ([string]$r['Role'] -eq 'SECONDARY') {
                                if ([string]$r['AllowReads'] -eq 'NO' -and [string]$r['BackupPref'] -in 'PRIMARY', 'NONE') { $looksPassive = $true }
                                else {
                                    $notes.Add(('this secondary is active, not passive: it {0}{1}. An active replica needs its own licence even with Software Assurance' -f
                                                $(if ([string]$r['AllowReads'] -ne 'NO') { 'allows read connections' } else { '' }),
                                                $(if ([string]$r['BackupPref'] -notin 'PRIMARY', 'NONE') { $(if ([string]$r['AllowReads'] -ne 'NO') { ' and ' } else { '' }) + 'is preferred for backups' } else { '' })))
                                }
                            }
                        }
                    }
                    catch { }
                }
                if (-not $looksPassive) {
                    try {
                        $sb = (Invoke-LicensingSql -Server $target -Query $script:LicensingStandbyQuery).Rows[0]
                        if ([int]$sb['UserDbs'] -gt 0 -and [int]$sb['UserDbs'] -eq [int]$sb['Restoring']) {
                            $looksPassive = $true
                            $notes.Add('every user database here is mid-restore, which looks like a log shipping or manual standby secondary')
                        }
                    }
                    catch { }
                    try {
                        $mirror = (Invoke-LicensingSql -Server $target -Query $script:LicensingMirrorQuery).Rows[0]
                        if ([int]$mirror['Mirrors'] -gt 0) { $looksPassive = $true; $notes.Add('this is a database mirroring partner') }
                    }
                    catch { }
                }

                # components living on the same engine
                $components = New-Object System.Collections.Generic.List[string]
                try {
                    $c = (Invoke-LicensingSql -Server $target -Query $script:LicensingComponentQuery).Rows[0]
                    if ([bool]$c['HasSsisCatalog'])  { $components.Add('Integration Services catalogue (SSISDB)') }
                    if ([bool]$c['HasReportServer']) { $components.Add('Reporting Services catalogue') }
                    if ([bool]$c['HasPowerBiRs'])    { $components.Add('Power BI Report Server catalogue') }
                    if ([bool]$c['HasMds'])          { $components.Add('Master Data Services') }
                    if ([bool]$c['HasDqs'])          { $components.Add('Data Quality Services') }
                }
                catch { }

                if ($facts.Family -eq 'Express' -and -not ($row['BiggestDbGb'] -is [DBNull]) -and [decimal]$row['BiggestDbGb'] -ge 9) {
                    $notes.Add(('the largest database here is {0} GB and Express stops at 10 GB: this one is about to need a licence' -f $row['BiggestDbGb']))
                }
                $online = [int]$row['OnlineCores']
                if ($facts.CoreCeiling -gt 0 -and $logical -gt $facts.CoreCeiling -and $online -lt $logical) {
                    $notes.Add(('the box has {0} logical CPUs but this edition is only using {1}' -f $logical, $online))
                }
                if (-not ($row['LicenseType'] -is [DBNull]) -and [string]$row['LicenseType'] -notin 'DISABLED', '') {
                    $notes.Add(('SERVERPROPERTY reports LicenseType {0}, which SQL Server has not maintained since 2008 - do not rely on it' -f $row['LicenseType']))
                }

                $instance = [pscustomobject]@{
                    Target        = $target
                    Instance      = [string]$row['ServerName']
                    Host          = [string]$row['HostName']
                    InstanceName  = [string]$row['InstanceName']
                    Product       = Get-LicensingProductName ([string]$row['ProductVersion'])
                    Edition       = $edition
                    EngineEdition = [int]$row['EngineEdition']
                    Facts         = $facts
                    ProductVersion = [string]$row['ProductVersion']
                    Patch         = (('{0} {1}' -f [string]$row['ProductLevel'], $(if ($row['ProductUpdate'] -is [DBNull]) { '' } else { [string]$row['ProductUpdate'] })).Trim())
                    IsVirtual     = $isVirtual
                    Sockets       = $sockets
                    CoresPerSocket = $perSocket
                    PhysicalCores = $physicalCores
                    HardwareSource = $hw.Source
                    LogicalCpus   = $logical
                    OnlineCores   = $online
                    MemoryMb      = if ($row['MemoryMb'] -is [DBNull]) { 0 } else { [int64]$row['MemoryMb'] }
                    Clustered     = ([int]$row['IsClustered'] -eq 1)
                    Role          = $role
                    LooksPassive  = $looksPassive
                    Databases     = [int]$row['Databases']
                    DataGb        = if ($row['DataGb'] -is [DBNull]) { $null } else { [decimal]$row['DataGb'] }
                    Components    = $components.ToArray()
                    Notes         = $notes.ToArray()
                }
                $instances.Add($instance)

                Write-LicensingBadge 'OK' 'Green'
                Write-Host ("  {0,-28} {1} {2}" -f $instance.Instance, $instance.Product, $facts.Family) -NoNewline
                Write-Host ("   {0}, {1}{2}" -f $(if ($isVirtual) { 'VM' } else { 'physical' }),
                            $(if ($isVirtual) { "$logical vCPU" } else { "$sockets socket(s), $physicalCores cores" }),
                            $(if ($hw.Source -eq 'inferred') { ' (inferred)' } elseif ($hw.Source -ne 'SQL Server') { " (from $($hw.Source))" } else { '' })) -ForegroundColor DarkGray
            }
            catch {
                $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                $unreachable.Add([pscustomobject]@{ Target = $target; Error = $message })
                Write-LicensingBadge 'MISS' 'Red'
                Write-Host ("  {0,-28} {1}" -f $target, $message)
            }
        }
        foreach ($i in @($instances | Where-Object { $_.Clustered })) {
            try {
                $nodes = Invoke-LicensingSql -Server $i.Target -Query $script:LicensingClusterQuery
                $others = @($nodes.Rows | ForEach-Object { [string]$_['NodeName'] } | Where-Object { $_ -ne $i.Host })
                if ($others.Count) {
                    $i.Notes = @($i.Notes) + ('a failover cluster instance; the other node(s) are {0}. One passive node is free under Software Assurance, and needs licensing without it' -f ($others -join ', '))
                }
            }
            catch { }
        }
        if ($IncludeHostInventory) {
            Write-Host ''
            foreach ($hostName in (@($instances | ForEach-Object { $_.Host }) | Select-Object -Unique)) {
                $inv = Get-LicensingHostComponents -HostName $hostName
                $hostInventory[$hostName] = $inv
                if (-not $inv.Ok) {
                    Write-LicensingBadge 'HOST' 'Yellow'
                    Write-Host ("  {0,-28} could not read the service list ({1}). Analysis, Reporting and Integration Services on this host will be missed." -f $hostName, $inv.Error)
                    continue
                }
                $extra = @($inv.Components | Where-Object { $_.Kind -ne 'Database engine' })
                if ($extra.Count) {
                    Write-LicensingBadge 'HOST' 'Cyan'
                    Write-Host ("  {0,-28} also runs {1}" -f $hostName, (($extra | ForEach-Object { '{0} ({1})' -f $_.Kind, $_.State.ToLower() }) -join ', '))
                }
            }
        }
        if ($instances.Count -eq 0) {
            Write-Host ''
            Write-Host '  Nothing could be audited.' -ForegroundColor Red
            Write-Host ''
            return
        }
        $hosts = New-Object System.Collections.Generic.List[object]
        foreach ($group in ($instances | Group-Object Host)) {
            $onHost = @($group.Group)
            $licence = Get-LicensingHostLicence -Instances $onHost -SoftwareAssurance:$SoftwareAssurance
            $serverCal = Get-LicensingServerCalOption -Instances $onHost
            $top = @($onHost | Sort-Object { $_.Facts.Rank } | Select-Object -Last 1)[0]

            $hosts.Add([pscustomobject]@{
                Host      = $group.Name
                Instances = $onHost
                Product   = $top.Product
                Licence   = $licence
                ServerCal = $serverCal
                IsVirtual = $top.IsVirtual
            })
        }
        $componentHosts = New-Object System.Collections.Generic.List[object]
        foreach ($hostName in $hostInventory.Keys) {
            $inv = $hostInventory[$hostName]
            if (-not $inv.Ok) { continue }
            $extra = @($inv.Components | Where-Object { $_.Kind -ne 'Database engine' -and $_.State -eq 'Running' })
            if ($extra.Count -eq 0) { continue }
            $hostRow = @($hosts | Where-Object { $_.Host -eq $hostName })
            $covered = ($hostRow.Count -gt 0 -and $hostRow[0].Licence.Packs -gt 0)
            $componentHosts.Add([pscustomobject]@{
                Host = $hostName
                Kinds = @($extra | ForEach-Object { $_.Kind } | Select-Object -Unique)
                Covered = $covered
            })
        }
        Write-Host ''
        Write-Host '  Hosts' -ForegroundColor White
        Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
        foreach ($h in ($hosts | Sort-Object { -$_.Licence.Packs }, Host)) {
            $l = $h.Licence
            $instanceText = (@($h.Instances | ForEach-Object { $_.InstanceName }) -join ', ')
            Write-Host ("  {0,-20} {1,-26} {2}" -f $h.Host, $instanceText,
                        $(if ($l.FreeOnly) { "$($l.Edition) only - no licence needed" }
                          else { '{0} {1}, {2} core licence(s), {3} x 2-core pack(s){4}' -f $h.Product, $l.Edition, $l.Cores, $l.Packs,
                                 $(if ($l.Waived -gt 0) { " (waived: $($l.Waived))" } else { '' }) })) `
                       -ForegroundColor $(if ($l.FreeOnly) { 'DarkGray' } elseif ($l.Passive) { 'Yellow' } else { 'Gray' })
            Write-Host ("  {0,-20} {1}" -f '', ('{0}{1}' -f $(if ($h.IsVirtual) { 'virtual machine, ' } else { 'physical, ' }), $l.Basis)) -ForegroundColor DarkGray
            foreach ($n in $l.Notes) { Write-Host ("  {0,-20} - {1}" -f '', $n) -ForegroundColor DarkGray }
            foreach ($i in $h.Instances) {
                foreach ($n in $i.Notes) {
                    $colour = if ($n -match 'production|180 days|about to need|SPLA|active, not passive') { 'Yellow' } else { 'DarkGray' }
                    Write-Host ("  {0,-20} - {1}: {2}" -f '', $i.InstanceName, $n) -ForegroundColor $colour
                }
                foreach ($c in $i.Components) { Write-Host ("  {0,-20} - {1}: {2}" -f '', $i.InstanceName, $c) -ForegroundColor DarkGray }
            }
        }
        $totals = Get-LicensingTotals -Hosts $hosts.ToArray()
        $needed = New-Object System.Collections.Generic.List[object]
        foreach ($n in $totals.Needed) {
            $n | Add-Member -NotePropertyName Price -NotePropertyValue (Get-LicensingPackPrice $n.Edition)
            $needed.Add($n)
        }
        $freeInstances = @($instances | Where-Object { -not $_.Facts.Licensable })
        Write-Host ''
        Write-Host '  Licences needed' -ForegroundColor White
        Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
        Write-Host ("  {0,-26} {1,-14} {2,-7} {3,-8} {4,-10} {5}" -f 'Product', 'Edition', 'Hosts', 'Cores', '2-core', 'Cost') -ForegroundColor DarkGray
        $totalPacks = 0
        $totalCost = [decimal]0
        $pricedAll = $true
        foreach ($n in ($needed | Sort-Object Product, Edition)) {
            $totalPacks += $n.Packs
            $cost = ''
            if ($null -ne $n.Price) { $c = $n.Price * $n.Packs; $totalCost += $c; $cost = Format-LicensingMoney $c }
            elseif ($n.Packs -gt 0) { $pricedAll = $false }
            Write-Host ("  {0,-26} {1,-14} {2,-7} {3,-8} {4,-10} {5}" -f $n.Product, $n.Edition, $n.Hosts, $n.Cores, $n.Packs, $cost)
        }
        foreach ($c in ($componentHosts | Where-Object { -not $_.Covered })) {
            Write-Host ("  {0,-26} {1}" -f ($c.Kinds -join ', '), ('on {0}, which has no licensed engine: this host needs a SQL Server licence of its own' -f $c.Host)) -ForegroundColor Yellow
        }
        if ($needed.Count -eq 0) { Write-Host '  Nothing in this list needs a licence.' -ForegroundColor Green }
        Write-Host ''
        Write-Host '  Total  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
        Write-Host ("  {0} two-core pack(s), covering {1} core(s) across {2} host(s){3}" -f
                    $totals.Packs, $totals.Cores, $totals.HostsLicensed,
                    $(if ($totalCost -gt 0) { ' - ' + (Format-LicensingMoney $totalCost) + $(if (-not $pricedAll) { ' (part priced)' } else { '' }) } else { '' }))
        $waivedTotal = $totals.Waived
        if ($waivedTotal -gt 0) {
            Write-Host ("         {0} pack(s) left out as passive failover under Software Assurance" -f $waivedTotal) -ForegroundColor Yellow
        }
        elseif (@($hosts | Where-Object { $_.Licence.Passive }).Count -gt 0) {
            $passivePacks = $totals.PassivePacks
            Write-Host ("         {0} of those pack(s) are for passive failover, and would be free with Software Assurance" -f $passivePacks) -ForegroundColor Yellow
        }
        if ($freeInstances.Count) {
            Write-Host ("         free, nothing to buy: {0}" -f ((@($freeInstances | Group-Object { $_.Facts.Family } |
                         ForEach-Object { '{0} x {1}' -f $_.Count, $_.Name }) -join ', '))) -ForegroundColor DarkGray
        }
        $calHosts = @($hosts | Where-Object { $null -ne $_.ServerCal -and -not $_.Licence.FreeOnly })
        if ($calHosts.Count) {
            $serverLicences = $calHosts.Count
            $calPacks = ($calHosts | ForEach-Object { $_.Licence.Packs } | Measure-Object -Sum).Sum
            Write-Host ''
            Write-Host '  Server + CAL instead, for the Standard hosts' -ForegroundColor White
            Write-Host ("    {0} server licence(s) for {1}, plus a CAL for every user or device that reaches them" -f
                        $serverLicences, (($calHosts | ForEach-Object { $_.Host }) -join ', ')) -ForegroundColor Gray
            Write-Host ("    instead of the {0} two-core pack(s) those hosts account for above" -f $calPacks) -ForegroundColor Gray
            if ($UserCount -gt 0 -and $ServerLicencePrice -gt 0 -and $CalPrice -gt 0) {
                $calCost = ($ServerLicencePrice * $serverLicences) + ($CalPrice * $UserCount)
                $corePrice = Get-LicensingPackPrice 'Standard'
                $coreCost = if ($null -ne $corePrice) { $corePrice * $calPacks } else { $null }
                Write-Host ("    {0} users: {1} as Server + CAL{2}" -f $UserCount, (Format-LicensingMoney $calCost),
                            $(if ($null -ne $coreCost) { ' against ' + (Format-LicensingMoney $coreCost) + ' per core - ' +
                               $(if ($calCost -lt $coreCost) { 'Server + CAL is cheaper' } else { 'per core is cheaper' }) } else { '' })) `
                           -ForegroundColor $(if ($null -ne $coreCost -and $calCost -lt $coreCost) { 'Green' } else { 'Gray' })
            }
            elseif ($UserCount -gt 0) {
                Write-Host ("    {0} CALs at the price you pay, against the per-core cost: give -CalPrice, -ServerLicencePrice and -CorePackPrice to have that compared" -f $UserCount) -ForegroundColor DarkGray
            }
            else {
                Write-Host '    CAL counts cannot be read off a server: pass -UserCount to have the two options compared.' -ForegroundColor DarkGray
            }
        }
        $findings = New-Object System.Collections.Generic.List[object]
        foreach ($i in $instances) {
            if ($i.Facts.Family -eq 'Developer') { $findings.Add([pscustomobject]@{ Instance = $i.Instance; What = 'Developer Edition - free for development and test only. If this is production, it needs a licence.' }) }
            if ($i.Facts.Family -eq 'Evaluation') { $findings.Add([pscustomobject]@{ Instance = $i.Instance; What = 'Evaluation Edition - stops working 180 days after installation.' }) }
            if ($i.Facts.Family -eq 'Web') { $findings.Add([pscustomobject]@{ Instance = $i.Instance; What = 'Web Edition - only licensable by service providers through SPLA.' }) }
            if ($i.Facts.Family -eq 'Unknown') { $findings.Add([pscustomobject]@{ Instance = $i.Instance; What = "Edition '$($i.Edition)' was not recognised, so it is not in the totals." }) }
            foreach ($n in $i.Notes) {
                if ($n -match 'about to need a licence|active, not passive|can only use') { $findings.Add([pscustomobject]@{ Instance = $i.Instance; What = $n }) }
            }
        }
        foreach ($c in ($componentHosts | Where-Object { -not $_.Covered })) {
            $findings.Add([pscustomobject]@{ Instance = $c.Host; What = ('{0} runs here with no licensed database engine, so this host needs a SQL Server licence of its own.' -f ($c.Kinds -join ', ')) })
        }
        foreach ($u in $unreachable) { $findings.Add([pscustomobject]@{ Instance = $u.Target; What = ('not audited: {0}' -f $u.Error) }) }
        if ($findings.Count) {
            Write-Host ''
            Write-Host '  Worth a look' -ForegroundColor White
            Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
            foreach ($f in $findings) { Write-Host ("  {0,-24} {1}" -f $f.Instance, $f.What) -ForegroundColor Yellow }
        }
        $virtualCount = @($hosts | Where-Object { $_.IsVirtual -and -not $_.Licence.FreeOnly }).Count
        if ($virtualCount -ge 4) {
            Write-Host ''
            Write-Host ("  {0} of these are virtual machines, licensed one VM at a time above. Where several share a hypervisor host," -f $virtualCount) -ForegroundColor Cyan
            Write-Host '  licensing that host''s physical cores for Enterprise with Software Assurance allows unlimited SQL VMs on it,' -ForegroundColor Cyan
            Write-Host '  which is often cheaper. Worth working out with whoever runs the hypervisor.' -ForegroundColor Cyan
        }
        Write-Host ''
        Write-Host '  This counts what the estate needs. What you already own - Software Assurance, agreements, existing' -ForegroundColor DarkGray
        Write-Host '  packs and CALs - is not on any server, so put this next to your paperwork before buying anything.' -ForegroundColor DarkGray
        Write-Host ''
        if ($CsvPath) {
            $instances | Select-Object Instance, Host, InstanceName, Product, Edition,
                @{ n = 'Family'; e = { $_.Facts.Family } }, @{ n = 'Licensable'; e = { $_.Facts.Licensable } },
                ProductVersion, Patch, @{ n = 'Virtual'; e = { $_.IsVirtual } }, Sockets, CoresPerSocket, LogicalCpus,
                OnlineCores, MemoryMb, Role, LooksPassive, Databases, DataGb,
                @{ n = 'HostCoreLicences'; e = { $hn = $_.Host; (@($hosts | Where-Object { $_.Host -eq $hn })[0]).Licence.Cores } },
                @{ n = 'HostPacks'; e = { $hn = $_.Host; (@($hosts | Where-Object { $_.Host -eq $hn })[0]).Licence.Packs } },
                @{ n = 'Components'; e = { $_.Components -join '; ' } }, @{ n = 'Notes'; e = { $_.Notes -join ' | ' } } |
                Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "  Saved to $CsvPath" -ForegroundColor Gray
        }
        if (-not $NoHtml) {
            if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) ("SqlLicensing_{0}.html" -f $runAt.ToString('yyyyMMdd_HHmm')) }
            $sb = New-Object System.Text.StringBuilder
            $add = { param($t) [void]$sb.AppendLine($t) }

            & $add @"
<!doctype html>
<html><head><meta charset="utf-8" /><title>SQL Server licensing audit - $($runAt.ToString('dd MMM yyyy'))</title>
<style>
body{margin:0;background:#F4F2F1;font-family:Krungthep,Bahnschrift,"DIN Alternate","Trebuchet MS","Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.45}
.wrap{max-width:1200px;margin:0 auto;padding:24px}
.hero{background:#231F20;color:#fff;padding:22px 28px;border-bottom:4px solid #44C8F5}.hero h1{margin:0;font-size:24px;letter-spacing:.5px}
.meta{color:#BFBBBA;font-size:13px;margin-top:6px}
.cards{display:flex;gap:12px;margin:18px 0;flex-wrap:wrap}.card{background:#fff;padding:12px 18px;min-width:120px;border-top:4px solid #44C8F5}
.card b{display:block;font-size:24px}.card.warn{border-color:#F2A93B}.card.free{border-color:#BFBBBA}
h2{font-size:17px;margin:26px 0 8px;letter-spacing:.4px}
table{width:100%;border-collapse:collapse;background:#fff;font-size:13px;margin-bottom:6px}
th{background:#231F20;color:#fff;text-align:left;padding:8px 10px;font-weight:600}
td{padding:8px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}
tr.total td{background:#231F20;color:#fff;font-weight:700;border-bottom:none}
td.num,th.num{text-align:right}
.free{color:#7A7473}.warn{background:#F9D58C}.pass{background:#DDF3FC}
.sub{color:#7A7473;font-size:12px}
ul.notes{margin:4px 0 0;padding-left:16px;color:#7A7473;font-size:12px}
.foot{color:#7A7473;font-size:12px;margin:26px 0 0;border-top:1px solid #E2DEDD;padding-top:12px}
</style></head><body>
<div class="hero"><h1>SQL Server licensing audit</h1>
<div class="meta">$($instances.Count) instance(s) on $($hosts.Count) host(s) &#183; audited $($runAt.ToString('dddd dd MMMM yyyy HH:mm')) from $env:COMPUTERNAME as $([Environment]::UserDomainName)\$([Environment]::UserName)$(if ($SoftwareAssurance) { ' &#183; Software Assurance assumed' } else { '' })</div></div>
<div class="wrap">
<div class="cards">
<div class="card"><b>$totalPacks</b>two-core packs</div>
<div class="card"><b>$($totals.Cores)</b>core licences</div>
<div class="card warn"><b>$($findings.Count)</b>to look at</div>
<div class="card free"><b>$($freeInstances.Count)</b>free editions</div>
$(if ($totalCost -gt 0) { "<div class=`"card`"><b>$(Format-LicensingMoney $totalCost)</b>estimated cost</div>" } else { '' })
</div>
<h2>Licences needed</h2>
<table><tr><th>Product</th><th>Edition</th><th>Model</th><th class="num">Hosts</th><th class="num">Core licences</th><th class="num">2-core packs</th>$(if ($totalCost -gt 0) { '<th class="num">Cost</th>' } else { '' })</tr>
"@

            foreach ($n in ($needed | Sort-Object Product, Edition)) {
                $cost = if ($null -ne $n.Price) { Format-LicensingMoney ($n.Price * $n.Packs) } else { '-' }
                & $add ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=`"num`">{3}</td><td class=`"num`">{4}</td><td class=`"num`">{5}</td>{6}</tr>" -f
                        (Esc-LicensingHtml $n.Product), (Esc-LicensingHtml $n.Edition), $n.Model, $n.Hosts, $n.Cores, $n.Packs,
                        $(if ($totalCost -gt 0) { "<td class=`"num`">$cost</td>" } else { '' }))
            }
            & $add ("<tr class=`"total`"><td colspan=`"5`">Total to cover everything in this list</td><td class=`"num`">{0}</td>{1}</tr>" -f
                    $totalPacks, $(if ($totalCost -gt 0) { "<td class=`"num`">$(Format-LicensingMoney $totalCost)</td>" } else { '' }))
            & $add '</table>'

            if ($waivedTotal -gt 0) { & $add ("<p class=`"sub`">{0} pack(s) for passive failover replicas are left out, as Software Assurance covers them.</p>" -f $waivedTotal) }
            if ($calHosts.Count) {
                & $add ("<p class=`"sub`">Server + CAL alternative: {0} Standard server licence(s) for {1}, plus a CAL per user or device, in place of {2} two-core pack(s).</p>" -f
                        $calHosts.Count, (Esc-LicensingHtml (($calHosts | ForEach-Object { $_.Host }) -join ', ')),
                        ($calHosts | ForEach-Object { $_.Licence.Packs } | Measure-Object -Sum).Sum)
            }

            & $add '<h2>Hosts</h2><table><tr><th>Host</th><th>Instances</th><th>Hardware</th><th>Edition licensed</th><th class="num">Cores</th><th class="num">Packs</th></tr>'
            foreach ($h in ($hosts | Sort-Object { -$_.Licence.Packs }, Host)) {
                $l = $h.Licence
                $class = if ($l.FreeOnly) { ' class="free"' } elseif ($l.Passive) { ' class="warn"' } else { '' }
                $notes = @($l.Notes) + @($h.Instances | ForEach-Object { $i = $_; $i.Notes | ForEach-Object { '{0}: {1}' -f $i.InstanceName, $_ } }) +
                         @($h.Instances | ForEach-Object { $i = $_; $i.Components | ForEach-Object { '{0}: {1}' -f $i.InstanceName, $_ } })
                $noteHtml = if (@($notes).Count) { '<ul class="notes">' + ((@($notes) | ForEach-Object { '<li>' + (Esc-LicensingHtml $_) + '</li>' }) -join '') + '</ul>' } else { '' }
                & $add ("<tr$class><td>{0}{1}</td><td>{2}<div class=`"sub`">{3}</div></td><td>{4}<div class=`"sub`">{5}</div></td><td>{6}</td><td class=`"num`">{7}</td><td class=`"num`">{8}</td></tr>" -f
                        (Esc-LicensingHtml $h.Host), $noteHtml,
                        (Esc-LicensingHtml ((@($h.Instances | ForEach-Object { $_.InstanceName }) -join ', '))),
                        (Esc-LicensingHtml ((@($h.Instances | ForEach-Object { $_.Role }) | Select-Object -Unique) -join '; ')),
                        $(if ($h.IsVirtual) { 'virtual machine' } else { 'physical' }), (Esc-LicensingHtml $l.Basis),
                        (Esc-LicensingHtml (@($h.Product, $l.Edition) -join ' ')),
                        $(if ($l.FreeOnly) { '-' } else { $l.Cores }), $(if ($l.FreeOnly) { '-' } else { $l.Packs }))
            }
            & $add '</table>'

            if ($findings.Count) {
                & $add '<h2>Worth a look</h2><table><tr><th>Where</th><th>What</th></tr>'
                foreach ($f in $findings) { & $add ("<tr class=`"warn`"><td>{0}</td><td>{1}</td></tr>" -f (Esc-LicensingHtml $f.Instance), (Esc-LicensingHtml $f.What)) }
                & $add '</table>'
            }

            & $add @"
<h2>How this was counted</h2>
<table><tr><th>Rule</th><th>Applied</th></tr>
<tr><td>Licences belong to an OS environment</td><td>Instances were grouped by host, so several instances on one server share one set of core licences.</td></tr>
<tr><td>Physical servers</td><td>Every physical core, with a minimum of four per socket. Hyperthreading does not change the count.</td></tr>
<tr><td>Virtual machines</td><td>Every vCPU, with a minimum of four per VM.</td></tr>
<tr><td>Two-core packs</td><td>Pack counts are rounded up, so an odd number of cores buys one core more than it needs.</td></tr>
<tr><td>Mixed editions on a host</td><td>The highest edition licenses the cores and covers the lower ones through downgrade rights.</td></tr>
<tr><td>Free editions</td><td>Express, Developer and Evaluation are listed but never totalled. Developer is for development and test only.</td></tr>
<tr><td>Passive failover</td><td>$(if ($SoftwareAssurance) { 'Taken out of the total, as you have Software Assurance.' } else { 'Counted, and shown separately: with Software Assurance one passive replica per licensed primary is free.' })</td></tr>
<tr><td>Not in these numbers</td><td>What you already own. Software Assurance, agreement terms, licence mobility, existing packs and CAL counts are not readable from a server - put this next to your paperwork.</td></tr>
</table>
<p class="foot">Molehill Data Services Ltd &#183; Company number 17219913 &#183; An inventory to inform a licensing conversation, not licensing advice.</p>
</div></body></html>
"@

            [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
            Write-Host "  Report saved: $OutputPath" -ForegroundColor Green
            Write-Host ''
            if ($Open) { Start-Process $OutputPath }
        }
        # what the exit code used to say, as something a caller can read
        [pscustomobject]@{
            Instances   = [object[]]$instances
            Hosts       = [object[]]$hosts
            Totals      = [object[]]$totals
            Needed      = [object[]]$needed
            Findings    = [object[]]$findings
            Unreachable = [object[]]$unreachable
            TotalPacks  = $totalPacks
            TotalCost   = $totalCost
            RunAt       = $runAt
        }
    }
}

function Get-LicensingEditionFacts {
    [CmdletBinding()]
    param([string] $Edition, [int] $EngineEdition = 0)

    $e = [string]$Edition
    $facts = [pscustomobject]@{
        Family = 'Unknown'; Licensable = $true; Models = @('PerCore'); Rank = 50
        CoreCeiling = 0           # cores the edition can actually use, 0 = no limit worth noting
        Note = $null
    }

    switch -Regex ($e) {
        'Developer' {
            $facts.Family = 'Developer'; $facts.Licensable = $false; $facts.Models = @(); $facts.Rank = 10
            $facts.Note = 'Developer Edition is licensed for development and test only. If anything in production touches this, it needs a real licence.'
            break
        }
        'Evaluation' {
            $facts.Family = 'Evaluation'; $facts.Licensable = $false; $facts.Models = @(); $facts.Rank = 15
            $facts.Note = 'Evaluation Edition stops working 180 days after installation. It needs replacing with a licensed edition, not renewing.'
            break
        }
        'Express' {
            $facts.Family = 'Express'; $facts.Licensable = $false; $facts.Models = @(); $facts.Rank = 5
            $facts.CoreCeiling = 4
            $facts.Note = 'Express is free, and capped: 4 cores, about 1.4 GB of memory for the engine, and 10 GB per database.'
            break
        }
        'Web' {
            $facts.Family = 'Web'; $facts.Models = @('PerCore'); $facts.Rank = 30
            $facts.Note = 'Web Edition is only licensed to service providers through SPLA. On a normal estate it is the wrong edition and needs replacing with Standard.'
            break
        }
        'Business Intelligence' {
            $facts.Family = 'BusinessIntelligence'; $facts.Models = @('ServerCal'); $facts.Rank = 60
            $facts.Note = 'Business Intelligence Edition is Server + CAL only, and was dropped after SQL Server 2014.'
            break
        }
        'Enterprise' {
            $facts.Family = 'Enterprise'; $facts.Models = @('PerCore'); $facts.Rank = 90
            break
        }
        'Standard' {
            $facts.Family = 'Standard'; $facts.Models = @('PerCore', 'ServerCal'); $facts.Rank = 70
            $facts.CoreCeiling = 24
            break
        }
        default {
            if ($EngineEdition -in 5, 6, 8, 9, 11) {
                $facts.Family = 'Azure'; $facts.Licensable = $false; $facts.Models = @(); $facts.Rank = 1
                $facts.Note = 'This is an Azure SQL service. It is paid for by the hour, not licensed per core, so it is not part of these totals.'
            }
            else { $facts.Note = "The edition string '$e' is not one this script recognises: check it by hand." }
        }
    }

    # pre-2012 Enterprise could be Server + CAL; from 2012 it is core-based only
    if ($facts.Family -eq 'Enterprise' -and $e -notmatch 'Core-based' -and $EngineEdition -eq 3) {
        $facts.Note = 'Enterprise is core-based only from SQL Server 2012. An older Server + CAL Enterprise licence can be kept on the version it came with, but not moved forward.'
    }
    $facts
}

function Get-LicensingHardwareFacts {
    [CmdletBinding()]
    param(
        [int] $ReportedSockets, [int] $ReportedCoresPerSocket,
        [int] $LogicalCpus, [int] $HyperthreadRatio, [bool] $IsVirtual,
        [int] $WindowsSockets, [int] $WindowsCores, [int] $WindowsLogical,
        [string] $Override, [string] $HostName = '<host>'
    )

    $facts = [pscustomobject]@{
        Sockets = 1; CoresPerSocket = 1; PhysicalCores = 1; LogicalCpus = [Math]::Max($LogicalCpus, 1)
        Source = 'SQL Server'; Assumed = $false; LowerBoundCores = 0; Note = $null
    }

    if ($Override) {
        $parts = ([string]$Override).ToLower().Split('x')
        $good = $false
        if ($parts.Count -eq 2 -and $parts[0].Trim() -match '^\d+$' -and $parts[1].Trim() -match '^\d+$') {
            $facts.Sockets = [Math]::Max([int]$parts[0].Trim(), 1)
            $facts.CoresPerSocket = [Math]::Max([int]$parts[1].Trim(), 1)
            $good = $true
        }
        elseif ($parts.Count -eq 1 -and $parts[0].Trim() -match '^\d+$') {
            $facts.Sockets = 1
            $facts.CoresPerSocket = [Math]::Max([int]$parts[0].Trim(), 1)
            $good = $true
        }
        if ($good) {
            $facts.PhysicalCores = $facts.Sockets * $facts.CoresPerSocket
            if ($IsVirtual) { $facts.LogicalCpus = $facts.PhysicalCores }
            $facts.Source = 'you'
            return $facts
        }
        $facts.Note = "-HardwareOverride '$Override' was not understood, so it was ignored: use '4x8' for four sockets of eight cores, or '16' for sixteen cores in one socket."
    }

    if ($WindowsCores -gt 0) {
        $keepNote = $facts.Note
        $facts.Sockets = [Math]::Max($WindowsSockets, 1)
        $facts.PhysicalCores = $WindowsCores
        $facts.CoresPerSocket = [Math]::Max([int][Math]::Round($WindowsCores / [double]$facts.Sockets), 1)
        if ($WindowsLogical -gt 0) { $facts.LogicalCpus = $WindowsLogical }
        $facts.Source = 'Windows'
        $facts.Note = $keepNote
        return $facts
    }

    if ($ReportedCoresPerSocket -gt 0) {
        $facts.CoresPerSocket = $ReportedCoresPerSocket
        if ($ReportedSockets -gt 0) { $facts.Sockets = $ReportedSockets }
        else {
            # Express and LocalDB report no socket count at all, while cores per socket is right
            $facts.Sockets = 1
            $facts.Note = 'this instance reports no socket count, so one socket is assumed - check it if the server has more than one processor'
        }
        $facts.PhysicalCores = $facts.Sockets * $facts.CoresPerSocket
        return $facts
    }

    # Before SQL Server 2012, cpu_count / hyperthread_ratio is the socket count - and nothing here
    # says whether those logical CPUs are hyperthreaded.
    $ratio = [Math]::Max($HyperthreadRatio, 1)
    $logical = [Math]::Max($LogicalCpus, 1)
    $facts.Sockets = [Math]::Max([int][Math]::Round($logical / [double]$ratio), 1)
    $facts.CoresPerSocket = [Math]::Max([int][Math]::Round($logical / [double]$facts.Sockets), 1)
    $facts.PhysicalCores = $facts.Sockets * $facts.CoresPerSocket
    $facts.Assumed = $true
    $facts.Source = 'inferred'

    $minimum = $facts.Sockets * 4
    $upper = [Math]::Max($facts.PhysicalCores, $minimum)
    $halved = [Math]::Max([int][Math]::Ceiling($facts.PhysicalCores / 2.0), 1)
    $facts.LowerBoundCores = [Math]::Max($halved, $minimum)

    if ($facts.LowerBoundCores -eq $upper) {
        $facts.Note = ('this version reports only {0} logical CPUs and a hyperthread ratio of {1}, which is {2} socket(s). Hyperthreading on or off, the four-per-socket minimum makes it {3} core licences either way' -f
                       $logical, $ratio, $facts.Sockets, $upper)
    }
    else {
        $facts.Note = ('this version reports only {0} logical CPUs and a hyperthread ratio of {1}, which is {2} socket(s). It cannot say whether hyperthreading is on, so {3} physical cores is assumed - with it on this could be as low as {4}. Confirm the physical cores, or pass -HardwareOverride @{{ ''{5}'' = ''{2}x{6}'' }}' -f
                       $logical, $ratio, $facts.Sockets, $facts.PhysicalCores, $facts.LowerBoundCores, $HostName, $facts.CoresPerSocket)
    }
    $facts
}

function Get-LicensingCoreLicences {
    [CmdletBinding()]
    param(
        [int] $Sockets,
        [int] $PhysicalCores,
        [int] $LogicalCpus,
        [bool] $IsVirtual
    )

    $result = [pscustomobject]@{ Cores = 0; Packs = 0; Basis = ''; Minimum = $false }

    if ($IsVirtual) {
        $counted = [Math]::Max($LogicalCpus, 1)
        $result.Cores = [Math]::Max($counted, 4)
        $result.Basis = '{0} vCPU' -f $counted
        $result.Minimum = ($counted -lt 4)
    }
    else {
        $sockets = [Math]::Max($Sockets, 1)
        $physical = [Math]::Max($PhysicalCores, 1)
        $result.Cores = [Math]::Max($physical, $sockets * 4)
        $result.Basis = '{0} socket{1}, {2} physical core{3}' -f $sockets, $(if ($sockets -ne 1) { 's' } else { '' }),
                                                                 $physical, $(if ($physical -ne 1) { 's' } else { '' })
        $result.Minimum = ($physical -lt $sockets * 4)
    }
    $result.Packs = [Math]::Ceiling($result.Cores / 2.0)
    $result
}

function Get-LicensingProductName {
    [CmdletBinding()]
    param([string] $ProductVersion)

    $parts = ([string]$ProductVersion).Split('.')
    if ($parts.Count -lt 2) { return 'SQL Server' }
    $key = '{0}.{1}' -f $parts[0], $parts[1]
    $names = @{
        '8.0' = '2000'; '9.0' = '2005'; '10.0' = '2008'; '10.50' = '2008 R2'; '11.0' = '2012'
        '12.0' = '2014'; '13.0' = '2016'; '14.0' = '2017'; '15.0' = '2019'; '16.0' = '2022'; '17.0' = '2025'
    }
    if ($names.ContainsKey($key)) { return 'SQL Server ' + $names[$key] }
    'SQL Server (build {0})' -f $ProductVersion
}

function Get-LicensingHostLicence {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Instances, [switch] $SoftwareAssurance)

    $result = [pscustomobject]@{
        Edition = $null; Cores = 0; Packs = 0; Basis = ''; Model = $null
        Passive = $false; Waived = 0; Notes = @(); FreeOnly = $false
    }
    if (-not $Instances -or $Instances.Count -eq 0) { return $result }

    $notes = New-Object System.Collections.Generic.List[string]
    $licensable = @($Instances | Where-Object { $_.Facts.Licensable })
    if ($licensable.Count -eq 0) {
        $top = @($Instances | Sort-Object { $_.Facts.Rank } | Select-Object -Last 1)[0]
        $result.FreeOnly = $true
        $result.Edition = $top.Facts.Family
        $result.Basis = (Get-LicensingCoreLicences -Sockets $top.Sockets -PhysicalCores $top.PhysicalCores `
                                          -LogicalCpus $top.LogicalCpus -IsVirtual $top.IsVirtual).Basis
        return $result
    }

    $top = @($licensable | Sort-Object { $_.Facts.Rank } | Select-Object -Last 1)[0]
    $result.Edition = $top.Facts.Family
    $result.Model = if ($top.Facts.Models -contains 'PerCore') { 'PerCore' } else { 'ServerCal' }

    $lower = @($licensable | Where-Object { $_.Facts.Family -ne $top.Facts.Family })
    if ($lower.Count) {
        $notes.Add(('{0} covers the {1} instance{2} on this host as well (downgrade rights)' -f
                    $top.Facts.Family, (($lower | ForEach-Object { $_.Facts.Family } | Select-Object -Unique) -join ' and '),
                    $(if ($lower.Count -ne 1) { 's' } else { '' })))
    }

    $cores = Get-LicensingCoreLicences -Sockets $top.Sockets -PhysicalCores $top.PhysicalCores `
                              -LogicalCpus $top.LogicalCpus -IsVirtual $top.IsVirtual
    $result.Cores = $cores.Cores
    $result.Packs = $cores.Packs
    $result.Basis = $cores.Basis
    if ($cores.Minimum) { $notes.Add(('the hardware is smaller than the licensing minimum, so {0} cores are licensed anyway' -f $cores.Cores)) }

    # the whole host is passive only if every licensable instance on it is
    $result.Passive = (@($licensable | Where-Object { -not $_.LooksPassive }).Count -eq 0)
    if ($result.Passive) {
        if ($SoftwareAssurance) {
            $result.Waived = $result.Packs
            $notes.Add(('passive failover only: free under Software Assurance, so its {0} core licences are not counted' -f $result.Cores))
            $result.Packs = 0
            $result.Cores = 0
        }
        else {
            $notes.Add('this looks like passive failover. With Software Assurance it would be free - without it, these licences are needed')
        }
    }

    # a Standard instance on a box with more cores than Standard can use is money burnt twice over
    if ($top.Facts.CoreCeiling -gt 0 -and $result.Cores -gt $top.Facts.CoreCeiling) {
        $notes.Add(('{0} can only use {1} of these {2} cores, but all of them have to be licensed. Fewer cores, or Enterprise, would both be cheaper than this' -f
                    $top.Facts.Family, $top.Facts.CoreCeiling, $result.Cores))
    }
    $result.Notes = $notes.ToArray()
    $result
}

function Get-LicensingServerCalOption {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Instances)

    $eligible = @($Instances | Where-Object { $_.Facts.Licensable -and $_.Facts.Models -contains 'ServerCal' })
    $blocked  = @($Instances | Where-Object { $_.Facts.Licensable -and $_.Facts.Models -notcontains 'ServerCal' })
    if ($eligible.Count -eq 0 -or $blocked.Count -gt 0) { return $null }
    [pscustomobject]@{ ServerLicences = 1; Edition = $eligible[0].Facts.Family }
}

function Get-LicensingTotals {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Hosts)

    $needed = New-Object System.Collections.Generic.List[object]
    foreach ($group in (@($Hosts | Where-Object { -not $_.Licence.FreeOnly }) | Group-Object { '{0}|{1}' -f $_.Product, $_.Licence.Edition })) {
        $first = $group.Group[0]
        $packs  = [int](@($group.Group) | ForEach-Object { $_.Licence.Packs } | Measure-Object -Sum).Sum
        $cores  = [int](@($group.Group) | ForEach-Object { $_.Licence.Cores } | Measure-Object -Sum).Sum
        $waived = [int](@($group.Group) | ForEach-Object { $_.Licence.Waived } | Measure-Object -Sum).Sum
        if ($packs -eq 0 -and $waived -eq 0) { continue }
        $needed.Add([pscustomobject]@{
            Product = $first.Product; Edition = $first.Licence.Edition; Model = 'Per core'
            Hosts = $group.Group.Count; Cores = $cores; Packs = $packs; Waived = $waived
        })
    }

    $passive = @($Hosts | Where-Object { $_.Licence.Passive -and -not $_.Licence.FreeOnly })
    $rows = $needed.ToArray()      # @() around a generic list trips PowerShell 5.1's binder
    [pscustomobject]@{
        Needed        = $rows
        Packs         = [int](@($rows) | Measure-Object Packs -Sum).Sum
        Cores         = [int](@($rows) | Measure-Object Cores -Sum).Sum
        Waived        = [int](@($rows) | Measure-Object Waived -Sum).Sum
        PassivePacks  = [int](@($passive) | ForEach-Object { $_.Licence.Packs } | Measure-Object -Sum).Sum
        HostsLicensed = @($Hosts | Where-Object { -not $_.Licence.FreeOnly }).Count
        HostsFree     = @($Hosts | Where-Object { $_.Licence.FreeOnly }).Count
    }
}

function New-LicensingConnectionString([string] $Server, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = 'master'
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Get-SqlLicensingAudit'
    $b['TrustServerCertificate'] = $true
    if ($SqlCredential) {
        $b['User ID'] = $SqlCredential.UserName
        $b['Password'] = $SqlCredential.GetNetworkCredential().Password
    }
    else { $b['Integrated Security'] = $true }
    $b.ConnectionString
}

function Invoke-LicensingSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query)
    $connection = New-Object System.Data.SqlClient.SqlConnection (New-LicensingConnectionString $Server $ConnectTimeoutSeconds)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 60
        $table = New-Object System.Data.DataTable
        [void](New-Object System.Data.SqlClient.SqlDataAdapter $command).Fill($table)
        , $table
    }
    finally { $connection.Dispose() }
}

function Get-LicensingInstanceFacts {
    [CmdletBinding()]
    param([string] $Server)

    $columns = @((Invoke-LicensingSql -Server $Server -Query "SELECT name FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.dm_os_sys_info')").Rows |
                 ForEach-Object { [string]$_['name'] })
    function Col([string] $Name, [string] $Type) {
        if ($columns -contains $Name) { "si.$Name" } else { "CONVERT($Type, NULL)" }
    }

    $memory = if ($columns -contains 'physical_memory_kb') { 'si.physical_memory_kb / 1024' }
              elseif ($columns -contains 'physical_memory_in_bytes') { 'si.physical_memory_in_bytes / 1048576' }
              else { 'CONVERT(bigint, NULL)' }

    # SERVERPROPERTY('ProductUpdateLevel') only exists from 2012, and asking for it on older
    # versions returns NULL rather than failing - but only ask where it means something
    $version = [string]((Invoke-LicensingSql -Server $Server -Query "SELECT V = CONVERT(nvarchar(32), SERVERPROPERTY('ProductVersion'))").Rows[0]['V'])
    $major = 0
    if ($version -match '^(\d+)\.') { $major = [int]$Matches[1] }
    $update = if ($major -ge 11) { "CONVERT(nvarchar(32), SERVERPROPERTY('ProductUpdateLevel'))" } else { 'CONVERT(nvarchar(32), NULL)' }
    $hadr   = if ($major -ge 11) { "CONVERT(int, SERVERPROPERTY('IsHadrEnabled'))" } else { 'CONVERT(int, 0)' }

    $query = @"
SELECT  ServerName     = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')),
        HostName       = ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')),
                                CONVERT(nvarchar(128), SERVERPROPERTY('MachineName'))),
        InstanceName   = ISNULL(CONVERT(nvarchar(128), SERVERPROPERTY('InstanceName')), N'MSSQLSERVER'),
        Edition        = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
        EngineEdition  = CONVERT(int, SERVERPROPERTY('EngineEdition')),
        ProductVersion = CONVERT(nvarchar(32), SERVERPROPERTY('ProductVersion')),
        ProductLevel   = CONVERT(nvarchar(32), SERVERPROPERTY('ProductLevel')),
        ProductUpdate  = $update,
        IsClustered    = CONVERT(int, SERVERPROPERTY('IsClustered')),
        IsHadrEnabled  = $hadr,
        LicenseType    = CONVERT(nvarchar(32), SERVERPROPERTY('LicenseType')),
        CpuCount       = si.cpu_count,
        HyperthreadRatio = si.hyperthread_ratio,
        SocketCount    = $(Col 'socket_count' 'int'),
        CoresPerSocket = $(Col 'cores_per_socket' 'int'),
        VmType         = $(Col 'virtual_machine_type_desc' 'nvarchar(60)'),
        MemoryMb       = $memory,
        OnlineCores    = (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE' AND scheduler_id < 1048576),
        Databases      = (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4),
        BiggestDbGb    = (SELECT CONVERT(decimal(10,1), MAX(x.Gb)) FROM
                            (SELECT Gb = SUM(CONVERT(bigint, mf.size)) * 8.0 / 1048576
                             FROM sys.master_files mf WHERE mf.database_id > 4 AND mf.type = 0
                             GROUP BY mf.database_id) x),
        DataGb         = (SELECT CONVERT(decimal(12,1), SUM(CONVERT(bigint, size)) * 8.0 / 1048576) FROM sys.master_files WHERE database_id > 4),
        StartTime      = $(Col 'sqlserver_start_time' 'datetime')
FROM sys.dm_os_sys_info si;
"@
    (Invoke-LicensingSql -Server $Server -Query $query).Rows[0]
}

function Get-LicensingHostHardware {
    [CmdletBinding()]
    param([string] $HostName)

    $result = [pscustomobject]@{ Ok = $false; Sockets = 0; Cores = 0; Logical = 0; IsVirtual = $null; Error = $null }
    $processors = $null
    $system = $null
    try {
        $session = New-CimSession -ComputerName $HostName -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        try {
            $processors = @(Get-CimInstance -CimSession $session -ClassName Win32_Processor -ErrorAction Stop)
            $system = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystem -ErrorAction Stop
        }
        finally { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
    catch {
        $result.Error = ($_.Exception.Message -split "`r?`n")[0]
        try {
            $processors = @(Get-WmiObject -Class Win32_Processor -ComputerName $HostName -ErrorAction Stop)
            $system = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $HostName -ErrorAction Stop
            $result.Error = $null
        }
        catch { $result.Error = ($_.Exception.Message -split "`r?`n")[0]; return $result }
    }
    if (-not $processors -or $processors.Count -eq 0) { return $result }

    $result.Sockets = $processors.Count
    foreach ($cpu in $processors) {
        # NumberOfCores needs Windows Server 2008 or later; without it there is nothing to add
        if ($null -ne $cpu.NumberOfCores) { $result.Cores += [int]$cpu.NumberOfCores }
        if ($null -ne $cpu.NumberOfLogicalProcessors) { $result.Logical += [int]$cpu.NumberOfLogicalProcessors }
    }
    if ($system) {
        $text = '{0} {1}' -f $system.Manufacturer, $system.Model
        if ($text -match 'VMware|Virtual Machine|VirtualBox|KVM|Xen|Hyper-V|QEMU|Parallels|Google Compute|Amazon EC2|Microsoft Corporation Virtual') { $result.IsVirtual = $true }
        else { $result.IsVirtual = $false }
    }
    $result.Ok = ($result.Cores -gt 0)
    $result
}

function Get-LicensingHostComponents {
    [CmdletBinding()]
    param([string] $HostName)

    $found = New-Object System.Collections.Generic.List[object]
    $pattern = '^(MSSQL|SQLAgent|SQLSERVERAGENT|MSOLAP|MSSQLServerOLAPService|ReportServer|SQLServerReportingServices|PowerBIReportServer|MsDtsServer)'
    $services = $null
    $problem = $null

    # DCOM over RPC, because WinRM is off on plenty of database servers and Get-CimInstance
    # -ComputerName would quietly insist on it
    try {
        $session = New-CimSession -ComputerName $HostName -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        try { $services = Get-CimInstance -CimSession $session -ClassName Win32_Service -ErrorAction Stop }
        finally { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
    catch {
        $problem = ($_.Exception.Message -split "`r?`n")[0]
        try { $services = Get-WmiObject -Class Win32_Service -ComputerName $HostName -ErrorAction Stop; $problem = $null }
        catch { $problem = ($_.Exception.Message -split "`r?`n")[0] }
    }
    if ($null -eq $services) {
        return [pscustomobject]@{ Ok = $false; Components = @(); Error = $problem }
    }
    $services = @($services | Where-Object { $_.Name -match $pattern })

    foreach ($s in $services) {
        $kind = switch -Regex ($s.Name) {
            '^(MSSQLServerOLAPService|MSOLAP\$)'                 { 'Analysis Services' }
            '^(ReportServer|SQLServerReportingServices)'         { 'Reporting Services' }
            '^PowerBIReportServer'                               { 'Power BI Report Server' }
            '^MsDtsServer'                                       { 'Integration Services' }
            '^(MSSQLSERVER$|MSSQL\$)'                            { 'Database engine' }
            default                                              { $null }
        }
        if (-not $kind) { continue }
        $found.Add([pscustomobject]@{ Kind = $kind; Service = $s.Name; State = $s.State; StartMode = $s.StartMode })
    }
    [pscustomobject]@{ Ok = $true; Components = $found.ToArray(); Error = $null }
}

function Write-LicensingBadge([string] $Text, [string] $Colour) {
    Write-Host (' ' + $Text.PadRight(5) + ' ') -NoNewline -ForegroundColor Black -BackgroundColor $Colour
}

function Esc-LicensingHtml([string] $Text) {
    if ($null -eq $Text) { return '' }
    [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-LicensingPackPrice([string] $Edition) {
    if ($null -eq $CorePackPrice) { return $null }
    if ($CorePackPrice -is [hashtable]) {
        foreach ($k in $CorePackPrice.Keys) { if ([string]$k -eq $Edition) { return [decimal]$CorePackPrice[$k] } }
        return $null
    }
    [decimal]$CorePackPrice
}

function Format-LicensingMoney([decimal] $Amount) { '{0:n0}' -f $Amount }

function Add-LicensingTarget([string[]] $Values) {
    foreach ($value in $Values) {
        $pending = $null
        foreach ($part in ([string]$value).Split(',')) {
            $piece = $part.Trim()
            if (-not $piece) { continue }
            if ($pending -and $piece -match '^\d+$') { $pending = '{0},{1}' -f $pending, $piece; continue }
            if ($pending) { $script:targets.Add($pending) }
            $pending = $piece
        }
        if ($pending) { $script:targets.Add($pending) }
    }
}

function Get-LicensingOverride([string] $HostName) {
    if (-not $HardwareOverride) { return $null }
    foreach ($key in $HardwareOverride.Keys) {
        if ([string]$key -eq $HostName) { return [string]$HardwareOverride[$key] }
    }
    $null
}

Register-MhSelfTest -Name 'Get-MhSqlLicensingAudit' -Test {
    function Inst([hashtable] $o) {
        $d = @{ Instance = 'SQL01'; Host = 'SQL01'; Edition = 'Standard Edition (64-bit)'; EngineEdition = 2
                Sockets = 1; CoresPerSocket = 8; PhysicalCores = 8; LogicalCpus = 16; IsVirtual = $false; LooksPassive = $false }
        foreach ($k in $o.Keys) { $d[$k] = $o[$k] }
        $i = [pscustomobject]$d
        $i | Add-Member -NotePropertyName Facts -NotePropertyValue (Get-LicensingEditionFacts $i.Edition $i.EngineEdition)
        $i
    }

    Test-MhSection 'editions'
    $f = Get-LicensingEditionFacts 'Enterprise Edition: Core-based Licensing (64-bit)' 3
    Test-MhCheck 'Enterprise is licensable, per core only' ($f.Family -eq 'Enterprise' -and $f.Licensable -and $f.Models -join ',' -eq 'PerCore')
    $f = Get-LicensingEditionFacts 'Enterprise Developer Edition (64-bit)' 3
    Test-MhCheck 'Developer is free, however it spells itself' ($f.Family -eq 'Developer' -and -not $f.Licensable) $f.Family
    Test-MhCheck 'and says why that matters' ($f.Note -match 'production')
    $f = Get-LicensingEditionFacts 'Enterprise Evaluation Edition (64-bit)' 3
    Test-MhCheck 'Evaluation is free but temporary' ($f.Family -eq 'Evaluation' -and -not $f.Licensable -and $f.Note -match '180')
    $f = Get-LicensingEditionFacts 'Standard Edition (64-bit)' 2
    Test-MhCheck 'Standard can go either way' ($f.Family -eq 'Standard' -and $f.Models.Count -eq 2)
    Test-MhCheck 'and knows its 24 core ceiling' ($f.CoreCeiling -eq 24)
    $f = Get-LicensingEditionFacts 'Express Edition with Advanced Services (64-bit)' 4
    Test-MhCheck 'Express is free' ($f.Family -eq 'Express' -and -not $f.Licensable)
    $f = Get-LicensingEditionFacts 'Web Edition (64-bit)' 2
    Test-MhCheck 'Web is flagged as service-provider only' ($f.Family -eq 'Web' -and $f.Note -match 'SPLA')
    $f = Get-LicensingEditionFacts 'Business Intelligence Edition (64-bit)' 2
    Test-MhCheck 'Business Intelligence is Server + CAL only' ($f.Models -join ',' -eq 'ServerCal')
    $f = Get-LicensingEditionFacts 'SQL Azure' 5
    Test-MhCheck 'Azure SQL is not licensed this way at all' (-not $f.Licensable -and $f.Family -eq 'Azure')

    Test-MhSection 'hardware'
    # SQL Server 2012 and later say it outright
    $h = Get-LicensingHardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -HyperthreadRatio 20 -IsVirtual $false
    Test-MhCheck 'a modern instance is taken at its word' ($h.Sockets -eq 2 -and $h.PhysicalCores -eq 20 -and -not $h.Assumed)
    Test-MhCheck 'and the source is named' ($h.Source -eq 'SQL Server')

    # the 2008 R2 case: cpu_count / hyperthread_ratio is the SOCKET count, not cores per socket
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false
    Test-MhCheck '16 logical CPUs at a ratio of 4 is four sockets, not one' ($h.Sockets -eq 4) "sockets=$($h.Sockets)"
    Test-MhCheck 'and 16 cores, not 4' ($h.PhysicalCores -eq 16) "cores=$($h.PhysicalCores)"
    $c = Get-LicensingCoreLicences -Sockets $h.Sockets -PhysicalCores $h.PhysicalCores -LogicalCpus 16 -IsVirtual $false
    Test-MhCheck 'so that server needs 16 core licences in 8 packs' ($c.Cores -eq 16 -and $c.Packs -eq 8) "cores=$($c.Cores) packs=$($c.Packs)"
    Test-MhCheck 'the guess is admitted to' ($h.Assumed -and $h.Source -eq 'inferred')
    Test-MhCheck 'and on four sockets the answer holds either way' ($h.LowerBoundCores -eq 16 -and $h.Note -match 'either way')

    # one socket, hyperthreaded: here the answer really does depend on the hardware
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 16 -IsVirtual $false
    Test-MhCheck 'all 16 on one socket is one socket of 16' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 16)
    Test-MhCheck 'the lower bound is given when it matters' ($h.LowerBoundCores -eq 8 -and $h.Note -match 'as low as 8')
    Test-MhCheck 'and it says how to put it right' ($h.Note -match 'HardwareOverride')

    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 8 -HyperthreadRatio 8 -IsVirtual $false
    Test-MhCheck 'an eight way single socket box is 8 cores' ($h.PhysicalCores -eq 8 -and $h.Sockets -eq 1)

    # Windows knows, so Windows wins
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 `
                           -WindowsSockets 2 -WindowsCores 8 -WindowsLogical 16 -IsVirtual $false
    Test-MhCheck 'what Windows reports beats what is inferred' ($h.Sockets -eq 2 -and $h.PhysicalCores -eq 8 -and -not $h.Assumed)
    Test-MhCheck 'and that source is named too' ($h.Source -eq 'Windows')
    $h = Get-LicensingHardwareFacts -ReportedSockets 1 -ReportedCoresPerSocket 24 -LogicalCpus 48 `
                           -WindowsSockets 2 -WindowsCores 32 -WindowsLogical 64 -IsVirtual $false
    Test-MhCheck 'Windows also beats what SQL Server reports' ($h.PhysicalCores -eq 32 -and $h.Source -eq 'Windows')

    # Express and LocalDB report no socket count
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 8 -LogicalCpus 4 -HyperthreadRatio 8 -IsVirtual $false
    Test-MhCheck 'no socket count means one socket of what it did report' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 8 -and $h.Note -match 'one socket is assumed')

    # you always win
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false -Override '4x4' -HostName 'OLD01'
    Test-MhCheck 'an override of 4x4 is four sockets of four' ($h.Sockets -eq 4 -and $h.PhysicalCores -eq 16 -and $h.Source -eq 'you')
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false -Override '12'
    Test-MhCheck 'a bare override is one socket of that many' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 12)
    $h = Get-LicensingHardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -IsVirtual $false -Override '4x4'
    Test-MhCheck 'an override beats even a modern instance' ($h.PhysicalCores -eq 16 -and $h.Source -eq 'you')
    $h = Get-LicensingHardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -IsVirtual $false -Override 'lots'
    Test-MhCheck 'nonsense in the override is ignored and said out loud' ($h.PhysicalCores -eq 20 -and $h.Note -match 'not understood')
    $h = Get-LicensingHardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 2 -HyperthreadRatio 2 -IsVirtual $true -Override '8'
    Test-MhCheck 'an override on a VM sets its vCPUs' ($h.LogicalCpus -eq 8)

    Test-MhSection 'cores'
    $c = Get-LicensingCoreLicences -Sockets 2 -PhysicalCores 16 -LogicalCpus 32 -IsVirtual $false
    Test-MhCheck 'a two by eight physical box is 16 cores, 8 packs' ($c.Cores -eq 16 -and $c.Packs -eq 8)
    Test-MhCheck 'and hyperthreading does not change it' ($c.Cores -eq 16)
    $c = Get-LicensingCoreLicences -Sockets 2 -PhysicalCores 4 -LogicalCpus 8 -IsVirtual $false
    Test-MhCheck 'four physical cores over two sockets still needs 8 (minimum per socket)' ($c.Cores -eq 8 -and $c.Minimum)
    $c = Get-LicensingCoreLicences -Sockets 4 -PhysicalCores 8 -LogicalCpus 16 -IsVirtual $false
    Test-MhCheck 'eight cores over four sockets needs 16 (the minimum four times)' ($c.Cores -eq 16 -and $c.Packs -eq 8)
    $c = Get-LicensingCoreLicences -Sockets 1 -PhysicalCores 1 -LogicalCpus 2 -IsVirtual $false
    Test-MhCheck 'a single core box pays the minimum four' ($c.Cores -eq 4 -and $c.Packs -eq 2)
    $c = Get-LicensingCoreLicences -Sockets 1 -PhysicalCores 9 -LogicalCpus 18 -IsVirtual $false
    Test-MhCheck 'nine cores needs nine licences, bought as five packs' ($c.Cores -eq 9 -and $c.Packs -eq 5)
    $c = Get-LicensingCoreLicences -Sockets 1 -PhysicalCores 4 -LogicalCpus 8 -IsVirtual $true
    Test-MhCheck 'a VM is licensed on vCPUs, not the hardware underneath' ($c.Cores -eq 8 -and $c.Basis -eq '8 vCPU')
    $c = Get-LicensingCoreLicences -Sockets 1 -PhysicalCores 2 -LogicalCpus 2 -IsVirtual $true
    Test-MhCheck 'a two vCPU VM pays the minimum four' ($c.Cores -eq 4 -and $c.Minimum)
    $c = Get-LicensingCoreLicences -Sockets 1 -PhysicalCores 7 -LogicalCpus 7 -IsVirtual $true
    Test-MhCheck 'seven vCPUs is seven licences in four packs' ($c.Cores -eq 7 -and $c.Packs -eq 4)

    Test-MhSection 'versions'
    Test-MhCheck '15.0 is 2019' ((Get-LicensingProductName '15.0.4335.1') -eq 'SQL Server 2019')
    Test-MhCheck '16.0 is 2022' ((Get-LicensingProductName '16.0.4165.4') -eq 'SQL Server 2022')
    Test-MhCheck '17.0 is 2025' ((Get-LicensingProductName '17.0.1135.8') -eq 'SQL Server 2025')
    Test-MhCheck '10.50 is 2008 R2, not 2008' ((Get-LicensingProductName '10.50.6000.34') -eq 'SQL Server 2008 R2')
    Test-MhCheck 'an unknown build keeps its number' ((Get-LicensingProductName '19.0.1.1') -match '19\.0')

    Test-MhSection 'hosts'
    $h = Get-LicensingHostLicence -Instances @((Inst @{}), (Inst @{ Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3 }))
    Test-MhCheck 'the highest edition on a host licenses its cores' ($h.Edition -eq 'Enterprise' -and $h.Packs -eq 4)
    Test-MhCheck 'and covers the lower one, said out loud' (($h.Notes -join ' ') -match 'downgrade rights')
    $h = Get-LicensingHostLicence -Instances @((Inst @{}), (Inst @{}))
    Test-MhCheck 'two instances on one host are one set of licences' ($h.Packs -eq 4)
    $h = Get-LicensingHostLicence -Instances @((Inst @{ Edition = 'Express Edition (64-bit)'; EngineEdition = 4 }))
    Test-MhCheck 'an Express-only host needs nothing' ($h.FreeOnly -and $h.Packs -eq 0)
    $h = Get-LicensingHostLicence -Instances @((Inst @{ Edition = 'Enterprise Developer Edition (64-bit)'; EngineEdition = 3 }), (Inst @{}))
    Test-MhCheck 'Developer beside Standard does not add to the bill' ($h.Edition -eq 'Standard' -and $h.Packs -eq 4)
    $h = Get-LicensingHostLicence -Instances @((Inst @{ LooksPassive = $true }))
    Test-MhCheck 'a passive host is counted when there is no Software Assurance' ($h.Packs -eq 4 -and $h.Passive)
    Test-MhCheck 'and the saving is pointed out' (($h.Notes -join ' ') -match 'Software Assurance')
    $h = Get-LicensingHostLicence -Instances @((Inst @{ LooksPassive = $true })) -SoftwareAssurance
    Test-MhCheck 'with Software Assurance it drops out of the total' ($h.Packs -eq 0 -and $h.Waived -eq 4)
    $h = Get-LicensingHostLicence -Instances @((Inst @{ LooksPassive = $true }), (Inst @{ LooksPassive = $false })) -SoftwareAssurance
    Test-MhCheck 'a host with one active instance is not passive' ($h.Packs -eq 4 -and -not $h.Passive)
    $h = Get-LicensingHostLicence -Instances @((Inst @{ Sockets = 2; CoresPerSocket = 16; PhysicalCores = 32; LogicalCpus = 64 }))
    Test-MhCheck 'Standard on a 32 core box is called out as waste' (($h.Notes -join ' ') -match 'can only use 24')

    $o = Get-LicensingServerCalOption -Instances @((Inst @{}))
    Test-MhCheck 'Standard offers the Server + CAL alternative' ($null -ne $o -and $o.ServerLicences -eq 1)
    $o = Get-LicensingServerCalOption -Instances @((Inst @{}), (Inst @{ Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3 }))
    Test-MhCheck 'Enterprise on the host rules Server + CAL out' ($null -eq $o)
    $o = Get-LicensingServerCalOption -Instances @((Inst @{ Edition = 'Express Edition (64-bit)'; EngineEdition = 4 }))
    Test-MhCheck 'a free host has no Server + CAL option to offer' ($null -eq $o)

    Test-MhSection 'the total'
    function FakeHost([string] $Name, [object[]] $Instances, [switch] $Sa) {
        [pscustomobject]@{
            Host = $Name; Instances = $Instances
            Product = (@($Instances | Sort-Object { $_.Facts.Rank } | Select-Object -Last 1)[0]).Product
            Licence = (Get-LicensingHostLicence -Instances $Instances -SoftwareAssurance:$Sa)
            ServerCal = (Get-LicensingServerCalOption -Instances $Instances)
            IsVirtual = $Instances[0].IsVirtual
        }
    }
    $ee  = Inst @{ Host = 'A'; Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3; Sockets = 2; CoresPerSocket = 8; PhysicalCores = 16; LogicalCpus = 32; Product = 'SQL Server 2022' }
    $st  = Inst @{ Host = 'B'; IsVirtual = $true; LogicalCpus = 4; PhysicalCores = 4; Product = 'SQL Server 2022' }
    $pas = Inst @{ Host = 'C'; IsVirtual = $true; LogicalCpus = 4; PhysicalCores = 4; LooksPassive = $true; Product = 'SQL Server 2022' }
    $exp = Inst @{ Host = 'D'; Edition = 'Express Edition (64-bit)'; EngineEdition = 4; Product = 'SQL Server 2022' }
    $old = Inst @{ Host = 'E'; Sockets = 1; CoresPerSocket = 4; PhysicalCores = 4; LogicalCpus = 8; Product = 'SQL Server 2016' }

    $estate = @((FakeHost 'A' @($ee)), (FakeHost 'B' @($st)), (FakeHost 'C' @($pas)), (FakeHost 'D' @($exp)), (FakeHost 'E' @($old)))
    $t = Get-LicensingTotals -Hosts $estate
    Test-MhCheck 'a mixed estate totals its packs' ($t.Packs -eq 14) "packs=$($t.Packs)"
    Test-MhCheck 'and its core licences' ($t.Cores -eq 28) "cores=$($t.Cores)"
    Test-MhCheck 'the free host is left out of the total' ($t.HostsFree -eq 1 -and $t.HostsLicensed -eq 4)
    Test-MhCheck 'one row per product and edition' ($t.Needed.Count -eq 3) "rows=$($t.Needed.Count)"
    $enterprise = @($t.Needed | Where-Object { $_.Edition -eq 'Enterprise' })
    Test-MhCheck 'Enterprise is its own line' ($enterprise.Count -eq 1 -and $enterprise[0].Packs -eq 8)
    $standard22 = @($t.Needed | Where-Object { $_.Edition -eq 'Standard' -and $_.Product -eq 'SQL Server 2022' })
    Test-MhCheck 'the two Standard 2022 hosts share a line' ($standard22.Count -eq 1 -and $standard22[0].Hosts -eq 2 -and $standard22[0].Packs -eq 4)
    Test-MhCheck 'a different version is a different line' (@($t.Needed | Where-Object { $_.Product -eq 'SQL Server 2016' }).Count -eq 1)
    Test-MhCheck 'the passive packs are visible inside the total' ($t.PassivePacks -eq 2)

    $estateSa = @((FakeHost 'A' @($ee)), (FakeHost 'B' @($st)), (FakeHost 'C' @($pas) -Sa), (FakeHost 'D' @($exp)), (FakeHost 'E' @($old)))
    $t = Get-LicensingTotals -Hosts $estateSa
    Test-MhCheck 'Software Assurance takes the passive host out' ($t.Packs -eq 12) "packs=$($t.Packs)"
    Test-MhCheck 'and shows what it saved' ($t.Waived -eq 2)
    Test-MhCheck 'the waived cores leave the total too, so packs and cores agree' ($t.Cores -eq 24 -and $t.Cores -eq $t.Packs * 2) "cores=$($t.Cores) packs=$($t.Packs)"
    Test-MhCheck 'while the passive host still appears' (@($t.Needed | Where-Object { $_.Edition -eq 'Standard' -and $_.Product -eq 'SQL Server 2022' })[0].Hosts -eq 2)

    $t = Get-LicensingTotals -Hosts @((FakeHost 'D' @($exp)))
    Test-MhCheck 'an all-free estate needs nothing at all' ($t.Packs -eq 0 -and $t.Needed.Count -eq 0)

    Write-Host ''
    return
}
