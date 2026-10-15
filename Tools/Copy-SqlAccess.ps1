#Requires -Version 5.1

<#
.SYNOPSIS
    Gives one principal the same access another one has: "give xyz on PROD the same access abc has
    on STAGING". Logins, server roles and permissions, database users, roles and permissions.

.DESCRIPTION
    Molehill Data Services | Copy-SqlAccess

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Copy-MhSqlAccess). With the module imported you would call that directly;
    this exists because copying one script to a box is how this estate works.

    It reads what the source principal has and writes the statements that reproduce it, creating
    the login and the users if they are not there.

    Nothing is changed until you have seen the plan. -WhatIf prints every statement and stops;
    without -Force it asks before applying, and a scheduled run with no console is told to pass
    -Force rather than failing with PowerShell's own message about it.

    It copes with what real instances look like: on-premises and Azure SQL Database and Managed
    Instance, Windows, SQL, Entra and contained users, a destination older than the source (which
    needs sp_addrolemember rather than ALTER ROLE), databases named differently at each end, and
    permissions on every securable class it has met. A class or a login type it has not met is
    reported rather than guessed at - a permission quietly dropped is the failure nobody notices
    until someone cannot work.

    What it will not do silently: copying access that amounts to control of the instance needs
    -AllowPrivileged, and copying a password or a SID needs -CopyPasswordAndSid.

    Exit code: 0 = done, or a plan printed with -WhatIf. 1 = something could not be copied.
    2 = could not start.

.PARAMETER SourceInstance
    The instance to read from.

.PARAMETER SourcePrincipal
    The login or user whose access is being copied.

.PARAMETER DestinationInstance
    The instance to write to. The same instance is allowed, which is how you clone a principal.

.PARAMETER Principal
    The login or user to give that access to. Created if it is not there.

.PARAMETER Database
    Only these databases. Everything the source principal is a user in, by default.

.PARAMETER DatabaseMap
    Databases named differently at each end: @{ SalesStg = 'SalesProd' } or 'SalesStg=SalesProd'.

.PARAMETER Password
    The password for a SQL login this has to create.

.PARAMETER CopyPasswordAndSid
    Copy the source login's password hash and SID, so the new login is the same login as far as
    every database is concerned. Same name, other instance, and it needs the right to read the hash.

.PARAMETER AllowPrivileged
    Allow access that amounts to control of the instance - sysadmin, securityadmin, CONTROL SERVER
    and the rest - to be copied. Refused without it.

.PARAMETER SkipServerLevel
    Database access only: no login, no server roles, no server permissions.

.PARAMETER Force
    Do not ask before applying.

.PARAMETER ScriptPath
    Write the statements to this file as well. The real password or hash is written to the file,
    not the masked form, so mind where it goes.

.PARAMETER SqlCredential
    SQL authentication for both ends.

.PARAMETER SourceSqlCredential
    SQL authentication for the source only.

.PARAMETER DestinationSqlCredential
    SQL authentication for the destination only.

.PARAMETER TrustServerCertificate
    Skip certificate validation, which an on-premises instance with a self-signed one needs.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for each connection. Default 15.

.PARAMETER LogLevel
    Quiet, Normal, Verbose or Debug. -Verbose and -Debug raise it on their own.

.PARAMETER LogFile
    Append the run to this file as well.

.PARAMETER SelfTest
    Check the reasoning - every statement it builds, and every refusal - with no server at all.

.EXAMPLE
    .\Copy-SqlAccess.ps1 -SourceInstance STG -SourcePrincipal abc -DestinationInstance PROD -Principal xyz -WhatIf

.EXAMPLE
    .\Copy-SqlAccess.ps1 STG abc PROD 'CONTOSO\xyz' -Database Sales -Force

.EXAMPLE
    .\Copy-SqlAccess.ps1 SQL01 AppSvc SQL01 AppSvc2 -CopyPasswordAndSid -AllowPrivileged

.NOTES
    Molehill Data Services. It reads the source and writes to the destination; the source is never
    changed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)] [string] $SourceInstance,
    [Parameter(Position = 1)] [string] $SourcePrincipal,
    [Parameter(Position = 2)] [string] $DestinationInstance,
    [Parameter(Position = 3)] [string] $Principal,

    [string[]] $Database,
    [object] $DatabaseMap,

    [System.Security.SecureString] $Password,
    [switch] $CopyPasswordAndSid,
    [switch] $AllowPrivileged,
    [switch] $SkipServerLevel,

    [switch] $Force,
    [string] $ScriptPath,

    [PSCredential] $SqlCredential,
    [PSCredential] $SourceSqlCredential,
    [PSCredential] $DestinationSqlCredential,
    [switch] $TrustServerCertificate,
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
    [string] $LogFile,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Copy-MhSqlAccess.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Copy-MhSqlAccess'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# handed through by asking the function what it takes, rather than by a list here that can
# drift: two shims were quietly dropping parameters that way, which looks exactly like the tool
# ignoring you
$takes = @((Get-Command Copy-MhSqlAccess).Parameters.Keys)
$arguments = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($takes -contains $name) { $arguments[$name] = $PSBoundParameters[$name] }
}

try {
    $run = Copy-MhSqlAccess @arguments
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}

if (-not $run) { exit 2 }
exit $(if ($run.Ok) { 0 } else { 1 })
