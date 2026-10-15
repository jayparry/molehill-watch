#Requires -Version 5.1

<#
.SYNOPSIS
    Says how far behind on patches each SQL Server and the Windows under it is, against Microsoft's
    own build data.

.DESCRIPTION
    Molehill Data Services | Get-PatchStatus

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Get-MhPatchStatus). With the module imported you would call that directly;
    this exists because copying one script to a box is how this estate works.

    Reads the build of every SQL Server instance it can find on each machine, and the Windows
    update revision, then compares both with Microsoft's published build lists. Nothing is
    installed and nothing is changed.

    For SQL Server it works out which branch an instance is on - cumulative updates or the
    security-only GDR branch - and reports how far behind it is on that branch, because telling
    someone on GDR to apply a CU moves a server onto a branch nobody meant to be on.

    Needs the internet for the reference data, or -ReferenceFile for a copy saved earlier with
    -SaveReference, which is how this runs against servers with no route out.

    Exit code: 0 = nothing critical, 1 = something critical, 2 = could not start.

.PARAMETER ComputerName
    The machines to check. Also takes a pipeline. Defaults to this machine.

.PARAMETER ServerList
    A file of machine names, one per line. Blank lines and # comments are ignored.

.PARAMETER SqlCredential
    SQL authentication. Windows authentication is used when this is left out.

.PARAMETER ReferenceFile
    Microsoft's build data saved earlier, instead of fetching it. For a machine with no internet.

.PARAMETER SaveReference
    Fetch the build data and save it to this file, then stop.

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

.PARAMETER SelfTest
    Check the patch verdicts - how far behind counts as what - with no server and no internet.

.EXAMPLE
    .\Get-PatchStatus.ps1 -ComputerName SQL01, SQL02

.EXAMPLE
    # once, somewhere with internet
    .\Get-PatchStatus.ps1 -SaveReference .\builds.json
    # then, on the server that has none
    .\Get-PatchStatus.ps1 -ComputerName SQL01 -ReferenceFile .\builds.json

.NOTES
    Molehill Data Services. Read-only: catalogue views, the registry, and Microsoft's published
    build data.
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
    [Parameter(ParameterSetName = 'Check')] [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 10,
    [Parameter(ParameterSetName = 'Download', Mandatory)] [string] $SaveReference,
    [ValidateRange(2, 12)] [int] $Months = 3,
    [switch] $SelfTest
)

begin {
    $ErrorActionPreference = 'Stop'

    $manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
        Write-Host "  Looked for: $manifest" -ForegroundColor Gray
        Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Get-MhPatchStatus.' -ForegroundColor Gray
        exit 2
    }
    Import-Module $manifest -Force

    if ($SelfTest) {
        $results = Invoke-MhSelfTest -ModuleOnly -Name 'Get-MhPatchStatus'
        if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
        exit 0
    }

    $collected = New-Object System.Collections.Generic.List[string]
}
process {
    foreach ($one in $ComputerName) { if ($one) { $collected.Add($one.Trim()) } }
}
end {
    # -ComputerName is taken here as well as in process{}, because powershell.exe -File skips
    # process{} entirely: that is how this script used to accept a machine name, ignore it, and
    # audit the local machine instead without saying anything.
    foreach ($one in $ComputerName) {
        if ($one -and -not $collected.Contains($one.Trim())) { $collected.Add($one.Trim()) }
    }

    $arguments = @{ Months = $Months }
    if ($collected.Count) { $arguments['ComputerName'] = $collected.ToArray() }
    foreach ($name in 'ServerList', 'SqlCredential', 'ReferenceFile', 'SaveReference', 'OutputPath',
                      'CsvPath', 'Open', 'SqlGraceDays', 'SqlCuBehindCritical', 'WindowsGraceDays',
                      'ConnectTimeoutSeconds') {
        if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
    }

    $results = @(Get-MhPatchStatus @arguments)
    if (@($results | Where-Object { $_.Severity -eq 'Critical' }).Count) { exit 1 }
    exit 0
}
