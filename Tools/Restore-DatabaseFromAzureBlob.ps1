#Requires -Version 5.1
<#
.SYNOPSIS
    Restores the latest completed full backup of a database from a source SQL Server onto a
    destination SQL Server, staging the backup through Azure Blob Storage and a local disk.

.DESCRIPTION
    Molehill Data Services

    For moving a database off an old server when the two cannot see each other, but both can see a
    storage account. The source database is the master copy at all times; anything on the
    destination with the same name is overwritten.

    Steps:
      1. Reads full backup history for the database from msdb on the source instance.
      2. Picks the newest backup whose file(s) are all present in the storage container. A backup
         msdb knows about but which has not finished uploading is skipped, so a half-written upload
         is never used (block blobs only become visible once fully committed).
      3. Downloads the file(s) to a local staging folder and checks each size against the blob.
      4. Reads the backup header on the destination BEFORE touching the existing database: this
         proves the SQL Server service account can read the staging folder, that the file is the
         backup it claims to be, and that this version of SQL Server can restore it.
      5. Takes the destination database offline (rolling back open connections) and restores over
         it WITH REPLACE. If the restore fails, the database is put back the way it was found.
      6. Applies post-restore steps (owner, PAGE_VERIFY CHECKSUM, plus optional compatibility
         level, orphaned user repair, statistics update and DBCC CHECKDB).
      7. Removes the local copy (unless -KeepLocalCopy) and prints a run summary.

    Backup files are matched to blobs by file name: the blob name, after any folder prefix, must be
    the same as the file name recorded in msdb on the source.

    Run this on the destination server. -LocalBackupPath must be a local disk that the destination
    SQL Server SERVICE ACCOUNT can read - not just you. A profile folder such as C:\Users\you\...
    will not do, and is the most common reason step 4 fails.

    WHEN IT WILL NOT CONNECT
    Connection problems are reported in detail rather than as one line: the name is resolved, the
    TCP port is tried, SQL Browser is asked about named instances, and the login error is explained
    with what usually causes it. -LogLevel Verbose shows every check; Debug adds the raw exceptions.
    An old source instance usually needs -TrustServerCertificate, because current SQL client
    libraries ask for an encrypted connection and SQL Server 2008 R2 has no certificate they trust.

    Supports -WhatIf: connects, reads history, lists blobs and reports the plan without downloading
    or restoring anything.

    Needs the dbatools and Az.Storage modules. Both ship nothing with this script; see
    -InstallMissingModules. Note that modules installed for Windows PowerShell 5.1 are not visible
    to PowerShell 7 and the other way round - the module check says which edition it is running in.

    Exit code: 0 = restored (or a clean dry run), 1 = failed, 2 = could not start (bad parameters
    or missing modules).

.PARAMETER SourceInstance
    SQL Server instance that took the backups. msdb backup history is read from here. Read-only.

.PARAMETER DestinationInstance
    SQL Server instance to restore onto. This is where the work happens.

.PARAMETER DatabaseName
    One or more database names on the source instance. Each is restored in turn, from its own latest
    backup; one failing does not stop the others, and the summary says what happened to each.

.PARAMETER DestinationDatabaseName
    Database name on the destination instance. Defaults to DatabaseName, and can only be used when
    restoring a single database - there is no sensible way to rename several at once.

.PARAMETER SourceSqlCredential
    SQL authentication credential for the source instance. Omit for Windows authentication.

.PARAMETER DestinationSqlCredential
    SQL authentication credential for the destination instance. Omit for Windows authentication.

.PARAMETER TrustServerCertificate
    Trust the server certificate and do not require an encrypted connection. Usually needed for
    SQL Server 2008 R2 and for any instance with a self-signed certificate.

.PARAMETER StorageAccountName
    Azure Storage account holding the backups.

.PARAMETER ContainerName
    Blob container holding the backups.

.PARAMETER BlobPrefix
    Optional virtual folder inside the container, e.g. 'LEGACYSERVER2008R2/MyDB'.

.PARAMETER SasToken
    Shared Access Signature with at least Read and List permission on the container. Takes a plain
    string or a SecureString; a leading '?' is removed. Wrap a plain string in SINGLE quotes - SAS
    tokens contain '&', which PowerShell treats as an operator outside quotes.

.PARAMETER LocalBackupPath
    Local staging folder for the downloaded file(s). Created if missing. Must be readable by the
    destination SQL Server service account.

.PARAMETER DataDirectory
    Destination folder for data files. Defaults to the destination instance default.

.PARAMETER LogDirectory
    Destination folder for log files. Defaults to the destination instance default.

.PARAMETER LookbackDays
    How many days of backup history to consider on the source. Default 14.

.PARAMETER DatabaseOwner
    Login to set as database owner after the restore. Checked for existence first. Pass an empty
    string to leave the owner as restored.

.PARAMETER CompatibilityLevel
    Compatibility level to set after the restore. 0 leaves it as restored (100 for SQL Server 2008 R2).

.PARAMETER RunCheckDb
    Run DBCC CHECKDB WITH DATA_PURITY after the restore. Worth it on a database coming off an old
    server, and slow on a big one.

.PARAMETER UpdateStatistics
    Run sp_updatestats after the restore.

.PARAMETER RepairOrphanUsers
    Remap database users to destination logins with the same name.

.PARAMETER KeepLocalCopy
    Keep the downloaded file(s) after a successful restore.

.PARAMETER InstallMissingModules
    Install dbatools and Az.Storage for the current user if they are missing.

.PARAMETER LogLevel
    How much to say. Quiet = problems and the summary only. Normal = each step and the decisions
    behind it (default). Verbose = every check, every candidate backup, every statement. Debug =
    Verbose plus raw exceptions, SQL error numbers and the redacted connection strings.
    Passing -Verbose or -Debug raises the level by itself.

.PARAMETER LogFile
    Append the same output to this file.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for each SQL connection and port test. Default 15.

.PARAMETER TestConnectionOnly
    Run the connection checks against both instances, print what they say, and stop. Nothing is
    read, downloaded or changed. Use this first when something will not connect.

.PARAMETER SelfTest
    Check the script's own logic - backup selection, error explanations, instance name parsing -
    without a server, a storage account or the modules.

.EXAMPLE
    .\Restore-DatabaseFromAzureBlob.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -DatabaseName MyDB -TestConnectionOnly -TrustServerCertificate
    # start here when it will not connect: every check, and what each failure usually means

.EXAMPLE
    # Dry run
    $sas = Read-Host -AsSecureString -Prompt 'SAS token'
    .\Restore-DatabaseFromAzureBlob.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -DatabaseName MyDB -StorageAccountName mycompany -ContainerName legacybackup `
        -BlobPrefix OLDSQL -SasToken $sas -LocalBackupPath D:\RestoreStaging `
        -TrustServerCertificate -WhatIf

.EXAMPLE
    .\Restore-DatabaseFromAzureBlob.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -DatabaseName MyDB -StorageAccountName mycompany -ContainerName legacybackup `
        -SasToken (Get-Secret -Name LegacyBackupSas) -LocalBackupPath D:\RestoreStaging `
        -TrustServerCertificate -CompatibilityLevel 170 -RepairOrphanUsers -UpdateStatistics `
        -RunCheckDb -LogLevel Verbose -LogFile D:\Logs\Restore-MyDB.log
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    # SQL Server
    [Parameter(Position = 0)]
    [string]$SourceInstance,

    [Parameter(Position = 1)]
    [string]$DestinationInstance,

    [Parameter(Position = 2)]
    [string[]]$DatabaseName,

    [string]$DestinationDatabaseName,

    [PSCredential]$SourceSqlCredential,

    [PSCredential]$DestinationSqlCredential,

    [switch]$TrustServerCertificate,

    # Azure Storage
    [string]$StorageAccountName,

    [string]$ContainerName,

    [string]$BlobPrefix,

    [object]$SasToken,

    # Restore
    [string]$LocalBackupPath,

    [string]$DataDirectory,

    [string]$LogDirectory,

    [ValidateRange(1, 365)]
    [int]$LookbackDays = 14,

    # Post-restore
    [string]$DatabaseOwner = 'sa',

    [ValidateSet(0, 100, 110, 120, 130, 140, 150, 160, 170)]
    [int]$CompatibilityLevel = 0,

    [switch]$RunCheckDb,

    [switch]$UpdateStatistics,

    [switch]$RepairOrphanUsers,

    # Housekeeping
    [switch]$KeepLocalCopy,

    [switch]$InstallMissingModules,

    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')]
    [string]$LogLevel = 'Normal',

    [string]$LogFile,

    [ValidateRange(1, 300)]
    [int]$ConnectTimeoutSeconds = 15,

    [switch]$TestConnectionOnly,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#==============================================================================
# Logging
#==============================================================================
$script:LevelRank = @{ Quiet = 0; Normal = 1; Verbose = 2; Debug = 3 }

# -Verbose and -Debug raise the level on their own, so either way of asking works
if ($PSBoundParameters.ContainsKey('Debug') -and $script:LevelRank[$LogLevel] -lt 3) { $LogLevel = 'Debug' }
elseif ($VerbosePreference -ne 'SilentlyContinue' -and $script:LevelRank[$LogLevel] -lt 2) { $LogLevel = 'Verbose' }

$script:Level       = $script:LevelRank[$LogLevel]
$script:LogPath     = $LogFile
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
    if ($script:LogPath -and $show) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -WhatIf:$false }
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
            Fix     = 'Current SQL client libraries ask for an encrypted connection, and an older instance has no certificate they trust. Add -TrustServerCertificate. This is the usual answer for SQL Server 2008 R2.'
        }
    }
    if ($m -match 'do not possess a common algorithm|existing connection was forcibly closed|SSL/TLS|schannel') {
        return [pscustomobject]@{
            Meaning = 'The two machines could not agree on a TLS version.'
            Fix     = 'SQL Server 2008 R2 only speaks TLS 1.2 from SP3 with KB3135244 (build 10.50.6542 or later). On SP2 or earlier it is TLS 1.0 only, so the machine running this script has to still allow TLS 1.0 - check SCHANNEL in the registry and the .NET strong crypto settings. -TrustServerCertificate does not help with this one: it is the protocol version, not the certificate.'
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

<#
  Picks which backup to restore: the newest full backup whose every file is already in the
  container. Anything newer that is still uploading is passed over, with the reason.

  Takes the grouped candidates and the set of blob file names, and returns the choice plus what was
  skipped, so the caller does the talking and this stays testable.
#>
function Select-BackupSet {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Candidates,
        [AllowEmptyCollection()][string[]]$BlobNames
    )

    $available = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $BlobNames) { if ($name) { [void]$available.Add($name) } }

    $skipped = New-Object System.Collections.Generic.List[object]
    $chosen = $null
    foreach ($candidate in ($Candidates | Sort-Object -Property Finished -Descending)) {
        $missing = @($candidate.Files | Where-Object { -not $available.Contains($_) })
        if ($missing.Count -eq 0) { $chosen = $candidate; break }
        $skipped.Add([pscustomobject]@{ Candidate = $candidate; Missing = $missing })
    }
    [pscustomobject]@{ Chosen = $chosen; Skipped = $skipped.ToArray() }
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

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

<#
  Runs one statement against a database on the destination. The token {DB} becomes
  QUOTENAME(database name) inside SQL Server, so the identifier is always quoted safely and the
  name never has to be pasted into the statement here.
#>
function Invoke-DbStatement {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Statement
    )
    $query = @'
DECLARE @sql nvarchar(max) = REPLACE(@Stmt, N'{DB}', QUOTENAME(@Db));
EXEC sys.sp_executesql @sql;
'@
    Write-Deep ("  statement: " + ($Statement -replace '\{DB\}', "[$Database]"))
    # QueryTimeout 0 = no timeout: a restore, CHECKDB or stats update can run for a long time
    Invoke-DbaQuery -SqlInstance $Instance -Database 'master' -Query $query `
        -SqlParameter @{ Db = $Database; Stmt = $Statement } -QueryTimeout 0 -EnableException | Out-Null
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

  ADO.NET does the login rather than dbatools, because the raw SqlException carries the error number
  that separates "wrong password" from "no route to the machine".
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
    # dbatools 2.x asks for an encrypted connection by default, so the check asks for one too.
    # Without this the check passes against a self-signed certificate and dbatools fails on it a
    # moment later, which is worse than no check at all.
    if ($Trust) {
        $builder['TrustServerCertificate'] = $true
        $builder['Encrypt'] = $false
    }
    else { $builder['Encrypt'] = $true }
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
    }
}

#==============================================================================
# Self test
#==============================================================================
if ($SelfTest) {
    $script:failed = 0
    function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    function Cand([string]$Finished, [string[]]$Files, [int]$Id = 1) {
        [pscustomobject]@{ BackupSetId = $Id; Finished = [datetime]$Finished; CopyOnly = $false; Files = $Files }
    }

    Write-Host 'Restore-DatabaseFromAzureBlob self test'
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

    Write-Host '  which backup to take' -ForegroundColor Gray
    $newest = Cand '2026-10-12 22:00' @('db_full_1012.bak') 3
    $middle = Cand '2026-10-11 22:00' @('db_full_1011.bak') 2
    $oldest = Cand '2026-10-10 22:00' @('db_full_1010.bak') 1
    $s = Select-BackupSet -Candidates @($oldest, $newest, $middle) -BlobNames @('db_full_1010.bak', 'db_full_1011.bak', 'db_full_1012.bak')
    Check 'the newest one that is there' ($s.Chosen.BackupSetId -eq 3)
    Check 'and nothing skipped' ($s.Skipped.Count -eq 0)

    $s = Select-BackupSet -Candidates @($oldest, $newest, $middle) -BlobNames @('db_full_1010.bak', 'db_full_1011.bak')
    Check 'a backup still uploading is passed over' ($s.Chosen.BackupSetId -eq 2)
    Check 'and the reason is reported' ($s.Skipped.Count -eq 1 -and $s.Skipped[0].Missing -contains 'db_full_1012.bak')

    $striped = Cand '2026-10-12 23:00' @('db_1.bak', 'db_2.bak', 'db_3.bak') 9
    $s = Select-BackupSet -Candidates @($striped, $middle) -BlobNames @('db_1.bak', 'db_3.bak', 'db_full_1011.bak')
    Check 'a striped backup needs every file' ($s.Chosen.BackupSetId -eq 2)
    Check 'and names the missing stripe' ($s.Skipped[0].Missing.Count -eq 1 -and $s.Skipped[0].Missing[0] -eq 'db_2.bak')
    $s = Select-BackupSet -Candidates @($striped) -BlobNames @('DB_1.BAK', 'db_2.bak', 'Db_3.Bak')
    Check 'blob names match whatever their case' ($null -ne $s.Chosen)
    $s = Select-BackupSet -Candidates @($newest) -BlobNames @()
    Check 'an empty container chooses nothing' ($null -eq $s.Chosen -and $s.Skipped.Count -eq 1)
    $s = Select-BackupSet -Candidates @() -BlobNames @('db_full_1012.bak')
    Check 'no history chooses nothing' ($null -eq $s.Chosen)

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
    Check 'a TLS version mismatch is told apart from a certificate problem' ($e.Meaning -match 'TLS version' -and $e.Fix -match 'TLS 1.0')
    Check 'and says the certificate switch will not fix it' ($e.Fix -match 'does not help')
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

    Write-Host '  sizes' -ForegroundColor Gray
    Check 'gigabytes' ((Format-Bytes 3221225472) -eq '3.00 GB')
    Check 'megabytes' ((Format-Bytes 5242880) -eq '5.0 MB')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Getting started
#==============================================================================
foreach ($required in 'SourceInstance', 'DestinationInstance') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        Write-Host "  -$required is needed." -ForegroundColor Red
        Write-Host '  Try: Get-Help .\Restore-DatabaseFromAzureBlob.ps1 -Detailed' -ForegroundColor Gray
        exit 2
    }
}
$databases = @($DatabaseName | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($databases.Count -eq 0) {
    Write-Host '  -DatabaseName is needed (one name, or several).' -ForegroundColor Red
    exit 2
}
if ($DestinationDatabaseName -and $databases.Count -gt 1) {
    Write-Host '  -DestinationDatabaseName renames one database, so it cannot be used with several. Run them separately, or leave the names as they are.' -ForegroundColor Red
    exit 2
}
if (-not $TestConnectionOnly) {
    foreach ($required in 'StorageAccountName', 'ContainerName', 'LocalBackupPath') {
        if (-not (Get-Variable -Name $required -ValueOnly)) {
            Write-Host "  -$required is needed (or use -TestConnectionOnly to check the instances first)." -ForegroundColor Red
            exit 2
        }
    }
    if ($null -eq $SasToken) {
        Write-Host '  -SasToken is needed (or use -TestConnectionOnly to check the instances first).' -ForegroundColor Red
        exit 2
    }
}

$SourceInstance = $SourceInstance.Trim()
$DestinationInstance = $DestinationInstance.Trim()

$runStart = Get-Date
$setupDone = $false
$results = New-Object System.Collections.Generic.List[object]
$storageContext = $null
$blobIndex = @{}

try {
    Write-Log ("Restore {0} database(s) from {1} to {2}{3}" -f $databases.Count, $SourceInstance, $DestinationInstance,
               $(if ($StorageAccountName) { " via $StorageAccountName/$ContainerName" } else { '' }))
    Write-Log ("Databases: " + ($databases -join ', '))
    Write-Detail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName) on $env:COMPUTERNAME; log level $LogLevel"
    if ($WhatIfPreference) { Write-Log 'WhatIf mode: nothing will be downloaded, restored or changed' -Level WARN }

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
    #endregion Connection checks

    #region Modules
    Start-Step 'Load modules'
    # ORDER MATTERS, do not tidy this into alphabetical: dbatools ships Azure.Storage.Blobs 12.18
    # and Az.Storage 9.x needs 12.25. Whichever loads first wins for the whole session, so loading
    # dbatools first makes every blob call fail with "Method not found: ...BlobBaseClient.GetProperties".
    foreach ($module in 'Az.Storage', 'dbatools') {
        $found = @(Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending)
        if ($found.Count -eq 0) {
            if (-not $InstallMissingModules) {
                Write-Deep ('module search path: ' + ($env:PSModulePath -split ';' -join ' | '))
                throw ("Module '$module' is not installed for $($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion). " +
                       "Re-run with -InstallMissingModules, or: Install-Module $module -Scope CurrentUser. " +
                       'Modules installed for Windows PowerShell 5.1 are not visible to PowerShell 7, or the other way round, so check which one you are in.')
            }
            Write-Log "Installing $module for the current user"
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
            $found = @(Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending)
        }
        Write-Detail ('  {0} {1} from {2}' -f $module, $found[0].Version, $found[0].ModuleBase)
        # Import-Module has no -WhatIf of its own, but the preference reaches inside the module and
        # dbatools then narrates every alias it defines. Turning it off around the import is the
        # only way to keep a -WhatIf run readable.
        $savedWhatIf = $WhatIfPreference
        try {
            $WhatIfPreference = $false
            Import-Module -Name $module -Verbose:$false
        }
        finally { $WhatIfPreference = $savedWhatIf }
    }

    $azureAssemblies = @([AppDomain]::CurrentDomain.GetAssemblies() |
                         Where-Object { $_.GetName().Name -eq 'Azure.Storage.Blobs' } |
                         ForEach-Object { $_.GetName().Version.ToString() })
    Write-Detail ('  Azure.Storage.Blobs loaded: ' + ($azureAssemblies -join ', '))
    if ($azureAssemblies.Count -gt 1) {
        Write-Log ("Two versions of Azure.Storage.Blobs are loaded in this session ({0}), which usually means dbatools was imported before Az.Storage - often by a PowerShell profile. The storage step may fail with 'Method not found'. Start a fresh PowerShell session and run this again." -f ($azureAssemblies -join ' and ')) -Level WARN
    }

    if ($TrustServerCertificate) {
        # session only, nothing is persisted
        Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true
        Set-DbatoolsConfig -FullName 'sql.connection.encrypt' -Value $false
        Write-Detail '  dbatools set to trust the server certificate and not require encryption for this session'
    }
    Complete-Step
    #endregion Modules

    #region Connect
    Start-Step 'Connect with dbatools'
    # NOTE: Connect-DbaInstance has no -EnableException; it throws on failure by itself.
    $sourceSplat = @{ SqlInstance = $SourceInstance; ConnectTimeout = $ConnectTimeoutSeconds }
    if ($SourceSqlCredential) { $sourceSplat.SqlCredential = $SourceSqlCredential }
    $destinationSplat = @{ SqlInstance = $DestinationInstance; ConnectTimeout = $ConnectTimeoutSeconds }
    if ($DestinationSqlCredential) { $destinationSplat.SqlCredential = $DestinationSqlCredential }

    # dbatools uses its own client library and its own defaults, so it can still refuse where the
    # check above succeeded. Explain that rather than handing over the raw message.
    try { $source = Connect-DbaInstance @sourceSplat }
    catch {
        $explain = Get-SqlErrorExplanation -Number 0 -Message $_.Exception.Message
        Write-Deep ('  dbatools exception: ' + $_.Exception.ToString())
        throw ("dbatools could not connect to the source $SourceInstance : " + ($_.Exception.Message -split "`r?`n")[0] +
               $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
    }
    try { $destination = Connect-DbaInstance @destinationSplat }
    catch {
        $explain = Get-SqlErrorExplanation -Number 0 -Message $_.Exception.Message
        Write-Deep ('  dbatools exception: ' + $_.Exception.ToString())
        throw ("dbatools could not connect to the destination $DestinationInstance : " + ($_.Exception.Message -split "`r?`n")[0] +
               $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
    }

    Write-Log "Source is $($source.VersionString); destination is $($destination.VersionString)"
    Write-Detail "  source edition $($source.Edition); destination edition $($destination.Edition)"
    Complete-Step
    #endregion Connect

    #region Storage listing, once for all the databases
    Start-Step 'List backup blobs in the storage container'
    # a quick name check first, because an account that does not exist otherwise takes Azure's six
    # retries and the best part of half a minute to say so
    try { [void][System.Net.Dns]::GetHostAddresses("$StorageAccountName.blob.core.windows.net") }
    catch {
        throw "The storage account '$StorageAccountName' does not resolve ($StorageAccountName.blob.core.windows.net). Check the name - it is the account name on its own, not a URL."
    }

    $sasPlain = ConvertTo-PlainSas -Token $SasToken
    Write-Deep ('  SAS parameters present: ' + (($sasPlain -split '&' | ForEach-Object { ($_ -split '=')[0] }) -join ', '))
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $sasPlain
    $sasPlain = $null

    $listSplat = @{ Container = $ContainerName; Context = $storageContext }
    if ($BlobPrefix) { $listSplat.Prefix = $BlobPrefix.Trim('/') + '/' }
    try { $blobs = @(Get-AzStorageBlob @listSplat) }
    catch {
        $storageMessage = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
        Write-Deep ('  storage exception: ' + $_.Exception.ToString())
        $hint = if ($storageMessage -match '403|not authorized|AuthenticationFailed|Signature') {
            'The SAS token was refused: it may have expired, be missing List permission (sp=rl at least), be for a different account, or have a start time in the future. Check the sv, se and sp values.'
        }
        elseif ($storageMessage -match '404|ContainerNotFound|does not exist') {
            "No container called '$ContainerName' in the account '$StorageAccountName'."
        }
        elseif ($storageMessage -match 'No such host|could not be resolved|Retry failed after') {
            "Could not reach '$StorageAccountName.blob.core.windows.net' at all. Check that this machine can reach Azure Storage."
        }
        elseif ($storageMessage -match 'Method not found') {
            'Two different versions of the Azure libraries are loaded in this session, which happens when dbatools is imported before Az.Storage. Start a fresh PowerShell session and run this again.'
        }
        else { '' }
        throw ("Could not list the container: $storageMessage" + $(if ($hint) { " $hint" } else { '' }))
    }
    Write-Log "Found $($blobs.Count) blob(s) under '$ContainerName/$BlobPrefix'"

    # index by file name; where the same name exists in several folders, the newest wins
    foreach ($blob in $blobs) {
        $leaf = ($blob.Name -split '/')[-1]
        if (-not $blobIndex.ContainsKey($leaf) -or $blob.LastModified -gt $blobIndex[$leaf].LastModified) {
            $blobIndex[$leaf] = $blob
        }
        Write-Deep ('  blob {0} ({1})' -f $blob.Name, (Format-Bytes $blob.Length))
    }
    if ($blobs.Count -eq 0) {
        Write-Log "The container listing came back empty. If the backups sit in a folder, -BlobPrefix has to name it (the parent folder is enough when several databases share it)." -Level WARN
    }
    Complete-Step
    #endregion Storage listing

    $setupDone = $true

    #==========================================================================
    # One database at a time. A failure on one is recorded and the rest carry on.
    #==========================================================================
    foreach ($database in $databases) {
        $destinationDatabase = if ($DestinationDatabaseName) { $DestinationDatabaseName } else { $database }
        $script:StepPrefix = if ($databases.Count -gt 1) { $database } else { '' }

        $outcome = [pscustomobject]@{
            Database = $database; DestinationDatabase = $destinationDatabase; Result = 'FAILED'
            Backup = $null; Bytes = 0; Files = 0; Detail = $null
        }
        $selected = $null
        $localFiles = @()
        $bytesNeeded = 0
        $restored = $false
        $priorState = $null

        try {
            if ($SourceInstance -eq $DestinationInstance -and $database -eq $destinationDatabase) {
                throw 'Source and destination are the same database. Refusing to overwrite the master copy.'
            }
            Write-Log ("---- {0} -> {1}.[{2}] ----" -f $database, $DestinationInstance, $destinationDatabase)

            #region Backup history
            Start-Step 'Read full backup history from source msdb'
            $historyQuery = @'
SELECT  bs.backup_set_id,
        bs.backup_finish_date,
        bs.is_copy_only,
        bs.backup_size,
        bmf.family_sequence_number,
        bmf.physical_device_name
FROM    msdb.dbo.backupset AS bs
JOIN    msdb.dbo.backupmediafamily AS bmf
        ON bmf.media_set_id = bs.media_set_id
WHERE   bs.database_name = @DatabaseName
AND     bs.type = 'D'                     -- full database backups
AND     bs.is_damaged = 0
AND     bmf.device_type IN (2, 102)       -- disk, and logical disk device
AND     bmf.mirror = 0                    -- primary media only, ignore MIRROR TO copies
AND     bs.backup_finish_date >= DATEADD(DAY, -@LookbackDays, GETDATE())
ORDER BY bs.backup_finish_date DESC, bmf.family_sequence_number;
'@
            $historyRows = @(Invoke-DbaQuery -SqlInstance $source -Database 'msdb' -Query $historyQuery `
                    -SqlParameter @{ DatabaseName = $database; LookbackDays = $LookbackDays } -As PSObject -EnableException)

            if ($historyRows.Count -eq 0) {
                throw "No full disk backups of [$database] on $SourceInstance in the last $LookbackDays day(s). Check the database name and -LookbackDays; backups written to URL or tape are not used by this script."
            }

            # one candidate per backup set; a striped backup has several files
            $candidates = @(
                $historyRows | Group-Object -Property backup_set_id | ForEach-Object {
                    $first = $_.Group[0]
                    [pscustomobject]@{
                        BackupSetId = $first.backup_set_id
                        Finished    = $first.backup_finish_date
                        CopyOnly    = [bool]$first.is_copy_only
                        SizeBytes   = [double]$first.backup_size
                        Files       = @($_.Group | Sort-Object -Property family_sequence_number |
                                        ForEach-Object { [System.IO.Path]::GetFileName($_.physical_device_name) })
                    }
                } | Sort-Object -Property Finished -Descending
            )
            Write-Log "Found $($candidates.Count) full backup(s) in the last $LookbackDays day(s); newest finished $($candidates[0].Finished)"
            foreach ($candidate in $candidates) {
                Write-Detail ('  set {0}: finished {1}{2}, {3} file(s): {4}' -f $candidate.BackupSetId, $candidate.Finished,
                              $(if ($candidate.CopyOnly) { ', copy-only' } else { '' }), $candidate.Files.Count, ($candidate.Files -join ', '))
            }
            Complete-Step
            #endregion Backup history

            #region Choose
            Start-Step 'Match the backup to the blobs in storage'
            $choice = Select-BackupSet -Candidates $candidates -BlobNames @($blobIndex.Keys)
            foreach ($skip in $choice.Skipped) {
                Write-Log ('Skipping the backup finished {0}: not in storage yet ({1})' -f $skip.Candidate.Finished, ($skip.Missing -join ', ')) -Level WARN
            }
            $selected = $choice.Chosen
            if (-not $selected) {
                throw "None of the $($candidates.Count) recent full backup(s) of [$database] are fully present in the container. Check the upload process and -BlobPrefix; the blob name after any folder must match the file name recorded in msdb."
            }

            $selectedBlobs = @($selected.Files | ForEach-Object { $blobIndex[$_] })
            $bytesNeeded = [long]($selectedBlobs | Measure-Object -Property Length -Sum).Sum
            $copyOnlyText = if ($selected.CopyOnly) { ', copy-only' } else { '' }
            Write-Log ('Selected the backup finished {0}{1}: {2} file(s), {3}' -f $selected.Finished, $copyOnlyText, $selectedBlobs.Count, (Format-Bytes $bytesNeeded))
            foreach ($blob in $selectedBlobs) { Write-Log ('  {0} ({1})' -f $blob.Name, (Format-Bytes $blob.Length)) -Min Verbose }
            $outcome.Backup = $selected.Finished
            $outcome.Bytes = $bytesNeeded
            $outcome.Files = $selectedBlobs.Count
            Complete-Step
            #endregion Choose

            #region Download
            Start-Step 'Download the backup file(s) to the staging folder'
            if (-not (Test-Path -LiteralPath $LocalBackupPath)) {
                Write-Detail "  creating $LocalBackupPath"
                New-Item -ItemType Directory -Path $LocalBackupPath -WhatIf:$false | Out-Null
            }

            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($LocalBackupPath))
            if (-not $root.StartsWith('\\')) {
                $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
                Write-Detail ('  {0} has {1} free; this backup needs {2}' -f $root, (Format-Bytes $freeBytes), (Format-Bytes $bytesNeeded))
                if ($freeBytes -lt ($bytesNeeded * 1.05)) {
                    throw ('Not enough free space on {0}: need {1}, have {2}{3}' -f $root, (Format-Bytes ($bytesNeeded * 1.05)), (Format-Bytes $freeBytes),
                           $(if ($KeepLocalCopy -and $databases.Count -gt 1) { '. -KeepLocalCopy keeps every database''s backup, which adds up over several' } else { '' }))
                }
            }
            if ($LocalBackupPath -match '^[A-Za-z]:\\Users\\') {
                Write-Log 'The staging folder is inside a user profile. The SQL Server service account usually cannot read there, which fails the next step - D:\RestoreStaging or similar is safer.' -Level WARN
            }

            $downloadedAny = $false
            $localFiles = @(
                foreach ($blob in $selectedBlobs) {
                    $target = Join-Path -Path $LocalBackupPath -ChildPath (($blob.Name -split '/')[-1])
                    if ($PSCmdlet.ShouldProcess($blob.Name, "Download to $target")) {
                        $timer = [System.Diagnostics.Stopwatch]::StartNew()
                        Get-AzStorageBlobContent -Container $ContainerName -Blob $blob.Name -Destination $target `
                            -Context $storageContext -Force | Out-Null
                        $timer.Stop()
                        $localLength = (Get-Item -LiteralPath $target).Length
                        if ($localLength -ne $blob.Length) {
                            throw "Size mismatch for $($target): the blob is $($blob.Length) bytes and the local file is $localLength bytes"
                        }
                        $rate = if ($timer.Elapsed.TotalSeconds -gt 0.5) { ' at {0}/s' -f (Format-Bytes ($localLength / $timer.Elapsed.TotalSeconds)) } else { '' }
                        Write-Log ('  {0} ({1}) in {2:N1}s{3}' -f (Split-Path -Leaf $target), (Format-Bytes $localLength), $timer.Elapsed.TotalSeconds, $rate)
                        $downloadedAny = $true
                    }
                    $target
                }
            )
            Complete-Step -Result $(if ($downloadedAny) { 'OK' } else { 'SKIPPED' })
            #endregion Download

            #region Check the backup before touching anything
            if ($downloadedAny) {
                Start-Step 'Read the backup header on the destination'
                # Deliberately before the destination database is touched: this is where "the service
                # account cannot read the staging folder" shows up, and nothing is broken yet.
                $deviceList = ($localFiles | ForEach-Object { "DISK = N'" + ($_ -replace "'", "''") + "'" }) -join ', '
                try {
                    $header = @(Invoke-DbaQuery -SqlInstance $destination -Database 'master' -As PSObject -EnableException `
                                -Query "RESTORE HEADERONLY FROM $deviceList")
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
                $headerRow = $header[0]
                Write-Detail ('  header: database [{0}], finished {1}, taken on SQL Server major version {2}' -f
                              $headerRow.DatabaseName, $headerRow.BackupFinishDate, $headerRow.SoftwareVersionMajor)

                if ([string]$headerRow.DatabaseName -ne $database) {
                    Write-Log ('The backup in the staging folder is of [{0}], not [{1}]. Check -BlobPrefix and the file names.' -f $headerRow.DatabaseName, $database) -Level WARN
                }
                $destinationMajor = [int]$destination.VersionMajor
                $backupMajor = [int]$headerRow.SoftwareVersionMajor
                if ($backupMajor -gt $destinationMajor) {
                    throw ('The backup was taken on SQL Server major version {0} and {1} is version {2}. A backup can only be restored onto the same version or newer.' -f
                           $backupMajor, $DestinationInstance, $destinationMajor)
                }
                Write-Log ('Backup header checks out: [{0}] taken on version {1}, restoring onto version {2}' -f $headerRow.DatabaseName, $backupMajor, $destinationMajor)
                Complete-Step
            }
            #endregion Check

            #region Restore
            Start-Step 'Restore the database on the destination'
            $target = "$DestinationInstance.[$destinationDatabase]"

            if ($PSCmdlet.ShouldProcess($target, 'Take offline and restore WITH REPLACE')) {
                $existing = Get-DbaDatabase -SqlInstance $destination -Database $destinationDatabase -EnableException
                if ($existing) {
                    $priorState = [string]$existing.Status
                    Write-Detail "  the existing copy is $priorState, owner $($existing.Owner), $([math]::Round($existing.SizeMB, 0)) MB"
                    Write-Log "Taking $target offline (rolling back open transactions)"
                    Set-DbaDbState -SqlInstance $destination -Database $destinationDatabase -Offline -Force -EnableException | Out-Null
                }
                else { Write-Detail '  nothing of that name on the destination yet' }

                $restoreSplat = @{
                    SqlInstance     = $destination
                    Path            = $localFiles
                    DatabaseName    = $destinationDatabase
                    WithReplace     = $true
                    EnableException = $true
                }
                if ($DataDirectory) { $restoreSplat.DestinationDataDirectory = $DataDirectory }
                if ($LogDirectory)  { $restoreSplat.DestinationLogDirectory = $LogDirectory }
                if ($destinationDatabase -ne $database) { $restoreSplat.ReplaceDbNameInFile = $true }
                Write-Detail ('  restoring from {0}' -f ($localFiles -join ', '))

                try { $restoreResult = @(Restore-DbaDatabase @restoreSplat) }
                catch {
                    # put the destination back as it was found, so a failed run does not leave it offline
                    if ($priorState -and $priorState -ne 'Offline') {
                        Write-Log "The restore failed; putting $target back $priorState" -Level WARN
                        try { Set-DbaDbState -SqlInstance $destination -Database $destinationDatabase -Online -Force -EnableException | Out-Null }
                        catch { Write-Log "  could not bring it back online: $($_.Exception.Message)" -Level ERROR }
                    }
                    throw
                }
                if (-not ($restoreResult | Where-Object { $_.RestoreComplete })) {
                    throw "Restore-DbaDatabase did not report a completed restore for $target"
                }
                $restored = $true
                Write-Log ("Restored {0}" -f $target)
                Complete-Step
            }
            else { Complete-Step -Result 'SKIPPED' }
            #endregion Restore

            #region Post-restore
            if ($restored) {
                if ($DatabaseOwner) {
                    Start-Step "Set the database owner to $DatabaseOwner"
                    $login = @(Invoke-DbaQuery -SqlInstance $destination -Database 'master' -As PSObject -EnableException `
                               -Query 'SELECT name FROM sys.server_principals WHERE name = @Owner AND type IN (''S'',''U'',''G'')' `
                               -SqlParameter @{ Owner = $DatabaseOwner })
                    if ($login.Count -eq 0) {
                        Write-Log "There is no login called '$DatabaseOwner' on $DestinationInstance, so the owner has been left as restored. Pass -DatabaseOwner with a login that exists, or '' to leave it alone." -Level WARN
                        Complete-Step -Result 'SKIPPED'
                    }
                    else {
                        Set-DbaDbOwner -SqlInstance $destination -Database $destinationDatabase -TargetLogin $DatabaseOwner -EnableException | Out-Null
                        Complete-Step
                    }
                }

                Start-Step 'Set PAGE_VERIFY CHECKSUM'
                Invoke-DbStatement -Instance $destination -Database $destinationDatabase `
                    -Statement 'ALTER DATABASE {DB} SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;'
                Complete-Step

                if ($CompatibilityLevel -gt 0) {
                    Start-Step "Set compatibility level $CompatibilityLevel"
                    Invoke-DbStatement -Instance $destination -Database $destinationDatabase `
                        -Statement "ALTER DATABASE {DB} SET COMPATIBILITY_LEVEL = $CompatibilityLevel;"
                    Complete-Step
                }

                if ($RepairOrphanUsers) {
                    Start-Step 'Repair orphaned users'
                    Repair-DbaDbOrphanUser -SqlInstance $destination -Database $destinationDatabase -EnableException | Out-Null
                    Complete-Step
                }

                if ($UpdateStatistics) {
                    Start-Step 'Update statistics'
                    Invoke-DbStatement -Instance $destination -Database $destinationDatabase `
                        -Statement 'EXEC {DB}.sys.sp_updatestats;'
                    Complete-Step
                }

                if ($RunCheckDb) {
                    Start-Step 'DBCC CHECKDB WITH DATA_PURITY'
                    Invoke-DbStatement -Instance $destination -Database $destinationDatabase `
                        -Statement 'DBCC CHECKDB ({DB}) WITH DATA_PURITY, NO_INFOMSGS, ALL_ERRORMSGS;'
                    Complete-Step
                }

                if (-not $KeepLocalCopy) {
                    Start-Step 'Remove the local backup copy'
                    foreach ($file in $localFiles) {
                        Write-Detail "  removing $file"
                        Remove-Item -LiteralPath $file -Force
                    }
                    Complete-Step
                }
                else { Write-Log "Local copy kept in $LocalBackupPath" }
            }
            #endregion Post-restore

            $outcome.Result = if ($restored) { 'RESTORED' } else { 'DRY RUN' }
        }
        catch {
            if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
            $exception = $_.Exception.GetBaseException()
            $outcome.Result = 'FAILED'
            $outcome.Detail = ($exception.Message -split "`r?`n")[0]
            Write-Log ("[{0}] {1}" -f $database, $outcome.Detail) -Level ERROR
            foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
                Write-Log "  $extra" -Level ERROR
            }
            if ($exception -is [System.Data.SqlClient.SqlException]) {
                $explain = Get-SqlErrorExplanation -Number $exception.Number -Message $exception.Message
                if ($explain.Meaning) { Write-Log "  what it means: $($explain.Meaning)" -Level ERROR }
                if ($explain.Fix) { Write-Log "  what to try: $($explain.Fix)" -Level WARN }
            }
            Write-Deep ('full exception: ' + $exception.ToString())
            if ($_.ScriptStackTrace) { Write-Deep ('at: ' + $_.ScriptStackTrace) }
            if ($localFiles.Count -gt 0 -and -not $restored) {
                Write-Log "  any downloaded file(s) have been left in $LocalBackupPath for investigation" -Level WARN
            }
            if ($databases.Count -gt 1) { Write-Log "  carrying on with the remaining database(s)" -Level WARN }
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
    foreach ($outcome in $results) {
        $name = if ($outcome.DestinationDatabase -ne $outcome.Database) { '{0} -> {1}' -f $outcome.Database, $outcome.DestinationDatabase } else { $outcome.Database }
        $line = '{0,-9} {1}' -f $outcome.Result, $name
        if ($outcome.Backup) { $line += ' (backup of {0}, {1} file(s), {2})' -f $outcome.Backup, $outcome.Files, (Format-Bytes $outcome.Bytes) }
        if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
        Write-Log $line -Level $(if ($outcome.Result -eq 'FAILED') { 'ERROR' } else { 'INFO' }) -Min Quiet
    }
    if ($script:Level -ge $script:LevelRank['Normal']) {
        foreach ($step in $script:Steps) {
            Write-Log ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step)
        }
    }
    $failedCount = @($results | Where-Object { $_.Result -eq 'FAILED' }).Count
    $okCount = @($results | Where-Object { $_.Result -eq 'RESTORED' }).Count
    $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
               elseif ($TestConnectionOnly) { 'CONNECTION CHECK' }
               elseif ($failedCount -gt 0 -and $okCount -gt 0) { "PARTLY DONE ($okCount of $($results.Count))" }
               elseif ($failedCount -gt 0) { 'FAILED' }
               elseif ($okCount -gt 0) { 'SUCCEEDED' }
               else { 'DRY RUN' }
    $bad = (-not $setupDone) -or $failedCount -gt 0
    Write-Log ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) -Level $(if ($bad) { 'ERROR' } else { 'INFO' }) -Min Quiet
    if ($script:LogPath) { Write-Log "Log file:     $script:LogPath" -Min Quiet }
    $script:ExitBad = $bad
}

if ($script:ExitBad) { exit 1 }
exit 0
