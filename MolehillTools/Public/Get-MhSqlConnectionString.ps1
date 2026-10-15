<#
.SYNOPSIS
    Builds a SQL Server connection string on a screen, the way SSMS asks for one, and puts it on
    the pipeline.

.DESCRIPTION
    One screen: server, authentication, user, password, database, and an Options screen for
    encryption and the rest. Every authentication method SQL Server offers is listed, from Windows
    and SQL logins on a 2000 box through to Entra on Azure SQL Database and Managed Instance. The
    string it has built is shown as you type, with the password masked until you ask for it.

    F5 opens the connection to prove the string works before handing it back, so what you get is a
    string that connected rather than a string that looked right. -SkipTest hands it back without
    connecting.

    Only the connection string goes to the pipeline. Everything drawn goes to the host, so this can
    be assigned or piped:

        $cs = Get-MhSqlConnectionString
        Get-MhSqlConnectionString | Set-Clipboard
        Invoke-Sqlcmd -ConnectionString (Get-MhSqlConnectionString) -Query 'SELECT @@VERSION'

    Nothing is cancelled quietly: Esc gives back nothing at all, so a script can tell the
    difference between a string and a change of mind.

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
    Drive the screen from a list of keystrokes instead of the keyboard, for testing and for
    recording a walkthrough. 'Down', 'Enter', 'Esc', 'Space', 'F2' to 'F9', 'text:SQLPROD01' and
    single characters are all understood.

.EXAMPLE
    $cs = Get-MhSqlConnectionString -SqlInstance SQLPROD01

.EXAMPLE
    Export-MhDatabaseSample -ConnectionString (Get-MhSqlConnectionString) -Database Sales

.EXAMPLE
    $c = Get-MhSqlConnectionString -SqlInstance myserver.database.windows.net -AsObject
    $c.ServerInfo.Platform

.NOTES
    Molehill Data Services. Read-only: it opens a connection and asks the server what it is.
#>
function Get-MhSqlConnectionString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)] [string] $SqlInstance,
        [Parameter(Position = 1)] [string] $Database,
        [string] $ApplicationName = 'Molehill SQL tools',
        [switch] $UseMicrosoftDataSqlClient,
        [switch] $UseSystemDataSqlClient,
        [switch] $SkipTest,
        [switch] $AsObject,
        [string[]] $KeyScript
    )

    if ($UseSystemDataSqlClient -and $UseMicrosoftDataSqlClient) {
        throw '-UseSystemDataSqlClient and -UseMicrosoftDataSqlClient ask for opposite things.'
    }

    Set-MhTuiKeyScript -Script $KeyScript
    $namespace = Select-MhSqlClientNamespace -PreferSystemData:$UseSystemDataSqlClient `
                                             -RequireMicrosoftData:$UseMicrosoftDataSqlClient
    $settings = New-MhSqlConnectSettings -Namespace $namespace -Server $SqlInstance -Database $Database `
                                         -ApplicationName $ApplicationName
    $connected = Show-MhSqlConnectDialog -Settings $settings -SkipTest:$SkipTest
    if (-not $connected) { return }

    if ($AsObject) { $connected } else { $connected.ConnectionString }
}
