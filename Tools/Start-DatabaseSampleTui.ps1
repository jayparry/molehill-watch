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

    The first screen is not written here: it comes from Molehill.SqlConnect.psm1 beside this
    script, which Get-SqlConnectionString.ps1 also uses to hand a connection string to the
    pipeline. Anything else that needs a connection can use it too.

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
    Check the screen logic - the connect screen's own tests from the module, plus the table
    picker - with no server at all.

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

# the screen, the authentication matrix and the connection string building all live in the module
# beside this script, so that anything else can use them too
$modulePath = Join-Path $PSScriptRoot 'Molehill.SqlConnect.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "  Molehill.SqlConnect.psm1 is not next to this script, and it is what draws the connect screen." -ForegroundColor Red
    Write-Host "  Looked in: $PSScriptRoot" -ForegroundColor Gray
    exit 2
}
Import-Module $modulePath -Force -DisableNameChecking

#==============================================================================
# The sums this screen does for itself
#==============================================================================
function Get-PickerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('All', 'Include', 'Exclude')] [string] $Mode,
        [int] $Total, [int] $Ticked
    )
    switch ($Mode) {
        'All' { return [pscustomobject]@{ Count = $Total; Text = "ALL TABLES - every one of the $Total will be exported" } }
        'Include' { return [pscustomobject]@{ Count = $Ticked; Text = "INCLUDE - $Ticked ticked of $Total, so $Ticked will be exported" } }
        default {
            $left = $Total - $Ticked
            return [pscustomobject]@{ Count = $left; Text = "EXCLUDE - $Ticked ticked of $Total, so $left will be exported" }
        }
    }
}
function Select-PickerRows {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Rows, [AllowEmptyString()] [string] $Filter)

    # -NoEnumerate so one match still comes back as a list: under Windows PowerShell 5.1 a single
    # object has no .Count, and counting the rows is most of what this screen does
    if (-not $Filter) { return Write-Output -NoEnumerate @($Rows) }
    $needle = $Filter.Trim()
    Write-Output -NoEnumerate @($Rows | Where-Object { "$($_.Schema).$($_.Table)" -like "*$needle*" })
}
function Format-Rows([object] $Value) {
    if ($null -eq $Value) { return '' }
    '{0:N0}' -f [int64]$Value
}

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
    Write-Output -NoEnumerate @((Invoke-SqlQueryTable -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Schema = [string]$_['SchemaName']; Table = [string]$_['TableName']; Rows = [int64]$_['Rows']; Ticked = $false }
    })
}

#==============================================================================
# Screen 2: which database
#==============================================================================
function Show-DatabasePicker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Databases)

    if (@($Databases).Count -eq 0) { return $null }
    $index = 0
    $window = 15
    while ($true) {
        Clear-TuiScreen
        Write-TuiTitle 'Which database'
        Write-Tui ''
        $first = [math]::Max(0, [math]::Min($index - [int]($window / 2), @($Databases).Count - $window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $window, @($Databases).Count); $i++) {
            $db = $Databases[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White } elseif ($db.State -ne 'ONLINE') { [ConsoleColor]::DarkGray } else { [ConsoleColor]::Gray }
            Write-Tui ('  {0} {1,-50} {2}' -f $marker, $db.Name, $(if ($db.State -ne 'ONLINE') { $db.State } else { '' })) $colour
        }
        Write-Tui ''
        Write-Tui ("  {0} of {1}" -f ($index + 1), @($Databases).Count) DarkGray
        Write-TuiKeys 'Up/Down   Enter choose   Esc back'

        $key = Read-TuiKey
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min(@($Databases).Count - 1, $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $window) }
            'PageDown'  { $index = [math]::Min(@($Databases).Count - 1, $index + $window) }
            'Home'      { $index = 0 }
            'End'       { $index = @($Databases).Count - 1 }
            'Enter'     { return $Databases[$index].Name }
            'Escape'    { return $null }
        }
    }
}

#==============================================================================
# Screen 3: which tables
#==============================================================================
function Show-TablePicker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Tables, [string] $DatabaseName)

    $mode = 'All'
    $index = 0
    $filter = ''
    $filtering = $false
    $window = 15
    $message = ''

    while ($true) {
        $visible = Select-PickerRows -Rows $Tables -Filter $filter
        if ($index -ge @($visible).Count) { $index = [math]::Max(0, @($visible).Count - 1) }
        $ticked = @($Tables | Where-Object { $_.Ticked }).Count
        $summary = Get-PickerSummary -Mode $mode -Total @($Tables).Count -Ticked $ticked

        Clear-TuiScreen
        Write-TuiTitle "Tables in [$DatabaseName]"
        Write-Tui ''
        Write-Tui ("  Mode: " + $summary.Text) $(if ($summary.Count -eq 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })
        if ($filtering -or $filter) {
            Write-Tui ("  Filter: '{0}'{1} - {2} of {3} shown" -f $filter,
                       $(if ($filtering) { ' (typing; Enter or Esc to stop)' } else { '' }),
                       @($visible).Count, @($Tables).Count) $(if ($filtering) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray })
        }
        Write-Tui ''

        if (@($visible).Count -eq 0) { Write-Tui '    nothing matches that filter' DarkGray }
        $first = [math]::Max(0, [math]::Min($index - [int]($window / 2), @($visible).Count - $window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $window, @($visible).Count); $i++) {
            $row = $visible[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $box = if ($mode -eq 'All') { '   ' } elseif ($row.Ticked) { '[x]' } else { '[ ]' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White }
                      elseif ($mode -eq 'Exclude' -and $row.Ticked) { [ConsoleColor]::DarkGray }
                      else { [ConsoleColor]::Gray }
            Write-Tui ('  {0} {1} {2,-50} {3,12} rows' -f $marker, $box, "$($row.Schema).$($row.Table)", (Format-Rows $row.Rows)) $colour
        }
        Write-Tui ''
        Write-Tui ("  {0} of {1} listed" -f $(if (@($visible).Count) { $index + 1 } else { 0 }), @($visible).Count) DarkGray
        if ($message) { Write-Tui "  $message" Yellow }
        if ($filtering) { Write-TuiKeys 'type to narrow the list   Backspace   Enter or Esc to stop filtering' }
        else { Write-TuiKeys 'Up/Down   Space tick   F2 mode (All/Include/Exclude)   F3 all shown   F4 none   F6 invert shown   F7 filter   Enter continue   Esc back' }

        $key = Read-TuiKey
        $message = ''

        # while the filter is being typed the letters are letters, not commands
        if ($filtering) {
            switch ($key.Name) {
                'Enter'     { $filtering = $false }
                'Escape'    { $filtering = $false; $filter = ''; $index = 0 }
                'Backspace' { $filter = Remove-TuiChar $filter; $index = 0 }
                'UpArrow'   { $index = [math]::Max(0, $index - 1) }
                'DownArrow' { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + 1) }
                default     { if ($key.Char) { $filter = Add-TuiChar $filter $key.Char; $index = 0 } }
            }
            continue
        }

        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $window) }
            'PageDown'  { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + $window) }
            'Home'      { $index = 0 }
            'End'       { $index = [math]::Max(0, @($visible).Count - 1) }
            'Escape'    { return $null }
            'Spacebar'  {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press M to include or exclude.' }
                elseif (@($visible).Count) { $visible[$index].Ticked = -not $visible[$index].Ticked }
            }
            'F2'        { $mode = switch ($mode) { 'All' { 'Include' } 'Include' { 'Exclude' } default { 'All' } } }
            'F3'        {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press F2 to include or exclude.' }
                else { foreach ($row in $visible) { $row.Ticked = $true } }
            }
            'F4'        { foreach ($row in $Tables) { $row.Ticked = $false } }
            'F6'        {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press F2 to include or exclude.' }
                else { foreach ($row in $visible) { $row.Ticked = -not $row.Ticked } }
            }
            'F7'        { $filtering = $true; $message = 'Filtering.' }
            'Enter'     { $handled = $false }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        if ($key.Name -eq 'Enter') {
            if ($mode -eq 'All') { return [pscustomobject]@{ Mode = 'All'; Names = @() } }
            $names = @($Tables | Where-Object { $_.Ticked } | ForEach-Object { "$($_.Schema).$($_.Table)" })
            if ($names.Count -eq 0) {
                $message = 'Nothing is ticked. Tick some tables with Space, or press M for ALL.'
                continue
            }
            if ($mode -eq 'Exclude' -and $names.Count -eq @($Tables).Count) {
                $message = 'Every table is ticked to be excluded, which would export nothing.'
                continue
            }
            return [pscustomobject]@{ Mode = $mode; Names = $names }
        }

        # nothing on this screen is typed into, so the old letters still work as shortcuts
        if ($key.Char) {
            switch (([string]$key.Char).ToUpperInvariant()) {
                '/' { $filtering = $true; $message = 'Filtering.' }
                'M' { $mode = switch ($mode) { 'All' { 'Include' } 'Include' { 'Exclude' } default { 'All' } } }
                'A' { if ($mode -ne 'All') { foreach ($row in $visible) { $row.Ticked = $true } } }
                'N' { foreach ($row in $Tables) { $row.Ticked = $false } }
                'V' { if ($mode -ne 'All') { foreach ($row in $visible) { $row.Ticked = -not $row.Ticked } } }
                default { $message = "Nothing is bound to '$($key.Char)'. F7 or / filters by name." }
            }
        }
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
        Clear-TuiScreen
        Write-TuiTitle "Export a sample of [$DatabaseName]"
        Write-Tui ''
        Write-TuiField -Label 'Rows per table' -Value $Options.Top -Focused ($fields[$focus] -eq 'Top') -Note 'TOP (n) ... ORDER BY NEWID()'
        Write-TuiField -Label 'Output folder' -Value $Options.OutputPath -Focused ($fields[$focus] -eq 'OutputPath') `
                       -Note "the zip lands here as $DatabaseName.zip"
        Write-TuiField -Label 'Read uncommitted' -Value $Options.ReadUncommitted -Focused ($fields[$focus] -eq 'ReadUncommitted') `
                       -Note 'no shared locks taken, for a busy production table'
        Write-TuiField -Label 'Delete folder after zip' -Value $Options.RemoveFolder -Focused ($fields[$focus] -eq 'RemoveFolder')
        Write-TuiField -Label 'Replace what is there' -Value $Options.Force -Focused ($fields[$focus] -eq 'Force') `
                       -Note 'overwrite an existing folder and zip of the same name'
        Write-Tui ''
        $what = switch ($Choice.Mode) {
            'All'     { 'every table' }
            'Include' { "only these $(@($Choice.Names).Count): " + (@($Choice.Names) -join ', ') }
            default   { "everything except these $(@($Choice.Names).Count): " + (@($Choice.Names) -join ', ') }
        }
        Write-Tui "  Tables: $what" Cyan
        if ($message) { Write-Tui ''; Write-Tui "  $message" Yellow }
        Write-TuiKeys 'Up/Down field   Space toggle   type to edit   F5 export   Esc back'

        $key = Read-TuiKey
        $message = ''
        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow' { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Escape'    { return $false }
            'Backspace' {
                switch ($fields[$focus]) {
                    'Top'        { $Options.Top = [int]((Remove-TuiChar ([string]$Options.Top)) + '0') }
                    'OutputPath' { $Options.OutputPath = Remove-TuiChar $Options.OutputPath }
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
                'OutputPath' { $Options.OutputPath = Add-TuiChar $Options.OutputPath $key.Char }
            }
        }
    }
}

#==============================================================================
# Self test
#==============================================================================
if ($SelfTest) {
    Write-Host 'Start-DatabaseSampleTui self test'
    Write-Host '  the connect screen (Molehill.SqlConnect)' -ForegroundColor Gray
    $module = Test-SqlConnectModule

    $failed = $module.Failed
    function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    $script:failed = $failed

    Write-Host '  the three ways to choose tables' -ForegroundColor Gray
    Check 'all means all' ((Get-PickerSummary -Mode All -Total 10 -Ticked 0).Count -eq 10)
    Check 'and says so' ((Get-PickerSummary -Mode All -Total 10 -Ticked 3).Text -match 'every one of the 10')
    Check 'include exports what is ticked' ((Get-PickerSummary -Mode Include -Total 10 -Ticked 3).Count -eq 3)
    Check 'exclude exports the rest' ((Get-PickerSummary -Mode Exclude -Total 10 -Ticked 3).Count -eq 7)
    Check 'excluding everything exports nothing' ((Get-PickerSummary -Mode Exclude -Total 10 -Ticked 10).Count -eq 0)
    Check 'including nothing exports nothing' ((Get-PickerSummary -Mode Include -Total 10 -Ticked 0).Count -eq 0)

    $rows = @(
        [pscustomobject]@{ Schema = 'dbo'; Table = 'Orders' }
        [pscustomobject]@{ Schema = 'dbo'; Table = 'CustomerAudit' }
        [pscustomobject]@{ Schema = 'staging'; Table = 'Load' }
    )
    Check 'no filter shows everything' ((Select-PickerRows -Rows $rows -Filter '').Count -eq 3)
    Check 'one match is still a list, which 5.1 would otherwise not count' (
        $null -ne (Select-PickerRows -Rows $rows -Filter 'Orders').Count)
    Check 'a filter narrows it' ((Select-PickerRows -Rows $rows -Filter 'audit').Count -eq 1)
    Check 'and matches the schema too' ((Select-PickerRows -Rows $rows -Filter 'staging').Count -eq 1)
    Check 'and nothing is nothing' ((Select-PickerRows -Rows $rows -Filter 'zzz').Count -eq 0)

    Write-Host ''
    if ($script:failed -eq 0) {
        Write-Host ("All self tests passed{0}." -f $(if ($module.Skipped) { ", $($module.Skipped) skipped" } else { '' })) -ForegroundColor Green
        exit 0
    }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
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
Set-TuiKeyScript -Script $KeyScript
$namespace = Select-SqlClientNamespace -PreferSystemData:$UseSystemDataSqlClient -RequireMicrosoftData:$UseMicrosoftDataSqlClient

$settings = New-SqlConnectSettings -Namespace $namespace -Server $SqlInstance -Database $Database `
                                   -ApplicationName 'Molehill Export-DatabaseSample'
$exportOptions = [pscustomobject]@{
    Top = $Top; OutputPath = $OutputPath; ReadUncommitted = $false; RemoveFolder = $false; Force = $false
}
$exitCode = 0

while ($true) {
    $connected = Show-SqlConnectDialog -Settings $settings
    if (-not $connected) { Write-Host ''; Write-Host '  Nothing done.' -ForegroundColor Gray; break }
    $connectionString = $connected.ConnectionString
    $info = $connected.ServerInfo
    if ($info.Major -gt 0 -and $info.Major -lt 9) {
        Write-Tui '  This is SQL Server 2000. The export needs the catalogue views that arrived in 2005, so it will not run against it.' Yellow
    }

    $connection = $null
    try {
        $connection = Open-SqlConnection -Settings $settings -ConnectionString $connectionString

        # a database has to be settled before the tables can be listed, and the connection string
        # has to be rebuilt for it: Initial Catalog is part of what you were shown
        if (-not $settings.Database) {
            Write-Tui ''
            Write-Tui '  Reading the database list...' DarkGray
            $databases = Get-SqlDatabaseList -Connection $connection -Info $info
            $chosen = Show-DatabasePicker -Databases $databases
            if (-not $chosen) { $connection.Dispose(); $connection = $null; continue }
            $settings.Database = $chosen
            $connection.Dispose()
            $connectionString = New-SqlConnectionString -Settings $settings
            $connection = Open-SqlConnection -Settings $settings -ConnectionString $connectionString
            $info = Get-SqlServerInfo -Connection $connection
        }

        Clear-TuiScreen
        Write-TuiTitle "Reading the tables in [$($settings.Database)]"
        $tables = Get-TuiTableList -Connection $connection -Info $info
        $connection.Dispose()
        $connection = $null

        if (@($tables).Count -eq 0) {
            Write-Tui ''
            Write-Tui "  [$($settings.Database)] has no user tables to sample." Yellow
            Write-TuiKeys 'any key to go back'
            [void](Read-TuiKey)
            $settings.Database = ''
            continue
        }

        $choice = Show-TablePicker -Tables $tables -DatabaseName $settings.Database
        if (-not $choice) { $settings.Database = ''; continue }

        if (-not (Show-ExportScreen -Options $exportOptions -Choice $choice -DatabaseName $settings.Database)) { continue }

        Clear-TuiScreen
        Write-TuiTitle "Exporting [$($settings.Database)]"
        Write-Tui ''
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
        if ($choice.Mode -eq 'Include') { $engineArgs['IncludeTable'] = $choice.Names }
        if ($choice.Mode -eq 'Exclude') { $engineArgs['ExcludeTable'] = $choice.Names }

        try {
            $result = & $enginePath @engineArgs
            if ($result -and $result.Failed -gt 0) { $exitCode = 1 }
        }
        catch {
            Write-Tui ''
            Write-Tui "  The export stopped: $(($_.Exception.GetBaseException().Message -split "`r?`n")[0])" Red
            $exitCode = 1
        }

        Write-Tui ''
        Write-TuiKeys 'any key for the connect screen, Esc to finish'
        if ((Read-TuiKey).Name -eq 'Escape') { break }
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
}

exit $exitCode
