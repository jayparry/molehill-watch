#Requires -Version 5.1

<#
.SYNOPSIS
    Licensing audit of a list of SQL Server instances: what is installed, what needs a licence, and
    the total you would have to buy to cover all of it.

.DESCRIPTION
    Molehill Data Services | Get-SqlLicensingAudit

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Get-MhSqlLicensingAudit). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    Point it at a list of instances and it produces the count you need before a licensing
    conversation - with a renewal, a reseller, or Microsoft. Nothing is installed and nothing is
    changed: it reads catalogue views, and WMI where it can.

    Every licensable product it can see is totalled into two-core packs, with the hosts grouped so
    that a VM and the box under it are not counted twice. Free editions are listed and never
    totalled. Where a price is given it is costed; where it is not, the pack count is the answer.

    Hardware facts come from the best source available, in this order: -HardwareOverride, then
    Windows itself, then SQL Server, then inference from what SQL Server does say. Which one was
    used is reported per host, because a core count inferred from a logical processor count is a
    lower bound rather than a fact.

    What it cannot know is what you already own: Software Assurance, agreement terms, licence
    mobility, packs on the shelf and CAL counts are not readable from a server. This is an
    inventory to inform a licensing conversation, not licensing advice.

    Exit code: 0 = nothing worth flagging, 1 = something was flagged, 2 = could not start.

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

.PARAMETER SelfTest
    Check the licensing reasoning - editions, cores, packs, hosts and totals - with no server at all.

.EXAMPLE
    .\Get-SqlLicensingAudit.ps1 -SqlInstance SQL01, SQL02\SALES

.EXAMPLE
    .\Get-SqlLicensingAudit.ps1 -ServerList .\servers.txt -SoftwareAssurance `
        -CorePackPrice @{ Enterprise = 12000; Standard = 3500 }

.NOTES
    Molehill Data Services. Read-only throughout.
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
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 10,
    [switch] $SelfTest
)

begin {
    $ErrorActionPreference = 'Stop'

    $manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
        Write-Host "  Looked for: $manifest" -ForegroundColor Gray
        Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Get-MhSqlLicensingAudit.' -ForegroundColor Gray
        exit 2
    }
    # not -Force: one shim calling another - the sample screen calls the export - would re-import
# the module underneath it and reset everything it holds, which is how a scripted run of the
# screen lost the keys it was being driven with halfway through
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

    if ($SelfTest) {
        $results = Invoke-MhSelfTest -ModuleOnly -Name 'Get-MhSqlLicensingAudit'
        if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
        exit 0
    }

    # the instances arrive down the pipeline one at a time and the audit wants them all at once
    $collected = New-Object System.Collections.Generic.List[string]
}
process {
    foreach ($instance in $SqlInstance) { if ($instance) { $collected.Add($instance.Trim()) } }
}
end {
    $arguments = @{ ConnectTimeoutSeconds = $ConnectTimeoutSeconds }
    if ($collected.Count) { $arguments['SqlInstance'] = $collected.ToArray() }
    foreach ($name in 'ServerList', 'SqlCredential', 'SoftwareAssurance', 'IncludeHostInventory',
                      'HardwareOverride', 'UserCount', 'CorePackPrice', 'ServerLicencePrice',
                      'CalPrice', 'OutputPath', 'CsvPath', 'NoHtml', 'Open') {
        if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
    }

    $audit = Get-MhSqlLicensingAudit @arguments
    if (-not $audit) { exit 2 }
    if (@($audit.Findings).Count) { exit 1 }
    exit 0
}
