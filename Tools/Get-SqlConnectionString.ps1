#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a SQL Server connection string on a screen, the way SSMS asks for one, and puts it on
    the pipeline.

.DESCRIPTION
    Molehill Data Services | Get-SqlConnectionString

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Get-MhSqlConnectionString). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

        $cs = .\Get-SqlConnectionString.ps1
        .\Get-SqlConnectionString.ps1 | Set-Clipboard
        .\Export-DatabaseSample.ps1 -ConnectionString (.\Get-SqlConnectionString.ps1) -Database Sales

    One screen: server, authentication, user, password, database, and an Options screen for
    encryption and the rest. Every authentication method SQL Server offers is listed, from Windows
    and SQL logins on a 2000 box through to Entra on Azure SQL Database and Managed Instance. F5
    opens the connection to prove the string works before handing it back.

    Only the connection string goes to the pipeline; everything drawn goes to the host.

    Exit code: 0 = a string, 1 = you pressed Esc, 2 = could not start.

.PARAMETER SqlInstance
    Fills the server box in.

.PARAMETER Database
    Fills the database box in.

.PARAMETER ApplicationName
    What the connection calls itself, which is what a DBA sees in sys.dm_exec_sessions.

.PARAMETER UseMicrosoftDataSqlClient
    Insist on Microsoft.Data.SqlClient, and say so plainly if it is not there. It is used by
    default anyway when the SqlServer module is installed.

.PARAMETER UseSystemDataSqlClient
    Start on System.Data.SqlClient instead: for SQL Server 2000 and 2005, which the other driver
    will not talk to, and for a machine where the SqlServer module is not wanted.

.PARAMETER SkipTest
    Hand back the string without opening the connection.

.PARAMETER AsObject
    Return an object - ConnectionString, Namespace, AuthMethod, AccessToken, Database, ServerInfo,
    Settings - instead of just the string.

.PARAMETER KeyScript
    Drive the screen from a list of keystrokes instead of the keyboard. 'Down', 'Enter', 'Esc',
    'Space', 'F2' to 'F9', 'text:SQLPROD01' and single characters are all understood.

.PARAMETER SelfTest
    Check the logic behind the screen with no server at all.

.EXAMPLE
    $cs = .\Get-SqlConnectionString.ps1 -SqlInstance SQLPROD01

.NOTES
    Molehill Data Services. Read-only: it opens a connection and asks the server what it is.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $SqlInstance,
    [Parameter(Position = 1)] [string] $Database,
    [string] $ApplicationName = 'Molehill SQL tools',
    [switch] $UseMicrosoftDataSqlClient,
    [switch] $UseSystemDataSqlClient,
    [switch] $SkipTest,
    [switch] $AsObject,
    [string[]] $KeyScript,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Get-MhSqlConnectionString.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

$arguments = @{}
foreach ($name in 'SqlInstance', 'Database', 'ApplicationName', 'UseMicrosoftDataSqlClient',
                  'UseSystemDataSqlClient', 'SkipTest', 'AsObject', 'KeyScript') {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}

$result = Get-MhSqlConnectionString @arguments
if (-not $result) { exit 1 }
$result
exit 0
