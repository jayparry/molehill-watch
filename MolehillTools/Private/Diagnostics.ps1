<#
    The plumbing three tools were each carrying their own copy of: logging at a level, timing the
    steps of a run, pulling an instance name apart, finding out whether a server is even reachable,
    and turning a SQL Server error number into a sentence about what to do.

    They were byte for byte identical in Copy-SqlAccess, Restore-DatabaseCopy and
    Restore-LatestAzureBackup, which is the whole argument for the module: one copy, one set of
    checks, and a fix in one place.

    The logging keeps state - what level to print at, which file to append to, the steps so far -
    so a tool calls Initialize-MhLog at the start of a run. Without it the defaults are Normal
    and no file, which is what a one-off call from a prompt wants.
#>

$script:MhLogRanks = @{ Quiet = 0; Normal = 1; Verbose = 2; Debug = 3 }
$script:MhLogLevel = 1
$script:MhLogFile = ''
$script:MhLogSteps = New-Object System.Collections.Generic.List[object]
$script:MhLogStep = $null
$script:MhLogTimer = $null
$script:MhLogPrefix = ''

<#
  Starts a run: the level to print at, where to append it, and an empty list of steps.

  -Verbose and -Debug raise the level on their own, so either way of asking works - which is why
  the caller passes its own $PSBoundParameters rather than being asked to work that out.
#>
function Initialize-MhLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $Level = 'Normal',
        [AllowEmptyString()] [string] $LogFile = '',
        [hashtable] $BoundParameters,
        [string] $Prefix = ''
    )

    if ($BoundParameters -and $BoundParameters.ContainsKey('Debug') -and $script:MhLogRanks[$Level] -lt 3) { $Level = 'Debug' }
    elseif ($VerbosePreference -ne 'SilentlyContinue' -and $script:MhLogRanks[$Level] -lt 2) { $Level = 'Verbose' }

    $script:MhLogLevel = $script:MhLogRanks[$Level]
    $script:MhLogFile = $LogFile
    $script:MhLogSteps = New-Object System.Collections.Generic.List[object]
    $script:MhLogStep = $null
    $script:MhLogTimer = $null
    $script:MhLogPrefix = $Prefix
}

<#
  The steps of the run so far, for the summary a tool prints at the end.

  Emitted one at a time rather than as the list: the module's convention is that callers wrap in
  @(), and ", $list" would hand them an array containing the list - which counts as one step
  whatever is in it. The checks below caught exactly that.
#>
function Get-MhLogStep { foreach ($step in $script:MhLogSteps) { $step } }

# what to put in front of every step name from here on, for a run that loops over databases
function Set-MhLogPrefix { param([AllowEmptyString()] [string] $Prefix) $script:MhLogPrefix = $Prefix }

function Write-MhDetail { param([string]$Message) Write-MhLog $Message -Min Verbose }
function Write-MhDeep   { param([string]$Message) Write-MhLog $Message -Min Debug }

function Write-MhLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')][string]$Min = 'Normal'
    )
    # problems are never hidden, however quiet you asked for
    $show = ($Level -ne 'INFO') -or ($script:MhLogLevel -ge $script:MhLogRanks[$Min])
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($show) {
        $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
        Write-Host $line -ForegroundColor $colour
    }
    if ($script:MhLogFile -and $show) {
        try { Add-Content -LiteralPath $script:MhLogFile -Value $line -WhatIf:$false }
        catch { Write-Host "(could not write to the log file: $($_.Exception.Message))" -ForegroundColor Yellow }
    }
}
function Start-MhStep {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:MhLogPrefix) { $Name = '{0}: {1}' -f $script:MhLogPrefix, $Name }
    $script:MhLogStep = $Name
    $script:MhLogTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-MhLog "START: $Name"
}
function Complete-MhStep {
    param([ValidateSet('OK', 'SKIPPED', 'FAILED')][string]$Result = 'OK')
    if (-not $script:MhLogStep) { return }
    $seconds = [math]::Round($script:MhLogTimer.Elapsed.TotalSeconds, 1)
    $script:MhLogSteps.Add([pscustomobject]@{ Step = $script:MhLogStep; Result = $Result; Seconds = $seconds })
    $level = if ($Result -eq 'FAILED') { 'ERROR' } else { 'INFO' }
    Write-MhLog "$($Result): $($script:MhLogStep) ($seconds s)" -Level $level
    $script:MhLogStep = $null
}

<#
  Pulls an instance string apart: SQL01, SQL01\SALES, SQL01,14330, sql01.contoso.com\SALES,1433,
  tcp:SQL01, (local), . and localhost all arrive here.
#>
function Split-MhSqlInstanceName {
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
function Get-MhSqlErrorExplanation {
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
function Test-MhReachedServer {
    [CmdletBinding()]
    param([int]$Number = 0, [AllowEmptyString()][string]$Message = '')

    if ($Number -gt 0) { return $true }
    # a TLS handshake, trusted or not, only happens once the server is talking
    if ($Message -match 'certificate|pre-login handshake|SSL Provider|encryption|Login failed|password') { return $true }
    $false
}
function Test-MhTcpPort {
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
function Get-MhSqlBrowserInstances {
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
function Test-MhSqlConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Instance,
        [PSCredential]$Credential,
        [switch]$Trust,
        [int]$TimeoutSeconds = 15
    )

    $parts = Split-MhSqlInstanceName -Instance $Instance
    $checks = New-Object System.Collections.Generic.List[object]

    Write-MhDetail ("  {0}: computer '{1}'{2}{3}" -f $Instance, $parts.Computer,
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

    Write-MhDeep ("  connection string: " + ($builder.ConnectionString -replace 'Password=[^;]*', 'Password=***'))
    $who = if ($Credential) { "SQL login '$($Credential.UserName)'" } else { "Windows account '$([Environment]::UserDomainName)\$([Environment]::UserName)'" }
    Write-MhDetail "  connecting as $who"

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
            Write-MhDeep ("  SqlException number {0}, state {1}, class {2}" -f $exception.Number, $exception.State, $exception.Class)
            foreach ($e in $exception.Errors) { Write-MhDeep ("    error {0}: {1}" -f $e.Number, $e.Message) }
        }
        Write-MhDeep ('  exception: ' + $exception.ToString())
        $failure = ($exception.Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' '
        $checks.Add([pscustomobject]@{ Name = 'login'; Ok = $false; Detail = $failure })
    }
    finally { $connection.Dispose() }

    if (-not $failure) {
        # it works; the name it resolved to is worth a line at Verbose, and nothing else is needed
        try {
            $addresses = @([System.Net.Dns]::GetHostAddresses($parts.Computer) | ForEach-Object { $_.IPAddressToString })
            Write-MhDetail ("  {0} resolves to {1}" -f $parts.Computer, ($addresses -join ', '))
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
    if (Test-MhReachedServer -Number $number -Message $failure) {
        Write-MhDetail '  SQL Server answered, so this is not a network problem'
        $explain = Get-MhSqlErrorExplanation -Number $number -Message $failure -Instance $Instance
        return [pscustomobject]@{
            Instance = $Instance; Parts = $parts; Checks = $checks.ToArray(); Connected = $false
            Meaning = $explain.Meaning; Fix = $explain.Fix; Error = $failure; Number = $number; Version = $null
        }
    }

    Write-MhDetail '  nothing answered, so checking the ground underneath it'

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
        $browser = @(Get-MhSqlBrowserInstances -Computer $parts.Computer)
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
        $tcp = Test-MhTcpPort -Computer $parts.Computer -Port $port -TimeoutMs ([Math]::Min($TimeoutSeconds, 10) * 1000)
        $checks.Add([pscustomobject]@{ Name = "TCP $port"; Ok = $tcp.Ok
            Detail = $(if ($tcp.Ok) { 'open' } else { $tcp.Error }) })
    }

    $explain = Get-MhSqlErrorExplanation -Number $number -Message $failure -Instance $Instance
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
function Write-MhConnectivityReport {
    param([Parameter(Mandatory)]$Result, [string]$Role)

    $label = "$Role $($Result.Instance)"
    if ($Result.Connected) {
        Write-MhLog "$label : connected - $($Result.Version)"
    }
    else {
        Write-MhLog "$label : NOT connected" -Level ERROR
    }
    foreach ($check in $Result.Checks) {
        $mark = if ($check.Ok) { 'ok  ' } else { 'FAIL' }
        $text = '    {0}  {1}{2}' -f $mark, $check.Name, $(if ($check.Detail) { " - $($check.Detail)" } else { '' })
        # a check that failed only matters when the connection did too: an instance on named pipes
        # or a dynamic port fails a TCP 1433 probe and works perfectly well
        if ($Result.Connected -or $check.Ok) { Write-MhLog $text -Min Verbose } else { Write-MhLog $text -Level WARN }
    }
    if (-not $Result.Connected) {
        if ($Result.Error)   { Write-MhLog "    what SQL Server said: $($Result.Error)" -Level ERROR }
        if ($Result.Meaning) { Write-MhLog "    what it means: $($Result.Meaning)" -Level ERROR }
        if ($Result.Fix)     { Write-MhLog "    what to try: $($Result.Fix)" -Level WARN }
        if ($Result.Error -match 'handshake|certificate|common algorithm|SSL|TLS|forcibly closed') {
            Write-MhLog ("    for the detail: .\Test-SqlTlsHandshake.ps1 '{0}'" -f $Result.Instance) -Level WARN
        }
    }
}

<#
  Asks before something there is no undo for.

  A scheduled run has no console to ask at, so rather than failing with PowerShell's own
  "NonInteractive mode" message it says what to pass instead.

  -Cmdlet is the caller's own $PSCmdlet: the prompt has to come from the cmdlet the user actually
  ran, and a function at module scope has no access to it. -Force and -DryRun are passed in for
  the same reason, which in the scripts these came from were read straight out of the caller.
#>
function Confirm-MhAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Caption = 'Are you sure?',
        $Cmdlet,
        [switch] $Force,
        [switch] $DryRun
    )

    if ($Force -or $DryRun) { return $true }
    try { return $Cmdlet.ShouldContinue($Message, $Caption) }
    catch {
        # the only way asking fails is having nobody to ask
        throw 'this would change a database and there is no console to confirm at. Run it where it can ask, or pass -Force when you already know you mean it.'
    }
}

Register-MhSelfTest -Name 'The shared diagnostics' -Test {
    # none of the three tools these came from checked any of this: the instance-name parsing and
    # the error explanations were the parts most worth checking and the parts nobody had
    Test-MhSection 'pulling an instance name apart'

    $p = Split-MhSqlInstanceName 'SQL01'
    Test-MhCheck 'a bare name is the default instance on 1433' ($p.Computer -eq 'SQL01' -and -not $p.Instance -and $p.Port -eq 1433)
    $p = Split-MhSqlInstanceName 'SQL01\SALES'
    Test-MhCheck 'a named instance has no port until Browser says' ($p.Computer -eq 'SQL01' -and $p.Instance -eq 'SALES' -and $p.Port -eq 0)
    $p = Split-MhSqlInstanceName 'SQL01,14330'
    Test-MhCheck 'a comma is a port' ($p.Computer -eq 'SQL01' -and $p.Port -eq 14330)
    $p = Split-MhSqlInstanceName 'tcp:sql01.contoso.com\SALES,1433'
    Test-MhCheck 'prefix, name, instance and port together' ($p.Computer -eq 'sql01.contoso.com' -and $p.Instance -eq 'SALES' -and $p.Port -eq 1433)
    foreach ($local in '.', '(local)', 'localhost', '') {
        $p = Split-MhSqlInstanceName $local
        Test-MhCheck "'$local' means this machine" ($p.Computer -eq 'localhost') $p.Computer
    }
    $p = Split-MhSqlInstanceName 'mymi.public.abc123.database.windows.net,3342'
    Test-MhCheck 'a managed instance public endpoint keeps its port' ($p.Port -eq 3342 -and $p.Computer -like '*.database.windows.net')
    $p = Split-MhSqlInstanceName 'SQL01,notaport'
    Test-MhCheck 'something that is not a port is not treated as one' ($p.Port -eq 1433) ("port $($p.Port), computer $($p.Computer)")

    Test-MhSection 'what a SQL Server error number means'

    $e = Get-MhSqlErrorExplanation -Number 18456 -Message 'Login failed for user. Reason: ... State: 8.'
    Test-MhCheck 'login failed names the state it was given' ($e.Meaning -match '18456' -and $e.Meaning -match 'password is wrong')
    $e = Get-MhSqlErrorExplanation -Number 18456 -Message 'Login failed for user. State: 5.'
    Test-MhCheck 'and a different state says something different' ($e.Meaning -match 'does not exist')
    $e = Get-MhSqlErrorExplanation -Number 233
    Test-MhCheck 'a closed handshake points at TCP/IP' ($e.Fix -match 'TCP/IP')
    $e = Get-MhSqlErrorExplanation -Number -2
    Test-MhCheck 'a timeout mentions the firewall that looks just like one' ($e.Fix -match 'firewall')
    $e = Get-MhSqlErrorExplanation -Number 40615
    Test-MhCheck 'an Azure firewall refusal says whose address to add' ($e.Fix -match 'public IP')
    $e = Get-MhSqlErrorExplanation -Number 999999 -Message 'something new'
    Test-MhCheck 'an error it has not met says nothing rather than guessing' ($null -ne $e -and -not $e.Meaning -and -not $e.Fix)

    Test-MhSection 'the log'

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "mh-log-$PID.txt"
    try {
        Initialize-MhLog -Level Quiet -LogFile $temp
        Write-MhLog 'ordinary progress'
        Write-MhLog 'something wrong' -Level ERROR
        Write-MhDetail 'only when asked for'
        $written = @(Get-Content -LiteralPath $temp -ErrorAction SilentlyContinue)
        Test-MhCheck 'a problem is written however quiet you asked for' (@($written | Where-Object { $_ -match 'something wrong' }).Count -eq 1)
        Test-MhCheck 'and ordinary progress is not' (-not @($written | Where-Object { $_ -match 'only when asked for' }).Count) ($written -join ' | ')

        Initialize-MhLog -Level Verbose -LogFile $temp
        Write-MhDetail 'now it is asked for'
        $written = @(Get-Content -LiteralPath $temp)
        Test-MhCheck 'at Verbose the detail is kept' (@($written | Where-Object { $_ -match 'now it is asked for' }).Count -eq 1)

        Initialize-MhLog -Level Quiet -LogFile $temp -Prefix 'Sales'
        Start-MhStep 'restoring'
        Complete-MhStep 'OK'
        Start-MhStep 'tidying'
        Complete-MhStep 'FAILED'
        $steps = @(Get-MhLogStep)
        Test-MhCheck 'each step is recorded once' ($steps.Count -eq 2) ("$($steps.Count) steps")
        Test-MhCheck 'with the result it was given' ($steps[0].Result -eq 'OK' -and $steps[1].Result -eq 'FAILED')
        Test-MhCheck 'and the prefix a looping run sets' ($steps[0].Step -eq 'Sales: restoring') $steps[0].Step
        Test-MhCheck 'how long each took is kept' ($null -ne $steps[0].Seconds)

        Complete-MhStep 'OK'
        Test-MhCheck 'finishing a step that never started records nothing' (@(Get-MhLogStep).Count -eq 2)

        Initialize-MhLog
        Test-MhCheck 'starting a run clears the last one' (-not @(Get-MhLogStep).Count)
        Test-MhCheck 'and stops writing to the old file' (-not $script:MhLogFile)
    }
    finally {
        Initialize-MhLog
        Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }

    Test-MhSection 'is anything listening'

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $open = Test-MhTcpPort -Computer '127.0.0.1' -Port $port -TimeoutMs 3000
        Test-MhCheck 'a port something is listening on is open' $open.Ok $open.Error
    }
    finally { $listener.Stop() }

    # the same port again, now that nothing is listening on it
    $shut = Test-MhTcpPort -Computer '127.0.0.1' -Port $port -TimeoutMs 3000
    Test-MhCheck 'and one nothing is listening on is not' (-not $shut.Ok)
    Test-MhCheck 'with the reason, not just a no' ([bool]$shut.Error) $shut.Error

    Test-MhSection 'asking before something irreversible'

    Test-MhCheck '-Force does not ask' (Confirm-MhAction -Message 'do it?' -Force)
    Test-MhCheck 'a dry run does not ask either' (Confirm-MhAction -Message 'do it?' -DryRun)
    $refused = ''
    try { $null = Confirm-MhAction -Message 'do it?' }
    catch { $refused = $_.Exception.Message }
    Test-MhCheck 'with nobody to ask it says what to pass instead' ($refused -match '-Force') $refused

    Test-MhSection 'did the failure even reach the server'

    # this decides whether the network probes are worth running at all, so getting it wrong means
    # a login problem is reported with a page about DNS
    Test-MhCheck 'a refused login proves the server answered' (Test-MhReachedServer -Number 18456)
    Test-MhCheck 'so does a rejected certificate' (Test-MhReachedServer -Message 'The certificate chain was issued by an authority that is not trusted')
    Test-MhCheck 'and a failed pre-login handshake' (Test-MhReachedServer -Message 'A connection was successfully established ... pre-login handshake')
    Test-MhCheck 'but a timeout did not reach it' (-not (Test-MhReachedServer -Message 'no answer within 5s (a firewall dropping packets looks like this)'))
    Test-MhCheck 'nor did a name that does not resolve' (-not (Test-MhReachedServer -Message 'No such host is known'))
}
