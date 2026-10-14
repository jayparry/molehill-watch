#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a SQL Server connection string on a screen, the way SSMS asks for one, and puts it on
    the pipeline.

.DESCRIPTION
    Molehill Data Services | Get-SqlConnectionString

    One screen: server, authentication, user, password, database, and an Options screen for
    encryption and the rest. Every authentication method SQL Server offers is listed, from Windows
    and SQL logins on a 2000 box through to Entra on Azure SQL Database and Managed Instance. The
    string it has built is shown as you type, with the password masked until you ask for it.

    Press F5 and it opens the connection to prove the string works before handing it back, so what
    you get is a string that connected rather than a string that looked right. -SkipTest hands it
    back without connecting.

    Only the connection string goes to the pipeline. Everything drawn goes to the host, so this
    can be assigned or piped:

        $cs = .\Get-SqlConnectionString.ps1
        .\Get-SqlConnectionString.ps1 | Set-Clipboard
        Invoke-Sqlcmd -ConnectionString (.\Get-SqlConnectionString.ps1) -Query 'SELECT @@VERSION'

    -AsObject gives the settings behind it as well - the driver, the method, the access token and
    what the server said about itself - for a caller that needs more than the string.

    Nothing is cancelled quietly: Esc gives back nothing at all and exits 1, so a script can tell
    the difference between a string and a change of mind.

    The screen, the authentication matrix and the string building live in Molehill.SqlConnect.psm1
    beside this script. Start-DatabaseSampleTui.ps1 uses the same module.

.PARAMETER SqlInstance
    Fills the server box in.

.PARAMETER Database
    Fills the database box in.

.PARAMETER ApplicationName
    What the connection calls itself, which is what a DBA sees in sys.dm_exec_sessions.
    Default 'Molehill SQL tools'.

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
    Drive the screen from a list of keystrokes instead of the keyboard, for testing and for
    recording a walkthrough. 'Down', 'Enter', 'Esc', 'Space', 'F2' to 'F9', 'text:SQLPROD01' and
    single characters are all understood.

.PARAMETER SelfTest
    Check the logic behind the screen - the string built for every authentication method, how
    secrets are masked, the keystroke handling - with no server at all.

.EXAMPLE
    $cs = .\Get-SqlConnectionString.ps1 -SqlInstance SQLPROD01

.EXAMPLE
    # the string, and nothing else, straight into another tool
    .\Export-DatabaseSample.ps1 -ConnectionString (.\Get-SqlConnectionString.ps1) -Database Sales

.EXAMPLE
    # everything about the connection, not just the string
    $c = .\Get-SqlConnectionString.ps1 -SqlInstance myserver.database.windows.net -AsObject
    $c.ServerInfo.Platform

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

# the screen, the authentication matrix and the connection string building all live in the module
# beside this script, so that anything else can use them too
$modulePath = Join-Path $PSScriptRoot 'Molehill.SqlConnect.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "  Molehill.SqlConnect.psm1 is not next to this script, and it is what draws the connect screen." -ForegroundColor Red
    Write-Host "  Looked in: $PSScriptRoot" -ForegroundColor Gray
    exit 2
}
Import-Module $modulePath -Force -DisableNameChecking

if ($SelfTest) {
    Write-Host 'Get-SqlConnectionString self test'
    $result = Test-SqlConnectModule
    Write-Host ''
    if ($result.Failed -eq 0) {
        Write-Host ("All self tests passed{0}." -f $(if ($result.Skipped) { ", $($result.Skipped) skipped" } else { '' })) -ForegroundColor Green
        exit 0
    }
    Write-Host "$($result.Failed) self test(s) failed." -ForegroundColor Red
    exit 1
}

if ($UseSystemDataSqlClient -and $UseMicrosoftDataSqlClient) {
    Write-Host '  -UseSystemDataSqlClient and -UseMicrosoftDataSqlClient ask for opposite things.' -ForegroundColor Red
    exit 2
}
Set-TuiKeyScript -Script $KeyScript
$namespace = Select-SqlClientNamespace -PreferSystemData:$UseSystemDataSqlClient -RequireMicrosoftData:$UseMicrosoftDataSqlClient

$settings = New-SqlConnectSettings -Namespace $namespace -Server $SqlInstance -Database $Database `
                                   -ApplicationName $ApplicationName
$connected = Show-SqlConnectDialog -Settings $settings -SkipTest:$SkipTest
if (-not $connected) { exit 1 }

if ($AsObject) { $connected } else { $connected.ConnectionString }
exit 0
