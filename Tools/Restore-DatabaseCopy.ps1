#Requires -Version 5.1

<#
.SYNOPSIS
    Restores a database from one SQL Server onto another: the latest full backup, skipping it when
    it has already been restored, or a copy kept rolling forward with log backups until you cut over
    to it. The backups can be read where they lie, or staged through Azure Blob Storage when the two
    servers cannot see each other.

.DESCRIPTION
    Molehill Data Services | Restore-DatabaseCopy

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Restore-MhDatabaseCopy). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

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

    Exit code: 0 = done (or a clean dry run), 1 = something failed, 2 = could not start.

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
    through -Command instead: powershell -Command "& .\Restore-DatabaseCopy.ps1 ... -BackupPathMap @{...}".

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

.PARAMETER SelfTest
    Check the script's own logic - the backup chain, the statements it builds, path handling, the
    error explanations - without a server, a storage account or any module.

.EXAMPLE
    .\Restore-DatabaseCopy.ps1 -SourceInstance SQL01 -Database Sales -DestinationInstance SQL02
    # latest full (plus a differential if there is one), online, and nothing at all if it is already restored

.EXAMPLE
    # Monday: seed the copy, then catch it up whenever you like
    .\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -KeepRestoring
    .\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -KeepRestoring      # applies the logs since
    # Friday 18:00, the ten minutes that matter:
    .\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -Cutover -TailLog -DisconnectSource

.EXAMPLE
    # off an old server that the new one cannot see, several databases in one run
    .\Restore-DatabaseCopy.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -Database Sales,Stock,Payroll -From AzureBlob -StorageAccountName mycompany `
        -ContainerName legacybackup -BlobPrefix OLDSQL -SasToken (Get-Secret -Name LegacyBackupSas) `
        -LocalBackupPath D:\RestoreStaging -TrustServerCertificate -RepairOrphanUsers

.EXAMPLE
    .\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -StopAt '2026-10-12 09:15' -WhatIf
    # prints the exact RESTORE statements it would run, and nothing else

.EXAMPLE
    .\Restore-DatabaseCopy.ps1 OLDSQL NEWSQL Sales -TestConnectionOnly -TrustServerCertificate
    # start here when something will not connect

.NOTES
    Molehill Data Services. Needs SQL Server 2012 or later at both ends, the right to restore on the
    destination, and read access to msdb on the source.
#>
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
    [switch] $Force,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Restore-MhDatabaseCopy.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Restore-MhDatabaseCopy'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# only what was actually passed, so the function's own defaults stand
$arguments = @{}
foreach ($name in @(
        'SourceInstance', 'DestinationInstance', 'Database', 'DestinationDatabase',
        'BackupPathMap', 'SourceHistoryFile', 'StorageAccountName', 'ContainerName',
        'BlobPrefix', 'SasToken', 'LocalBackupPath', 'KeepLocalCopy',
        'InstallMissingModules', 'KeepRestoring', 'Standby', 'StandbyPath',
        'Cutover', 'TailLog', 'TailLogPath', 'DisconnectSource',
        'DisconnectDestination', 'StopAt', 'NoDifferential', 'DataPath',
        'LogPath', 'KeepFilePaths', 'DatabaseOwner', 'RepairOrphanUsers',
        'UpdateStatistics', 'RunCheckDb', 'SqlCredential', 'SourceSqlCredential',
        'DestinationSqlCredential', 'TrustServerCertificate', 'LogFile', 'CsvPath',
        'TestConnectionOnly', 'Force'
        'WhatIf', 'Confirm', 'Verbose', 'Debug')) {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}

try {
    $run = Restore-MhDatabaseCopy @arguments
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}

if (-not $run) { exit 2 }
exit $(if ($run.Ok) { 0 } else { 1 })
