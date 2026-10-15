#Requires -Version 5.1

<#
.SYNOPSIS
    Restores a database from one SQL Server onto another: the latest full backup, skipping it when
    it has already been restored, or a copy kept rolling forward with log backups until you cut over
    to it. The backups can be read where they lie, or staged through Azure Blob Storage when the two
    servers cannot see each other.

.DESCRIPTION
    Molehill Data Services

    Three jobs, one script.

    1. REFRESH. "Restore the latest full backup of SRC.Sales onto DST, unless that same backup is
       already there." Safe to run on a schedule: it compares the backup set against the restore
       history on the destination and does nothing when it is already restored.

    2. ROLLING RESTORE - log shipping by hand, for moving a large database with minutes of downtime
       instead of hours. Restore it today with -KeepRestoring (or -Standby if you want to read it),
       then run the script again as often as you like to apply the log backups taken since. At
       cutover, -Cutover -TailLog takes the tail of the log from the source, applies it, and brings
       the copy online. The only downtime is that last log.

    3. ACROSS A GAP. With -From AzureBlob the backups are pulled out of a storage container into a
       local staging folder first, for when the destination cannot see the source's backup share -
       an old server being retired, a different site, a different network. Everything else behaves
       the same, including rolling restores: each run downloads only the log backups it still needs.

    WHERE THE BACKUP FILES COME FROM
      -From Path (default)  The paths recorded in msdb on the source, as the destination sees them.
                            -BackupPathMap translates a path, and a local path on another machine is
                            retried through its admin share (\\SOURCE\D$\...) automatically.
      -From AzureBlob       A blob container. Backups are matched to blobs by file name: the blob
                            name, after any folder prefix, must equal the file name in msdb. A
                            backup msdb knows about but which has not finished uploading is passed
                            over with the reason, so a half-written upload is never used.

    Needs no modules at all for -From Path. -From AzureBlob needs Az.Storage, and nothing else; the
    restores themselves are plain T-SQL either way.

    WHAT IT CHECKS BEFORE RESTORING ANYTHING
      * the destination can read every file in the chain, and is not an older version of SQL Server
        than the backup was taken on
      * the backup header matches the database it claims to be
      * the database on the destination really is a copy of the source (restore history, then the
        backup family) before it overwrites it - an unrelated database of that name needs -Force
      * the file paths it is about to write are not already in use by a different database
      * the log chain joins up, and says where it breaks if it does not

    The source is read-only unless you ask for -TailLog or -DisconnectSource, which are the two
    things that change it. Both say what they will do and ask first unless -Force is given.

    WHEN IT WILL NOT CONNECT
    Connection problems are reported in detail rather than as one line. The login is tried first;
    only when it fails are the name, SQL Browser and the TCP port checked, and the error is
    explained with what usually causes it. -TestConnectionOnly runs just those checks.
    -LogLevel Verbose shows every step, Debug adds the raw exceptions and error numbers.


.PARAMETER SourceInstance
    The instance whose backups you want. Read-only: its msdb history.

.PARAMETER DestinationInstance
    The instance to restore onto. This is where the work happens.

.PARAMETER Database
    One or more database names as they are on the source. Each is restored in turn; one failing is
    reported and the rest carry on, and the summary says what happened to each.

.PARAMETER DestinationDatabase
    Restore under a different name. One database at a time - there is no sensible way to rename
    several at once.

.PARAMETER From
    Where the backup files are read from: Path (default) or AzureBlob.

.PARAMETER SourceHistoryFile
    Read the source's backup history out of a CSV file instead of connecting to it, produced by
    running Tools\Export-BackupHistory.sql on the source server. The source is then never contacted:
    useful when a modern machine cannot complete a TLS handshake with an old instance, which shows up
    as "An existing connection was forcibly closed by the remote host".

    -TailLog and -DisconnectSource need a live source and are refused with this. So is the admin
    share fallback for backup paths, since the source's machine name is not known - use
    -BackupPathMap, or -From AzureBlob.

.PARAMETER BackupPathMap
    Path translation for -From Path, when the destination sees the backups somewhere else:
    @{ 'D:\Backup' = '\\SQL01\Backup$'; 'E:\Logs' = '\\SQL01\Logs$' }. Longest prefix wins.
    Scheduling it? powershell.exe -File turns every argument into a string, so a hashtable has to go
    through -Command instead: powershell -Command "& Restore-MhDatabaseCopy ... -BackupPathMap @{...}".

.PARAMETER StorageAccountName
    -From AzureBlob: the storage account holding the backups. The account name on its own, not a URL.

.PARAMETER ContainerName
    -From AzureBlob: the blob container.

.PARAMETER BlobPrefix
    -From AzureBlob: optional virtual folder inside the container, e.g. 'OLDSQL/Sales'. A parent
    folder is enough when several databases share one.

.PARAMETER SasToken
    -From AzureBlob: a Shared Access Signature with at least Read and List permission on the
    container. Takes a plain string or a SecureString; a leading '?' is removed. Wrap a plain string
    in SINGLE quotes - SAS tokens contain '&', which PowerShell treats as an operator otherwise.

.PARAMETER LocalBackupPath
    -From AzureBlob: the local staging folder for downloaded files. Created if missing. It must be
    readable by the destination SQL Server SERVICE ACCOUNT, not just by you - a path under
    C:\Users will not do, and is the most common reason a staged restore fails.

.PARAMETER KeepLocalCopy
    -From AzureBlob: keep the downloaded file(s) instead of deleting them after a successful restore.

.PARAMETER KeepRestoring
    Leave the copy in a restoring state so more log backups can be applied later. This is the
    rolling restore: run the script again whenever you want to catch up.

.PARAMETER Standby
    Like -KeepRestoring, but leave the copy readable between log restores (RESTORE ... WITH STANDBY).

.PARAMETER StandbyPath
    Folder for the standby undo file. Default: the destination's default data path.

.PARAMETER Cutover
    Apply everything outstanding and bring the copy online. After this it is a normal database and
    no more logs can go on.

.PARAMETER TailLog
    At cutover, back up the tail of the log on the SOURCE with NORECOVERY and apply it. That leaves
    the source in a restoring state - which is the point, nobody can write to it after the switch -
    and implies -Cutover. It asks first unless -Force.

.PARAMETER TailLogPath
    Folder for the tail log backup. It has to be readable by the destination as well, so with
    -From AzureBlob use a share both can see: the tail log is not routed through blob storage,
    because waiting for an upload defeats the point of a tail log.

.PARAMETER DisconnectSource
    Before the tail log, close every connection to the source database so nothing can write between
    the backup and the switch. Asks first unless -Force.

.PARAMETER DisconnectDestination
    Close sessions using the copy if they are in the way. Readers of a -Standby copy will block a
    log restore, so this is usually wanted with scheduled standby runs.

.PARAMETER StopAt
    Point in time to stop at, e.g. '2026-10-12 14:30'. Applies logs up to that moment.

.PARAMETER NoDifferential
    Ignore differential backups, even where one would save time.

.PARAMETER HistoryDays
    How far back to read the source's backup history. Default 180 days.

.PARAMETER DataPath
    Where to put the data files. Default: the destination instance's own default data path.

.PARAMETER LogPath
    Where to put the log file. Default: the destination instance's own default log path.

.PARAMETER KeepFilePaths
    Restore the files to the paths they had on the source, instead of relocating them.

.PARAMETER DatabaseOwner
    Login to make the database owner once it is online. Checked to exist first. Left as restored
    when not given.

.PARAMETER CompatibilityLevel
    Compatibility level to set once the database is online. 0 leaves it as restored.

.PARAMETER RepairOrphanUsers
    Remap database users to destination logins of the same name.

.PARAMETER UpdateStatistics
    Run sp_updatestats once the database is online.

.PARAMETER RunCheckDb
    Run DBCC CHECKDB WITH DATA_PURITY once the database is online. Worth it for a database coming
    off an old server, and slow on a big one.

.PARAMETER SqlCredential
    SQL authentication for both instances. -SourceSqlCredential and -DestinationSqlCredential
    override it for one end. Windows authentication is used when none are given.

.PARAMETER TrustServerCertificate
    Trust the server certificate. Needed for an instance with a self-signed certificate, which
    includes most older ones.

.PARAMETER LogLevel
    How much to say. Quiet = problems and the summary only. Normal = each step and the decisions
    behind it (default). Verbose = every check, every candidate backup, every statement. Debug =
    Verbose plus raw exceptions, SQL error numbers and the redacted connection strings.
    Passing -Verbose or -Debug raises the level by itself.

.PARAMETER LogFile
    Append the same output to this file.

.PARAMETER CsvPath
    Write one row per database, with the outcome, to a CSV file.

.PARAMETER TestConnectionOnly
    Run the connection checks against both instances, print what they say, and stop.

.PARAMETER Force
    Overwrite a database on the destination that is not a copy of the source, and do not ask before
    touching the source (-TailLog, -DisconnectSource).

.PARAMETER InstallMissingModules
    -From AzureBlob: install Az.Storage for the current user if it is missing.


.EXAMPLE
    Restore-MhDatabaseCopy -SourceInstance SQL01 -Database Sales -DestinationInstance SQL02
    # latest full (plus a differential if there is one), online, and nothing at all if it is already restored

.EXAMPLE
    # Monday: seed the copy, then catch it up whenever you like
    Restore-MhDatabaseCopy SQL01 SQL02 Sales -KeepRestoring
    Restore-MhDatabaseCopy SQL01 SQL02 Sales -KeepRestoring      # applies the logs since
    # Friday 18:00, the ten minutes that matter:
    Restore-MhDatabaseCopy SQL01 SQL02 Sales -Cutover -TailLog -DisconnectSource

.EXAMPLE
    # off an old server that the new one cannot see, several databases in one run
    Restore-MhDatabaseCopy -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -Database Sales,Stock,Payroll -From AzureBlob -StorageAccountName mycompany `
        -ContainerName legacybackup -BlobPrefix OLDSQL -SasToken (Get-Secret -Name LegacyBackupSas) `
        -LocalBackupPath D:\RestoreStaging -TrustServerCertificate -RepairOrphanUsers

.EXAMPLE
    Restore-MhDatabaseCopy SQL01 SQL02 Sales -StopAt '2026-10-12 09:15' -WhatIf
    # prints the exact RESTORE statements it would run, and nothing else

.EXAMPLE
    Restore-MhDatabaseCopy OLDSQL NEWSQL Sales -TestConnectionOnly -TrustServerCertificate
    # start here when something will not connect

.NOTES
    Molehill Data Services. Needs SQL Server 2012 or later at both ends, the right to restore on the
    destination, and read access to msdb on the source.
#>

function Restore-MhDatabaseCopy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)] [string] $SourceInstance,
        [Parameter(Position = 1)] [string] $DestinationInstance,
        [Parameter(Position = 2)] [Alias('DatabaseName')] [string[]] $Database,
        [Alias('DestinationDatabaseName')] [string] $DestinationDatabase,

        [ValidateSet('Path', 'AzureBlob')] [string] $From = 'Path',

        # -From Path
        [hashtable] $BackupPathMap,

        # when the source cannot be connected to at all
        [string] $SourceHistoryFile,

        # -From AzureBlob
        [string] $StorageAccountName,
        [string] $ContainerName,
        [string] $BlobPrefix,
        [object] $SasToken,
        [string] $LocalBackupPath,
        [switch] $KeepLocalCopy,
        [switch] $InstallMissingModules,

        # what to restore
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
        [Alias('LookbackDays')] [ValidateRange(1, 365)] [int] $HistoryDays = 180,

        # where the restored files go
        [Alias('DataDirectory')] [string] $DataPath,
        [Alias('LogDirectory')] [string] $LogPath,
        [switch] $KeepFilePaths,

        # once it is online
        [string] $DatabaseOwner,
        [ValidateSet(0, 100, 110, 120, 130, 140, 150, 160, 170)] [int] $CompatibilityLevel = 0,
        [switch] $RepairOrphanUsers,
        [switch] $UpdateStatistics,
        [switch] $RunCheckDb,

        # connecting
        [PSCredential] $SqlCredential,
        [PSCredential] $SourceSqlCredential,
        [PSCredential] $DestinationSqlCredential,
        [switch] $TrustServerCertificate,
        [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

        # saying what happened
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
        [string] $LogFile,
        [string] $CsvPath,
        [switch] $TestConnectionOnly,
        [switch] $Force
    )

    $ErrorActionPreference = 'Stop'

    # the module's log, started for this run: -Verbose and -Debug raise the level on their own, which
    # is why it is handed $PSBoundParameters rather than being asked to work that out
    Initialize-MhLog -Level $LogLevel -LogFile $LogFile -BoundParameters $PSBoundParameters

    # the functions at module scope cannot see this function's parameters, so this run's settings are
    # copied where they can see them - every run, so nothing carries over from the last one
    $script:DbCopySourceInstance = $SourceInstance
    $script:DbCopyDestinationInstance = $DestinationInstance
    $script:DbCopySqlCredential = $SqlCredential
    $script:DbCopySourceSqlCredential = $SourceSqlCredential
    $script:DbCopyDestinationSqlCredential = $DestinationSqlCredential
    $script:DbCopyTrustServerCertificate = $TrustServerCertificate
    $script:DbCopyConnectTimeoutSeconds = $ConnectTimeoutSeconds
    $script:DbCopyLocalBackupPath = $LocalBackupPath
    $script:DbCopyContainerName = $ContainerName
    $script:DbCopyBackupPathMap = $BackupPathMap

    # whether the destination can answer xp_fileexist, which is asked once and remembered. Per run,
    # because the answer belongs to the destination this run is talking to.
    $script:DbCopyFileCheckWorks = $true
    $ErrorActionPreference = 'Stop'
    if (-not $script:DbCopySourceSqlCredential) { $script:DbCopySourceSqlCredential = $script:DbCopySqlCredential }
    if (-not $script:DbCopyDestinationSqlCredential) { $script:DbCopyDestinationSqlCredential = $script:DbCopySqlCredential }

    $SourceHistoryQuery = @"
SELECT  bs.backup_set_id, bs.backup_set_uuid, bs.type, bs.position,
        bs.first_lsn, bs.last_lsn, bs.checkpoint_lsn, bs.database_backup_lsn,
        bs.backup_start_date, bs.backup_finish_date, bs.database_name, bs.family_guid,
        bs.is_copy_only, bs.has_backup_checksums, bs.backup_size,
        bs.software_major_version, bs.key_algorithm,
        mf.physical_device_name, mf.family_sequence_number
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id AND mf.mirror = 0
WHERE bs.database_name = @db
  AND bs.is_damaged = 0
  AND bs.backup_finish_date >= DATEADD(day, -@days, SYSDATETIME())
  AND mf.device_type IN (2, 102)        -- disk and logical disk device
ORDER BY bs.backup_finish_date, bs.backup_set_id, mf.family_sequence_number;
"@
    $SourceOffDiskQuery = @"
SELECT Kinds = COUNT(*),
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
        drs.family_guid
FROM sys.databases d
LEFT JOIN sys.database_recovery_status drs ON drs.database_id = d.database_id
WHERE d.name = @db;
"@
    $DestRestoreHistoryQuery = @"
SELECT TOP (1) rh.restore_date, bs.type, bs.last_lsn, bs.backup_set_uuid,
               bs.backup_finish_date, bs.database_name
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
    $offlineSource = [bool]$SourceHistoryFile
    if ($offlineSource -and -not $script:DbCopySourceInstance) { $script:DbCopySourceInstance = 'the source (from history file)' }
    foreach ($required in 'SourceInstance', 'DestinationInstance') {
        if (-not (Get-Variable -Name $required -ValueOnly)) {
            Stop-DbCopyRun "-$required is needed. Get-Help Restore-MhDatabaseCopy -Detailed shows what goes with it."
        }
    }
    if ($offlineSource -and ($TailLog -or $DisconnectSource)) {
        Stop-DbCopyRun ('-TailLog and -DisconnectSource have to talk to the source, so they cannot be used with -SourceHistoryFile. ' +
                        'Take the tail log on the source itself, put it somewhere the destination can read, and apply it there.')
    }
    $named = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($named.Count -eq 1 -and $named[0] -match ',') { $named = @($named[0] -split ',') }
    $databases = @($named | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($databases.Count -eq 0) {
        Stop-DbCopyRun '-Database is needed (one name, or several).'
    }
    if ($DestinationDatabase -and $databases.Count -gt 1) {
        Stop-DbCopyRun '-DestinationDatabase renames one database, so it cannot be used with several. Run them separately, or leave the names as they are.'
    }
    if ($From -eq 'AzureBlob' -and -not $TestConnectionOnly) {
        foreach ($required in 'StorageAccountName', 'ContainerName', 'LocalBackupPath') {
            if (-not (Get-Variable -Name $required -ValueOnly)) {
                Stop-DbCopyRun "-From AzureBlob needs -$required."
            }
        }
        if ($null -eq $SasToken) { Stop-DbCopyRun '-From AzureBlob needs -SasToken.' }
    }
    if ($TailLog -and -not $Cutover) { $Cutover = $true }
    if ($DisconnectSource -and -not $TailLog) { Stop-DbCopyRun '-DisconnectSource is for the cutover: add -TailLog.' }
    if ($Cutover -and ($KeepRestoring -or $Standby)) { Stop-DbCopyRun '-Cutover brings the copy online; -KeepRestoring and -Standby keep it offline. Pick one.' }
    if ($Standby) { $KeepRestoring = $true }
    $script:DbCopySourceInstance = $script:DbCopySourceInstance.Trim()
    $script:DbCopyDestinationInstance = $script:DbCopyDestinationInstance.Trim()
    $stopAtValue = if ($PSBoundParameters.ContainsKey('StopAt')) { $StopAt } else { $null }
    $dryRun = $WhatIfPreference -eq $true
    $script:DbCopyBlobList = $null
    $script:DbCopyStagedList = New-Object System.Collections.Generic.List[string]
    $runStart = Get-Date
    $setupDone = $false
    $results = New-Object System.Collections.Generic.List[object]
    try {
        Write-MhLog ("Restore {0} database(s) from {1} to {2}, backups read {3}" -f $databases.Count, $script:DbCopySourceInstance, $script:DbCopyDestinationInstance,
                   $(if ($From -eq 'AzureBlob') { "from $StorageAccountName/$script:DbCopyContainerName" } else { 'where msdb says they are' }))
        Write-MhLog ('Databases: ' + ($databases -join ', '))
        Write-MhDetail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName) on $env:COMPUTERNAME; log level $LogLevel"
        if ($dryRun) { Write-MhLog 'WhatIf mode: the statements below are printed, not run' -Level WARN }

        #region Connection checks
        Start-MhStep 'Check the SQL Server instances'
        if ($offlineSource) {
            Write-MhLog ('source: not contacted, its backup history comes from {0}' -f $SourceHistoryFile)
        }
        else {
            $sourceCheck = Test-MhSqlConnectivity -Instance $script:DbCopySourceInstance -Credential $script:DbCopySourceSqlCredential `
                                                -Trust:$script:DbCopyTrustServerCertificate -TimeoutSeconds $script:DbCopyConnectTimeoutSeconds
            Write-MhConnectivityReport -Result $sourceCheck -Role 'source'
        }
        $destinationCheck = Test-MhSqlConnectivity -Instance $script:DbCopyDestinationInstance -Credential $script:DbCopyDestinationSqlCredential `
                                                 -Trust:$script:DbCopyTrustServerCertificate -TimeoutSeconds $script:DbCopyConnectTimeoutSeconds
        Write-MhConnectivityReport -Result $destinationCheck -Role 'destination'

        $failed = @()
        if (-not $offlineSource -and -not $sourceCheck.Connected) { $failed += "source $script:DbCopySourceInstance" }
        if (-not $destinationCheck.Connected) { $failed += "destination $script:DbCopyDestinationInstance" }
        if ($failed.Count) {
            $extra = ''
            if (-not $offlineSource -and -not $sourceCheck.Connected -and $sourceCheck.Error -match 'forcibly closed|handshake|common algorithm|certificate') {
                $extra = ' If the source is an old instance that will not negotiate encryption, Test-SqlTlsHandshake.ps1 says why - and -SourceHistoryFile lets you restore without contacting it at all.'
            }
            throw ('Cannot connect to ' + ($failed -join ' and ') + '. The checks above say why; -LogLevel Verbose shows every step and Debug the raw errors.' + $extra)
        }
        Complete-MhStep

        if ($TestConnectionOnly) {
            Write-MhLog 'TestConnectionOnly: both instances answered, nothing else was done'
            $setupDone = $true
            throw [System.Management.Automation.HaltCommandException]::new('done')
        }
        #endregion

        #region The two ends
        Start-MhStep 'Read the instances'
        $srcInfo = $null
        $sourceHost = $null
        $sourceBackupDir = $null
        if (-not $offlineSource) {
            $srcInfo = (Invoke-DbCopySql -Server $script:DbCopySourceInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), MachineName = CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), BackupDir = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultBackupPath'))").Rows[0]
            $sourceHost = [string]$srcInfo['MachineName']
            $sourceBackupDir = [string]$srcInfo['BackupDir']
        }
        $dstInfo = (Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), DataPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), LogPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath'))").Rows[0]

        if ($srcInfo -and [string]$srcInfo['ServerName'] -eq [string]$dstInfo['ServerName'] -and -not $DestinationDatabase) {
            throw 'The source and the destination are the same instance, so the copy needs -DestinationDatabase.'
        }
        if ($offlineSource -and $From -eq 'Path' -and -not $script:DbCopyBackupPathMap) {
            Write-MhLog 'With -SourceHistoryFile the source machine name is unknown, so a path it cannot see will not be retried through an admin share. If the destination cannot read the recorded paths, pass -BackupPathMap or use -From AzureBlob.' -Level WARN
        }

        $defaultData = [string]$dstInfo['DataPath']
        $defaultLog = [string]$dstInfo['LogPath']
        if (-not $defaultData -or -not $defaultLog) {
            # older instances leave those properties empty: master's own files are the next best guess
            $mf = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query "SELECT Type = type_desc, Path = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name))) FROM sys.master_files WHERE database_id = 1"
            foreach ($r in $mf.Rows) {
                if (-not $defaultData -and [string]$r['Type'] -eq 'ROWS') { $defaultData = [string]$r['Path'] }
                if (-not $defaultLog -and [string]$r['Type'] -eq 'LOG') { $defaultLog = [string]$r['Path'] }
            }
        }
        if ($DataPath) { $defaultData = $DataPath }
        if ($LogPath) { $defaultLog = $LogPath }
        if (-not $StandbyPath) { $StandbyPath = $defaultData }
        Write-MhDetail ('  restored files go to {0}{1}' -f $defaultData, $(if ($defaultLog -ne $defaultData) { " and $defaultLog" } else { '' }))
        Complete-MhStep
        #endregion

        #region Storage, once for all the databases
        if ($From -eq 'AzureBlob') {
            Start-MhStep 'Open the storage container'
            $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
            if ($found.Count -eq 0) {
                if (-not $InstallMissingModules) {
                    Write-MhDeep ('module search path: ' + ($env:PSModulePath -split ';' -join ' | '))
                    throw ("-From AzureBlob needs the Az.Storage module, which is not installed for $($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion). " +
                           'Re-run with -InstallMissingModules, or: Install-Module Az.Storage -Scope CurrentUser. ' +
                           'Modules installed for Windows PowerShell 5.1 are not visible to PowerShell 7, or the other way round, so check which one you are in.')
                }
                Write-MhLog 'Installing Az.Storage for the current user'
                Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
                $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
            }
            Write-MhDetail ('  Az.Storage {0} from {1}' -f $found[0].Version, $found[0].ModuleBase)
            # Import-Module has no -WhatIf of its own, but the preference reaches inside the module and
            # it then narrates everything it defines
            $savedWhatIf = $WhatIfPreference
            try {
                $WhatIfPreference = $false
                Import-Module -Name Az.Storage -Verbose:$false
            }
            finally { $WhatIfPreference = $savedWhatIf }

            $script:DbCopyBlobList = Connect-DbCopyBlobContainer -AccountName $StorageAccountName -Container $script:DbCopyContainerName `
                                                  -Prefix $BlobPrefix -Sas $SasToken

            if (-not (Test-Path -LiteralPath $script:DbCopyLocalBackupPath)) {
                Write-MhDetail "  creating $script:DbCopyLocalBackupPath"
                New-Item -ItemType Directory -Path $script:DbCopyLocalBackupPath -WhatIf:$false | Out-Null
            }
            if ($script:DbCopyLocalBackupPath -match '^[A-Za-z]:\\Users\\') {
                Write-MhLog 'The staging folder is inside a user profile. The SQL Server service account usually cannot read there, which fails the header check - D:\RestoreStaging or similar is safer.' -Level WARN
            }
            Complete-MhStep
        }
        #endregion

        $script:FileHistory = $null
        if ($offlineSource) {
            Start-MhStep 'Read the backup history file'
            $script:FileHistory = Import-DbCopyBackupHistory -Path $SourceHistoryFile
            Write-MhLog ('{0} row(s) of history for {1} database(s)' -f $script:FileHistory.Count,
                       @($script:FileHistory | ForEach-Object { [string]$_.database_name } | Select-Object -Unique).Count)
            Complete-MhStep
        }

        $setupDone = $true

        #==========================================================================
        # One database at a time. A failure on one is recorded and the rest carry on.
        #==========================================================================
        foreach ($dbName in $databases) {
            $dstName = if ($DestinationDatabase) { $DestinationDatabase } else { $dbName }
            Set-MhLogPrefix $(if ($databases.Count -gt 1) { $dbName } else { '' })
            $script:DbCopyStagedList.Clear()

            $outcome = [pscustomobject]@{
                SourceInstance = $script:DbCopySourceInstance; Database = $dbName
                DestinationInstance = $script:DbCopyDestinationInstance; DestinationDatabase = $dstName
                Result = 'FAILED'; Action = ''; RestoredTo = $null; Applied = 0; Bytes = 0; Detail = $null
            }
            $selected = $null
            $restored = $false
            $priorState = $null

            try {
                if ($script:DbCopySourceInstance -eq $script:DbCopyDestinationInstance -and $dbName -eq $dstName) {
                    throw 'Source and destination are the same database. Refusing to overwrite the master copy.'
                }
                Write-MhLog ('---- {0} -> {1}.[{2}] ----' -f $dbName, $script:DbCopyDestinationInstance, $dstName)

                #region History
                Start-MhStep $(if ($offlineSource) { 'Read the backup history from the file' } else { 'Read the backup history from the source' })
                if ($offlineSource) {
                    $cutoff = (Get-Date).AddDays(-$HistoryDays)
                    $rows = @($script:FileHistory | Where-Object { [string]$_.database_name -eq $dbName })
                    if ($rows.Count -eq 0) {
                        throw ("{0} has no history for [{1}]. The names it does have: {2}" -f $SourceHistoryFile, $dbName,
                               ((@($script:FileHistory | ForEach-Object { [string]$_.database_name } | Select-Object -Unique) | Sort-Object) -join ', '))
                    }
                    $sets = @()
                    foreach ($group in ($rows | Group-Object { [string]$_.backup_set_id })) {
                        $first = $group.Group[0]
                        $finish = Read-DbCopyHistoryDate $first.backup_finish_date
                        if ($finish -lt $cutoff) { continue }
                        $sets += [pscustomobject]@{
                            SetId        = [int]$first.backup_set_id
                            Uuid         = [string]$first.backup_set_uuid
                            Type         = [string]$first.type
                            Position     = [int]$first.position
                            FirstLsn     = [decimal]$first.first_lsn
                            LastLsn      = [decimal]$first.last_lsn
                            CheckpointLsn     = [decimal]$first.checkpoint_lsn
                            DatabaseBackupLsn = [decimal]$first.database_backup_lsn
                            StartDate    = Read-DbCopyHistoryDate $first.backup_start_date
                            FinishDate   = $finish
                            FamilyGuid   = [string]$first.family_guid
                            IsCopyOnly   = ([string]$first.is_copy_only -eq '1')
                            HasChecksums = ([string]$first.has_backup_checksums -eq '1')
                            Size         = [double]$first.backup_size
                            Major        = [int]$first.software_major_version
                            Encrypted    = ([string]$first.key_algorithm).Trim().Length -gt 0
                            Files        = @($group.Group | Sort-Object { [int]$_.family_sequence_number } | ForEach-Object { [string]$_.physical_device_name })
                        }
                    }
                    if ($sets.Count -eq 0) {
                        throw ("{0} has history for [{1}] but none of it is within the last {2} days. Raise -HistoryDays, or export it again." -f $SourceHistoryFile, $dbName, $HistoryDays)
                    }
                }
                else {
                $history = Invoke-DbCopySql -Server $script:DbCopySourceInstance -Query $SourceHistoryQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
                if ($history.Rows.Count -eq 0) {
                    $extra = ''
                    $offDisk = Invoke-DbCopySql -Server $script:DbCopySourceInstance -Query $SourceOffDiskQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
                    if ($offDisk.Rows.Count -and [int]$offDisk.Rows[0]['Kinds'] -gt 0) {
                        $extra = ' Its backups go to {0}, which this script does not restore from.' -f $offDisk.Rows[0]['Devices']
                    }
                    throw ("No disk backups of [{0}] in the last {1} days on {2}.{3}" -f $dbName, $HistoryDays, $script:DbCopySourceInstance, $extra)
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
                }
                Write-MhDetail ('  {0} backup set(s) in history: {1} full, {2} differential, {3} log' -f $sets.Count,
                              @($sets | Where-Object { $_.Type -eq 'D' }).Count, @($sets | Where-Object { $_.Type -eq 'I' }).Count,
                              @($sets | Where-Object { $_.Type -eq 'L' }).Count)

                # with storage in the way, only what has finished uploading can be restored
                if ($From -eq 'AzureBlob') {
                    $availability = Select-DbCopyAvailableSets -BackupSets $sets -AvailableFiles @($script:DbCopyBlobList.Index.Keys)
                    foreach ($skip in $availability.Skipped) {
                        Write-MhLog ('Passing over the {0} backup finished {1}: not in storage yet ({2})' -f
                                   $(switch ($skip.Set.Type) { 'D' { 'full' } 'I' { 'differential' } default { 'log' } }),
                                   $skip.Set.FinishDate, ($skip.Missing -join ', ')) -Level WARN
                    }
                    $sets = $availability.Kept
                    if ($sets.Count -eq 0) { throw "None of the backups of [$dbName] in the last $HistoryDays days are in the container yet. Check the upload process and -BlobPrefix; the blob name after any folder must match the file name recorded in msdb." }
                }
                Write-MhLog ('Newest usable backup finished {0}' -f (@($sets | Sort-Object FinishDate | Select-Object -Last 1)).FinishDate)
                Complete-MhStep
                #endregion

                #region What is on the destination
                Start-MhStep 'Look at the destination'
                $existing = $null
                $dstRow = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }
                if ($dstRow.Rows.Count) { $existing = $dstRow.Rows[0] }

                $lastRestore = $null
                $historyRow = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query $DestRestoreHistoryQuery -Parameters @{ '@db' = $dstName }
                if ($historyRow.Rows.Count) { $lastRestore = $historyRow.Rows[0] }

                $state = if ($existing) { [string]$existing['state_desc'] } else { 'ABSENT' }
                $inStandby = $existing -and [bool]$existing['is_in_standby']
                # a standby copy is reported ONLINE with is_in_standby set, not RESTORING - but it is
                # still mid-restore and still takes more log backups, which is the point of standby
                $isRestoring = ($state -eq 'RESTORING') -or $inStandby
                $dstFamily = if ($existing -and -not ($existing['family_guid'] -is [DBNull])) { ([guid]$existing['family_guid']).ToString() } else { $null }

                Write-MhLog ('The destination copy is ' + $(
                    if (-not $existing) { 'not there yet' }
                    elseif ($isRestoring) {
                        '{0}{1}' -f $(if ($inStandby) { 'in standby, readable, mid-restore' } else { 'restoring' }),
                                    $(if ($lastRestore) { ', last restore ' + ([datetime]$lastRestore['restore_date']).ToString('dd MMM HH:mm') } else { '' })
                    }
                    else { '{0}, {1}' -f $state.ToLower(), [string]$existing['user_access_desc'] }))

                # is that database a copy of this source database, or someone else's?
                $isCopy = $false
                if ($existing) {
                    if ($lastRestore -and [string]$lastRestore['database_name'] -eq $dbName) { $isCopy = $true }
                    elseif ($dstFamily) { $isCopy = @($sets | Where-Object { $_.FamilyGuid -eq $dstFamily }).Count -gt 0 }
                }

                $latestFull = @($sets | Where-Object { $_.Type -eq 'D' } | Sort-Object FinishDate | Select-Object -Last 1)
                if ($latestFull.Count -eq 0) { throw 'no full backup available, so there is nothing to restore from' }
                $latestFull = $latestFull[0]

                $alreadyRow = $null
                $already = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query $DestAlreadyRestoredQuery -Parameters @{ '@db' = $dstName; '@uuid' = $latestFull.Uuid }
                if ($already.Rows.Count) { $alreadyRow = $already.Rows[0] }
                Complete-MhStep

                # the plain refresh: same full already here, nothing asked for on top of it
                if ($alreadyRow -and $existing -and -not $isRestoring -and -not $KeepRestoring -and -not $Cutover -and -not $stopAtValue -and -not $Force) {
                    Write-MhLog ('Already restored: the full backup of {0} was restored here {1}. Nothing to do.' -f
                               ([datetime]$alreadyRow['backup_finish_date']).ToString('dd MMM HH:mm'),
                               ([datetime]$alreadyRow['restore_date']).ToString('dd MMM HH:mm'))
                    $outcome.Result = 'ALREADY DONE'
                    $outcome.Action = 'SkippedAlreadyRestored'
                    $outcome.RestoredTo = [datetime]$alreadyRow['backup_finish_date']
                    continue
                }

                $lastRestoredLsn = $null
                if ($isRestoring) {
                    if (-not $lastRestore) {
                        throw 'the copy is mid-restore but this instance has no restore history for it (msdb cleared?), so there is no safe way to know which log comes next - restore it again from a full backup with -Force'
                    }
                    $lastRestoredLsn = [decimal]$lastRestore['last_lsn']
                }
                elseif ($existing -and ($Cutover -or $KeepRestoring) -and $alreadyRow -and -not $Force) {
                    Write-MhLog 'The copy is already online, so no more log backups can be applied to it. Restore it again with -Force to start a new copy.' -Level WARN
                    $outcome.Result = 'CHECK'
                    $outcome.Action = 'AlreadyOnline'
                    $outcome.Detail = 'the copy is recovered; a new full restore is needed to roll it forward again'
                    continue
                }

                if ($existing -and -not $isRestoring -and -not $isCopy -and -not $Force) {
                    throw ("{0} on {1} is not a copy of {2} (no restore history for it, and the backup family does not match), so it has not been touched. Use -Force to overwrite it anyway." -f $dstName, $script:DbCopyDestinationInstance, $dbName)
                }
                #endregion

                #region Work out the chain
                Start-MhStep 'Work out what to restore'
                $chain = Select-DbCopyBackupChain -BackupSets $sets -LastRestoredLsn $lastRestoredLsn -StopAt $stopAtValue `
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

                $plan = New-Object System.Collections.Generic.List[string]
                if ($chain.Full) { $plan.Add('full of ' + $chain.Full.FinishDate.ToString('dd MMM HH:mm') + ' (' + (Format-MhSize $chain.Full.Size) + ')') }
                if ($chain.Diff) { $plan.Add('differential of ' + $chain.Diff.FinishDate.ToString('dd MMM HH:mm')) }
                if ($chain.Logs.Count) { $plan.Add(('{0} log backup(s) to {1}' -f $chain.Logs.Count, $chain.Logs[-1].FinishDate.ToString('dd MMM HH:mm'))) }
                if ($TailLog) { $plan.Add('the tail of the log, taken now') }

                if ($plan.Count -eq 0) {
                    if (-not $Cutover) {
                        Write-MhLog 'Up to date already: the copy has everything the source has backed up.' -Level WARN
                        $outcome.Result = 'CHECK'
                        $outcome.Action = 'NothingNew'
                        $outcome.Detail = 'nothing new to apply'
                        Complete-MhStep -Result 'SKIPPED'
                        continue
                    }
                    $plan.Add('recovery only')
                }
                $finishText = if ($Cutover) { 'then online' } elseif ($Standby) { 'left readable in standby' } elseif ($KeepRestoring) { 'left restoring for more logs' } else { 'then online' }
                Write-MhLog (($plan -join ', ') + ', ' + $finishText)
                if ($chain.Gap) { Write-MhLog ('Chain gap: ' + $chain.Gap) -Level WARN }
                if ($chain.StopAtSet) { Write-MhLog ('Stopping at ' + $stopAtValue.ToString('dd MMM yyyy HH:mm:ss')) }

                if (@($toRestore | Where-Object { $_.Set.Encrypted }).Count) {
                    Write-MhLog 'These backups are encrypted: the destination needs the same certificate or key, or the restore will fail.' -Level WARN
                }
                $tooNew = @($toRestore | Where-Object { [int]$_.Set.Major -gt [int]$dstInfo['Major'] })
                if ($tooNew.Count) {
                    throw ('the backups were taken on SQL Server major version {0} and {1} is version {2}: a backup cannot be restored onto an older version' -f $tooNew[0].Set.Major, $script:DbCopyDestinationInstance, $dstInfo['Major'])
                }
                Complete-MhStep
                #endregion

                #region Get the files where the destination can read them
                Start-MhStep $(if ($From -eq 'AzureBlob') { 'Download the backup file(s)' } else { 'Check the destination can read the backup file(s)' })
                if ($From -eq 'AzureBlob') {
                    $needed = [long](@($toRestore | ForEach-Object { $_.Set.Size }) | Measure-Object -Sum).Sum
                    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:DbCopyLocalBackupPath))
                    if (-not $root.StartsWith('\\')) {
                        $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
                        Write-MhDetail ('  {0} has {1} free; this chain is about {2}' -f $root, (Format-MhSize $freeBytes), (Format-MhSize $needed))
                        if ($freeBytes -lt ($needed * 1.05)) {
                            throw ('Not enough free space on {0}: need about {1}, have {2}' -f $root, (Format-MhSize ($needed * 1.05)), (Format-MhSize $freeBytes))
                        }
                    }
                }
                $downloadedBytes = 0
                foreach ($item in $toRestore) {
                    $r = Resolve-DbCopyBackupFiles -Files $item.Set.Files -DestinationServer $script:DbCopyDestinationInstance `
                                             -SourceHost $sourceHost -Download:($From -eq 'AzureBlob')
                    $downloadedBytes += $r.Bytes
                    $item.Set = $item.Set | Select-Object * -ExcludeProperty Files
                    $item.Set | Add-Member -NotePropertyName Files -NotePropertyValue $r.Files
                }
                $outcome.Bytes = $downloadedBytes
                Complete-MhStep
                #endregion

                #region Prove the file is the backup it claims to be
                if (-not $dryRun -and $toRestore.Count -gt 0) {
                    Start-MhStep 'Read the backup header on the destination'
                    # Deliberately before the destination database is touched: an unreadable staging
                    # folder or the wrong file shows up here, while nothing is broken yet. The full is
                    # the one worth proving; a cutover may have nothing but a tail log to apply.
                    $first = @($toRestore | Where-Object { $_.Label -eq 'full' })
                    if ($first.Count -eq 0) { $first = $toRestore[0] } else { $first = $first[0] }
                    $deviceList = (@($first.Set.Files) | ForEach-Object { "DISK = N'" + (Esc-MhStr $_) + "'" }) -join ', '
                    try {
                        $header = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query "RESTORE HEADERONLY FROM $deviceList"
                    }
                    catch {
                        $exception = $_.Exception.GetBaseException()
                        $number = 0
                        if ($exception -is [System.Data.SqlClient.SqlException]) { $number = $exception.Number }
                        if ($exception.Message -match 'Operating system error 5|Cannot open backup device') { $number = 3201 }
                        $explain = Get-MhSqlErrorExplanation -Number $number -Message $exception.Message
                        Write-MhDeep ('  header exception: ' + $exception.ToString())
                        throw ('Could not read the backup header: ' + ($exception.Message -split "`r?`n")[0] +
                               $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
                    }
                    $headerRow = $header.Rows[0]
                    Write-MhDetail ('  header: [{0}], finished {1}, taken on major version {2}' -f
                                  $headerRow['DatabaseName'], $headerRow['BackupFinishDate'], $headerRow['SoftwareVersionMajor'])
                    if ([string]$headerRow['DatabaseName'] -ne $dbName) {
                        Write-MhLog ('The file on disk is a backup of [{0}], not [{1}]. Check the file names{2}.' -f
                                   $headerRow['DatabaseName'], $dbName, $(if ($From -eq 'AzureBlob') { ' and -BlobPrefix' } else { '' })) -Level WARN
                    }
                    Complete-MhStep
                }
                #endregion

                #region Where the files go
                $moveList = $null
                if ($chain.Full -and -not $KeepFilePaths) {
                    Start-MhStep 'Work out where the database files go'
                    $fileList = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query (
                        'RESTORE FILELISTONLY FROM ' + ((@($toRestore[0].Set.Files) | ForEach-Object { "DISK = N'" + (Esc-MhStr $_) + "'" }) -join ', ') +
                        ' WITH FILE = ' + [int]$toRestore[0].Set.Position)
                    $moveList = @{}
                    foreach ($f in $fileList.Rows) {
                        $moveList[[string]$f['LogicalName']] = Get-MhMoveTarget -PhysicalName ([string]$f['PhysicalName']) -FileType ([string]$f['Type']) `
                                                                -DataPath $defaultData -LogPath $defaultLog -SourceDatabase $dbName -DestinationDatabase $dstName
                    }
                    foreach ($target in $moveList.Values) {
                        $owner = Get-DbCopyScalar -Server $script:DbCopyDestinationInstance -Parameters @{ '@p' = $target } -Query `
                                 'SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p'
                        if ($owner -and [string]$owner -ne $dstName) {
                            throw ("the file {0} already belongs to the database {1} on {2}. Use -DataPath / -LogPath to put the copy somewhere else." -f $target, $owner, $script:DbCopyDestinationInstance)
                        }
                    }
                    Write-MhDetail ('  {0} file(s) to {1}' -f $moveList.Count, $defaultData)
                    Complete-MhStep
                }
                #endregion

                #region Permission to go ahead
                if ($existing -and $chain.Full -and -not $isRestoring) {
                    $what = 'overwrite {0} on {1} with the backup of {2} taken {3}' -f $dstName, $script:DbCopyDestinationInstance, $dbName, $chain.Full.FinishDate
                    if (-not $isCopy) {
                        if (-not (Confirm-MhAction ($what + '. That database is NOT a copy of the source - everything in it will be lost. Continue?') 'Overwrite an unrelated database')) {
                            throw 'not overwritten'
                        }
                    }
                    elseif (-not $PSCmdlet.ShouldProcess(("{0} on {1}" -f $dstName, $script:DbCopyDestinationInstance), $what)) {
                        if (-not $dryRun) { throw 'not overwritten' }
                    }
                }

                if ($DisconnectDestination -and $existing -and -not $dryRun) {
                    $spids = Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Parameters @{ '@db' = $dstName } -Query `
                             'SELECT session_id FROM sys.dm_exec_sessions WHERE database_id = DB_ID(@db) AND session_id <> @@SPID'
                    if ($spids.Rows.Count) {
                        Write-MhLog ('{0} session(s) are using the copy, closing them' -f $spids.Rows.Count) -Level WARN
                        foreach ($s in $spids.Rows) {
                            try { [void](Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query ('KILL ' + [int]$s['session_id'])) } catch { }
                        }
                    }
                }
                #endregion

                #region The tail of the log, off the source
                if ($TailLog) {
                    Start-MhStep 'Back up the tail of the log on the source'
                    $folder = if ($TailLogPath) { $TailLogPath } else { $sourceBackupDir }
                    if (-not $folder) { throw 'nowhere to put the tail log backup: pass -TailLogPath' }
                    $tailFile = '{0}\{1}_tail_{2}.trn' -f $folder.TrimEnd('\'), $dbName, (Get-Date).ToString('yyyyMMdd_HHmmss')

                    # one question for everything that happens to the source, asked before any of it
                    # happens: being talked out of the tail log half way through would leave the source
                    # in single user for no reason at all
                    $ask = 'About to change the SOURCE database {0} on {1}:' -f $dbName, $script:DbCopySourceInstance
                    if ($DisconnectSource) { $ask += "`r`n  - close every connection to it (SINGLE_USER WITH ROLLBACK IMMEDIATE); open transactions are rolled back" }
                    $ask += "`r`n  - back up the tail of its log WITH NORECOVERY, which leaves it in a restoring state and unusable until someone recovers it."
                    $ask += "`r`nThat is what a cutover is, but there is no undo. Go ahead?"
                    if (-not (Confirm-MhAction $ask 'Cut over from the source database')) { throw 'the source was left alone, so nothing has been cut over' }

                    if ($DisconnectSource) {
                        $sql = 'ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' -f (Esc-MhName $dbName)
                        if ($dryRun) { Write-MhLog ('would run: ' + $sql) }
                        else {
                            Write-MhLog 'Closing connections to the source database' -Level WARN
                            [void](Invoke-DbCopySql -Server $script:DbCopySourceInstance -Query $sql)
                        }
                    }

                    $tailSql = "BACKUP LOG {0} TO DISK = N'{1}' WITH NORECOVERY, CHECKSUM, INIT, STATS = 5;" -f (Esc-MhName $dbName), (Esc-MhStr $tailFile)
                    if ($dryRun) { Write-MhLog ('would run: ' + $tailSql) }
                    else {
                        Write-MhLog "Backing the tail of the log up to $tailFile"
                        $r = Invoke-DbCopyLongSql -Server $script:DbCopySourceInstance -Sql $tailSql -Label 'tail log'
                        if (-not $r.Ok) { throw ('the tail log backup failed, so the source has not been changed: ' + $r.Error) }
                        Write-MhLog ('Taken in {0}s - the source database is now in a restoring state' -f $r.Seconds) -Level WARN
                    }

                    # the destination has to be able to read it, and it does not go through storage:
                    # waiting for an upload would defeat the point of a tail log
                    $tailPath = Resolve-DbCopyBackupPath -Path $tailFile -Map $script:DbCopyBackupPathMap
                    if (-not $dryRun -and -not (Test-DbCopyDestinationFile -Server $script:DbCopyDestinationInstance -Path $tailPath)) {
                        $viaShare = Get-DbCopyAdminSharePath -Path $tailPath -SourceHost $sourceHost
                        if ($viaShare -and (Test-DbCopyDestinationFile -Server $script:DbCopyDestinationInstance -Path $viaShare)) { $tailPath = $viaShare }
                        else {
                            throw ("the tail log is at {0} but {1} cannot read it. It is a valid backup: put it somewhere both servers can see - -TailLogPath on a share - and apply it by hand, then recover the copy." -f $tailPath, $script:DbCopyDestinationInstance)
                        }
                    }
                    $toRestore.Add([pscustomobject]@{
                        Set = [pscustomobject]@{ Position = 1; Files = @($tailPath); HasChecksums = $true }
                        Kind = 'Log'; Label = 'tail log'
                    })
                    Complete-MhStep
                }
                #endregion

                #region Restore
                Start-MhStep 'Restore on the destination'
                $target = "$script:DbCopyDestinationInstance.[$dstName]"
                if ($existing -and $chain.Full -and -not $isRestoring -and -not $dryRun) {
                    $priorState = $state
                    Write-MhLog "Taking $target offline (rolling back open transactions)"
                    [void](Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query ('ALTER DATABASE {0} SET OFFLINE WITH ROLLBACK IMMEDIATE;' -f (Esc-MhName $dstName)))
                }

                $applied = 0
                $seconds = 0.0
                try {
                    # everything was already applied, and all that is left is to bring it online
                    if ($Cutover -and $toRestore.Count -eq 0) {
                        $recoverSql = 'RESTORE DATABASE {0} WITH RECOVERY;' -f (Esc-MhName $dstName)
                        if ($dryRun) { Write-MhLog ('would run: ' + $recoverSql) }
                        else {
                            Write-MhLog 'Nothing left to apply, so recovering the copy as it stands'
                            $r = Invoke-DbCopyLongSql -Server $script:DbCopyDestinationInstance -Sql $recoverSql -Label 'recovery'
                            if (-not $r.Ok) { throw ('recovery failed: ' + $r.Error) }
                            $applied++
                        }
                    }
                    for ($i = 0; $i -lt $toRestore.Count; $i++) {
                        $item = $toRestore[$i]
                        $isLast = ($i -eq $toRestore.Count - 1)
                        $finish = 'NORECOVERY'
                        if ($isLast) {
                            if ($Cutover -or (-not $KeepRestoring)) { $finish = 'RECOVERY' }
                            elseif ($Standby) { $finish = 'STANDBY' }
                        }
                        $standbyFile = '{0}\{1}_standby.bak' -f $StandbyPath.TrimEnd('\'), $dstName
                        $sql = New-MhRestoreCommand -Database $dstName -BackupSet $item.Set -Kind $item.Kind -Finish $finish `
                                   -StandbyFile $standbyFile -MoveList $(if ($item.Label -eq 'full') { $moveList } else { $null }) `
                                   -Replace:($item.Label -eq 'full' -and $null -ne $existing) `
                                   -StopAt $(if ($chain.StopAtSet -and $item.Set -eq $chain.StopAtSet) { $stopAtValue } else { $null })

                        if ($dryRun) { Write-MhLog ("would run:`r`n" + $sql) ; continue }

                        Write-MhLog ("Restoring the {0}" -f $item.Label)
                        $r = Invoke-DbCopyLongSql -Server $script:DbCopyDestinationInstance -Sql $sql -Label $item.Label
                        if (-not $r.Ok) { throw ('{0} failed: {1}' -f $item.Label, $r.Error) }
                        $applied++
                        $seconds += $r.Seconds
                        $size = if ($r.Megabytes) { ', ' + (Format-MhSize ($r.Megabytes * 1MB)) } else { '' }
                        $rate = if ($r.Megabytes -and $r.Seconds -gt 0.5) { ' at {0:n0} MB/sec' -f ($r.Megabytes / $r.Seconds) } else { '' }
                        Write-MhDetail ('  {0} done in {1}s{2}{3}' -f $item.Label, $r.Seconds, $size, $rate)
                    }
                }
                catch {
                    # put the destination back as it was found, so a failed run does not leave it offline
                    if ($priorState -and $priorState -notin 'OFFLINE', 'RESTORING') {
                        Write-MhLog "The restore failed; putting $target back online" -Level WARN
                        try { [void](Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query ('ALTER DATABASE {0} SET ONLINE;' -f (Esc-MhName $dstName))) }
                        catch { Write-MhLog ('  could not bring it back online: ' + $_.Exception.Message) -Level ERROR }
                    }
                    throw
                }
                $outcome.Applied = $applied

                if ($dryRun) {
                    Write-MhLog ('{0} statement(s) would run, nothing was changed' -f $toRestore.Count)
                    $outcome.Result = 'DRY RUN'
                    $outcome.Action = 'WhatIf'
                    Complete-MhStep -Result 'SKIPPED'
                    continue
                }
                Complete-MhStep
                #endregion

                #region How it ended up
                $after = (Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }).Rows[0]
                $stateNow = [string]$after['state_desc']
                $reached = if ($TailLog) { Get-Date } elseif ($chain.Logs.Count) { $chain.Logs[-1].FinishDate } elseif ($chain.Diff) { $chain.Diff.FinishDate } elseif ($chain.Full) { $chain.Full.FinishDate } else { $null }
                $outcome.RestoredTo = $reached
                $restored = $true
                $online = (-not $KeepRestoring) -or $Cutover

                if ($online) {
                    if ($stateNow -ne 'ONLINE') { throw "the restores worked but the copy is $stateNow rather than online" }
                    # SINGLE_USER and RESTRICTED_USER live inside the database, so a copy of a source
                    # that was closed off comes back closed off, and nobody wants that
                    if ([string]$after['user_access_desc'] -ne 'MULTI_USER') {
                        [void](Invoke-DbCopySql -Server $script:DbCopyDestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-MhName $dstName)))
                        Write-MhLog ('The backup was taken while the database was {0}, so the copy has been opened up to MULTI_USER' -f ([string]$after['user_access_desc']).ToLower()) -Level WARN
                    }
                }
                #endregion

                #region Once it is online
                if ($online) {
                    if ($DatabaseOwner) {
                        Start-MhStep "Set the database owner to $DatabaseOwner"
                        $login = Get-DbCopyScalar -Server $script:DbCopyDestinationInstance -Parameters @{ '@n' = $DatabaseOwner } -Query `
                                 "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G')"
                        if (-not $login) {
                            Write-MhLog "There is no login called '$DatabaseOwner' on $script:DbCopyDestinationInstance, so the owner has been left as restored." -Level WARN
                            Complete-MhStep -Result 'SKIPPED'
                        }
                        else {
                            try {
                                Invoke-DbCopyStatement -Server $script:DbCopyDestinationInstance -DatabaseName $dstName `
                                    -Statement ('ALTER AUTHORIZATION ON DATABASE::{DB} TO ' + (Esc-MhName $DatabaseOwner) + ';')
                                Complete-MhStep
                            }
                            catch {
                                # a login cannot own the database and also be one of its users
                                Write-MhLog ("Could not make '{0}' the owner: {1} The owner has been left as restored." -f
                                           $DatabaseOwner, ($_.Exception.GetBaseException().Message -split "`r?`n")[0]) -Level WARN
                                Complete-MhStep -Result 'SKIPPED'
                            }
                        }
                    }

                    Start-MhStep 'Set PAGE_VERIFY CHECKSUM'
                    Invoke-DbCopyStatement -Server $script:DbCopyDestinationInstance -DatabaseName $dstName `
                        -Statement 'ALTER DATABASE {DB} SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;'
                    Complete-MhStep

                    if ($CompatibilityLevel -gt 0) {
                        Start-MhStep "Set compatibility level $CompatibilityLevel"
                        Invoke-DbCopyStatement -Server $script:DbCopyDestinationInstance -DatabaseName $dstName `
                            -Statement "ALTER DATABASE {DB} SET COMPATIBILITY_LEVEL = $CompatibilityLevel;"
                        Complete-MhStep
                    }

                    if ($RepairOrphanUsers) {
                        Start-MhStep 'Point database users back at the destination logins'
                        $users = Repair-DbCopyOrphanUser -Server $script:DbCopyDestinationInstance -DatabaseName $dstName
                        if ($users.Remapped.Count) { Write-MhLog ('Remapped {0} user(s): {1}' -f $users.Remapped.Count, ($users.Remapped -join ', ')) }
                        if ($users.Blocked.Count) {
                            Write-MhLog ('Could not remap {0}: the login of that name is already mapped to another user here, usually because it owns the database. Drop or rename the user if it is still wanted.' -f ($users.Blocked -join ', ')) -Level WARN
                        }
                        if (-not $users.Remapped.Count -and -not $users.Blocked.Count) { Write-MhDetail '  no orphaned users to remap' }
                        Complete-MhStep
                    }

                    if ($UpdateStatistics) {
                        Start-MhStep 'Update statistics'
                        $r = Invoke-DbCopyLongSql -Server $script:DbCopyDestinationInstance -Label 'statistics' `
                                -Sql ('EXEC {0}.sys.sp_updatestats;' -f (Esc-MhName $dstName))
                        if (-not $r.Ok) { throw ('updating statistics failed: ' + $r.Error) }
                        Complete-MhStep
                    }

                    if ($RunCheckDb) {
                        Start-MhStep 'DBCC CHECKDB WITH DATA_PURITY'
                        $r = Invoke-DbCopyLongSql -Server $script:DbCopyDestinationInstance -Label 'checkdb' `
                                -Sql ('DBCC CHECKDB ({0}) WITH DATA_PURITY, NO_INFOMSGS, ALL_ERRORMSGS;' -f (Esc-MhName $dstName))
                        if (-not $r.Ok) { throw ('DBCC CHECKDB reported a problem: ' + $r.Error) }
                        Write-MhLog 'DBCC CHECKDB found nothing to report'
                        Complete-MhStep
                    }
                }
                #endregion

                #region Tidy up and say how it went
                if ($From -eq 'AzureBlob' -and -not $KeepLocalCopy -and $script:DbCopyStagedList.Count -gt 0) {
                    Start-MhStep 'Remove the staged copy'
                    foreach ($file in $script:DbCopyStagedList) {
                        Write-MhDetail "  removing $file"
                        try { Remove-Item -LiteralPath $file -Force } catch { Write-MhLog ('  could not remove ' + $file + ': ' + $_.Exception.Message) -Level WARN }
                    }
                    Complete-MhStep
                }

                if ($Cutover) {
                    Write-MhLog ('Cut over: {0} is online, {1} restore(s) in {2}s' -f $target, $applied, [math]::Round($seconds, 1))
                    Write-MhLog 'Still to do by hand: logins and orphaned users, jobs, linked servers, and the connection strings' -Min Verbose
                    if ($TailLog) { Write-MhLog ('{0} on {1} is in a restoring state. Leave it there until you are happy, then RESTORE DATABASE ... WITH RECOVERY puts it back.' -f $dbName, $script:DbCopySourceInstance) -Level WARN }
                    $outcome.Result = 'CUT OVER'
                    $outcome.Action = 'Cutover'
                }
                elseif ($KeepRestoring) {
                    Write-MhLog ('{0} applied, copy {1} and up to {2}' -f $applied,
                               $(if ([bool]$after['is_in_standby']) { 'readable in standby' } else { 'left restoring' }),
                               $(if ($reached) { $reached.ToString('dd MMM HH:mm') } else { 'date unknown' }))
                    Write-MhLog ('Run the same command again to apply the logs taken after {0}, and add -Cutover -TailLog when you are ready to switch' -f $(if ($reached) { $reached.ToString('HH:mm') } else { 'now' })) -Min Verbose
                    $outcome.Result = 'ROLLING'
                    $outcome.Action = 'Rolling'
                }
                else {
                    Write-MhLog ('Restored and online, {0} restore(s) in {1}s, data as at {2}' -f $applied, [math]::Round($seconds, 1), $reached.ToString('dd MMM HH:mm'))
                    $outcome.Result = 'RESTORED'
                    $outcome.Action = 'Refresh'
                }
                if ($chain.Gap) { $outcome.Detail = $chain.Gap }
                #endregion
            }
            catch {
                if (Test-MhStepOpen) { Complete-MhStep -Result 'FAILED' }
                $exception = $_.Exception.GetBaseException()
                $outcome.Result = 'FAILED'
                $outcome.Detail = ($exception.Message -split "`r?`n")[0]
                Write-MhLog ('[{0}] {1}' -f $dbName, $outcome.Detail) -Level ERROR
                foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
                    Write-MhLog "  $extra" -Level ERROR
                }
                if ($exception -is [System.Data.SqlClient.SqlException]) {
                    $explain = Get-MhSqlErrorExplanation -Number $exception.Number -Message $exception.Message
                    if ($explain.Meaning) { Write-MhLog ('  what it means: ' + $explain.Meaning) -Level ERROR }
                    if ($explain.Fix) { Write-MhLog ('  what to try: ' + $explain.Fix) -Level WARN }
                }
                Write-MhDeep ('full exception: ' + $exception.ToString())
                if ($_.ScriptStackTrace) { Write-MhDeep ('at: ' + $_.ScriptStackTrace) }
                if ($script:DbCopyStagedList.Count -gt 0 -and -not $restored) {
                    Write-MhLog ('  the staged file(s) have been left in {0} for investigation' -f $script:DbCopyLocalBackupPath) -Level WARN
                }
                if ($databases.Count -gt 1) { Write-MhLog '  carrying on with the remaining database(s)' -Level WARN }
            }
            finally {
                Set-MhLogPrefix ''
                $results.Add($outcome)
            }
        }
    }
    catch [System.Management.Automation.HaltCommandException] {
        # -TestConnectionOnly finishing early, not a failure
    }
    catch {
        if (Test-MhStepOpen) { Complete-MhStep -Result 'FAILED' }
        $exception = $_.Exception.GetBaseException()
        Write-MhLog ($exception.Message -split "`r?`n")[0] -Level ERROR
        foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
            Write-MhLog "  $extra" -Level ERROR
        }
        Write-MhDeep ('full exception: ' + $exception.ToString())
        if ($_.ScriptStackTrace) { Write-MhDeep ('at: ' + $_.ScriptStackTrace) }
        if (-not (Test-MhLogAtLeast 'Verbose')) {
            Write-MhLog 'Run again with -LogLevel Verbose (or Debug) for more, or -TestConnectionOnly to check the instances on their own.' -Level WARN
        }
    }
    finally {
        $elapsed = (Get-Date) - $runStart
        Write-MhLog '---------------- Run summary ----------------' -Min Quiet
        Write-MhLog "Source:       $script:DbCopySourceInstance" -Min Quiet
        Write-MhLog "Destination:  $script:DbCopyDestinationInstance" -Min Quiet
        Write-MhLog ("Backups:      {0}" -f $(if ($From -eq 'AzureBlob') { "staged from $StorageAccountName/$script:DbCopyContainerName" } else { 'read where msdb says they are' })) -Min Quiet
        foreach ($outcome in $results) {
            $name = if ($outcome.DestinationDatabase -ne $outcome.Database) { '{0} -> {1}' -f $outcome.Database, $outcome.DestinationDatabase } else { $outcome.Database }
            $line = '{0,-12} {1}' -f $outcome.Result, $name
            if ($outcome.RestoredTo) { $line += ' (data as at {0})' -f $outcome.RestoredTo }
            if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
            Write-MhLog $line -Level $(if ($outcome.Result -eq 'FAILED') { 'ERROR' } elseif ($outcome.Result -eq 'CHECK') { 'WARN' } else { 'INFO' }) -Min Quiet
        }
        if (Test-MhLogAtLeast 'Normal') {
            foreach ($step in (Get-MhLogStep)) { Write-MhLog ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
        }
        $failedCount = @($results | Where-Object { $_.Result -eq 'FAILED' }).Count
        $doneCount = @($results | Where-Object { $_.Result -in 'RESTORED', 'CUT OVER', 'ROLLING', 'ALREADY DONE' }).Count
        $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
                   elseif ($TestConnectionOnly) { 'CONNECTION CHECK' }
                   elseif ($failedCount -gt 0 -and $doneCount -gt 0) { "PARTLY DONE ($doneCount of $($results.Count))" }
                   elseif ($failedCount -gt 0) { 'FAILED' }
                   elseif ($doneCount -gt 0) { 'DONE' }
                   else { 'NOTHING DONE' }
        $bad = (-not $setupDone) -or $failedCount -gt 0
        Write-MhLog ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) -Level $(if ($bad) { 'ERROR' } else { 'INFO' }) -Min Quiet
        if ($LogFile) { Write-MhLog "Log file:     $LogFile" -Min Quiet }

        if ($CsvPath -and $results.Count) {
            $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
            Write-MhLog "Saved to      $CsvPath" -Min Quiet
        }
    }
    # the shim turns this into an exit code; a caller gets every database's outcome
    [pscustomobject]@{
        SourceInstance      = $SourceInstance
        DestinationInstance = $DestinationInstance
        Databases           = $results.ToArray()   # @() on a generic list throws
        Steps               = @(Get-MhLogStep)
        Result              = $overall
        DryRun              = [bool]$dryRun
        Elapsed             = $elapsed
        Ok                  = -not $bad
    }
}

function Format-DbCopyStamp {
    [CmdletBinding()]
    param([AllowNull()] $Value, [string] $Format = 'dd MMM yyyy HH:mm')

    if ($null -eq $Value) { return '(no date)' }
    try { (ConvertTo-MhUtcTime $Value).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture) + ' UTC' }
    catch { '(unreadable date)' }
}

function Select-DbCopyBackupChain {
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

function Resolve-DbCopyBackupPath {
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

function Get-DbCopyAdminSharePath {
    [CmdletBinding()]
    param([string] $Path, [string] $SourceHost)

    if (-not $SourceHost -or $Path -notmatch '^[A-Za-z]:\\') { return $null }
    '\\{0}\{1}$\{2}' -f $SourceHost, $Path.Substring(0, 1), $Path.Substring(3)
}

function Get-DbCopyCredentialFor([string] $Server) {
    if ($Server -eq $script:DbCopySourceInstance -and $script:DbCopySourceSqlCredential) { return $script:DbCopySourceSqlCredential }
    if ($Server -eq $script:DbCopyDestinationInstance -and $script:DbCopyDestinationSqlCredential) { return $script:DbCopyDestinationSqlCredential }
    $script:DbCopySqlCredential
}

function Select-DbCopyAvailableSets {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $BackupSets,
        [AllowEmptyCollection()] [string[]] $AvailableFiles
    )

    $available = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $AvailableFiles) { if ($name) { [void]$available.Add($name) } }

    $kept = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    foreach ($set in @($BackupSets)) {
        $missing = @(@($set.Files) | ForEach-Object { [System.IO.Path]::GetFileName($_) } |
                     Where-Object { -not $available.Contains($_) })
        if ($missing.Count -eq 0) { $kept.Add($set) }
        else { $skipped.Add([pscustomobject]@{ Set = $set; Missing = $missing }) }
    }
    [pscustomobject]@{ Kept = $kept.ToArray(); Skipped = $skipped.ToArray() }
}

function Test-DbCopyDestinationFile {
    [CmdletBinding()]
    param([string] $Server, [string] $Path)

    if (-not $script:DbCopyFileCheckWorks) { return $true }
    try {
        $sql = "DECLARE @r TABLE (FileExists bit, IsDir bit, ParentExists bit);
                INSERT @r EXEC master.dbo.xp_fileexist @p;
                SELECT TOP (1) FileExists FROM @r;"
        [bool](Get-DbCopyScalar -Server $Server -Query $sql -Parameters @{ '@p' = $Path })
    }
    catch {
        Write-MhDetail "  cannot use xp_fileexist on the destination ($(($_.Exception.Message -split "`r?`n")[0])), so file paths are not checked in advance"
        $script:DbCopyFileCheckWorks = $false
        $true
    }
}

function Connect-DbCopyBlobContainer {
    [CmdletBinding()]
    param([string] $AccountName, [string] $Container, [string] $Prefix, [object] $Sas)

    # a quick name check first: an account that does not exist otherwise takes Azure's six retries
    # and the best part of half a minute to say so
    try { [void][System.Net.Dns]::GetHostAddresses("$AccountName.blob.core.windows.net") }
    catch {
        throw "The storage account '$AccountName' does not resolve ($AccountName.blob.core.windows.net). Check the name - it is the account name on its own, not a URL."
    }

    $sasPlain = ConvertTo-MhPlainSas -Token $Sas
    Write-MhDeep ('  SAS parameters present: ' + (($sasPlain -split '&' | ForEach-Object { ($_ -split '=')[0] }) -join ', '))
    $context = New-AzStorageContext -StorageAccountName $AccountName -SasToken $sasPlain
    $sasPlain = $null

    $listSplat = @{ Container = $Container; Context = $context }
    if ($Prefix) { $listSplat.Prefix = $Prefix.Trim('/') + '/' }
    try { $blobs = @(Get-AzStorageBlob @listSplat) }
    catch {
        $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
        Write-MhDeep ('  storage exception: ' + $_.Exception.ToString())
        $hint = if ($message -match '403|not authorized|AuthenticationFailed|Signature') {
            'The SAS token was refused: it may have expired, be missing List permission (sp=rl at least), be for a different account, or have a start time in the future. Check the sv, se and sp values.'
        }
        elseif ($message -match '404|ContainerNotFound|does not exist') { "No container called '$Container' in the account '$AccountName'." }
        elseif ($message -match 'No such host|could not be resolved|Retry failed after') { "Could not reach '$AccountName.blob.core.windows.net'. Check that this machine can reach Azure Storage." }
        elseif ($message -match 'Method not found') { 'Two different versions of the Azure libraries are loaded in this session. Start a fresh PowerShell session and run this again.' }
        else { '' }
        throw ("Could not list the container: $message" + $(if ($hint) { " $hint" } else { '' }))
    }

    $index = @{}
    foreach ($blob in $blobs) {
        $leaf = ($blob.Name -split '/')[-1]
        if (-not $index.ContainsKey($leaf) -or (ConvertTo-MhUtcTime $blob.LastModified) -gt (ConvertTo-MhUtcTime $index[$leaf].LastModified)) { $index[$leaf] = $blob }
        Write-MhDeep ('  blob {0} ({1})' -f $blob.Name, (Format-MhSize $blob.Length))
    }
    Write-MhLog "Found $($blobs.Count) blob(s) under '$Container/$Prefix'"
    if ($blobs.Count -eq 0) {
        Write-MhLog 'The container listing came back empty. If the backups sit in a folder, -BlobPrefix has to name it (a parent folder is enough when several databases share one).' -Level WARN
    }
    [pscustomobject]@{ Context = $context; Index = $index; Count = $blobs.Count }
}

function Resolve-DbCopyBackupFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Files,
        [Parameter(Mandatory)] [string] $DestinationServer,
        [string] $SourceHost,
        [switch] $Download
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    $bytes = 0
    foreach ($file in $Files) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($Download) {
            if (-not $script:DbCopyBlobList.Index.ContainsKey($leaf)) {
                throw "The container has no blob called '$leaf'. The blob name after any folder must match the file name recorded in msdb."
            }
            $target = Join-Path -Path $script:DbCopyLocalBackupPath -ChildPath $leaf
            if ($PSCmdlet.ShouldProcess($leaf, "Download to $target")) {
                $bytes += Get-MhBlobToFile -Context $script:DbCopyBlobList.Context -Container $script:DbCopyContainerName `
                                         -Blob $script:DbCopyBlobList.Index[$leaf] -TargetPath $target
                $script:DbCopyStagedList.Add($target)
            }
            $resolved.Add($target)
            continue
        }

        $path = Resolve-DbCopyBackupPath -Path $file -Map $script:DbCopyBackupPathMap
        if (-not (Test-DbCopyDestinationFile -Server $DestinationServer -Path $path)) {
            $viaShare = Get-DbCopyAdminSharePath -Path $path -SourceHost $SourceHost
            if ($viaShare -and (Test-DbCopyDestinationFile -Server $DestinationServer -Path $viaShare)) {
                Write-MhDetail ('  {0} is not visible to the destination, using {1}' -f $path, $viaShare)
                $path = $viaShare
            }
            else {
                throw ("{0} cannot read the backup file {1}{2}. Put the backups somewhere both servers can see, map the path with -BackupPathMap, or stage them through storage with -From AzureBlob." -f
                       $DestinationServer, $path, $(if ($viaShare) { " (nor $viaShare)" } else { '' }))
            }
        }
        $resolved.Add($path)
    }
    [pscustomobject]@{ Files = $resolved.ToArray(); Bytes = $bytes }
}

function Repair-DbCopyOrphanUser {
    [CmdletBinding()]
    param([string] $Server, [string] $DatabaseName)

    $sql = @'
SET NOCOUNT ON;
DECLARE @result TABLE (UserName sysname, Outcome varchar(10));
DECLARE @name sysname, @taken bit, @sql nvarchar(max);
DECLARE orphans CURSOR LOCAL FAST_FORWARD FOR
    SELECT dp.name,
           CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals x WHERE x.sid = sp.sid)
                             THEN 1 ELSE 0 END)
    FROM sys.database_principals AS dp
    JOIN sys.server_principals AS sp ON sp.name = dp.name
    WHERE dp.type IN ('S', 'U', 'G')
      AND dp.sid IS NOT NULL
      AND dp.sid <> sp.sid
      AND dp.authentication_type <> 2          -- leave contained users alone
      AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys');
OPEN orphans;
FETCH NEXT FROM orphans INTO @name, @taken;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @taken = 1
        INSERT @result (UserName, Outcome) VALUES (@name, 'blocked');
    ELSE
    BEGIN
        SET @sql = N'ALTER USER ' + QUOTENAME(@name) + N' WITH LOGIN = ' + QUOTENAME(@name) + N';';
        EXEC sys.sp_executesql @sql;
        INSERT @result (UserName, Outcome) VALUES (@name, 'remapped');
    END
    FETCH NEXT FROM orphans INTO @name, @taken;
END
CLOSE orphans;
DEALLOCATE orphans;
SELECT UserName, Outcome FROM @result;
'@
    $rows = Invoke-DbCopySql -Server $Server -Query $sql -DatabaseName $DatabaseName
    [pscustomobject]@{
        Remapped = @($rows.Rows | Where-Object { [string]$_['Outcome'] -eq 'remapped' } | ForEach-Object { [string]$_['UserName'] })
        Blocked  = @($rows.Rows | Where-Object { [string]$_['Outcome'] -eq 'blocked' } | ForEach-Object { [string]$_['UserName'] })
    }
}

function Import-DbCopyBackupHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "No backup history file at $Path" }

    $columns = 'backup_set_id', 'backup_set_uuid', 'type', 'position', 'first_lsn', 'last_lsn',
               'checkpoint_lsn', 'database_backup_lsn', 'backup_start_date', 'backup_finish_date',
               'database_name', 'family_guid', 'is_copy_only', 'has_backup_checksums', 'backup_size',
               'software_major_version', 'key_algorithm', 'physical_device_name', 'family_sequence_number'

    $lines = @(Get-Content -LiteralPath $Path -TotalCount 5 | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { throw "$Path is empty. Check that Export-BackupHistory.sql returned rows on the source." }
    $sample = $lines[0]

    # whichever separator carves the first line into the right number of fields
    $delimiter = $null
    foreach ($candidate in ',', '|', "`t", ';') {
        if (($sample -split [regex]::Escape($candidate)).Count -eq $columns.Count) { $delimiter = $candidate; break }
    }
    if (-not $delimiter) {
        throw ("Cannot make sense of $Path : its first line has " + (($sample -split ',').Count) +
               " comma separated field(s) and $($columns.Count) are expected. It has to be the output of Tools\Export-BackupHistory.sql.")
    }
    $shown = switch ($delimiter) { "`t" { 'tab' } default { "'$delimiter'" } }

    $hasHeader = $sample -match '(^|\W)backup_set_id(\W|$)'
    if ($hasHeader) { $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter) }
    else { $rows = @(Import-Csv -LiteralPath $Path -Delimiter $delimiter -Header $columns) }
    Write-MhDetail ('  {0}, {1} separated, {2} header line' -f $Path, $shown, $(if ($hasHeader) { 'with a' } else { 'with no' }))

    # sqlcmd writes a row of dashes under the header when it is left on
    $rows = @($rows | Where-Object { [string]$_.backup_set_id -notmatch '^-+$' -and ([string]$_.backup_set_id).Trim() })
    if ($rows.Count -eq 0) { throw "$Path has no data rows in it." }

    $have = @($rows[0].PSObject.Properties.Name)
    $missing = @($columns | Where-Object { $have -notcontains $_ })
    if ($missing.Count) {
        throw ("$Path is missing the column(s) " + ($missing -join ', ') + '. It has to be the output of Tools\Export-BackupHistory.sql.')
    }
    foreach ($row in $rows) {
        foreach ($name in $columns) { $row.$name = ([string]$row.$name).Trim() }
    }
    Write-MhDetail ('  {0} history row(s) read' -f $rows.Count)
    $rows
}

function Read-DbCopyHistoryDate {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $clean = ([string]$Text).Trim()
    $formats = @('yyyy-MM-ddTHH:mm:ss.fff', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-dd HH:mm:ss.fff', 'yyyy-MM-dd HH:mm:ss')
    foreach ($format in $formats) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($clean, $format, [System.Globalization.CultureInfo]::InvariantCulture,
                                      [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }
    # last resort, in case someone saved the file through something that reformatted the dates
    [datetime]::Parse($clean, [System.Globalization.CultureInfo]::CurrentCulture)
}

Register-MhSelfTest -Name 'Restore-MhDatabaseCopy' -Test {
    $t0 = Get-Date '2026-10-05 22:00'
    function Set_([string]$Type, [int]$First, [int]$Last, [int]$Mins, [hashtable]$More = @{}) {
        $o = @{ Type = $Type; FirstLsn = [decimal]$First; LastLsn = [decimal]$Last
                CheckpointLsn = [decimal]$First; DatabaseBackupLsn = [decimal]0
                FinishDate = $t0.AddMinutes($Mins); Position = 1; HasChecksums = $true
                Files = @('D:\B\f.bak'); FamilyGuid = 'FAM1'; Uuid = [guid]::NewGuid().ToString() }
        foreach ($k in $More.Keys) { $o[$k] = $More[$k] }
        [pscustomobject]$o
    }

    Test-MhSection 'the chain'

    $full1 = Set_ 'D' 100 200 0
    $full2 = Set_ 'D' 500 600 600
    $diff  = Set_ 'I' 600 700 630 @{ DatabaseBackupLsn = [decimal]500 }
    $log1  = Set_ 'L' 200 300 60
    $log2  = Set_ 'L' 300 400 120
    $log3  = Set_ 'L' 600 700 660
    $log4  = Set_ 'L' 700 800 700
    $log5  = Set_ 'L' 800 900 760

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $full2, $log1, $log2) -NoDifferential
    Test-MhCheck 'takes the newest full' ($c.Full -eq $full2)
    Test-MhCheck 'and no logs that predate it' ($c.Logs.Count -eq 0)

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2)
    Test-MhCheck 'follows the logs after the full' ($c.Logs.Count -eq 2 -and $c.Logs[0] -eq $log1 -and $c.Logs[1] -eq $log2)

    $c = Select-DbCopyBackupChain -BackupSets @($full2, $diff, $log3, $log4, $log5)
    Test-MhCheck 'uses the differential that belongs to the full' ($c.Diff -eq $diff)
    Test-MhCheck 'and skips the logs the differential already covers' ($c.Logs.Count -eq 2 -and $c.Logs[0] -eq $log4)

    $c = Select-DbCopyBackupChain -BackupSets @($full2, $diff, $log3, $log4, $log5) -NoDifferential
    Test-MhCheck '-NoDifferential goes the long way round' ($null -eq $c.Diff -and $c.Logs.Count -eq 3)

    $orphan = Set_ 'I' 600 700 630 @{ DatabaseBackupLsn = [decimal]999 }
    $c = Select-DbCopyBackupChain -BackupSets @($full2, $orphan)
    Test-MhCheck 'ignores a differential from another full' ($null -eq $c.Diff)

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2) -LastRestoredLsn ([decimal]300)
    Test-MhCheck 'catching up applies only the new logs' ($null -eq $c.Full -and $c.Logs.Count -eq 1 -and $c.Logs[0] -eq $log2)

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2) -LastRestoredLsn ([decimal]400)
    Test-MhCheck 'nothing new is not an error' ($c.Logs.Count -eq 0 -and $null -eq $c.Error -and $null -eq $c.Gap)

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log5) -LastRestoredLsn ([decimal]300)
    Test-MhCheck 'a broken chain is an error, not a surprise later' ($null -ne $c.Error) $c.Error

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2, $log5)
    Test-MhCheck 'a gap mid-chain restores what it can' ($c.Logs.Count -eq 2 -and $null -ne $c.Gap)

    $wide = Set_ 'L' 200 400 90      # one log covering the same ground as two others
    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2, $wide)
    Test-MhCheck 'prefers the backup that reaches furthest' ($c.Logs.Count -eq 1 -and $c.Logs[0] -eq $wide)

    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $log2) -StopAt $t0.AddMinutes(90)
    Test-MhCheck 'stops at a point in time' ($c.Logs.Count -eq 2 -and $c.StopAtSet -eq $log2)

    $c = Select-DbCopyBackupChain -BackupSets @($full2, $full1, $log1) -StopAt $t0.AddMinutes(90)
    Test-MhCheck 'and seeds from the full that was taken before it' ($c.Full -eq $full1)

    $c = Select-DbCopyBackupChain -BackupSets @()
    Test-MhCheck 'no backups at all says so' ($null -ne $c.Error)

    $other = Set_ 'L' 300 400 120 @{ FamilyGuid = 'FAM2' }
    $c = Select-DbCopyBackupChain -BackupSets @($full1, $log1, $other) -FamilyGuid 'FAM1'
    Test-MhCheck 'ignores backups of a different database lineage' ($c.Logs.Count -eq 1)

    Test-MhSection 'the statements'
    $sql = New-MhRestoreCommand -Database 'Sales Copy' -BackupSet (Set_ 'D' 1 2 0 @{ Position = 3; Files = @('D:\B\a.bak', 'D:\B\b.bak') }) `
                              -MoveList @{ 'Sales' = 'E:\Data\SalesCopy.mdf'; 'Sales_log' = 'F:\Log\SalesCopy.ldf' } -Finish 'NORECOVERY'
    Test-MhCheck 'striped backups list every file' (($sql -split 'DISK =').Count -eq 3)
    Test-MhCheck 'the backup set position is used' ($sql -match 'FILE = 3')
    Test-MhCheck 'files are relocated' ($sql -match "MOVE N'Sales' TO N'E:\\Data\\SalesCopy\.mdf'")
    Test-MhCheck 'the database name is bracketed' ($sql -match '\[Sales Copy\]')
    Test-MhCheck 'left restoring when asked' ($sql -match 'NORECOVERY' -and $sql -notmatch 'STANDBY')
    Test-MhCheck 'checksums are verified when the backup has them' ($sql -match 'CHECKSUM')

    $sql = New-MhRestoreCommand -Database 'Sales' -Kind 'Log' -BackupSet (Set_ 'L' 1 2 0) -Finish 'RECOVERY' -StopAt $t0
    Test-MhCheck 'a log restore is a RESTORE LOG' ($sql -match '^RESTORE LOG')
    Test-MhCheck 'point in time becomes STOPAT' ($sql -match "STOPAT = N'2026-10-05T22:00:00'")

    $sql = New-MhRestoreCommand -Database 'Sales' -BackupSet (Set_ 'D' 1 2 0) -Finish 'STANDBY' -StandbyFile 'E:\Data\Sales.standby' -Replace
    Test-MhCheck 'standby names its undo file' ($sql -match "STANDBY = N'E:\\Data\\Sales\.standby'")
    Test-MhCheck 'REPLACE only when asked for' ($sql -match 'REPLACE')

    $sql = New-MhRestoreCommand -Database "O'Brien" -BackupSet (Set_ 'D' 1 2 0 @{ Files = @("D:\B\o'b.bak") })
    Test-MhCheck 'quotes and brackets are escaped' ($sql -match "\[O'Brien\]" -and $sql -match "o''b\.bak")

    Test-MhSection 'paths'
    $map = @{ 'D:\Backup' = '\\SQL01\Backup$'; 'D:\Backup\Logs' = '\\SQL01\Logs$' }
    Test-MhCheck 'the longest matching prefix wins' ((Resolve-DbCopyBackupPath -Path 'D:\Backup\Logs\a.trn' -Map $map) -eq '\\SQL01\Logs$\a.trn')
    Test-MhCheck 'other paths map too' ((Resolve-DbCopyBackupPath -Path 'D:\Backup\a.bak' -Map $map) -eq '\\SQL01\Backup$\a.bak')
    Test-MhCheck 'an unmapped path is left alone' ((Resolve-DbCopyBackupPath -Path 'E:\Other\a.bak' -Map $map) -eq 'E:\Other\a.bak')
    Test-MhCheck 'the admin share is the fallback' ((Get-DbCopyAdminSharePath -Path 'D:\Backup\a.bak' -SourceHost 'SQL01') -eq '\\SQL01\D$\Backup\a.bak')
    Test-MhCheck 'a UNC path has no admin share form' ($null -eq (Get-DbCopyAdminSharePath -Path '\\x\y\a.bak' -SourceHost 'SQL01'))

    Test-MhCheck 'data files go to the data path' ((Get-MhMoveTarget -PhysicalName 'X:\old\Sales.mdf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log') -eq 'E:\Data\Sales.mdf')
    Test-MhCheck 'log files go to the log path' ((Get-MhMoveTarget -PhysicalName 'X:\old\Sales_log.ldf' -FileType 'L' -DataPath 'E:\Data' -LogPath 'F:\Log') -eq 'F:\Log\Sales_log.ldf')
    Test-MhCheck 'a renamed copy gets renamed files' ((Get-MhMoveTarget -PhysicalName 'X:\old\Sales.mdf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log' -SourceDatabase 'Sales' -DestinationDatabase 'SalesTest') -eq 'E:\Data\SalesTest.mdf')
    Test-MhCheck 'an unrelated file name is kept' ((Get-MhMoveTarget -PhysicalName 'X:\old\extra1.ndf' -FileType 'D' -DataPath 'E:\Data' -LogPath 'F:\Log' -SourceDatabase 'Sales' -DestinationDatabase 'SalesTest') -eq 'E:\Data\extra1.ndf')

    Test-MhSection 'instance names'
    $p = Split-MhSqlInstanceName 'SQL01'
    Test-MhCheck 'a bare name is the default instance on 1433' ($p.Computer -eq 'SQL01' -and $p.Instance -eq '' -and $p.Port -eq 1433)
    $p = Split-MhSqlInstanceName 'SQL01\SALES'
    Test-MhCheck 'a named instance has no port until Browser says' ($p.Computer -eq 'SQL01' -and $p.Instance -eq 'SALES' -and $p.Port -eq 0)
    $p = Split-MhSqlInstanceName 'SQL01,14330'
    Test-MhCheck 'a comma is a port' ($p.Computer -eq 'SQL01' -and $p.Port -eq 14330)
    $p = Split-MhSqlInstanceName 'sql01.contoso.com\SALES,1433'
    Test-MhCheck 'a full name with instance and port' ($p.Computer -eq 'sql01.contoso.com' -and $p.Instance -eq 'SALES' -and $p.Port -eq 1433)
    $p = Split-MhSqlInstanceName 'tcp:SQL01'
    Test-MhCheck 'a protocol prefix is dropped' ($p.Computer -eq 'SQL01')
    $p = Split-MhSqlInstanceName '.'
    Test-MhCheck 'a dot is the local machine' ($p.Computer -eq 'localhost')

    Test-MhSection 'explaining failures'
    $e = Get-MhSqlErrorExplanation -Number 18456 -Message "Login failed for user 'sa'. Reason: ... [CLIENT: 10.0.0.1] State: 8"
    Test-MhCheck 'login failed is explained' ($e.Meaning -match '18456' -and $e.Meaning -match 'password is wrong')
    $e = Get-MhSqlErrorExplanation -Number 18456 -Message "Login failed for user 'CONTOSO\jo'. State: 5"
    Test-MhCheck 'and state 5 means no such login' ($e.Meaning -match 'does not exist')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'A connection was successfully established with the server, but then an error occurred during the pre-login handshake.'
    Test-MhCheck 'the 2008 R2 encryption trap is named' ($e.Fix -match 'TrustServerCertificate')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'The certificate chain was issued by an authority that is not trusted.'
    Test-MhCheck 'so is an untrusted certificate' ($e.Fix -match 'TrustServerCertificate')
    $e = Get-MhSqlErrorExplanation -Number -2 -Message 'Timeout expired'
    Test-MhCheck 'a timeout blames the firewall, not the password' ($e.Fix -match 'firewall')
    $e = Get-MhSqlErrorExplanation -Number 3201 -Message 'Cannot open backup device'
    Test-MhCheck 'a backup device error points at the service account' ($e.Fix -match 'SERVICE ACCOUNT')
    $e = Get-MhSqlErrorExplanation -Number 5 -Message 'Access is denied.'
    Test-MhCheck 'so does access denied' ($e.Fix -match 'service account')
    $e = Get-MhSqlErrorExplanation -Number 3169 -Message 'backed up on a server running version 16.00'
    Test-MhCheck 'a too-new backup is explained' ($e.Meaning -match 'newer version')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'error: 26 - Error Locating Server/Instance Specified'
    Test-MhCheck 'a missing named instance points at SQL Browser' ($e.Fix -match 'SQL Browser')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message "A parameter cannot be found that matches parameter name 'EnableException'."
    Test-MhCheck 'and a script fault is called a script fault' ($e.Meaning -match 'fault in the script')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'The client and server cannot communicate, because they do not possess a common algorithm'
    Test-MhCheck 'an encryption mismatch is told apart from a certificate problem' ($e.Meaning -match 'not a certificate')
    Test-MhCheck 'and says the certificate switch will not fix it' ($e.Fix -match 'will not help')
    Test-MhCheck 'and sends you to the tool that measures it' ($e.Fix -match 'Test-SqlTlsHandshake')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'The wait operation timed out'
    Test-MhCheck 'a bare timeout is explained as a timeout' ($e.Meaning -match 'did not answer' -and $e.Fix -match 'firewall')
    $e = Get-MhSqlErrorExplanation -Number 0 -Message 'something nobody has seen before'
    Test-MhCheck 'an unknown error explains nothing rather than guessing' ($e.Meaning -eq '')

    Test-MhSection 'did it reach the server'
    Test-MhCheck 'an error number means it did' (Test-MhReachedServer -Number 18456 -Message 'Login failed')
    Test-MhCheck 'a rejected certificate means it did' (Test-MhReachedServer -Number 0 -Message 'The certificate chain was issued by an authority that is not trusted')
    Test-MhCheck 'a pre-login handshake failure means it did' (Test-MhReachedServer -Number 0 -Message 'error occurred during the pre-login handshake')
    Test-MhCheck 'a timeout means it did not' (-not (Test-MhReachedServer -Number 0 -Message 'The wait operation timed out'))
    Test-MhCheck 'and nor does an unreachable name' (-not (Test-MhReachedServer -Number 0 -Message 'No such host is known'))

    Test-MhSection 'asking SQL Browser'
    $none = @(Get-MhSqlBrowserInstances -Computer 'no-such-host-xyz.invalid' -TimeoutMs 500)
    Test-MhCheck 'a host that cannot be reached returns nothing countable' ($none.Count -eq 0)

    Test-MhSection 'the SAS token'
    Test-MhCheck 'a leading question mark is dropped' ((ConvertTo-MhPlainSas '?sv=2024&sig=abc') -eq 'sv=2024&sig=abc')
    Test-MhCheck 'and surrounding space' ((ConvertTo-MhPlainSas '  sv=2024  ') -eq 'sv=2024')
    $secure = ConvertTo-SecureString 'sv=2024&sig=xyz' -AsPlainText -Force
    Test-MhCheck 'a SecureString comes back out' ((ConvertTo-MhPlainSas $secure) -eq 'sv=2024&sig=xyz')
    $threw = $false
    try { ConvertTo-MhPlainSas '   ' | Out-Null } catch { $threw = $true }
    Test-MhCheck 'an empty token is refused' $threw
    $threw = $false
    try { ConvertTo-MhPlainSas 42 | Out-Null } catch { $threw = $true }
    Test-MhCheck 'and so is something that is not a token' $threw

    Test-MhSection 'logging levels'
    Initialize-MhLog -Level Normal
    Test-MhCheck 'a Normal run shows Normal but not Verbose' ((Test-MhLogAtLeast 'Normal') -and -not (Test-MhLogAtLeast 'Verbose'))
    Initialize-MhLog -Level Debug
    Test-MhCheck 'and Debug shows everything' ((Test-MhLogAtLeast 'Debug') -and (Test-MhLogAtLeast 'Verbose'))
    Initialize-MhLog

    Test-MhSection 'what is available to restore'
    function AvSet([string] $Type, [string] $Finished, [string[]] $Files) {
        [pscustomobject]@{ Type = $Type; FinishDate = [datetime]$Finished; Files = $Files }
    }
    $full = AvSet 'D' '2026-10-12 20:00' @('db_full.bak')
    $log1 = AvSet 'L' '2026-10-12 21:00' @('db_log1.trn')
    $log2 = AvSet 'L' '2026-10-12 22:00' @('db_log2.trn')
    $a = Select-DbCopyAvailableSets -BackupSets @($full, $log1, $log2) -AvailableFiles @('db_full.bak', 'db_log1.trn', 'db_log2.trn')
    Test-MhCheck 'everything uploaded is kept' ($a.Kept.Count -eq 3 -and $a.Skipped.Count -eq 0)
    $a = Select-DbCopyAvailableSets -BackupSets @($full, $log1, $log2) -AvailableFiles @('db_full.bak', 'db_log1.trn')
    Test-MhCheck 'a log still uploading is held back' ($a.Kept.Count -eq 2 -and $a.Skipped.Count -eq 1)
    Test-MhCheck 'and named' ($a.Skipped[0].Missing -contains 'db_log2.trn')
    $striped = AvSet 'D' '2026-10-12 23:00' @('s_1.bak', 's_2.bak')
    $a = Select-DbCopyAvailableSets -BackupSets @($striped) -AvailableFiles @('s_1.bak')
    Test-MhCheck 'a striped backup needs every stripe' ($a.Kept.Count -eq 0 -and $a.Skipped[0].Missing[0] -eq 's_2.bak')
    $a = Select-DbCopyAvailableSets -BackupSets @($striped) -AvailableFiles @('S_1.BAK', 's_2.BAK')
    Test-MhCheck 'names match whatever their case' ($a.Kept.Count -eq 1)
    $pathy = AvSet 'D' '2026-10-12 20:00' @('E:\SqlBackup\prod\db_full.bak')
    $a = Select-DbCopyAvailableSets -BackupSets @($pathy) -AvailableFiles @('db_full.bak')
    Test-MhCheck 'a blob is matched to the file name, not the whole path' ($a.Kept.Count -eq 1)
    $a = Select-DbCopyAvailableSets -BackupSets @() -AvailableFiles @('db_full.bak')
    Test-MhCheck 'no history keeps nothing' ($a.Kept.Count -eq 0)
    $a = Select-DbCopyAvailableSets -BackupSets @($full) -AvailableFiles @()
    Test-MhCheck 'an empty container keeps nothing' ($a.Kept.Count -eq 0 -and $a.Skipped.Count -eq 1)

    Test-MhSection 'sizes'
    Test-MhCheck 'gigabytes' ((Format-MhSize 3221225472) -eq '3.0 GB')
    Test-MhCheck 'megabytes' ((Format-MhSize 5242880) -eq '5 MB')

}

# one way to refuse a run, tagged so the shim can tell "you asked for the impossible" from
# "something broke", and on the error stream rather than the host so a caller can catch it
function Stop-DbCopyRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Reason)
    Write-Error $Reason -Category InvalidArgument -ErrorId 'MhBadArgument' -ErrorAction Stop
}

<#
  This tool's four calls into SQL Server, in its own shape, over the module's one copy of each.

  It asks by server name and expects the credential, the certificate and the timeout for that end
  to be worked out for it, which is what its own copies used to do - so every call site above is
  unchanged.
#>
function New-DbCopyConnectionString([string] $Server, [string] $DatabaseName = 'master') {
    New-MhConnectionString -Server $Server -Database $DatabaseName `
        -Credential (Get-DbCopyCredentialFor $Server) `
        -TrustServerCertificate:$script:DbCopyTrustServerCertificate `
        -TimeoutSeconds $script:DbCopyConnectTimeoutSeconds `
        -ApplicationName 'Restore-DatabaseCopy'
}

function Invoke-DbCopySql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')
    Invoke-MhSql -ConnectionString (New-DbCopyConnectionString $Server $DatabaseName) -Query $Query -Parameters $Parameters
}

function Get-DbCopyScalar {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')
    $table = Invoke-DbCopySql -Server $Server -Query $Query -Parameters $Parameters -DatabaseName $DatabaseName
    if ($table.Rows.Count -eq 0) { return $null }
    $value = $table.Rows[0][0]
    if ($value -is [DBNull]) { $null } else { $value }
}

function Invoke-DbCopyLongSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Sql, [string] $Label)
    Invoke-MhLongRunningSql -ConnectionString (New-DbCopyConnectionString $Server) -Sql $Sql -Label $Label
}

function Invoke-DbCopyStatement {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
          [Parameter(Mandatory)] [string] $Statement)
    Invoke-MhDbStatement -ConnectionString (New-DbCopyConnectionString $Server) -DatabaseName $DatabaseName -Statement $Statement
}
