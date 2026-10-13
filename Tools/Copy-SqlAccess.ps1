#Requires -Version 5.1
<#
.SYNOPSIS
    Gives a principal on one instance the same access another principal has on another instance:
    creates it if it is not there, then copies role memberships and permissions, server level and
    in every database. Works against SQL Server on premises, Azure SQL Managed Instance and Azure
    SQL Database, with any kind of authentication.

.DESCRIPTION
    Molehill Data Services

    For the request that arrives most often: "give xyz on PROD the same access abc has on STAGE".
    It reads what the source principal actually has, works out the statements that would reproduce
    it for the target, and tells you exactly what it is going to do before it does it.

    WHAT IT COPIES
      Server level, where the instance has one (on premises and Managed Instance):
        * the login itself, created if missing - Windows, Entra, or SQL authentication
        * server role memberships, fixed and user-defined
        * server permissions, including DENY and WITH GRANT OPTION
      In every database the source principal appears in:
        * the user, created if missing, with the same default schema
        * database role memberships, fixed and user-defined
        * database permissions at every class it finds - database, schema, object, column, type,
          role, assembly, certificate, key, full-text, XML schema collection and the Service Broker
          ones - including DENY and WITH GRANT OPTION

    WHAT IT DOES NOT COPY, AND SAYS SO
      Ownership. A schema, role or object owned by the source principal is reported, not
      transferred: who owns what is a decision rather than an access right, and moving it can
      break things that depend on it. Credentials, proxies, Agent job ownership, encryption keys
      and anything outside the database engine are left alone too.

    SAFETY
      Nothing is changed until you have seen the plan. -WhatIf prints every statement and stops.
      Without it you are asked to confirm, and the plan is printed first either way. Anything that
      amounts to control of the instance - sysadmin, securityadmin, CONTROL SERVER, ALTER ANY LOGIN
      and the like - is listed separately and refused unless you pass -AllowPrivileged, because
      "the same access as abc" is a reasonable request right up to the point where abc is sysadmin.

    AUTHENTICATION, AND WHAT CAN AND CANNOT BE RECREATED
      A Windows or Entra principal needs no secret, so it is recreated exactly. A SQL login needs a
      password:
        * cloning the same name to another instance: -CopyPasswordAndSid reproduces it byte for
          byte, hash and SID, so applications and orphaned users keep working.
        * creating a differently named login: give -Password, or it is skipped and reported. A
          password is never invented for you.
      On Azure SQL Database there is no server level to copy; its principals live in the databases,
      and master is treated as one of them.

    Needs no modules. Read-only on the source.

    Exit code: 0 = done, or a plan printed with -WhatIf. 1 = something could not be copied. 2 =
    could not start.

.PARAMETER SourceInstance
    The instance to copy access from. Only ever read.

.PARAMETER SourcePrincipal
    The login or user whose access you want to copy, e.g. 'abc', 'CONTOSO\\abc', 'abc@contoso.com'.

.PARAMETER DestinationInstance
    The instance to copy access to. Defaults to the source instance, for copying one principal's
    access to another on the same server.

.PARAMETER Principal
    The login or user to give that access to. Defaults to -SourcePrincipal, for cloning the same
    principal onto another instance.

.PARAMETER Database
    Limit the copy to these databases. By default every database the source principal appears in
    is considered.

.PARAMETER DatabaseMap
    Where the databases are named differently at each end: @{ 'SalesStg' = 'SalesProd' }. Anything
    not named here is matched by its own name.
    Scheduling it? powershell.exe -File turns every argument into a string and cannot pass a
    hashtable, so use -Command for that, or the Stg=Prod string form: -DatabaseMap 'SalesStg=SalesProd'.

.PARAMETER Password
    The password for a new SQL login or contained user, as a SecureString. Only needed when the
    target does not exist and authenticates with a password.

.PARAMETER CopyPasswordAndSid
    When cloning a SQL login of the same name to another instance, recreate it with the source's
    password hash and SID. That keeps applications working and stops database users being
    orphaned. Refused when the names differ, because a SID identifies one principal.

.PARAMETER AllowPrivileged
    Allow the memberships and permissions that amount to control of the instance to be copied.
    Without it they are listed and skipped.

.PARAMETER SkipServerLevel
    Copy only the database-level access, leaving logins, server roles and server permissions alone.

.PARAMETER Force
    Apply without asking. For scheduled or unattended runs; the plan is still printed.

.PARAMETER ScriptPath
    Write every statement to this file as well, whether or not they are applied. Useful when the
    change has to go through someone else.

.PARAMETER SourceSqlCredential
    SQL authentication for the source. Windows authentication is used when left out.

.PARAMETER DestinationSqlCredential
    SQL authentication for the destination.

.PARAMETER SqlCredential
    SQL authentication for both ends, where they are the same.

.PARAMETER TrustServerCertificate
    Trust the server certificate, which an instance with a self-signed one needs.

.PARAMETER LogLevel
    How much to say. Quiet = problems and the summary only. Normal = each step and the decisions
    behind it (default). Verbose = every permission found and every statement. Debug = Verbose plus
    raw exceptions and SQL error numbers. -Verbose or -Debug raise it by themselves.

.PARAMETER LogFile
    Append the same output to this file.

.PARAMETER SelfTest
    Check the script's own logic - the statements it builds for every permission class, how it
    classifies a privileged grant, name quoting and the database mapping - with no server at all.

.EXAMPLE
    .\Copy-SqlAccess.ps1 -SourceInstance STAGE -SourcePrincipal abc `
        -DestinationInstance PROD -Principal 'CONTOSO\xyz' -WhatIf
    # the whole plan, and nothing changed

.EXAMPLE
    .\Copy-SqlAccess.ps1 -SourceInstance STAGE -SourcePrincipal abc `
        -DestinationInstance PROD -Principal 'CONTOSO\xyz' -ScriptPath .\grant-xyz.sql
    # does it, and leaves the script behind for the change record

.EXAMPLE
    # the same login onto a new server, password and SID intact
    .\Copy-SqlAccess.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
        -SourcePrincipal AppSvc -CopyPasswordAndSid

.EXAMPLE
    # Azure SQL Database: no server level, master treated as a database like any other
    .\Copy-SqlAccess.ps1 -SourceInstance stg.database.windows.net -SourcePrincipal 'abc@contoso.com' `
        -DestinationInstance prd.database.windows.net -Principal 'xyz@contoso.com' `
        -SqlCredential (Get-Credential) -Database Sales

.NOTES
    Molehill Data Services. The source is only read. On the destination it creates principals and
    grants permissions, so read the plan.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)] [string] $SourceInstance,
    [Parameter(Position = 1)] [string] $SourcePrincipal,
    [Parameter(Position = 2)] [string] $DestinationInstance,
    [Parameter(Position = 3)] [string] $Principal,

    [string[]] $Database,
    [object] $DatabaseMap,

    [System.Security.SecureString] $Password,
    [switch] $CopyPasswordAndSid,
    [switch] $AllowPrivileged,
    [switch] $SkipServerLevel,

    [switch] $Force,
    [string] $ScriptPath,

    [PSCredential] $SqlCredential,
    [PSCredential] $SourceSqlCredential,
    [PSCredential] $DestinationSqlCredential,
    [switch] $TrustServerCertificate,
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
    [string] $LogFile,
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
$script:LogFilePath = $LogFile
$script:Steps       = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = $null
$script:StepTimer   = $null
$script:StepPrefix  = ''

#==============================================================================
# Plumbing: logging, connecting, and getting a straight answer out of SQL Server
#==============================================================================

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
    $builder['Application Name'] = 'Copy-SqlAccess'
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
# which credential belongs to which end
function Get-CredentialFor([string] $Server) {
    if ($Server -eq $DestinationInstance) { return $DestinationSqlCredential }
    if ($Server -eq $SourceInstance) { return $SourceSqlCredential }
    $SqlCredential
}
function New-ConnectionString([string] $Server, [string] $DatabaseName, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $DatabaseName
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Copy-SqlAccess'
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
# The decisions, kept free of SQL Server so -SelfTest can check them
#==============================================================================

<#
  The securable half of a GRANT, for one row of sys.database_permissions or sys.server_permissions.

  Every class writes its target differently and getting it wrong produces a statement that either
  fails or, worse, grants something else. A class this does not know is returned as $null so the
  caller reports it rather than guessing - a permission quietly dropped is the one failure mode
  that nobody notices until someone cannot work.
#>
function Get-SecurableClause {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClassDesc,
        [AllowEmptyString()] [string] $SchemaName,
        [AllowEmptyString()] [string] $ObjectName,
        [AllowEmptyString()] [string] $ColumnName,
        [AllowEmptyString()] [string] $SubType
    )

    $two = {
        if ($SchemaName) { (Esc-Name $SchemaName) + '.' + (Esc-Name $ObjectName) } else { Esc-Name $ObjectName }
    }

    switch ($ClassDesc.ToUpperInvariant()) {
        'DATABASE'  { return '' }            # GRANT CONNECT TO [x] - no ON clause at all
        'SERVER'    { return '' }
        'OBJECT_OR_COLUMN' {
            if (-not $ObjectName) { return $null }
            $clause = 'ON ' + (& $two)
            if ($ColumnName) { $clause += '(' + (Esc-Name $ColumnName) + ')' }
            return $clause
        }
        'SCHEMA'                  { if ($ObjectName) { return 'ON SCHEMA::' + (Esc-Name $ObjectName) } return $null }
        'TYPE'                    { if ($ObjectName) { return 'ON TYPE::' + (& $two) } return $null }
        'XML_SCHEMA_COLLECTION'   { if ($ObjectName) { return 'ON XML SCHEMA COLLECTION::' + (& $two) } return $null }
        'DATABASE_PRINCIPAL' {
            # the one class that needs to know what kind of principal it found
            if (-not $ObjectName) { return $null }
            $kind = switch ($SubType.ToUpperInvariant()) {
                'R' { 'ROLE::' ; break }
                'A' { 'APPLICATION ROLE::' ; break }
                default { 'USER::' }
            }
            return 'ON ' + $kind + (Esc-Name $ObjectName)
        }
        'ROLE'                    { if ($ObjectName) { return 'ON ROLE::' + (Esc-Name $ObjectName) } return $null }
        'APPLICATION_ROLE'        { if ($ObjectName) { return 'ON APPLICATION ROLE::' + (Esc-Name $ObjectName) } return $null }
        'ASSEMBLY'                { if ($ObjectName) { return 'ON ASSEMBLY::' + (Esc-Name $ObjectName) } return $null }
        'CERTIFICATE'             { if ($ObjectName) { return 'ON CERTIFICATE::' + (Esc-Name $ObjectName) } return $null }
        'ASYMMETRIC_KEY'          { if ($ObjectName) { return 'ON ASYMMETRIC KEY::' + (Esc-Name $ObjectName) } return $null }
        'SYMMETRIC_KEY'           { if ($ObjectName) { return 'ON SYMMETRIC KEY::' + (Esc-Name $ObjectName) } return $null }
        'FULLTEXT_CATALOG'        { if ($ObjectName) { return 'ON FULLTEXT CATALOG::' + (Esc-Name $ObjectName) } return $null }
        'FULLTEXT_STOPLIST'       { if ($ObjectName) { return 'ON FULLTEXT STOPLIST::' + (Esc-Name $ObjectName) } return $null }
        'SEARCH_PROPERTY_LIST'    { if ($ObjectName) { return 'ON SEARCH PROPERTY LIST::' + (Esc-Name $ObjectName) } return $null }
        'MESSAGE_TYPE'            { if ($ObjectName) { return 'ON MESSAGE TYPE::' + (Esc-Name $ObjectName) } return $null }
        'SERVICE_CONTRACT'        { if ($ObjectName) { return 'ON CONTRACT::' + (Esc-Name $ObjectName) } return $null }
        'SERVICE'                 { if ($ObjectName) { return 'ON SERVICE::' + (Esc-Name $ObjectName) } return $null }
        'REMOTE_SERVICE_BINDING'  { if ($ObjectName) { return 'ON REMOTE SERVICE BINDING::' + (Esc-Name $ObjectName) } return $null }
        'ROUTE'                   { if ($ObjectName) { return 'ON ROUTE::' + (Esc-Name $ObjectName) } return $null }
        'DATABASE_SCOPED_CREDENTIAL' { if ($ObjectName) { return 'ON DATABASE SCOPED CREDENTIAL::' + (Esc-Name $ObjectName) } return $null }
        'SERVER_PRINCIPAL' {
            if (-not $ObjectName) { return $null }
            if ($SubType.ToUpperInvariant() -eq 'R') { return 'ON SERVER ROLE::' + (Esc-Name $ObjectName) }
            return 'ON LOGIN::' + (Esc-Name $ObjectName)
        }
        'SERVER_ROLE'             { if ($ObjectName) { return 'ON SERVER ROLE::' + (Esc-Name $ObjectName) } return $null }
        'ENDPOINT'                { if ($ObjectName) { return 'ON ENDPOINT::' + (Esc-Name $ObjectName) } return $null }
        'AVAILABILITY_GROUP'      { if ($ObjectName) { return 'ON AVAILABILITY GROUP::' + (Esc-Name $ObjectName) } return $null }
        default { return $null }
    }
}

<#
  One row of permissions turned into the statement that reproduces it.

  state_desc carries the three cases that matter: a plain GRANT, a DENY, and a GRANT that the
  principal may pass on in turn. Losing the last two would quietly hand out more access than the
  source had, or less.
#>
function New-PermissionStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [string] $ToPrincipal
    )

    $clause = Get-SecurableClause -ClassDesc ([string]$Row.ClassDesc) -SchemaName ([string]$Row.SchemaName) `
                                  -ObjectName ([string]$Row.ObjectName) -ColumnName ([string]$Row.ColumnName) `
                                  -SubType ([string]$Row.SubType)
    if ($null -eq $clause) { return $null }

    $permission = ([string]$Row.PermissionName).Trim()
    if (-not $permission) { return $null }
    $target = Esc-Name $ToPrincipal
    $state = ([string]$Row.StateDesc).ToUpperInvariant()

    $verb = switch ($state) {
        'DENY'                    { 'DENY' }
        'REVOKE'                  { 'REVOKE' }
        default                   { 'GRANT' }
    }
    $statement = $verb + ' ' + $permission
    if ($clause) { $statement += ' ' + $clause }
    $statement += ' TO ' + $target
    if ($state -eq 'GRANT_WITH_GRANT_OPTION') { $statement += ' WITH GRANT OPTION' }
    $statement + ';'
}

<#
  Whether a membership or permission amounts to control of the instance.

  "The same access as abc" is a fair request until abc turns out to be sysadmin, so these are
  listed separately and left alone unless they are asked for explicitly. The list is deliberately
  blunt: anything that can grant itself more, read everything, or run code as someone else.
#>
function Test-PrivilegedGrant {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $RoleName, [AllowEmptyString()] [string] $PermissionName)

    $roles = 'sysadmin', 'securityadmin', 'serveradmin', 'setupadmin', 'processadmin', 'diskadmin',
             'dbcreator', 'bulkadmin', 'loginmanager', 'dbmanager'
    $permissions = 'CONTROL SERVER', 'ALTER ANY LOGIN', 'ALTER ANY SERVER ROLE', 'ALTER ANY CREDENTIAL',
                   'ALTER ANY LINKED SERVER', 'ALTER SETTINGS', 'ALTER TRACE', 'ADMINISTER BULK OPERATIONS',
                   'IMPERSONATE ANY LOGIN', 'SELECT ALL USER SECURABLES', 'UNSAFE ASSEMBLY',
                   'EXTERNAL ACCESS ASSEMBLY', 'CREATE SERVER ROLE', 'SHUTDOWN'

    if ($RoleName -and ($roles -contains $RoleName.ToLowerInvariant())) { return $true }
    if ($PermissionName -and ($permissions -contains $PermissionName.ToUpperInvariant())) { return $true }
    $false
}

# where a database is called something else at the other end
function Resolve-DatabaseName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name, $Map)

    if ($null -eq $Map) { return $Name }
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in $Map.Keys) { if ([string]$key -eq $Name) { return [string]$Map[$key] } }
        return $Name
    }
    # the string form, for powershell.exe -File which cannot pass a hashtable
    foreach ($entry in @($Map)) {
        foreach ($pair in (([string]$entry) -split ';')) {
            $parts = $pair.Split('=')
            if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $Name) { return $parts[1].Trim() }
        }
    }
    $Name
}

<#
  The statement that creates the target principal, which depends on what it authenticates with and
  on what kind of instance it is going onto.

  Azure SQL Database has no server level worth the name: its principals are database users, and a
  Windows account means nothing to it. A password is never invented - where one is needed and not
  supplied, the caller is told and the principal is left uncreated rather than created wrongly.
#>
function New-PrincipalStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Login', 'User')] [string] $Scope,
        [Parameter(Mandatory)] [string] $TypeDesc,
        [AllowEmptyString()] [string] $DefaultDatabase,
        [AllowEmptyString()] [string] $DefaultSchema,
        [AllowEmptyString()] [string] $PasswordLiteral,
        [AllowEmptyString()] [string] $Sid,
        [switch] $Hashed,
        [switch] $AzureSqlDatabase,
        [AllowEmptyString()] [string] $ForLogin,
        [AllowEmptyString()] [string] $AuthType
    )

    $quoted = Esc-Name $Name
    $type = $TypeDesc.ToUpperInvariant()
    $windows = ($type -like 'WINDOWS*')
    $external = ($type -like '*EXTERNAL*')          # Entra, in all its spellings

    if ($Scope -eq 'Login') {
        if ($AzureSqlDatabase) { return $null }     # there is no CREATE LOGIN worth having here
        if ($windows) { return 'CREATE LOGIN ' + $quoted + ' FROM WINDOWS' + $(if ($DefaultDatabase) { ' WITH DEFAULT_DATABASE = ' + (Esc-Name $DefaultDatabase) } else { '' }) + ';' }
        if ($external) { return 'CREATE LOGIN ' + $quoted + ' FROM EXTERNAL PROVIDER;' }
        if (-not $PasswordLiteral) { return $null }
        $with = 'PASSWORD = ' + $PasswordLiteral
        if ($Hashed) { $with += ' HASHED' }
        if ($Sid) { $with += ', SID = ' + $Sid }
        if ($DefaultDatabase) { $with += ', DEFAULT_DATABASE = ' + (Esc-Name $DefaultDatabase) }
        if ($Hashed) { $with += ', CHECK_POLICY = OFF' }   # a copied hash must not be re-policed
        return 'CREATE LOGIN ' + $quoted + ' WITH ' + $with + ';'
    }

    # A database user, where what to write is decided by what it authenticates with rather than by
    # its type. type_desc says SQL_USER for all three of a user mapped to a login, a user with no
    # login at all and a contained user with its own password; authentication_type_desc is what
    # tells them apart - INSTANCE, NONE and DATABASE.
    $tail = if ($DefaultSchema) { ' WITH DEFAULT_SCHEMA = ' + (Esc-Name $DefaultSchema) } else { '' }
    $auth = $AuthType.ToUpperInvariant()
    $password = ''
    if ($PasswordLiteral) {
        $password = 'CREATE USER ' + $quoted + ' WITH PASSWORD = ' + $PasswordLiteral +
                    $(if ($DefaultSchema) { ', DEFAULT_SCHEMA = ' + (Esc-Name $DefaultSchema) } else { '' }) + ';'
    }

    if ($external -or $auth -eq 'EXTERNAL') { return 'CREATE USER ' + $quoted + ' FROM EXTERNAL PROVIDER' + $tail + ';' }
    if ($auth -eq 'NONE') { return 'CREATE USER ' + $quoted + ' WITHOUT LOGIN' + $tail + ';' }
    if ($auth -eq 'DATABASE') { if ($password) { return $password } return $null }
    if ($type -like '*MAPPED*') { return $null }   # tied to a certificate or key, which is not ours to copy
    if ($ForLogin) { return 'CREATE USER ' + $quoted + ' FOR LOGIN ' + (Esc-Name $ForLogin) + $tail + ';' }
    if ($windows) { return 'CREATE USER ' + $quoted + ' FROM WINDOWS' + $tail + ';' }
    if ($password) { return $password }
    $null
}

<#
  The same statement with any password taken out of it, for anything anyone else will read.

  The plan is printed and may be written to a log file that outlives the change, so a password
  typed into -Password, or a hash copied with -CopyPasswordAndSid, must not travel with it. The
  file written by -ScriptPath is the one exception, because it has to be able to run.
#>
function Hide-Secret {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Statement)
    [regex]::Replace($Statement, "(?i)(PASSWORD\s*=\s*)(N?'(?:[^']|'')*'|0x[0-9A-Fa-f]+)", '$1<withheld>')
}

# a SecureString turned into a T-SQL literal, and gone again as soon as possible
function ConvertTo-SqlPasswordLiteral {
    [CmdletBinding()]
    param([AllowNull()] [System.Security.SecureString] $Secure)

    if ($null -eq $Secure) { return '' }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { "N'" + ([System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) -replace "'", "''") + "'" }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# sys.sql_logins gives the hash as bytes; CREATE LOGIN wants it as 0x...
function ConvertTo-HexLiteral {
    [CmdletBinding()]
    param([AllowNull()] $Bytes)

    if ($null -eq $Bytes -or $Bytes -is [System.DBNull]) { return '' }
    if ($Bytes -is [string]) { return $Bytes }
    '0x' + (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

# what SERVERPROPERTY('EngineEdition') is telling us
function Get-EditionName([int] $EngineEdition) {
    switch ($EngineEdition) {
        1 { 'SQL Server Personal/Desktop' }
        2 { 'SQL Server Standard' }
        3 { 'SQL Server Enterprise, Developer or Evaluation' }
        4 { 'SQL Server Express or LocalDB' }
        5 { 'Azure SQL Database' }
        6 { 'Azure Synapse Analytics' }
        8 { 'Azure SQL Managed Instance' }
        9 { 'Azure Synapse serverless SQL pool' }
        11 { 'Azure SQL Edge' }
        default { "an engine edition this script has not seen before ($EngineEdition)" }
    }
}

<#
  Adding a member to a role, written the way the destination can run it.

  ALTER ROLE ... ADD MEMBER and ALTER SERVER ROLE arrived in SQL Server 2012. Anything older needs
  the stored procedures, and this is a tool for estates that still have an old box in the corner,
  so both forms are built here rather than assumed.
#>
function New-RoleMemberStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RoleName,
        [Parameter(Mandatory)] [string] $MemberName,
        [Parameter(Mandatory)] [ValidateSet('Server', 'Database')] [string] $Scope,
        [int] $MajorVersion = 0
    )

    $legacy = ($MajorVersion -gt 0 -and $MajorVersion -lt 11)
    if ($Scope -eq 'Server') {
        if ($legacy) { return "EXEC sp_addsrvrolemember @loginame = N'" + (Esc-Str $MemberName) + "', @rolename = N'" + (Esc-Str $RoleName) + "';" }
        return 'ALTER SERVER ROLE ' + (Esc-Name $RoleName) + ' ADD MEMBER ' + (Esc-Name $MemberName) + ';'
    }
    if ($legacy) { return "EXEC sp_addrolemember @rolename = N'" + (Esc-Str $RoleName) + "', @membername = N'" + (Esc-Str $MemberName) + "';" }
    'ALTER ROLE ' + (Esc-Name $RoleName) + ' ADD MEMBER ' + (Esc-Name $MemberName) + ';'
}

<#
  Where to look up the name behind a permission's major_id, per class.

  sys.database_permissions and sys.server_permissions only give you a number; which catalogue view
  turns it back into a name depends on the class. Doing this as a lookup rather than one large CASE
  expression matters for old versions: a query that mentions sys.database_scoped_credentials will
  not even compile on SQL Server 2012, so each view is asked for only when the permission needs it
  and only after checking the view is there.

  OBJECT_OR_COLUMN and SCHEMA are handled separately because they have built-in functions, and
  because they are the two classes that actually turn up in real estates.

  Classes not listed here - availability groups, whose id is a GUID rather than the integer the
  permission carries - are reported as not copied instead of being guessed at.
#>
$script:ClassLookup = @{
    'TYPE'                       = @{ View = 'sys.types';                           Id = 'user_type_id';               Schema = $true }
    'XML_SCHEMA_COLLECTION'      = @{ View = 'sys.xml_schema_collections';          Id = 'xml_collection_id';          Schema = $true }
    'DATABASE_PRINCIPAL'         = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'ROLE'                       = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'APPLICATION_ROLE'           = @{ View = 'sys.database_principals';             Id = 'principal_id';               Type = $true }
    'ASSEMBLY'                   = @{ View = 'sys.assemblies';                      Id = 'assembly_id' }
    'CERTIFICATE'                = @{ View = 'sys.certificates';                    Id = 'certificate_id' }
    'ASYMMETRIC_KEY'             = @{ View = 'sys.asymmetric_keys';                 Id = 'asymmetric_key_id' }
    'SYMMETRIC_KEY'              = @{ View = 'sys.symmetric_keys';                  Id = 'symmetric_key_id' }
    'FULLTEXT_CATALOG'           = @{ View = 'sys.fulltext_catalogs';               Id = 'fulltext_catalog_id' }
    'FULLTEXT_STOPLIST'          = @{ View = 'sys.fulltext_stoplists';              Id = 'stoplist_id' }
    'SEARCH_PROPERTY_LIST'       = @{ View = 'sys.registered_search_property_lists'; Id = 'property_list_id' }
    'MESSAGE_TYPE'               = @{ View = 'sys.service_message_types';           Id = 'message_type_id' }
    'SERVICE_CONTRACT'           = @{ View = 'sys.service_contracts';               Id = 'service_contract_id' }
    'SERVICE'                    = @{ View = 'sys.services';                        Id = 'service_id' }
    'REMOTE_SERVICE_BINDING'     = @{ View = 'sys.remote_service_bindings';          Id = 'remote_service_binding_id' }
    'ROUTE'                      = @{ View = 'sys.routes';                          Id = 'route_id' }
    'DATABASE_SCOPED_CREDENTIAL' = @{ View = 'sys.database_scoped_credentials';      Id = 'credential_id' }
    'SERVER_PRINCIPAL'           = @{ View = 'sys.server_principals';               Id = 'principal_id';               Type = $true }
    'SERVER_ROLE'                = @{ View = 'sys.server_principals';               Id = 'principal_id';               Type = $true }
    'ENDPOINT'                   = @{ View = 'sys.endpoints';                       Id = 'endpoint_id' }
}

function Get-ClassLookup([string] $ClassDesc) {
    if (-not $ClassDesc) { return $null }
    $key = $ClassDesc.ToUpperInvariant()
    if ($script:ClassLookup.ContainsKey($key)) { return $script:ClassLookup[$key] }
    $null
}

# the query that turns a set of major_ids back into names, for one class
function New-TargetLookupQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClassDesc, [Parameter(Mandatory)] [int[]] $Ids)

    $list = ($Ids | Sort-Object -Unique) -join ','
    switch ($ClassDesc.ToUpperInvariant()) {
        'OBJECT_OR_COLUMN' {
            return "SELECT MajorId = o.object_id, SchemaName = SCHEMA_NAME(o.schema_id), ObjectName = o.name, " +
                   "SubType = CONVERT(char(1), NULL) FROM sys.objects o WHERE o.object_id IN ($list);"
        }
        'SCHEMA' {
            return "SELECT MajorId = s.schema_id, SchemaName = CONVERT(sysname, NULL), ObjectName = s.name, " +
                   "SubType = CONVERT(char(1), NULL) FROM sys.schemas s WHERE s.schema_id IN ($list);"
        }
    }
    $lookup = Get-ClassLookup $ClassDesc
    if (-not $lookup) { return $null }
    $schema = if ($lookup.Schema) { 'SCHEMA_NAME(x.schema_id)' } else { 'CONVERT(sysname, NULL)' }
    # principals need their own type as well, because a permission on a role is not written the way
    # one on a user is
    $subType = if ($lookup.Type) { 'x.type' } else { 'CONVERT(char(1), NULL)' }
    "IF OBJECT_ID('$($lookup.View)') IS NOT NULL EXEC sp_executesql N'" +
    "SELECT MajorId = x.$($lookup.Id), SchemaName = $schema, ObjectName = x.name, SubType = $subType " +
    "FROM $($lookup.View) x WHERE x.$($lookup.Id) IN ($list)';"
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
    function Perm([string] $Class, [string] $Permission, [string] $State = 'GRANT',
                  [string] $Schema = '', [string] $Object = '', [string] $Column = '', [string] $SubType = '') {
        [pscustomobject]@{ ClassDesc = $Class; PermissionName = $Permission; StateDesc = $State
                           SchemaName = $Schema; ObjectName = $Object; ColumnName = $Column; SubType = $SubType }
    }

    Write-Host 'Copy-SqlAccess self test'
    Write-Host '  the statements it builds' -ForegroundColor Gray
    Check 'connect to the database has no ON clause' ((New-PermissionStatement (Perm 'DATABASE' 'CONNECT') 'xyz') -eq 'GRANT CONNECT TO [xyz];')
    Check 'a table' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Orders') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders] TO [xyz];')
    Check 'a column' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Orders' 'Total') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders]([Total]) TO [xyz];')
    Check 'a schema' ((New-PermissionStatement (Perm 'SCHEMA' 'EXECUTE' 'GRANT' '' 'sales') 'xyz') -eq 'GRANT EXECUTE ON SCHEMA::[sales] TO [xyz];')
    Check 'a type keeps its schema' ((New-PermissionStatement (Perm 'TYPE' 'EXECUTE' 'GRANT' 'dbo' 'OrderList') 'xyz') -eq 'GRANT EXECUTE ON TYPE::[dbo].[OrderList] TO [xyz];')
    Check 'a role' ((New-PermissionStatement (Perm 'ROLE' 'ALTER' 'GRANT' '' 'ReportReaders') 'xyz') -eq 'GRANT ALTER ON ROLE::[ReportReaders] TO [xyz];')
    Check 'impersonating a user' ((New-PermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'dbo') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[dbo] TO [xyz];')
    Check 'a certificate' ((New-PermissionStatement (Perm 'CERTIFICATE' 'VIEW DEFINITION' 'GRANT' '' 'AppCert') 'xyz') -eq 'GRANT VIEW DEFINITION ON CERTIFICATE::[AppCert] TO [xyz];')
    Check 'a symmetric key spells the two words out' ((New-PermissionStatement (Perm 'SYMMETRIC_KEY' 'VIEW DEFINITION' 'GRANT' '' 'AppKey') 'xyz') -eq 'GRANT VIEW DEFINITION ON SYMMETRIC KEY::[AppKey] TO [xyz];')
    Check 'an XML schema collection too' ((New-PermissionStatement (Perm 'XML_SCHEMA_COLLECTION' 'EXECUTE' 'GRANT' 'dbo' 'Invoices') 'xyz') -eq 'GRANT EXECUTE ON XML SCHEMA COLLECTION::[dbo].[Invoices] TO [xyz];')
    Check 'a service broker contract' ((New-PermissionStatement (Perm 'SERVICE_CONTRACT' 'SEND' 'GRANT' '' 'OrderContract') 'xyz') -eq 'GRANT SEND ON CONTRACT::[OrderContract] TO [xyz];')
    Check 'a server permission has no ON clause' ((New-PermissionStatement (Perm 'SERVER' 'VIEW SERVER STATE') 'xyz') -eq 'GRANT VIEW SERVER STATE TO [xyz];')
    Check 'impersonating a login' ((New-PermissionStatement (Perm 'SERVER_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'sa') 'xyz') -eq 'GRANT IMPERSONATE ON LOGIN::[sa] TO [xyz];')
    Check 'an endpoint' ((New-PermissionStatement (Perm 'ENDPOINT' 'CONNECT' 'GRANT' '' 'TSQL Default TCP') 'xyz') -eq 'GRANT CONNECT ON ENDPOINT::[TSQL Default TCP] TO [xyz];')

    Write-Host '  a principal, which is three different things under one class' -ForegroundColor Gray
    Check 'a database role is a role, not a user' ((New-PermissionStatement (Perm 'DATABASE_PRINCIPAL' 'ALTER' 'GRANT' '' 'ReportReaders' '' 'R') 'xyz') -eq 'GRANT ALTER ON ROLE::[ReportReaders] TO [xyz];')
    Check 'an application role says so' ((New-PermissionStatement (Perm 'DATABASE_PRINCIPAL' 'ALTER' 'GRANT' '' 'AppRole' '' 'A') 'xyz') -eq 'GRANT ALTER ON APPLICATION ROLE::[AppRole] TO [xyz];')
    Check 'a SQL user is a user' ((New-PermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'LocalOnly' '' 'S') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[LocalOnly] TO [xyz];')
    Check 'a Windows user is too' ((New-PermissionStatement (Perm 'DATABASE_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'CONTOSO\abc' '' 'U') 'xyz') -eq 'GRANT IMPERSONATE ON USER::[CONTOSO\abc] TO [xyz];')
    Check 'a server role is a server role' ((New-PermissionStatement (Perm 'SERVER_PRINCIPAL' 'ALTER' 'GRANT' '' 'AppAdmins' '' 'R') 'xyz') -eq 'GRANT ALTER ON SERVER ROLE::[AppAdmins] TO [xyz];')
    Check 'and a login is a login' ((New-PermissionStatement (Perm 'SERVER_PRINCIPAL' 'IMPERSONATE' 'GRANT' '' 'sa' '' 'S') 'xyz') -eq 'GRANT IMPERSONATE ON LOGIN::[sa] TO [xyz];')

    Write-Host '  the three states, which all matter' -ForegroundColor Gray
    Check 'a deny stays a deny' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'DENY' 'dbo' 'Wages') 'xyz') -eq 'DENY SELECT ON [dbo].[Wages] TO [xyz];')
    Check 'a grant option is carried over' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT_WITH_GRANT_OPTION' 'dbo' 'Orders') 'xyz') -eq 'GRANT SELECT ON [dbo].[Orders] TO [xyz] WITH GRANT OPTION;')
    Check 'and a revoke is not turned into a grant' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'REVOKE' 'dbo' 'Orders') 'xyz') -match '^REVOKE ')

    Write-Host '  names that would otherwise break out of the statement' -ForegroundColor Gray
    Check 'a bracket in a table name is escaped' ((New-PermissionStatement (Perm 'OBJECT_OR_COLUMN' 'SELECT' 'GRANT' 'dbo' 'Odd]Name') 'xyz') -eq 'GRANT SELECT ON [dbo].[Odd]]Name] TO [xyz];')
    Check 'a domain account is quoted whole' ((New-PermissionStatement (Perm 'DATABASE' 'CONNECT') 'CONTOSO\xyz') -eq 'GRANT CONNECT TO [CONTOSO\xyz];')
    Check 'an Entra account with an at sign too' ((New-PermissionStatement (Perm 'DATABASE' 'CONNECT') 'xyz@contoso.com') -eq 'GRANT CONNECT TO [xyz@contoso.com];')

    Write-Host '  a class it does not know is reported, not guessed' -ForegroundColor Gray
    Check 'an unknown class gives nothing back' ($null -eq (New-PermissionStatement (Perm 'SOME_NEW_CLASS' 'SELECT' 'GRANT' '' 'thing') 'xyz'))
    Check 'and so does a known class with no target' ($null -eq (New-PermissionStatement (Perm 'SCHEMA' 'EXECUTE') 'xyz'))

    Write-Host '  what counts as control of the instance' -ForegroundColor Gray
    Check 'sysadmin does' (Test-PrivilegedGrant -RoleName 'sysadmin')
    Check 'securityadmin does' (Test-PrivilegedGrant -RoleName 'securityadmin')
    Check 'and so does dbcreator' (Test-PrivilegedGrant -RoleName 'dbcreator')
    Check 'Azure loginmanager does' (Test-PrivilegedGrant -RoleName 'loginmanager')
    Check 'CONTROL SERVER does' (Test-PrivilegedGrant -PermissionName 'CONTROL SERVER')
    Check 'ALTER ANY LOGIN does' (Test-PrivilegedGrant -PermissionName 'alter any login')
    Check 'public does not' (-not (Test-PrivilegedGrant -RoleName 'public'))
    Check 'db_datareader does not' (-not (Test-PrivilegedGrant -RoleName 'db_datareader'))
    Check 'VIEW SERVER STATE does not' (-not (Test-PrivilegedGrant -PermissionName 'VIEW SERVER STATE'))
    Check 'and nor does plain SELECT' (-not (Test-PrivilegedGrant -PermissionName 'SELECT'))

    Write-Host '  databases named differently at each end' -ForegroundColor Gray
    Check 'a hashtable maps it' ((Resolve-DatabaseName -Name 'SalesStg' -Map @{ SalesStg = 'SalesProd' }) -eq 'SalesProd')
    Check 'anything unmapped keeps its name' ((Resolve-DatabaseName -Name 'Stock' -Map @{ SalesStg = 'SalesProd' }) -eq 'Stock')
    Check 'the string form works for -File' ((Resolve-DatabaseName -Name 'SalesStg' -Map 'SalesStg=SalesProd') -eq 'SalesProd')
    Check 'several pairs in one string' ((Resolve-DatabaseName -Name 'Stock' -Map 'SalesStg=SalesProd;Stock=StockProd') -eq 'StockProd')
    Check 'no map at all is no change' ((Resolve-DatabaseName -Name 'Sales' -Map $null) -eq 'Sales')

    Write-Host '  creating the principal' -ForegroundColor Gray
    Check 'a Windows login' ((New-PrincipalStatement -Name 'CONTOSO\xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN') -eq 'CREATE LOGIN [CONTOSO\xyz] FROM WINDOWS;')
    Check 'with its default database' ((New-PrincipalStatement -Name 'CONTOSO\xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN' -DefaultDatabase 'Sales') -match 'DEFAULT_DATABASE = \[Sales\]')
    Check 'an Entra login' ((New-PrincipalStatement -Name 'xyz@contoso.com' -Scope Login -TypeDesc 'EXTERNAL_LOGIN') -eq 'CREATE LOGIN [xyz@contoso.com] FROM EXTERNAL PROVIDER;')
    Check 'a SQL login needs a password' ($null -eq (New-PrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'SQL_LOGIN'))
    Check 'and takes one when given' ((New-PrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'SQL_LOGIN' -PasswordLiteral "N'pw'") -eq "CREATE LOGIN [xyz] WITH PASSWORD = N'pw';")
    $cloned = New-PrincipalStatement -Name 'AppSvc' -Scope Login -TypeDesc 'SQL_LOGIN' -PasswordLiteral '0xABCD' -Sid '0x1234' -Hashed
    Check 'a cloned login carries hash and SID' ($cloned -match 'PASSWORD = 0xABCD HASHED' -and $cloned -match 'SID = 0x1234')
    Check 'and is not re-policed, which would reject the hash' ($cloned -match 'CHECK_POLICY = OFF')
    Check 'there is no login to create on Azure SQL Database' ($null -eq (New-PrincipalStatement -Name 'xyz' -Scope Login -TypeDesc 'WINDOWS_LOGIN' -AzureSqlDatabase))

    Check 'a user for a login' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -ForLogin 'xyz') -eq 'CREATE USER [xyz] FOR LOGIN [xyz];')
    Check 'with its default schema' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -ForLogin 'xyz' -DefaultSchema 'sales') -match 'DEFAULT_SCHEMA = \[sales\]')
    Check 'an Entra user needs no login' ((New-PrincipalStatement -Name 'xyz@contoso.com' -Scope User -TypeDesc 'EXTERNAL_USER') -eq 'CREATE USER [xyz@contoso.com] FROM EXTERNAL PROVIDER;')
    Check 'a user with no login behind it' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'NONE') -eq 'CREATE USER [xyz] WITHOUT LOGIN;')
    Check 'which is how SQL Server describes it, whatever the type says' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'NONE' -ForLogin 'xyz') -eq 'CREATE USER [xyz] WITHOUT LOGIN;')
    Check 'a contained user with a password' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE' -PasswordLiteral "N'pw'") -eq "CREATE USER [xyz] WITH PASSWORD = N'pw';")
    Check 'a contained user keeps its default schema' ((New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE' -PasswordLiteral "N'pw'" -DefaultSchema 'sales') -match ', DEFAULT_SCHEMA = \[sales\];$')
    Check 'a certificate-mapped user is not invented' ($null -eq (New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'CERTIFICATE_MAPPED_USER'))
    Check 'a Windows user mapped straight through' ((New-PrincipalStatement -Name 'CONTOSO\xyz' -Scope User -TypeDesc 'WINDOWS_USER') -eq 'CREATE USER [CONTOSO\xyz] FROM WINDOWS;')
    Check 'and a contained user with no password is refused' ($null -eq (New-PrincipalStatement -Name 'xyz' -Scope User -TypeDesc 'SQL_USER' -AuthType 'DATABASE'))

    Write-Host '  hex and secrets' -ForegroundColor Gray
    Check 'a password is kept out of the printed plan' ((Hide-Secret "CREATE LOGIN [xyz] WITH PASSWORD = N'p''wd', DEFAULT_DATABASE = [Sales];") -eq 'CREATE LOGIN [xyz] WITH PASSWORD = <withheld>, DEFAULT_DATABASE = [Sales];')
    Check 'and so is a copied hash' ((Hide-Secret 'CREATE LOGIN [xyz] WITH PASSWORD = 0xABCDEF HASHED, SID = 0x1234;') -eq 'CREATE LOGIN [xyz] WITH PASSWORD = <withheld> HASHED, SID = 0x1234;')
    Check 'a statement with no password is left alone' ((Hide-Secret 'GRANT SELECT ON [dbo].[T] TO [xyz];') -eq 'GRANT SELECT ON [dbo].[T] TO [xyz];')
    Check 'bytes become a hex literal' ((ConvertTo-HexLiteral ([byte[]](0x01, 0xAB, 0xFF))) -eq '0x01ABFF')
    Check 'nothing becomes nothing' ((ConvertTo-HexLiteral $null) -eq '')
    $secure = ConvertTo-SecureString "p'wd" -AsPlainText -Force
    Check 'a password is quoted and its quote doubled' ((ConvertTo-SqlPasswordLiteral $secure) -eq "N'p''wd'")
    Check 'no password is an empty literal' ((ConvertTo-SqlPasswordLiteral $null) -eq '')

    Write-Host '  statements an older destination can actually run' -ForegroundColor Gray
    Check 'a modern server role' ((New-RoleMemberStatement -RoleName 'dbcreator' -MemberName 'xyz' -Scope Server -MajorVersion 16) -eq 'ALTER SERVER ROLE [dbcreator] ADD MEMBER [xyz];')
    Check 'a modern database role' ((New-RoleMemberStatement -RoleName 'db_datareader' -MemberName 'xyz' -Scope Database -MajorVersion 16) -eq 'ALTER ROLE [db_datareader] ADD MEMBER [xyz];')
    Check '2008 R2 gets sp_addsrvrolemember' ((New-RoleMemberStatement -RoleName 'dbcreator' -MemberName 'CONTOSO\xyz' -Scope Server -MajorVersion 10) -eq "EXEC sp_addsrvrolemember @loginame = N'CONTOSO\xyz', @rolename = N'dbcreator';")
    Check '2008 R2 gets sp_addrolemember' ((New-RoleMemberStatement -RoleName 'db_datareader' -MemberName 'xyz' -Scope Database -MajorVersion 10) -eq "EXEC sp_addrolemember @rolename = N'db_datareader', @membername = N'xyz';")
    Check 'and a quote in a role name is doubled, not left to break out' ((New-RoleMemberStatement -RoleName "O'Brien" -MemberName 'xyz' -Scope Database -MajorVersion 10) -match "N'O''Brien'")
    Check 'an unknown version is assumed to be a current one' ((New-RoleMemberStatement -RoleName 'public' -MemberName 'xyz' -Scope Database) -match '^ALTER ROLE ')

    Write-Host '  looking a permission target up by class' -ForegroundColor Gray
    Check 'a table is found through sys.objects' ((New-TargetLookupQuery -ClassDesc 'OBJECT_OR_COLUMN' -Ids @(5, 5, 3)) -match 'sys\.objects o WHERE o\.object_id IN \(3,5\);$')
    Check 'a principal lookup brings its type back with it' ((New-TargetLookupQuery -ClassDesc 'DATABASE_PRINCIPAL' -Ids @(5)) -match 'SubType = x\.type')
    Check 'and anything else does not pretend to have one' ((New-TargetLookupQuery -ClassDesc 'CERTIFICATE' -Ids @(5)) -match 'SubType = CONVERT\(char\(1\), NULL\)')
    Check 'a schema through sys.schemas' ((New-TargetLookupQuery -ClassDesc 'SCHEMA' -Ids @(9)) -match 'sys\.schemas s WHERE s\.schema_id IN \(9\)')
    $credential = New-TargetLookupQuery -ClassDesc 'DATABASE_SCOPED_CREDENTIAL' -Ids @(7)
    Check 'a view that may not exist is asked for only if it is there' ($credential -match "IF OBJECT_ID\('sys\.database_scoped_credentials'\) IS NOT NULL")
    Check 'and by its own id column' ($credential -match 'credential_id IN \(7\)')
    Check 'a type carries its schema back with it' ((New-TargetLookupQuery -ClassDesc 'TYPE' -Ids @(256)) -match 'SCHEMA_NAME\(x\.schema_id\)')
    Check 'a certificate does not pretend to have one' ((New-TargetLookupQuery -ClassDesc 'CERTIFICATE' -Ids @(1)) -match 'CONVERT\(sysname, NULL\)')
    Check 'an availability group is not guessed at, because its id is a GUID' ($null -eq (New-TargetLookupQuery -ClassDesc 'AVAILABILITY_GROUP' -Ids @(1)))
    Check 'nor is any other class it has not met' ($null -eq (New-TargetLookupQuery -ClassDesc 'SOMETHING_NEW' -Ids @(1)))

    Write-Host '  knowing what kind of instance it is talking to' -ForegroundColor Gray
    Check 'on premises' ((Get-EditionName 3) -match 'SQL Server Enterprise')
    Check 'Azure SQL Database' ((Get-EditionName 5) -eq 'Azure SQL Database')
    Check 'a managed instance' ((Get-EditionName 8) -eq 'Azure SQL Managed Instance')
    Check 'and an edition from the future is not misreported' ((Get-EditionName 99) -match 'not seen before')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# Reading the source
#
# Nothing here resolves a permission's target in the query itself. The views that turn a major_id
# back into a name differ by version - sys.database_scoped_credentials does not exist before 2016,
# search property lists not before 2012 - and a query that merely mentions a missing view will not
# compile at all. So the permissions come back with their numbers, and the names are looked up
# afterwards, one class at a time, only for the classes that actually turned up.
#==============================================================================
$LoginQuery = @"
SELECT  sp.name, sp.type, sp.type_desc, sp.is_disabled, sp.default_database_name,
        Sid = sp.sid,
        PasswordHash = CASE WHEN sp.type = 'S'
                            THEN (SELECT sl.password_hash FROM sys.sql_logins sl WHERE sl.principal_id = sp.principal_id) END
FROM sys.server_principals sp
WHERE sp.name = @p AND sp.type <> 'R';
"@

$ServerRoleQuery = @"
SELECT RoleName = r.name
FROM sys.server_role_members m
JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
JOIN sys.server_principals p ON p.principal_id = m.member_principal_id
WHERE p.name = @p
ORDER BY r.name;
"@

$ServerPermissionQuery = @"
SELECT  StateDesc = pe.state_desc, PermissionName = pe.permission_name, ClassDesc = pe.class_desc,
        MajorId = pe.major_id, MinorId = pe.minor_id
FROM sys.server_permissions pe
JOIN sys.server_principals p ON p.principal_id = pe.grantee_principal_id
WHERE p.name = @p
ORDER BY pe.class_desc, pe.permission_name;
"@

# asked of each database in turn, because Azure SQL Database has no cross-database anything and the
# answer has to be the same shape either way
$DatabaseRoleQuery = @"
SELECT RoleName = r.name
FROM sys.database_role_members m
JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = @p
ORDER BY r.name;
"@

$DatabasePermissionQuery = @"
SELECT  StateDesc = pe.state_desc, PermissionName = pe.permission_name, ClassDesc = pe.class_desc,
        MajorId = pe.major_id, MinorId = pe.minor_id
FROM sys.database_permissions pe
JOIN sys.database_principals u ON u.principal_id = pe.grantee_principal_id
WHERE u.name = @p
ORDER BY pe.class_desc, pe.permission_name;
"@

# what the principal owns, which is reported rather than moved
$OwnedQuery = @"
SELECT Kind = 'schema', ObjectName = s.name
FROM sys.schemas s JOIN sys.database_principals p ON p.principal_id = s.principal_id WHERE p.name = @p
UNION ALL
SELECT Kind = 'role', ObjectName = r.name
FROM sys.database_principals r JOIN sys.database_principals p ON p.principal_id = r.owning_principal_id
WHERE r.type = 'R' AND p.name = @p
UNION ALL
SELECT Kind = 'object', ObjectName = SCHEMA_NAME(o.schema_id) + '.' + o.name
FROM sys.objects o JOIN sys.database_principals p ON p.principal_id = o.principal_id WHERE p.name = @p;
"@

<#
  sys.database_principals.authentication_type_desc arrived in SQL Server 2012, and it is the column
  that tells a user mapped to a login apart from one created WITHOUT LOGIN - both are SQL_USER and
  both have a SID. Older versions are asked the same question a different way: a SID that no login
  answers to means there is no login behind the user.

  On 2008 and 2008 R2 that also catches a user whose login has since been dropped, which would be
  recreated here as WITHOUT LOGIN rather than mapped. The plan says which it is before anything is
  run, so it is visible rather than surprising.
#>
function Get-UserQuery([int] $MajorVersion) {
    $auth = if ($MajorVersion -ge 11) { 'dp.authentication_type_desc' }
            else { "CONVERT(nvarchar(60), CASE WHEN dp.sid IS NULL OR (dp.type = 'S' AND SUSER_SNAME(dp.sid) IS NULL) THEN 'NONE' ELSE 'INSTANCE' END)" }
    @"
SELECT  dp.name, dp.type, dp.type_desc, dp.default_schema_name,
        AuthType = $auth,
        HasSid = CONVERT(bit, CASE WHEN dp.sid IS NULL THEN 0 ELSE 1 END)
FROM sys.database_principals dp
WHERE dp.name = @p AND dp.type NOT IN ('R', 'A');
"@
}

<#
  Turns the numbers in a set of permission rows into the names the statements need.

  One query per class, each asked for only if its catalogue view is there, so an old instance
  answers what it can and says nothing about what it has never heard of. A row whose target cannot
  be named is marked unresolvable, and the caller reports it as not copied rather than writing a
  statement that would grant something else.
#>
function Resolve-PermissionTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [string] $DatabaseName = 'master'
    )

    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Rows) {
        $resolved.Add([pscustomobject]@{
            StateDesc = [string]$row['StateDesc']; PermissionName = [string]$row['PermissionName']
            ClassDesc = [string]$row['ClassDesc']; MajorId = [int]$row['MajorId']; MinorId = [int]$row['MinorId']
            SchemaName = ''; ObjectName = ''; ColumnName = ''; SubType = ''; Resolvable = $true
        })
    }

    foreach ($group in ($resolved | Where-Object { $_.MajorId -ne 0 } | Group-Object ClassDesc)) {
        $ids = @($group.Group | ForEach-Object { $_.MajorId })
        $query = New-TargetLookupQuery -ClassDesc $group.Name -Ids $ids
        if (-not $query) {
            foreach ($row in $group.Group) { $row.Resolvable = $false }
            continue
        }
        $names = @{}
        $schemas = @{}
        $subTypes = @{}
        try {
            foreach ($found in (Invoke-Sql -Server $Server -DatabaseName $DatabaseName -Query $query).Rows) {
                $id = [int]$found['MajorId']
                $names[$id] = [string]$found['ObjectName']
                if ($found['SchemaName'] -isnot [DBNull]) { $schemas[$id] = [string]$found['SchemaName'] }
                if ($found['SubType'] -isnot [DBNull]) { $subTypes[$id] = ([string]$found['SubType']).Trim() }
            }
        }
        catch { Write-Deep ('could not look up {0} targets: {1}' -f $group.Name, $_.Exception.Message) }

        foreach ($row in $group.Group) {
            if ($names.ContainsKey($row.MajorId)) {
                $row.ObjectName = $names[$row.MajorId]
                if ($schemas.ContainsKey($row.MajorId)) { $row.SchemaName = $schemas[$row.MajorId] }
                if ($subTypes.ContainsKey($row.MajorId)) { $row.SubType = $subTypes[$row.MajorId] }
            }
            else { $row.Resolvable = $false }
        }
    }

    # column permissions, the one case where minor_id means something
    $columnRows = @($resolved | Where-Object { $_.ClassDesc -eq 'OBJECT_OR_COLUMN' -and $_.MinorId -gt 0 -and $_.Resolvable })
    if ($columnRows.Count) {
        $where = @($columnRows | ForEach-Object { '(c.object_id = {0} AND c.column_id = {1})' -f $_.MajorId, $_.MinorId }) -join ' OR '
        $query = 'SELECT MajorId = c.object_id, MinorId = c.column_id, ColumnName = c.name FROM sys.columns c WHERE ' + $where + ';'
        $columns = @{}
        try {
            foreach ($found in (Invoke-Sql -Server $Server -DatabaseName $DatabaseName -Query $query).Rows) {
                $columns[('{0}.{1}' -f [int]$found['MajorId'], [int]$found['MinorId'])] = [string]$found['ColumnName']
            }
        }
        catch { Write-Deep ('could not look up column names: ' + $_.Exception.Message) }
        foreach ($row in $columnRows) {
            $key = '{0}.{1}' -f $row.MajorId, $row.MinorId
            if ($columns.ContainsKey($key)) { $row.ColumnName = $columns[$key] } else { $row.Resolvable = $false }
        }
    }

    $resolved.ToArray()
}

#==============================================================================
# Getting started
#==============================================================================
foreach ($required in 'SourceInstance', 'SourcePrincipal') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        Write-Host "  -$required is needed." -ForegroundColor Red
        Write-Host '  Try: Get-Help .\Copy-SqlAccess.ps1 -Detailed' -ForegroundColor Gray
        exit 2
    }
}
if (-not $DestinationInstance) { $DestinationInstance = $SourceInstance }
if (-not $Principal) { $Principal = $SourcePrincipal }
$SourceInstance = $SourceInstance.Trim()
$DestinationInstance = $DestinationInstance.Trim()
$SourcePrincipal = $SourcePrincipal.Trim()
$Principal = $Principal.Trim()

if ($SourceInstance -eq $DestinationInstance -and $SourcePrincipal -eq $Principal) {
    Write-Host '  The source and the target are the same principal on the same instance, so there is nothing to copy.' -ForegroundColor Red
    exit 2
}
if ($CopyPasswordAndSid -and $SourcePrincipal -ne $Principal) {
    Write-Host '  -CopyPasswordAndSid reproduces one principal on another instance, so it cannot be used when the names differ.' -ForegroundColor Red
    Write-Host '  A SID identifies a single principal; giving it to a second one would make them the same account.' -ForegroundColor Gray
    exit 2
}
if ($CopyPasswordAndSid -and $SourceInstance -eq $DestinationInstance) {
    Write-Host '  -CopyPasswordAndSid is for copying to another instance; that SID is already taken on this one.' -ForegroundColor Red
    exit 2
}

$databaseFilter = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($databaseFilter.Count -eq 1 -and $databaseFilter[0] -match ',') {
    # powershell.exe -File hands a comma-separated list over as one string
    $databaseFilter = @($databaseFilter[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$dryRun = ($WhatIfPreference -eq $true)
$runStart = Get-Date
$plan = New-Object System.Collections.Generic.List[object]      # Database, Statement, Note, Privileged
$skipped = New-Object System.Collections.Generic.List[object]
$owned = New-Object System.Collections.Generic.List[object]
$setupDone = $false
$applied = 0
$failed = 0
$script:ExitBad = $false

function Add-Plan([string] $Database, [string] $Statement, [string] $Note = '', [bool] $Privileged = $false,
                  [string] $Kind = 'Grant') {
    # Kind is how the apply knows what depends on what: everything in a database needs the user,
    # and the user needs the login
    $plan.Add([pscustomobject]@{ Database = $Database; Statement = $Statement; Note = $Note
                                 Privileged = $Privileged; Kind = $Kind })
}
function Add-Skip([string] $Where, [string] $What, [string] $Why) {
    $skipped.Add([pscustomobject]@{ Where = $Where; What = $What; Why = $Why })
}
function Get-FirstLine([string] $Text) { ($Text -split "`r?`n")[0] }

<#
  What the target already has, as the set of statements that would produce it.

  Re-granting something is harmless in SQL Server, but a plan full of grants the target already
  holds is a plan nobody reads, and it hides the two lines that matter. Comparing the statements
  rather than the rows means the comparison is exactly as good as the statements themselves.
#>
function Get-ExistingGrants {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Query, [string] $DatabaseName = 'master')

    $have = @{}
    try {
        $rows = @((Invoke-Sql -Server $DestinationInstance -DatabaseName $DatabaseName -Query $Query `
                   -Parameters @{ '@p' = $Principal }).Rows)
        foreach ($row in (Resolve-PermissionTargets -Server $DestinationInstance -DatabaseName $DatabaseName -Rows $rows)) {
            if (-not $row.Resolvable) { continue }
            $statement = New-PermissionStatement -Row $row -ToPrincipal $Principal
            if ($statement) { $have[$statement] = $true }
        }
    }
    catch { Write-Deep ('could not read what the target already has: ' + $_.Exception.Message) }
    $have
}

<#
  The plan in the order it was built, grouped by database.

  Order is not cosmetic here: the login has to exist before a database user can be created for it,
  and a user before anything can be granted to it. Group-Object does not promise to hand the groups
  back in the order it met them - it sorted master into the middle, so every statement failed on a
  principal that did not exist yet - so the order is kept here instead of being assumed.
#>
function Get-PlanGroups {
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($item in $plan) { if (-not $order.Contains($item.Database)) { $order.Add($item.Database) } }
    foreach ($name in $order) {
        [pscustomobject]@{ Name = $name; Group = @($plan | Where-Object { $_.Database -eq $name }) }
    }
}

try {
    Write-Log ('Copy the access of {0} on {1} to {2} on {3}' -f $SourcePrincipal, $SourceInstance, $Principal, $DestinationInstance)
    Write-Detail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName); log level $LogLevel"
    if ($dryRun) { Write-Log 'WhatIf: the plan is printed and nothing is changed.' -Level WARN }

    #region Both ends
    Start-Step 'Check both instances'
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
        throw ('cannot connect to ' + ($which -join ' and ') + '. The checks above say why.')
    }

    $facts = "SELECT EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')), " +
             "MajorVersion = CONVERT(int, PARSENAME(CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')), 4)), " +
             "ProductVersion = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion'))"
    $srcFacts = (Invoke-Sql -Server $SourceInstance -Query $facts).Rows[0]
    $dstFacts = (Invoke-Sql -Server $DestinationInstance -Query $facts).Rows[0]
    $srcEdition = [int]$srcFacts['EngineEdition']
    $dstEdition = [int]$dstFacts['EngineEdition']
    $srcMajor = [int]$srcFacts['MajorVersion']
    $dstMajor = [int]$dstFacts['MajorVersion']
    $srcIsAzureDb = ($srcEdition -in 5, 6, 9, 11)
    $dstIsAzureDb = ($dstEdition -in 5, 6, 9, 11)
    $hasServerLevel = (-not $srcIsAzureDb) -and (-not $dstIsAzureDb) -and (-not $SkipServerLevel)

    Write-Log ('Source:      {0}, {1} ({2})' -f $SourceInstance, (Get-EditionName $srcEdition), [string]$srcFacts['ProductVersion'])
    Write-Log ('Destination: {0}, {1} ({2})' -f $DestinationInstance, (Get-EditionName $dstEdition), [string]$dstFacts['ProductVersion'])
    if (($srcIsAzureDb -or $dstIsAzureDb) -and -not $SkipServerLevel) {
        Write-Log 'Azure SQL Database has no server level, so logins, server roles and server permissions are not part of this copy. Its principals live in the databases, and master is one of them.' -Level WARN
    }
    elseif ($SkipServerLevel) { Write-Detail '  -SkipServerLevel: database access only' }
    if ($dstMajor -gt 0 -and $dstMajor -lt 11) {
        Write-Log 'The destination is older than SQL Server 2012, so role memberships are added with the stored procedures rather than ALTER ROLE.' -Level WARN
    }
    Complete-Step
    #endregion

    #region Which databases
    Start-Step 'Find the databases the principal is in'
    if ($srcIsAzureDb -and $databaseFilter.Count) { $sourceDatabases = @($databaseFilter) }
    else {
        $query = if ($srcIsAzureDb) { 'SELECT name FROM sys.databases ORDER BY name' }
                 else { "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND (database_id = 1 OR database_id > 4) ORDER BY name" }
        $sourceDatabases = @((Invoke-Sql -Server $SourceInstance -Query $query).Rows | ForEach-Object { [string]$_['name'] })
    }
    if ($databaseFilter.Count) {
        $wanted = $databaseFilter
        $missing = @($wanted | Where-Object { $sourceDatabases -notcontains $_ })
        $sourceDatabases = @($sourceDatabases | Where-Object { $wanted -contains $_ })
        foreach ($m in $missing) { Add-Skip $m 'the whole database' 'not found on the source, or not online' }
    }
    Write-Detail ('  looking in: ' + ($sourceDatabases -join ', '))

    $userQuery = Get-UserQuery $srcMajor
    $inDatabases = New-Object System.Collections.Generic.List[object]
    foreach ($db in $sourceDatabases) {
        try {
            $user = Invoke-Sql -Server $SourceInstance -DatabaseName $db -Query $userQuery -Parameters @{ '@p' = $SourcePrincipal }
            if ($user.Rows.Count) { $inDatabases.Add([pscustomobject]@{ Database = $db; User = $user.Rows[0] }) }
        }
        catch { Add-Skip $db 'reading the user' (Get-FirstLine $_.Exception.GetBaseException().Message) }
    }
    Write-Log ('{0} is a user in {1} database(s){2}' -f $SourcePrincipal, $inDatabases.Count,
               $(if ($inDatabases.Count) { ': ' + (@($inDatabases | ForEach-Object { $_.Database }) -join ', ') } else { '' }))
    Complete-Step
    #endregion

    #region The server level
    $sourceLogin = $null
    if ($hasServerLevel) {
        Start-Step 'Read the login and its server-level access'
        $loginRows = Invoke-Sql -Server $SourceInstance -Query $LoginQuery -Parameters @{ '@p' = $SourcePrincipal }
        if ($loginRows.Rows.Count -eq 0) {
            # a role name gets here too, and "there is no login" would be a misleading way to say so
            $asRole = Get-Scalar -Server $SourceInstance -Parameters @{ '@p' = $SourcePrincipal } -Query `
                      "SELECT name FROM sys.server_principals WHERE name = @p AND type = 'R'"
            if ($asRole) { Write-Log ("'{0}' is a server role on the source, not a login." -f $SourcePrincipal) -Level WARN }
            else { Write-Log ("There is no login called '{0}' on the source, so this is a database user only." -f $SourcePrincipal) }
            Complete-Step -Result 'SKIPPED'
        }
        else {
            $sourceLogin = $loginRows.Rows[0]
            Write-Log ('The source login is a {0}{1}' -f [string]$sourceLogin['type_desc'],
                       $(if ([bool]$sourceLogin['is_disabled']) { ', disabled' } else { '' }))

            $already = Get-Scalar -Server $DestinationInstance -Query 'SELECT name FROM sys.server_principals WHERE name = @p' `
                                  -Parameters @{ '@p' = $Principal }
            if ($already) { Write-Log ("The login '{0}' is already on the destination, so it is left as it is." -f $Principal) }
            else {
                $passwordLiteral = ''
                $sid = ''
                $hashed = $false
                if ([string]$sourceLogin['type'] -eq 'S') {
                    if ($CopyPasswordAndSid) {
                        $passwordLiteral = ConvertTo-HexLiteral $sourceLogin['PasswordHash']
                        $sid = ConvertTo-HexLiteral $sourceLogin['Sid']
                        $hashed = $true
                        if (-not $passwordLiteral) {
                            Add-Skip 'server' ('login ' + $Principal) 'the password hash could not be read, which needs CONTROL SERVER or VIEW DEFINITION on the login'
                        }
                    }
                    elseif ($Password) { $passwordLiteral = ConvertTo-SqlPasswordLiteral $Password }
                }
                # the source's default database is mapped like any other, and dropped if it is not
                # there: a login created with a DEFAULT_DATABASE that does not exist simply fails,
                # and then so does everything that needed it
                $defaultDb = [string]$sourceLogin['default_database_name']
                if ($defaultDb) {
                    $mapped = Resolve-DatabaseName -Name $defaultDb -Map $DatabaseMap
                    $onDestination = Get-Scalar -Server $DestinationInstance -Parameters @{ '@p' = $mapped } `
                                                -Query 'SELECT name FROM sys.databases WHERE name = @p'
                    if ($onDestination) { $defaultDb = $mapped }
                    else {
                        Write-Log ("The source login's default database '{0}' is not on the destination, so the login is created with master as its default instead." -f $defaultDb) -Level WARN
                        $defaultDb = ''
                    }
                }
                $statement = New-PrincipalStatement -Name $Principal -Scope Login -TypeDesc ([string]$sourceLogin['type_desc']) `
                                -DefaultDatabase $defaultDb `
                                -PasswordLiteral $passwordLiteral -Sid $sid -Hashed:$hashed -AzureSqlDatabase:$dstIsAzureDb
                if ($statement) {
                    Add-Plan 'master' $statement ('create the login (' + [string]$sourceLogin['type_desc'] + ')') $false 'Login'
                    if ([bool]$sourceLogin['is_disabled']) {
                        Add-Plan 'master' ('ALTER LOGIN ' + (Esc-Name $Principal) + ' DISABLE;') 'the source login is disabled, so this one is too'
                    }
                }
                else {
                    Add-Skip 'server' ('login ' + $Principal) 'a SQL login needs a password: pass -Password, or -CopyPasswordAndSid to clone the same name onto another instance'
                }
            }

            $destinationRoles = @((Invoke-Sql -Server $DestinationInstance -Query `
                                  "SELECT name FROM sys.server_principals WHERE type = 'R'").Rows | ForEach-Object { [string]$_['name'] })
            $destinationMemberOf = @((Invoke-Sql -Server $DestinationInstance -Query $ServerRoleQuery -Parameters @{ '@p' = $Principal }).Rows |
                                     ForEach-Object { [string]$_['RoleName'] })
            foreach ($row in (Invoke-Sql -Server $SourceInstance -Query $ServerRoleQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
                $role = [string]$row['RoleName']
                $privileged = Test-PrivilegedGrant -RoleName $role
                if ($privileged -and -not $AllowPrivileged) {
                    Add-Skip 'server' ('server role ' + $role) 'this is control of the instance: pass -AllowPrivileged to copy it'
                    continue
                }
                if ($destinationMemberOf -contains $role) { Write-Detail "  already in the server role $role"; continue }
                if ($destinationRoles -notcontains $role) {
                    Add-Skip 'server' ('server role ' + $role) 'there is no server role of that name on the destination'
                    continue
                }
                Add-Plan 'master' (New-RoleMemberStatement -RoleName $role -MemberName $Principal -Scope Server -MajorVersion $dstMajor) `
                         ('server role ' + $role) $privileged
            }

            $have = if ($already) { Get-ExistingGrants -Query $ServerPermissionQuery } else { @{} }
            $serverRows = @((Invoke-Sql -Server $SourceInstance -Query $ServerPermissionQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows)
            foreach ($row in (Resolve-PermissionTargets -Server $SourceInstance -Rows $serverRows)) {
                $privileged = Test-PrivilegedGrant -PermissionName $row.PermissionName
                if ($privileged -and -not $AllowPrivileged) {
                    Add-Skip 'server' ($row.PermissionName + ' on the server') 'this is control of the instance: pass -AllowPrivileged to copy it'
                    continue
                }
                $statement = if ($row.Resolvable) { New-PermissionStatement -Row $row -ToPrincipal $Principal } else { $null }
                if ($statement -and $have.ContainsKey($statement)) { Write-Detail ('  already has ' + $statement); continue }
                if ($statement) { Add-Plan 'master' $statement ('server permission ' + $row.PermissionName) $privileged }
                else {
                    Add-Skip 'server' ('{0} on {1}' -f $row.PermissionName, $row.ClassDesc) `
                             'the thing it is granted on could not be named, so it is left out rather than guessed at'
                }
            }
            Complete-Step
        }
    }
    #endregion

    #region Each database
    foreach ($entry in $inDatabases) {
        $sourceDb = $entry.Database
        $targetDb = Resolve-DatabaseName -Name $sourceDb -Map $DatabaseMap
        $script:StepPrefix = $targetDb
        Start-Step 'Read and plan the database access'
        if ($targetDb -ne $sourceDb) { Write-Log ('mapped from {0}' -f $sourceDb) }

        $existing = $null
        try {
            $existing = Invoke-Sql -Server $DestinationInstance -DatabaseName $targetDb -Parameters @{ '@p' = $Principal } `
                                   -Query 'SELECT name FROM sys.database_principals WHERE name = @p'
        }
        catch {
            Add-Skip $targetDb 'the whole database' ('cannot be opened on the destination: ' + (Get-FirstLine $_.Exception.GetBaseException().Message))
            Complete-Step -Result 'FAILED'
            $script:StepPrefix = ''
            continue
        }

        $user = $entry.User
        if ($existing.Rows.Count) { Write-Detail ('  the user is already in {0}, so it is left as it is' -f $targetDb) }
        else {
            $forLogin = ''
            $authType = [string]$user['AuthType']
            if ([bool]$user['HasSid'] -and $authType -notin 'DATABASE', 'NONE', 'EXTERNAL' -and -not $dstIsAzureDb) { $forLogin = $Principal }
            $passwordLiteral = if ($Password) { ConvertTo-SqlPasswordLiteral $Password } else { '' }
            $statement = New-PrincipalStatement -Name $Principal -Scope User -TypeDesc ([string]$user['type_desc']) `
                            -DefaultSchema ([string]$user['default_schema_name']) -ForLogin $forLogin `
                            -PasswordLiteral $passwordLiteral -AuthType $authType -AzureSqlDatabase:$dstIsAzureDb
            if ($statement) { Add-Plan $targetDb $statement ('create the user (' + [string]$user['type_desc'] + ', ' + $authType + ')') $false 'User' }
            else {
                $why = if ([string]$user['type_desc'] -like '*MAPPED*') {
                           'a user mapped to a certificate or an asymmetric key has to be created against that certificate or key, which is not something this copies'
                       }
                       else { 'this user has its own password rather than a login behind it, so it needs one here too: pass -Password' }
                Add-Skip $targetDb ('user ' + $Principal) $why
            }
        }

        $destinationRoles = @((Invoke-Sql -Server $DestinationInstance -DatabaseName $targetDb -Query `
                              "SELECT name FROM sys.database_principals WHERE type = 'R'").Rows | ForEach-Object { [string]$_['name'] })
        $destinationMemberOf = @((Invoke-Sql -Server $DestinationInstance -DatabaseName $targetDb -Query $DatabaseRoleQuery `
                                 -Parameters @{ '@p' = $Principal }).Rows | ForEach-Object { [string]$_['RoleName'] })
        foreach ($row in (Invoke-Sql -Server $SourceInstance -DatabaseName $sourceDb -Query $DatabaseRoleQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
            $role = [string]$row['RoleName']
            $privileged = Test-PrivilegedGrant -RoleName $role
            if ($privileged -and -not $AllowPrivileged) {
                Add-Skip $targetDb ('database role ' + $role) 'this is control of the instance: pass -AllowPrivileged to copy it'
                continue
            }
            if ($destinationMemberOf -contains $role) { Write-Detail "  already in the role $role"; continue }
            if ($destinationRoles -notcontains $role) {
                Add-Skip $targetDb ('database role ' + $role) ('there is no role of that name in ' + $targetDb + ' on the destination')
                continue
            }
            Add-Plan $targetDb (New-RoleMemberStatement -RoleName $role -MemberName $Principal -Scope Database -MajorVersion $dstMajor) `
                     ('role ' + $role) $privileged
        }

        $have = if ($existing.Rows.Count) { Get-ExistingGrants -Query $DatabasePermissionQuery -DatabaseName $targetDb } else { @{} }
        $permissionRows = @((Invoke-Sql -Server $SourceInstance -DatabaseName $sourceDb -Query $DatabasePermissionQuery `
                            -Parameters @{ '@p' = $SourcePrincipal }).Rows)
        foreach ($row in (Resolve-PermissionTargets -Server $SourceInstance -DatabaseName $sourceDb -Rows $permissionRows)) {
            $privileged = Test-PrivilegedGrant -PermissionName $row.PermissionName
            if ($privileged -and -not $AllowPrivileged) {
                Add-Skip $targetDb ($row.PermissionName + ' in ' + $targetDb) 'this is control of the instance: pass -AllowPrivileged to copy it'
                continue
            }
            $statement = if ($row.Resolvable) { New-PermissionStatement -Row $row -ToPrincipal $Principal } else { $null }
            if ($statement -and $have.ContainsKey($statement)) { Write-Detail ('  already has ' + $statement); continue }
            if ($statement) {
                $on = if ($row.ObjectName) { $row.ObjectName } else { 'the database' }
                Add-Plan $targetDb $statement ('{0} on {1}' -f $row.PermissionName, $on) $privileged
            }
            else {
                Add-Skip $targetDb ('{0} on {1}' -f $row.PermissionName, $row.ClassDesc) `
                         'the thing it is granted on could not be named, so it is left out rather than guessed at'
            }
        }

        foreach ($row in (Invoke-Sql -Server $SourceInstance -DatabaseName $sourceDb -Query $OwnedQuery -Parameters @{ '@p' = $SourcePrincipal }).Rows) {
            $owned.Add([pscustomobject]@{ Database = $sourceDb; Kind = [string]$row['Kind']; Name = [string]$row['ObjectName'] })
        }
        Complete-Step
        $script:StepPrefix = ''
    }
    #endregion

    if ($inDatabases.Count -eq 0 -and -not $sourceLogin) {
        $isRole = Get-Scalar -Server $SourceInstance -Parameters @{ '@p' = $SourcePrincipal } -Query `
                  "SELECT name FROM sys.server_principals WHERE name = @p AND type = 'R'"
        if ($isRole) {
            Write-Log ("'{0}' is a server role, not a login or a user. This copies what a principal has, so name one of its members instead." -f $SourcePrincipal) -Level WARN
        }
        else {
            Write-Log ("Nothing found for '{0}' on {1}. Check the spelling, including the domain part, and that you can see it: the catalogue views show you only what your own permissions allow." -f $SourcePrincipal, $SourceInstance) -Level WARN
        }
    }
    $setupDone = $true

    #region The plan
    Write-Host ''
    Write-Log ('---- the plan: {0} statement(s) ----' -f $plan.Count) -Min Quiet
    foreach ($group in (Get-PlanGroups)) {
        Write-Log ('  in {0}:' -f $group.Name) -Min Quiet
        foreach ($item in $group.Group) {
            Write-Log ('    ' + (Hide-Secret $item.Statement) + $(if ($item.Privileged) { '    -- privileged' } else { '' })) -Min Quiet
        }
    }
    if ($plan.Count -eq 0) {
        Write-Log '  nothing to do: either there is no access to copy, or the target already has all of it' -Min Quiet
    }

    if ($skipped.Count) {
        Write-Host ''
        Write-Log ('---- not copied ({0}) ----' -f $skipped.Count) -Level WARN
        foreach ($item in $skipped) { Write-Log ('  {0}: {1} - {2}' -f $item.Where, $item.What, $item.Why) -Level WARN }
    }
    if ($owned.Count) {
        Write-Host ''
        Write-Log ('---- owned by {0}, which is not copied ----' -f $SourcePrincipal)
        foreach ($item in $owned) { Write-Log ('  {0}: {1} {2}' -f $item.Database, $item.Kind, $item.Name) }
        Write-Log '  ownership is a decision rather than an access right, so it is left alone. Move it with ALTER AUTHORIZATION if that is what you want.'
    }

    if ($ScriptPath) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('-- The access of ' + $SourcePrincipal + ' on ' + $SourceInstance)
        $lines.Add('-- copied to ' + $Principal + ' on ' + $DestinationInstance)
        $lines.Add('-- written ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' by Copy-SqlAccess.ps1')
        foreach ($group in (Get-PlanGroups)) {
            $lines.Add('')
            $lines.Add('USE ' + (Esc-Name $group.Name) + ';')
            $lines.Add('GO')
            foreach ($item in $group.Group) { $lines.Add($item.Statement) }
        }
        if ($skipped.Count) {
            $lines.Add('')
            foreach ($item in $skipped) { $lines.Add('-- NOT COPIED: ' + $item.Where + ': ' + $item.What + ' - ' + $item.Why) }
        }
        [System.IO.File]::WriteAllLines($ScriptPath, $lines.ToArray())
        Write-Host ''
        Write-Log "Script written to $ScriptPath"
        if (@($plan | Where-Object { $_.Statement -match '(?i)PASSWORD\s*=' }).Count) {
            Write-Log '  that file contains the password, because it has to be able to run. It is not in this log, and it should not stay on disk.' -Level WARN
        }
    }
    #endregion

    #region Do it
    if ($plan.Count -and -not $dryRun) {
        $privilegedCount = @($plan | Where-Object { $_.Privileged }).Count
        $ask = 'Apply {0} statement(s) to {1}, giving {2} the access {3} has on {4}?' -f `
               $plan.Count, $DestinationInstance, $Principal, $SourcePrincipal, $SourceInstance
        if ($privilegedCount) { $ask += ' {0} of them amount to control of the instance.' -f $privilegedCount }
        Write-Host ''
        if (-not (Confirm-Action $ask 'Copy access')) { throw 'nothing was applied' }

        # If the principal itself cannot be created there is no point issuing everything that would
        # be granted to it: twenty-five copies of "the user does not exist" bury the one error that
        # actually explains it.
        $abandoned = ''
        foreach ($group in (Get-PlanGroups)) {
            $script:StepPrefix = $group.Name
            Start-Step 'Apply'
            $failedHere = 0
            $stopHere = ''
            foreach ($item in $group.Group) {
                if ($abandoned -or $stopHere) {
                    Add-Skip $group.Name $item.Note ('not attempted: ' + $(if ($stopHere) { $stopHere } else { $abandoned }))
                    continue
                }
                try {
                    [void](Invoke-Sql -Server $DestinationInstance -DatabaseName $group.Name -Query $item.Statement)
                    $applied++
                    Write-Detail ('  ok: ' + (Hide-Secret $item.Statement))
                }
                catch {
                    $failed++
                    $failedHere++
                    $message = Get-FirstLine $_.Exception.GetBaseException().Message
                    Write-Log ('failed: ' + (Hide-Secret $item.Statement)) -Level ERROR
                    Write-Log ('  ' + $message) -Level ERROR
                    Add-Skip $group.Name $item.Note $message
                    if ($item.Kind -eq 'Login') {
                        $abandoned = 'the login could not be created'
                        Write-Log 'The login could not be created, so nothing that depends on it is attempted. Fix the error above and run this again; what did apply is left as it is.' -Level ERROR
                    }
                    elseif ($item.Kind -eq 'User') {
                        $stopHere = 'the user could not be created in ' + $group.Name
                        Write-Log ('The user could not be created in {0}, so the rest of that database is left alone.' -f $group.Name) -Level ERROR
                    }
                }
            }
            Complete-Step -Result $(if ($failedHere) { 'FAILED' } elseif ($abandoned -or $stopHere) { 'SKIPPED' } else { 'OK' })
            $script:StepPrefix = ''
        }
    }
    #endregion
}
catch {
    if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
    $exception = $_.Exception.GetBaseException()
    Write-Log (Get-FirstLine $exception.Message) -Level ERROR
    if ($exception -is [System.Data.SqlClient.SqlException]) {
        $explain = Get-SqlErrorExplanation -Number $exception.Number -Message $exception.Message
        if ($explain.Meaning) { Write-Log ('  what it means: ' + $explain.Meaning) -Level ERROR }
        if ($explain.Fix) { Write-Log ('  what to try: ' + $explain.Fix) -Level WARN }
    }
    Write-Deep ('full exception: ' + $exception.ToString())
    if ($_.ScriptStackTrace) { Write-Deep ('at: ' + $_.ScriptStackTrace) }
    $failed++
}
finally {
    $elapsed = (Get-Date) - $runStart
    Write-Host ''
    Write-Log '---------------- Run summary ----------------' -Min Quiet
    Write-Log ('From:         {0} on {1}' -f $SourcePrincipal, $SourceInstance) -Min Quiet
    Write-Log ('To:           {0} on {1}' -f $Principal, $DestinationInstance) -Min Quiet
    Write-Log ('Planned:      {0} statement(s) across {1} database(s)' -f $plan.Count, @(Get-PlanGroups).Count) -Min Quiet
    if (-not $dryRun) { Write-Log ('Applied:      {0}, failed {1}' -f $applied, $failed) -Min Quiet }
    if ($skipped.Count) { Write-Log ('Not copied:   {0} - listed above' -f $skipped.Count) -Level WARN -Min Quiet }
    if ($script:Level -ge $script:LevelRank['Normal']) {
        foreach ($step in $script:Steps) { Write-Log ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
    }
    $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
               elseif ($dryRun) { 'PLAN ONLY' }
               elseif ($failed -gt 0) { 'PARTLY DONE' }
               elseif ($applied -gt 0) { 'DONE' }
               else { 'NOTHING TO DO' }
    $broke = (-not $setupDone) -or ($failed -gt 0)
    $bad = $broke -or ($skipped.Count -gt 0)
    Write-Log ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) `
              -Level $(if ($broke) { 'ERROR' } elseif ($bad) { 'WARN' } else { 'INFO' }) -Min Quiet
    if ($script:LogFilePath) { Write-Log "Log file:     $script:LogFilePath" -Min Quiet }
    $script:ExitBad = $bad
}

if ($script:ExitBad) { exit 1 }
exit 0
