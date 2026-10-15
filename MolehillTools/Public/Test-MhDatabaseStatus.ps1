<#
.SYNOPSIS
    Checks every database on an instance and says plainly whether it is available: green for pass,
    red for fail, with the reason.

.DESCRIPTION
    For after a patch, a failover, a VM snapshot restore or anything else that might have left a
    database behind. Quick on purpose - it is "is everything back?", not a consistency check, so
    there is no DBCC CHECKDB here and it runs in seconds.

    For each database it reads the state, the user access mode, whether it is read-only, in
    standby or closing itself, how many suspect pages it has, and where it sits in an availability
    group. Then, unless -Quick, it opens a connection to the database itself and runs SELECT 1,
    because a database can look online in the catalogue and still refuse a connection.

    The verdict is one of three: OK, CHECK for something worth a look, FAIL for something that is
    not working. A failure outranks a thing to look at, and the reason is always given.

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

.PARAMETER ConnectTimeoutSeconds
    How long to wait for the instance. Default 5, because an instance that is still starting
    should be reported as such rather than waited on.

.OUTPUTS
    The status object, with Info, Databases, Issues and RunAt, so it can be used as well as read.

.EXAMPLE
    Test-MhDatabaseStatus SQL01

.EXAMPLE
    Test-MhDatabaseStatus -SqlInstance SQL01\SALES -FailuresOnly -CsvPath .\status.csv

.NOTES
    Molehill Data Services. Read-only: it reads catalogue views and opens a connection per
    database. Exit-code equivalent: the Issues count on the object it returns.
#>
function Test-MhDatabaseStatus {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $SqlInstance,
        [pscredential] $SqlCredential,
        [switch] $Quick,
        [switch] $FailuresOnly,
        [string] $CsvPath,
        [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 5
    )

    if (-not $SqlInstance) {
        Write-Host ''
        Write-Host '  Database status' -ForegroundColor Cyan
        Write-Host '  Checks every database on an instance after a patch, failover or restore.' -ForegroundColor Gray
        Write-Host ''
        $SqlInstance = Read-Host '  SQL Server instance (e.g. SQL01, SQL01\SALES, localhost)'
        if (-not $SqlInstance) { Write-Host '  Nothing to check.' -ForegroundColor Yellow; return }
    }

    try {
        $status = Get-InstanceStatus -Server $SqlInstance.Trim() -Credential $SqlCredential `
                      -TimeoutSeconds $ConnectTimeoutSeconds -Quick:$Quick
    }
    catch {
        Write-Host ''
        Write-Host ("  Could not read {0}: {1}" -f $SqlInstance, $_.Exception.GetBaseException().Message) -ForegroundColor Red
        Write-Host '  The instance may still be starting, or the name may be wrong.' -ForegroundColor Gray
        Write-Host ''
        throw
    }

    # the report already works out how bad the worst thing is, so take its answer rather than
    # working it out again somewhere else and risking the two disagreeing
    $code = Write-DatabaseStatusReport -Status $status -FailuresOnly:$FailuresOnly -Quick:$Quick
    $status | Add-Member -NotePropertyName ExitCode -NotePropertyValue ([int]$code) -Force

    if ($CsvPath) {
        $status.Databases |
            Select-Object @{ n = 'Instance'; e = { $status.Info['ServerName'] } },
                          @{ n = 'CheckedAt'; e = { $status.RunAt } },
                          Name, Verdict, State, UserAccess, Recovery, IsReadOnly, IsAutoClose, IsInStandby,
                          SuspectPages, AgName, AgRole, AgSyncState, AgHealth, Probe, ProbeMs,
                          @{ n = 'Reasons'; e = { $_.Reasons -join '; ' } },
                          @{ n = 'Notes'; e = { $_.Notes -join '; ' } } |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  Saved to $CsvPath" -ForegroundColor Gray
        Write-Host ''
    }

    $status
}

$script:DbStatusInstanceQuery = @"
SELECT  ServerName      = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')),
        ProductVersion  = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductVersion')),
        ProductLevel    = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductLevel')),
        ProductUpdate   = CONVERT(nvarchar(32),  SERVERPROPERTY('ProductUpdateLevel')),
        Edition         = CONVERT(nvarchar(64),  SERVERPROPERTY('Edition')),
        IsClustered     = CONVERT(int,           SERVERPROPERTY('IsClustered')),
        IsHadrEnabled   = CONVERT(int,           SERVERPROPERTY('IsHadrEnabled')),
        StartTime       = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
        LoginName       = SUSER_SNAME(),
        IsSysadmin      = CONVERT(int, IS_SRVROLEMEMBER('sysadmin'));
"@

$script:DbStatusServicesQuery = @"
SELECT servicename, status_desc, startup_type_desc FROM sys.dm_server_services;
"@

$script:DbStatusDatabaseQuery = @"
SELECT  d.name,
        d.database_id,
        State        = d.state_desc,
        UserAccess   = d.user_access_desc,
        Recovery     = d.recovery_model_desc,
        IsReadOnly   = d.is_read_only,
        IsAutoClose  = d.is_auto_close_on,
        IsInStandby  = d.is_in_standby,
        SuspectPages = ISNULL(sp.Pages, 0),
        AgName       = ag.name,
        AgRole       = rs.role_desc,
        AgSyncState  = rs.synchronization_state_desc,
        AgHealth     = rs.synchronization_health_desc,
        AgSuspended  = rs.is_suspended,
        AgSuspendReason = rs.suspend_reason_desc,
        HasAccess    = HAS_DBACCESS(d.name)
FROM sys.databases d
OUTER APPLY (SELECT Pages = COUNT(*) FROM msdb.dbo.suspect_pages s WHERE s.database_id = d.database_id AND s.event_type <= 3) sp
LEFT JOIN sys.dm_hadr_database_replica_states rs ON rs.database_id = d.database_id AND rs.is_local = 1
LEFT JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
ORDER BY CASE WHEN d.database_id <= 4 THEN 0 ELSE 1 END, d.name;
"@

$script:DbStatusDatabaseQueryBasic = @"
SELECT  d.name,
        d.database_id,
        State        = d.state_desc,
        UserAccess   = d.user_access_desc,
        Recovery     = d.recovery_model_desc,
        IsReadOnly   = d.is_read_only,
        IsAutoClose  = d.is_auto_close_on,
        IsInStandby  = d.is_in_standby,
        SuspectPages = ISNULL(sp.Pages, 0),
        AgName       = CONVERT(nvarchar(128), NULL),
        AgRole       = CONVERT(nvarchar(60), NULL),
        AgSyncState  = CONVERT(nvarchar(60), NULL),
        AgHealth     = CONVERT(nvarchar(60), NULL),
        AgSuspended  = CONVERT(bit, 0),
        AgSuspendReason = CONVERT(nvarchar(60), NULL),
        HasAccess    = HAS_DBACCESS(d.name)
FROM sys.databases d
OUTER APPLY (SELECT Pages = COUNT(*) FROM msdb.dbo.suspect_pages s WHERE s.database_id = d.database_id AND s.event_type <= 3) sp
ORDER BY CASE WHEN d.database_id <= 4 THEN 0 ELSE 1 END, d.name;
"@

function Get-DatabaseVerdict {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Database)

    $fail = New-Object System.Collections.Generic.List[string]
    $look = New-Object System.Collections.Generic.List[string]
    $note = New-Object System.Collections.Generic.List[string]
    $d = $Database

    $isSecondary = ($d.AgRole -eq 'SECONDARY')

    switch ($d.State) {
        'ONLINE' { }
        'RESTORING' {
            if ($d.IsInStandby) { $look.Add('standby (log shipping secondary): read-only until the next restore') }
            elseif ($isSecondary) { $look.Add('Availability Group secondary: restoring, which is normal for a non-readable replica') }
            else { $fail.Add('RESTORING: a restore was started and never finished') }
        }
        'RECOVERING'        { $fail.Add('RECOVERING: still coming up, give it a moment and run again') }
        'RECOVERY_PENDING'  { $fail.Add('RECOVERY_PENDING: SQL Server could not start recovery - usually a missing or offline file') }
        'SUSPECT'           { $fail.Add('SUSPECT: recovery failed, the database is not usable') }
        'EMERGENCY'         { $fail.Add('EMERGENCY: someone put it there by hand, it is not available to applications') }
        'OFFLINE'           { $fail.Add('OFFLINE: taken offline, bring it back with ALTER DATABASE ... SET ONLINE') }
        default             { $fail.Add("state $($d.State)") }
    }

    if ($d.UserAccess -ne 'MULTI_USER') {
        $fail.Add("$($d.UserAccess): applications cannot connect while it is in this mode")
    }
    if ($d.IsReadOnly -and -not $d.IsInStandby -and -not $isSecondary) { $look.Add('read-only') }
    if ($d.IsAutoClose) { $note.Add('auto-close is on: the first connection after idle has to start the database') }
    if ($d.SuspectPages -gt 0) { $fail.Add("$($d.SuspectPages) suspect page(s) recorded in msdb") }

    if ($d.AgRole) {
        if ($d.AgSuspended) { $fail.Add("Availability Group: data movement suspended ($($d.AgSuspendReason))") }
        elseif ($d.AgSyncState -eq 'NOT SYNCHRONIZING') { $fail.Add('Availability Group: not synchronising') }
        elseif ($d.AgHealth -eq 'NOT_HEALTHY') { $fail.Add("Availability Group: $($d.AgSyncState), health not healthy") }
        elseif ($d.AgHealth -eq 'PARTIALLY_HEALTHY') { $look.Add("Availability Group: $($d.AgSyncState), partially healthy") }
    }

    if ($d.Probe -eq 'failed') { $fail.Add("could not connect: $($d.ProbeError)") }

    $verdict = 'OK'
    if ($look.Count)  { $verdict = 'CHECK' }
    if ($fail.Count)  { $verdict = 'FAIL' }

    [pscustomobject]@{
        Verdict = $verdict
        Reasons = @($fail) + @($look)
        Notes   = @($note)
    }
}

function Get-InstanceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [pscredential] $Credential,
        [ValidateRange(1, 300)] [int] $TimeoutSeconds = 5,
        [switch] $Quick
    )

    # one place for what every query here needs, rather than the ambient scope the script version
    # read it from
    $sql = @{
        Server = $Server; Credential = $Credential; TimeoutSeconds = $TimeoutSeconds
        TrustServerCertificate = $true; ApplicationName = 'MolehillTools Test-MhDatabaseStatus'
    }

    $info = (Invoke-MhSql @sql -Database 'master' -Query $script:DbStatusInstanceQuery).Rows[0]

    $services = @()
    try { $services = (Invoke-MhSql @sql -Database 'master' -Query $script:DbStatusServicesQuery).Rows }
    catch { $services = @() }    # not available on every build, and needs VIEW SERVER STATE

    try   { $rows = (Invoke-MhSql @sql -Database 'master' -Query $script:DbStatusDatabaseQuery).Rows }
    catch { $rows = (Invoke-MhSql @sql -Database 'master' -Query $script:DbStatusDatabaseQueryBasic).Rows }

    $databases = foreach ($r in $rows) {
        $db = [pscustomobject]@{
            Name            = [string]$r['name']
            State           = [string]$r['State']
            UserAccess      = [string]$r['UserAccess']
            Recovery        = [string]$r['Recovery']
            IsReadOnly      = [bool]$r['IsReadOnly']
            IsAutoClose     = [bool]$r['IsAutoClose']
            IsInStandby     = [bool]$r['IsInStandby']
            SuspectPages    = [int]$r['SuspectPages']
            AgName          = if ($r['AgName'] -is [DBNull]) { $null } else { [string]$r['AgName'] }
            AgRole          = if ($r['AgRole'] -is [DBNull]) { $null } else { [string]$r['AgRole'] }
            AgSyncState     = if ($r['AgSyncState'] -is [DBNull]) { $null } else { [string]$r['AgSyncState'] }
            AgHealth        = if ($r['AgHealth'] -is [DBNull]) { $null } else { [string]$r['AgHealth'] }
            AgSuspended     = if ($r['AgSuspended'] -is [DBNull]) { $false } else { [bool]$r['AgSuspended'] }
            AgSuspendReason = if ($r['AgSuspendReason'] -is [DBNull]) { $null } else { [string]$r['AgSuspendReason'] }
            HasAccess       = [int]$r['HasAccess']
            Notes           = @()
            Probe           = 'skipped'
            ProbeMs         = $null
            ProbeError      = $null
            Verdict         = 'OK'
            Reasons         = @()
        }

        # the real test: can something connect to this database right now?
        if (-not $Quick) {
            if ($db.State -ne 'ONLINE') { $db.Probe = 'n/a' }
            elseif ($db.AgRole -eq 'SECONDARY' -and $db.HasAccess -eq 0) { $db.Probe = 'n/a (secondary)' }
            else {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $null = Invoke-MhSql @sql -Database $db.Name -Query 'SELECT 1;'
                    $db.Probe = 'ok'
                }
                catch {
                    $db.Probe = 'failed'
                    $db.ProbeError = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                }
                $watch.Stop()
                $db.ProbeMs = [int]$watch.ElapsedMilliseconds
            }
        }

        $verdict = Get-DatabaseVerdict $db
        $db.Verdict = $verdict.Verdict
        $db.Reasons = $verdict.Reasons
        $db.Notes = $verdict.Notes
        $db
    }

    # A service set to start automatically that is not running is a failure in its own right:
    # the databases can be perfectly healthy while nothing runs the jobs or the backups.
    $issues = New-Object System.Collections.Generic.List[string]
    foreach ($s in $services) {
        $name = [string]$s['servicename']
        if ($name -notmatch 'SQL Server|Agent') { continue }
        if ([string]$s['status_desc'] -ne 'Running' -and [string]$s['startup_type_desc'] -like 'Automatic*') {
            $tail = if ($name -match 'Agent') { ' - scheduled jobs and backups will not run' } else { '' }
            $issues.Add(('{0} is {1} but is set to start automatically{2}' -f $name, $s['status_desc'], $tail))
        }
    }

    [pscustomobject]@{
        Info      = $info
        Services  = $services
        Databases = @($databases)
        Issues    = @($issues)
        RunAt     = Get-Date
    }
}

function Write-DatabaseStatusReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Status, [switch] $FailuresOnly, [switch] $Quick)

    $i = $Status.Info
    $uptime = (Get-Date) - [datetime]$i['StartTime']
    $upText = '{0}d {1}h {2}m' -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes
    $recent = $uptime.TotalHours -lt 1

    # Clear-MhTuiScreen rather than Clear-Host: there is no console to clear when the output is
    # redirected, and Clear-Host throws "The handle is invalid" rather than doing nothing
    Clear-MhTuiScreen
    Write-Host ''
    Write-Host "  Database status  " -NoNewline -ForegroundColor Black -BackgroundColor Cyan
    Write-Host "  $($i['ServerName'])   $($Status.RunAt.ToString('ddd dd MMM HH:mm:ss'))"
    Write-Host ''
    Write-Host ("  {0}  {1} {2}{3}" -f $i['Edition'], $i['ProductVersion'], $i['ProductLevel'],
                $(if ([string]$i['ProductUpdate']) { ' ' + $i['ProductUpdate'] } else { '' })) -ForegroundColor Gray
    Write-Host ("  Up {0} (started {1}){2}" -f $upText, ([datetime]$i['StartTime']).ToString('dd MMM HH:mm'),
                $(if ($recent) { '  <- restarted within the hour' } else { '' })) `
               -ForegroundColor $(if ($recent) { 'Yellow' } else { 'Gray' })

    foreach ($s in $Status.Services) {
        $name = [string]$s['servicename']
        if ($name -notmatch 'SQL Server|Agent') { continue }
        $running = ([string]$s['status_desc'] -eq 'Running')
        $expected = ([string]$s['startup_type_desc'] -like 'Automatic*')
        $colour = if ($running) { 'Green' } elseif ($expected) { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,-42} {1}{2}" -f $name, $s['status_desc'],
                    $(if (-not $running -and $expected) { ' (set to start automatically)' } else { '' })) -ForegroundColor $colour
    }
    Write-Host ''

    $shown = if ($FailuresOnly) { @($Status.Databases | Where-Object { $_.Verdict -ne 'OK' }) } else { $Status.Databases }
    $width = 10
    foreach ($d in $Status.Databases) { if ($d.Name.Length -gt $width) { $width = [Math]::Min($d.Name.Length, 40) } }

    Write-Host (" {0,-6} {1,-$width}  {2,-16} {3,-15} {4,-13} {5}" -f 'Result', 'Database', 'State', 'Access', 'Recovery', 'Connect') -ForegroundColor Gray
    Write-Host (" {0}" -f ('-' * ($width + 64))) -ForegroundColor DarkGray

    foreach ($d in $shown) {
        $colour = switch ($d.Verdict) { 'OK' { 'Green' } 'CHECK' { 'Yellow' } default { 'Red' } }
        $label  = switch ($d.Verdict) { 'OK' { ' PASS ' } 'CHECK' { ' CHECK' } default { ' FAIL ' } }
        $probe  = switch ($d.Probe) {
            'ok'      { if ($null -ne $d.ProbeMs) { "ok ($($d.ProbeMs) ms)" } else { 'ok' } }
            'skipped' { '-' }
            default   { $d.Probe }
        }
        Write-Host $label -NoNewline -ForegroundColor Black -BackgroundColor $colour
        Write-Host ("  {0,-$width}  {1,-16} {2,-15} {3,-13} {4}" -f $d.Name, $d.State, $d.UserAccess, $d.Recovery, $probe)
        if ($d.AgName) {
            Write-Host ("        {0,-$width}  Availability Group {1}: {2}, {3}" -f '', $d.AgName, $d.AgRole, $d.AgSyncState) -ForegroundColor DarkGray
        }
        foreach ($n in $d.Notes) {
            Write-Host ("        {0,-$width}  {1}" -f '', $n) -ForegroundColor DarkGray
        }
    }

    $bad = @($Status.Databases | Where-Object { $_.Verdict -ne 'OK' })
    if ($bad.Count -or $Status.Issues.Count) {
        Write-Host ''
        Write-Host '  What is wrong' -ForegroundColor Gray
        foreach ($issue in $Status.Issues) { Write-Host ("    {0}" -f $issue) -ForegroundColor Red }
        foreach ($d in $bad) {
            $colour = if ($d.Verdict -eq 'FAIL') { 'Red' } else { 'Yellow' }
            foreach ($reason in $d.Reasons) {
                Write-Host ("    {0}: {1}" -f $d.Name, $reason) -ForegroundColor $colour
            }
        }
    }

    $ok    = @($Status.Databases | Where-Object { $_.Verdict -eq 'OK' }).Count
    $check = @($Status.Databases | Where-Object { $_.Verdict -eq 'CHECK' }).Count
    $fail  = @($Status.Databases | Where-Object { $_.Verdict -eq 'FAIL' }).Count
    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host " $ok passed " -NoNewline -ForegroundColor Black -BackgroundColor Green
    if ($check) { Write-Host " $check to check " -NoNewline -ForegroundColor Black -BackgroundColor Yellow }
    if ($fail)  { Write-Host " $fail failed " -NoNewline -ForegroundColor White -BackgroundColor Red }
    Write-Host ("   of {0} database(s){1}" -f $Status.Databases.Count, $(if ($Quick) { ', catalogue only' } else { '' }))
    Write-Host ''

    if ($fail -or $Status.Issues.Count) { return 2 }
    if ($check) { return 1 }
    return 0
}

Register-MhSelfTest -Name 'Test-MhDatabaseStatus' -Test {
    function Db([hashtable] $Overrides) {
        $d = @{ Name = 'Test'; State = 'ONLINE'; UserAccess = 'MULTI_USER'; IsReadOnly = $false; IsAutoClose = $false
                IsInStandby = $false; SuspectPages = 0; AgRole = $null; AgSyncState = $null; AgHealth = $null
                AgSuspended = $false; AgSuspendReason = $null; Probe = 'ok'; ProbeError = $null }
        foreach ($k in $Overrides.Keys) { $d[$k] = $Overrides[$k] }
        [pscustomobject]$d
    }
    Test-MhSection 'the verdict it reaches about one database'
    $v = Get-DatabaseVerdict (Db @{});                                            Test-MhCheck 'a healthy database passes' ($v.Verdict -eq 'OK') $v.Verdict
    $v = Get-DatabaseVerdict (Db @{ State = 'SUSPECT' });                          Test-MhCheck 'suspect fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ State = 'RECOVERY_PENDING' });                 Test-MhCheck 'recovery pending fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ State = 'OFFLINE' });                          Test-MhCheck 'offline fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ State = 'RESTORING' });                        Test-MhCheck 'a half-finished restore fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ State = 'RESTORING'; IsInStandby = $true });   Test-MhCheck 'standby is only worth a look' ($v.Verdict -eq 'CHECK')
    $v = Get-DatabaseVerdict (Db @{ State = 'RESTORING'; AgRole = 'SECONDARY' });  Test-MhCheck 'an AG secondary restoring is normal' ($v.Verdict -eq 'CHECK')
    $v = Get-DatabaseVerdict (Db @{ UserAccess = 'SINGLE_USER' });                 Test-MhCheck 'single user fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ UserAccess = 'RESTRICTED_USER' });             Test-MhCheck 'restricted user fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ IsReadOnly = $true });                         Test-MhCheck 'read-only is worth a look' ($v.Verdict -eq 'CHECK')
        $v = Get-DatabaseVerdict (Db @{ IsAutoClose = $true })
    Test-MhCheck 'auto-close is a note, not a failure' ($v.Verdict -eq 'OK' -and $v.Notes.Count -eq 1)
    $v = Get-DatabaseVerdict (Db @{ SuspectPages = 3 });                           Test-MhCheck 'suspect pages fail' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ Probe = 'failed'; ProbeError = 'login failed' }); Test-MhCheck 'a failed connection fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ AgRole = 'PRIMARY'; AgSyncState = 'NOT SYNCHRONIZING' }); Test-MhCheck 'an AG not synchronising fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ AgRole = 'PRIMARY'; AgSyncState = 'SYNCHRONIZED'; AgSuspended = $true; AgSuspendReason = 'SUSPEND_FROM_USER' })
    Test-MhCheck 'suspended data movement fails' ($v.Verdict -eq 'FAIL')
    $v = Get-DatabaseVerdict (Db @{ AgRole = 'PRIMARY'; AgSyncState = 'SYNCHRONIZED'; AgHealth = 'HEALTHY' }); Test-MhCheck 'a healthy AG passes' ($v.Verdict -eq 'OK')
    $v = Get-DatabaseVerdict (Db @{ State = 'SUSPECT'; IsReadOnly = $true })
    Test-MhCheck 'a failure outranks something to look at' ($v.Verdict -eq 'FAIL')
    Test-MhCheck 'the reason is given, not just the verdict' ($v.Reasons.Count -ge 2) "$($v.Reasons.Count) reason(s)"
}
