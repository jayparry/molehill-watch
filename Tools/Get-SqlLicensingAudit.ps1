<#
.SYNOPSIS
    Licensing audit of a list of SQL Server instances: what is installed, what needs a licence, and
    the total you would have to buy to cover all of it.

.DESCRIPTION
    Point it at a list of instances and it produces the count you need before a licensing
    conversation - with a renewal, a reseller, or Microsoft. Nothing is installed and nothing is
    changed: it reads SERVERPROPERTY and a few DMVs, and optionally the Windows service list on each
    host to find the components that live outside the database engine.

    WHAT IT COUNTS, AND THE RULES IT APPLIES

      * Licences belong to an OS environment, not to an instance. Several instances on one server
        share one set of core licences, so instances are grouped by host before anything is totted up.
      * The processor numbers come from the best source available, and the report says which was
        used. SQL Server 2012 and later report sockets and cores per socket directly. Older versions
        report only logical CPUs and a hyperthread ratio - which give the socket count, but cannot
        say whether hyperthreading is on - so Windows is asked instead (one Win32_Processor row per
        socket, over RPC). If that cannot be reached, the count is inferred on the assumption that
        hyperthreading is off, which is the higher number and cannot leave you short, and the row
        says so and offers -HardwareOverride.
      * Physical server: every physical core is licensed, with a minimum of four per socket.
      * Virtual machine: every vCPU is licensed, with a minimum of four per VM.
      * Core licences are sold in two-core packs, so the pack count is rounded up.
      * The highest edition on a host sets the licence for that host's cores: Enterprise licences
        cover a Standard instance sitting beside them (downgrade rights), not the other way round.
      * Enterprise is core-based only from SQL Server 2012. Standard can be core-based or
        Server + CAL, so both are shown and you pick.
      * Free, and listed but never totalled: Express, Developer and Evaluation. Developer and
        Evaluation are flagged, because Developer in production is the single most common finding of
        a real audit and Evaluation stops working after 180 days.
      * A passive failover replica is free under Software Assurance - one per licensed primary. Those
        are counted by default and shown separately as "waived with Software Assurance" so you can
        see both numbers; -SoftwareAssurance takes them out of the total.
      * Reporting, Integration and Analysis Services on a host with no licensed engine need a SQL
        Server licence of their own for that host. That is what -IncludeHostInventory looks for.

    WHAT IT CANNOT KNOW, AND WILL SAY SO

      Your entitlements. Software Assurance, Enterprise Agreement terms, licence mobility, existing
      core packs, CAL counts and whether a Developer instance really is a development box are all
      things no server can tell you. This produces the demand side of the sum - what the estate needs
      - so you can put it next to what you own. It is an inventory, not legal advice.

    Exit code: 0 = audited, nothing to question, 1 = something to look at (Developer in production,
    Evaluation, Express at its ceiling, a server that could not be reached), 2 = nothing was audited.

.PARAMETER SqlInstance
    The instances to audit: SQL01, 'SQL02\SALES', 'SQL03,14330'. You are asked for them if neither
    this nor -ServerList is given.

.PARAMETER ServerList
    A text file of instances, one per line. Blank lines and lines starting with # are ignored.

.PARAMETER SqlCredential
    SQL Server authentication. Windows authentication is used when this is left out.

.PARAMETER SoftwareAssurance
    You have Software Assurance. Passive failover replicas are then taken out of the total instead of
    only being shown separately.

.PARAMETER HardwareOverride
    The real processor layout for a host, when you have looked it up yourself and want it used instead
    of anything discovered: @{ 'OLDSQL01' = '4x4'; 'OLDSQL02' = '16' }. '4x4' is four sockets of four
    cores, '16' is sixteen cores in one socket (or sixteen vCPUs on a VM). This always wins.

.PARAMETER IncludeHostInventory
    Also read the Windows service list on each host (CIM/WMI, needs RPC) to find Analysis Services,
    Reporting Services, Integration Services and Power BI Report Server. Worth it: those need
    licensing too and none of them can be seen from a SQL connection.

.PARAMETER UserCount
    How many users (or devices) you would buy CALs for, if you want the Server + CAL option costed.

.PARAMETER CorePackPrice
    What you pay for a two-core pack, per edition if you like: @{ Enterprise = 12000; Standard = 3200 }.
    A single number is taken as Enterprise and Standard alike. Money only appears if you give prices -
    nothing is assumed, because list prices go stale and yours are probably not list.

.PARAMETER ServerLicencePrice
    What you pay for one Standard server licence, for the Server + CAL comparison.

.PARAMETER CalPrice
    What you pay for one CAL.

.PARAMETER OutputPath
    Write the HTML report here. Default: SqlLicensing_<date>.html in the current folder. -NoHtml skips it.

.PARAMETER CsvPath
    Also write one row per instance to CSV.

.PARAMETER Open
    Open the HTML report when it is written.

.EXAMPLE
    .\Get-SqlLicensingAudit.ps1 -SqlInstance SQL01, SQL02, 'SQL03\SALES'

.EXAMPLE
    .\Get-SqlLicensingAudit.ps1 -ServerList .\servers.txt -IncludeHostInventory -SoftwareAssurance
    # the number to renew on, with SSAS/SSRS/SSIS hosts found and passive replicas taken out

.EXAMPLE
    .\Get-SqlLicensingAudit.ps1 -ServerList .\servers.txt -CorePackPrice @{ Enterprise = 12500; Standard = 3250 } -UserCount 40 -Open
    # the same with money on it, and the Server + CAL option priced against per core

.NOTES
    Molehill Data Services. Read-only. SQL Server 2012 or later reports everything used here; older
    instances are audited with what they do report and the assumption is written on the row.
#>
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
    [int] $ConnectTimeoutSeconds = 10,
    [switch] $SelfTest
)

begin {
    $ErrorActionPreference = 'Stop'
    $script:targets = New-Object System.Collections.Generic.List[string]
}
process {
    foreach ($t in $SqlInstance) { if ($t) { $script:targets.Add($t.Trim()) } }
}
end {

#==============================================================================
# The licensing rules. No SQL Server in here, so -SelfTest can check the sums.
#==============================================================================

<#
  What an edition string means for licensing. The string matters more than EngineEdition: Developer
  reports itself as "Enterprise Developer Edition", and a licensable Enterprise and a free Developer
  are both EngineEdition 3.
#>
function Get-EditionFacts {
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

<#
  Core licences for one OS environment.

  Physical: every physical core, minimum four per socket. Hyperthreading makes no difference.
  Virtual: every vCPU the VM can see, minimum four. Threads count, so a VM given 8 vCPUs on a
  hyperthreaded host is 8 licences, not 4.

  Two-core packs, so the pack count rounds up - an odd core count buys one core more than it needs.
#>
<#
  Works out what hardware a host actually has, from the best source available.

  In order of preference: what you told it (-HardwareOverride), what Windows says (one Win32_Processor
  row per socket, carrying physical and logical core counts), then what SQL Server says.

  SQL Server 2012 and later report socket_count and cores_per_socket directly. Before that there is
  only cpu_count and hyperthread_ratio, and the one thing those two reliably give is the SOCKET
  count: cpu_count / hyperthread_ratio. They cannot say whether hyperthreading is on, so they cannot
  give the physical core count. This assumes it is off, which counts the higher number - the one that
  cannot leave you short - and says so, with the lower bound in the note.
#>
function Get-HardwareFacts {
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

function Get-CoreLicences {
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

# 17.0.x -> SQL Server 2025. Anything newer than this script knows about keeps its version number.
function Get-SqlProductName {
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

<#
  One host's bill. Instances are already grouped by host; the highest licensable edition on the host
  licenses its cores, and anything free sitting on the same host rides along for nothing.
#>
function Get-HostLicence {
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
        $result.Basis = (Get-CoreLicences -Sockets $top.Sockets -PhysicalCores $top.PhysicalCores `
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

    $cores = Get-CoreLicences -Sockets $top.Sockets -PhysicalCores $top.PhysicalCores `
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

# the Server + CAL alternative for an eligible host, so the two can be put side by side
function Get-ServerCalOption {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Instances)

    $eligible = @($Instances | Where-Object { $_.Facts.Licensable -and $_.Facts.Models -contains 'ServerCal' })
    $blocked  = @($Instances | Where-Object { $_.Facts.Licensable -and $_.Facts.Models -notcontains 'ServerCal' })
    if ($eligible.Count -eq 0 -or $blocked.Count -gt 0) { return $null }
    [pscustomobject]@{ ServerLicences = 1; Edition = $eligible[0].Facts.Family }
}

<#
  Adds the hosts up into the thing you actually buy: a row per product and edition, with the core
  licences and two-core packs each needs, and what a passive replica is taking out of the total.
#>
function Get-LicenceTotals {
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

#==============================================================================
# Self test
#==============================================================================
if ($SelfTest) {
    $script:failed = 0
    function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    function Inst([hashtable] $o) {
        $d = @{ Instance = 'SQL01'; Host = 'SQL01'; Edition = 'Standard Edition (64-bit)'; EngineEdition = 2
                Sockets = 1; CoresPerSocket = 8; PhysicalCores = 8; LogicalCpus = 16; IsVirtual = $false; LooksPassive = $false }
        foreach ($k in $o.Keys) { $d[$k] = $o[$k] }
        $i = [pscustomobject]$d
        $i | Add-Member -NotePropertyName Facts -NotePropertyValue (Get-EditionFacts $i.Edition $i.EngineEdition)
        $i
    }

    Write-Host 'Get-SqlLicensingAudit self test'
    Write-Host '  editions' -ForegroundColor Gray
    $f = Get-EditionFacts 'Enterprise Edition: Core-based Licensing (64-bit)' 3
    Check 'Enterprise is licensable, per core only' ($f.Family -eq 'Enterprise' -and $f.Licensable -and $f.Models -join ',' -eq 'PerCore')
    $f = Get-EditionFacts 'Enterprise Developer Edition (64-bit)' 3
    Check 'Developer is free, however it spells itself' ($f.Family -eq 'Developer' -and -not $f.Licensable) $f.Family
    Check 'and says why that matters' ($f.Note -match 'production')
    $f = Get-EditionFacts 'Enterprise Evaluation Edition (64-bit)' 3
    Check 'Evaluation is free but temporary' ($f.Family -eq 'Evaluation' -and -not $f.Licensable -and $f.Note -match '180')
    $f = Get-EditionFacts 'Standard Edition (64-bit)' 2
    Check 'Standard can go either way' ($f.Family -eq 'Standard' -and $f.Models.Count -eq 2)
    Check 'and knows its 24 core ceiling' ($f.CoreCeiling -eq 24)
    $f = Get-EditionFacts 'Express Edition with Advanced Services (64-bit)' 4
    Check 'Express is free' ($f.Family -eq 'Express' -and -not $f.Licensable)
    $f = Get-EditionFacts 'Web Edition (64-bit)' 2
    Check 'Web is flagged as service-provider only' ($f.Family -eq 'Web' -and $f.Note -match 'SPLA')
    $f = Get-EditionFacts 'Business Intelligence Edition (64-bit)' 2
    Check 'Business Intelligence is Server + CAL only' ($f.Models -join ',' -eq 'ServerCal')
    $f = Get-EditionFacts 'SQL Azure' 5
    Check 'Azure SQL is not licensed this way at all' (-not $f.Licensable -and $f.Family -eq 'Azure')

    Write-Host '  hardware' -ForegroundColor Gray
    # SQL Server 2012 and later say it outright
    $h = Get-HardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -HyperthreadRatio 20 -IsVirtual $false
    Check 'a modern instance is taken at its word' ($h.Sockets -eq 2 -and $h.PhysicalCores -eq 20 -and -not $h.Assumed)
    Check 'and the source is named' ($h.Source -eq 'SQL Server')

    # the 2008 R2 case: cpu_count / hyperthread_ratio is the SOCKET count, not cores per socket
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false
    Check '16 logical CPUs at a ratio of 4 is four sockets, not one' ($h.Sockets -eq 4) "sockets=$($h.Sockets)"
    Check 'and 16 cores, not 4' ($h.PhysicalCores -eq 16) "cores=$($h.PhysicalCores)"
    $c = Get-CoreLicences -Sockets $h.Sockets -PhysicalCores $h.PhysicalCores -LogicalCpus 16 -IsVirtual $false
    Check 'so that server needs 16 core licences in 8 packs' ($c.Cores -eq 16 -and $c.Packs -eq 8) "cores=$($c.Cores) packs=$($c.Packs)"
    Check 'the guess is admitted to' ($h.Assumed -and $h.Source -eq 'inferred')
    Check 'and on four sockets the answer holds either way' ($h.LowerBoundCores -eq 16 -and $h.Note -match 'either way')

    # one socket, hyperthreaded: here the answer really does depend on the hardware
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 16 -IsVirtual $false
    Check 'all 16 on one socket is one socket of 16' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 16)
    Check 'the lower bound is given when it matters' ($h.LowerBoundCores -eq 8 -and $h.Note -match 'as low as 8')
    Check 'and it says how to put it right' ($h.Note -match 'HardwareOverride')

    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 8 -HyperthreadRatio 8 -IsVirtual $false
    Check 'an eight way single socket box is 8 cores' ($h.PhysicalCores -eq 8 -and $h.Sockets -eq 1)

    # Windows knows, so Windows wins
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 `
                           -WindowsSockets 2 -WindowsCores 8 -WindowsLogical 16 -IsVirtual $false
    Check 'what Windows reports beats what is inferred' ($h.Sockets -eq 2 -and $h.PhysicalCores -eq 8 -and -not $h.Assumed)
    Check 'and that source is named too' ($h.Source -eq 'Windows')
    $h = Get-HardwareFacts -ReportedSockets 1 -ReportedCoresPerSocket 24 -LogicalCpus 48 `
                           -WindowsSockets 2 -WindowsCores 32 -WindowsLogical 64 -IsVirtual $false
    Check 'Windows also beats what SQL Server reports' ($h.PhysicalCores -eq 32 -and $h.Source -eq 'Windows')

    # Express and LocalDB report no socket count
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 8 -LogicalCpus 4 -HyperthreadRatio 8 -IsVirtual $false
    Check 'no socket count means one socket of what it did report' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 8 -and $h.Note -match 'one socket is assumed')

    # you always win
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false -Override '4x4' -HostName 'OLD01'
    Check 'an override of 4x4 is four sockets of four' ($h.Sockets -eq 4 -and $h.PhysicalCores -eq 16 -and $h.Source -eq 'you')
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 16 -HyperthreadRatio 4 -IsVirtual $false -Override '12'
    Check 'a bare override is one socket of that many' ($h.Sockets -eq 1 -and $h.PhysicalCores -eq 12)
    $h = Get-HardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -IsVirtual $false -Override '4x4'
    Check 'an override beats even a modern instance' ($h.PhysicalCores -eq 16 -and $h.Source -eq 'you')
    $h = Get-HardwareFacts -ReportedSockets 2 -ReportedCoresPerSocket 10 -LogicalCpus 40 -IsVirtual $false -Override 'lots'
    Check 'nonsense in the override is ignored and said out loud' ($h.PhysicalCores -eq 20 -and $h.Note -match 'not understood')
    $h = Get-HardwareFacts -ReportedSockets 0 -ReportedCoresPerSocket 0 -LogicalCpus 2 -HyperthreadRatio 2 -IsVirtual $true -Override '8'
    Check 'an override on a VM sets its vCPUs' ($h.LogicalCpus -eq 8)

    Write-Host '  cores' -ForegroundColor Gray
    $c = Get-CoreLicences -Sockets 2 -PhysicalCores 16 -LogicalCpus 32 -IsVirtual $false
    Check 'a two by eight physical box is 16 cores, 8 packs' ($c.Cores -eq 16 -and $c.Packs -eq 8)
    Check 'and hyperthreading does not change it' ($c.Cores -eq 16)
    $c = Get-CoreLicences -Sockets 2 -PhysicalCores 4 -LogicalCpus 8 -IsVirtual $false
    Check 'four physical cores over two sockets still needs 8 (minimum per socket)' ($c.Cores -eq 8 -and $c.Minimum)
    $c = Get-CoreLicences -Sockets 4 -PhysicalCores 8 -LogicalCpus 16 -IsVirtual $false
    Check 'eight cores over four sockets needs 16 (the minimum four times)' ($c.Cores -eq 16 -and $c.Packs -eq 8)
    $c = Get-CoreLicences -Sockets 1 -PhysicalCores 1 -LogicalCpus 2 -IsVirtual $false
    Check 'a single core box pays the minimum four' ($c.Cores -eq 4 -and $c.Packs -eq 2)
    $c = Get-CoreLicences -Sockets 1 -PhysicalCores 9 -LogicalCpus 18 -IsVirtual $false
    Check 'nine cores needs nine licences, bought as five packs' ($c.Cores -eq 9 -and $c.Packs -eq 5)
    $c = Get-CoreLicences -Sockets 1 -PhysicalCores 4 -LogicalCpus 8 -IsVirtual $true
    Check 'a VM is licensed on vCPUs, not the hardware underneath' ($c.Cores -eq 8 -and $c.Basis -eq '8 vCPU')
    $c = Get-CoreLicences -Sockets 1 -PhysicalCores 2 -LogicalCpus 2 -IsVirtual $true
    Check 'a two vCPU VM pays the minimum four' ($c.Cores -eq 4 -and $c.Minimum)
    $c = Get-CoreLicences -Sockets 1 -PhysicalCores 7 -LogicalCpus 7 -IsVirtual $true
    Check 'seven vCPUs is seven licences in four packs' ($c.Cores -eq 7 -and $c.Packs -eq 4)

    Write-Host '  versions' -ForegroundColor Gray
    Check '15.0 is 2019' ((Get-SqlProductName '15.0.4335.1') -eq 'SQL Server 2019')
    Check '16.0 is 2022' ((Get-SqlProductName '16.0.4165.4') -eq 'SQL Server 2022')
    Check '17.0 is 2025' ((Get-SqlProductName '17.0.1135.8') -eq 'SQL Server 2025')
    Check '10.50 is 2008 R2, not 2008' ((Get-SqlProductName '10.50.6000.34') -eq 'SQL Server 2008 R2')
    Check 'an unknown build keeps its number' ((Get-SqlProductName '19.0.1.1') -match '19\.0')

    Write-Host '  hosts' -ForegroundColor Gray
    $h = Get-HostLicence -Instances @((Inst @{}), (Inst @{ Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3 }))
    Check 'the highest edition on a host licenses its cores' ($h.Edition -eq 'Enterprise' -and $h.Packs -eq 4)
    Check 'and covers the lower one, said out loud' (($h.Notes -join ' ') -match 'downgrade rights')
    $h = Get-HostLicence -Instances @((Inst @{}), (Inst @{}))
    Check 'two instances on one host are one set of licences' ($h.Packs -eq 4)
    $h = Get-HostLicence -Instances @((Inst @{ Edition = 'Express Edition (64-bit)'; EngineEdition = 4 }))
    Check 'an Express-only host needs nothing' ($h.FreeOnly -and $h.Packs -eq 0)
    $h = Get-HostLicence -Instances @((Inst @{ Edition = 'Enterprise Developer Edition (64-bit)'; EngineEdition = 3 }), (Inst @{}))
    Check 'Developer beside Standard does not add to the bill' ($h.Edition -eq 'Standard' -and $h.Packs -eq 4)
    $h = Get-HostLicence -Instances @((Inst @{ LooksPassive = $true }))
    Check 'a passive host is counted when there is no Software Assurance' ($h.Packs -eq 4 -and $h.Passive)
    Check 'and the saving is pointed out' (($h.Notes -join ' ') -match 'Software Assurance')
    $h = Get-HostLicence -Instances @((Inst @{ LooksPassive = $true })) -SoftwareAssurance
    Check 'with Software Assurance it drops out of the total' ($h.Packs -eq 0 -and $h.Waived -eq 4)
    $h = Get-HostLicence -Instances @((Inst @{ LooksPassive = $true }), (Inst @{ LooksPassive = $false })) -SoftwareAssurance
    Check 'a host with one active instance is not passive' ($h.Packs -eq 4 -and -not $h.Passive)
    $h = Get-HostLicence -Instances @((Inst @{ Sockets = 2; CoresPerSocket = 16; PhysicalCores = 32; LogicalCpus = 64 }))
    Check 'Standard on a 32 core box is called out as waste' (($h.Notes -join ' ') -match 'can only use 24')

    $o = Get-ServerCalOption -Instances @((Inst @{}))
    Check 'Standard offers the Server + CAL alternative' ($null -ne $o -and $o.ServerLicences -eq 1)
    $o = Get-ServerCalOption -Instances @((Inst @{}), (Inst @{ Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3 }))
    Check 'Enterprise on the host rules Server + CAL out' ($null -eq $o)
    $o = Get-ServerCalOption -Instances @((Inst @{ Edition = 'Express Edition (64-bit)'; EngineEdition = 4 }))
    Check 'a free host has no Server + CAL option to offer' ($null -eq $o)

    Write-Host '  the total' -ForegroundColor Gray
    function FakeHost([string] $Name, [object[]] $Instances, [switch] $Sa) {
        [pscustomobject]@{
            Host = $Name; Instances = $Instances
            Product = (@($Instances | Sort-Object { $_.Facts.Rank } | Select-Object -Last 1)[0]).Product
            Licence = (Get-HostLicence -Instances $Instances -SoftwareAssurance:$Sa)
            ServerCal = (Get-ServerCalOption -Instances $Instances)
            IsVirtual = $Instances[0].IsVirtual
        }
    }
    $ee  = Inst @{ Host = 'A'; Edition = 'Enterprise Edition: Core-based Licensing (64-bit)'; EngineEdition = 3; Sockets = 2; CoresPerSocket = 8; PhysicalCores = 16; LogicalCpus = 32; Product = 'SQL Server 2022' }
    $st  = Inst @{ Host = 'B'; IsVirtual = $true; LogicalCpus = 4; PhysicalCores = 4; Product = 'SQL Server 2022' }
    $pas = Inst @{ Host = 'C'; IsVirtual = $true; LogicalCpus = 4; PhysicalCores = 4; LooksPassive = $true; Product = 'SQL Server 2022' }
    $exp = Inst @{ Host = 'D'; Edition = 'Express Edition (64-bit)'; EngineEdition = 4; Product = 'SQL Server 2022' }
    $old = Inst @{ Host = 'E'; Sockets = 1; CoresPerSocket = 4; PhysicalCores = 4; LogicalCpus = 8; Product = 'SQL Server 2016' }

    $estate = @((FakeHost 'A' @($ee)), (FakeHost 'B' @($st)), (FakeHost 'C' @($pas)), (FakeHost 'D' @($exp)), (FakeHost 'E' @($old)))
    $t = Get-LicenceTotals -Hosts $estate
    Check 'a mixed estate totals its packs' ($t.Packs -eq 14) "packs=$($t.Packs)"
    Check 'and its core licences' ($t.Cores -eq 28) "cores=$($t.Cores)"
    Check 'the free host is left out of the total' ($t.HostsFree -eq 1 -and $t.HostsLicensed -eq 4)
    Check 'one row per product and edition' ($t.Needed.Count -eq 3) "rows=$($t.Needed.Count)"
    $enterprise = @($t.Needed | Where-Object { $_.Edition -eq 'Enterprise' })
    Check 'Enterprise is its own line' ($enterprise.Count -eq 1 -and $enterprise[0].Packs -eq 8)
    $standard22 = @($t.Needed | Where-Object { $_.Edition -eq 'Standard' -and $_.Product -eq 'SQL Server 2022' })
    Check 'the two Standard 2022 hosts share a line' ($standard22.Count -eq 1 -and $standard22[0].Hosts -eq 2 -and $standard22[0].Packs -eq 4)
    Check 'a different version is a different line' (@($t.Needed | Where-Object { $_.Product -eq 'SQL Server 2016' }).Count -eq 1)
    Check 'the passive packs are visible inside the total' ($t.PassivePacks -eq 2)

    $estateSa = @((FakeHost 'A' @($ee)), (FakeHost 'B' @($st)), (FakeHost 'C' @($pas) -Sa), (FakeHost 'D' @($exp)), (FakeHost 'E' @($old)))
    $t = Get-LicenceTotals -Hosts $estateSa
    Check 'Software Assurance takes the passive host out' ($t.Packs -eq 12) "packs=$($t.Packs)"
    Check 'and shows what it saved' ($t.Waived -eq 2)
    Check 'the waived cores leave the total too, so packs and cores agree' ($t.Cores -eq 24 -and $t.Cores -eq $t.Packs * 2) "cores=$($t.Cores) packs=$($t.Packs)"
    Check 'while the passive host still appears' (@($t.Needed | Where-Object { $_.Edition -eq 'Standard' -and $_.Product -eq 'SQL Server 2022' })[0].Hosts -eq 2)

    $t = Get-LicenceTotals -Hosts @((FakeHost 'D' @($exp)))
    Check 'an all-free estate needs nothing at all' ($t.Packs -eq 0 -and $t.Needed.Count -eq 0)

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Collecting the facts
#==============================================================================
function New-ConnectionString([string] $Server, [int] $Timeout) {
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

function Invoke-Sql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query)
    $connection = New-Object System.Data.SqlClient.SqlConnection (New-ConnectionString $Server $ConnectTimeoutSeconds)
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

<#
  The hardware and version facts, asked for in a way that works on every version.

  sys.dm_os_sys_info has gained and renamed columns over the years - socket_count and
  cores_per_socket arrived in 2012, physical_memory_kb replaced physical_memory_in_bytes - so the
  column list is read first and the SELECT is built from what is actually there. That beats running
  a modern query, catching the error and falling back to a cut-down one, which is how a 2008 R2
  server quietly lost its virtual machine flag and its memory.
#>
function Get-InstanceFacts {
    [CmdletBinding()]
    param([string] $Server)

    $columns = @((Invoke-Sql -Server $Server -Query "SELECT name FROM sys.all_columns WHERE object_id = OBJECT_ID('sys.dm_os_sys_info')").Rows |
                 ForEach-Object { [string]$_['name'] })
    function Col([string] $Name, [string] $Type) {
        if ($columns -contains $Name) { "si.$Name" } else { "CONVERT($Type, NULL)" }
    }

    $memory = if ($columns -contains 'physical_memory_kb') { 'si.physical_memory_kb / 1024' }
              elseif ($columns -contains 'physical_memory_in_bytes') { 'si.physical_memory_in_bytes / 1048576' }
              else { 'CONVERT(bigint, NULL)' }

    # SERVERPROPERTY('ProductUpdateLevel') only exists from 2012, and asking for it on older
    # versions returns NULL rather than failing - but only ask where it means something
    $version = [string]((Invoke-Sql -Server $Server -Query "SELECT V = CONVERT(nvarchar(32), SERVERPROPERTY('ProductVersion'))").Rows[0]['V'])
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
    (Invoke-Sql -Server $Server -Query $query).Rows[0]
}

# anything on the engine that points at a licensable component living beside it
$ComponentQuery = @"
SELECT  HasSsisCatalog   = CONVERT(bit, CASE WHEN DB_ID('SSISDB') IS NOT NULL THEN 1 ELSE 0 END),
        HasReportServer  = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'ReportServer%') THEN 1 ELSE 0 END),
        HasPowerBiRs     = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'PowerBIReportServer%') THEN 1 ELSE 0 END),
        HasMds           = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'MDS%') THEN 1 ELSE 0 END),
        HasDqs           = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE 'DQS%') THEN 1 ELSE 0 END);
"@

$HadrQuery = @"
SELECT  Role          = rs.role_desc,
        AllowReads    = ar.secondary_role_allow_connections_desc,
        BackupPref    = ag.automated_backup_preference_desc,
        AgName        = ag.name
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE rs.is_local = 1;
"@

# a machine whose user databases are all mid-restore is almost always a log shipping secondary
$StandbyQuery = @"
SELECT  UserDbs   = COUNT(*),
        Restoring = SUM(CASE WHEN state_desc IN ('RESTORING', 'OFFLINE') OR is_in_standby = 1 THEN 1 ELSE 0 END)
FROM sys.databases WHERE database_id > 4;
"@

$MirrorQuery = @"
SELECT Mirrors = COUNT(*) FROM sys.database_mirroring WHERE mirroring_role = 2;
"@

$ClusterQuery = @"
SELECT NodeName = NodeName, Status = status_description FROM sys.dm_os_cluster_nodes;
"@

<#
  What Windows says the processors are: one Win32_Processor row per socket, each carrying its
  physical and logical core counts. This is the only way to be certain on SQL Server 2008 R2 and
  older, which do not report cores per socket at all - and it also answers whether the machine is
  virtual, which those versions may not either.
#>
function Get-HostHardware {
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

<#
  The Windows service list for a host. SSAS, SSRS, SSIS and Power BI Report Server cannot be seen
  from a SQL connection at all, and each of them needs the host licensed, so an audit that skips
  them undercounts. Needs RPC to the host, and quietly gives up when it is not there.
#>
function Get-HostComponents {
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

#==============================================================================
# Reporting helpers
#==============================================================================
function Write-Badge([string] $Text, [string] $Colour) {
    Write-Host (' ' + $Text.PadRight(5) + ' ') -NoNewline -ForegroundColor Black -BackgroundColor $Colour
}
function Esc-Html([string] $Text) {
    if ($null -eq $Text) { return '' }
    [System.Net.WebUtility]::HtmlEncode($Text)
}
function Get-PackPrice([string] $Edition) {
    if ($null -eq $CorePackPrice) { return $null }
    if ($CorePackPrice -is [hashtable]) {
        foreach ($k in $CorePackPrice.Keys) { if ([string]$k -eq $Edition) { return [decimal]$CorePackPrice[$k] } }
        return $null
    }
    [decimal]$CorePackPrice
}
function Format-Money([decimal] $Amount) { '{0:n0}' -f $Amount }

#==============================================================================
# What are we auditing?
#==============================================================================
<#
  Takes instances out of whatever was typed. A comma means "and the next one", except when what
  follows it is only digits, because SQL04,14330 is one instance on a port and not two servers.
#>
function Add-Targets([string[]] $Values) {
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

# powershell.exe -File runs no pipeline at all, so the process block above never fires and the
# parameter has to be picked up here. Scheduled tasks are usually -File, so this is not a corner case.
if ($script:targets.Count -eq 0 -and $SqlInstance) { Add-Targets $SqlInstance }

if ($ServerList) {
    if (-not (Test-Path -LiteralPath $ServerList)) { Write-Host "  No such list: $ServerList" -ForegroundColor Red; exit 2 }
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
    elseif ($answer) { Add-Targets $answer }
}
if ($script:targets.Count -eq 0) { Write-Host '  Nothing to audit.' -ForegroundColor Yellow; exit 2 }

$runAt = Get-Date
Write-Host ''
Write-Host '  SQL Server licensing audit  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
Write-Host ("  {0} instance(s)   {1}" -f $script:targets.Count, $runAt.ToString('ddd dd MMM yyyy HH:mm'))
Write-Host ''

$instances = New-Object System.Collections.Generic.List[object]
$unreachable = New-Object System.Collections.Generic.List[object]
$hostInventory = @{}
$hostHardware = @{}

function Get-Override([string] $HostName) {
    if (-not $HardwareOverride) { return $null }
    foreach ($key in $HardwareOverride.Keys) {
        if ([string]$key -eq $HostName) { return [string]$HardwareOverride[$key] }
    }
    $null
}

foreach ($target in ($script:targets | Select-Object -Unique)) {
    try {
        $row = Get-InstanceFacts -Server $target

        $edition = [string]$row['Edition']
        $facts = Get-EditionFacts $edition ([int]$row['EngineEdition'])
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
        if (($reportedPerSocket -le 0 -or $IncludeHostInventory) -and -not (Get-Override $hostName)) {
            if (-not $hostHardware.ContainsKey($hostName)) { $hostHardware[$hostName] = Get-HostHardware -HostName $hostName }
            if ($hostHardware[$hostName].Ok) { $windows = $hostHardware[$hostName] }
        }

        $hw = Get-HardwareFacts -ReportedSockets $reportedSockets -ReportedCoresPerSocket $reportedPerSocket `
                                -LogicalCpus $logical -HyperthreadRatio ([int]$row['HyperthreadRatio']) -IsVirtual $isVirtual `
                                -WindowsSockets $(if ($windows) { $windows.Sockets } else { 0 }) `
                                -WindowsCores $(if ($windows) { $windows.Cores } else { 0 }) `
                                -WindowsLogical $(if ($windows) { $windows.Logical } else { 0 }) `
                                -Override (Get-Override $hostName) -HostName $hostName
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
                $hadr = Invoke-Sql -Server $target -Query $HadrQuery
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
                $sb = (Invoke-Sql -Server $target -Query $StandbyQuery).Rows[0]
                if ([int]$sb['UserDbs'] -gt 0 -and [int]$sb['UserDbs'] -eq [int]$sb['Restoring']) {
                    $looksPassive = $true
                    $notes.Add('every user database here is mid-restore, which looks like a log shipping or manual standby secondary')
                }
            }
            catch { }
            try {
                $mirror = (Invoke-Sql -Server $target -Query $MirrorQuery).Rows[0]
                if ([int]$mirror['Mirrors'] -gt 0) { $looksPassive = $true; $notes.Add('this is a database mirroring partner') }
            }
            catch { }
        }

        # components living on the same engine
        $components = New-Object System.Collections.Generic.List[string]
        try {
            $c = (Invoke-Sql -Server $target -Query $ComponentQuery).Rows[0]
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
            Product       = Get-SqlProductName ([string]$row['ProductVersion'])
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

        Write-Badge 'OK' 'Green'
        Write-Host ("  {0,-28} {1} {2}" -f $instance.Instance, $instance.Product, $facts.Family) -NoNewline
        Write-Host ("   {0}, {1}{2}" -f $(if ($isVirtual) { 'VM' } else { 'physical' }),
                    $(if ($isVirtual) { "$logical vCPU" } else { "$sockets socket(s), $physicalCores cores" }),
                    $(if ($hw.Source -eq 'inferred') { ' (inferred)' } elseif ($hw.Source -ne 'SQL Server') { " (from $($hw.Source))" } else { '' })) -ForegroundColor DarkGray
    }
    catch {
        $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
        $unreachable.Add([pscustomobject]@{ Target = $target; Error = $message })
        Write-Badge 'MISS' 'Red'
        Write-Host ("  {0,-28} {1}" -f $target, $message)
    }
}

# clustered instances: the other nodes matter for licensing, so name them
foreach ($i in @($instances | Where-Object { $_.Clustered })) {
    try {
        $nodes = Invoke-Sql -Server $i.Target -Query $ClusterQuery
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
        $inv = Get-HostComponents -HostName $hostName
        $hostInventory[$hostName] = $inv
        if (-not $inv.Ok) {
            Write-Badge 'HOST' 'Yellow'
            Write-Host ("  {0,-28} could not read the service list ({1}). Analysis, Reporting and Integration Services on this host will be missed." -f $hostName, $inv.Error)
            continue
        }
        $extra = @($inv.Components | Where-Object { $_.Kind -ne 'Database engine' })
        if ($extra.Count) {
            Write-Badge 'HOST' 'Cyan'
            Write-Host ("  {0,-28} also runs {1}" -f $hostName, (($extra | ForEach-Object { '{0} ({1})' -f $_.Kind, $_.State.ToLower() }) -join ', '))
        }
    }
}

if ($instances.Count -eq 0) {
    Write-Host ''
    Write-Host '  Nothing could be audited.' -ForegroundColor Red
    Write-Host ''
    exit 2
}

#==============================================================================
# One host at a time, then the bill
#==============================================================================
$hosts = New-Object System.Collections.Generic.List[object]
foreach ($group in ($instances | Group-Object Host)) {
    $onHost = @($group.Group)
    $licence = Get-HostLicence -Instances $onHost -SoftwareAssurance:$SoftwareAssurance
    $serverCal = Get-ServerCalOption -Instances $onHost
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

# components found on a host whose engine is free or absent still need that host licensed
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

#==============================================================================
# Licences needed
#==============================================================================
$totals = Get-LicenceTotals -Hosts $hosts.ToArray()
$needed = New-Object System.Collections.Generic.List[object]
foreach ($n in $totals.Needed) {
    $n | Add-Member -NotePropertyName Price -NotePropertyValue (Get-PackPrice $n.Edition)
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
    if ($null -ne $n.Price) { $c = $n.Price * $n.Packs; $totalCost += $c; $cost = Format-Money $c }
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
            $(if ($totalCost -gt 0) { ' - ' + (Format-Money $totalCost) + $(if (-not $pricedAll) { ' (part priced)' } else { '' }) } else { '' }))

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

# the Server + CAL alternative, where it is allowed
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
        $corePrice = Get-PackPrice 'Standard'
        $coreCost = if ($null -ne $corePrice) { $corePrice * $calPacks } else { $null }
        Write-Host ("    {0} users: {1} as Server + CAL{2}" -f $UserCount, (Format-Money $calCost),
                    $(if ($null -ne $coreCost) { ' against ' + (Format-Money $coreCost) + ' per core - ' +
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

#==============================================================================
# Things to look at
#==============================================================================
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

#==============================================================================
# CSV and HTML
#==============================================================================
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
$(if ($totalCost -gt 0) { "<div class=`"card`"><b>$(Format-Money $totalCost)</b>estimated cost</div>" } else { '' })
</div>
<h2>Licences needed</h2>
<table><tr><th>Product</th><th>Edition</th><th>Model</th><th class="num">Hosts</th><th class="num">Core licences</th><th class="num">2-core packs</th>$(if ($totalCost -gt 0) { '<th class="num">Cost</th>' } else { '' })</tr>
"@

    foreach ($n in ($needed | Sort-Object Product, Edition)) {
        $cost = if ($null -ne $n.Price) { Format-Money ($n.Price * $n.Packs) } else { '-' }
        & $add ("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=`"num`">{3}</td><td class=`"num`">{4}</td><td class=`"num`">{5}</td>{6}</tr>" -f
                (Esc-Html $n.Product), (Esc-Html $n.Edition), $n.Model, $n.Hosts, $n.Cores, $n.Packs,
                $(if ($totalCost -gt 0) { "<td class=`"num`">$cost</td>" } else { '' }))
    }
    & $add ("<tr class=`"total`"><td colspan=`"5`">Total to cover everything in this list</td><td class=`"num`">{0}</td>{1}</tr>" -f
            $totalPacks, $(if ($totalCost -gt 0) { "<td class=`"num`">$(Format-Money $totalCost)</td>" } else { '' }))
    & $add '</table>'

    if ($waivedTotal -gt 0) { & $add ("<p class=`"sub`">{0} pack(s) for passive failover replicas are left out, as Software Assurance covers them.</p>" -f $waivedTotal) }
    if ($calHosts.Count) {
        & $add ("<p class=`"sub`">Server + CAL alternative: {0} Standard server licence(s) for {1}, plus a CAL per user or device, in place of {2} two-core pack(s).</p>" -f
                $calHosts.Count, (Esc-Html (($calHosts | ForEach-Object { $_.Host }) -join ', ')),
                ($calHosts | ForEach-Object { $_.Licence.Packs } | Measure-Object -Sum).Sum)
    }

    & $add '<h2>Hosts</h2><table><tr><th>Host</th><th>Instances</th><th>Hardware</th><th>Edition licensed</th><th class="num">Cores</th><th class="num">Packs</th></tr>'
    foreach ($h in ($hosts | Sort-Object { -$_.Licence.Packs }, Host)) {
        $l = $h.Licence
        $class = if ($l.FreeOnly) { ' class="free"' } elseif ($l.Passive) { ' class="warn"' } else { '' }
        $notes = @($l.Notes) + @($h.Instances | ForEach-Object { $i = $_; $i.Notes | ForEach-Object { '{0}: {1}' -f $i.InstanceName, $_ } }) +
                 @($h.Instances | ForEach-Object { $i = $_; $i.Components | ForEach-Object { '{0}: {1}' -f $i.InstanceName, $_ } })
        $noteHtml = if (@($notes).Count) { '<ul class="notes">' + ((@($notes) | ForEach-Object { '<li>' + (Esc-Html $_) + '</li>' }) -join '') + '</ul>' } else { '' }
        & $add ("<tr$class><td>{0}{1}</td><td>{2}<div class=`"sub`">{3}</div></td><td>{4}<div class=`"sub`">{5}</div></td><td>{6}</td><td class=`"num`">{7}</td><td class=`"num`">{8}</td></tr>" -f
                (Esc-Html $h.Host), $noteHtml,
                (Esc-Html ((@($h.Instances | ForEach-Object { $_.InstanceName }) -join ', '))),
                (Esc-Html ((@($h.Instances | ForEach-Object { $_.Role }) | Select-Object -Unique) -join '; ')),
                $(if ($h.IsVirtual) { 'virtual machine' } else { 'physical' }), (Esc-Html $l.Basis),
                (Esc-Html (@($h.Product, $l.Edition) -join ' ')),
                $(if ($l.FreeOnly) { '-' } else { $l.Cores }), $(if ($l.FreeOnly) { '-' } else { $l.Packs }))
    }
    & $add '</table>'

    if ($findings.Count) {
        & $add '<h2>Worth a look</h2><table><tr><th>Where</th><th>What</th></tr>'
        foreach ($f in $findings) { & $add ("<tr class=`"warn`"><td>{0}</td><td>{1}</td></tr>" -f (Esc-Html $f.Instance), (Esc-Html $f.What)) }
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

if ($findings.Count) { exit 1 }
exit 0
}
