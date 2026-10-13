#Requires -Version 5.1
<#
.SYNOPSIS
    Restores the newest full backup sitting in an Azure Blob Storage container onto a destination
    SQL Server, then tidies each copy up: users cleared out, owner set, recovery model set, and
    optionally users added back and the database made read-only.

.DESCRIPTION
    Molehill Data Services

    For keeping a set of databases refreshed from backups that are already in blob storage. There is
    no source SQL Server in this at all: the container is the source of truth, and the newest backup
    found in each database's folder is the one restored.

    The container is expected to be laid out one folder per database:

        FULL/DAILY/<database name>/<something>.bak

    so -Database Sales,Stock reads FULL/DAILY/Sales/ and FULL/DAILY/Stock/ and takes the newest
    .bak from each. -BlobPathPattern changes that shape if yours differs.

    WHAT HAPPENS TO EACH DATABASE
      1. The newest backup in its folder is downloaded to the staging folder and its header read,
         which proves it is a full backup of the database it claims to be and that the destination
         can read the file at all.
      2. Anything of that name on the destination is taken offline and restored over.
      3. Then, once every database has been restored:
           * every user is dropped except the built-in ones (dbo, guest, INFORMATION_SCHEMA, sys)
             and the fixed roles. A user owning a schema has that schema handed to dbo first,
             because otherwise it cannot be dropped. Anything that still refuses is reported with
             the reason rather than passed over in silence.
           * the owner is set to sa
           * the recovery model is set to SIMPLE
           * -AddUser creates the users you name, assuming each login already exists on the
             destination - and warning, rather than failing, where one does not
           * -ReadOnly, last of all, sets the database read-only

    The order matters and is deliberate: users are cleared before the owner is set, so nothing
    clashes with sa, and read-only is left until the very end because a read-only database cannot
    be changed further.

    Needs the Az.Storage module and nothing else; the restores are plain T-SQL.

    THE STAGING FOLDER
    -LocalBackupPath has to be readable by the destination SQL Server SERVICE ACCOUNT, not just by
    you. A path under C:\Users will not do. The easiest arrangement is to run this on the
    destination server with a staging folder on one of its own drives.

    Exit code: 0 = every database done (or a clean dry run), 1 = at least one failed, 2 = could not
    start.

.PARAMETER DestinationInstance
    The instance to restore onto.

.PARAMETER Database
    One or more database names. Each names both the folder to read in the container and the
    database to restore onto the destination.

.PARAMETER StorageAccountName
    The storage account holding the backups. The account name on its own, not a URL.

.PARAMETER ContainerName
    The blob container.

.PARAMETER SasToken
    A Shared Access Signature with at least Read and List permission on the container. Takes a
    plain string or a SecureString; a leading '?' is removed. Wrap a plain string in SINGLE quotes -
    SAS tokens contain '&', which PowerShell treats as an operator otherwise.

.PARAMETER BlobPathPattern
    Where to look inside the container, with {db} standing in for the database name. Default
    'FULL/DAILY/{db}/'. Backslashes are accepted and turned into the forward slashes blob storage
    actually uses.

.PARAMETER LocalBackupPath
    Staging folder for the downloaded backup. Created if missing. Must be readable by the
    destination SQL Server service account.

.PARAMETER DataPath
    Where to put the data files. Default: the destination instance's own default data path.

.PARAMETER LogPath
    Where to put the log file. Default: the destination instance's own default log path.

.PARAMETER Owner
    The login to make the database owner. Default 'sa'. If there is no login of that name, the
    login that really is the system administrator (principal 1) is used and the substitution is
    reported - that covers an instance where sa has been renamed.

.PARAMETER RecoveryModel
    The recovery model to set once restored. Default SIMPLE.

.PARAMETER AddUser
    Users to create, each mapped to a login of the same name that is expected to exist already. A
    missing login is a warning, not a failure.

    An entry can name which database it is for, so one user need not go into all of them. Three
    shapes are accepted, and they can be mixed:

      'BiTeam'                             every database in -Database
      'Sales:BiTeam:db_datareader'         that database only, with that role
      @{ Database = 'Sales'; User = 'REPORTS\BiTeam'; Role = 'db_datareader', 'db_datawriter' }

    The colon form exists because powershell.exe -File turns every argument into a string and
    cannot pass a hashtable at all, which is what a scheduled task will be doing. Use '*' as the
    database to mean all of them. Roles can be comma separated inside the third part. Naming a
    database that is not in -Database is refused up front rather than quietly doing nothing.

.PARAMETER AddUserRole
    The role or roles to use for entries that do not name their own, e.g. db_datareader, db_owner.
    Without a role a user is created with no permissions at all, which is rarely what anyone wants.

.PARAMETER ReadOnly
    Set each database read-only once everything else is done.

.PARAMETER KeepUsers
    Leave the existing users alone instead of clearing them out.

.PARAMETER KeepLocalCopy
    Keep the downloaded backup files instead of deleting them after a successful restore.

.PARAMETER Force
    Overwrite a database on the destination even when it was not put there by this script.

.PARAMETER SqlCredential
    SQL authentication for the destination. Windows authentication is used when this is left out.

.PARAMETER TrustServerCertificate
    Trust the server certificate, which an instance with a self-signed one needs.

.PARAMETER LogLevel
    How much to say. Quiet = problems and the summary only. Normal = each step and the decisions
    behind it (default). Verbose = every blob considered and every statement. Debug = Verbose plus
    raw exceptions and SQL error numbers. -Verbose or -Debug raise it by themselves.

.PARAMETER LogFile
    Append the same output to this file.

.PARAMETER CsvPath
    Write one row per database, with the outcome, to a CSV file.

.PARAMETER InstallMissingModules
    Install Az.Storage for the current user if it is missing.

.PARAMETER SelfTest
    Check the script's own logic - picking the newest backup, the blob paths it builds, the
    principals it will and will not drop - without a server, a storage account or any module.

.EXAMPLE
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging

.EXAMPLE
    # refreshed, tidied, and handed to the reporting team read-only
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser REPORTS\BiTeam -AddUserRole db_datareader -ReadOnly

.EXAMPLE
    # the reporting team on Sales only, the application account on both
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser 'Sales:REPORTS\BiTeam:db_datareader', 'AppSvc' -AddUserRole db_datawriter

.EXAMPLE
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging -WhatIf
    # lists the backup it would use and the statements it would run, and changes nothing

.NOTES
    Molehill Data Services. The container is only ever read. On the destination, the named databases
    are overwritten - that is the point - so check the names.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)] [string] $DestinationInstance,
    [Parameter(Position = 1)] [Alias('DatabaseName')] [string[]] $Database,

    # the container
    [string] $StorageAccountName,
    [string] $ContainerName,
    [object] $SasToken,
    [string] $BlobPathPattern = 'FULL/DAILY/{db}/',
    [string] $LocalBackupPath,
    [switch] $KeepLocalCopy,
    [switch] $InstallMissingModules,

    # where the restored files go
    [Alias('DataDirectory')] [string] $DataPath,
    [Alias('LogDirectory')] [string] $LogPath,

    # what to do with each copy afterwards
    [string] $Owner = 'sa',
    [ValidateSet('SIMPLE', 'FULL', 'BULK_LOGGED')] [string] $RecoveryModel = 'SIMPLE',
    [object[]] $AddUser,
    [string[]] $AddUserRole,
    [switch] $ReadOnly,
    [switch] $KeepUsers,

    # connecting
    [PSCredential] $SqlCredential,
    [switch] $TrustServerCertificate,
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

    # saying what happened
    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
    [string] $LogFile,
    [string] $CsvPath,
    [switch] $Force,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

# the helpers below connect by name, and there is only one instance in this script
$SourceInstance = $null
$SourceSqlCredential = $null
$DestinationSqlCredential = $SqlCredential

#==============================================================================
# Logging
#==============================================================================
$script:LevelRank = @{ Quiet = 0; Normal = 1; Verbose = 2; Debug = 3 }

# -Verbose and -Debug raise the level on their own, so either way of asking works
if ($PSBoundParameters.ContainsKey('Debug') -and $script:LevelRank[$LogLevel] -lt 3) { $LogLevel = 'Debug' }
elseif ($VerbosePreference -ne 'SilentlyContinue' -and $script:LevelRank[$LogLevel] -lt 2) { $LogLevel = 'Verbose' }

$script:Level       = $script:LevelRank[$LogLevel]
$script:Messages    = New-Object System.Collections.Generic.List[string]
$script:LogFilePath = $LogFile
$script:Steps       = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = $null
$script:StepTimer   = $null
$script:StepPrefix  = ''

# identifiers and literals, quoted the long way round
function Esc-Name([string] $Name) { '[' + ($Name -replace '\]', ']]') + ']' }
function Esc-Str([string] $Text) { $Text -replace "'", "''" }

function Write-Detail { param([string]$Message) Write-Log $Message -Min Verbose }
function Write-Deep   { param([string]$Message) Write-Log $Message -Min Debug }

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
function Format-Size([double] $Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:n1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:n1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n0} MB' -f ($Bytes / 1MB)) }
    '{0:n0} KB' -f ($Bytes / 1KB)
}
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
function New-ConnectionString([string] $Server, [string] $DatabaseName, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $DatabaseName
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Restore-DatabaseCopy'
    if ($TrustServerCertificate) { $b['TrustServerCertificate'] = $true }
    $credential = $DestinationSqlCredential
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
        if (-not $index.ContainsKey($leaf) -or (ConvertTo-UtcTime $blob.LastModified) -gt (ConvertTo-UtcTime $index[$leaf].LastModified)) { $index[$leaf] = $blob }
        Write-Deep ('  blob {0} ({1})' -f $blob.Name, (Format-Size $blob.Length))
    }
    Write-Log "Found $($blobs.Count) blob(s) under '$Container/$Prefix'"
    if ($blobs.Count -eq 0) {
        Write-Log 'The container listing came back empty. If the backups sit in a folder, -BlobPrefix has to name it (a parent folder is enough when several databases share one).' -Level WARN
    }
    [pscustomobject]@{ Context = $context; Index = $index; All = @($blobs); Count = $blobs.Count }
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

#==============================================================================
# The decisions, kept free of SQL Server and Azure so -SelfTest can check them
#==============================================================================

<#
  Puts a timestamp into one known type, whatever shape it arrived in.

  Az.Storage hands back LastModified as a DateTimeOffset, SQL Server hands back a DateTime, and a
  file read off disk can give either or a string. Letting PowerShell convert between them is the
  trap: the conversion goes through the string form in the machine's own culture, so code that
  works on one regional setting throws "Cannot convert the ... value of type System.DateTimeOffset
  to type System.DateTime" on another. Everything here is normalised to a UTC DateTimeOffset on the
  way in, parsed with the invariant culture, and compared as that type only.
#>
function ConvertTo-UtcTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $Value)

    if ($null -eq $Value) { throw 'no timestamp to convert' }
    if ($Value -is [System.DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        $when = [datetime]$Value
        # an unspecified kind is treated as UTC rather than as local: blob and backup timestamps
        # are UTC, and guessing local would shift them by the server's offset
        if ($when.Kind -eq [System.DateTimeKind]::Unspecified) {
            $when = [datetime]::SpecifyKind($when, [System.DateTimeKind]::Utc)
        }
        return ([System.DateTimeOffset]$when).ToUniversalTime()
    }

    $text = ([string]$Value).Trim()
    if (-not $text) { throw 'no timestamp to convert' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($text, $invariant, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime() }

    # the shapes SQL Server, sqlcmd and the Azure libraries produce, none of them regional
    $formats = @('yyyy-MM-ddTHH:mm:ss.fffK', 'yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-dd HH:mm:ss.fff',
                 'yyyy-MM-dd HH:mm:ss', 'M/d/yyyy h:mm:ss tt zzz', 'M/d/yyyy h:mm:ss tt',
                 'd/M/yyyy HH:mm:ss zzz', 'd/M/yyyy HH:mm:ss')
    if ([System.DateTimeOffset]::TryParseExact($text, $formats, $invariant, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    throw ("cannot make a date out of '" + $text + "'")
}

<#
  One spelling for dates in the output, so a log reads the same whatever region the server is set to.

  -Utc is for values that really are UTC, such as a blob's LastModified. It is deliberately not the
  default: SQL Server records backup_finish_date in the server's own local time, and labelling that
  UTC would be a plain lie an hour wide.
#>
function Format-Stamp {
    [CmdletBinding()]
    param([AllowNull()] $Value, [string] $Format = 'dd MMM yyyy HH:mm', [switch] $Utc)

    if ($null -eq $Value) { return '(no date)' }
    try {
        $text = (ConvertTo-UtcTime $Value).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($Utc) { $text + ' UTC' } else { $text }
    }
    catch { '(unreadable date)' }
}

<#
  Where in the container a database's backups live. {db} is the database name, backslashes become
  the forward slashes blob storage actually uses, and the prefix always ends in one so that a
  folder called Sales cannot match SalesArchive as well.
#>
function Get-BlobPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Pattern, [Parameter(Mandatory)] [string] $DatabaseName)

    $prefix = $Pattern.Replace('\', '/').Replace('{db}', $DatabaseName)
    $prefix = $prefix.Trim('/')
    if ($prefix) { $prefix + '/' } else { '' }
}

<#
  Picks the backup to restore out of what the container holds.

  Newest wins, by the time the blob was last written, because there is no msdb here to ask - the
  container is the whole story. Only backup files are considered, so a folder with a log of the
  upload or a stray text file in it does not confuse matters.

  A striped backup is several files for one backup set, and taking the newest of them on its own
  would produce a restore that cannot work. Anything written within a couple of minutes of the
  chosen file is therefore returned as well, as candidate siblings; the header read later says
  whether the set really does span several files, and only then are they used.
#>
function Select-LatestBackupBlob {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Blobs,
        [string[]] $Extensions = @('.bak'),
        [int] $SiblingWindowSeconds = 120
    )

    $usable = @($Blobs | Where-Object {
        $name = ($_.Name -split '/')[-1]
        $name -and ($Extensions -contains [System.IO.Path]::GetExtension($name).ToLower())
    })
    if ($usable.Count -eq 0) { return [pscustomobject]@{ Chosen = $null; Siblings = @(); Considered = 0 } }

    # normalise every timestamp once, then only ever compare that type. Az.Storage returns a
    # DateTimeOffset and anything that coerces it to a DateTime does so through the machine's own
    # regional setting, which is how this used to fail on a server set to US dates.
    $dated = @($usable | ForEach-Object {
        [pscustomobject]@{ Blob = $_; When = (ConvertTo-UtcTime $_.LastModified) }
    })

    $newest = @($dated | Sort-Object When, { $_.Blob.Name } | Select-Object -Last 1)[0]
    $siblings = @($dated | Where-Object {
        $_.Blob.Name -ne $newest.Blob.Name -and
        [Math]::Abs(($_.When - $newest.When).TotalSeconds) -le $SiblingWindowSeconds
    } | Sort-Object { $_.Blob.Name } | ForEach-Object { $_.Blob })

    [pscustomobject]@{ Chosen = $newest.Blob; Siblings = $siblings; Considered = $usable.Count; ChosenWhen = $newest.When }
}

<#
  Works out who gets added to what.

  -AddUser takes a plain name for every database, a 'Database:User:Role' string for one of them, or
  a hashtable spelling the three out. The string form carries its weight because powershell.exe
  -File hands every argument over as a string and cannot pass a hashtable at all - and a scheduled
  task is exactly where this ends up. A colon is safe as the separator: a Windows account has a
  backslash in it, never a colon.

  Everything is flattened into one grant per database and user, with the roles merged, so the
  caller just asks what a given database needs.
#>
function Resolve-UserGrant {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Entries,
        [AllowEmptyCollection()] [string[]] $DefaultRoles,
        [Parameter(Mandatory)] [string[]] $Databases
    )

    $grants = New-Object System.Collections.Generic.List[object]
    $unknown = New-Object System.Collections.Generic.List[string]

    function Add-Grant([string] $Database, [string] $User, [string[]] $Roles) {
        $existing = @($grants | Where-Object { $_.Database -eq $Database -and $_.User -eq $User })
        if ($existing.Count) {
            foreach ($role in $Roles) { if ($existing[0].Roles -notcontains $role) { $existing[0].Roles += $role } }
            return
        }
        $grants.Add([pscustomobject]@{ Database = $Database; User = $User; Roles = @($Roles) })
    }

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $database = '*'
        $user = ''
        $roles = @()

        if ($entry -is [System.Collections.IDictionary] -or $entry -is [pscustomobject]) {
            $get = {
                param($names)
                foreach ($name in $names) {
                    if ($entry -is [System.Collections.IDictionary]) {
                        foreach ($key in $entry.Keys) { if ([string]$key -eq $name) { return $entry[$key] } }
                    }
                    else {
                        $property = $entry.PSObject.Properties[$name]
                        if ($property) { return $property.Value }
                    }
                }
                $null
            }
            $d = & $get @('Database', 'Db', 'DatabaseName')
            $u = & $get @('User', 'UserName', 'Login', 'Name')
            $r = & $get @('Role', 'Roles')
            if ($d) { $database = ([string]$d).Trim() }
            if ($u) { $user = ([string]$u).Trim() }
            if ($r) { $roles = @($r | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
            if (-not $user) { throw "an -AddUser entry does not say who to add: $($entry | Out-String)".Trim() }
        }
        else {
            $text = ([string]$entry).Trim()
            if (-not $text) { continue }
            $parts = $text.Split(':')
            if ($parts.Count -eq 1) { $user = $parts[0].Trim() }
            elseif ($parts.Count -ge 2) {
                $database = $parts[0].Trim()
                $user = $parts[1].Trim()
                if ($parts.Count -ge 3) {
                    $roles = @(($parts[2..($parts.Count - 1)] -join ':') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            }
            if (-not $user) { throw "cannot make sense of the -AddUser entry '$text': expected a name, or Database:User:Role." }
        }

        if ($roles.Count -eq 0) { $roles = @(@($DefaultRoles) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }

        if ($database -eq '*') {
            foreach ($db in $Databases) { Add-Grant $db $user $roles }
        }
        else {
            $match = @($Databases | Where-Object { $_ -eq $database })
            if ($match.Count -eq 0) { $unknown.Add(('{0} (for {1})' -f $database, $user)); continue }
            Add-Grant $match[0] $user $roles
        }
    }

    [pscustomobject]@{ Grants = $grants.ToArray(); Unknown = $unknown.ToArray() }
}

<#
  Whether a database principal is one of the built-in ones that has to stay.

  dbo, guest, INFORMATION_SCHEMA and sys are principals 1 to 4 in every database. The fixed roles
  and the certificate-backed ## principals are the instance's own business. Everything else in a
  restored copy came from the server it was taken from, and is what -KeepUsers exists to spare.
#>
function Test-SystemPrincipal {
    [CmdletBinding()]
    param([int] $PrincipalId, [AllowEmptyString()] [string] $Name, [AllowEmptyString()] [string] $Type, [bool] $IsFixedRole = $false)

    if ($PrincipalId -le 4) { return $true }
    if ($IsFixedRole) { return $true }
    if (([string]$Name).StartsWith('##')) { return $true }
    if (([string]$Type) -notin 'S', 'U', 'G', 'E', 'X') { return $true }   # roles, certificates, keys
    $false
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
    # Az.Storage returns LastModified as a DateTimeOffset, so that is what the fake blobs carry.
    # The old helper handed back a DateTime, which is how a conversion bug reached a live server.
    function Blob([string] $Name, [string] $When, [int] $Length = 1048576) {
        $utc = [datetime]::SpecifyKind([datetime]::ParseExact($When, 'yyyy-MM-dd HH:mm',
                   [System.Globalization.CultureInfo]::InvariantCulture), [System.DateTimeKind]::Utc)
        [pscustomobject]@{ Name = $Name; LastModified = [System.DateTimeOffset]$utc; Length = $Length }
    }

    Write-Host 'Restore-LatestAzureBackup self test'
    Write-Host '  where to look' -ForegroundColor Gray
    Check 'the documented layout' ((Get-BlobPrefix -Pattern 'FULL/DAILY/{db}/' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'backslashes are accepted' ((Get-BlobPrefix -Pattern 'FULL\DAILY\{db}\' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'a missing trailing slash is added' ((Get-BlobPrefix -Pattern 'FULL/DAILY/{db}' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'so Sales cannot match SalesArchive' ((Get-BlobPrefix -Pattern '{db}' -DatabaseName 'Sales') -eq 'Sales/')
    Check 'a flat container is allowed' ((Get-BlobPrefix -Pattern '/' -DatabaseName 'Sales') -eq '')
    Check 'the name goes in more than once if asked' ((Get-BlobPrefix -Pattern 'FULL/{db}/DAILY/{db}/' -DatabaseName 'Sales') -eq 'FULL/Sales/DAILY/Sales/')

    Write-Host '  which backup' -ForegroundColor Gray
    $old = Blob 'FULL/DAILY/Sales/Sales_20261011.bak' '2026-10-11 22:05'
    $mid = Blob 'FULL/DAILY/Sales/Sales_20261012.bak' '2026-10-12 22:05'
    $new = Blob 'FULL/DAILY/Sales/Sales_20261013.bak' '2026-10-13 22:05'
    $s = Select-LatestBackupBlob -Blobs @($old, $new, $mid)
    Check 'the newest one wins' ($s.Chosen.Name -eq $new.Name)
    Check 'and it says how many it looked at' ($s.Considered -eq 3)
    Check 'with nothing mistaken for a sibling' ($s.Siblings.Count -eq 0)

    $log = Blob 'FULL/DAILY/Sales/upload.log' '2026-10-14 01:00'
    $txt = Blob 'FULL/DAILY/Sales/readme.txt' '2026-10-14 02:00'
    $s = Select-LatestBackupBlob -Blobs @($mid, $new, $log, $txt)
    Check 'other files in the folder are ignored' ($s.Chosen.Name -eq $new.Name -and $s.Considered -eq 2)

    $a = Blob 'FULL/DAILY/Sales/Sales_1of2.bak' '2026-10-13 22:05'
    $b = Blob 'FULL/DAILY/Sales/Sales_2of2.bak' '2026-10-13 22:06'
    $s = Select-LatestBackupBlob -Blobs @($mid, $a, $b)
    Check 'a stripe written a minute later is a candidate sibling' ($s.Siblings.Count -eq 1)
    Check 'and the older backup is not' (($s.Siblings | ForEach-Object { $_.Name }) -notcontains $mid.Name)

    $s = Select-LatestBackupBlob -Blobs @()
    Check 'an empty folder chooses nothing' ($null -eq $s.Chosen -and $s.Considered -eq 0)
    $s = Select-LatestBackupBlob -Blobs @($log)
    Check 'a folder with no backups in it chooses nothing' ($null -eq $s.Chosen)
    $s = Select-LatestBackupBlob -Blobs @($mid, $new) -Extensions @('.trn')
    Check 'the extensions it accepts can be changed' ($null -eq $s.Chosen)

    Write-Host '  who gets added to what' -ForegroundColor Gray
    $dbs = 'Sales', 'Stock'
    $g = Resolve-UserGrant -Entries @('BiTeam') -DefaultRoles @('db_datareader') -Databases $dbs
    Check 'a bare name goes into every database' ($g.Grants.Count -eq 2 -and ($g.Grants | ForEach-Object { $_.Database }) -contains 'Stock')
    Check 'and picks up the default role' ($g.Grants[0].Roles -contains 'db_datareader')

    $g = Resolve-UserGrant -Entries @('Sales:BiTeam') -DefaultRoles @('db_datareader') -Databases $dbs
    Check 'Database:User goes into that one only' ($g.Grants.Count -eq 1 -and $g.Grants[0].Database -eq 'Sales')
    Check 'and still takes the default role' ($g.Grants[0].Roles -contains 'db_datareader')

    $g = Resolve-UserGrant -Entries @('Sales:BiTeam:db_owner') -DefaultRoles @('db_datareader') -Databases $dbs
    Check 'a named role beats the default' ($g.Grants[0].Roles.Count -eq 1 -and $g.Grants[0].Roles[0] -eq 'db_owner')

    $g = Resolve-UserGrant -Entries @('Sales:BiTeam:db_datareader,db_datawriter') -Databases $dbs
    Check 'roles can be comma separated in the string form' ($g.Grants[0].Roles.Count -eq 2)

    $g = Resolve-UserGrant -Entries @('*:BiTeam:db_owner') -Databases $dbs
    Check 'a star means every database' ($g.Grants.Count -eq 2)

    $g = Resolve-UserGrant -Entries @('CONTOSO\\jo') -Databases $dbs
    Check 'a Windows account with a backslash is not mangled' ($g.Grants[0].User -eq 'CONTOSO\\jo')
    $g = Resolve-UserGrant -Entries @('Sales:CONTOSO\\jo:db_datareader') -Databases $dbs
    Check 'and works in the string form too' ($g.Grants.Count -eq 1 -and $g.Grants[0].User -eq 'CONTOSO\\jo')

    $g = Resolve-UserGrant -Entries @(@{ Database = 'Stock'; User = 'AppSvc'; Role = 'db_datawriter', 'db_datareader' }) -Databases $dbs
    Check 'a hashtable entry works' ($g.Grants.Count -eq 1 -and $g.Grants[0].Database -eq 'Stock' -and $g.Grants[0].Roles.Count -eq 2)
    $g = Resolve-UserGrant -Entries @([pscustomobject]@{ DatabaseName = 'Sales'; Login = 'AppSvc'; Roles = 'db_owner' }) -Databases $dbs
    Check 'and the other spellings of its keys' ($g.Grants.Count -eq 1 -and $g.Grants[0].User -eq 'AppSvc')
    $g = Resolve-UserGrant -Entries @(@{ User = 'AppSvc' }) -DefaultRoles @('db_datareader') -Databases $dbs
    Check 'a hashtable with no database means all of them' ($g.Grants.Count -eq 2)

    $g = Resolve-UserGrant -Entries @('Sales:BiTeam:db_datareader', 'BiTeam') -DefaultRoles @('db_datawriter') -Databases $dbs
    Check 'the same user twice is merged, not duplicated' (@($g.Grants | Where-Object { $_.Database -eq 'Sales' }).Count -eq 1)
    Check 'and its roles are merged' ((@($g.Grants | Where-Object { $_.Database -eq 'Sales' })[0].Roles | Sort-Object) -join ',' -eq 'db_datareader,db_datawriter')

    $g = Resolve-UserGrant -Entries @('Sale:BiTeam') -Databases $dbs
    Check 'a database that is not being restored is reported, not ignored' ($g.Grants.Count -eq 0 -and $g.Unknown.Count -eq 1)
    Check 'and the report says which user it was for' ($g.Unknown[0] -match 'BiTeam')

    $g = Resolve-UserGrant -Entries @('BiTeam') -Databases $dbs
    Check 'no default role leaves the roles empty rather than inventing one' (@($g.Grants[0].Roles).Count -eq 0)
    $g = Resolve-UserGrant -Entries @() -Databases $dbs
    Check 'nothing asked for is nothing granted' ($g.Grants.Count -eq 0)
    $threw = $false
    try { Resolve-UserGrant -Entries @('Sales:') -Databases $dbs | Out-Null } catch { $threw = $true }
    Check 'an entry with no user is refused' $threw

    Write-Host '  dates, whatever the region' -ForegroundColor Gray
    $offset = [System.DateTimeOffset]::new(2026, 10, 13, 10, 56, 59, [TimeSpan]::Zero)
    Check 'a DateTimeOffset comes back as itself' ((ConvertTo-UtcTime $offset) -eq $offset)
    $plain = [datetime]::SpecifyKind([datetime]::new(2026, 10, 13, 10, 56, 59), [System.DateTimeKind]::Utc)
    Check 'a DateTime is taken as UTC, not shifted' ((ConvertTo-UtcTime $plain).UtcDateTime -eq $plain)
    $unspecified = [datetime]::new(2026, 10, 13, 10, 56, 59)
    Check 'an unspecified kind is not shifted either' ((ConvertTo-UtcTime $unspecified).Hour -eq 10)
    Check 'the US string from the failing server reads correctly' ((ConvertTo-UtcTime '9/13/2026 10:56:59 AM +00:00').ToString('yyyy-MM-dd HH:mm:ss') -eq '2026-09-13 10:56:59')
    Check 'an ISO string reads correctly' ((ConvertTo-UtcTime '2026-10-13T10:56:59').ToString('yyyy-MM-dd HH:mm') -eq '2026-10-13 10:56')
    Check 'a SQL style string reads correctly' ((ConvertTo-UtcTime '2026-10-13 10:56:59.123').ToString('yyyy-MM-dd HH:mm') -eq '2026-10-13 10:56')
    $threw = $false
    try { ConvertTo-UtcTime 'not a date at all' | Out-Null } catch { $threw = $true }
    Check 'nonsense is refused rather than guessed at' $threw
    Check 'output is spelled the same way whatever the region' ((Format-Stamp $offset) -eq '13 Oct 2026 10:56')
    Check 'and says UTC only where that is true' ((Format-Stamp $offset -Utc) -eq '13 Oct 2026 10:56 UTC')

    # the real test: do it all again with the machine pretending to be somewhere else
    $was = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in 'en-US', 'de-DE', 'en-GB') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($culture)
            $old = Blob 'FULL/DAILY/Sales/old.bak' '2026-10-11 22:05'
            $mid = Blob 'FULL/DAILY/Sales/mid.bak' '2026-10-12 22:05'
            $new = Blob 'FULL/DAILY/Sales/new.bak' '2026-10-13 22:05'
            $pick = Select-LatestBackupBlob -Blobs @($old, $new, $mid)
            Check ("under $culture the newest is still picked") ($pick.Chosen.Name -eq $new.Name)
            Check ("under $culture days apart are not mistaken for stripes") ($pick.Siblings.Count -eq 0)

            $stripe = Blob 'FULL/DAILY/Sales/new_stripe.bak' '2026-10-13 22:06'
            $pick = Select-LatestBackupBlob -Blobs @($mid, $new, $stripe)
            Check ("under $culture a minute apart is a candidate stripe") ($pick.Siblings.Count -eq 1 -and $pick.Siblings[0].Name -eq $new.Name)
            Check ("under $culture the date still reads the same") ((Format-Stamp $new.LastModified -Utc) -eq '13 Oct 2026 22:05 UTC')
            Check ("under $culture a US string still converts") ((ConvertTo-UtcTime '9/13/2026 10:56:59 AM +00:00').Month -eq 9)
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $was }

    Write-Host '  which users stay' -ForegroundColor Gray
    Check 'dbo stays' (Test-SystemPrincipal -PrincipalId 1 -Name 'dbo' -Type 'S')
    Check 'guest stays' (Test-SystemPrincipal -PrincipalId 2 -Name 'guest' -Type 'S')
    Check 'INFORMATION_SCHEMA stays' (Test-SystemPrincipal -PrincipalId 3 -Name 'INFORMATION_SCHEMA' -Type 'S')
    Check 'sys stays' (Test-SystemPrincipal -PrincipalId 4 -Name 'sys' -Type 'S')
    Check 'a fixed role stays' (Test-SystemPrincipal -PrincipalId 16384 -Name 'db_owner' -Type 'R' -IsFixedRole $true)
    Check 'a certificate-backed principal stays' (Test-SystemPrincipal -PrincipalId 5 -Name '##MS_PolicyEventProcessingLogin##' -Type 'S')
    Check 'a custom role is not a user, so it stays' (Test-SystemPrincipal -PrincipalId 20 -Name 'ReportReaders' -Type 'R')
    Check 'a SQL user goes' (-not (Test-SystemPrincipal -PrincipalId 5 -Name 'appuser' -Type 'S'))
    Check 'a Windows user goes' (-not (Test-SystemPrincipal -PrincipalId 6 -Name 'CONTOSO\jo' -Type 'U'))
    Check 'a Windows group goes' (-not (Test-SystemPrincipal -PrincipalId 7 -Name 'CONTOSO\Reporting' -Type 'G'))
    Check 'an Entra user goes' (-not (Test-SystemPrincipal -PrincipalId 8 -Name 'jo@contoso.com' -Type 'E'))

    Write-Host '  sizes' -ForegroundColor Gray
    Check 'gigabytes' ((Format-Size 3221225472) -eq '3.0 GB')
    Check 'megabytes' ((Format-Size 5242880) -eq '5 MB')

    Write-Host '  explaining failures' -ForegroundColor Gray
    $e = Get-SqlErrorExplanation -Number 3201 -Message 'Cannot open backup device'
    Check 'a backup device error points at the service account' ($e.Fix -match 'SERVICE ACCOUNT')
    $e = Get-SqlErrorExplanation -Number 18456 -Message "Login failed for user 'sa'. State: 8"
    Check 'a refused login is explained' ($e.Meaning -match '18456')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Tidying a restored copy
#==============================================================================

<#
  Drops every user the copy brought with it from the server it came off, keeping the built-in ones.

  Schema ownership is handed to dbo first, because a user that owns a schema cannot be dropped and
  that is the usual reason this fails. Role ownership is moved the same way. Anything that still
  refuses comes back with the reason, so it can be dealt with rather than quietly left behind.
#>
function Clear-DatabaseUser {
    [CmdletBinding()]
    param([string] $Server, [string] $DatabaseName)

    $sql = @'
SET NOCOUNT ON;
DECLARE @outcome TABLE (UserName sysname, Result varchar(10), Detail nvarchar(400));
DECLARE @name sysname, @sql nvarchar(max);

DECLARE @doomed TABLE (PrincipalId int PRIMARY KEY, UserName sysname);
INSERT @doomed (PrincipalId, UserName)
SELECT dp.principal_id, dp.name
FROM sys.database_principals AS dp
WHERE dp.type IN ('S', 'U', 'G', 'E', 'X')
  AND dp.principal_id > 4                  -- dbo, guest, INFORMATION_SCHEMA and sys are 1 to 4
  AND dp.is_fixed_role = 0
  AND dp.name NOT LIKE '##%';              -- certificate-backed, the instance's own

-- a user owning a schema or a role cannot be dropped, so hand those to dbo first
DECLARE @owned TABLE (Kind varchar(10), ObjectName sysname, UserName sysname);
INSERT @owned (Kind, ObjectName, UserName)
SELECT 'schema', s.name, d.UserName
FROM sys.schemas AS s JOIN @doomed AS d ON d.PrincipalId = s.principal_id;
INSERT @owned (Kind, ObjectName, UserName)
SELECT 'role', r.name, d.UserName
FROM sys.database_principals AS r JOIN @doomed AS d ON d.PrincipalId = r.owning_principal_id
WHERE r.type = 'R' AND r.is_fixed_role = 0;

DECLARE @kind varchar(10), @object sysname;
DECLARE handover CURSOR LOCAL FAST_FORWARD FOR SELECT Kind, ObjectName, UserName FROM @owned;
OPEN handover;
FETCH NEXT FROM handover INTO @kind, @object, @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF @kind = 'schema' SET @sql = N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(@object) + N' TO [dbo];';
        ELSE                SET @sql = N'ALTER AUTHORIZATION ON ROLE::' + QUOTENAME(@object) + N' TO [dbo];';
        EXEC sys.sp_executesql @sql;
        INSERT @outcome (UserName, Result, Detail)
        VALUES (@name, 'handover', @kind + N' ' + @object + N' now belongs to dbo');
    END TRY
    BEGIN CATCH
        INSERT @outcome (UserName, Result, Detail)
        VALUES (@name, 'kept', N'could not hand over ' + @kind + N' ' + @object + N': ' + ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM handover INTO @kind, @object, @name;
END
CLOSE handover;
DEALLOCATE handover;

DECLARE doomed CURSOR LOCAL FAST_FORWARD FOR SELECT UserName FROM @doomed ORDER BY UserName;
OPEN doomed;
FETCH NEXT FROM doomed INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'DROP USER ' + QUOTENAME(@name) + N';';
        EXEC sys.sp_executesql @sql;
        INSERT @outcome (UserName, Result, Detail) VALUES (@name, 'dropped', NULL);
    END TRY
    BEGIN CATCH
        INSERT @outcome (UserName, Result, Detail) VALUES (@name, 'kept', ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM doomed INTO @name;
END
CLOSE doomed;
DEALLOCATE doomed;

SELECT UserName, Result, Detail FROM @outcome ORDER BY Result, UserName;
'@
    $rows = Invoke-Sql -Server $Server -Query $sql -DatabaseName $DatabaseName
    [pscustomobject]@{
        Dropped  = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'dropped' } | ForEach-Object { [string]$_['UserName'] })
        Handover = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'handover' } | ForEach-Object { [string]$_['Detail'] })
        Kept     = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'kept' } | ForEach-Object { '{0}: {1}' -f $_['UserName'], $_['Detail'] })
    }
}

<#
  Creates the users asked for, mapped to logins of the same name.

  The login is expected to exist already - this is a restored copy being handed to people who can
  already get at the instance - so a missing one is reported and skipped rather than invented,
  because a user with no login behind it looks fine and then nobody can log in.
#>
function Add-DatabaseUser {
    [CmdletBinding()]
    param([string] $Server, [string] $DatabaseName, [AllowEmptyCollection()] [object[]] $Grants)

    $created = New-Object System.Collections.Generic.List[string]
    $noLogin = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($grant in @($Grants)) {
        $name = ([string]$grant.User).Trim()
        if (-not $name) { continue }
        $login = Get-Scalar -Server $Server -Parameters @{ '@n' = $name } -Query `
                 "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G','E','X')"
        if (-not $login) { $noLogin.Add($name); continue }
        try {
            $statement = 'IF DATABASE_PRINCIPAL_ID(N''' + ($name -replace "'", "''") + ''') IS NULL CREATE USER ' + (Esc-Name $name) + ' FOR LOGIN ' + (Esc-Name $name) + ';'
            [void](Invoke-Sql -Server $Server -Query $statement -DatabaseName $DatabaseName)
            foreach ($role in @($grant.Roles)) {
                $r = ([string]$role).Trim()
                if (-not $r) { continue }
                [void](Invoke-Sql -Server $Server -DatabaseName $DatabaseName -Query `
                       ('ALTER ROLE ' + (Esc-Name $r) + ' ADD MEMBER ' + (Esc-Name $name) + ';'))
            }
            $created.Add($(if (@($grant.Roles).Count) { '{0} in {1}' -f $name, (@($grant.Roles) -join ', ') } else { $name }))
        }
        catch { $failed.Add(('{0}: {1}' -f $name, ($_.Exception.GetBaseException().Message -split "`r?`n")[0])) }
    }
    [pscustomobject]@{ Created = $created.ToArray(); NoLogin = $noLogin.ToArray(); Failed = $failed.ToArray() }
}

# the real system administrator is principal 1 whatever it has been renamed to
function Resolve-OwnerLogin {
    [CmdletBinding()]
    param([string] $Server, [string] $Wanted)

    $exact = Get-Scalar -Server $Server -Parameters @{ '@n' = $Wanted } -Query `
             "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G')"
    if ($exact) { return [pscustomobject]@{ Login = [string]$exact; Substituted = $false } }

    $sa = Get-Scalar -Server $Server -Query 'SELECT name FROM sys.server_principals WHERE principal_id = 1'
    if ($sa) { return [pscustomobject]@{ Login = [string]$sa; Substituted = $true } }
    [pscustomobject]@{ Login = $null; Substituted = $false }
}

#==============================================================================
# Getting started
#==============================================================================
if (-not $DestinationInstance) {
    Write-Host '  -DestinationInstance is needed.' -ForegroundColor Red
    Write-Host '  Try: Get-Help .\Restore-LatestAzureBackup.ps1 -Detailed' -ForegroundColor Gray
    exit 2
}
# powershell.exe -File hands every argument over as a string, so -Database Sales,Stock arrives as
# one element rather than two
$named = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($named.Count -eq 1 -and $named[0] -match ',') { $named = @($named[0] -split ',') }
$databases = @($named | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($databases.Count -eq 0) {
    Write-Host '  -Database is needed (one name, or several).' -ForegroundColor Red
    exit 2
}
foreach ($required in 'StorageAccountName', 'ContainerName', 'LocalBackupPath') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        Write-Host "  -$required is needed." -ForegroundColor Red
        exit 2
    }
}
if ($null -eq $SasToken) { Write-Host '  -SasToken is needed.' -ForegroundColor Red; exit 2 }
if ($AddUserRole -and -not $AddUser) {
    Write-Host '  -AddUserRole only means something with -AddUser.' -ForegroundColor Red
    exit 2
}

# worked out now rather than per database: naming a database that is not being restored is a typo,
# and finding out after the restores would mean a user silently missing from a copy already handed over
$userGrants = @()
if ($AddUser) {
    try { $resolved = Resolve-UserGrant -Entries $AddUser -DefaultRoles $AddUserRole -Databases $databases }
    catch {
        Write-Host ('  ' + ($_.Exception.Message -split "`r?`n")[0]) -ForegroundColor Red
        exit 2
    }
    if ($resolved.Unknown.Count) {
        Write-Host ('  -AddUser names database(s) that are not in -Database: ' + ($resolved.Unknown -join '; ')) -ForegroundColor Red
        Write-Host ('  the databases being restored are: ' + ($databases -join ', ')) -ForegroundColor Gray
        exit 2
    }
    $userGrants = $resolved.Grants
}

$DestinationInstance = $DestinationInstance.Trim()
$dryRun = $WhatIfPreference -eq $true

$script:Blobs = $null
$runStart = Get-Date
$setupDone = $false
$results = New-Object System.Collections.Generic.List[object]
$restoredOk = New-Object System.Collections.Generic.List[object]

try {
    Write-Log ("Restore {0} database(s) onto {1} from {2}/{3}" -f $databases.Count, $DestinationInstance, $StorageAccountName, $ContainerName)
    Write-Log ('Databases: ' + ($databases -join ', '))
    Write-Detail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName) on $env:COMPUTERNAME; log level $LogLevel"
    if ($dryRun) { Write-Log 'WhatIf mode: the statements below are printed, not run' -Level WARN }

    #region The destination
    Start-Step 'Check the destination'
    $check = Test-SqlConnectivity -Instance $DestinationInstance -Credential $SqlCredential `
                                  -Trust:$TrustServerCertificate -TimeoutSeconds $ConnectTimeoutSeconds
    Write-ConnectivityReport -Result $check -Role 'destination'
    if (-not $check.Connected) {
        throw ("Cannot connect to $DestinationInstance. The checks above say why; -LogLevel Verbose shows every step and Debug the raw errors.")
    }

    $dstInfo = (Invoke-Sql -Server $DestinationInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), DataPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), LogPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath'))").Rows[0]
    $defaultData = [string]$dstInfo['DataPath']
    $defaultLog = [string]$dstInfo['LogPath']
    if (-not $defaultData -or -not $defaultLog) {
        $mf = Invoke-Sql -Server $DestinationInstance -Query "SELECT Type = type_desc, Path = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name))) FROM sys.master_files WHERE database_id = 1"
        foreach ($r in $mf.Rows) {
            if (-not $defaultData -and [string]$r['Type'] -eq 'ROWS') { $defaultData = [string]$r['Path'] }
            if (-not $defaultLog -and [string]$r['Type'] -eq 'LOG') { $defaultLog = [string]$r['Path'] }
        }
    }
    if ($DataPath) { $defaultData = $DataPath }
    if ($LogPath) { $defaultLog = $LogPath }
    Write-Detail ('  restored files go to {0}{1}' -f $defaultData, $(if ($defaultLog -ne $defaultData) { " and $defaultLog" } else { '' }))

    # the owner is wanted on every copy, so settle it once and say so now rather than per database
    $ownerLogin = Resolve-OwnerLogin -Server $DestinationInstance -Wanted $Owner
    if (-not $ownerLogin.Login) {
        Write-Log ("There is no login called '{0}' on {1} and no principal 1 either, so the owner will be left as restored." -f $Owner, $DestinationInstance) -Level WARN
    }
    elseif ($ownerLogin.Substituted) {
        Write-Log ("There is no login called '{0}', so the system administrator login '{1}' will be used instead." -f $Owner, $ownerLogin.Login) -Level WARN
    }
    Complete-Step
    #endregion

    #region The container
    Start-Step 'Open the storage container'
    $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
    if ($found.Count -eq 0) {
        if (-not $InstallMissingModules) {
            Write-Deep ('module search path: ' + ($env:PSModulePath -split ';' -join ' | '))
            throw ("The Az.Storage module is not installed for $($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion). " +
                   'Re-run with -InstallMissingModules, or: Install-Module Az.Storage -Scope CurrentUser. ' +
                   'Modules installed for Windows PowerShell 5.1 are not visible to PowerShell 7, or the other way round, so check which one you are in.')
        }
        Write-Log 'Installing Az.Storage for the current user'
        Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
        $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
    }
    Write-Detail ('  Az.Storage {0} from {1}' -f $found[0].Version, $found[0].ModuleBase)
    # Import-Module has no -WhatIf of its own, but the preference reaches inside the module
    $savedWhatIf = $WhatIfPreference
    try { $WhatIfPreference = $false; Import-Module -Name Az.Storage -Verbose:$false }
    finally { $WhatIfPreference = $savedWhatIf }

    $script:Blobs = Connect-BlobContainer -AccountName $StorageAccountName -Container $ContainerName `
                                          -Prefix '' -Sas $SasToken

    if (-not (Test-Path -LiteralPath $LocalBackupPath)) {
        Write-Detail "  creating $LocalBackupPath"
        New-Item -ItemType Directory -Path $LocalBackupPath -WhatIf:$false | Out-Null
    }
    if ($LocalBackupPath -match '^[A-Za-z]:\\Users\\') {
        Write-Log 'The staging folder is inside a user profile. The SQL Server service account usually cannot read there, which fails the header check - a folder on one of the server''s own drives is safer.' -Level WARN
    }
    Complete-Step
    #endregion

    $setupDone = $true
    $allBlobs = @($script:Blobs.All)

    #==========================================================================
    # Restore each database. A failure on one is recorded and the rest carry on.
    #==========================================================================
    foreach ($dbName in $databases) {
        $script:StepPrefix = if ($databases.Count -gt 1) { $dbName } else { '' }
        $outcome = [pscustomobject]@{
            Database = $dbName; DestinationInstance = $DestinationInstance; Result = 'FAILED'
            Backup = $null; BackupTaken = $null; Bytes = 0; Users = $null; Detail = $null
        }
        $staged = New-Object System.Collections.Generic.List[string]
        $restored = $false

        try {
            Write-Log ('---- {0} ----' -f $dbName)

            #region Find it
            Start-Step 'Find the newest backup in the container'
            $prefix = Get-BlobPrefix -Pattern $BlobPathPattern -DatabaseName $dbName
            Write-Detail ("  looking under {0}/{1}" -f $ContainerName, $prefix)
            $inFolder = @($allBlobs | Where-Object { ([string]$_.Name).Replace('\', '/').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
            foreach ($b in $inFolder) { Write-Deep ('  {0} ({1}, {2})' -f $b.Name, (Format-Size $b.Length), (Format-Stamp $b.LastModified -Utc)) }

            $pick = Select-LatestBackupBlob -Blobs $inFolder
            if (-not $pick.Chosen) {
                throw ("Nothing to restore: no .bak under {0}/{1} ({2} blob(s) in that folder altogether). Check -BlobPathPattern and the database name." -f
                       $ContainerName, $prefix, $inFolder.Count)
            }
            $blob = $pick.Chosen
            Write-Log ('Newest backup: {0} ({1}, written {2})' -f $blob.Name, (Format-Size $blob.Length), (Format-Stamp $blob.LastModified -Utc))
            $outcome.Backup = $blob.Name
            if ($pick.Siblings.Count) {
                Write-Detail ('  {0} other file(s) written within two minutes of it, which may be stripes of the same backup' -f $pick.Siblings.Count)
            }
            Complete-Step
            #endregion

            #region Download it
            Start-Step 'Download the backup'
            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($LocalBackupPath))
            if (-not $root.StartsWith('\\')) {
                $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
                Write-Detail ('  {0} has {1} free; the backup is {2}' -f $root, (Format-Size $freeBytes), (Format-Size $blob.Length))
                if ($freeBytes -lt ($blob.Length * 1.05)) {
                    throw ('Not enough free space on {0}: need about {1}, have {2}' -f $root, (Format-Size ($blob.Length * 1.05)), (Format-Size $freeBytes))
                }
            }
            $localFiles = @()
            if ($PSCmdlet.ShouldProcess($blob.Name, "Download to $LocalBackupPath")) {
                $target = Join-Path -Path $LocalBackupPath -ChildPath (($blob.Name -split '/')[-1])
                $outcome.Bytes = Get-BlobToFile -Context $script:Blobs.Context -Container $ContainerName -Blob $blob -TargetPath $target
                $staged.Add($target)
                $localFiles = @($target)
            }
            Complete-Step -Result $(if ($localFiles.Count) { 'OK' } else { 'SKIPPED' })
            #endregion

            if ($dryRun) {
                Write-Log ('Would restore {0} over {1}.[{2}], then clear its users, set the owner and the recovery model{3}' -f
                           $blob.Name, $DestinationInstance, $dbName, $(if ($ReadOnly) { ', and make it read-only' } else { '' }))
                $outcome.Result = 'DRY RUN'
                continue
            }

            #region Prove it is what it says
            Start-Step 'Read the backup header'
            # before the existing database is touched: an unreadable staging folder or the wrong
            # file shows up here, while nothing is broken yet
            $deviceList = (@($localFiles) | ForEach-Object { "DISK = N'" + (Esc-Str $_) + "'" }) -join ', '
            try { $header = Invoke-Sql -Server $DestinationInstance -Query "RESTORE HEADERONLY FROM $deviceList" }
            catch {
                $exception = $_.Exception.GetBaseException()
                $number = 0
                if ($exception -is [System.Data.SqlClient.SqlException]) { $number = $exception.Number }
                if ($exception.Message -match 'Operating system error 5|Cannot open backup device') { $number = 3201 }
                $explain = Get-SqlErrorExplanation -Number $number -Message $exception.Message
                Write-Deep ('  header exception: ' + $exception.ToString())
                throw ('Could not read the backup header: ' + ($exception.Message -split "`r?`n")[0] + $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
            }
            $row = $header.Rows[0]
            $backupType = [int]$row['BackupType']
            $families = [int]$row['FamilyCount']
            $inside = [string]$row['DatabaseName']
            $taken = ConvertTo-UtcTime $row['BackupFinishDate']
            $outcome.BackupTaken = $taken
            Write-Log ('The file holds a {0} backup of [{1}], finished {2}, from SQL Server major version {3}' -f
                       $(switch ($backupType) { 1 { 'full' } 2 { 'transaction log' } 5 { 'differential' } default { "type $backupType" } }),
                       $inside, (Format-Stamp $taken), $row['SoftwareVersionMajor'])

            if ($backupType -ne 1) {
                throw ("that is not a full backup, so it cannot be restored on its own. The newest file under {0} is a {1}." -f
                       $prefix, $(switch ($backupType) { 2 { 'transaction log backup' } 5 { 'differential backup' } default { "backup of type $backupType" } }))
            }
            if ($families -gt 1) {
                throw ("that backup was written across {0} files (a striped backup) and only one of them is here. All {0} have to be restored together: name them in the container so they can be told apart, or take the backup to a single file." -f $families)
            }
            if ($inside -ne $dbName) {
                Write-Log ("The backup is of [{0}] but it was found in the folder for [{1}] and will be restored as [{1}]. Check the container layout if that is not intended." -f $inside, $dbName) -Level WARN
            }
            if ([int]$row['SoftwareVersionMajor'] -gt [int]$dstInfo['Major']) {
                throw ('the backup was taken on SQL Server major version {0} and {1} is version {2}: a backup cannot be restored onto an older version' -f
                       $row['SoftwareVersionMajor'], $DestinationInstance, $dstInfo['Major'])
            }
            Complete-Step
            #endregion

            #region Restore it
            Start-Step 'Restore it'
            $existing = Invoke-Sql -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                        'SELECT state_desc, user_access_desc, is_read_only FROM sys.databases WHERE name = @db'
            $isThere = $existing.Rows.Count -gt 0
            if ($isThere) {
                $wasReadOnly = [bool]$existing.Rows[0]['is_read_only']
                Write-Detail ('  the existing copy is {0}{1}' -f ([string]$existing.Rows[0]['state_desc']).ToLower(), $(if ($wasReadOnly) { ', read-only' } else { '' }))

                $restoredHere = Get-Scalar -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                                'SELECT TOP (1) 1 FROM msdb.dbo.restorehistory WHERE destination_database_name = @db'
                if (-not $restoredHere -and -not $Force) {
                    throw ("{0} already exists on {1} and this instance has no record of restoring it, so it has not been touched. Check the name, or use -Force to overwrite it anyway." -f $dbName, $DestinationInstance)
                }
                Write-Log "Taking $dbName offline (rolling back open transactions)"
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET OFFLINE WITH ROLLBACK IMMEDIATE;' -f (Esc-Name $dbName)))
            }
            else { Write-Detail '  nothing of that name on the destination yet' }

            # where its files should land
            $fileList = Invoke-Sql -Server $DestinationInstance -Query ("RESTORE FILELISTONLY FROM $deviceList")
            $moveList = @{}
            foreach ($f in $fileList.Rows) {
                $moveList[[string]$f['LogicalName']] = Get-MoveTarget -PhysicalName ([string]$f['PhysicalName']) -FileType ([string]$f['Type']) `
                                                        -DataPath $defaultData -LogPath $defaultLog -SourceDatabase $inside -DestinationDatabase $dbName
            }
            foreach ($file in $moveList.Values) {
                $owner = Get-Scalar -Server $DestinationInstance -Parameters @{ '@p' = $file } -Query `
                         'SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p'
                if ($owner -and [string]$owner -ne $dbName) {
                    throw ("the file {0} already belongs to the database {1} on {2}. Use -DataPath / -LogPath to put the copy somewhere else." -f $file, $owner, $DestinationInstance)
                }
            }
            Write-Detail ('  {0} file(s) to {1}' -f $moveList.Count, $defaultData)

            $set = [pscustomobject]@{ Position = [int]$row['Position']; Files = $localFiles; HasChecksums = $true }
            $sql = New-RestoreCommand -Database $dbName -BackupSet $set -Kind 'Database' -Finish 'RECOVERY' `
                       -MoveList $moveList -Replace:$isThere
            $r = Invoke-LongRunningSql -Server $DestinationInstance -Sql $sql -Label 'restore'
            if (-not $r.Ok) {
                if ($isThere) {
                    Write-Log "The restore failed; putting $dbName back online" -Level WARN
                    try { [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET ONLINE;' -f (Esc-Name $dbName))) }
                    catch { Write-Log ('  could not bring it back online: ' + $_.Exception.Message) -Level ERROR }
                }
                throw ('the restore failed: ' + $r.Error)
            }
            $restored = $true
            $size = if ($r.Megabytes) { ', ' + (Format-Size ($r.Megabytes * 1MB)) } else { '' }
            Write-Log ('Restored in {0}s{1}' -f $r.Seconds, $size)

            # a copy of a database that was closed off comes back closed off
            $after = (Invoke-Sql -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                      'SELECT state_desc, user_access_desc, is_read_only FROM sys.databases WHERE name = @db').Rows[0]
            if ([string]$after['state_desc'] -ne 'ONLINE') { throw ('the restore finished but the database is {0} rather than online' -f $after['state_desc']) }
            if ([bool]$after['is_read_only']) {
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET READ_WRITE;' -f (Esc-Name $dbName)))
                Write-Detail '  the backup was taken read-only, so the copy has been set read-write for the tidying up'
            }
            if ([string]$after['user_access_desc'] -ne 'MULTI_USER') {
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-Name $dbName)))
                Write-Detail ('  the backup was taken {0}, so the copy has been opened up to MULTI_USER' -f ([string]$after['user_access_desc']).ToLower())
            }
            Complete-Step
            #endregion

            if (-not $KeepLocalCopy -and $staged.Count) {
                Start-Step 'Remove the staged copy'
                foreach ($file in $staged) {
                    Write-Detail "  removing $file"
                    try { Remove-Item -LiteralPath $file -Force } catch { Write-Log ('  could not remove ' + $file + ': ' + $_.Exception.Message) -Level WARN }
                }
                Complete-Step
            }
            $outcome.Result = 'RESTORED'
            $restoredOk.Add($dbName)
        }
        catch {
            if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
            $exception = $_.Exception.GetBaseException()
            $outcome.Result = 'FAILED'
            $outcome.Detail = ($exception.Message -split "`r?`n")[0]
            Write-Log ('[{0}] {1}' -f $dbName, $outcome.Detail) -Level ERROR
            if ($exception -is [System.Data.SqlClient.SqlException]) {
                $explain = Get-SqlErrorExplanation -Number $exception.Number -Message $exception.Message
                if ($explain.Meaning) { Write-Log ('  what it means: ' + $explain.Meaning) -Level ERROR }
                if ($explain.Fix) { Write-Log ('  what to try: ' + $explain.Fix) -Level WARN }
            }
            Write-Deep ('full exception: ' + $exception.ToString())
            if ($_.ScriptStackTrace) { Write-Deep ('at: ' + $_.ScriptStackTrace) }
            if ($staged.Count -and -not $restored) { Write-Log ('  the staged file has been left in {0} for investigation' -f $LocalBackupPath) -Level WARN }
            if ($databases.Count -gt 1) { Write-Log '  carrying on with the remaining database(s)' -Level WARN }
        }
        finally {
            $script:StepPrefix = ''
            $results.Add($outcome)
        }
    }

    #==========================================================================
    # With all the databases copied, tidy them up
    #==========================================================================
    if ($restoredOk.Count -and -not $dryRun) {
        Write-Log ('---- tidying up {0} restored database(s) ----' -f $restoredOk.Count)
        foreach ($dbName in $restoredOk) {
            $script:StepPrefix = if ($restoredOk.Count -gt 1) { $dbName } else { '' }
            $outcome = @($results | Where-Object { $_.Database -eq $dbName })[0]
            try {
                if (-not $KeepUsers) {
                    Start-Step 'Clear out the users it came with'
                    $users = Clear-DatabaseUser -Server $DestinationInstance -DatabaseName $dbName
                    foreach ($moved in $users.Handover) { Write-Detail ('  ' + $moved) }
                    if ($users.Dropped.Count) { Write-Log ('Dropped {0} user(s): {1}' -f $users.Dropped.Count, ($users.Dropped -join ', ')) }
                    else { Write-Log 'No users to drop; only the built-in ones were there' }
                    foreach ($kept in $users.Kept) { Write-Log ('Could not drop ' + $kept) -Level WARN }
                    $outcome.Users = '{0} dropped' -f $users.Dropped.Count
                    Complete-Step
                }

                if ($ownerLogin.Login) {
                    Start-Step ("Set the owner to {0}" -f $ownerLogin.Login)
                    Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dbName `
                        -Statement ('ALTER AUTHORIZATION ON DATABASE::{DB} TO ' + (Esc-Name $ownerLogin.Login) + ';')
                    Complete-Step
                }

                Start-Step ("Set the recovery model to $RecoveryModel")
                Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dbName `
                    -Statement ("ALTER DATABASE {DB} SET RECOVERY $RecoveryModel;")
                Complete-Step

                $mine = @($userGrants | Where-Object { $_.Database -eq $dbName })
                if ($mine.Count) {
                    Start-Step 'Add the users asked for'
                    $added = Add-DatabaseUser -Server $DestinationInstance -DatabaseName $dbName -Grants $mine
                    if ($added.Created.Count) {
                        $roleless = @($mine | Where-Object { @($_.Roles).Count -eq 0 })
                        Write-Log ('Added ' + ($added.Created -join '; ') +
                                   $(if ($roleless.Count) { ' - no role membership, so no permissions yet' } else { '' }))
                    }
                    foreach ($missing in $added.NoLogin) {
                        Write-Log ("There is no login called '{0}' on {1}, so no user was created for it. Create the login first, then run this again." -f $missing, $DestinationInstance) -Level WARN
                    }
                    foreach ($failure in $added.Failed) { Write-Log ('Could not add ' + $failure) -Level WARN }
                    Complete-Step
                }
                elseif ($userGrants.Count) { Write-Detail '  no users asked for on this one' }

                # last, because a read-only database cannot be changed any further
                if ($ReadOnly) {
                    Start-Step 'Set it read-only'
                    # AUTO_CLOSE undoes this: a database that closes and reopens comes back
                    # read-write, so the setting looks applied and then quietly is not. Turning
                    # AUTO_CLOSE off is the only way to make read-only mean anything, and it is
                    # not something a restored copy on a server wants switched on in any case.
                    $autoClose = Get-Scalar -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                                 'SELECT is_auto_close_on FROM sys.databases WHERE name = @db'
                    if ($autoClose -and [bool]$autoClose) {
                        Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dbName `
                            -Statement 'ALTER DATABASE {DB} SET AUTO_CLOSE OFF;'
                        Write-Log 'Turned AUTO_CLOSE off first: with it on, the database reverts to read-write the next time it is opened' -Level WARN
                    }

                    Invoke-DbStatement -Server $DestinationInstance -DatabaseName $dbName `
                        -Statement 'ALTER DATABASE {DB} SET READ_ONLY WITH ROLLBACK IMMEDIATE;'

                    # and prove it took, rather than reporting the statement that was sent
                    $nowReadOnly = Get-Scalar -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                                   'SELECT is_read_only FROM sys.databases WHERE name = @db'
                    if (-not ($nowReadOnly -and [bool]$nowReadOnly)) {
                        throw 'the database did not stay read-only. Something else is holding it read-write; check AUTO_CLOSE and whether anything is reopening it.'
                    }
                    Write-Log 'Set read-only'
                    Complete-Step
                }

                # say what it actually is now, not what was asked for
                # -DatabaseName matters: sys.database_principals is scoped to the connection's
                # database, so without it this counted master's users instead of this one's
                $final = (Invoke-Sql -Server $DestinationInstance -DatabaseName $dbName -Parameters @{ '@db' = $dbName } -Query `
                          'SELECT recovery_model_desc, is_read_only, Owner = SUSER_SNAME(owner_sid), Users = (SELECT COUNT(*) FROM sys.database_principals WHERE type IN (''S'',''U'',''G'') AND principal_id > 4) FROM sys.databases WHERE name = @db').Rows[0]
                Write-Log ('{0} is now: owner {1}, recovery {2}, {3}, {4} user(s) besides the built-in ones' -f
                           $dbName, $final['Owner'], $final['recovery_model_desc'],
                           $(if ([bool]$final['is_read_only']) { 'read-only' } else { 'read-write' }), $final['Users'])
                $outcome.Users = '{0} left' -f $final['Users']
                $outcome.Result = 'DONE'
            }
            catch {
                if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
                $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                Write-Log ('[{0}] restored, but the tidying up failed: {1}' -f $dbName, $message) -Level ERROR
                Write-Deep ('full exception: ' + $_.Exception.ToString())
                $outcome.Result = 'RESTORED, NOT TIDIED'
                $outcome.Detail = $message
            }
            finally { $script:StepPrefix = '' }
        }
    }
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
        Write-Log 'Run again with -LogLevel Verbose (or Debug) for more.' -Level WARN
    }
}
finally {
    $elapsed = (Get-Date) - $runStart
    Write-Log '---------------- Run summary ----------------' -Min Quiet
    Write-Log "Destination:  $DestinationInstance" -Min Quiet
    Write-Log "Container:    $StorageAccountName/$ContainerName" -Min Quiet
    if (-not $dryRun -and $restoredOk.Count) {
        Write-Log ("Applied to each: {0}owner {1}, recovery {2}{3}{4}" -f
                   $(if ($KeepUsers) { 'users left alone, ' } else { 'users cleared, ' }),
                   $(if ($ownerLogin -and $ownerLogin.Login) { $ownerLogin.Login } else { 'unchanged' }),
                   $RecoveryModel,
                   $(if ($userGrants.Count) { ', users added per database' } else { '' }),
                   $(if ($ReadOnly) { ', read-only' } else { '' })) -Min Quiet
    }
    foreach ($outcome in $results) {
        $line = '{0,-20} {1}' -f $outcome.Result, $outcome.Database
        if ($outcome.BackupTaken) { $line += ' (backup of {0})' -f (Format-Stamp $outcome.BackupTaken) }
        elseif ($outcome.Backup) { $line += ' ({0})' -f $outcome.Backup }
        $granted = @($userGrants | Where-Object { $_.Database -eq $outcome.Database } | ForEach-Object { $_.User })
        if ($granted.Count) { $line += ' [+' + ($granted -join ', ') + ']' }
        if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
        Write-Log $line -Level $(if ($outcome.Result -like 'FAILED*') { 'ERROR' } elseif ($outcome.Result -like '*NOT TIDIED*') { 'WARN' } else { 'INFO' }) -Min Quiet
    }
    if ($script:Level -ge $script:LevelRank['Normal']) {
        foreach ($step in $script:Steps) { Write-Log ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
    }
    $failedCount = @($results | Where-Object { $_.Result -like 'FAILED*' -or $_.Result -like '*NOT TIDIED*' }).Count
    $doneCount = @($results | Where-Object { $_.Result -in 'DONE', 'RESTORED', 'DRY RUN' }).Count
    $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
               elseif ($failedCount -gt 0 -and $doneCount -gt 0) { "PARTLY DONE ($doneCount of $($results.Count))" }
               elseif ($failedCount -gt 0) { 'FAILED' }
               elseif ($dryRun) { 'DRY RUN' }
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
