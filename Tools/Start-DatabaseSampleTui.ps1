#Requires -Version 5.1

<#
.SYNOPSIS
    A connect-and-pick screen for Export-DatabaseSample.ps1: builds the connection the way SSMS
    does, shows you the connection string it built, lists the tables and lets you choose which
    ones to sample.

.DESCRIPTION
    Molehill Data Services | Start-DatabaseSampleTui

    Four screens, in order:

      1. CONNECT - server name, authentication, user, password, database, and an Options screen
         for encryption and the rest. Every authentication method SQL Server offers is listed,
         from Windows and SQL logins on a 2000 box through to Entra on Azure SQL Database and
         Managed Instance. The connection string it has built is shown at the bottom as you type,
         with the password masked until you ask for it.
      2. DATABASE - if you did not name one, the databases on that server, to pick from.
      3. TABLES - every table it would export, with its row count, and three ways to choose:
         ALL, only the ones you tick (include), or everything except the ones you tick (exclude).
      4. EXPORT - rows per table, where the zip goes, and the run itself.

    The export is done by Export-DatabaseSample.ps1 in the same folder, handed the exact
    connection string you saw and the exact table names you picked. Nothing is sampled until you
    confirm on the last screen.

    None of the screens are written here. They come from Molehill.SqlConnect.psm1 beside this
    script: the connect dialog, which Get-SqlConnectionString.ps1 also uses to hand a connection
    string to the pipeline, and the two pickers - Show-MhTuiList for one of something and
    Show-MhTuiCheckList for the all / only these / all but these choice. What is left in this script
    is the table discovery, the export form, and the order it all happens in.

    AUTHENTICATION, AND WHICH DRIVER CAN DO WHAT
    The methods on offer are not guessed at: each one is tried against the connection string
    builder when the screen opens, and anything the driver in use cannot do is shown greyed with
    the reason. There are two drivers and they differ:

      * Microsoft.Data.SqlClient, which comes with the SqlServer module, is used when it is there.
        It is the one with every Entra method - interactive, password, integrated, service
        principal, managed identity, device code and default - and the only one with
        Encrypt = Strict (TDS 8) and a host name in certificate. Install it with
        Install-Module SqlServer -Scope CurrentUser.
      * System.Data.SqlClient is the fallback, and needs nothing installed at all. That is what it
        is for: a locked-down server that cannot reach the gallery still gets Windows and SQL
        authentication, and it is the only driver that will talk to SQL Server 2000 or 2005.
        Pass -UseSystemDataSqlClient to insist on it.

    One caveat about the fallback: under Windows PowerShell it accepts the Entra keywords, so the
    screen offers them, but completing an interactive sign-in through it also needs ADAL on the
    machine - something the screen cannot check for you. Under PowerShell 7 it has no Entra
    support at all and says so. Where Entra matters, the SqlServer module is the answer.

    Press F3 on the connect screen to switch driver; the list of methods and options changes with
    it. No Az modules are used or needed.

    THE KEYS
    The commands are function keys throughout, so that every printable character belongs to the box
    the caret is in: F2 options, F3 driver, F4 show the password, F5 connect, F6 copy the string,
    Esc to leave. On the table screen F2 changes mode, F3 ticks everything shown, F4 clears, F6
    inverts and F7 filters, with Space, Enter and Esc as you would expect.

.PARAMETER SqlInstance
    Fills the server box in, so you do not have to type it.

.PARAMETER Database
    Fills the database box in. Leave it out and you get the list to pick from.

.PARAMETER OutputPath
    Where the zip goes. Default: the current folder. Changeable on the export screen.

.PARAMETER Top
    Rows per table. Default 200. Changeable on the export screen.

.PARAMETER UseMicrosoftDataSqlClient
    Insist on Microsoft.Data.SqlClient, and say so plainly if it is not there. It is used by
    default anyway when the SqlServer module is installed, so this is only needed to turn a quiet
    fallback into a complaint.

.PARAMETER UseSystemDataSqlClient
    Start on System.Data.SqlClient instead, skipping the SqlServer module altogether. For SQL
    Server 2000 and 2005, which the other driver will not talk to, and to avoid the module import
    on a machine where it is slow or not wanted.

.PARAMETER KeyScript
    Drive the screens from a list of keystrokes instead of the keyboard, for testing and for
    recording a walkthrough. 'Down', 'Enter', 'Esc', 'Space', 'F2' to 'F9', 'text:SQLPROD01' and
    single characters are all understood.

.PARAMETER SelfTest
    Check the logic behind the screens, which all come from Molehill.SqlConnect, with no server at
    all.

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1 -SqlInstance SQLPROD01 -Database Sales

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1 -SqlInstance myserver.database.windows.net

.NOTES
    Molehill Data Services. Reads only: it lists databases and tables, and the export it runs
    takes a sample of rows. Nothing on the server is changed.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $SqlInstance,
    [Parameter(Position = 1)] [string] $Database,
    [string] $OutputPath = (Get-Location).ProviderPath,
    [ValidateRange(1, 2147483647)] [int] $Top = 200,
    [switch] $UseMicrosoftDataSqlClient,
    [switch] $UseSystemDataSqlClient,
    [string[]] $KeyScript,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

# the screens, the authentication matrix and the connection string building all live in
# MolehillTools, so that anything else can use them too
$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it, and it is what draws the screens.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    exit 2
}
# not -Force: one shim calling another - the sample screen calls the export - would re-import
# the module underneath it and reset everything it holds, which is how a scripted run of the
# screen lost the keys it was being driven with halfway through
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

#==============================================================================
# The tables this database would export
#==============================================================================
<#
  The tables the export would consider, with their row counts.

  The same shape as Export-DatabaseSample's own discovery - user tables, nothing Microsoft shipped,
  no diagram support tables - so what is ticked here is what gets exported. SQL Server 2000 has
  none of those catalogue views, so it falls back to INFORMATION_SCHEMA and says what it cannot do.
#>
function Get-TuiTableList {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection, [Parameter(Mandatory)] $Info)

    if ($Info.Major -lt 9) {
        $query = @"
SELECT SchemaName = TABLE_SCHEMA, TableName = TABLE_NAME, [Rows] = CAST(0 AS bigint)
FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_SCHEMA, TABLE_NAME
"@
    }
    else {
        $query = @"
SELECT  SchemaName = s.name,
        TableName  = o.name,
        [Rows]     = ISNULL((SELECT SUM(p.rows) FROM sys.partitions AS p
                             WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)), 0)
FROM    sys.objects AS o
JOIN    sys.schemas AS s ON s.schema_id = o.schema_id
WHERE   o.type = 'U'
AND     o.is_ms_shipped = 0
AND     NOT EXISTS (SELECT 1 FROM sys.extended_properties AS ep
                    WHERE ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0
                    AND   ep.name = N'microsoft_database_tools_support')
ORDER BY s.name, o.name
"@
    }
    (Invoke-MhSqlQuery -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Schema = [string]$_['SchemaName']; Table = [string]$_['TableName']; Rows = [int64]$_['Rows'] }
    }
}

#==============================================================================
# Screen 4: the export itself
#==============================================================================
function Show-ExportScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Options, [Parameter(Mandatory)] $Choice, [Parameter(Mandatory)] [string] $DatabaseName)

    $fields = @('Top', 'OutputPath', 'ReadUncommitted', 'RemoveFolder', 'Force')
    $focus = 0
    $message = ''
    while ($true) {
        Clear-MhTuiScreen
        Write-MhTuiTitle "Export a sample of [$DatabaseName]"
        Write-MhTui ''
        Write-MhTuiField -Label 'Rows per table' -Value $Options.Top -Focused ($fields[$focus] -eq 'Top') -Note 'TOP (n) ... ORDER BY NEWID()'
        Write-MhTuiField -Label 'Output folder' -Value $Options.OutputPath -Focused ($fields[$focus] -eq 'OutputPath') `
                       -Note "the zip lands here as $DatabaseName.zip"
        Write-MhTuiField -Label 'Read uncommitted' -Value $Options.ReadUncommitted -Focused ($fields[$focus] -eq 'ReadUncommitted') `
                       -Note 'no shared locks taken, for a busy production table'
        Write-MhTuiField -Label 'Delete folder after zip' -Value $Options.RemoveFolder -Focused ($fields[$focus] -eq 'RemoveFolder')
        Write-MhTuiField -Label 'Replace what is there' -Value $Options.Force -Focused ($fields[$focus] -eq 'Force') `
                       -Note 'overwrite an existing folder and zip of the same name'
        Write-MhTui ''
        $what = switch ($Choice.Mode) {
            'All'     { 'every table' }
            'Include' { "only these $(@($Choice.Labels).Count): " + (@($Choice.Labels) -join ', ') }
            default   { "everything except these $(@($Choice.Labels).Count): " + (@($Choice.Labels) -join ', ') }
        }
        Write-MhTui "  Tables: $what" Cyan
        if ($message) { Write-MhTui ''; Write-MhTui "  $message" Yellow }
        Write-MhTuiKeys 'Up/Down field   Space toggle   type to edit   F5 export   Esc back'

        $key = Read-MhTuiKey
        $message = ''
        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow' { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Escape'    { return $false }
            'Backspace' {
                switch ($fields[$focus]) {
                    'Top'        { $Options.Top = [int]((Remove-MhTuiChar ([string]$Options.Top)) + '0') }
                    'OutputPath' { $Options.OutputPath = Remove-MhTuiChar $Options.OutputPath }
                }
            }
            'Spacebar'  {
                switch ($fields[$focus]) {
                    'ReadUncommitted' { $Options.ReadUncommitted = -not $Options.ReadUncommitted }
                    'RemoveFolder'    { $Options.RemoveFolder = -not $Options.RemoveFolder }
                    'Force'           { $Options.Force = -not $Options.Force }
                }
            }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        switch ($key.Name) {
            'F5'        {
                if (-not (Test-Path -LiteralPath $Options.OutputPath -PathType Container)) {
                    $message = "There is no folder called '$($Options.OutputPath)'."
                    continue
                }
                if ($Options.Top -lt 1) { $message = 'Rows per table has to be at least 1.'; continue }
                return $true
            }
        }
        if ($message) { continue }
        if ($key.Char) {
            switch ($fields[$focus]) {
                'Top' {
                    if ([char]::IsDigit($key.Char)) {
                        $text = ([string]$Options.Top) + $key.Char
                        if ($text.Length -le 9) { $Options.Top = [int]$text }
                    }
                }
                'OutputPath' { $Options.OutputPath = Add-MhTuiChar $Options.OutputPath $key.Char }
            }
        }
    }
}

#==============================================================================
# Self test
#
# The screens here are the module's now - the connect dialog, the list and the tick list - so its
# tests are these tests. What is left in this script is the table discovery query and the export
# form, and both of those need a server to mean anything.
#==============================================================================
if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

#==============================================================================
# The run
#==============================================================================
$enginePath = Join-Path $PSScriptRoot 'Export-DatabaseSample.ps1'
if (-not (Test-Path -LiteralPath $enginePath)) {
    Write-Host "  Export-DatabaseSample.ps1 is not next to this script, and it is what does the exporting." -ForegroundColor Red
    Write-Host "  Looked in: $PSScriptRoot" -ForegroundColor Gray
    exit 2
}

if ($UseSystemDataSqlClient -and $UseMicrosoftDataSqlClient) {
    Write-Host '  -UseSystemDataSqlClient and -UseMicrosoftDataSqlClient ask for opposite things.' -ForegroundColor Red
    exit 2
}
Set-MhTuiKeyScript -Script $KeyScript
$namespace = Select-MhSqlClientNamespace -PreferSystemData:$UseSystemDataSqlClient -RequireMicrosoftData:$UseMicrosoftDataSqlClient

$settings = New-MhSqlConnectSettings -Namespace $namespace -Server $SqlInstance -Database $Database `
                                   -ApplicationName 'Molehill Export-DatabaseSample'
$exportOptions = [pscustomobject]@{
    Top = $Top; OutputPath = $OutputPath; ReadUncommitted = $false; RemoveFolder = $false; Force = $false
}
$exitCode = 0

while ($true) {
    $connected = Show-MhSqlConnectDialog -Settings $settings
    if (-not $connected) { Write-Host ''; Write-Host '  Nothing done.' -ForegroundColor Gray; break }
    $connectionString = $connected.ConnectionString
    $info = $connected.ServerInfo
    if ($info.Major -gt 0 -and $info.Major -lt 9) {
        Write-MhTui '  This is SQL Server 2000. The export needs the catalogue views that arrived in 2005, so it will not run against it.' Yellow
    }

    $connection = $null
    try {
        $connection = Open-MhSqlConnection -Settings $settings -ConnectionString $connectionString

        # a database has to be settled before the tables can be listed, and the connection string
        # has to be rebuilt for it: Initial Catalog is part of what you were shown
        if (-not $settings.Database) {
            Write-MhTui ''
            Write-MhTui '  Reading the database list...' DarkGray
            $databases = @(Get-MhSqlDatabaseList -Connection $connection -Info $info)
            $chosen = Show-MhTuiList -Items $databases -Title 'Which database' -AllowFilter `
                          -Label { $_.Name } -Detail { if ($_.State -ne 'ONLINE') { $_.State } else { '' } } `
                          -Dim { $_.State -ne 'ONLINE' }
            if (-not $chosen) { $connection.Dispose(); $connection = $null; continue }
            $settings.Database = $chosen.Name
            $connection.Dispose()
            $connectionString = New-MhSqlConnectionString -Settings $settings
            $connection = Open-MhSqlConnection -Settings $settings -ConnectionString $connectionString
            $info = Get-MhSqlServerInfo -Connection $connection
        }

        Clear-MhTuiScreen
        Write-MhTuiTitle "Reading the tables in [$($settings.Database)]"
        $tables = @(Get-TuiTableList -Connection $connection -Info $info)
        $connection.Dispose()
        $connection = $null

        if (@($tables).Count -eq 0) {
            Write-MhTui ''
            Write-MhTui "  [$($settings.Database)] has no user tables to sample." Yellow
            Write-MhTuiKeys 'any key to go back'
            [void](Read-MhTuiKey)
            $settings.Database = ''
            continue
        }

        $choice = Show-MhTuiCheckList -Items $tables -Title "Tables in [$($settings.Database)]" `
                       -Label { "$($_.Schema).$($_.Table)" } -Detail { '{0:N0} rows' -f $_.Rows } `
                       -ItemNoun 'table' -Action 'exported'
        if (-not $choice) { $settings.Database = ''; continue }

        if (-not (Show-ExportScreen -Options $exportOptions -Choice $choice -DatabaseName $settings.Database)) { continue }

        Clear-MhTuiScreen
        Write-MhTuiTitle "Exporting [$($settings.Database)]"
        Write-MhTui ''
        $engineArgs = @{
            ConnectionString = $connectionString
            Database         = $settings.Database
            OutputPath       = $exportOptions.OutputPath
            Top              = $exportOptions.Top
        }
        if ($settings.Namespace -eq 'Microsoft.Data.SqlClient') { $engineArgs['UseMicrosoftDataSqlClient'] = $true }
        if ($settings.AuthId -eq 'Token') { $engineArgs['AccessToken'] = $settings.Token.Trim() }
        if ($exportOptions.ReadUncommitted) { $engineArgs['ReadUncommitted'] = $true }
        if ($exportOptions.RemoveFolder) { $engineArgs['RemoveFolderAfterZip'] = $true }
        if ($exportOptions.Force) { $engineArgs['Force'] = $true }
        if ($choice.Mode -eq 'Include') { $engineArgs['IncludeTable'] = $choice.Labels }
        if ($choice.Mode -eq 'Exclude') { $engineArgs['ExcludeTable'] = $choice.Labels }

        try {
            $result = & $enginePath @engineArgs
            if ($result -and $result.Failed -gt 0) { $exitCode = 1 }
        }
        catch {
            Write-MhTui ''
            Write-MhTui "  The export stopped: $(($_.Exception.GetBaseException().Message -split "`r?`n")[0])" Red
            $exitCode = 1
        }

        Write-MhTui ''
        Write-MhTuiKeys 'any key for the connect screen, Esc to finish'
        if ((Read-MhTuiKey).Name -eq 'Escape') { break }
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
}

exit $exitCode
