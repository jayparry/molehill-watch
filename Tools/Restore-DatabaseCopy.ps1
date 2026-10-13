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

if (-not $SourceSqlCredential) { $SourceSqlCredential = $SqlCredential }
if (-not $DestinationSqlCredential) { $DestinationSqlCredential = $SqlCredential }

#==============================================================================
# Logging
#==============================================================================
$script:LevelRank = @{ Quiet = 0; Normal = 1; Verbose = 2; Debug = 3 }

# -Verbose and -Debug raise the level on their own, so either way of asking works
if ($PSBoundParameters.ContainsKey('Debug') -and $script:LevelRank[$LogLevel] -lt 3) { $LogLevel = 'Debug' }
elseif ($VerbosePreference -ne 'SilentlyContinue' -and $script:LevelRank[$LogLevel] -lt 2) { $LogLevel = 'Verbose' }

$script:Level       = $script:LevelRank[$LogLevel]
$script:Messages    = New-Object System.Collections.Generic.List[string]
$script:LogFilePath     = $LogFile
$script:Steps       = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = $null
$script:StepTimer   = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')][string]$Min = 'Normal'
    )
    # problems are never hidden, however quiet you asked for
    $show = ($Level -ne 'INFO') -or ($script:Level -ge $script:LevelRank[$Min])
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($show) {
        $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
        Write-Host $line -ForegroundColor $colour
    }
    if ($script:LogFilePath -and $show) {
        try { Add-Content -LiteralPath $script:LogFilePath -Value $line -WhatIf:$false }
        catch { Write-Host "(could not write to the log file: $($_.Exception.Message))" -ForegroundColor Yellow }
    }
}

function Write-Detail { param([string]$Message) Write-Log $Message -Min Verbose }
function Write-Deep   { param([string]$Message) Write-Log $Message -Min Debug }

$script:StepPrefix = ''

function Start-Step {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:StepPrefix) { $Name = '{0}: {1}' -f $script:StepPrefix, $Name }
    $script:CurrentStep = $Name
    $script:StepTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "START: $Name"
}

function Complete-Step {
    param([ValidateSet('OK', 'SKIPPED', 'FAILED')][string]$Result = 'OK')
    if (-not $script:CurrentStep) { return }
    $seconds = [math]::Round($script:StepTimer.Elapsed.TotalSeconds, 1)
    $script:Steps.Add([pscustomobject]@{ Step = $script:CurrentStep; Result = $Result; Seconds = $seconds })
    $level = if ($Result -eq 'FAILED') { 'ERROR' } else { 'INFO' }
    Write-Log "$($Result): $($script:CurrentStep) ($seconds s)" -Level $level
    $script:CurrentStep = $null
}

#==============================================================================
# The decisions, kept free of SQL Server and Azure so -SelfTest can check them
#==============================================================================
<#
  Pulls an instance string apart: SQL01, SQL01\SALES, SQL01,14330, sql01.contoso.com\SALES,1433,
  tcp:SQL01, (local), . and localhost all arrive here.
#>
function Split-SqlInstanceName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Instance)

    $result = [pscustomobject]@{ Computer = ''; Instance = ''; Port = 0; Raw = $Instance }
    $text = ([string]$Instance).Trim()
    foreach ($prefix in 'tcp:', 'np:', 'lpc:') {
        if ($text.ToLower().StartsWith($prefix)) { $text = $text.Substring($prefix.Length); break }
    }

    # a comma separates the port, a backslash the named instance
    $comma = $text.LastIndexOf(',')
    if ($comma -gt 0) {
        $tail = $text.Substring($comma + 1).Trim()
        if ($tail -match '^\d+$') {
            $result.Port = [int]$tail
            $text = $text.Substring(0, $comma)
        }
    }
    $slash = $text.IndexOf('\')
    if ($slash -ge 0) {
        $result.Instance = $text.Substring($slash + 1).Trim()
        $text = $text.Substring(0, $slash)
    }
    $computer = $text.Trim()
    if (-not $computer -or $computer -eq '.' -or $computer -eq '(local)' -or $computer -eq '(localdb)') { $computer = 'localhost' }
    $result.Computer = $computer
    if (-not $result.Instance -and $result.Port -eq 0) { $result.Port = 1433 }
    $result
}

<#
  Turns a SQL or network failure into something worth reading: what it means, and what usually
  causes it. Matched on the error number where there is one, then on the message text.
#>
function Get-SqlErrorExplanation {
    [CmdletBinding()]
    param([int]$Number = 0, [AllowEmptyString()][string]$Message = '', [AllowEmptyString()][string]$Instance = '')

    $m = [string]$Message
    switch ($Number) {
        18456 {
            $state = if ($m -match 'state:?\s*(\d+)') { [int]$Matches[1] } else { 0 }
            $extra = switch ($state) {
                5  { ' The login does not exist on that instance.' }
                6  { ' A Windows login was used with SQL authentication.' }
                7  { ' The login exists but is disabled, or the password is wrong.' }
                8  { ' The password is wrong.' }
                38 { ' The login worked but the default database cannot be opened.' }
                default { '' }
            }
            return [pscustomobject]@{
                Meaning = "SQL Server refused the login (18456).$extra"
                Fix = 'Check the login and password. With Windows authentication, the account running this script needs its own login on that instance - and if you are on a different machine, make sure it is being passed through rather than falling back to an anonymous logon.'
            }
        }
        18452 { return [pscustomobject]@{ Meaning = 'The login is from an untrusted domain and cannot be used with Windows authentication (18452).'; Fix = 'Use -SourceSqlCredential or -DestinationSqlCredential with a SQL login, or run as an account the instance trusts.' } }
        18487 { return [pscustomobject]@{ Meaning = 'The password for that SQL login has expired (18487).'; Fix = 'Reset it on the instance, then try again.' } }
        18488 { return [pscustomobject]@{ Meaning = 'That SQL login must change its password before it can be used (18488).'; Fix = 'Change it on the instance, then try again.' } }
        4060  { return [pscustomobject]@{ Meaning = 'The login worked, but its default database cannot be opened (4060).'; Fix = 'The database may be offline, or the login may have no access to it. This script connects to master, so check the login''s default database.' } }
        233   { return [pscustomobject]@{ Meaning = 'The connection was closed during the handshake (233).'; Fix = 'Usually TCP/IP is disabled on the instance, or it is only listening on named pipes. Enable TCP/IP in SQL Server Configuration Manager, or connect by name without a protocol prefix.' } }
        -2    { return [pscustomobject]@{ Meaning = 'The connection timed out before the instance answered.'; Fix = 'A firewall dropping packets silently looks exactly like this. Check the port is open, and raise -ConnectTimeoutSeconds if the instance is simply slow to wake.' } }
        53    { return [pscustomobject]@{ Meaning = 'The network path to that machine was not found (53).'; Fix = 'Check the name is right and resolves from here. A machine name with no domain suffix often needs the full name.' } }
        2     { return [pscustomobject]@{ Meaning = 'The instance could not be located (2).'; Fix = 'Check the name and, for a named instance, that SQL Browser is running on it - or give the port directly as SERVER,PORT.' } }
        40615 { return [pscustomobject]@{ Meaning = 'Azure SQL refused the connection because this address is not on its firewall (40615).'; Fix = 'Add this machine''s public IP to the server firewall rules.' } }
        40532 { return [pscustomobject]@{ Meaning = 'Azure SQL could not route the login (40532).'; Fix = 'Use the full server name, and for a contained database the login''s own database.' } }
        3201  { return [pscustomobject]@{ Meaning = 'SQL Server could not open the backup device (3201).'; Fix = 'The path has to be readable by the SQL SERVICE ACCOUNT, not by you. Stage the backup somewhere outside a user profile, such as D:\RestoreStaging, and give the service account read access.' } }
        5     { return [pscustomobject]@{ Meaning = 'Access was denied to a file (5).'; Fix = 'Same cause as 3201: the SQL Server service account cannot read the staging folder. A path under C:\Users will not work.' } }
        3154  { return [pscustomobject]@{ Meaning = 'The backup set holds a backup of a different database (3154).'; Fix = 'The file in the staging folder is not a backup of the database being replaced. Check the blob prefix and the file names in msdb.' } }
        3169  { return [pscustomobject]@{ Meaning = 'The backup was taken on a newer version of SQL Server than the destination (3169).'; Fix = 'A backup can only be restored onto the same version or newer. Restore it somewhere at that version or later.' } }
    }

    # no number worth matching, or a client-side failure: go on the text
    if ($m -match 'pre-login handshake|certificate chain was issued by an authority that is not trusted|The target principal name is incorrect|SSL Provider|encryption') {
        return [pscustomobject]@{
            Meaning = 'The connection failed while setting up encryption.'
            Fix     = 'Try -TrustServerCertificate first: an instance with a self-signed certificate needs it. If that changes nothing, the handshake is failing on the protocol or the cipher rather than on trust - Test-SqlTlsHandshake.ps1 against the instance will say which, and what certificate it is presenting.'
        }
    }
    if ($m -match 'do not possess a common algorithm|existing connection was forcibly closed|SSL/TLS|schannel') {
        return [pscustomobject]@{
            Meaning = 'The two machines could not agree on how to encrypt the connection - a TLS version or a cipher suite, not a certificate.'
            Fix     = 'SQL Server encrypts the login packet whatever -TrustServerCertificate says, so that switch will not help here. Run Test-SqlTlsHandshake.ps1 against the instance: it says which TLS versions it will do, whether a default client is offered them, and what certificate it presents - an old instance often has a 1024-bit SHA1 one that a modern client refuses. Guessing between those causes wastes an afternoon.'
        }
    }
    if ($m -match 'wait operation timed out|Timeout expired|timeout period elapsed') {
        return [pscustomobject]@{
            Meaning = 'The instance did not answer before the timeout.'
            Fix     = 'Nothing refused the connection - it simply went unanswered, which is what a firewall dropping packets looks like. Check the port is open from here, and that the instance is running and listening on TCP. -ConnectTimeoutSeconds raises the wait if the instance is just slow.'
        }
    }
    if ($m -match 'Error Locating Server/Instance Specified|error: 26') {
        return [pscustomobject]@{
            Meaning = 'The named instance could not be located.'
            Fix     = 'SQL Browser (UDP 1434) answers that question and is often blocked or stopped. Give the port instead: SERVER,PORT.'
        }
    }
    if ($m -match 'network-related or instance-specific|not found or was not accessible') {
        return [pscustomobject]@{
            Meaning = 'The client could not reach an instance by that name.'
            Fix     = 'Check the name, that the instance is running, and that TCP is reachable from here. The checks above show which part failed.'
        }
    }
    if ($m -match 'A parameter cannot be found that matches parameter name') {
        return [pscustomobject]@{
            Meaning = 'A command was called with a parameter it does not have, which is a fault in the script rather than in your servers.'
            Fix     = 'Note the parameter name in the message - nothing was connected to or changed.'
        }
    }
    if ($m -match 'Login failed') {
        return [pscustomobject]@{ Meaning = 'SQL Server refused the login.'; Fix = 'Check the account has a login on that instance.' }
    }
    [pscustomobject]@{ Meaning = ''; Fix = '' }
}

<#
  Did the failure happen at SQL Server, or before reaching it?

  It decides whether the network checks are worth running: a refused login or a rejected certificate
  both prove the server answered, so probing DNS and the port would only add a misleading line. A
  timeout or an unresolvable name means nothing answered, and then the probes are the whole story.
#>
function Test-ReachedServer {
    [CmdletBinding()]
    param([int]$Number = 0, [AllowEmptyString()][string]$Message = '')

    if ($Number -gt 0) { return $true }
    # a TLS handshake, trusted or not, only happens once the server is talking
    if ($Message -match 'certificate|pre-login handshake|SSL Provider|encryption|Login failed|password') { return $true }
    $false
}

# A SecureString here, a plain string there, and a leading '?' from the portal either way.
function ConvertTo-PlainSas {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Token)

    if ($null -eq $Token) { throw 'SasToken is empty.' }
    $plain = $null
    if ($Token -is [System.Security.SecureString]) {
        # ConvertFrom-SecureString -AsPlainText is PowerShell 7 only, and this script runs on 5.1
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    elseif ($Token -is [string]) { $plain = $Token }
    else { throw "SasToken must be a string or a SecureString, not $($Token.GetType().FullName)." }

    $plain = $plain.Trim().TrimStart('?')
    if (-not $plain) { throw 'SasToken is empty.' }
    $plain
}

#==============================================================================
# Connection checks
#==============================================================================
function Test-TcpPort {
    [CmdletBinding()]
    param([string]$Computer, [int]$Port, [int]$TimeoutMs = 5000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Computer, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return [pscustomobject]@{ Ok = $false; Error = "no answer within $([int]($TimeoutMs / 1000))s (a firewall dropping packets looks like this)" }
        }
        $client.EndConnect($async)
        [pscustomobject]@{ Ok = $true; Error = $null }
    }
    catch { [pscustomobject]@{ Ok = $false; Error = ($_.Exception.GetBaseException().Message -split "`r?`n")[0] } }
    finally { $client.Close() }
}

# SQL Browser, over UDP 1434, is the only thing that knows which port a named instance is on
function Get-SqlBrowserInstances {
    [CmdletBinding()]
    param([string]$Computer, [int]$TimeoutMs = 2500)

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Computer, 1434)
        [void]$udp.Send([byte[]](0x03), 1)
        $endpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $bytes = $udp.Receive([ref]$endpoint)
        if ($bytes.Length -le 3) { return @() }
        $text = [System.Text.Encoding]::ASCII.GetString($bytes, 3, $bytes.Length - 3)
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($block in ($text -split ';;')) {
            if (-not $block) { continue }
            $fields = $block -split ';'
            $map = @{}
            for ($i = 0; $i -lt $fields.Count - 1; $i += 2) { $map[$fields[$i]] = $fields[$i + 1] }
            if ($map.ContainsKey('InstanceName')) {
                $found.Add([pscustomobject]@{
                    Instance = [string]$map['InstanceName']
                    Port     = if ($map.ContainsKey('tcp')) { [int]$map['tcp'] } else { 0 }
                    Version  = if ($map.ContainsKey('Version')) { [string]$map['Version'] } else { '' }
                })
            }
        }
        # callers wrap this in @(), which is what makes .Count safe whether this returns none, one
        # (PowerShell would otherwise hand back a bare object) or many
        $found.ToArray()
    }
    catch { @() }
    finally { $udp.Close() }
}

<#
  Whether an instance will connect, and when it will not, why.

  The login is tried first, because that is the thing that actually has to work and it answers the
  question in one go. Only when it fails is the ground underneath it checked - the name, SQL Browser
  for a named instance, then the TCP port - so a working connection costs one attempt rather than a
  round of probes, and a broken one gets the full story.

  The login goes through ADO.NET directly because the raw SqlException carries the error number,
  which is what separates "wrong password" from "no route to the machine".
#>
function Test-SqlConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [PSCredential]$Credential,
        [switch]$Trust,
        [int]$TimeoutSeconds = 15
    )

    $parts = Split-SqlInstanceName -Instance $Instance
    $checks = New-Object System.Collections.Generic.List[object]

    Write-Detail ("  {0}: computer '{1}'{2}{3}" -f $Instance, $parts.Computer,
                  $(if ($parts.Instance) { ", named instance '$($parts.Instance)'" } else { '' }),
                  $(if ($parts.Port) { ", port $($parts.Port)" } else { '' }))

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Instance
    $builder['Initial Catalog'] = 'master'
    $builder['Connect Timeout'] = $TimeoutSeconds
    $builder['Application Name'] = 'Restore-DatabaseFromAzureBlob'
    if ($Trust) { $builder['TrustServerCertificate'] = $true }
    if ($Credential) {
        $builder['User ID'] = $Credential.UserName
        $builder['Password'] = $Credential.GetNetworkCredential().Password
    }
    else { $builder['Integrated Security'] = $true }

    Write-Deep ("  connection string: " + ($builder.ConnectionString -replace 'Password=[^;]*', 'Password=***'))
    $who = if ($Credential) { "SQL login '$($Credential.UserName)'" } else { "Windows account '$([Environment]::UserDomainName)\$([Environment]::UserName)'" }
    Write-Detail "  connecting as $who"

    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $failure = $null
    $number = 0
    $info = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')) + ' | ' + CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) + ' | ' + CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) + ' | connected as ' + SUSER_SNAME()"
        $info = [string]$command.ExecuteScalar()
        $checks.Add([pscustomobject]@{ Name = 'login'; Ok = $true; Detail = $info })
        $connection.Close()
    }
    catch {
        $exception = $_.Exception.GetBaseException()
        if ($exception -is [System.Data.SqlClient.SqlException]) {
            $number = $exception.Number
            Write-Deep ("  SqlException number {0}, state {1}, class {2}" -f $exception.Number, $exception.State, $exception.Class)
            foreach ($e in $exception.Errors) { Write-Deep ("    error {0}: {1}" -f $e.Number, $e.Message) }
        }
        Write-Deep ('  exception: ' + $exception.ToString())
        $failure = ($exception.Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' '
        $checks.Add([pscustomobject]@{ Name = 'login'; Ok = $false; Detail = $failure })
    }
    finally { $connection.Dispose() }

    if (-not $failure) {
        # it works; the name it resolved to is worth a line at Verbose, and nothing else is needed
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($parts.Computer) | ForEach-Object { $_.IPAddressToString })
            Write-Detail ("  {0} resolves to {1}" -f $parts.Computer, ($addresses -join ', '))
        }
        catch { }
        return [pscustomobject]@{
            Instance = $Instance; Parts = $parts; Checks = $checks.ToArray(); Connected = $true
            Meaning = ''; Fix = ''; Error = $null; Number = 0; Version = $info
        }
    }

    # ---- it did not connect, so work out how far it got ----
    # A SQL error number means SQL Server itself answered, so the name, the port and SQL Browser all
    # demonstrably work: probing them would only add a misleading line about TCP 1433 on an instance
    # that is listening somewhere else entirely.
    if (Test-ReachedServer -Number $number -Message $failure) {
        Write-Detail '  SQL Server answered, so this is not a network problem'
        $explain = Get-SqlErrorExplanation -Number $number -Message $failure -Instance $Instance
        return [pscustomobject]@{
            Instance = $Instance; Parts = $parts; Checks = $checks.ToArray(); Connected = $false
            Meaning = $explain.Meaning; Fix = $explain.Fix; Error = $failure; Number = $number; Version = $null
        }
    }

    Write-Detail '  nothing answered, so checking the ground underneath it'

    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($parts.Computer) | ForEach-Object { $_.IPAddressToString })
        $checks.Insert(0, [pscustomobject]@{ Name = 'name resolves'; Ok = $true; Detail = ($addresses -join ', ') })
    }
    catch {
        $checks.Insert(0, [pscustomobject]@{ Name = 'name resolves'; Ok = $false; Detail = ($_.Exception.GetBaseException().Message -split "`r?`n")[0] })
        return [pscustomobject]@{
            Instance = $Instance; Parts = $parts; Checks = $checks.ToArray(); Connected = $false
            Meaning = "The name '$($parts.Computer)' does not resolve from this machine."
            Fix = 'Check the spelling, try the fully qualified name, or use the IP address. Nothing else can work until this does.'
            Error = $failure; Number = $number; Version = $null
        }
    }

    $port = $parts.Port
    if ($parts.Instance -and $port -eq 0) {
        $browser = @(Get-SqlBrowserInstances -Computer $parts.Computer)
        if ($browser.Count) {
            $match = @($browser | Where-Object { $_.Instance -eq $parts.Instance })
            if ($match.Count -and $match[0].Port -gt 0) {
                $port = $match[0].Port
                $checks.Add([pscustomobject]@{ Name = 'SQL Browser'; Ok = $true; Detail = "instance $($parts.Instance) is on port $port" })
            }
            else {
                $checks.Add([pscustomobject]@{ Name = 'SQL Browser'; Ok = $false
                    Detail = "answered, but knows no instance called '$($parts.Instance)'. It offers: " + (($browser | ForEach-Object { $_.Instance }) -join ', ') })
            }
        }
        else {
            $checks.Add([pscustomobject]@{ Name = 'SQL Browser'; Ok = $false; Detail = 'no answer on UDP 1434 (stopped, or blocked by a firewall)' })
        }
    }
    if ($port -gt 0) {
        $tcp = Test-TcpPort -Computer $parts.Computer -Port $port -TimeoutMs ([Math]::Min($TimeoutSeconds, 10) * 1000)
        $checks.Add([pscustomobject]@{ Name = "TCP $port"; Ok = $tcp.Ok
            Detail = $(if ($tcp.Ok) { 'open' } else { $tcp.Error }) })
    }

    $explain = Get-SqlErrorExplanation -Number $number -Message $failure -Instance $Instance
    $meaning = $explain.Meaning
    $fix = $explain.Fix

    # Nothing answered, so a definite probe result beats guessing from the message text: "the login
    # timed out" is less use than "that port is refused".
    if ($true) {
        $refused = @($checks | Where-Object { -not $_.Ok -and $_.Name -like 'TCP *' -and $_.Detail -match 'refused' })
        $silent = @($checks | Where-Object { -not $_.Ok -and $_.Name -like 'TCP *' -and $_.Detail -match 'no answer' })
        $noBrowser = @($checks | Where-Object { -not $_.Ok -and $_.Name -eq 'SQL Browser' })
        if ($refused.Count) {
            $meaning = "Nothing is listening on $($refused[0].Name) of $($parts.Computer): the machine is there and answered, but refused the port."
            $fix = 'Check the instance is running, that TCP/IP is enabled for it, and that it is on the port you have given. A named instance usually picks its own port, so check it in SQL Server Configuration Manager or give SERVER,PORT.'
        }
        elseif ($silent.Count) {
            $meaning = "$($silent[0].Name) of $($parts.Computer) did not answer at all."
            $fix = 'Being dropped rather than refused points at a firewall between here and there, rather than at SQL Server.'
        }
        elseif ($noBrowser.Count) {
            $meaning = "The named instance '$($parts.Instance)' could not be located on $($parts.Computer)."
            $fix = 'SQL Browser answers that question over UDP 1434 and is often stopped or blocked. Give the port directly instead, as SERVER,PORT.'
        }
    }

    [pscustomobject]@{
        Instance = $Instance; Parts = $parts; Checks = $checks.ToArray(); Connected = $false
        Meaning = $meaning; Fix = $fix; Error = $failure; Number = $number; Version = $null
    }
}

function Write-ConnectivityReport {
    param([Parameter(Mandatory)]$Result, [string]$Role)

    $label = "$Role $($Result.Instance)"
    if ($Result.Connected) {
        Write-Log "$label : connected - $($Result.Version)"
    }
    else {
        Write-Log "$label : NOT connected" -Level ERROR
    }
    foreach ($check in $Result.Checks) {
        $mark = if ($check.Ok) { 'ok  ' } else { 'FAIL' }
        $text = '    {0}  {1}{2}' -f $mark, $check.Name, $(if ($check.Detail) { " - $($check.Detail)" } else { '' })
        # a check that failed only matters when the connection did too: an instance on named pipes
        # or a dynamic port fails a TCP 1433 probe and works perfectly well
        if ($Result.Connected -or $check.Ok) { Write-Log $text -Min Verbose } else { Write-Log $text -Level WARN }
    }
    if (-not $Result.Connected) {
        if ($Result.Error)   { Write-Log "    what SQL Server said: $($Result.Error)" -Level ERROR }
        if ($Result.Meaning) { Write-Log "    what it means: $($Result.Meaning)" -Level ERROR }
        if ($Result.Fix)     { Write-Log "    what to try: $($Result.Fix)" -Level WARN }
        if ($Result.Error -match 'handshake|certificate|common algorithm|SSL|TLS|forcibly closed') {
            Write-Log ("    for the detail: .\Test-SqlTlsHandshake.ps1 '{0}'" -f $Result.Instance) -Level WARN
        }
    }
}

# identifiers and literals, quoted the long way round
function Esc-Name([string] $Name) { '[' + ($Name -replace '\]', ']]') + ']' }
function Esc-Str([string] $Text) { $Text -replace "'", "''" }

function Format-Size([double] $Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:n1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:n1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n0} MB' -f ($Bytes / 1MB)) }
    '{0:n0} KB' -f ($Bytes / 1KB)
}

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
# Talking to SQL Server
#==============================================================================
<#
  Which credential belongs to which end. The two instances can need different logins, and every
  connection in here is made by name, so the name is what decides.
#>
function Get-CredentialFor([string] $Server) {
    if ($Server -eq $SourceInstance -and $SourceSqlCredential) { return $SourceSqlCredential }
    if ($Server -eq $DestinationInstance -and $DestinationSqlCredential) { return $DestinationSqlCredential }
    $SqlCredential
}

function New-ConnectionString([string] $Server, [string] $DatabaseName, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $DatabaseName
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Restore-DatabaseCopy'
    if ($TrustServerCertificate) { $b['TrustServerCertificate'] = $true }
    $credential = Get-CredentialFor $Server
    if ($credential) {
        $b['User ID'] = $credential.UserName
        $b['Password'] = $credential.GetNetworkCredential().Password
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

#==============================================================================
# Where the backup files are
#==============================================================================

<#
  Narrows backup sets down to the ones whose every file is actually available, and says what was
  passed over and why.

  This is what keeps a half-finished upload out of a restore: msdb records a backup the moment it
  finishes writing on the source, while a block blob only appears once it is fully committed, so
  the newest row in history is routinely ahead of the container. Filtering the sets before the chain
  is worked out means the chain is built only from what can really be restored - and in a rolling
  restore it naturally stops at the last log that made it across.
#>
function Select-AvailableSets {
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

# Can the destination read this file? xp_fileexist is the only way to ask it, and it may be denied.
$script:FileCheckWorks = $true
function Test-DestinationFile {
    [CmdletBinding()]
    param([string] $Server, [string] $Path)

    if (-not $script:FileCheckWorks) { return $true }
    try {
        $sql = "DECLARE @r TABLE (FileExists bit, IsDir bit, ParentExists bit);
                INSERT @r EXEC master.dbo.xp_fileexist @p;
                SELECT TOP (1) FileExists FROM @r;"
        [bool](Get-Scalar -Server $Server -Query $sql -Parameters @{ '@p' = $Path })
    }
    catch {
        Write-Detail "  cannot use xp_fileexist on the destination ($(($_.Exception.Message -split "`r?`n")[0])), so file paths are not checked in advance"
        $script:FileCheckWorks = $false
        $true
    }
}

<#
  Opens the container and indexes it by file name, so a backup set recorded in msdb can be matched
  to the blob holding it. Where the same name appears in several folders, the newest wins.
#>
function Connect-BlobContainer {
    [CmdletBinding()]
    param([string] $AccountName, [string] $Container, [string] $Prefix, [object] $Sas)

    # a quick name check first: an account that does not exist otherwise takes Azure's six retries
    # and the best part of half a minute to say so
    try { [void][System.Net.Dns]::GetHostAddresses("$AccountName.blob.core.windows.net") }
    catch {
        throw "The storage account '$AccountName' does not resolve ($AccountName.blob.core.windows.net). Check the name - it is the account name on its own, not a URL."
    }

    $sasPlain = ConvertTo-PlainSas -Token $Sas
    Write-Deep ('  SAS parameters present: ' + (($sasPlain -split '&' | ForEach-Object { ($_ -split '=')[0] }) -join ', '))
    $context = New-AzStorageContext -StorageAccountName $AccountName -SasToken $sasPlain
    $sasPlain = $null

    $listSplat = @{ Container = $Container; Context = $context }
    if ($Prefix) { $listSplat.Prefix = $Prefix.Trim('/') + '/' }
    try { $blobs = @(Get-AzStorageBlob @listSplat) }
    catch {
        $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
        Write-Deep ('  storage exception: ' + $_.Exception.ToString())
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
        if (-not $index.ContainsKey($leaf) -or $blob.LastModified -gt $index[$leaf].LastModified) { $index[$leaf] = $blob }
        Write-Deep ('  blob {0} ({1})' -f $blob.Name, (Format-Size $blob.Length))
    }
    Write-Log "Found $($blobs.Count) blob(s) under '$Container/$Prefix'"
    if ($blobs.Count -eq 0) {
        Write-Log 'The container listing came back empty. If the backups sit in a folder, -BlobPrefix has to name it (a parent folder is enough when several databases share one).' -Level WARN
    }
    [pscustomobject]@{ Context = $context; Index = $index; Count = $blobs.Count }
}

# Fetches one blob and proves it arrived whole: a short file would fail the restore far less clearly.
function Get-BlobToFile {
    [CmdletBinding()]
    param($Context, [string] $Container, $Blob, [string] $TargetPath)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Get-AzStorageBlobContent -Container $Container -Blob $Blob.Name -Destination $TargetPath `
        -Context $Context -Force | Out-Null
    $timer.Stop()
    $length = (Get-Item -LiteralPath $TargetPath).Length
    if ($length -ne $Blob.Length) {
        throw "Size mismatch for $($TargetPath): the blob is $($Blob.Length) bytes and the local file is $length bytes"
    }
    $rate = if ($timer.Elapsed.TotalSeconds -gt 0.5) { ' at {0}/s' -f (Format-Size ($length / $timer.Elapsed.TotalSeconds)) } else { '' }
    Write-Log ('  {0} ({1}) in {2:N1}s{3}' -f (Split-Path -Leaf $TargetPath), (Format-Size $length), $timer.Elapsed.TotalSeconds, $rate)
    $length
}

<#
  Turns the file names a backup set recorded in msdb into paths the destination can actually open.

  -From Path maps the path and, for a local path on another machine, retries it through the admin
  share. -From AzureBlob downloads the blob of that name into the staging folder. Either way the
  restore itself sees nothing but a path, which is why the two modes need no special cases further
  down.
#>
function Resolve-BackupFiles {
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
            if (-not $script:Blobs.Index.ContainsKey($leaf)) {
                throw "The container has no blob called '$leaf'. The blob name after any folder must match the file name recorded in msdb."
            }
            $target = Join-Path -Path $LocalBackupPath -ChildPath $leaf
            if ($PSCmdlet.ShouldProcess($leaf, "Download to $target")) {
                $bytes += Get-BlobToFile -Context $script:Blobs.Context -Container $ContainerName `
                                         -Blob $script:Blobs.Index[$leaf] -TargetPath $target
                $script:Staged.Add($target)
            }
            $resolved.Add($target)
            continue
        }

        $path = Resolve-BackupPath -Path $file -Map $BackupPathMap
        if (-not (Test-DestinationFile -Server $DestinationServer -Path $path)) {
            $viaShare = Get-AdminSharePath -Path $path -SourceHost $SourceHost
            if ($viaShare -and (Test-DestinationFile -Server $DestinationServer -Path $viaShare)) {
                Write-Detail ('  {0} is not visible to the destination, using {1}' -f $path, $viaShare)
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

#==============================================================================
# Statements against the destination
#==============================================================================

<#
  Runs one short statement against a database on the destination. The token {DB} becomes
  QUOTENAME(database name) inside SQL Server, so the identifier is always quoted safely and the
  name never has to be pasted into the statement out here.
#>
function Invoke-DbStatement {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
          [Parameter(Mandatory)] [string] $Statement)

    $query = @'
DECLARE @sql nvarchar(max) = REPLACE(@Stmt, N'{DB}', QUOTENAME(@Db));
EXEC sys.sp_executesql @sql;
'@
    Write-Deep ('  statement: ' + ($Statement -replace '\{DB\}', ('[' + $DatabaseName + ']')))
    [void](Invoke-Sql -Server $Server -Query $query -Parameters @{ '@Db' = $DatabaseName; '@Stmt' = $Statement })
}

<#
  Points database users back at the destination's logins of the same name.

  A restored database carries its users and their SIDs from the old server, where they will not
  match the logins here, and those users then cannot log in at all. Only users whose name matches a
  login and whose SID does not are touched; contained users and the built-in principals are left
  alone.

  One case cannot be fixed by remapping, and is reported rather than attempted: where the login of
  that name is already mapped to another user in the database - most often because it owns it, and
  so is dbo - SQL Server will not map it to a second user. Dropping or renaming that user is a
  decision, not a repair.

  Runs inside the restored database, so sys.database_principals means the right thing.
#>
function Repair-OrphanUser {
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
    $rows = Invoke-Sql -Server $Server -Query $sql -DatabaseName $DatabaseName
    [pscustomobject]@{
        Remapped = @($rows.Rows | Where-Object { [string]$_['Outcome'] -eq 'remapped' } | ForEach-Object { [string]$_['UserName'] })
        Blocked  = @($rows.Rows | Where-Object { [string]$_['Outcome'] -eq 'blocked' } | ForEach-Object { [string]$_['UserName'] })
    }
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
    Write-Host 'Restore-DatabaseCopy self test'
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

    Write-Host '  instance names' -ForegroundColor Gray
    $p = Split-SqlInstanceName 'SQL01'
    Check 'a bare name is the default instance on 1433' ($p.Computer -eq 'SQL01' -and $p.Instance -eq '' -and $p.Port -eq 1433)
    $p = Split-SqlInstanceName 'SQL01\SALES'
    Check 'a named instance has no port until Browser says' ($p.Computer -eq 'SQL01' -and $p.Instance -eq 'SALES' -and $p.Port -eq 0)
    $p = Split-SqlInstanceName 'SQL01,14330'
    Check 'a comma is a port' ($p.Computer -eq 'SQL01' -and $p.Port -eq 14330)
    $p = Split-SqlInstanceName 'sql01.contoso.com\SALES,1433'
    Check 'a full name with instance and port' ($p.Computer -eq 'sql01.contoso.com' -and $p.Instance -eq 'SALES' -and $p.Port -eq 1433)
    $p = Split-SqlInstanceName 'tcp:SQL01'
    Check 'a protocol prefix is dropped' ($p.Computer -eq 'SQL01')
    $p = Split-SqlInstanceName '.'
    Check 'a dot is the local machine' ($p.Computer -eq 'localhost')

    Write-Host '  explaining failures' -ForegroundColor Gray
    $e = Get-SqlErrorExplanation -Number 18456 -Message "Login failed for user 'sa'. Reason: ... [CLIENT: 10.0.0.1] State: 8"
    Check 'login failed is explained' ($e.Meaning -match '18456' -and $e.Meaning -match 'password is wrong')
    $e = Get-SqlErrorExplanation -Number 18456 -Message "Login failed for user 'CONTOSO\jo'. State: 5"
    Check 'and state 5 means no such login' ($e.Meaning -match 'does not exist')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'A connection was successfully established with the server, but then an error occurred during the pre-login handshake.'
    Check 'the 2008 R2 encryption trap is named' ($e.Fix -match 'TrustServerCertificate')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'The certificate chain was issued by an authority that is not trusted.'
    Check 'so is an untrusted certificate' ($e.Fix -match 'TrustServerCertificate')
    $e = Get-SqlErrorExplanation -Number -2 -Message 'Timeout expired'
    Check 'a timeout blames the firewall, not the password' ($e.Fix -match 'firewall')
    $e = Get-SqlErrorExplanation -Number 3201 -Message 'Cannot open backup device'
    Check 'a backup device error points at the service account' ($e.Fix -match 'SERVICE ACCOUNT')
    $e = Get-SqlErrorExplanation -Number 5 -Message 'Access is denied.'
    Check 'so does access denied' ($e.Fix -match 'service account')
    $e = Get-SqlErrorExplanation -Number 3169 -Message 'backed up on a server running version 16.00'
    Check 'a too-new backup is explained' ($e.Meaning -match 'newer version')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'error: 26 - Error Locating Server/Instance Specified'
    Check 'a missing named instance points at SQL Browser' ($e.Fix -match 'SQL Browser')
    $e = Get-SqlErrorExplanation -Number 0 -Message "A parameter cannot be found that matches parameter name 'EnableException'."
    Check 'and a script fault is called a script fault' ($e.Meaning -match 'fault in the script')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'The client and server cannot communicate, because they do not possess a common algorithm'
    Check 'an encryption mismatch is told apart from a certificate problem' ($e.Meaning -match 'not a certificate')
    Check 'and says the certificate switch will not fix it' ($e.Fix -match 'will not help')
    Check 'and sends you to the tool that measures it' ($e.Fix -match 'Test-SqlTlsHandshake')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'The wait operation timed out'
    Check 'a bare timeout is explained as a timeout' ($e.Meaning -match 'did not answer' -and $e.Fix -match 'firewall')
    $e = Get-SqlErrorExplanation -Number 0 -Message 'something nobody has seen before'
    Check 'an unknown error explains nothing rather than guessing' ($e.Meaning -eq '')

    Write-Host '  did it reach the server' -ForegroundColor Gray
    Check 'an error number means it did' (Test-ReachedServer -Number 18456 -Message 'Login failed')
    Check 'a rejected certificate means it did' (Test-ReachedServer -Number 0 -Message 'The certificate chain was issued by an authority that is not trusted')
    Check 'a pre-login handshake failure means it did' (Test-ReachedServer -Number 0 -Message 'error occurred during the pre-login handshake')
    Check 'a timeout means it did not' (-not (Test-ReachedServer -Number 0 -Message 'The wait operation timed out'))
    Check 'and nor does an unreachable name' (-not (Test-ReachedServer -Number 0 -Message 'No such host is known'))

    Write-Host '  asking SQL Browser' -ForegroundColor Gray
    $none = @(Get-SqlBrowserInstances -Computer 'no-such-host-xyz.invalid' -TimeoutMs 500)
    Check 'a host that cannot be reached returns nothing countable' ($none.Count -eq 0)

    Write-Host '  the SAS token' -ForegroundColor Gray
    Check 'a leading question mark is dropped' ((ConvertTo-PlainSas '?sv=2024&sig=abc') -eq 'sv=2024&sig=abc')
    Check 'and surrounding space' ((ConvertTo-PlainSas '  sv=2024  ') -eq 'sv=2024')
    $secure = ConvertTo-SecureString 'sv=2024&sig=xyz' -AsPlainText -Force
    Check 'a SecureString comes back out' ((ConvertTo-PlainSas $secure) -eq 'sv=2024&sig=xyz')
    $threw = $false
    try { ConvertTo-PlainSas '   ' | Out-Null } catch { $threw = $true }
    Check 'an empty token is refused' $threw
    $threw = $false
    try { ConvertTo-PlainSas 42 | Out-Null } catch { $threw = $true }
    Check 'and so is something that is not a token' $threw

    Write-Host '  logging levels' -ForegroundColor Gray
    Check 'Quiet is below Normal' ($script:LevelRank['Quiet'] -lt $script:LevelRank['Normal'])
    Check 'Verbose is above Normal' ($script:LevelRank['Verbose'] -gt $script:LevelRank['Normal'])
    Check 'Debug is the loudest' ($script:LevelRank['Debug'] -eq 3)

    Write-Host '  what is available to restore' -ForegroundColor Gray
    function AvSet([string] $Type, [string] $Finished, [string[]] $Files) {
        [pscustomobject]@{ Type = $Type; FinishDate = [datetime]$Finished; Files = $Files }
    }
    $full = AvSet 'D' '2026-10-12 20:00' @('db_full.bak')
    $log1 = AvSet 'L' '2026-10-12 21:00' @('db_log1.trn')
    $log2 = AvSet 'L' '2026-10-12 22:00' @('db_log2.trn')
    $a = Select-AvailableSets -BackupSets @($full, $log1, $log2) -AvailableFiles @('db_full.bak', 'db_log1.trn', 'db_log2.trn')
    Check 'everything uploaded is kept' ($a.Kept.Count -eq 3 -and $a.Skipped.Count -eq 0)
    $a = Select-AvailableSets -BackupSets @($full, $log1, $log2) -AvailableFiles @('db_full.bak', 'db_log1.trn')
    Check 'a log still uploading is held back' ($a.Kept.Count -eq 2 -and $a.Skipped.Count -eq 1)
    Check 'and named' ($a.Skipped[0].Missing -contains 'db_log2.trn')
    $striped = AvSet 'D' '2026-10-12 23:00' @('s_1.bak', 's_2.bak')
    $a = Select-AvailableSets -BackupSets @($striped) -AvailableFiles @('s_1.bak')
    Check 'a striped backup needs every stripe' ($a.Kept.Count -eq 0 -and $a.Skipped[0].Missing[0] -eq 's_2.bak')
    $a = Select-AvailableSets -BackupSets @($striped) -AvailableFiles @('S_1.BAK', 's_2.BAK')
    Check 'names match whatever their case' ($a.Kept.Count -eq 1)
    $pathy = AvSet 'D' '2026-10-12 20:00' @('E:\SqlBackup\prod\db_full.bak')
    $a = Select-AvailableSets -BackupSets @($pathy) -AvailableFiles @('db_full.bak')
    Check 'a blob is matched to the file name, not the whole path' ($a.Kept.Count -eq 1)
    $a = Select-AvailableSets -BackupSets @() -AvailableFiles @('db_full.bak')
    Check 'no history keeps nothing' ($a.Kept.Count -eq 0)
    $a = Select-AvailableSets -BackupSets @($full) -AvailableFiles @()
    Check 'an empty container keeps nothing' ($a.Kept.Count -eq 0 -and $a.Skipped.Count -eq 1)

    Write-Host '  sizes' -ForegroundColor Gray
    Check 'gigabytes' ((Format-Size 3221225472) -eq '3.0 GB')
    Check 'megabytes' ((Format-Size 5242880) -eq '5 MB')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Queries
#==============================================================================
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

# backups this script cannot use, so a hole in the history can be explained rather than guessed at
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

#==============================================================================
# Getting started
#==============================================================================
foreach ($required in 'SourceInstance', 'DestinationInstance') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        Write-Host "  -$required is needed." -ForegroundColor Red
        Write-Host '  Try: Get-Help .\Restore-DatabaseCopy.ps1 -Detailed' -ForegroundColor Gray
        exit 2
    }
}
# powershell.exe -File hands every argument over as a string, so -Database Sales,Stock arrives as
# one element rather than two. Splitting a lone element on its commas makes scheduled runs work the
# same as a prompt. A database whose name genuinely contains a comma therefore has to be run on its
# own, without one.
$named = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($named.Count -eq 1 -and $named[0] -match ',') { $named = @($named[0] -split ',') }
$databases = @($named | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($databases.Count -eq 0) {
    Write-Host '  -Database is needed (one name, or several).' -ForegroundColor Red
    exit 2
}
if ($DestinationDatabase -and $databases.Count -gt 1) {
    Write-Host '  -DestinationDatabase renames one database, so it cannot be used with several. Run them separately, or leave the names as they are.' -ForegroundColor Red
    exit 2
}
if ($From -eq 'AzureBlob' -and -not $TestConnectionOnly) {
    foreach ($required in 'StorageAccountName', 'ContainerName', 'LocalBackupPath') {
        if (-not (Get-Variable -Name $required -ValueOnly)) {
            Write-Host "  -From AzureBlob needs -$required." -ForegroundColor Red
            exit 2
        }
    }
    if ($null -eq $SasToken) { Write-Host '  -From AzureBlob needs -SasToken.' -ForegroundColor Red; exit 2 }
}
if ($TailLog -and -not $Cutover) { $Cutover = $true }
if ($DisconnectSource -and -not $TailLog) { Write-Host '  -DisconnectSource is for the cutover: add -TailLog.' -ForegroundColor Red; exit 2 }
if ($Cutover -and ($KeepRestoring -or $Standby)) { Write-Host '  -Cutover brings the copy online; -KeepRestoring and -Standby keep it offline. Pick one.' -ForegroundColor Red; exit 2 }
if ($Standby) { $KeepRestoring = $true }

$SourceInstance = $SourceInstance.Trim()
$DestinationInstance = $DestinationInstance.Trim()
$stopAtValue = if ($PSBoundParameters.ContainsKey('StopAt')) { $StopAt } else { $null }
$dryRun = $WhatIfPreference -eq $true

$script:Blobs = $null
$script:Staged = New-Object System.Collections.Generic.List[string]
$runStart = Get-Date
$setupDone = $false
$results = New-Object System.Collections.Generic.List[object]

try {
    Write-Log ("Restore {0} database(s) from {1} to {2}, backups read {3}" -f $databases.Count, $SourceInstance, $DestinationInstance,
               $(if ($From -eq 'AzureBlob') { "from $StorageAccountName/$ContainerName" } else { 'where msdb says they are' }))
    Write-Log ('Databases: ' + ($databases -join ', '))
    Write-Detail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName) on $env:COMPUTERNAME; log level $LogLevel"
    if ($dryRun) { Write-Log 'WhatIf mode: the statements below are printed, not run' -Level WARN }

    #region Connection checks
    Start-Step 'Check the SQL Server instances'
    $sourceCheck = Test-SqlConnectivity -Instance $SourceInstance -Credential $SourceSqlCredential `
                                        -Trust:$TrustServerCertificate -TimeoutSeconds $ConnectTimeoutSeconds
    Write-ConnectivityReport -Result $sourceCheck -Role 'source'
    $destinationCheck = Test-SqlConnectivity -Instance $DestinationInstance -Credential $DestinationSqlCredential `
                                             -Trust:$TrustServerCertificate -TimeoutSeconds $ConnectTimeoutSeconds
    Write-ConnectivityReport -Result $destinationCheck -Role 'destination'

    if (-not $sourceCheck.Connected -or -not $destinationCheck.Connected) {
        $which = @()
        if (-not $sourceCheck.Connected) { $which += "source $SourceInstance" }
        if (-not $destinationCheck.Connected) { $which += "destination $DestinationInstance" }
        throw ('Cannot connect to ' + ($which -join ' and ') + '. The checks above say why; -LogLevel Verbose shows every step and Debug the raw errors.')
    }
    Complete-Step

    if ($TestConnectionOnly) {
        Write-Log 'TestConnectionOnly: both instances answered, nothing else was done'
        $setupDone = $true
        throw [System.Management.Automation.HaltCommandException]::new('done')
    }
    #endregion

    #region The two ends
    Start-Step 'Read the instances'
    $srcInfo = (Invoke-Sql -Server $SourceInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), MachineName = CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), BackupDir = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultBackupPath'))").Rows[0]
    $dstInfo = (Invoke-Sql -Server $DestinationInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), DataPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), LogPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath'))").Rows[0]
    $sourceHost = [string]$srcInfo['MachineName']

    if ([string]$srcInfo['ServerName'] -eq [string]$dstInfo['ServerName'] -and -not $DestinationDatabase) {
        throw 'The source and the destination are the same instance, so the copy needs -DestinationDatabase.'
    }

    $defaultData = [string]$dstInfo['DataPath']
    $defaultLog = [string]$dstInfo['LogPath']
    if (-not $defaultData -or -not $defaultLog) {
        # older instances leave those properties empty: master's own files are the next best guess
        $mf = Invoke-Sql -Server $DestinationInstance -Query "SELECT Type = type_desc, Path = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name))) FROM sys.master_files WHERE database_id = 1"
        foreach ($r in $mf.Rows) {
            if (-not $defaultData -and [string]$r['Type'] -eq 'ROWS') { $defaultData = [string]$r['Path'] }
            if (-not $defaultLog -and [string]$r['Type'] -eq 'LOG') { $defaultLog = [string]$r['Path'] }
        }
    }
    if ($DataPath) { $defaultData = $DataPath }
    if ($LogPath) { $defaultLog = $LogPath }
    if (-not $StandbyPath) { $StandbyPath = $defaultData }
    Write-Detail ('  restored files go to {0}{1}' -f $defaultData, $(if ($defaultLog -ne $defaultData) { " and $defaultLog" } else { '' }))
    Complete-Step
    #endregion

    #region Storage, once for all the databases
    if ($From -eq 'AzureBlob') {
        Start-Step 'Open the storage container'
        $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
        if ($found.Count -eq 0) {
            if (-not $InstallMissingModules) {
                Write-Deep ('module search path: ' + ($env:PSModulePath -split ';' -join ' | '))
                throw ("-From AzureBlob needs the Az.Storage module, which is not installed for $($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion). " +
                       'Re-run with -InstallMissingModules, or: Install-Module Az.Storage -Scope CurrentUser. ' +
                       'Modules installed for Windows PowerShell 5.1 are not visible to PowerShell 7, or the other way round, so check which one you are in.')
            }
            Write-Log 'Installing Az.Storage for the current user'
            Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
            $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
        }
        Write-Detail ('  Az.Storage {0} from {1}' -f $found[0].Version, $found[0].ModuleBase)
        # Import-Module has no -WhatIf of its own, but the preference reaches inside the module and
        # it then narrates everything it defines
        $savedWhatIf = $WhatIfPreference
        try {
            $WhatIfPreference = $false
            Import-Module -Name Az.Storage -Verbose:$false
        }
        finally { $WhatIfPreference = $savedWhatIf }

        $script:Blobs = Connect-BlobContainer -AccountName $StorageAccountName -Container $ContainerName `
                                              -Prefix $BlobPrefix -Sas $SasToken

        if (-not (Test-Path -LiteralPath $LocalBackupPath)) {
            Write-Detail "  creating $LocalBackupPath"
            New-Item -ItemType Directory -Path $LocalBackupPath -WhatIf:$false | Out-Null
        }
        if ($LocalBackupPath -match '^[A-Za-z]:\\Users\\') {
            Write-Log 'The staging folder is inside a user profile. The SQL Server service account usually cannot read there, which fails the header check - D:\RestoreStaging or similar is safer.' -Level WARN
        }
        Complete-Step
    }
    #endregion

    $setupDone = $true

    #==========================================================================
    # One database at a time. A failure on one is recorded and the rest carry on.
    #==========================================================================
    foreach ($dbName in $databases) {
        $dstName = if ($DestinationDatabase) { $DestinationDatabase } else { $dbName }
        $script:StepPrefix = if ($databases.Count -gt 1) { $dbName } else { '' }
        $script:Staged.Clear()

        $outcome = [pscustomobject]@{
            SourceInstance = $SourceInstance; Database = $dbName
            DestinationInstance = $DestinationInstance; DestinationDatabase = $dstName
            Result = 'FAILED'; Action = ''; RestoredTo = $null; Applied = 0; Bytes = 0; Detail = $null
        }
        $selected = $null
        $restored = $false
        $priorState = $null

        try {
            if ($SourceInstance -eq $DestinationInstance -and $dbName -eq $dstName) {
                throw 'Source and destination are the same database. Refusing to overwrite the master copy.'
            }
            Write-Log ('---- {0} -> {1}.[{2}] ----' -f $dbName, $DestinationInstance, $dstName)

            #region History
            Start-Step 'Read the backup history from the source'
            $history = Invoke-Sql -Server $SourceInstance -Query $SourceHistoryQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
            if ($history.Rows.Count -eq 0) {
                $extra = ''
                $offDisk = Invoke-Sql -Server $SourceInstance -Query $SourceOffDiskQuery -Parameters @{ '@db' = $dbName; '@days' = $HistoryDays }
                if ($offDisk.Rows.Count -and [int]$offDisk.Rows[0]['Kinds'] -gt 0) {
                    $extra = ' Its backups go to {0}, which this script does not restore from.' -f $offDisk.Rows[0]['Devices']
                }
                throw ("No disk backups of [{0}] in the last {1} days on {2}.{3}" -f $dbName, $HistoryDays, $SourceInstance, $extra)
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
            Write-Detail ('  {0} backup set(s) in history: {1} full, {2} differential, {3} log' -f $sets.Count,
                          @($sets | Where-Object { $_.Type -eq 'D' }).Count, @($sets | Where-Object { $_.Type -eq 'I' }).Count,
                          @($sets | Where-Object { $_.Type -eq 'L' }).Count)

            # with storage in the way, only what has finished uploading can be restored
            if ($From -eq 'AzureBlob') {
                $availability = Select-AvailableSets -BackupSets $sets -AvailableFiles @($script:Blobs.Index.Keys)
                foreach ($skip in $availability.Skipped) {
                    Write-Log ('Passing over the {0} backup finished {1}: not in storage yet ({2})' -f
                               $(switch ($skip.Set.Type) { 'D' { 'full' } 'I' { 'differential' } default { 'log' } }),
                               $skip.Set.FinishDate, ($skip.Missing -join ', ')) -Level WARN
                }
                $sets = $availability.Kept
                if ($sets.Count -eq 0) { throw "None of the backups of [$dbName] in the last $HistoryDays days are in the container yet. Check the upload process and -BlobPrefix; the blob name after any folder must match the file name recorded in msdb." }
            }
            Write-Log ('Newest usable backup finished {0}' -f (@($sets | Sort-Object FinishDate | Select-Object -Last 1)).FinishDate)
            Complete-Step
            #endregion

            #region What is on the destination
            Start-Step 'Look at the destination'
            $existing = $null
            $dstRow = Invoke-Sql -Server $DestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }
            if ($dstRow.Rows.Count) { $existing = $dstRow.Rows[0] }

            $lastRestore = $null
            $historyRow = Invoke-Sql -Server $DestinationInstance -Query $DestRestoreHistoryQuery -Parameters @{ '@db' = $dstName }
            if ($historyRow.Rows.Count) { $lastRestore = $historyRow.Rows[0] }

            $state = if ($existing) { [string]$existing['state_desc'] } else { 'ABSENT' }
            $inStandby = $existing -and [bool]$existing['is_in_standby']
            # a standby copy is reported ONLINE with is_in_standby set, not RESTORING - but it is
            # still mid-restore and still takes more log backups, which is the point of standby
            $isRestoring = ($state -eq 'RESTORING') -or $inStandby
            $dstFamily = if ($existing -and -not ($existing['family_guid'] -is [DBNull])) { ([guid]$existing['family_guid']).ToString() } else { $null }

            Write-Log ('The destination copy is ' + $(
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
            $already = Invoke-Sql -Server $DestinationInstance -Query $DestAlreadyRestoredQuery -Parameters @{ '@db' = $dstName; '@uuid' = $latestFull.Uuid }
            if ($already.Rows.Count) { $alreadyRow = $already.Rows[0] }
            Complete-Step

            # the plain refresh: same full already here, nothing asked for on top of it
            if ($alreadyRow -and $existing -and -not $isRestoring -and -not $KeepRestoring -and -not $Cutover -and -not $stopAtValue -and -not $Force) {
                Write-Log ('Already restored: the full backup of {0} was restored here {1}. Nothing to do.' -f
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
                Write-Log 'The copy is already online, so no more log backups can be applied to it. Restore it again with -Force to start a new copy.' -Level WARN
                $outcome.Result = 'CHECK'
                $outcome.Action = 'AlreadyOnline'
                $outcome.Detail = 'the copy is recovered; a new full restore is needed to roll it forward again'
                continue
            }

            if ($existing -and -not $isRestoring -and -not $isCopy -and -not $Force) {
                throw ("{0} on {1} is not a copy of {2} (no restore history for it, and the backup family does not match), so it has not been touched. Use -Force to overwrite it anyway." -f $dstName, $DestinationInstance, $dbName)
            }
            #endregion

            #region Work out the chain
            Start-Step 'Work out what to restore'
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

            $plan = New-Object System.Collections.Generic.List[string]
            if ($chain.Full) { $plan.Add('full of ' + $chain.Full.FinishDate.ToString('dd MMM HH:mm') + ' (' + (Format-Size $chain.Full.Size) + ')') }
            if ($chain.Diff) { $plan.Add('differential of ' + $chain.Diff.FinishDate.ToString('dd MMM HH:mm')) }
            if ($chain.Logs.Count) { $plan.Add(('{0} log backup(s) to {1}' -f $chain.Logs.Count, $chain.Logs[-1].FinishDate.ToString('dd MMM HH:mm'))) }
            if ($TailLog) { $plan.Add('the tail of the log, taken now') }

            if ($plan.Count -eq 0) {
                if (-not $Cutover) {
                    Write-Log 'Up to date already: the copy has everything the source has backed up.' -Level WARN
                    $outcome.Result = 'CHECK'
                    $outcome.Action = 'NothingNew'
                    $outcome.Detail = 'nothing new to apply'
                    Complete-Step -Result 'SKIPPED'
                    continue
                }
                $plan.Add('recovery only')
            }
            $finishText = if ($Cutover) { 'then online' } elseif ($Standby) { 'left readable in standby' } elseif ($KeepRestoring) { 'left restoring for more logs' } else { 'then online' }
            Write-Log (($plan -join ', ') + ', ' + $finishText)
            if ($chain.Gap) { Write-Log ('Chain gap: ' + $chain.Gap) -Level WARN }
            if ($chain.StopAtSet) { Write-Log ('Stopping at ' + $stopAtValue.ToString('dd MMM yyyy HH:mm:ss')) }

            if (@($toRestore | Where-Object { $_.Set.Encrypted }).Count) {
                Write-Log 'These backups are encrypted: the destination needs the same certificate or key, or the restore will fail.' -Level WARN
            }
            $tooNew = @($toRestore | Where-Object { [int]$_.Set.Major -gt [int]$dstInfo['Major'] })
            if ($tooNew.Count) {
                throw ('the backups were taken on SQL Server major version {0} and {1} is version {2}: a backup cannot be restored onto an older version' -f $tooNew[0].Set.Major, $DestinationInstance, $dstInfo['Major'])
            }
            Complete-Step
            #endregion

            #region Get the files where the destination can read them
            Start-Step $(if ($From -eq 'AzureBlob') { 'Download the backup file(s)' } else { 'Check the destination can read the backup file(s)' })
            if ($From -eq 'AzureBlob') {
                $needed = [long](@($toRestore | ForEach-Object { $_.Set.Size }) | Measure-Object -Sum).Sum
                $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($LocalBackupPath))
                if (-not $root.StartsWith('\\')) {
                    $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
                    Write-Detail ('  {0} has {1} free; this chain is about {2}' -f $root, (Format-Size $freeBytes), (Format-Size $needed))
                    if ($freeBytes -lt ($needed * 1.05)) {
                        throw ('Not enough free space on {0}: need about {1}, have {2}' -f $root, (Format-Size ($needed * 1.05)), (Format-Size $freeBytes))
                    }
                }
            }
            $downloadedBytes = 0
            foreach ($item in $toRestore) {
                $r = Resolve-BackupFiles -Files $item.Set.Files -DestinationServer $DestinationInstance `
                                         -SourceHost $sourceHost -Download:($From -eq 'AzureBlob')
                $downloadedBytes += $r.Bytes
                $item.Set = $item.Set | Select-Object * -ExcludeProperty Files
                $item.Set | Add-Member -NotePropertyName Files -NotePropertyValue $r.Files
            }
            $outcome.Bytes = $downloadedBytes
            Complete-Step
            #endregion

            #region Prove the file is the backup it claims to be
            if (-not $dryRun -and $toRestore.Count -gt 0) {
                Start-Step 'Read the backup header on the destination'
                # Deliberately before the destination database is touched: an unreadable staging
                # folder or the wrong file shows up here, while nothing is broken yet. The full is
                # the one worth proving; a cutover may have nothing but a tail log to apply.
                $first = @($toRestore | Where-Object { $_.Label -eq 'full' })
                if ($first.Count -eq 0) { $first = $toRestore[0] } else { $first = $first[0] }
                $deviceList = (@($first.Set.Files) | ForEach-Object { "DISK = N'" + (Esc-Str $_) + "'" }) -join ', '
                try {
                    $header = Invoke-Sql -Server $DestinationInstance -Query "RESTORE HEADERONLY FROM $deviceList"
                }
                catch {
                    $exception = $_.Exception.GetBaseException()
                    $number = 0
                    if ($exception -is [System.Data.SqlClient.SqlException]) { $number = $exception.Number }
                    if ($exception.Message -match 'Operating system error 5|Cannot open backup device') { $number = 3201 }
                    $explain = Get-SqlErrorExplanation -Number $number -Message $exception.Message
                    Write-Deep ('  header exception: ' + $exception.ToString())
                    throw ('Could not read the backup header: ' + ($exception.Message -split "`r?`n")[0] +
                           $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
                }
                $headerRow = $header.Rows[0]
                Write-Detail ('  header: [{0}], finished {1}, taken on major version {2}' -f
                              $headerRow['DatabaseName'], $headerRow['BackupFinishDate'], $headerRow['SoftwareVersionMajor'])
                if ([string]$headerRow['DatabaseName'] -ne $dbName) {
                    Write-Log ('The file on disk is a backup of [{0}], not [{1}]. Check the file names{2}.' -f
                               $headerRow['DatabaseName'], $dbName, $(if ($From -eq 'AzureBlob') { ' and -BlobPrefix' } else { '' })) -Level WARN
                }
                Complete-Step
            }
            #endregion

            #region Where the files go
            $moveList = $null
            if ($chain.Full -and -not $KeepFilePaths) {
                Start-Step 'Work out where the database files go'
                $fileList = Invoke-Sql -Server $DestinationInstance -Query (
                    'RESTORE FILELISTONLY FROM ' + ((@($toRestore[0].Set.Files) | ForEach-Object { "DISK = N'" + (Esc-Str $_) + "'" }) -join ', ') +
                    ' WITH FILE = ' + [int]$toRestore[0].Set.Position)
                $moveList = @{}
                foreach ($f in $fileList.Rows) {
                    $moveList[[string]$f['LogicalName']] = Get-MoveTarget -PhysicalName ([string]$f['PhysicalName']) -FileType ([string]$f['Type']) `
                                                            -DataPath $defaultData -LogPath $defaultLog -SourceDatabase $dbName -DestinationDatabase $dstName
                }
                foreach ($target in $moveList.Values) {
                    $owner = Get-Scalar -Server $DestinationInstance -Parameters @{ '@p' = $target } -Query `
                             'SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p'
                    if ($owner -and [string]$owner -ne $dstName) {
                        throw ("the file {0} already belongs to the database {1} on {2}. Use -DataPath / -LogPath to put the copy somewhere else." -f $target, $owner, $DestinationInstance)
                    }
                }
                Write-Detail ('  {0} file(s) to {1}' -f $moveList.Count, $defaultData)
                Complete-Step
            }
            #endregion

            #region Permission to go ahead
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
                         'SELECT session_id FROM sys.dm_exec_sessions WHERE database_id = DB_ID(@db) AND session_id <> @@SPID'
                if ($spids.Rows.Count) {
                    Write-Log ('{0} session(s) are using the copy, closing them' -f $spids.Rows.Count) -Level WARN
                    foreach ($s in $spids.Rows) {
                        try { [void](Invoke-Sql -Server $DestinationInstance -Query ('KILL ' + [int]$s['session_id'])) } catch { }
                    }
                }
            }
            #endregion

            #region The tail of the log, off the source
            if ($TailLog) {
                Start-Step 'Back up the tail of the log on the source'
                $folder = if ($TailLogPath) { $TailLogPath } else { [string]$srcInfo['BackupDir'] }
                if (-not $folder) { throw 'nowhere to put the tail log backup: pass -TailLogPath' }
                $tailFile = '{0}\{1}_tail_{2}.trn' -f $folder.TrimEnd('\'), $dbName, (Get-Date).ToString('yyyyMMdd_HHmmss')

                # one question for everything that happens to the source, asked before any of it
                # happens: being talked out of the tail log half way through would leave the source
                # in single user for no reason at all
                $ask = 'About to change the SOURCE database {0} on {1}:' -f $dbName, $SourceInstance
                if ($DisconnectSource) { $ask += "`r`n  - close every connection to it (SINGLE_USER WITH ROLLBACK IMMEDIATE); open transactions are rolled back" }
                $ask += "`r`n  - back up the tail of its log WITH NORECOVERY, which leaves it in a restoring state and unusable until someone recovers it."
                $ask += "`r`nThat is what a cutover is, but there is no undo. Go ahead?"
                if (-not (Confirm-Action $ask 'Cut over from the source database')) { throw 'the source was left alone, so nothing has been cut over' }

                if ($DisconnectSource) {
                    $sql = 'ALTER DATABASE {0} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' -f (Esc-Name $dbName)
                    if ($dryRun) { Write-Log ('would run: ' + $sql) }
                    else {
                        Write-Log 'Closing connections to the source database' -Level WARN
                        [void](Invoke-Sql -Server $SourceInstance -Query $sql)
                    }
                }

                $tailSql = "BACKUP LOG {0} TO DISK = N'{1}' WITH NORECOVERY, CHECKSUM, INIT, STATS = 5;" -f (Esc-Name $dbName), (Esc-Str $tailFile)
                if ($dryRun) { Write-Log ('would run: ' + $tailSql) }
                else {
                    Write-Log "Backing the tail of the log up to $tailFile"
                    $r = Invoke-LongRunningSql -Server $SourceInstance -Sql $tailSql -Label 'tail log'
                    if (-not $r.Ok) { throw ('the tail log backup failed, so the source has not been changed: ' + $r.Error) }
                    Write-Log ('Taken in {0}s - the source database is now in a restoring state' -f $r.Seconds) -Level WARN
                }

                # the destination has to be able to read it, and it does not go through storage:
                # waiting for an upload would defeat the point of a tail log
                $tailPath = Resolve-BackupPath -Path $tailFile -Map $BackupPathMap
                if (-not $dryRun -and -not (Test-DestinationFile -Server $DestinationInstance -Path $tailPath)) {
                    $viaShare = Get-AdminSharePath -Path $tailPath -SourceHost $sourceHost
                    if ($viaShare -and (Test-DestinationFile -Server $DestinationInstance -Path $viaShare)) { $tailPath = $viaShare }
                    else {
                        throw ("the tail log is at {0} but {1} cannot read it. It is a valid backup: put it somewhere both servers can see - -TailLogPath on a share - and apply it by hand, then recover the copy." -f $tailPath, $DestinationInstance)
                    }
                }
                $toRestore.Add([pscustomobject]@{
                    Set = [pscustomobject]@{ Position = 1; Files = @($tailPath); HasChecksums = $true }
                    Kind = 'Log'; Label = 'tail log'
                })
                Complete-Step
            }
            #endregion

            #region Restore
            Start-Step 'Restore on the destination'
            $target = "$DestinationInstance.[$dstName]"
            if ($existing -and $chain.Full -and -not $isRestoring -and -not $dryRun) {
                $priorState = $state
                Write-Log "Taking $target offline (rolling back open transactions)"
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET OFFLINE WITH ROLLBACK IMMEDIATE;' -f (Esc-Name $dstName)))
            }

            $applied = 0
            $seconds = 0.0
            try {
                # everything was already applied, and all that is left is to bring it online
                if ($Cutover -and $toRestore.Count -eq 0) {
                    $recoverSql = 'RESTORE DATABASE {0} WITH RECOVERY;' -f (Esc-Name $dstName)
                    if ($dryRun) { Write-Log ('would run: ' + $recoverSql) }
                    else {
                        Write-Log 'Nothing left to apply, so recovering the copy as it stands'
                        $r = Invoke-LongRunningSql -Server $DestinationInstance -Sql $recoverSql -Label 'recovery'
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
                    $sql = New-RestoreCommand -Database $dstName -BackupSet $item.Set -Kind $item.Kind -Finish $finish `
                               -StandbyFile $standbyFile -MoveList $(if ($item.Label -eq 'full') { $moveList } else { $null }) `
                               -Replace:($item.Label -eq 'full' -and $null -ne $existing) `
                               -StopAt $(if ($chain.StopAtSet -and $item.Set -eq $chain.StopAtSet) { $stopAtValue } else { $null })

                    if ($dryRun) { Write-Log ("would run:`r`n" + $sql) ; continue }

                    Write-Log ("Restoring the {0}" -f $item.Label)
                    $r = Invoke-LongRunningSql -Server $DestinationInstance -Sql $sql -Label $item.Label
                    if (-not $r.Ok) { throw ('{0} failed: {1}' -f $item.Label, $r.Error) }
                    $applied++
                    $seconds += $r.Seconds
                    $size = if ($r.Megabytes) { ', ' + (Format-Size ($r.Megabytes * 1MB)) } else { '' }
                    $rate = if ($r.Megabytes -and $r.Seconds -gt 0.5) { ' at {0:n0} MB/sec' -f ($r.Megabytes / $r.Seconds) } else { '' }
                    Write-Detail ('  {0} done in {1}s{2}{3}' -f $item.Label, $r.Seconds, $size, $rate)
                }
            }
            catch {
                # put the destination back as it was found, so a failed run does not leave it offline
                if ($priorState -and $priorState -notin 'OFFLINE', 'RESTORING') {
                    Write-Log "The restore failed; putting $target back online" -Level WARN
                    try { [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET ONLINE;' -f (Esc-Name $dstName))) }
                    catch { Write-Log ('  could not bring it back online: ' + $_.Exception.Message) -Level ERROR }
                }
                throw
            }
            $outcome.Applied = $applied

            if ($dryRun) {
                Write-Log ('{0} statement(s) would run, nothing was changed' -f $toRestore.Count)
                $outcome.Result = 'DRY RUN'
                $outcome.Action = 'WhatIf'
                Complete-Step -Result 'SKIPPED'
                continue
            }
            Complete-Step
            #endregion

            #region How it ended up
            $after = (Invoke-Sql -Server $DestinationInstance -Query $DestDatabaseQuery -Parameters @{ '@db' = $dstName }).Rows[0]
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
                    [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-Name $dstName)))
                    Write-Log ('The backup was taken while the database was {0}, so the copy has been opened up to MULTI_USER' -f ([string]$after['user_access_desc']).ToLower()) -Level WARN
                }
            }
            #endregion

            #region Once it is online
            if ($online) {
                if ($DatabaseOwner) {
                    Start-Step "Set the database owner to $DatabaseOwner"
                    $login = Get-Scalar -Server $DestinationInstance -Parameters @{ '@n' = $DatabaseOwner } -Query `
                             "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G')"
                    if (-not $login) {
                        Write-Log "There is no login called '$DatabaseOwner' on $DestinationInstance, so the owner has been left as restored." -Level WARN
                        Complete-Step -Result 'SKIPPED'
                    }
                    else {
                        try {
                            Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dstName `
                                -Statement ('ALTER AUTHORIZATION ON DATABASE::{DB} TO ' + (Esc-Name $DatabaseOwner) + ';')
                            Complete-Step
                        }
                        catch {
                            # a login cannot own the database and also be one of its users
                            Write-Log ("Could not make '{0}' the owner: {1} The owner has been left as restored." -f
                                       $DatabaseOwner, ($_.Exception.GetBaseException().Message -split "`r?`n")[0]) -Level WARN
                            Complete-Step -Result 'SKIPPED'
                        }
                    }
                }

                Start-Step 'Set PAGE_VERIFY CHECKSUM'
                Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dstName `
                    -Statement 'ALTER DATABASE {DB} SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;'
                Complete-Step

                if ($CompatibilityLevel -gt 0) {
                    Start-Step "Set compatibility level $CompatibilityLevel"
                    Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dstName `
                        -Statement "ALTER DATABASE {DB} SET COMPATIBILITY_LEVEL = $CompatibilityLevel;"
                    Complete-Step
                }

                if ($RepairOrphanUsers) {
                    Start-Step 'Point database users back at the destination logins'
                    $users = Repair-OrphanUser -Server $DestinationInstance -DatabaseName $dstName
                    if ($users.Remapped.Count) { Write-Log ('Remapped {0} user(s): {1}' -f $users.Remapped.Count, ($users.Remapped -join ', ')) }
                    if ($users.Blocked.Count) {
                        Write-Log ('Could not remap {0}: the login of that name is already mapped to another user here, usually because it owns the database. Drop or rename the user if it is still wanted.' -f ($users.Blocked -join ', ')) -Level WARN
                    }
                    if (-not $users.Remapped.Count -and -not $users.Blocked.Count) { Write-Detail '  no orphaned users to remap' }
                    Complete-Step
                }

                if ($UpdateStatistics) {
                    Start-Step 'Update statistics'
                    $r = Invoke-LongRunningSql -Server $DestinationInstance -Label 'statistics' `
                            -Sql ('EXEC {0}.sys.sp_updatestats;' -f (Esc-Name $dstName))
                    if (-not $r.Ok) { throw ('updating statistics failed: ' + $r.Error) }
                    Complete-Step
                }

                if ($RunCheckDb) {
                    Start-Step 'DBCC CHECKDB WITH DATA_PURITY'
                    $r = Invoke-LongRunningSql -Server $DestinationInstance -Label 'checkdb' `
                            -Sql ('DBCC CHECKDB ({0}) WITH DATA_PURITY, NO_INFOMSGS, ALL_ERRORMSGS;' -f (Esc-Name $dstName))
                    if (-not $r.Ok) { throw ('DBCC CHECKDB reported a problem: ' + $r.Error) }
                    Write-Log 'DBCC CHECKDB found nothing to report'
                    Complete-Step
                }
            }
            #endregion

            #region Tidy up and say how it went
            if ($From -eq 'AzureBlob' -and -not $KeepLocalCopy -and $script:Staged.Count -gt 0) {
                Start-Step 'Remove the staged copy'
                foreach ($file in $script:Staged) {
                    Write-Detail "  removing $file"
                    try { Remove-Item -LiteralPath $file -Force } catch { Write-Log ('  could not remove ' + $file + ': ' + $_.Exception.Message) -Level WARN }
                }
                Complete-Step
            }

            if ($Cutover) {
                Write-Log ('Cut over: {0} is online, {1} restore(s) in {2}s' -f $target, $applied, [math]::Round($seconds, 1))
                Write-Log 'Still to do by hand: logins and orphaned users, jobs, linked servers, and the connection strings' -Min Verbose
                if ($TailLog) { Write-Log ('{0} on {1} is in a restoring state. Leave it there until you are happy, then RESTORE DATABASE ... WITH RECOVERY puts it back.' -f $dbName, $SourceInstance) -Level WARN }
                $outcome.Result = 'CUT OVER'
                $outcome.Action = 'Cutover'
            }
            elseif ($KeepRestoring) {
                Write-Log ('{0} applied, copy {1} and up to {2}' -f $applied,
                           $(if ([bool]$after['is_in_standby']) { 'readable in standby' } else { 'left restoring' }),
                           $(if ($reached) { $reached.ToString('dd MMM HH:mm') } else { 'date unknown' }))
                Write-Log ('Run the same command again to apply the logs taken after {0}, and add -Cutover -TailLog when you are ready to switch' -f $(if ($reached) { $reached.ToString('HH:mm') } else { 'now' })) -Min Verbose
                $outcome.Result = 'ROLLING'
                $outcome.Action = 'Rolling'
            }
            else {
                Write-Log ('Restored and online, {0} restore(s) in {1}s, data as at {2}' -f $applied, [math]::Round($seconds, 1), $reached.ToString('dd MMM HH:mm'))
                $outcome.Result = 'RESTORED'
                $outcome.Action = 'Refresh'
            }
            if ($chain.Gap) { $outcome.Detail = $chain.Gap }
            #endregion
        }
        catch {
            if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
            $exception = $_.Exception.GetBaseException()
            $outcome.Result = 'FAILED'
            $outcome.Detail = ($exception.Message -split "`r?`n")[0]
            Write-Log ('[{0}] {1}' -f $dbName, $outcome.Detail) -Level ERROR
            foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
                Write-Log "  $extra" -Level ERROR
            }
            if ($exception -is [System.Data.SqlClient.SqlException]) {
                $explain = Get-SqlErrorExplanation -Number $exception.Number -Message $exception.Message
                if ($explain.Meaning) { Write-Log ('  what it means: ' + $explain.Meaning) -Level ERROR }
                if ($explain.Fix) { Write-Log ('  what to try: ' + $explain.Fix) -Level WARN }
            }
            Write-Deep ('full exception: ' + $exception.ToString())
            if ($_.ScriptStackTrace) { Write-Deep ('at: ' + $_.ScriptStackTrace) }
            if ($script:Staged.Count -gt 0 -and -not $restored) {
                Write-Log ('  the staged file(s) have been left in {0} for investigation' -f $LocalBackupPath) -Level WARN
            }
            if ($databases.Count -gt 1) { Write-Log '  carrying on with the remaining database(s)' -Level WARN }
        }
        finally {
            $script:StepPrefix = ''
            $results.Add($outcome)
        }
    }
}
catch [System.Management.Automation.HaltCommandException] {
    # -TestConnectionOnly finishing early, not a failure
}
catch {
    if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
    $exception = $_.Exception.GetBaseException()
    Write-Log ($exception.Message -split "`r?`n")[0] -Level ERROR
    foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
        Write-Log "  $extra" -Level ERROR
    }
    Write-Deep ('full exception: ' + $exception.ToString())
    if ($_.ScriptStackTrace) { Write-Deep ('at: ' + $_.ScriptStackTrace) }
    if ($script:Level -lt $script:LevelRank['Verbose']) {
        Write-Log 'Run again with -LogLevel Verbose (or Debug) for more, or -TestConnectionOnly to check the instances on their own.' -Level WARN
    }
}
finally {
    $elapsed = (Get-Date) - $runStart
    Write-Log '---------------- Run summary ----------------' -Min Quiet
    Write-Log "Source:       $SourceInstance" -Min Quiet
    Write-Log "Destination:  $DestinationInstance" -Min Quiet
    Write-Log ("Backups:      {0}" -f $(if ($From -eq 'AzureBlob') { "staged from $StorageAccountName/$ContainerName" } else { 'read where msdb says they are' })) -Min Quiet
    foreach ($outcome in $results) {
        $name = if ($outcome.DestinationDatabase -ne $outcome.Database) { '{0} -> {1}' -f $outcome.Database, $outcome.DestinationDatabase } else { $outcome.Database }
        $line = '{0,-12} {1}' -f $outcome.Result, $name
        if ($outcome.RestoredTo) { $line += ' (data as at {0})' -f $outcome.RestoredTo }
        if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
        Write-Log $line -Level $(if ($outcome.Result -eq 'FAILED') { 'ERROR' } elseif ($outcome.Result -eq 'CHECK') { 'WARN' } else { 'INFO' }) -Min Quiet
    }
    if ($script:Level -ge $script:LevelRank['Normal']) {
        foreach ($step in $script:Steps) { Write-Log ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
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
    Write-Log ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) -Level $(if ($bad) { 'ERROR' } else { 'INFO' }) -Min Quiet
    if ($script:LogFilePath) { Write-Log "Log file:     $script:LogFilePath" -Min Quiet }

    if ($CsvPath -and $results.Count) {
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Log "Saved to      $CsvPath" -Min Quiet
    }
    $script:ExitBad = $bad
}

if ($script:ExitBad) { exit 1 }
exit 0
