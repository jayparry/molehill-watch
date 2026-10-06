<#
.SYNOPSIS
    Restores a database from one on-premises SQL Server to another, from the source server's own
    backup history. Skips a full backup that has already been restored, and can keep a copy rolling
    forward with log backups until you cut over to it.

.DESCRIPTION
    Two jobs, one script.

    1. REFRESH. "Restore the latest full backup of SRC.Sales onto DST, unless that same backup is
       already there." Safe to run on a schedule: it compares the backup set against the restore
       history on the destination and does nothing when it is already restored.

    2. ROLLING RESTORE - log shipping by hand, for moving a large database with minutes of
       downtime instead of hours. Restore it today with -KeepRestoring (or -Standby if you want to
       read it), then run the script again as often as you like to apply the log backups taken since.
       At cutover, -Cutover -TailLog takes the tail of the log from the source, applies it, and
       brings the copy online. The only downtime is that last log.

    Nothing is installed and nothing is needed on the servers. The chain is worked out from
    msdb.dbo.backupset on the SOURCE, so it follows whatever takes your backups. The RESTOREs run
    on the DESTINATION, which must be able to read the backup files - see -BackupPathMap if the
    paths differ, or let the script try the admin share (\\SOURCE\D$\...) by itself.

    The source is read-only unless you ask for -TailLog or -DisconnectSource, which are the two
    things that change it. Both say what they are about to do and ask first unless -Force is given.

    On-premises disk backups only: backup sets written to URL (Azure Blob Storage) or tape are
    ignored, and the script says so rather than pretending the chain is complete.

    WHAT IT CHECKS BEFORE RESTORING ANYTHING
      * the destination can read every file in the chain, and is not an older version of SQL Server
        than the backup was taken on
      * the database on the destination really is a copy of the source (restore history, then the
        backup family) before it overwrites it - an unrelated database of the same name needs -Force
      * the file paths it is about to write are not already in use by a different database
      * the log chain actually joins up, and says where it breaks if it does not

    Exit code: 0 = done or nothing to do, 1 = something to check, 2 = a failure.

.PARAMETER SourceInstance
    The instance whose backups you want, e.g. SQL01 or SQL01\SALES. Read-only: its msdb history.
    You are asked for it if it is left out.

.PARAMETER Database
    One or more database names as they are on the source.

.PARAMETER DestinationInstance
    The instance to restore onto. This is where the RESTORE statements run.

.PARAMETER DestinationDatabase
    Restore under a different name. One database at a time.

.PARAMETER DataPath
    Where to put the data files. Default: the destination instance's own default data path.

.PARAMETER LogPath
    Where to put the log file. Default: the destination instance's own default log path.

.PARAMETER KeepFilePaths
    Restore the files to the paths they had on the source, instead of relocating them.

.PARAMETER BackupPathMap
    Path translation for when the destination sees the backups somewhere else, e.g.
    @{ 'D:\Backup' = '\\SQL01\Backup$'; 'E:\Logs' = '\\SQL01\Logs$' }. Longest prefix wins.
    Scheduling it? powershell.exe -File turns every argument into a string, so a hashtable has to go
    through -Command instead: powershell -Command "& .\Restore-DatabaseCopy.ps1 ... -BackupPathMap @{...}".

.PARAMETER KeepRestoring
    Leave the copy in a restoring state so more log backups can be applied later. This is the
    rolling restore: run the script again whenever you want to catch up.

.PARAMETER Standby
    Like -KeepRestoring, but leave the copy readable between log restores (RESTORE ... WITH STANDBY).
    Handy for checking the data, and for proving to someone else that the copy is real.

.PARAMETER StandbyPath
    Folder for the standby undo file. Default: the destination's default data path.

.PARAMETER Cutover
    Apply everything outstanding and bring the copy online (WITH RECOVERY). Add -TailLog to take the
    last log off the source first. After this the copy is a normal database and no more logs can go on.

.PARAMETER TailLog
    At cutover, back up the tail of the log on the SOURCE with NORECOVERY and apply it. This leaves
    the source database in a restoring state - which is the point, nobody can write to it after the
    switch - and implies -Cutover. It asks first unless -Force.

.PARAMETER TailLogPath
    Folder for the tail log backup. Must be readable by the destination as well. Default: the
    source instance's default backup directory.

.PARAMETER DisconnectSource
    Before the tail log, kick everyone off the source database (SINGLE_USER WITH ROLLBACK IMMEDIATE)
    so nothing can write between the tail backup and the switch. Asks first unless -Force.

.PARAMETER DisconnectDestination
    Kill sessions using the copy if they are in the way of a restore. Readers of a -Standby copy
    will block it, so this is usually wanted with scheduled standby runs.

.PARAMETER StopAt
    Point in time to stop at, e.g. '2026-10-06 14:30'. Applies logs up to that moment (WITH STOPAT).

.PARAMETER NoDifferential
    Ignore differential backups, even when one would save time.

.PARAMETER HistoryDays
    How far back to read the source's backup history. Default 180 days.

.PARAMETER Force
    Overwrite a database on the destination that is not a copy of the source, and do not ask before
    touching the source (-TailLog, -DisconnectSource).

.PARAMETER SqlCredential
    SQL Server authentication for both instances. Windows authentication is used when left out.

.PARAMETER CsvPath
    Write one row per database, with the outcome, to a CSV file.

.EXAMPLE
    .\Restore-DatabaseCopy.ps1 -SourceInstance SQL01 -Database Sales -DestinationInstance SQL02
    # latest full (plus a differential if there is one), online, and nothing at all if it is already restored

.EXAMPLE
    # Monday: seed the copy, then catch it up whenever you like
    .\Restore-DatabaseCopy.ps1 SQL01 Sales SQL02 -KeepRestoring
    .\Restore-DatabaseCopy.ps1 SQL01 Sales SQL02 -KeepRestoring      # applies the logs since
    # Friday 18:00, the ten minutes that matter:
    .\Restore-DatabaseCopy.ps1 SQL01 Sales SQL02 -Cutover -TailLog -DisconnectSource

.EXAMPLE
    .\Restore-DatabaseCopy.ps1 SQL01 Sales SQL02 -StopAt '2026-10-06 09:15' -WhatIf
    # prints the exact RESTORE statements it would run, and nothing else

.NOTES
    Molehill Data Services. Needs SQL Server 2012 or later at both ends, VIEW SERVER STATE and the
    right to restore on the destination, and read access to msdb on the source.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)] [string] $SourceInstance,
    [Parameter(Position = 1)] [string[]] $Database,
    [Parameter(Position = 2)] [string] $DestinationInstance,
    [string] $DestinationDatabase,
    [string] $DataPath,
    [string] $LogPath,
    [switch] $KeepFilePaths,
    [hashtable] $BackupPathMap,
    [switch] $KeepRestoring,
    [switch] $Standby,
    [string] $StandbyPath,
    [switch] $Cutover,
    [switch] $TailLog,
    [string] $TailLogPath,
    [switch] $DisconnectSource,
    [switch] $DisconnectDestination,
    [datetime] $StopAt,
    [switch] $NoDifferential,
    [int] $HistoryDays = 180,
    [switch] $Force,
    [pscredential] $SqlCredential,
    [int] $ConnectTimeoutSeconds = 10,
    [string] $CsvPath,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$script:Messages = New-Object System.Collections.Generic.List[string]

#==============================================================================
# The decisions. Kept free of SQL Server so they can be tested on their own
# (-SelfTest) rather than only against a pair of live instances.
#==============================================================================

<#
  Works out what to restore.

  Seeding (nothing restored yet): the newest full, the newest differential that belongs to it, and
  then every log backup that carries the copy forward.

  Catching up (LastRestoredLsn given): logs only, from where the copy got to.

  The log walk is deliberately greedy rather than "everything in date order": at each step it takes
  the backup that reaches furthest forward. That copes with overlapping ranges, copy-only log
  backups and a second backup job logging to its own files, all of which are normal in the wild.
#>
function Select-BackupChain {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $BackupSets,
        $LastRestoredLsn,
        $StopAt,
        [switch] $NoDifferential,
        [string] $FamilyGuid
    )

    $result = [pscustomobject]@{
        Full = $null; Diff = $null; Logs = @(); StopAtSet = $null; Error = $null; Gap = $null
    }

    $sets = @($BackupSets)
    # a copy is only ever rolled forward by backups of the same database lineage: a source that was
    # itself restored, or detached and reattached, starts a new family and its logs will not apply
    if ($FamilyGuid) {
        $sets = @($sets | Where-Object { -not $_.FamilyGuid -or [string]$_.FamilyGuid -eq $FamilyGuid })
    }
    if ($StopAt) {
        $sets = @($sets | Where-Object { $_.Type -eq 'L' -or $_.FinishDate -le $StopAt })
    }

    $threshold = $null
    if ($null -ne $LastRestoredLsn) {
        $threshold = [decimal]$LastRestoredLsn
    }
    else {
        $full = @($sets | Where-Object { $_.Type -eq 'D' } | Sort-Object FinishDate, { [decimal]$_.LastLsn } | Select-Object -Last 1)
        if (-not $full) {
            $result.Error = if ($StopAt) { 'no full backup taken before that point in time' } else { 'no full backup in the source''s history' }
            return $result
        }
        $result.Full = $full[0]
        $threshold = [decimal]$full[0].LastLsn

        if (-not $NoDifferential) {
            # a differential belongs to a full when its database_backup_lsn matches that full's checkpoint_lsn
            $diff = @($sets | Where-Object {
                        $_.Type -eq 'I' -and
                        [decimal]$_.DatabaseBackupLsn -eq [decimal]$full[0].CheckpointLsn -and
                        [decimal]$_.LastLsn -gt $threshold } |
                      Sort-Object FinishDate, { [decimal]$_.LastLsn } | Select-Object -Last 1)
            if ($diff) { $result.Diff = $diff[0]; $threshold = [decimal]$diff[0].LastLsn }
        }
    }

    $logs = New-Object System.Collections.Generic.List[object]
    $allLogs = @($sets | Where-Object { $_.Type -eq 'L' })
    while ($true) {
        $next = @($allLogs | Where-Object { [decimal]$_.FirstLsn -le $threshold -and [decimal]$_.LastLsn -gt $threshold } |
                  Sort-Object { [decimal]$_.LastLsn } | Select-Object -Last 1)
        if (-not $next) { break }
        $logs.Add($next[0])
        $threshold = [decimal]$next[0].LastLsn
        if ($StopAt -and $next[0].FinishDate -ge $StopAt) { $result.StopAtSet = $next[0]; break }
    }
    $result.Logs = $logs.ToArray()

    # anything still ahead of us that we could not reach means the chain is broken, which is worth
    # saying plainly: somebody has taken a log backup that is not in this history, or truncated it
    if (-not $result.StopAtSet) {
        $ahead = @($allLogs | Where-Object { [decimal]$_.LastLsn -gt $threshold } | Sort-Object { [decimal]$_.FirstLsn })
        if ($ahead.Count) {
            $detail = 'the next log backup in the history starts at LSN {0} but the copy needs one that covers LSN {1} ({2})' -f
                      $ahead[0].FirstLsn, $threshold, (Split-Path -Leaf ([string]$ahead[0].Files[0]))
            if ($logs.Count -eq 0 -and $null -ne $LastRestoredLsn) { $result.Error = "the log chain is broken: $detail" }
            else { $result.Gap = $detail }
        }
    }

    $result
}

<#
  Translates a backup path for the destination. -BackupPathMap first (longest prefix wins), then,
  for a local path on another machine, the admin share - which is what you reach for by hand anyway.
#>
function Resolve-BackupPath {
    [CmdletBinding()]
    param([string] $Path, [hashtable] $Map)

    if ($Map) {
        foreach ($key in ($Map.Keys | Sort-Object { $_.Length } -Descending)) {
            if ($Path.StartsWith($key, [StringComparison]::OrdinalIgnoreCase)) {
                return ($Map[$key].TrimEnd('\') + $Path.Substring($key.Length))
            }
        }
    }
    $Path
}

function Get-AdminSharePath {
    [CmdletBinding()]
    param([string] $Path, [string] $SourceHost)

    if (-not $SourceHost -or $Path -notmatch '^[A-Za-z]:\\') { return $null }
    '\\{0}\{1}$\{2}' -f $SourceHost, $Path.Substring(0, 1), $Path.Substring(3)
}

# [db] / 'string' the long way round, because a database called O'Brien]x is still a database
function Esc-Name([string] $Name) { '[' + ($Name -replace '\]', ']]') + ']' }
function Esc-Str([string] $Text) { $Text -replace "'", "''" }

<#
  Builds one RESTORE statement. Separate from running it so that -WhatIf can print exactly what
  would have run, and so the self test can check the awkward parts (file positions, MOVE, STOPAT).
#>
function New-RestoreCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Database,
        [Parameter(Mandatory)] $BackupSet,          # Files, Position, HasChecksums
        [ValidateSet('Database', 'Log')] [string] $Kind = 'Database',
        [ValidateSet('NORECOVERY', 'RECOVERY', 'STANDBY')] [string] $Finish = 'NORECOVERY',
        [string] $StandbyFile,
        $MoveList,                                   # @{ LogicalName = TargetPath }
        [switch] $Replace,
        $StopAt
    )

    $verb = if ($Kind -eq 'Log') { 'RESTORE LOG' } else { 'RESTORE DATABASE' }
    $devices = (@($BackupSet.Files) | ForEach-Object { "DISK = N'" + (Esc-Str $_) + "'" }) -join ",`r`n     "

    $with = New-Object System.Collections.Generic.List[string]
    $with.Add('FILE = ' + [int]$BackupSet.Position)
    if ($MoveList) {
        foreach ($logical in ($MoveList.Keys | Sort-Object)) {
            $with.Add("MOVE N'" + (Esc-Str $logical) + "' TO N'" + (Esc-Str $MoveList[$logical]) + "'")
        }
    }
    if ($Replace) { $with.Add('REPLACE') }
    switch ($Finish) {
        'NORECOVERY' { $with.Add('NORECOVERY') }
        'RECOVERY'   { $with.Add('RECOVERY') }
        'STANDBY'    { $with.Add("STANDBY = N'" + (Esc-Str $StandbyFile) + "'") }
    }
    if ($StopAt) { $with.Add("STOPAT = N'" + $StopAt.ToString('yyyy-MM-ddTHH:mm:ss') + "'") }
    if ($BackupSet.HasChecksums) { $with.Add('CHECKSUM') }
    $with.Add('STATS = 5')

    "{0} {1}`r`nFROM {2}`r`nWITH {3};" -f $verb, (Esc-Name $Database), $devices, ($with -join ",`r`n     ")
}

# the target path for one file out of the backup, data and log kept apart, FILESTREAM to its folder
function Get-MoveTarget {
    [CmdletBinding()]
    param([string] $PhysicalName, [string] $FileType, [string] $DataPath, [string] $LogPath,
          [string] $SourceDatabase, [string] $DestinationDatabase)

    $leaf = Split-Path -Leaf $PhysicalName
    # a copy restored next to the original must not be called the same thing on disk
    if ($SourceDatabase -and $DestinationDatabase -and $SourceDatabase -ne $DestinationDatabase -and
        $leaf.StartsWith($SourceDatabase, [StringComparison]::OrdinalIgnoreCase)) {
        $leaf = $DestinationDatabase + $leaf.Substring($SourceDatabase.Length)
    }
    $folder = if ($FileType -eq 'L') { $LogPath } else { $DataPath }
    ($folder.TrimEnd('\') + '\' + $leaf)
}

#==============================================================================
# Self test
#==============================================================================
if ($SelfTest) {
    $script:failed = 0
    function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    $t0 = Get-Date '2026-10-05 22:00'
    function Set_([string]$Type, [int]$First, [int]$Last, [int]$Mins, [hashtable]$More = @{}) {
        $o = @{ Type = $Type; FirstLsn = [decimal]$First; LastLsn = [decimal]$Last
                CheckpointLsn = [decimal]$First; DatabaseBackupLsn = [decimal]0
                FinishDate = $t0.AddMinutes($Mins); Position = 1; HasChecksums = $true
                Files = @('D:\B\f.bak'); FamilyGuid = 'FAM1'; Uuid = [guid]::NewGuid().ToString() }
        foreach ($k in $More.Keys) { $o[$k] = $More[$k] }
        [pscustomobject]$o
    }

    Write-Host 'Restore-DatabaseCopy self test'
    Write-Host '  the chain' -ForegroundColor Gray

    $full1 = Set_ 'D' 100 200 0
    $full2 = Set_ 'D' 500 600 600
    $diff  = Set_ 'I' 600 700 630 @{ DatabaseBackupLsn = [decimal]500 }
    $log1  = Set_ 'L' 200 300 60
    $log2  = Set_ 'L' 300 400 120
    $log3  = Set_ 'L' 600 700 660
    $log4  = Set_ 'L' 700 800 700
    $log5  = Set_ 'L' 800 900 760

    $c = Select-BackupChain -BackupSets @($full1, $full2, $log1, $log2) -NoDifferential
    Check 'takes the newest full' ($c.Full -eq $full2)
    Check 'and no logs that predate it' ($c.Logs.Count -eq 0)

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2)
    Check 'follows the logs after the full' ($c.Logs.Count -eq 2 -and $c.Logs[0] -eq $log1 -and $c.Logs[1] -eq $log2)

    $c = Select-BackupChain -BackupSets @($full2, $diff, $log3, $log4, $log5)
    Check 'uses the differential that belongs to the full' ($c.Diff -eq $diff)
    Check 'and skips the logs the differential already covers' ($c.Logs.Count -eq 2 -and $c.Logs[0] -eq $log4)

    $c = Select-BackupChain -BackupSets @($full2, $diff, $log3, $log4, $log5) -NoDifferential
    Check '-NoDifferential goes the long way round' ($null -eq $c.Diff -and $c.Logs.Count -eq 3)

    $orphan = Set_ 'I' 600 700 630 @{ DatabaseBackupLsn = [decimal]999 }
    $c = Select-BackupChain -BackupSets @($full2, $orphan)
    Check 'ignores a differential from another full' ($null -eq $c.Diff)

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2) -LastRestoredLsn ([decimal]300)
    Check 'catching up applies only the new logs' ($null -eq $c.Full -and $c.Logs.Count -eq 1 -and $c.Logs[0] -eq $log2)

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2) -LastRestoredLsn ([decimal]400)
    Check 'nothing new is not an error' ($c.Logs.Count -eq 0 -and $null -eq $c.Error -and $null -eq $c.Gap)

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log5) -LastRestoredLsn ([decimal]300)
    Check 'a broken chain is an error, not a surprise later' ($null -ne $c.Error) $c.Error

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2, $log5)
    Check 'a gap mid-chain restores what it can' ($c.Logs.Count -eq 2 -and $null -ne $c.Gap)

    $wide = Set_ 'L' 200 400 90      # one log covering the same ground as two others
    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2, $wide)
    Check 'prefers the backup that reaches furthest' ($c.Logs.Count -eq 1 -and $c.Logs[0] -eq $wide)

    $c = Select-BackupChain -BackupSets @($full1, $log1, $log2) -StopAt $t0.AddMinutes(90)
    Check 'stops at a point in time' ($c.Logs.Count -eq 2 -and $c.StopAtSet -eq $log2)

    $c = Select-BackupChain -BackupSets @($full2, $full1, $log1) -StopAt $t0.AddMinutes(90)
    Check 'and seeds from the full that was taken before it' ($c.Full -eq $full1)

    $c = Select-BackupChain -BackupSets @()
    Check 'no backups at all says so' ($null -ne $c.Error)

    $other = Set_ 'L' 300 400 120 @{ FamilyGuid = 'FAM2' }
    $c = Select-BackupChain -BackupSets @($full1, $log1, $other) -FamilyGuid 'FAM1'
    Check 'ignores backups of a different database lineage' ($c.Logs.Count -eq 1)

    Write-Host '  the statements' -ForegroundColor Gray
    $sql = New-RestoreCommand -Database 'Sales Copy' -BackupSet (Set_ 'D' 1 2 0 @{ Position = 3; Files = @('D:\B\a.bak', 'D:\B\b.bak') }) `
                              -MoveList @{ 'Sales' = 'E:\Data\SalesCopy.mdf'; 'Sales_log' = 'F:\Log\SalesCopy.ldf' } -Finish 'NORECOVERY'
    Check 'striped backups list every file' (($sql -split 'DISK =').Count -eq 3)
    Check 'the backup set position is used' ($sql -match 'FILE = 3')
    Check 'files are relocated' ($sql -match "MOVE N'Sales' TO N'E:\\Data\\SalesCopy\.mdf'")
    Check 'the database name is bracketed' ($sql -match '\[Sales Copy\]')
    Check 'left restoring when asked' ($sql -match 'NORECOVERY' -and $sql -notmatch 'STANDBY')
    Check 'checksums are verified when the backup has them' ($sql -match 'CHECKSUM')

    $sql = New-RestoreCommand -Database 'Sales' -Kind 'Log' -BackupSet (Set_ 'L' 1 2 0) -Finish 'RECOVERY' -StopAt $t0
    Check 'a log restore is a RESTORE LOG' ($sql -match '^RESTORE LOG')
    Check 'point in time becomes STOPAT' ($sql -match "STOPAT = N'2026-10-05T22:00:00'")

    $sql = New-RestoreCommand -Database 'Sales' -BackupSet (Set_ 'D' 1 2 0) -Finish 'STANDBY' -StandbyFile 'E:\Data\Sales.standby' -Replace
    Check 'standby names its undo file' ($sql -match "STANDBY = N'E:\\Data\\Sales\.standby'")
    Check 'REPLACE only when asked for' ($sql -match 'REPLACE')

    $sql = New-RestoreCommand -Database "O'Brien" -BackupSet (Set_ 'D' 1 2 0 @{ Files = @("D:\B\o'b.bak") })
    Check 'quotes and brackets are escaped' ($sql -match "\[O'Brien\]" -and $sql -match "o''b\.bak")

    Write-Host '  paths' -ForegroundColor Gray
    $map = @{ 'D:\Backup' = '\\SQL01\Backup$'; 'D:\Backup\Logs' = '\\SQL01\Logs$' }
    Check 'the longest matching prefix wins' ((Resolve-BackupPath -Path 'D:\Backup\Logs\a.trn' -Map $map) -eq '\\SQL01\Logs$\a.trn')
    Check 'other paths map too' ((Resolve-BackupPath -Path 'D:\Backup\a.bak' -Map $map) -eq '\\SQL01\Backup$\a.bak')
    Check 'an unmapped path is left alone' ((Resolve-BackupPath -Path 'E:\Other\a.bak' -Map $map) -eq 'E:\Other\a.bak')
    Check 'the admin share is the fallback' ((Get-AdminSharePath -Path 'D:\Backup\a.bak' -SourceHost 'SQL01') -eq '\\SQL01\D$\Backup\a.bak')
    Check 'a UNC path has no admin share form' ($null -eq (Get-AdminSharePath -Path '\\x\y\a.bak' -SourceHost 'SQL01'))

    Check 'data files go to the data path' ((Get-MoveTarget -PhysicalName 'X:\old\Sales.mdf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log') -eq 'E:\Data\Sales.mdf')
    Check 'log files go to the log path' ((Get-MoveTarget -PhysicalName 'X:\old\Sales_log.ldf' -FileType 'L' -DataPath 'E:\Data' -LogPath 'F:\Log') -eq 'F:\Log\Sales_log.ldf')
    Check 'a renamed copy gets renamed files' ((Get-MoveTarget -PhysicalName 'X:\old\Sales.mdf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log' -SourceDatabase 'Sales' -DestinationDatabase 'SalesTest') -eq 'E:\Data\SalesTest.mdf')
    Check 'an unrelated file name is kept' ((Get-MoveTarget -PhysicalName 'X:\old\extra1.ndf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log' -SourceDatabase 'Sales' -DestinationDatabase 'SalesTest') -eq 'E:\Data\extra1.ndf')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Talking to SQL Server
#==============================================================================
function New-ConnectionString([string] $Server, [string] $DatabaseName, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $DatabaseName
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Restore-DatabaseCopy'
    $b['TrustServerCertificate'] = $true
    if ($SqlCredential) {
        $b['User ID'] = $SqlCredential.UserName
        $b['Password'] = $SqlCredential.GetNetworkCredential().Password
    }
    else { $b['Integrated Security'] = $true }
    $b.ConnectionString
}

function Invoke-Sql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')

    $connection = New-Object System.Data.SqlClient.SqlConnection (New-ConnectionString $Server $DatabaseName $ConnectTimeoutSeconds)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 120
        if ($Parameters) { foreach ($k in $Parameters.Keys) { [void]$command.Parameters.AddWithValue($k, $Parameters[$k]) } }
        $table = New-Object System.Data.DataTable
        [void](New-Object System.Data.SqlClient.SqlDataAdapter $command).Fill($table)
        , $table
    }
    finally { $connection.Dispose() }
}

function Get-Scalar {
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')
    $t = Invoke-Sql -Server $Server -Query $Query -Parameters $Parameters -DatabaseName $DatabaseName
    if ($t.Rows.Count -eq 0) { return $null }
    $v = $t.Rows[0][0]
    if ($v -is [DBNull]) { $null } else { $v }
}

<#
  Runs a RESTORE or BACKUP and shows it moving. SQL Server reports progress as informational
  messages ("40 percent processed."), which arrive on the connection's InfoMessage event, so one
  connection does the work and the reporting - no polling from a second session.
#>
function Invoke-LongRunningSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Sql, [string] $Label)

    $script:Messages.Clear()
    $script:LastPercent = -1
    $quiet = [Console]::IsOutputRedirected
    $connection = New-Object System.Data.SqlClient.SqlConnection (New-ConnectionString $Server 'master' $ConnectTimeoutSeconds)
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($sender, $e)
        foreach ($err in $e.Errors) {
            $text = [string]$err.Message
            $script:Messages.Add($text)
            if ($text -match '(\d+) percent processed') {
                $pct = [int]$Matches[1]
                if ($pct -gt $script:LastPercent) {
                    $script:LastPercent = $pct
                    if ($script:QuietProgress) {
                        if ($pct % 25 -eq 0) { Write-Host ("    {0,-12} {1}  {2}%" -f '', $script:ProgressLabel, $pct) -ForegroundColor DarkGray }
                    }
                    else {
                        Write-Host ("`r    {0,-12} {1} {2,3}%  " -f '', $script:ProgressLabel, $pct) -NoNewline -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
    $script:QuietProgress = $quiet
    $script:ProgressLabel = $Label

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connection.add_InfoMessage($handler)
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        $command.CommandTimeout = 0        # a big restore takes as long as it takes
        [void]$command.ExecuteNonQuery()
        $watch.Stop()
        if (-not $quiet -and $script:LastPercent -ge 0) { Write-Host "`r$(' ' * 60)`r" -NoNewline }

        # "RESTORE DATABASE successfully processed 134518 pages in 8.714 seconds (120.586 MB/sec)."
        $summary = @($script:Messages | Where-Object { $_ -match 'successfully processed' }) | Select-Object -Last 1
        $mb = $null
        if ($summary -match 'processed (\d+) pages') { $mb = [math]::Round(([double]$Matches[1] * 8KB) / 1MB, 0) }
        [pscustomobject]@{
            Ok = $true; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Megabytes = $mb
            Message = $summary; Error = $null
        }
    }
    catch {
        $watch.Stop()
        if (-not $quiet -and $script:LastPercent -ge 0) { Write-Host "`r$(' ' * 60)`r" -NoNewline }
        [pscustomobject]@{
            Ok = $false; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Megabytes = $null
            Message = $null; Error = ($_.Exception.GetBaseException().Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' '
        }
    }
    finally { $connection.Dispose() }
}

#==============================================================================
# Reporting
#==============================================================================
<#
  Asks before something there is no undo for. A scheduled run has no console to ask at, so rather
  than failing with PowerShell's own "NonInteractive mode" message it says what to pass instead.
#>
function Confirm-Action([string] $Message, [string] $Caption) {
    if ($Force -or $dryRun) { return $true }
    try { return $PSCmdlet.ShouldContinue($Message, $Caption) }
    catch {
        # the only way asking fails is having nobody to ask
        throw 'this would change a database and there is no console to confirm at. Run it where it can ask, or pass -Force when you already know you mean it.'
    }
}

function Write-Step([string] $Label, [string] $Text, [string] $Colour = 'Gray') {
    Write-Host ("    {0,-12} " -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor $Colour
}
function Write-Result([string] $Verdict, [string] $Text) {
    $colour = switch ($Verdict) { 'PASS' { 'Green' } 'CHECK' { 'Yellow' } default { 'Red' } }
    Write-Host ('  ' + $Verdict.PadRight(5) + ' ') -NoNewline -ForegroundColor Black -BackgroundColor $colour
    Write-Host " $Text"
}
function Format-Size([double] $Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:n1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:n1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n0} MB' -f ($Bytes / 1MB)) }
    '{0:n0} KB' -f ($Bytes / 1KB)
}

#==============================================================================
# Queries
#==============================================================================
$SourceHistoryQuery = @"
SELECT  bs.backup_set_id, bs.backup_set_uuid, bs.type, bs.position,
        bs.first_lsn, bs.last_lsn, bs.checkpoint_lsn, bs.database_backup_lsn,
        bs.backup_start_date, bs.backup_finish_date, bs.database_name, bs.family_guid,
        bs.is_copy_only, bs.has_backup_checksums, bs.backup_size, bs.compressed_backup_size,
        bs.software_major_version, bs.recovery_model, bs.key_algorithm, bs.encryptor_type,
        mf.physical_device_name, mf.family_sequence_number
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id AND mf.mirror = 0
WHERE bs.database_name = @db
  AND bs.is_damaged = 0
  AND bs.backup_finish_date >= DATEADD(day, -@days, SYSDATETIME())
  AND mf.device_type IN (2, 102)        -- disk and logical disk device: on-premises only
ORDER BY bs.backup_finish_date, bs.backup_set_id, mf.family_sequence_number;
"@

# backup sets this script cannot use, so a hole in the chain can be explained rather than guessed at
$SourceOffDiskQuery = @"
SELECT Kinds = COUNT(*), Latest = MAX(bs.backup_finish_date),
       Devices = STUFF((SELECT DISTINCT ', ' + CASE mf2.device_type WHEN 7 THEN 'tape' WHEN 9 THEN 'URL' WHEN 109 THEN 'URL' ELSE 'device ' + CONVERT(varchar(5), mf2.device_type) END
                        FROM msdb.dbo.backupset bs2
                        JOIN msdb.dbo.backupmediafamily mf2 ON mf2.media_set_id = bs2.media_set_id
                        WHERE bs2.database_name = @db AND mf2.device_type NOT IN (2, 102)
                          AND bs2.backup_finish_date >= DATEADD(day, -@days, SYSDATETIME())
                        FOR XML PATH('')), 1, 2, '')
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id
WHERE bs.database_name = @db AND mf.device_type NOT IN (2, 102)
  AND bs.backup_finish_date >= DATEADD(day, -@days, SYSDATETIME());
"@

$DestDatabaseQuery = @"
SELECT  d.name, d.state_desc, d.user_access_desc, d.is_read_only, d.is_in_standby,
        drs.family_guid, drs.database_guid
FROM sys.databases d
LEFT JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.name = @db;
"@

$DestRestoreHistoryQuery = @"
SELECT TOP (1) rh.restore_date, rh.restore_type, bs.type, bs.last_lsn, bs.backup_set_uuid,
               bs.backup_finish_date, bs.database_name, bs.family_guid
FROM msdb.dbo.restorehistory rh
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = @db
ORDER BY rh.restore_history_id DESC;
"@

$DestAlreadyRestoredQuery = @"
SELECT TOP (1) rh.restore_date, bs.backup_finish_date
FROM msdb.dbo.restorehistory rh
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name = @db AND bs.backup_set_uuid = @uuid
ORDER BY rh.restore_history_id DESC;
"@

#==============================================================================
# Getting started
#==============================================================================
if (-not $SourceInstance) {
    Write-Host ''
    Write-Host '  Restore a database copy' -ForegroundColor Cyan
    Write-Host '  Reads the source''s backup history and restores onto another instance.' -ForegroundColor Gray
    Write-Host ''
    $SourceInstance = Read-Host '  Source instance (the backups came from here)'
}
if (-not $Database) {
    $answer = Read-Host '  Database (comma separated for more than one)'
    $Database = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $DestinationInstance) { $DestinationInstance = Read-Host '  Destination instance (the restore runs here)' }
if (-not $SourceInstance -or -not $Database -or -not $DestinationInstance) {
    Write-Host '  Need a source, a database and a destination.' -ForegroundColor Yellow
    exit 1
}

if ($TailLog -and -not $Cutover) { $Cutover = $true }
if ($DisconnectSource -and -not $TailLog) { Write-Host '  -DisconnectSource is for the cutover: add -TailLog.' -ForegroundColor Red; exit 2 }
if ($Cutover -and ($KeepRestoring -or $Standby)) { Write-Host '  -Cutover brings the copy online; -KeepRestoring and -Standby keep it offline. Pick one.' -ForegroundColor Red; exit 2 }
if ($DestinationDatabase -and $Database.Count -gt 1) { Write-Host '  -DestinationDatabase renames one database, so pass one -Database.' -ForegroundColor Red; exit 2 }
if ($Standby) { $KeepRestoring = $true }
$stopAtValue = if ($PSBoundParameters.ContainsKey('StopAt')) { $StopAt } else { $null }
$dryRun = $WhatIfPreference -eq $true

$startedAt = Get-Date
Write-Host ''
Write-Host '  Restore database copy  ' -NoNewline -ForegroundColor Black -BackgroundColor Cyan
Write-Host ("  {0} -> {1}   {2}" -f $SourceInstance, $DestinationInstance, $startedAt.ToString('ddd dd MMM HH:mm'))
if ($dryRun) { Write-Host '  -WhatIf: the statements below are printed, not run.' -ForegroundColor Yellow }
Write-Host ''

# --------------------------------------------------------------- the two ends
try {
    $srcInfo = (Invoke-Sql -Server $SourceInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), MachineName = CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), BackupDir = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultBackupPath'))").Rows[0]
}
catch {
    Write-Host ("  Cannot read the source {0}: {1}" -f $SourceInstance, $_.Exception.GetBaseException().Message) -ForegroundColor Red
    exit 2
}
try {
    $dstInfo = (Invoke-Sql -Server $DestinationInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), DataPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), LogPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath'))").Rows[0]
}
catch {
    Write-Host ("  Cannot read the destination {0}: {1}" -f $DestinationInstance, $_.Exception.GetBaseException().Message) -ForegroundColor Red
    exit 2
}

$sourceHost = [string]$srcInfo['MachineName']
if ([string]$srcInfo['ServerName'] -eq [string]$dstInfo['ServerName'] -and -not $DestinationDatabase) {
    Write-Host '  The source and the destination are the same instance, so the copy needs -DestinationDatabase.' -ForegroundColor Red
    exit 2
}

# where files go, if we are relocating them
$defaultData = [string]$dstInfo['DataPath']
$defaultLog  = [string]$dstInfo['LogPath']
if (-not $defaultData -or -not $defaultLog) {
    # older instances leave those properties empty: master's own files are the next best guess
    $mf = Invoke-Sql -Server $DestinationInstance -Query "SELECT Type = type_desc, Path = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name))) FROM sys.master_files WHERE database_id = 1"
    foreach ($r in $mf.Rows) {
        if (-not $defaultData -and [string]$r['Type'] -eq 'ROWS') { $defaultData = [string]$r['Path'] }
        if (-not $defaultLog  -and [string]$r['Type'] -eq 'LOG')  { $defaultLog  = [string]$r['Path'] }
    }
}
if ($DataPath) { $defaultData = $DataPath }
if ($LogPath)  { $defaultLog  = $LogPath }
if (-not $StandbyPath) { $StandbyPath = $defaultData }

# can the destination see a given file? xp_fileexist is the only way to ask it, and it may be denied
$script:FileCheckWorks = $true
function Test-DestinationFile([string] $Path) {
    if (-not $script:FileCheckWorks) { return $true }
    try {
        $sql = "DECLARE @r TABLE (FileExists bit, IsDir bit, ParentExists bit);
                INSERT @r EXEC master.dbo.xp_fileexist @p;
                SELECT TOP (1) FileExists FROM @r;"
        [bool](Get-Scalar -Server $DestinationInstance -Query $sql -Parameters @{ '@p' = $Path })
    }
    catch { $script:FileCheckWorks = $false; $true }
}

$results = New-Object System.Collections.Generic.List[object]

#==============================================================================
# One database at a time
#==============================================================================
foreach ($dbName in $Database) {
    $dstName = if ($DestinationDatabase) { $DestinationDatabase } else { $dbName }
    $result = [pscustomobject]@{
        SourceInstance = $SourceInstance; Database = $dbName
        DestinationInstance = $DestinationInstance; DestinationDatabase = $dstName
        Verdict = 'PASS'; Action = ''; Detail = ''; RestoredTo = $null; Seconds = 0
    }
    Write-Host ("  {0}{1}" -f $dbName, $(if ($dstName -ne $dbName) { " -> $dstName" } else { '' })) -ForegroundColor White

    try {
        # ---------------------------------------------------------- the source
        $history = Invoke-Sql -Server $SourceInstance -Query $SourceHistoryQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
        if ($history.Rows.Count -eq 0) {
            $offDisk = Invoke-Sql -Server $SourceInstance -Query $SourceOffDiskQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
            $extra = ''
            if ($offDisk.Rows.Count -and [int]$offDisk.Rows[0]['Kinds'] -gt 0) {
                $extra = ' Its backups go to {0}, which this script does not restore from (on-premises disk only).' -f $offDisk.Rows[0]['Devices']
            }
            throw ("no disk backups of {0} in the last {1} days on {2}.{3}" -f $dbName, $HistoryDays, $SourceInstance, $extra)
        }

        # one row per media family, so fold the stripes back into one backup set each
        $sets = @()
        foreach ($group in ($history.Rows | Group-Object { $_['backup_set_id'] })) {
            $first = $group.Group[0]
            $sets += [pscustomobject]@{
                SetId        = [int]$first['backup_set_id']
                Uuid         = [string]$first['backup_set_uuid']
                Type         = [string]$first['type']
                Position     = [int]$first['position']
                FirstLsn     = [decimal]$first['first_lsn']
                LastLsn      = [decimal]$first['last_lsn']
                CheckpointLsn     = [decimal]$first['checkpoint_lsn']
                DatabaseBackupLsn = if ($first['database_backup_lsn'] -is [DBNull]) { [decimal]0 } else { [decimal]$first['database_backup_lsn'] }
                StartDate    = [datetime]$first['backup_start_date']
                FinishDate   = [datetime]$first['backup_finish_date']
                FamilyGuid   = [string]$first['family_guid']
                IsCopyOnly   = [bool]$first['is_copy_only']
                HasChecksums = [bool]$first['has_backup_checksums']
                Size         = [double]$first['backup_size']
                Major        = [int]$first['software_major_version']
                Encrypted    = -not ($first['key_algorithm'] -is [DBNull])
                Files        = @($group.Group | Sort-Object { [int]$_['family_sequence_number'] } | ForEach-Object { [string]$_['physical_device_name'] })
            }
        }

        # ----------------------------------------------------- the destination
        $existing = $null
        $dstRow = Invoke-Sql -Server $DestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }
        if ($dstRow.Rows.Count) { $existing = $dstRow.Rows[0] }

        $lastRestore = $null
        $historyRow = Invoke-Sql -Server $DestinationInstance -Query $DestRestoreHistoryQuery -Parameters @{ '@db' = $dstName }
        if ($historyRow.Rows.Count) { $lastRestore = $historyRow.Rows[0] }

        $state = if ($existing) { [string]$existing['state_desc'] } else { 'ABSENT' }
        $inStandby = $existing -and [bool]$existing['is_in_standby']
        # a standby copy is reported ONLINE with is_in_standby set, not RESTORING - but it is still
        # mid-restore and still takes more log backups, which is the whole point of standby
        $isRestoring = ($state -eq 'RESTORING') -or $inStandby
        $dstFamily = if ($existing -and -not ($existing['family_guid'] -is [DBNull])) { ([guid]$existing['family_guid']).ToString() } else { $null }

        Write-Step 'source' ('{0}, {1} backup set(s) on disk, newest {2}' -f $SourceInstance, $sets.Count,
                             (($sets | Sort-Object FinishDate | Select-Object -Last 1).FinishDate.ToString('dd MMM HH:mm')))
        Write-Step 'destination' $(
            if (-not $existing) { 'the database is not there yet' }
            elseif ($isRestoring) {
                '{0}{1}' -f $(if ($inStandby) { 'standby, readable, mid-restore' } else { 'restoring' }),
                            $(if ($lastRestore) { ', last restore ' + ([datetime]$lastRestore['restore_date']).ToString('dd MMM HH:mm') } else { '' })
            }
            else { '{0}, {1}' -f $state.ToLower(), [string]$existing['user_access_desc'] }
        )

        # is this database on the destination a copy of that source database, or someone else's?
        $isCopy = $false
        if ($existing) {
            if ($lastRestore -and [string]$lastRestore['database_name'] -eq $dbName) { $isCopy = $true }
            elseif ($dstFamily) { $isCopy = @($sets | Where-Object { $_.FamilyGuid -eq $dstFamily }).Count -gt 0 }
        }

        # ------------------------------------------- has it been restored already?
        $latestFull = @($sets | Where-Object { $_.Type -eq 'D' } | Sort-Object FinishDate | Select-Object -Last 1)
        if ($latestFull.Count -eq 0) { throw 'no full backup in the source''s disk history, so there is nothing to restore from' }
        $latestFull = $latestFull[0]

        $alreadyRow = $null
        $already = Invoke-Sql -Server $DestinationInstance -Query $DestAlreadyRestoredQuery -Parameters @{ '@db' = $dstName; '@uuid' = $latestFull.Uuid }
        if ($already.Rows.Count) { $alreadyRow = $already.Rows[0] }

        # the plain refresh: same full already here, nothing asked for on top of it
        if ($alreadyRow -and $existing -and -not $isRestoring -and -not $KeepRestoring -and -not $Cutover -and -not $stopAtValue -and -not $Force) {
            Write-Step 'plan' ('the full backup of {0} was restored here {1}' -f
                               ([datetime]$alreadyRow['backup_finish_date']).ToString('dd MMM HH:mm'),
                               ([datetime]$alreadyRow['restore_date']).ToString('dd MMM HH:mm')) 'Green'
            Write-Result 'PASS' 'already restored - nothing to do'
            $result.Action = 'SkippedAlreadyRestored'
            $result.Detail = 'full backup of {0} restored here {1}' -f ([datetime]$alreadyRow['backup_finish_date']), ([datetime]$alreadyRow['restore_date'])
            $results.Add($result); Write-Host ''
            continue
        }

        # ------------------------------------------------------ seed or catch up?
        $lastRestoredLsn = $null
        if ($isRestoring) {
            if (-not $lastRestore) {
                throw 'the copy is mid-restore but this instance has no restore history for it (msdb cleared?), so there is no safe way to know which log comes next - restore it again from a full backup with -Force'
            }
            $lastRestoredLsn = [decimal]$lastRestore['last_lsn']
        }
        elseif ($existing -and ($Cutover -or $KeepRestoring) -and $alreadyRow -and -not $Force) {
            # online copy, and they have asked for more logs: it is recovered, the chain is finished
            Write-Step 'plan' 'the copy is already online, so no more log backups can be applied to it' 'Yellow'
            Write-Result 'CHECK' 'already online - restore it again with -Force to start a new copy'
            $result.Verdict = 'CHECK'; $result.Action = 'AlreadyOnline'
            $result.Detail = 'the copy is recovered; a new full restore is needed to roll it forward again'
            $results.Add($result); Write-Host ''
            continue
        }

        if ($existing -and -not $isRestoring -and -not $isCopy -and -not $Force) {
            throw ("{0} on {1} is not a copy of {2} (no restore history for it, and the backup family does not match), so it has not been touched. Use -Force to overwrite it anyway." -f $dstName, $DestinationInstance, $dbName)
        }

        $chain = Select-BackupChain -BackupSets $sets -LastRestoredLsn $lastRestoredLsn -StopAt $stopAtValue `
                                    -NoDifferential:$NoDifferential -FamilyGuid $(if ($isRestoring) { $dstFamily } else { $null })
        if ($chain.Error) { throw $chain.Error }

        $toRestore = New-Object System.Collections.Generic.List[object]
        if ($chain.Full) { $toRestore.Add([pscustomobject]@{ Set = $chain.Full; Kind = 'Database'; Label = 'full' }) }
        if ($chain.Diff) { $toRestore.Add([pscustomobject]@{ Set = $chain.Diff; Kind = 'Database'; Label = 'differential' }) }
        $n = 0
        foreach ($log in $chain.Logs) {
            $n++
            $toRestore.Add([pscustomobject]@{ Set = $log; Kind = 'Log'; Label = ('log {0}/{1}' -f $n, $chain.Logs.Count) })
        }

        # ------------------------------------------------------------ the tail log
        $tailSet = $null
        if ($TailLog) {
            $folder = if ($TailLogPath) { $TailLogPath } else { [string]$srcInfo['BackupDir'] }
            if (-not $folder) { throw 'nowhere to put the tail log backup: pass -TailLogPath' }
            $tailFile = '{0}\{1}_tail_{2}.trn' -f $folder.TrimEnd('\'), $dbName, (Get-Date).ToString('yyyyMMdd_HHmmss')
            $tailSet = [pscustomobject]@{ Position = 1; Files = @($tailFile); HasChecksums = $true }
        }

        # --------------------------------------------------------------- the plan
        $plan = New-Object System.Collections.Generic.List[string]
        if ($chain.Full) { $plan.Add('full of ' + $chain.Full.FinishDate.ToString('dd MMM HH:mm') + ' (' + (Format-Size $chain.Full.Size) + ')') }
        if ($chain.Diff) { $plan.Add('differential of ' + $chain.Diff.FinishDate.ToString('dd MMM HH:mm')) }
        if ($chain.Logs.Count) { $plan.Add(('{0} log backup(s) to {1}' -f $chain.Logs.Count, $chain.Logs[-1].FinishDate.ToString('dd MMM HH:mm'))) }
        if ($TailLog) { $plan.Add('the tail of the log, taken now') }
        if ($plan.Count -eq 0) {
            Write-Step 'plan' 'nothing new to apply' 'Yellow'
            Write-Result 'CHECK' ('up to date already - the copy has everything the source has backed up' + $(if ($Cutover) { ', so nothing was applied before the switch' } else { '' }))
            if ($Cutover) {
                # still worth finishing the recovery they asked for
                $plan.Add('recovery only')
            }
            else {
                $result.Verdict = 'CHECK'; $result.Action = 'NothingNew'
                $results.Add($result); Write-Host ''
                continue
            }
        }
        $finishText = if ($Cutover) { 'then online (WITH RECOVERY)' } elseif ($Standby) { 'left readable in standby' } elseif ($KeepRestoring) { 'left restoring for more logs' } else { 'then online' }
        Write-Step 'plan' (($plan -join ', ') + ', ' + $finishText)
        if ($chain.Gap) { Write-Step 'warning' $chain.Gap 'Yellow' }
        if ($chain.StopAtSet) { Write-Step 'stop at' $stopAtValue.ToString('dd MMM yyyy HH:mm:ss') }

        $encrypted = @($toRestore | Where-Object { $_.Set.Encrypted }).Count
        if ($encrypted) { Write-Step 'note' 'these backups are encrypted: the destination needs the same certificate or key, or the restore will fail' 'Yellow' }
        $tooNew = @($toRestore | Where-Object { [int]$_.Set.Major -gt [int]$dstInfo['Major'] })
        if ($tooNew.Count) {
            throw ('the backups were taken on SQL Server major version {0} and {1} is version {2}: a backup cannot be restored onto an older version' -f $tooNew[0].Set.Major, $DestinationInstance, $dstInfo['Major'])
        }

        # ------------------------------------------- can the destination read them?
        foreach ($item in $toRestore) {
            $resolved = New-Object System.Collections.Generic.List[string]
            foreach ($file in $item.Set.Files) {
                $path = Resolve-BackupPath -Path $file -Map $BackupPathMap
                if (-not (Test-DestinationFile $path)) {
                    $viaShare = Get-AdminSharePath -Path $path -SourceHost $sourceHost
                    if ($viaShare -and (Test-DestinationFile $viaShare)) {
                        Write-Step 'path' ('{0} is not visible to the destination, using {1}' -f $path, $viaShare) 'Yellow'
                        $path = $viaShare
                    }
                    else {
                        throw ("{0} cannot read the backup file {1}{2}. Put the backups somewhere both servers can see, or map the path with -BackupPathMap." -f
                               $DestinationInstance, $path, $(if ($viaShare) { " (nor $viaShare)" } else { '' }))
                    }
                }
                $resolved.Add($path)
            }
            $item.Set = $item.Set | Select-Object * -ExcludeProperty Files
            $item.Set | Add-Member -NotePropertyName Files -NotePropertyValue $resolved.ToArray()
        }

        # ------------------------------------------------------- where files go
        $moveList = $null
        if ($chain.Full -and -not $KeepFilePaths) {
            $fileList = Invoke-Sql -Server $DestinationInstance -Query (
                "RESTORE FILELISTONLY FROM " + ((@($toRestore[0].Set.Files) | ForEach-Object { "DISK = N'" + (Esc-Str $_) + "'" }) -join ', ') +
                " WITH FILE = " + [int]$toRestore[0].Set.Position)
            $moveList = @{}
            foreach ($f in $fileList.Rows) {
                $moveList[[string]$f['LogicalName']] = Get-MoveTarget -PhysicalName ([string]$f['PhysicalName']) -FileType ([string]$f['Type']) `
                                                        -DataPath $defaultData -LogPath $defaultLog -SourceDatabase $dbName -DestinationDatabase $dstName
            }
            # a path already belonging to a different database is a mistake waiting to happen
            foreach ($target in $moveList.Values) {
                $owner = Get-Scalar -Server $DestinationInstance -Parameters @{ '@p' = $target } -Query `
                         "SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p"
                if ($owner -and [string]$owner -ne $dstName) {
                    throw ("the file {0} already belongs to the database {1} on {2}. Use -DataPath / -LogPath to put the copy somewhere else." -f $target, $owner, $DestinationInstance)
                }
            }
            Write-Step 'files' ('{0} file(s) to {1}{2}' -f $moveList.Count, $defaultData, $(if ($defaultLog -ne $defaultData) { " and $defaultLog" } else { '' }))
        }

        # ------------------------------------------------ permission to go ahead
        if ($existing -and $chain.Full -and -not $isRestoring) {
            $what = 'overwrite {0} on {1} with the backup of {2} taken {3}' -f $dstName, $DestinationInstance, $dbName, $chain.Full.FinishDate
            if (-not $isCopy) {
                if (-not (Confirm-Action ($what + '. That database is NOT a copy of the source - everything in it will be lost. Continue?') 'Overwrite an unrelated database')) {
                    throw 'not overwritten'
                }
            }
            elseif (-not $PSCmdlet.ShouldProcess(("{0} on {1}" -f $dstName, $DestinationInstance), $what)) {
                if (-not $dryRun) { throw 'not overwritten' }
            }
        }

        if ($DisconnectDestination -and $existing -and -not $dryRun) {
            $spids = Invoke-Sql -Server $DestinationInstance -Parameters @{ '@db' = $dstName } -Query `
                     "SELECT session_id FROM sys.dm_exec_sessions WHERE database_id = DB_ID(@db) AND session_id <> @@SPID"
            if ($spids.Rows.Count) {
                Write-Step 'sessions' ('{0} session(s) using the copy, closing them' -f $spids.Rows.Count) 'Yellow'
                foreach ($s in $spids.Rows) {
                    try { [void](Invoke-Sql -Server $DestinationInstance -Query ('KILL ' + [int]$s['session_id'])) } catch { }
                }
            }
        }

        # ---------------------------------------------------- the source side
        if ($TailLog) {
            # one question for everything that happens to the source, asked before any of it happens:
            # being talked out of the tail log half way through would leave the source in single user
            # for no reason at all
            $ask = 'About to change the SOURCE database {0} on {1}:' -f $dbName, $SourceInstance
            if ($DisconnectSource) { $ask += "`r`n  - close every connection to it (SINGLE_USER WITH ROLLBACK IMMEDIATE); open transactions are rolled back" }
            $ask += "`r`n  - back up the tail of its log WITH NORECOVERY, which leaves it in a restoring state and unusable until someone recovers it."
            $ask += "`r`nThat is what a cutover is, but there is no undo. Go ahead?"
            $go = Confirm-Action $ask 'Cut over from the source database'
            if (-not $go) { throw 'the source was left alone, so nothing has been cut over' }

            if ($DisconnectSource) {
                $sql = 'ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' -f (Esc-Name $dbName)
                if ($dryRun) { Write-Step 'would run' $sql 'DarkCyan' }
                else {
                    Write-Step 'source' 'closing connections to the source database' 'Yellow'
                    [void](Invoke-Sql -Server $SourceInstance -Query $sql)
                }
            }

            $tailSql = "BACKUP LOG {0} TO DISK = N'{1}' WITH NORECOVERY, CHECKSUM, INIT, STATS = 5;" -f (Esc-Name $dbName), (Esc-Str $tailSet.Files[0])
            if ($dryRun) { Write-Step 'would run' $tailSql 'DarkCyan' }
            else {
                Write-Step 'tail log' ('backing up to {0}' -f $tailSet.Files[0])
                $r = Invoke-LongRunningSql -Server $SourceInstance -Sql $tailSql -Label 'tail log'
                if (-not $r.Ok) { throw ('the tail log backup failed, so the source has not been changed: ' + $r.Error) }
                Write-Step 'tail log' ('taken in {0}s - the source database is now in a restoring state' -f $r.Seconds) 'Yellow'
            }
            # the destination has to be able to read it too
            $tailPath = Resolve-BackupPath -Path $tailSet.Files[0] -Map $BackupPathMap
            if (-not $dryRun -and -not (Test-DestinationFile $tailPath)) {
                $viaShare = Get-AdminSharePath -Path $tailPath -SourceHost $sourceHost
                if ($viaShare -and (Test-DestinationFile $viaShare)) { $tailPath = $viaShare }
                else { throw ("the tail log is at {0} but {1} cannot read it. It is a valid backup - put it somewhere the destination can see and apply it by hand, or re-run with -TailLogPath on a share." -f $tailPath, $DestinationInstance) }
            }
            $tailSet.Files = @($tailPath)
            $toRestore.Add([pscustomobject]@{ Set = $tailSet; Kind = 'Log'; Label = 'tail log' })
        }

        # ----------------------------------------------------------- restoring
        $applied = 0
        $seconds = 0.0
        for ($i = 0; $i -lt $toRestore.Count; $i++) {
            $item = $toRestore[$i]
            $isLast = ($i -eq $toRestore.Count - 1)
            $finish = 'NORECOVERY'
            if ($isLast) {
                if ($Cutover -or (-not $KeepRestoring)) { $finish = 'RECOVERY' }
                elseif ($Standby) { $finish = 'STANDBY' }
            }
            elseif ($Standby -and -not $Cutover) { $finish = 'NORECOVERY' }

            $standbyFile = '{0}\{1}_standby.bak' -f $StandbyPath.TrimEnd('\'), $dstName
            $sql = New-RestoreCommand -Database $dstName -BackupSet $item.Set -Kind $item.Kind -Finish $finish `
                       -StandbyFile $standbyFile -MoveList $(if ($item.Label -eq 'full') { $moveList } else { $null }) `
                       -Replace:($item.Label -eq 'full' -and $null -ne $existing) `
                       -StopAt $(if ($chain.StopAtSet -and $item.Set -eq $chain.StopAtSet) { $stopAtValue } else { $null })

            if ($dryRun) { Write-Step 'would run' ($sql -replace "`r`n", "`r`n                 ") 'DarkCyan'; continue }

            Write-Step 'restoring' $item.Label
            $r = Invoke-LongRunningSql -Server $DestinationInstance -Sql $sql -Label $item.Label
            if (-not $r.Ok) { throw ('{0} failed: {1}' -f $item.Label, $r.Error) }
            $applied++
            $seconds += $r.Seconds
            $size = if ($r.Megabytes) { ', ' + (Format-Size ($r.Megabytes * 1MB)) } else { '' }
            $rate = if ($r.Megabytes -and $r.Seconds -gt 0.5) { ' at {0:n0} MB/sec' -f ($r.Megabytes / $r.Seconds) } else { '' }
            Write-Step '' ('{0} done in {1}s{2}{3}' -f $item.Label, $r.Seconds, $size, $rate) 'DarkGray'
        }

        if ($dryRun) {
            Write-Result 'PASS' ('{0} statement(s) would run, nothing was changed' -f $toRestore.Count)
            $result.Action = 'WhatIf'; $results.Add($result); Write-Host ''
            continue
        }

        # ------------------------------------------------------------- the state now
        $after = (Invoke-Sql -Server $DestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }).Rows[0]
        $stateNow = [string]$after['state_desc']
        $reached = if ($chain.Logs.Count) { $chain.Logs[-1].FinishDate } elseif ($chain.Diff) { $chain.Diff.FinishDate } elseif ($chain.Full) { $chain.Full.FinishDate } else { $null }
        if ($TailLog) { $reached = Get-Date }
        $result.RestoredTo = $reached
        $result.Seconds = [math]::Round($seconds, 1)
        $result.Action = if ($Cutover) { 'Cutover' } elseif ($KeepRestoring) { 'Rolling' } else { 'Refresh' }

        if ($Cutover) {
            if ($stateNow -ne 'ONLINE') { throw "the restores worked but the copy is $stateNow rather than online" }
            [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-Name $dstName)))
            Write-Result 'PASS' ('cut over: {0} is online on {1}, {2} restore(s) in {3}s' -f $dstName, $DestinationInstance, $applied, [math]::Round($seconds, 1))
            Write-Step 'next' 'logins and orphaned users, jobs, linked servers, and the applications'' connection strings' 'DarkGray'
            if ($TailLog) { Write-Step 'source' ('{0} on {1} is in a restoring state. Leave it there until you are happy, then RESTORE DATABASE ... WITH RECOVERY puts it back.' -f $dbName, $SourceInstance) 'Yellow' }
        }
        elseif ($KeepRestoring) {
            $readable = [bool]$after['is_in_standby']
            Write-Result 'PASS' ('{0} applied, copy {1} and up to {2}' -f $applied,
                                 $(if ($readable) { 'readable in standby' } else { 'left restoring' }),
                                 $(if ($reached) { $reached.ToString('dd MMM HH:mm') } else { 'date unknown' }))
            Write-Step 'next' ('run the same command again to apply the logs taken after {0}, and add -Cutover -TailLog when you are ready to switch' -f $(if ($reached) { $reached.ToString('HH:mm') } else { 'now' })) 'DarkGray'
        }
        else {
            if ($stateNow -ne 'ONLINE') { throw "the restores worked but the copy is $stateNow rather than online" }
            # SINGLE_USER and RESTRICTED_USER live inside the database, so a copy of a source that was
            # closed off comes back closed off. Nobody wants a refreshed copy they cannot connect to.
            if ([string]$after['user_access_desc'] -ne 'MULTI_USER') {
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-Name $dstName)))
                Write-Step 'access' ('the backup was taken while the database was {0}, so the copy has been opened up to MULTI_USER' -f ([string]$after['user_access_desc']).ToLower()) 'Yellow'
            }
            Write-Result 'PASS' ('restored and online, {0} restore(s) in {1}s, data as at {2}' -f $applied, [math]::Round($seconds, 1), $reached.ToString('dd MMM HH:mm'))
        }
        if ($chain.Gap) { $result.Verdict = 'CHECK'; $result.Detail = $chain.Gap }
        $results.Add($result)
    }
    catch {
        $message = $_.Exception.GetBaseException().Message
        Write-Result 'FAIL' $message
        $result.Verdict = 'FAIL'; $result.Detail = $message
        $results.Add($result)
    }
    Write-Host ''
}

#==============================================================================
# Summary
#==============================================================================
$ok    = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$check = @($results | Where-Object { $_.Verdict -eq 'CHECK' }).Count
$fail  = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count

Write-Host '  ' -NoNewline
Write-Host " $ok done " -NoNewline -ForegroundColor Black -BackgroundColor Green
if ($check) { Write-Host " $check to check " -NoNewline -ForegroundColor Black -BackgroundColor Yellow }
if ($fail)  { Write-Host " $fail failed " -NoNewline -ForegroundColor White -BackgroundColor Red }
Write-Host ("   of {0} database(s) in {1}" -f $results.Count, ((Get-Date) - $startedAt).ToString('hh\:mm\:ss'))
Write-Host ''

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Saved to $CsvPath" -ForegroundColor Gray
    Write-Host ''
}

if ($fail) { exit 2 }
if ($check) { exit 1 }
exit 0
