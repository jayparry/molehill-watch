#Requires -Version 5.1

<#
.SYNOPSIS
    Checks every database on an instance and says plainly whether it is available: green for pass,
    red for fail, with the reason.

.DESCRIPTION
    Molehill Data Services | Test-DatabaseStatus

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Test-MhDatabaseStatus). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    For after a patch, a failover, a VM snapshot restore or anything else that might have left a
    database behind. Quick on purpose - it is "is everything back?", not a consistency check, so
    there is no DBCC CHECKDB here and it runs in seconds.

    For each database it reads the state, the user access mode, whether it is read-only, in
    standby or closing itself, how many suspect pages it has, and where it sits in an availability
    group. Then, unless -Quick, it opens a connection to the database itself and runs SELECT 1,
    because a database can look online in the catalogue and still refuse a connection.

    The verdict is one of three: OK, CHECK for something worth a look, FAIL for something that is
    not working. A failure outranks a thing to look at, and the reason is always given.

    Exit code: 0 = everything is fine, 1 = something is worth a look, 2 = something has failed or
    the instance could not be read.

.PARAMETER SqlInstance
    The instance to check. Asked for if left out.

.PARAMETER SqlCredential
    SQL authentication. Windows authentication is used when this is left out.

.PARAMETER Quick
    Skip the per-database connection test, which is the only slow part.

.PARAMETER FailuresOnly
    Show only the databases that failed or need a look.

.PARAMETER CsvPath
    Write the per-database detail to this file as well.

.PARAMETER NonInteractive
    Do not offer to run again at the end: for a scheduled task, where there is no key to press.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for the instance. Default 5, because an instance that is still starting
    should be reported as such rather than waited on.

.PARAMETER SelfTest
    Check the verdicts it reaches, with no server at all.

.EXAMPLE
    .\Test-DatabaseStatus.ps1 SQL01

.EXAMPLE
    .\Test-DatabaseStatus.ps1 -SqlInstance SQL01\SALES -FailuresOnly -CsvPath .\status.csv

.NOTES
    Molehill Data Services. Read-only: it reads catalogue views and opens a connection per
    database.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $SqlInstance,
    [pscredential] $SqlCredential,
    [switch] $Quick,
    [switch] $FailuresOnly,
    [string] $CsvPath,
    [switch] $NonInteractive,
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 5,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Test-MhDatabaseStatus.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim calling another - the sample screen calls the export - would re-import
# the module underneath it and reset everything it holds, which is how a scripted run of the
# screen lost the keys it was being driven with halfway through
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Test-MhDatabaseStatus'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# a redirected or piped console has no key to read, so do not offer to wait for one
$interactive = -not $NonInteractive -and $Host.UI.RawUI -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

while ($true) {
    try {
        $status = Test-MhDatabaseStatus -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                      -Quick:$Quick -FailuresOnly:$FailuresOnly -CsvPath $CsvPath `
                      -ConnectTimeoutSeconds $ConnectTimeoutSeconds
    }
    catch { exit 2 }
    if (-not $status) { exit 1 }

    # the module worked out the worst thing it found; this does not second-guess it
    $code = [int]$status.ExitCode

    if (-not $interactive) { exit $code }

    Write-Host '  [R] run again   [F] failures only   [A] all   [Q] quit' -ForegroundColor DarkGray
    try { $key = [Console]::ReadKey($true) } catch { exit $code }
    switch ($key.Key) {
        'R' { continue }
        'F' { $FailuresOnly = $true; continue }
        'A' { $FailuresOnly = $false; continue }
        'Q' { exit $code }
        default { exit $code }
    }
}
