#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'SqlServer'; ModuleVersion = '22.0.0' }

<#
.SYNOPSIS
    Copies an Azure SQL Database to one or more target logical servers and swaps it in
    place of the existing database on each.

.DESCRIPTION
    Molehill Data Services

    For each target server (all copies run in parallel server-side):
      1. Starts CREATE DATABASE ... AS COPY OF on the target server's master database.
      2. Polls until the copy is ONLINE, fails, or times out.
      3. Renames the existing target database to <TargetDatabase>-prev-<stamp>.
      4. Renames the copy to <TargetDatabase>.
      5. Drops the previous database (unless -KeepPrevious).

    If step 4 fails, step 3 is rolled back so the environment keeps its original database.

    Safe by default: without -Execute, preflight checks run (read-only) and the planned
    SQL is printed. Nothing is created, renamed or dropped.

.PARAMETER SourceServer
    Source logical server. Short name (sql-my-ser) or FQDN (sql-my-ser.database.windows.net).

.PARAMETER SourceDatabase
    Database to copy.

.PARAMETER TargetServer
    One or more target logical servers, one per environment.

.PARAMETER TargetDatabase
    Name the database should have on each target. Defaults to SourceDatabase.

.PARAMETER ServiceObjective
    Optional service objective for the copy, e.g. S2, GP_Gen5_2. Defaults to the source's.

.PARAMETER ElasticPool
    Optional elastic pool name on the target server. Cannot be combined with ServiceObjective.

.PARAMETER SqlCredential
    SQL authentication credential. If omitted, a Microsoft Entra ID access token from the
    current Az context is used (run Connect-AzAccount first).

.PARAMETER PollSeconds
    Seconds between status checks. Default 30.

.PARAMETER TimeoutMinutes
    Maximum wait for all copies. Default 240.

.PARAMETER KeepPrevious
    Keep the replaced database as <TargetDatabase>-prev-<stamp> instead of dropping it.

.PARAMETER Execute
    Actually run the copy, rename and drop. Without it the script is a dry run.

.PARAMETER SelfTest
    Checks the parts of this script that need no server: the name handling, the SQL it builds,
    the swap plan, and the refusal to copy a database over itself. Connects to nothing.
    Exit code: 0 = all passed, 1 = something failed.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test, sql-oof-uat -TargetDatabase oof-web

    Dry run against three environments.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test -TargetDatabase oof-web `
        -ElasticPool pool-nonprod -Execute
#>
[CmdletBinding()]
param(
    # not Mandatory on purpose: a missing Mandatory parameter makes PowerShell prompt, and a prompt
    # in a pipeline or a scheduled run is a hang rather than a failure. They are checked below.
    [string]$SourceServer,
    [string]$SourceDatabase,
    [string[]]$TargetServer,
    [string]$TargetDatabase = $SourceDatabase,
    [string]$ServiceObjective,
    [string]$ElasticPool,
    [pscredential]$SqlCredential,
    [ValidateRange(5, 600)][int]$PollSeconds = 30,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 240,
    [switch]$KeepPrevious,
    [switch]$Execute,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host ('{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}' -f (Get-Date), $Level, $Message) -ForegroundColor $colour
}

function Resolve-ServerName {
    param([string]$Name)
    $short = ($Name -split '\.')[0].ToLowerInvariant()
    $fqdn  = if ($Name -like '*.*') { $Name.ToLowerInvariant() } else { "$short.database.windows.net" }
    [pscustomobject]@{ Short = $short; Fqdn = $fqdn }
}

function ConvertTo-QuotedName {
    param([string]$Name)
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Get-SqlAccessToken {
    # Fetched per call so long-running copies outlive the token lifetime safely.
    $t = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
    if ($t.Token -is [securestring]) {
        ConvertFrom-SecureString -SecureString $t.Token -AsPlainText
    }
    else {
        $t.Token
    }
}

function Invoke-MasterQuery {
    param(
        [string]$Server,
        [string]$Query,
        [int]$Timeout = 60
    )
    $p = @{
        ServerInstance = $Server
        Database       = 'master'
        Query          = $Query
        QueryTimeout   = $Timeout
        Encrypt        = 'Mandatory'
        ErrorAction    = 'Stop'
    }
    if ($SqlCredential) { $p.Credential = $SqlCredential } else { $p.AccessToken = Get-SqlAccessToken }
    Invoke-Sqlcmd @p
}

function Test-DatabaseExists {
    param([string]$Server, [string]$Name)

    # @() and a row count, rather than reading .n off whatever came back. Under
    # Set-StrictMode -Version Latest a result that is not one row makes $r.n throw "The property
    # 'n' cannot be found on this object", and the preflight below records that against the server
    # as its reason for failing - which reads like a bug in this script rather than a server that
    # answered oddly, and sends whoever is looking at it to the wrong place entirely.
    $rows = @(Invoke-MasterQuery -Server $Server -Query "SELECT COUNT(*) AS n FROM sys.databases WHERE name = $(ConvertTo-SqlLiteral $Name);")
    if ($rows.Count -ne 1) {
        throw "Counting $Name on $Server came back as $($rows.Count) row(s) instead of one, so whether it exists is not known."
    }
    [int]$rows[0].n -gt 0
}

function Get-NameStamp {
    # The invariant culture, not the server's. 'yyyy' under a Thai or Hijri calendar gives 2569 or
    # 1448, so the same run would name its databases differently depending on the region the
    # machine happens to be set to - and nobody looking for yesterday's copy is going to search for
    # oof-web-prev-256910221700.
    param([datetime]$When = (Get-Date))
    $When.ToString('yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-CopyStatement {
    param(
        [string]$SourceServerShort,
        [string]$SourceDatabase,
        [string]$CopyName,
        [string]$ServiceObjective,
        [string]$ElasticPool
    )
    if ($ServiceObjective -and $ElasticPool) {
        throw 'Specify either -ServiceObjective or -ElasticPool, not both.'
    }

    $qSource = '{0}.{1}' -f (ConvertTo-QuotedName $SourceServerShort), (ConvertTo-QuotedName $SourceDatabase)

    $with = ''
    if ($ServiceObjective) {
        $with = " ( SERVICE_OBJECTIVE = '{0}' )" -f $ServiceObjective.Replace("'", "''")
    }
    elseif ($ElasticPool) {
        $with = ' ( SERVICE_OBJECTIVE = ELASTIC_POOL( name = {0} ) )' -f (ConvertTo-QuotedName $ElasticPool)
    }

    "CREATE DATABASE $(ConvertTo-QuotedName $CopyName) AS COPY OF $qSource$with;"
}

function Get-SwapPlan {
    # The statements that put the copy in place, in the order they have to happen. One function so
    # the dry run prints the plan that the swap below actually carries out, rather than a second
    # list beside it that can drift from it.
    param(
        [string]$TargetDatabase,
        [string]$CopyName,
        [string]$PreviousName,
        [bool]$TargetExists,
        [bool]$KeepPrevious
    )
    $qTarget = ConvertTo-QuotedName $TargetDatabase
    $qCopy   = ConvertTo-QuotedName $CopyName
    $qPrev   = ConvertTo-QuotedName $PreviousName

    $plan = @()
    if ($TargetExists) { $plan += "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" }
    $plan += "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;"
    # nothing to drop when there was nothing there: the copy is the first database of that name
    if ($TargetExists -and -not $KeepPrevious) { $plan += "DROP DATABASE $qPrev;" }
    $plan
}

function Get-SourceClash {
    # The one refusal that matters. Copying a database over itself would rename the source aside
    # and then drop it, which is the whole environment gone rather than a failed run. Same server
    # and same name is the source; same server and a different name is an ordinary copy within one
    # logical server, and a different server with the same name is the normal case.
    param(
        [string]$TargetFqdn,
        [string]$TargetDatabase,
        [string]$SourceFqdn,
        [string]$SourceDatabase
    )
    if ($TargetFqdn -eq $SourceFqdn -and $TargetDatabase -eq $SourceDatabase) {
        return "Target $TargetFqdn / $TargetDatabase is the source database. Refusing to overwrite the source."
    }
    ''
}

#endregion

#region Self test

# Everything above that does not need a server. It runs before the setup below so that -SelfTest
# never looks for an Az context or opens a connection.
if ($SelfTest) {
    $script:failed = 0
    function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    function Threw([scriptblock]$Body) {
        try { & $Body | Out-Null; '' } catch { ($_.Exception.Message -split "`r?`n")[0] }
    }

    Write-Host 'Copy-AzureSqlDatabase self test' -ForegroundColor Cyan
    Write-Host '  server names' -ForegroundColor Gray

    # -ceq throughout, not -eq: PowerShell compares strings case-insensitively, so -eq here would
    # pass whether or not the lower-casing happened at all. These checks are about the case.
    $short = Resolve-ServerName 'sql-my-ser'
    Check 'a short name keeps its short form' ($short.Short -ceq 'sql-my-ser') $short.Short
    Check 'and gets the Azure SQL suffix' ($short.Fqdn -ceq 'sql-my-ser.database.windows.net') $short.Fqdn

    $full = Resolve-ServerName 'sql-my-ser.database.windows.net'
    Check 'an FQDN is left as it is' ($full.Fqdn -ceq 'sql-my-ser.database.windows.net') $full.Fqdn
    Check 'and still yields the short name for AS COPY OF' ($full.Short -ceq 'sql-my-ser') $full.Short

    $loud = Resolve-ServerName 'SQL-MY-SER.Database.Windows.Net'
    Check 'case is flattened, so the same server is the same server' (
        $loud.Fqdn -ceq $full.Fqdn -and $loud.Short -ceq $full.Short) "$($loud.Short) / $($loud.Fqdn)"
    Check 'and it really is lower-cased rather than merely compared loosely' (
        $loud.Short -ceq 'sql-my-ser' -and $loud.Fqdn -ceq 'sql-my-ser.database.windows.net')
        "$($loud.Short) / $($loud.Fqdn)"

    # a private endpoint or a sovereign cloud is somebody else's suffix, not ours to replace
    $other = Resolve-ServerName 'sql-my-ser.privatelink.database.chinacloudapi.cn'
    Check 'a suffix that is not ours is not rewritten' (
        $other.Fqdn -ceq 'sql-my-ser.privatelink.database.chinacloudapi.cn') $other.Fqdn

    Write-Host '  quoting' -ForegroundColor Gray
    Check 'a name is bracketed' ((ConvertTo-QuotedName 'oof-web') -eq '[oof-web]') (ConvertTo-QuotedName 'oof-web')
    Check 'a closing bracket in a name is doubled, not left to close the quoting early' (
        (ConvertTo-QuotedName 'od]d') -eq '[od]]d]') (ConvertTo-QuotedName 'od]d')
    Check 'a literal is an N string' ((ConvertTo-SqlLiteral 'oof-web') -eq "N'oof-web'") (ConvertTo-SqlLiteral 'oof-web')
    Check 'and a quote in one is doubled' ((ConvertTo-SqlLiteral "o'd") -eq "N'o''d'") (ConvertTo-SqlLiteral "o'd")

    Write-Host '  the copy statement' -ForegroundColor Gray
    $plain = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' -CopyName 'oof-web-copy-1'
    Check 'it copies from server.database, which is what AS COPY OF wants' (
        $plain -eq 'CREATE DATABASE [oof-web-copy-1] AS COPY OF [sql-my-ser].[oof-web-src];') $plain

    $sized = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' `
                               -CopyName 'oof-web-copy-1' -ServiceObjective 'GP_Gen5_2'
    Check 'a service objective is passed through' ($sized -match "SERVICE_OBJECTIVE = 'GP_Gen5_2' \)") $sized

    $pooled = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' `
                                -CopyName 'oof-web-copy-1' -ElasticPool 'pool-nonprod'
    Check 'an elastic pool goes in as a pool, bracketed' (
        $pooled -match 'ELASTIC_POOL\( name = \[pool-nonprod\] \)') $pooled

    Check 'asking for both is refused' (
        (Threw { New-CopyStatement -SourceServerShort 's' -SourceDatabase 'd' -CopyName 'c' `
                                   -ServiceObjective 'S2' -ElasticPool 'p' }) -match 'not both')

    # the objective is a string in the statement rather than an identifier, so it is the one place
    # a quote could end the literal early
    $quoted = New-CopyStatement -SourceServerShort 's' -SourceDatabase 'd' -CopyName 'c' -ServiceObjective "S2' --"
    Check 'a quote in the objective cannot end the string early' ($quoted -match "'S2'' --'") $quoted

    Write-Host '  the swap plan' -ForegroundColor Gray
    $replace = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                              -PreviousName 'oof-web-prev-1' -TargetExists $true -KeepPrevious $false)
    Check 'replacing takes three statements' ($replace.Count -eq 3) "$($replace.Count)"
    Check 'the live one is moved aside first' ($replace[0] -eq 'ALTER DATABASE [oof-web] MODIFY NAME = [oof-web-prev-1];') $replace[0]
    Check 'then the copy takes its name' ($replace[1] -eq 'ALTER DATABASE [oof-web-copy-1] MODIFY NAME = [oof-web];') $replace[1]
    Check 'and only the one moved aside is dropped' ($replace[2] -eq 'DROP DATABASE [oof-web-prev-1];') $replace[2]

    $kept = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                           -PreviousName 'oof-web-prev-1' -TargetExists $true -KeepPrevious $true)
    Check 'keeping the previous one drops nothing' (
        $kept.Count -eq 2 -and -not @($kept | Where-Object { $_ -match 'DROP' }).Count) ($kept -join ' ')

    $fresh = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                            -PreviousName 'oof-web-prev-1' -TargetExists $false -KeepPrevious $false)
    Check 'a target that does not exist is only renamed into place' ($fresh.Count -eq 1) ($fresh -join ' ')
    Check 'and nothing is dropped when there was nothing there' (
        -not @($fresh | Where-Object { $_ -match 'DROP' }).Count) ($fresh -join ' ')

    # the check that matters: whatever the combination, the only thing a plan ever drops is the
    # database that was renamed out of the way
    foreach ($exists in $true, $false) {
        foreach ($keep in $true, $false) {
            $plan = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                                   -PreviousName 'oof-web-prev-1' -TargetExists $exists -KeepPrevious $keep)
            $drops = @($plan | Where-Object { $_ -match '^DROP' })
            Check "nothing but the moved-aside copy is dropped (exists=$exists, keep=$keep)" (
                -not @($drops | Where-Object { $_ -notmatch '\[oof-web-prev-1\];$' }).Count) ($drops -join ' ')
        }
    }

    Write-Host '  refusing to copy a database over itself' -ForegroundColor Gray
    $src = Resolve-ServerName 'sql-my-ser'
    Check 'the same server and the same name is the source, and is refused' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing to overwrite the source')
    Check 'the same server under another name is an ordinary copy' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'oof-web-dev' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -eq '')
    Check 'another server with the same name is the normal case' (
        (Get-SourceClash -TargetFqdn 'sql-oof-dev.database.windows.net' -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -eq '')
    # the comparison happens after Resolve-ServerName, so a shouted target cannot slip past it
    Check 'a differently cased server name does not get past it' (
        (Get-SourceClash -TargetFqdn (Resolve-ServerName 'SQL-MY-SER').Fqdn -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing')
    Check 'and nor does a differently cased database name' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'OOF-Web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing')

    Write-Host '  the stamp that goes in the names' -ForegroundColor Gray
    # the one check here that needs a culture that is not ours: th-TH counts years from a different
    # era, so a stamp built through the current culture comes out as 2569 rather than 2026
    $when = New-Object datetime 2026, 10, 22, 16, 45, 0
    $wasCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in 'en-GB', 'en-US', 'de-DE', 'th-TH') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
            Check "the same stamp under $culture" ((Get-NameStamp $when) -ceq '202610221645') (Get-NameStamp $when)
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $wasCulture }

    Write-Host '  counting a database before touching it' -ForegroundColor Gray
    # the rows Invoke-Sqlcmd would hand back, as the DataRows they really are
    function CountRows([int[]]$Counts) {
        $table = New-Object System.Data.DataTable
        [void]$table.Columns.Add('n', [int])
        foreach ($one in $Counts) { [void]$table.Rows.Add($one) }
        $table.Rows
    }
    $script:stubRows = @()
    function Invoke-MasterQuery { param([string]$Server, [string]$Query, [int]$Timeout = 60) $script:stubRows }

    $script:stubRows = @(CountRows 1)
    Check 'one row saying one means the database is there' (Test-DatabaseExists -Server 's' -Name 'd')
    $script:stubRows = @(CountRows 0)
    Check 'one row saying none means it is not' (-not (Test-DatabaseExists -Server 's' -Name 'd'))

    $script:stubRows = @()
    $noRows = Threw { Test-DatabaseExists -Server 'sql-oof-dev.database.windows.net' -Name 'oof-web' }
    Check 'no rows at all is refused, not read as a missing property' ($noRows -match 'instead of one') $noRows
    Check 'and the refusal says which database on which server' (
        $noRows -match 'oof-web' -and $noRows -match 'sql-oof-dev') $noRows
    Check 'nothing about a property that cannot be found' ($noRows -notmatch 'cannot be found') $noRows

    $script:stubRows = @(CountRows 1, 1)
    Check 'and more than one row is refused too' (
        (Threw { Test-DatabaseExists -Server 's' -Name 'd' }) -match 'instead of one')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#endregion

#region Setup

$missing = @()
if (-not $SourceServer)   { $missing += '-SourceServer' }
if (-not $SourceDatabase) { $missing += '-SourceDatabase' }
if (-not $TargetServer)   { $missing += '-TargetServer' }
if ($missing.Count) {
    throw ('{0} {1} needed. See Get-Help .\Copy-AzureSqlDatabase.ps1 for what this takes.' -f
           ($missing -join ', '), $(if ($missing.Count -eq 1) { 'is' } else { 'are' }))
}

$stamp    = Get-NameStamp
$source   = Resolve-ServerName $SourceServer
$copyName = "$TargetDatabase-copy-$stamp"
$prevName = "$TargetDatabase-prev-$stamp"

$qCopy   = ConvertTo-QuotedName $copyName
$qTarget = ConvertTo-QuotedName $TargetDatabase
$qPrev   = ConvertTo-QuotedName $prevName

$createSql = New-CopyStatement -SourceServerShort $source.Short -SourceDatabase $SourceDatabase `
                               -CopyName $copyName -ServiceObjective $ServiceObjective -ElasticPool $ElasticPool

if (-not $SqlCredential -and -not (Get-AzContext)) {
    throw 'No -SqlCredential supplied and no Az context found. Run Connect-AzAccount first.'
}

$targets = $TargetServer |
    ForEach-Object { Resolve-ServerName $_ } |
    Sort-Object Fqdn -Unique |
    ForEach-Object {
        $clash = Get-SourceClash -TargetFqdn $_.Fqdn -TargetDatabase $TargetDatabase `
                                 -SourceFqdn $source.Fqdn -SourceDatabase $SourceDatabase
        if ($clash) { throw $clash }
        [pscustomobject]@{
            Server       = $_.Short
            Fqdn         = $_.Fqdn
            TargetExists = $false
            Status       = 'Pending'
            Message      = ''
            Started      = $null
            Finished     = $null
        }
    }

Write-Log ("Mode: {0}" -f ($Execute ? 'EXECUTE' : 'DRY RUN')) ($Execute ? 'WARN' : 'INFO')
Write-Log "Source: $($source.Fqdn) / $SourceDatabase"
Write-Log "Targets: $(($targets.Fqdn) -join ', ')  ->  $TargetDatabase"

#endregion

#region Preflight

Write-Log 'Preflight checks'

if (-not (Test-DatabaseExists -Server $source.Fqdn -Name $SourceDatabase)) {
    throw "Source database $SourceDatabase not found on $($source.Fqdn)."
}

foreach ($t in $targets) {
    try {
        if (Test-DatabaseExists -Server $t.Fqdn -Name $copyName) {
            throw "Copy name $copyName already exists."
        }
        $t.TargetExists = Test-DatabaseExists -Server $t.Fqdn -Name $TargetDatabase
        Write-Log ('{0}: reachable; {1} {2}' -f $t.Fqdn, $TargetDatabase,
            ($t.TargetExists ? 'exists and will be replaced' : 'does not exist and will be created'))
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Preflight: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Dry run

if (-not $Execute) {
    foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
        Write-Log "Planned SQL on $($t.Fqdn) (master):"
        $plan = @($createSql, '-- poll sys.databases / sys.dm_database_copies until ONLINE') +
                @(Get-SwapPlan -TargetDatabase $TargetDatabase -CopyName $copyName -PreviousName $prevName `
                               -TargetExists $t.TargetExists -KeepPrevious ([bool]$KeepPrevious))
        $plan | ForEach-Object { Write-Host "    $_" }
    }
    Write-Log 'Dry run complete. Re-run with -Execute to apply.' WARN
    return
}

#endregion

#region Start copies

foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
    try {
        Write-Log "$($t.Fqdn): starting copy as $copyName"
        Invoke-MasterQuery -Server $t.Fqdn -Query $createSql -Timeout 600 | Out-Null
        $t.Status  = 'Copying'
        $t.Started = Get-Date
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Start copy: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Wait for copies

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$pollSql  = @"
SELECT d.state_desc, c.percent_complete, c.error_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_copies AS c ON c.database_id = d.database_id
WHERE d.name = $(ConvertTo-SqlLiteral $copyName);
"@
$opSql = @"
SELECT TOP (1) operation, state_desc, error_desc
FROM sys.dm_operation_status
WHERE major_resource_id = $(ConvertTo-SqlLiteral $copyName)
ORDER BY start_time DESC;
"@

while ($targets | Where-Object Status -eq 'Copying') {

    foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
        try {
            $r = Invoke-MasterQuery -Server $t.Fqdn -Query $pollSql

            if (-not $r) {
                # Failed copies are dropped by Azure; look for the reason.
                $op     = Invoke-MasterQuery -Server $t.Fqdn -Query $opSql
                $detail = if ($op) { "$($op.operation) $($op.state_desc): $([string]$op.error_desc)" } else { 'no operation status recorded' }
                $t.Status  = 'Failed'
                $t.Message = "Copy database disappeared. $detail"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            elseif ($r.state_desc -eq 'ONLINE') {
                $t.Status   = 'Copied'
                $t.Finished = Get-Date
                Write-Log ('{0}: copy ONLINE after {1:hh\:mm\:ss}' -f $t.Fqdn, ($t.Finished - $t.Started)) OK
            }
            elseif ([string]$r.error_desc) {
                $t.Status  = 'Failed'
                $t.Message = "Copy error: $([string]$r.error_desc)"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            else {
                $pct = if ($r.percent_complete -is [DBNull]) { 'n/a' } else { '{0:N1}%' -f $r.percent_complete }
                Write-Log "$($t.Fqdn): $($r.state_desc)  $pct"
            }
        }
        catch {
            Write-Log "$($t.Fqdn): poll error, will retry: $($_.Exception.Message)" WARN
        }
    }

    if ((Get-Date) -gt $deadline) {
        foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
            $t.Status  = 'Failed'
            $t.Message = "Timed out after $TimeoutMinutes minutes. Copy $copyName may still be running server-side."
            Write-Log "$($t.Fqdn): $($t.Message)" ERROR
        }
        break
    }

    if ($targets | Where-Object Status -eq 'Copying') { Start-Sleep -Seconds $PollSeconds }
}

#endregion

#region Swap

foreach ($t in ($targets | Where-Object Status -eq 'Copied')) {
    $renamedOld = $false
    try {
        if ($t.TargetExists) {
            Write-Log "$($t.Fqdn): renaming $TargetDatabase to $prevName"
            Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" -Timeout 300 | Out-Null
            $renamedOld = $true
        }

        Write-Log "$($t.Fqdn): renaming $copyName to $TargetDatabase"
        Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null

        if ($renamedOld -and -not $KeepPrevious) {
            try {
                Write-Log "$($t.Fqdn): dropping $prevName"
                Invoke-MasterQuery -Server $t.Fqdn -Query "DROP DATABASE $qPrev;" -Timeout 600 | Out-Null
                $t.Message = 'Replaced; previous database dropped.'
            }
            catch {
                $t.Message = "Replaced, but drop of $prevName failed: $($_.Exception.Message)"
                Write-Log "$($t.Fqdn): $($t.Message)" WARN
            }
        }
        elseif ($renamedOld) {
            $t.Message = "Replaced; previous database kept as $prevName."
        }
        else {
            $t.Message = 'Created.'
        }

        $t.Status = 'Done'
        Write-Log "$($t.Fqdn): $($t.Message)" OK
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Swap: $($_.Exception.Message)"
        if ($renamedOld) {
            try {
                Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qPrev MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null
                $t.Message += " Original rename rolled back; $copyName left in place."
            }
            catch {
                $t.Message += " ROLLBACK FAILED: original database is currently named $prevName."
            }
        }
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Summary

Write-Log 'Run summary'
$targets |
    Select-Object Fqdn, Status,
        @{ n = 'CopyTime'; e = { if ($_.Started -and $_.Finished) { '{0:hh\:mm\:ss}' -f ($_.Finished - $_.Started) } } },
        Message |
    Format-Table -AutoSize -Wrap

if ($targets | Where-Object Status -ne 'Done') { exit 1 }

#endregion
