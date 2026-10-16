#Requires -Version 5.1

<#
.SYNOPSIS
    Clones a set of databases from Azure Blob Storage onto this SQL Server, restoring each one
    straight out of the container, then settling it: users dropped, owner set, recovery model set,
    the users you want added, encrypted, read-only last. Built to be one step of a SQL Agent job.

.DESCRIPTION
    Molehill Data Services | Clone-DatabasesFromBlob

    One file, no module, no Az modules, nothing to install. It needs Windows authentication to the
    instance and a managed identity that can read the container.

    Nothing is downloaded. Each backup is restored from its URL, which means the instance reads it
    out of the container itself and no staging disk is involved at all - so the server needs room
    for the database and nothing more.

    Two separate uses of the same managed identity, which is worth knowing when one of them fails:

      * this script lists the container over the Blob REST API, to find the newest backup for each
        database, with a token it asks the machine's own metadata service for. The identity needs
        Storage Blob Data Reader on the container for that.
      * SQL Server reads the backup itself, through a credential named after the container URL:

        CREATE CREDENTIAL [https://<account>.blob.core.windows.net/<container>]
            WITH IDENTITY = 'MANAGED IDENTITY';

        That credential is a one-off, and this refuses to start without it rather than failing
        inside RESTORE. SQL Server 2022 and later can use a managed identity this way; before
        that, the credential has to hold a shared access signature instead, and this script does
        not set one up.

    The copies keep the names they have in the backup, and the newest backup in each database's
    folder is the one restored - the container is the whole story, there is no msdb to ask.

    As each database lands, and before the next one is looked at, it is settled: the users it came
    with are dropped (except the built-in ones), the owner is set, the recovery model is set, and
    the users you asked for are added. A copy of production should not sit with production's users
    in it while the rest of the list restores.

    With -EnableTde, nothing is readable until it is encrypted:

      * the restore statement itself ends with SET RESTRICTED_USER, in the same batch, so there is
        no moment at which an unencrypted copy of production is online and open
      * encryption is started and the next database is begun. The scan is a background job and
        every database's can run at the same time; waiting for one before starting the next would
        be the slowest possible order
      * once every restore is done, this waits for all of the scans together, and lets people into
        each database as its own scan finishes - MULTI_USER, then read-only if you asked for it
      * a database whose scan has not finished when -TdeWaitMinutes runs out is left shut, and the
        two statements to run when it does finish are printed. It is not opened up and quietly left
        half encrypted.

    Exit code: 0 = every database done (or a clean -WhatIf), 1 = at least one failed, 2 = it could
    not start at all. For a SQL Agent job step, use CmdExec and let the exit code decide:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\Scripts\Clone-DatabasesFromBlob.ps1" -Database Sales,Stock -StorageAccountName mycompany -ContainerName backups -EnableTde -TdeCertificateName MySuperSecureCertificate

.PARAMETER DestinationInstance
    The instance to restore onto. Defaults to the default instance on this machine, which is what
    a job step on the box itself wants.

.PARAMETER Database
    The databases to clone. A comma separated list works when the job step passes it as one
    string, which is what powershell.exe -File does.

.PARAMETER StorageAccountName
    The storage account holding the backups.

.PARAMETER ContainerName
    The container inside it.

.PARAMETER BlobPathPattern
    Where each database's backups live inside the container, with {db} standing in for the name.
    Default: FULL/DAILY/{db}/ - the layout this was written for. '/' means a flat container.

.PARAMETER ManagedIdentityClientId
    The client id of a user-assigned managed identity. Leave it out for the system-assigned one.

.PARAMETER BlobEndpointSuffix
    For a cloud other than the public one, where the blob endpoint is not blob.core.windows.net.

.PARAMETER DataPath
    Where the data files go. The instance's own default data path if left out.

.PARAMETER LogPath
    Where the log files go. The instance's own default log path if left out.

.PARAMETER Owner
    Who owns each copy afterwards. Default sa. Falls back to the real system administrator account
    whatever it has been renamed to.

.PARAMETER RecoveryModel
    SIMPLE, FULL or BULK_LOGGED. Default SIMPLE, because a copy nobody backs up has no use for a
    log that keeps growing.

.PARAMETER AddUser
    Users to create afterwards, for logins that already exist. A plain name goes into every
    database; 'Sales:BiTeam:db_datareader' names one database, one user and its roles; a hashtable
    spells the three out. The string form is there because a job step cannot pass a hashtable.

.PARAMETER AddUserRole
    The roles for -AddUser entries that do not name their own. Without a role a user has no
    permissions at all.

.PARAMETER ReadOnly
    Set each copy read-only once everything else is done - which, with -EnableTde, means after its
    encryption has finished, because a read-only database cannot be changed any further.

.PARAMETER KeepUsers
    Leave the users that came with the backup alone.

.PARAMETER EnableTde
    Encrypt each copy with TDE (AES-256) as it lands, and wait for the scan to finish. The instance
    needs a database master key and a server certificate already - this refuses before anything is
    restored, with the statements to run, rather than creating keys whose backup nobody has taken.

.PARAMETER TdeCertificateName
    The server certificate protecting the encryption key.

.PARAMETER TdeWaitMinutes
    How long to wait, at the end of the run, for every encryption scan to finish. Default 60. It is
    one wait for all of them, not one each, because they run at the same time. A database still
    encrypting when it runs out is left shut rather than opened up half encrypted, and what to run
    when it does finish is printed.

.PARAMETER TrustServerCertificate
    Skip certificate validation on the connection to SQL Server, which an instance with a
    self-signed certificate and forced encryption needs.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for the connection. Default 15.

.PARAMETER Force
    Overwrite a database this instance has no record of having restored. Without it, a database of
    that name which did not come from here is left alone and reported.

.PARAMETER LogLevel
    Quiet, Normal, Verbose or Debug. Normal is right for a job: every step and every decision, and
    nothing else. -Verbose and -Debug raise it on their own.

.PARAMETER LogFile
    Append the run to this file as well as writing it out. A job step's output is captured by Agent
    anyway, so this is for keeping a copy somewhere a person will look.

.PARAMETER SelfTest
    Check the reasoning - which backup is chosen, where to look for it, who gets added to what, the
    statements built - with no Azure and no SQL Server at all.

.EXAMPLE
    .\Clone-DatabasesFromBlob.ps1 -Database Sales,Stock -StorageAccountName mycompany -ContainerName backups -WhatIf

    What it would do tonight, and nothing else.

.EXAMPLE
    .\Clone-DatabasesFromBlob.ps1 -Database Sales,Stock -StorageAccountName mycompany -ContainerName backups `
        -EnableTde -TdeCertificateName MySuperSecureCertificate

.EXAMPLE
    .\Clone-DatabasesFromBlob.ps1 -Database Sales -StorageAccountName mycompany -ContainerName backups `
        -AddUser 'REPORTS\BiTeam' -AddUserRole db_datareader -ReadOnly

.NOTES
    Molehill Data Services. It reads the container and writes to this instance; the backups are
    never changed, and nothing is deleted from the container.

    The generic version of this - any source, staged or direct, point-in-time, log chains - is
    Restore-MhLatestAzureBackup in MolehillTools. This one is deliberately only the job.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)] [string] $DestinationInstance = '.',
    [Parameter(Position = 1)] [Alias('DatabaseName')] [string[]] $Database,

    # the container. Not Mandatory on purpose: a missing Mandatory parameter makes PowerShell
    # prompt, and a prompt in a job step is a hang rather than a failure. They are checked below.
    [string] $StorageAccountName,
    [string] $ContainerName,
    [string] $BlobPathPattern = 'FULL/DAILY/{db}/',
    [string] $ManagedIdentityClientId,
    [string] $BlobEndpointSuffix = 'blob.core.windows.net',

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
    [switch] $EnableTde,
    [string] $TdeCertificateName = 'MolehillTde',
    [ValidateRange(1, 1440)] [int] $TdeWaitMinutes = 60,

    # connecting
    [switch] $TrustServerCertificate,
    [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,
    [switch] $Force,

    # saying what happened
    [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
    [string] $LogFile,
    [switch] $SelfTest
)

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

function Format-Size([double] $Bytes) {
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1TB) { return ([string]::Format($invariant, '{0:n1} TB', $Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ([string]::Format($invariant, '{0:n1} GB', $Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ([string]::Format($invariant, '{0:n0} MB', $Bytes / 1MB)) }
    [string]::Format($invariant, '{0:n0} KB', $Bytes / 1KB)
}

#==============================================================================
# Talking to SQL Server
#==============================================================================

<#
  Windows authentication only, on purpose: this runs as a job step, so the account SQL Server sees
  is the one Agent runs it as, and there is no password to keep anywhere for a script to read.
#>
function New-ConnectionString([string] $Server, [string] $DatabaseName, [int] $Timeout) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $DatabaseName
    $b['Integrated Security'] = $true
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'Clone-DatabasesFromBlob'
    if ($TrustServerCertificate) { $b['TrustServerCertificate'] = $true }
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
  Puts a timestamp into one known type, whatever shape it arrived in.

  The blob listing hands back a DateTimeOffset, SQL Server hands back a DateTime, and a date
  read out of a file can give either or a string. Letting PowerShell convert between them is the
  trap: the conversion goes through the string form in the machine's own culture, so code that
  works on one regional setting throws "Cannot convert the ... value of type System.DateTimeOffset
  to type System.DateTime" on another. Everything here is normalised to a UTC DateTimeOffset on the
  way in, parsed with the invariant culture, and compared as that type only.
#>
function ConvertTo-UtcTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $Value)

    if ($null -eq $Value) { throw 'no timestamp to convert' }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        throw ('expected one timestamp and was given {0} of them at once. That is a fault in whatever called this, not a date that cannot be read.' -f @($Value).Count)
    }
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

#==============================================================================
# The container, through the machine's managed identity
#==============================================================================

<#
  A token for the storage API from the machine's own identity.

  Asked of the instance metadata service directly rather than through Az.Accounts, because this has
  to run on a server where nothing can be installed. HttpWebRequest rather than Invoke-RestMethod
  for one reason: the proxy. A machine-wide proxy applies to Invoke-RestMethod by default and the
  metadata address must never go through one, which fails as a timeout that looks like "no managed
  identity" - so the proxy is turned off explicitly here.
#>
function Get-MiToken {
    [CmdletBinding()]
    param([string] $Resource = 'https://storage.azure.com/', [string] $ClientId, [int] $TimeoutSeconds = 20)

    $url = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=' +
           [uri]::EscapeDataString($Resource)
    if ($ClientId) { $url += '&client_id=' + [uri]::EscapeDataString($ClientId) }

    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.Headers.Add('Metadata', 'true')
    $request.Proxy = $null
    $request.Timeout = $TimeoutSeconds * 1000

    try {
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
    }
    catch {
        $detail = (($_.Exception.GetBaseException().Message -split "`r?`n")[0]).TrimEnd('.')
        throw ("could not get a token from the machine's managed identity: $detail. " +
               'This needs to run on an Azure VM or an Arc-enabled server with a managed identity assigned' +
               $(if ($ClientId) { " and -ManagedIdentityClientId $ClientId has to be one of them." } else { '.' }))
    }

    $token = ($body | ConvertFrom-Json).access_token
    if (-not $token) { throw 'the managed identity answered without a token, which should not happen' }
    Write-Deep ('  token for ' + $Resource + ' acquired, ' + $token.Length + ' characters')
    $token
}

# one request to the Blob REST API, with the two headers it insists on when the authorisation is a
# bearer token rather than a signature
function Invoke-BlobRest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Url, [Parameter(Mandatory)] [string] $Token, [int] $TimeoutSeconds = 60)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Headers.Add('Authorization', 'Bearer ' + $Token)
    $request.Headers.Add('x-ms-version', '2021-08-06')
    $request.Timeout = $TimeoutSeconds * 1000

    try {
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
    }
    catch [System.Net.WebException] {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $extra = switch ($status) {
            403 { ' The identity can reach the account but is not allowed to read it: it needs the Storage Blob Data Reader role on the container (the account''s own access keys are not used here).' }
            404 { ' There is no such account or container at that address.' }
            default { '' }
        }
        throw ('the container could not be listed (HTTP {0}).{1}' -f $status, $extra)
    }
}

<#
  Turns one page of the Blob REST API's answer into blobs and the marker for the next page.

  Separate from the request so that it can be checked against a real page of XML without a storage
  account - the parsing and the choosing that follows it are the parts that can be got wrong, and
  they were: see the note on Get-ContainerBlob below.
#>
function ConvertFrom-BlobListXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Xml)

    $document = [xml]$Xml
    $blobs = New-Object System.Collections.Generic.List[object]
    foreach ($blob in $document.EnumerationResults.Blobs.Blob) {
        $blobs.Add([pscustomobject]@{
            Name = [string]$blob.Name
            # a DateTimeOffset, parsed from RFC 1123 with the invariant culture, and never touched
            # as a string again: the machine's own date settings never get a say
            LastModified = [System.DateTimeOffset]::Parse([string]$blob.Properties.'Last-Modified',
                               [System.Globalization.CultureInfo]::InvariantCulture)
            Length = [long]$blob.Properties.'Content-Length'
        })
    }

    # an empty <NextMarker /> comes through the XML adapter as an element rather than as a string,
    # and anything but a real marker has to read as "no more pages" or the loop below never ends
    $marker = ''
    $next = $document.EnumerationResults.NextMarker
    if ($next -is [string]) { $marker = $next }
    elseif ($next -and $next.InnerText) { $marker = [string]$next.InnerText }

    [pscustomobject]@{ Blobs = $blobs.ToArray(); NextMarker = $marker.Trim() }
}

<#
  Every blob under a prefix, one at a time, following the continuation marker.

  Emitted one at a time rather than returned as a list: ", $list" hands the caller an array holding
  the array, and a caller that wraps the result in @() - as it should - then has one element that
  is all of the blobs. Which is how the first real run of this failed: the chooser read
  $_.LastModified off that one element, got all twenty-five timestamps at once, and reported that
  it could not make a date out of them. Every blob in the container, in one error message.

  A container with a few years of nightly backups in it holds more than one page of results, and a
  listing that stops at the first page quietly picks the newest of the first five thousand - which
  on a container listed in name order is not the newest at all.
#>
function Get-ContainerBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Account, [Parameter(Mandatory)] [string] $Container,
        [AllowEmptyString()] [string] $Prefix, [Parameter(Mandatory)] [string] $Token,
        [string] $EndpointSuffix = 'blob.core.windows.net'
    )

    $marker = ''
    $pages = 0
    $count = 0
    do {
        $url = 'https://{0}.{1}/{2}?restype=container&comp=list&maxresults=5000' -f $Account, $EndpointSuffix, $Container
        if ($Prefix) { $url += '&prefix=' + [uri]::EscapeDataString($Prefix) }
        if ($marker) { $url += '&marker=' + [uri]::EscapeDataString($marker) }

        $page = ConvertFrom-BlobListXml -Xml (Invoke-BlobRest -Url $url -Token $Token)
        $pages++
        foreach ($blob in $page.Blobs) {
            $count++
            $blob
        }
        $marker = $page.NextMarker
    } while ($marker)

    Write-Deep ('  listed {0} blob(s) under ''{1}'' in {2} page(s)' -f $count, $Prefix, $pages)
}

# the URL SQL Server restores from. Each segment is escaped, the slashes between them are not: a
# backup file with a space in its name is otherwise a 404 inside RESTORE.
function Get-BlobUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Account, [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $BlobName, [string] $EndpointSuffix = 'blob.core.windows.net'
    )

    $path = (($BlobName -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    'https://{0}.{1}/{2}/{3}' -f $Account, $EndpointSuffix, $Container, $path
}

# the one-off a server needs before it can read a container by identity
function New-BlobCredentialStatement {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ContainerUrl)
    "CREATE CREDENTIAL {0} WITH IDENTITY = 'MANAGED IDENTITY';" -f (Esc-Name $ContainerUrl)
}

<#
  Whether SQL Server has the credential it will need for this container.

  Checked before anything is restored, because the alternative is finding out inside RESTORE, where
  it arrives as "Cannot open backup device ... Operating system error 86 (The specified network
  password is not correct)" - which is a sentence about nothing at all.

  SQL Server matches a credential to a URL by longest prefix, so one named for the account works
  for every container in it; both names are accepted here for that reason.
#>
function Test-BlobCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $Account,
        [Parameter(Mandatory)] [string] $Container, [string] $EndpointSuffix = 'blob.core.windows.net'
    )

    $containerUrl = 'https://{0}.{1}/{2}' -f $Account, $EndpointSuffix, $Container
    $accountUrl = 'https://{0}.{1}' -f $Account, $EndpointSuffix

    $rows = @((Invoke-Sql -Server $Server -Parameters @{ '@c' = $containerUrl; '@a' = $accountUrl } -Query @'
SELECT name, credential_identity
FROM sys.credentials
WHERE name = @c OR name = @a
ORDER BY LEN(name) DESC
'@).Rows)

    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Found = $false; Name = $null; Identity = $null
                                  ContainerUrl = $containerUrl; Statement = (New-BlobCredentialStatement $containerUrl) }
    }
    [pscustomobject]@{
        Found = $true; Name = [string]$rows[0]['name']; Identity = [string]$rows[0]['credential_identity']
        ContainerUrl = $containerUrl; Statement = (New-BlobCredentialStatement $containerUrl)
    }
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

    foreach ($blob in $Blobs) {
        if ($blob -isnot [string] -and $blob -is [System.Collections.IEnumerable]) {
            throw ('the blobs were handed over as one element holding {0} of them, rather than one at a time. That is a fault in whatever called this: a container full of backups would otherwise be reported as having none.' -f @($blob).Count)
        }
    }

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

#==============================================================================
# The restore itself
#==============================================================================

<#
  Where one file out of the backup should land: the log file to the log path, everything else -
  data and FILESTREAM - to the data path, keeping the name it has inside the backup.

  The generic version of this renames the file when the copy is restored under a different name.
  Here the copies keep the name they have in the backup, so there is nothing to rename and nothing
  for a renamed file to collide with.
#>
function Get-MoveTarget {
    [CmdletBinding()]
    param([string] $PhysicalName, [string] $FileType, [string] $DataPath, [string] $LogPath)

    $leaf = Split-Path -Leaf $PhysicalName
    $folder = if ($FileType -eq 'L') { $LogPath } else { $DataPath }
    ($folder.TrimEnd('\') + '\' + $leaf)
}

<#
  Builds the one RESTORE this job ever runs: a full backup, read straight out of the container,
  brought online, with its files moved to where this instance keeps them.

  Separate from running it so that -WhatIf can print exactly what would have run, and so the self
  test can check the awkward parts without a server.
#>
function New-RestoreCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Database,
        [Parameter(Mandatory)] $BackupSet,          # Urls, Position, HasChecksums
        $MoveList,                                   # @{ LogicalName = TargetPath }
        [switch] $Replace,
        # shuts the database to everyone but its owners in the same batch as the restore, so there
        # is no moment at which a copy of production is online, unencrypted and open. A separate
        # statement afterwards would leave exactly that moment, however short.
        [switch] $RestrictAccess
    )

    $devices = (@($BackupSet.Urls) | ForEach-Object { "URL = N'" + (Esc-Str $_) + "'" }) -join ",`r`n     "

    $with = New-Object System.Collections.Generic.List[string]
    $with.Add('FILE = ' + [int]$BackupSet.Position)
    if ($MoveList) {
        foreach ($logical in ($MoveList.Keys | Sort-Object)) {
            $with.Add("MOVE N'" + (Esc-Str $logical) + "' TO N'" + (Esc-Str $MoveList[$logical]) + "'")
        }
    }
    if ($Replace) { $with.Add('REPLACE') }
    $with.Add('RECOVERY')
    if ($BackupSet.HasChecksums) { $with.Add('CHECKSUM') }
    $with.Add('STATS = 5')

    $statement = "RESTORE DATABASE {0}`r`nFROM {1}`r`nWITH {2};" -f (Esc-Name $Database), $devices, ($with -join ",`r`n     ")
    if ($RestrictAccess) {
        $statement += "`r`nALTER DATABASE {0} SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;" -f (Esc-Name $Database)
    }
    $statement
}

<#
  Reads the header of a backup set given as one or more URLs.

  A striped backup is one backup written across several files, and HEADERONLY on one file of a set
  does not report "this is striped" - it refuses, because the media set is incomplete. So the
  caller tries the one blob it chose, and on that refusal tries again with the blobs written beside
  it. Getting this wrong means a restore that fails after taking the existing copy offline.
#>
function Read-BackupHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string[]] $Urls)

    $devices = (@($Urls) | ForEach-Object { "URL = N'" + (Esc-Str $_) + "'" }) -join ', '
    Invoke-Sql -Server $Server -Query "RESTORE HEADERONLY FROM $devices"
}

#==============================================================================
# What happens to each copy once it is here
#==============================================================================

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

<#
  Whether an instance can encrypt a database with a certificate of its own, worked out from facts
  rather than from a connection so that the reasoning is testable.

  SQL Server 2019 brought TDE to Standard; before that it needs Enterprise, Developer or
  Evaluation. Express has never had it and still does not - on 2025 Express the engine answers
  CREATE DATABASE ENCRYPTION KEY with "Transparent Data Encryption is not available in the edition
  of this SQL Server instance", which is worth knowing before a database is restored rather than
  after. The rest is about the keys, and the chain behind them is what makes encryption
  open without anyone typing a password at startup: the database encryption key is protected by a
  server certificate, the certificate's private key by the database master key in master, and that
  by the service master key. Break any link and the database will not come online.

  Azure manages all of this itself, so there a certificate of your own is the wrong answer rather
  than a missing one.
#>
function Get-TdeProblem {
    [CmdletBinding()]
    param(
        [int] $EngineEdition, [int] $MajorVersion, [AllowEmptyString()] [string] $Edition,
        [bool] $HasMasterKey, [AllowEmptyString()] [string] $CertificateName,
        [AllowEmptyString()] [string] $FoundCertificate, [AllowEmptyString()] [string] $PrivateKeyType
    )

    $problems = New-Object System.Collections.Generic.List[string]

    if ($EngineEdition -in 5, 6, 9, 11) {
        $problems.Add('this is Azure SQL Database, where encryption at rest is managed by the platform and there is no certificate of yours to protect anything with. Leave -EnableTde off.')
    }
    elseif ($EngineEdition -eq 8) {
        $problems.Add('this is Azure SQL Managed Instance, which holds the keys itself: databases are encrypted by the instance rather than by a certificate you create. Leave -EnableTde off.')
    }
    elseif ($EngineEdition -in 1, 4) {
        $problems.Add(("{0} does not have TDE at any version: the engine refuses to create a database encryption key outright. It needs Standard, Enterprise, Developer or Evaluation." -f
                       $(if ($Edition) { $Edition } else { 'This edition' })))
    }
    elseif ($MajorVersion -gt 0 -and $MajorVersion -lt 15 -and $EngineEdition -ne 3) {
        $problems.Add(("TDE needs Enterprise, Developer or Evaluation edition before SQL Server 2019, and this is {0} (major version {1}). 2019 brought it to Standard as well." -f
                       $(if ($Edition) { $Edition } else { 'another edition' }), $MajorVersion))
    }

    if (-not $HasMasterKey) {
        $problems.Add("there is no database master key in master. Create one, back it up and keep the password: CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<a long random string>';")
    }
    if (-not $FoundCertificate) {
        $problems.Add(("there is no certificate called '{0}' in master. Create it, then back it up WITH PRIVATE KEY before anything is encrypted with it: CREATE CERTIFICATE {1} WITH SUBJECT = 'TDE certificate for restored copies';" -f
                       $CertificateName, (Esc-Name $CertificateName)))
    }
    elseif ($PrivateKeyType -eq 'NO_PRIVATE_KEY') {
        $problems.Add(("the certificate '{0}' has no private key, so it cannot protect a database encryption key. It was restored from a .cer without its .pvk; restore it again WITH PRIVATE KEY." -f $CertificateName))
    }
    elseif ($PrivateKeyType -eq 'ENCRYPTED_BY_PASSWORD') {
        $problems.Add(("the private key of '{0}' is protected by a password rather than by the database master key, so SQL Server cannot open it unattended. Re-import it so the master key protects it." -f $CertificateName))
    }

    $problems.ToArray()
}

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

<#
  Asks the destination the questions Get-TdeProblem needs answered.
#>
function Test-TdeReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $CertificateName)

    $query = @'
SELECT  EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')),
        Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')),
        Edition = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
        HasMasterKey = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END),
        CertFound = ISNULL((SELECT TOP (1) c.name FROM sys.certificates c WHERE c.name = @cert), ''),
        KeyType = ISNULL((SELECT TOP (1) c.pvt_key_encryption_type_desc FROM sys.certificates c WHERE c.name = @cert), ''),
        Thumbprint = ISNULL((SELECT TOP (1) CONVERT(varchar(80), c.thumbprint, 1) FROM sys.certificates c WHERE c.name = @cert), ''),
        Subject = ISNULL((SELECT TOP (1) c.subject FROM sys.certificates c WHERE c.name = @cert), ''),
        Expiry = (SELECT TOP (1) c.expiry_date FROM sys.certificates c WHERE c.name = @cert)
'@
    $facts = (Invoke-Sql -Server $Server -Parameters @{ '@cert' = $CertificateName } -Query $query).Rows[0]

    $problems = @(Get-TdeProblem -EngineEdition ([int]$facts['EngineEdition']) -MajorVersion ([int]$facts['Major']) `
                                 -Edition ([string]$facts['Edition']) -HasMasterKey ([bool]$facts['HasMasterKey']) `
                                 -CertificateName $CertificateName -FoundCertificate ([string]$facts['CertFound']) `
                                 -PrivateKeyType ([string]$facts['KeyType']))
    [pscustomobject]@{
        Ok         = ($problems.Count -eq 0)
        Problems   = $problems
        Subject    = [string]$facts['Subject']
        Thumbprint = [string]$facts['Thumbprint']
        Expiry     = $(if ($facts['Expiry'] -is [DBNull]) { $null } else { $facts['Expiry'] })
    }
}

<#
  Starts the encryption and does not wait for it.

  Encrypting is a background scan: SET ENCRYPTION ON returns at once and the pages are encrypted
  afterwards, at whatever rate the server can manage. Waiting for each database in turn would mean
  the last one in the list starting its scan only once every earlier scan had finished, which is
  the slowest possible order - they run perfectly well at the same time. So every database is
  started, and the waiting happens once, at the end, for all of them.
#>
function Start-DatabaseEncryption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
        [Parameter(Mandatory)] [string] $CertificateName
    )

    $already = @(Get-EncryptionProgress -Server $Server -DatabaseName $DatabaseName)
    if ($already.Count -and $already[0].State -eq 3) {
        Write-Detail '  it is encrypted already'
        return [pscustomobject]@{ Started = $false; Already = $true }
    }

    if ($already.Count -eq 0) {
        Write-Detail ('  creating the database encryption key, protected by the certificate ' + $CertificateName)
        # this one has to run inside the database: there is no way to qualify it from master
        [void](Invoke-Sql -Server $Server -DatabaseName $DatabaseName -Query `
               ('CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE ' + (Esc-Name $CertificateName) + ';'))
    }
    else { Write-Detail '  the encryption key is already there, so only the encryption needs turning on' }

    Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName -Statement 'ALTER DATABASE {DB} SET ENCRYPTION ON;'
    [pscustomobject]@{ Started = $true; Already = $false }
}

<#
  Where each database has got to with its encryption: one query for all of them, because the
  waiting below asks again every few seconds.

  encryption_state is the answer: 1 unencrypted, 2 encrypting, 3 encrypted, 4 changing key, 5
  decrypting - and no row at all means the database has no encryption key yet.

  sys.dm_database_encryption_keys is server-scoped, so this is asked from master about the
  databases rather than from inside each one. The rows are turned into plain objects here, where
  the DataRow handling is in one place: when this was asked for through a scriptblock the same
  expression came back as an Int32, every poll read the state as 0, and a database that had
  finished encrypting in a tenth of a second looked like one stuck at 0% until the wait timed out.
#>
function Get-EncryptionProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string[]] $DatabaseName)

    # a parameter per name rather than the names pasted into the statement: a database name is an
    # identifier and may contain anything at all
    $parameters = @{}
    $placeholders = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $DatabaseName.Count; $i++) {
        $parameters["@d$i"] = $DatabaseName[$i]
        $placeholders.Add("@d$i")
    }

    $query = @"
SELECT  DatabaseName = DB_NAME(k.database_id), k.encryption_state, k.percent_complete,
        k.key_algorithm, k.key_length
FROM sys.dm_database_encryption_keys AS k
WHERE DB_NAME(k.database_id) IN ($($placeholders -join ', '))
"@
    foreach ($row in (Invoke-Sql -Server $Server -Query $query -Parameters $parameters).Rows) {
        [pscustomobject]@{
            Name      = [string]$row['DatabaseName']
            State     = [int]$row['encryption_state']
            Percent   = [double]$row['percent_complete']
            Algorithm = [string]$row['key_algorithm']
            KeyLength = [int]$row['key_length']
        }
    }
}

# what each state is called, so a log line says something rather than a number
function Get-EncryptionStateName {
    [CmdletBinding()]
    param([int] $State)
    switch ($State) {
        1 { 'not encrypted' }
        2 { 'encrypting' }
        3 { 'encrypted' }
        4 { 'changing its key' }
        5 { 'being decrypted' }
        default { "state $State" }
    }
}

<#
  One line saying where every database has got to, for the log while the scans run.

  A name with no row at all has not started its scan yet, which is worth saying rather than
  leaving out: "Stock no key yet" is a fact, a missing Stock is a mystery.
#>
function Format-EncryptionProgress {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Progress, [AllowEmptyCollection()] [string[]] $Expected = @())

    $byName = @{}
    foreach ($one in $Progress) { $byName[$one.Name] = $one }
    $names = @($Expected)
    if (-not $names.Count) { $names = @($Progress | ForEach-Object { $_.Name }) }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $one = $byName[$name]
        if (-not $one) { $parts.Add("$name no key yet"); continue }
        if ($one.State -eq 2) { $parts.Add(('{0} {1}%' -f $name, [math]::Round($one.Percent, 1))); continue }
        $parts.Add(('{0} {1}' -f $name, (Get-EncryptionStateName $one.State)))
    }
    $parts -join ', '
}

<#
  Waits for every database that is encrypting, together, and says what happened to each.

  The scans are what they are: a big database takes as long as it takes, and nothing here makes it
  faster. What this does is stop the run finishing while a copy is still half encrypted, because
  until it is encrypted nobody is allowed into it.

  A scan that never moved at all is reported as that rather than as a timeout: "0%, and it never
  moved" is a different morning from "68% and still going", and the first one means something else
  is wrong - or that the database has no encryption key and never started.

  Whether it moved is measured against the first reading rather than against a clock, which is the
  honest comparison: a database with no row at all has not started, and one that is still at the
  percentage it began at has not moved, however long or short the wait was.
#>
function Wait-DatabaseEncryption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string[]] $DatabaseName,
        [ValidateRange(1, 1440)] [int] $WaitMinutes = 60,
        [ValidateRange(1, 60)] [int] $PollSeconds = 5
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $startedAt = @{}
    $said = [datetime]::MinValue
    $progress = @()

    while ($true) {
        $progress = @(Get-EncryptionProgress -Server $Server -DatabaseName $DatabaseName)

        # where each one was the first time it was looked at, to compare against at the end
        foreach ($name in $DatabaseName) {
            if ($startedAt.ContainsKey($name)) { continue }
            $one = $null
            foreach ($candidate in $progress) { if ($candidate.Name -eq $name) { $one = $candidate } }
            $startedAt[$name] = $(if (-not $one) { -1 } elseif ($one.State -eq 3) { 100 } else { $one.Percent })
        }

        # written out rather than filtered with Where-Object: inside that filter $_ is the name
        # being tested and also, confusingly, the row being compared, which is how this went wrong
        # the first time. A database is still pending if it has no row, or its row is not state 3.
        $pending = @()
        foreach ($name in $DatabaseName) {
            $one = $null
            foreach ($candidate in $progress) { if ($candidate.Name -eq $name) { $one = $candidate } }
            if (-not $one -or $one.State -ne 3) { $pending += $name }
        }

        if ($pending.Count -eq 0) { break }
        if ((Get-Date) -ge $deadline) { break }

        if (((Get-Date) - $said).TotalSeconds -ge 15) {
            Write-Log ('  encrypting: {0} (after {1}s)' -f (Format-EncryptionProgress -Progress $progress -Expected $pending),
                       [math]::Round($timer.Elapsed.TotalSeconds))
            $said = Get-Date
        }
        Start-Sleep -Seconds $PollSeconds
    }

    foreach ($name in $DatabaseName) {
        $one = $null
        foreach ($candidate in $progress) { if ($candidate.Name -eq $name) { $one = $candidate } }
        $encrypted = [bool]($one -and $one.State -eq 3)
        $now = $(if (-not $one) { -1 } elseif ($encrypted) { 100 } else { $one.Percent })
        [pscustomobject]@{
            Name      = $name
            Encrypted = $encrypted
            State     = $(if ($one) { $one.State } else { 0 })
            Percent   = $(if ($now -lt 0) { 0 } else { [math]::Round($now, 1) })
            Algorithm = $(if ($one) { $one.Algorithm } else { '' })
            KeyLength = $(if ($one) { $one.KeyLength } else { 0 })
            Seconds   = [math]::Round($timer.Elapsed.TotalSeconds, 1)
            # it never moved: either there is still no encryption key, or it is exactly where it
            # was when the waiting started
            Stalled   = [bool]((-not $encrypted) -and $now -le $startedAt[$name])
        }
    }
}

<#
  Lets people in, now that there is nothing left to hide.

  MULTI_USER first and read-only second: a read-only database cannot be changed any further, so the
  order cannot be the other way round.
#>
function Open-RestoredDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
        [switch] $ReadOnly
    )

    Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName -Statement 'ALTER DATABASE {DB} SET MULTI_USER;'
    Write-Log 'Open to everyone who has a user in it'

    if (-not $ReadOnly) { return }

    # AUTO_CLOSE undoes read-only: a database that closes and reopens comes back read-write, so the
    # setting looks applied and then quietly is not
    $autoClose = Get-Scalar -Server $Server -Parameters @{ '@db' = $DatabaseName } -Query `
                 'SELECT is_auto_close_on FROM sys.databases WHERE name = @db'
    if ($autoClose -and [bool]$autoClose) {
        Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName -Statement 'ALTER DATABASE {DB} SET AUTO_CLOSE OFF;'
        Write-Log 'Turned AUTO_CLOSE off first: with it on, the database reverts to read-write the next time it is opened' -Level WARN
    }

    Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName -Statement 'ALTER DATABASE {DB} SET READ_ONLY WITH ROLLBACK IMMEDIATE;'

    # and prove it took, rather than reporting the statement that was sent
    $nowReadOnly = Get-Scalar -Server $Server -Parameters @{ '@db' = $DatabaseName } -Query `
                   'SELECT is_read_only FROM sys.databases WHERE name = @db'
    if (-not ($nowReadOnly -and [bool]$nowReadOnly)) {
        throw 'the database did not stay read-only. Something else is holding it read-write; check AUTO_CLOSE and whether anything is reopening it.'
    }
    Write-Log 'Set read-only'
}

# what it actually is now, asked of the server rather than assumed from what was sent
function Write-DatabaseState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName, $Outcome)

    # -DatabaseName matters: sys.database_principals is scoped to the connection's database, so
    # without it this counts master's users instead of this one's
    $final = (Invoke-Sql -Server $Server -DatabaseName $DatabaseName -Parameters @{ '@db' = $DatabaseName } -Query `
              'SELECT recovery_model_desc, is_read_only, user_access_desc, Owner = SUSER_SNAME(owner_sid), Users = (SELECT COUNT(*) FROM sys.database_principals WHERE type IN (''S'',''U'',''G'') AND principal_id > 4), Encryption = ISNULL((SELECT TOP (1) k.encryption_state FROM sys.dm_database_encryption_keys k WHERE k.database_id = DB_ID(@db)), 0) FROM sys.databases WHERE name = @db').Rows[0]

    Write-Log ('{0} is now: owner {1}, recovery {2}, {3}, {4}, {5}, {6} user(s) besides the built-in ones' -f
               $DatabaseName, $final['Owner'], $final['recovery_model_desc'],
               ([string]$final['user_access_desc']).ToLower().Replace('_', ' '),
               $(if ([bool]$final['is_read_only']) { 'read-only' } else { 'read-write' }),
               (Get-EncryptionStateName ([int]$final['Encryption'])), $final['Users'])
    if ($Outcome) { $Outcome.Users = '{0} left' -f $final['Users'] }
}

<#
  Everything that happens to a copy as it lands, for one database, except letting anyone into it.

  This runs as each database is restored rather than once at the end, so a copy of production does
  not sit with the users it came with still in it while the rest of the list restores.

  What is not here: the encryption and the opening up. Encryption is started by the caller and
  waited for once, at the end, for every database together - and until a database is encrypted it
  stays shut, which is the whole point of restricting it in the restore itself.
#>
function Complete-RestoredDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
        [Parameter(Mandatory)] $Outcome, $OwnerLogin,
        [AllowEmptyCollection()] [object[]] $Grants = @()
    )

    if (-not $KeepUsers) {
        Start-Step 'Clear out the users it came with'
        $users = Clear-DatabaseUser -Server $Server -DatabaseName $DatabaseName
        foreach ($moved in $users.Handover) { Write-Detail ('  ' + $moved) }
        if ($users.Dropped.Count) { Write-Log ('Dropped {0} user(s): {1}' -f $users.Dropped.Count, ($users.Dropped -join ', ')) }
        else { Write-Log 'No users to drop; only the built-in ones were there' }
        foreach ($kept in $users.Kept) { Write-Log ('Could not drop ' + $kept) -Level WARN }
        $Outcome.Users = '{0} dropped' -f $users.Dropped.Count
        Complete-Step
    }

    if ($OwnerLogin -and $OwnerLogin.Login) {
        Start-Step ('Set the owner to {0}' -f $OwnerLogin.Login)
        if ($OwnerLogin.Substituted) {
            Write-Log ("There is no login called '{0}' here, so the owner is {1}, which is this instance's own system administrator account" -f $Owner, $OwnerLogin.Login) -Level WARN
        }
        Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName `
            -Statement ('ALTER AUTHORIZATION ON DATABASE::{DB} TO ' + (Esc-Name $OwnerLogin.Login) + ';')
        Complete-Step
    }

    Start-Step ("Set the recovery model to $RecoveryModel")
    Invoke-DbStatement -Server $Server -DatabaseName $DatabaseName `
        -Statement ("ALTER DATABASE {DB} SET RECOVERY $RecoveryModel;")
    Complete-Step

    if ($Grants.Count) {
        Start-Step 'Add the users asked for'
        $added = Add-DatabaseUser -Server $Server -DatabaseName $DatabaseName -Grants $Grants
        if ($added.Created.Count) {
            $roleless = @($Grants | Where-Object { @($_.Roles).Count -eq 0 })
            Write-Log ('Added ' + ($added.Created -join '; ') +
                       $(if ($roleless.Count) { ' - no role membership, so no permissions yet' } else { '' }))
        }
        foreach ($missing in $added.NoLogin) {
            Write-Log ("There is no login called '{0}' here, so no user was created for it. Create the login first, then run this again." -f $missing) -Level WARN
        }
        foreach ($failure in $added.Failed) { Write-Log ('Could not add ' + $failure) -Level WARN }
        Complete-Step
    }
    elseif ($userGrants.Count) { Write-Detail '  no users asked for on this one' }
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
    # the blob listing hands back a DateTimeOffset, so that is what the fake blobs carry: a
    # DateTime here would pass a check the real thing fails on a server set to US dates
    function Blob([string] $Name, [string] $When, [int] $Length = 1048576) {
        $utc = [datetime]::SpecifyKind([datetime]::ParseExact($When, 'yyyy-MM-dd HH:mm',
                   [System.Globalization.CultureInfo]::InvariantCulture), [System.DateTimeKind]::Utc)
        [pscustomobject]@{ Name = $Name; LastModified = [System.DateTimeOffset]$utc; Length = $Length }
    }

    Write-Host 'Clone-DatabasesFromBlob self test'
    Write-Host '  where to look' -ForegroundColor Gray
    Check 'the documented layout' ((Get-BlobPrefix -Pattern 'FULL/DAILY/{db}/' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'backslashes are accepted' ((Get-BlobPrefix -Pattern 'FULL\DAILY\{db}\' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'a missing trailing slash is added' ((Get-BlobPrefix -Pattern 'FULL/DAILY/{db}' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Check 'so Sales cannot match SalesArchive' ((Get-BlobPrefix -Pattern '{db}' -DatabaseName 'Sales') -eq 'Sales/')
    Check 'a flat container is allowed' ((Get-BlobPrefix -Pattern '/' -DatabaseName 'Sales') -eq '')

    Write-Host '  the URL SQL Server is given' -ForegroundColor Gray
    $url = Get-BlobUrl -Account 'mycompany' -Container 'backups' -BlobName 'FULL/DAILY/Sales/Sales_20261013.bak'
    Check 'account, container and blob in one address' ($url -eq 'https://mycompany.blob.core.windows.net/backups/FULL/DAILY/Sales/Sales_20261013.bak') $url
    $url = Get-BlobUrl -Account 'mycompany' -Container 'backups' -BlobName 'FULL/DAILY/Sales/Sales full 13 Oct.bak'
    Check 'a space in the name is escaped, the slashes are not' ($url -eq 'https://mycompany.blob.core.windows.net/backups/FULL/DAILY/Sales/Sales%20full%2013%20Oct.bak') $url
    $url = Get-BlobUrl -Account 'mycompany' -Container 'backups' -BlobName 'x.bak' -EndpointSuffix 'blob.core.usgovcloudapi.net'
    Check 'another cloud is reachable' ($url -like 'https://mycompany.blob.core.usgovcloudapi.net/*') $url
    Check 'the credential statement names the container, quoted' ((New-BlobCredentialStatement 'https://mycompany.blob.core.windows.net/backups') -eq "CREATE CREDENTIAL [https://mycompany.blob.core.windows.net/backups] WITH IDENTITY = 'MANAGED IDENTITY';")

    Write-Host '  reading the container listing' -ForegroundColor Gray
    # a page of the Blob REST API's answer, cut down but in its real shape. The dates are the
    # shape it really sends: RFC 1123, GMT, which no regional setting is allowed to touch.
    $page = @'
<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults ServiceEndpoint="https://mycompany.blob.core.windows.net/" ContainerName="backups">
  <Prefix>FULL/DAILY/MPS3/</Prefix>
  <MaxResults>5000</MaxResults>
  <Blobs>
    <Blob>
      <Name>FULL/DAILY/MPS3/MPS3_20261014.bak</Name>
      <Properties><Last-Modified>Wed, 14 Oct 2026 10:50:46 GMT</Last-Modified><Content-Length>1073741824</Content-Length><BlobType>BlockBlob</BlobType></Properties>
    </Blob>
    <Blob>
      <Name>FULL/DAILY/MPS3/MPS3_20261015.bak</Name>
      <Properties><Last-Modified>Thu, 15 Oct 2026 10:50:17 GMT</Last-Modified><Content-Length>1073748000</Content-Length><BlobType>BlockBlob</BlobType></Properties>
    </Blob>
    <Blob>
      <Name>FULL/DAILY/MPS3/upload.log</Name>
      <Properties><Last-Modified>Thu, 15 Oct 2026 11:02:00 GMT</Last-Modified><Content-Length>812</Content-Length><BlobType>BlockBlob</BlobType></Properties>
    </Blob>
  </Blobs>
  <NextMarker />
</EnumerationResults>
'@
    $read = ConvertFrom-BlobListXml -Xml $page
    Check 'every blob on the page is read' (@($read.Blobs).Count -eq 3) ("$(@($read.Blobs).Count) blobs")
    Check 'an empty NextMarker means there are no more pages' ($read.NextMarker -eq '') ("[$($read.NextMarker)]")
    Check 'the name comes through whole, folders and all' ($read.Blobs[0].Name -eq 'FULL/DAILY/MPS3/MPS3_20261014.bak') $read.Blobs[0].Name
    Check 'the size is a number' ($read.Blobs[0].Length -eq 1073741824) "$($read.Blobs[0].Length)"
    Check 'the date is a DateTimeOffset, not a string' ($read.Blobs[0].LastModified -is [System.DateTimeOffset])
    Check 'and it is the date the container said, in UTC' ($read.Blobs[0].LastModified -eq [System.DateTimeOffset]::new(2026, 10, 14, 10, 50, 46, [TimeSpan]::Zero)) $read.Blobs[0].LastModified.ToString('o')
    $withMarker = ConvertFrom-BlobListXml -Xml ($page -replace '<NextMarker />', '<NextMarker>2!abc</NextMarker>')
    Check 'a real marker is read, so the next page is asked for' ($withMarker.NextMarker -eq '2!abc') $withMarker.NextMarker
    Check 'and an empty container reads as no blobs rather than failing' (@((ConvertFrom-BlobListXml -Xml '<?xml version="1.0"?><EnumerationResults><Blobs /><NextMarker /></EnumerationResults>').Blobs).Count -eq 0)

    # the seam this had wrong on its first real run: the listing goes straight into the chooser, and
    # what the chooser gets has to be the blobs themselves, not one element holding all of them
    $chosen = Select-LatestBackupBlob -Blobs @($read.Blobs)
    Check 'the listing feeds the chooser directly' ($null -ne $chosen.Chosen) 'nothing was chosen'
    Check 'and the newest backup out of it wins' ($chosen.Chosen.Name -eq 'FULL/DAILY/MPS3/MPS3_20261015.bak') $chosen.Chosen.Name
    Check 'the log file in the folder is not mistaken for a backup' ($chosen.Considered -eq 2) "considered $($chosen.Considered)"
    # and what it used to be handed instead: one element holding every blob. That has to be refused
    # at the door, because the alternative is not an error - it is "no backups in this container".
    $wrapped = @(, @($read.Blobs))
    $threw = ''
    try { $null = Select-LatestBackupBlob -Blobs $wrapped } catch { $threw = $_.Exception.GetBaseException().Message }
    Check 'being handed every blob as one element is refused' ($threw -match 'one element holding 3 of them') $threw
    Check 'and the message says whose fault it is' ($threw -match 'fault in whatever called this') $threw
    # the same mistake one layer down, for a caller that reaches past the chooser
    $threw = ''
    try { $null = ConvertTo-UtcTime @($read.Blobs).LastModified } catch { $threw = $_.Exception.GetBaseException().Message }
    Check 'and so is handing three timestamps to something that wants one' ($threw -match 'expected one timestamp and was given 3 of them') $threw

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
    $s = Select-LatestBackupBlob -Blobs @($a, $b, $mid)
    Check 'the stripes of one backup are kept together' ($s.Siblings.Count -eq 1) ("chose $($s.Chosen.Name)")
    Check 'and yesterday is not one of them' (-not @($s.Siblings | Where-Object { $_.Name -eq $mid.Name }).Count)
    $s = Select-LatestBackupBlob -Blobs @()
    Check 'an empty folder chooses nothing rather than failing' ($null -eq $s.Chosen -and $s.Considered -eq 0)

    Write-Host '  the statement it builds' -ForegroundColor Gray
    $set = [pscustomobject]@{ Urls = @('https://mycompany.blob.core.windows.net/backups/FULL/DAILY/Sales/Sales.bak')
                              Position = 1; HasChecksums = $true }
    $move = @{ 'Sales' = 'D:\SqlData\Sales.mdf'; 'Sales_log' = 'L:\SqlLogs\Sales_log.ldf' }
    $sql = New-RestoreCommand -Database 'Sales' -BackupSet $set -MoveList $move
    Check 'it restores from the URL, not from a disk' ($sql -match 'FROM URL = N''https://' -and $sql -notmatch 'DISK =') $sql
    Check 'the database is quoted' ($sql -match '^RESTORE DATABASE \[Sales\]')
    Check 'at the position in the set' ($sql -match 'FILE = 1')
    Check 'both files are moved, in a settled order' ($sql -match "(?s)MOVE N'Sales' TO .*MOVE N'Sales_log' TO")
    Check 'it is brought online' ($sql -match 'RECOVERY' -and $sql -notmatch 'NORECOVERY')
    Check 'checksums are checked when the backup has them' ($sql -match 'CHECKSUM')
    Check 'and it reports progress' ($sql -match 'STATS = 5')
    Check 'nothing is replaced unless asked' ($sql -notmatch 'REPLACE')
    $sql = New-RestoreCommand -Database 'Sales' -BackupSet $set -MoveList $move -Replace
    Check 'replacing an existing copy says so' ($sql -match 'REPLACE')
    Check 'and nothing is shut unless asked' ($sql -notmatch 'RESTRICTED_USER')
    $sql = New-RestoreCommand -Database 'Sales' -BackupSet $set -MoveList $move -RestrictAccess
    Check 'shutting it happens in the same batch as the restore, not after it' ($sql -match "(?s)^RESTORE DATABASE .*ALTER DATABASE \[Sales\] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;$") $sql

    Write-Host '  where each database has got to' -ForegroundColor Gray
    Check 'state 1 is not encrypted' ((Get-EncryptionStateName 1) -eq 'not encrypted')
    Check 'state 2 is encrypting' ((Get-EncryptionStateName 2) -eq 'encrypting')
    Check 'state 3 is encrypted' ((Get-EncryptionStateName 3) -eq 'encrypted')
    Check 'state 5 is being decrypted, which is somebody else at work' ((Get-EncryptionStateName 5) -eq 'being decrypted')
    Check 'a state nobody has seen is reported as itself' ((Get-EncryptionStateName 9) -eq 'state 9')

    function Progress([string] $Name, [int] $State, [double] $Percent) {
        [pscustomobject]@{ Name = $Name; State = $State; Percent = $Percent; Algorithm = 'AES_256'; KeyLength = 256 }
    }
    $line = Format-EncryptionProgress -Progress @((Progress 'Sales' 2 46.5), (Progress 'Stock' 3 100)) -Expected @('Sales', 'Stock')
    Check 'one line says where each of them is' ($line -eq 'Sales 46.5%, Stock encrypted') $line
    $line = Format-EncryptionProgress -Progress @((Progress 'Sales' 2 10)) -Expected @('Sales', 'Orders')
    Check 'a database with no key yet is said to have none, not left out' ($line -eq 'Sales 10%, Orders no key yet') $line
    $line = Format-EncryptionProgress -Progress @() -Expected @('Sales')
    Check 'and nothing started yet reads as that' ($line -eq 'Sales no key yet') $line
    $striped = [pscustomobject]@{ Urls = @('https://a.blob.core.windows.net/c/one.bak', 'https://a.blob.core.windows.net/c/two.bak')
                                  Position = 1; HasChecksums = $false }
    $sql = New-RestoreCommand -Database 'Sales' -BackupSet $striped
    Check 'a striped backup lists every file' (([regex]::Matches($sql, 'URL = N')).Count -eq 2) $sql
    Check 'and a backup with no checksums is not asked to verify them' ($sql -notmatch 'CHECKSUM')
    $odd = [pscustomobject]@{ Urls = @("https://a.blob.core.windows.net/c/o'brien.bak"); Position = 2; HasChecksums = $false }
    $sql = New-RestoreCommand -Database "Sales]Odd" -BackupSet $odd
    Check 'a quote in a URL is doubled, not left to break out' ($sql -match "o''brien") $sql
    Check 'and a bracket in a database name is escaped' ($sql -match '\[Sales\]\]Odd\]') $sql

    Write-Host '  where the restored files go' -ForegroundColor Gray
    Check 'data to the data path' ((Get-MoveTarget -PhysicalName 'E:\Prod\Sales.mdf' -FileType 'D' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs') -eq 'D:\SqlData\Sales.mdf')
    Check 'the log to the log path' ((Get-MoveTarget -PhysicalName 'E:\Prod\Sales_log.ldf' -FileType 'L' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs') -eq 'L:\SqlLogs\Sales_log.ldf')
    Check 'a trailing slash does not double up' ((Get-MoveTarget -PhysicalName 'E:\Prod\Sales.mdf' -FileType 'D' -DataPath 'D:\SqlData\' -LogPath 'L:\SqlLogs') -eq 'D:\SqlData\Sales.mdf')

    Write-Host '  who gets added to what' -ForegroundColor Gray
    $g = Resolve-UserGrant -Entries @('BiTeam') -DefaultRoles @('db_datareader') -Databases @('Sales', 'Stock')
    Check 'a plain name goes into every database' ($g.Grants.Count -eq 2 -and -not $g.Unknown.Count)
    Check 'with the default role' (@($g.Grants[0].Roles) -contains 'db_datareader')
    $g = Resolve-UserGrant -Entries @('Sales:BiTeam:db_datareader') -DefaultRoles @() -Databases @('Sales', 'Stock')
    Check 'the string form names one database' ($g.Grants.Count -eq 1 -and $g.Grants[0].Database -eq 'Sales')
    $g = Resolve-UserGrant -Entries @('Nope:BiTeam:db_datareader') -DefaultRoles @() -Databases @('Sales')
    Check 'a database not being restored is reported, not ignored' ($g.Unknown.Count -eq 1)
    $g = Resolve-UserGrant -Entries @('*:BiTeam:db_datareader') -DefaultRoles @() -Databases @('Sales', 'Stock')
    Check 'a star means all of them' ($g.Grants.Count -eq 2)
    $g = Resolve-UserGrant -Entries @(@{ Database = 'Sales'; User = 'CONTOSO\jo'; Role = 'db_datareader', 'db_datawriter' }) -DefaultRoles @() -Databases @('Sales')
    Check 'a hashtable carries several roles' (@($g.Grants[0].Roles).Count -eq 2)
    Check 'and a Windows account keeps its backslash' ($g.Grants[0].User -eq 'CONTOSO\jo')

    Write-Host '  dates, whatever the region' -ForegroundColor Gray
    $expected = [System.DateTimeOffset]::new(2026, 10, 13, 22, 5, 0, [TimeSpan]::Zero)
    Check 'an offset is kept as it is' ((ConvertTo-UtcTime ([System.DateTimeOffset]$expected)) -eq $expected)
    Check 'a UTC date too' ((ConvertTo-UtcTime ([datetime]::SpecifyKind([datetime]'2026-10-13T22:05:00', [System.DateTimeKind]::Utc))) -eq $expected)
    Check 'an ISO string too' ((ConvertTo-UtcTime '2026-10-13T22:05:00Z') -eq $expected)
    Check 'and RFC 1123, which is what the blob listing returns' ((ConvertTo-UtcTime ([System.DateTimeOffset]::Parse('Tue, 13 Oct 2026 22:05:00 GMT', [System.Globalization.CultureInfo]::InvariantCulture))) -eq $expected)
    $was = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        # a server set to US dates read 13/10 as an invalid month and threw; a server set to UK
        # dates read 10/13 as the 13th month. Neither may happen now.
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
        Check 'the same answer under US dates' ((ConvertTo-UtcTime '2026-10-13T22:05:00Z') -eq $expected)
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-GB')
        Check 'and under UK dates' ((ConvertTo-UtcTime '2026-10-13T22:05:00Z') -eq $expected)
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $was }

    Write-Host '  which users stay' -ForegroundColor Gray
    Check 'dbo stays' (Test-SystemPrincipal -PrincipalId 1 -Name 'dbo' -Type 'S')
    Check 'guest stays' (Test-SystemPrincipal -PrincipalId 2 -Name 'guest' -Type 'S')
    Check 'sys stays' (Test-SystemPrincipal -PrincipalId 4 -Name 'sys' -Type 'S')
    Check 'a fixed role stays' (Test-SystemPrincipal -PrincipalId 16384 -Name 'db_owner' -Type 'R' -IsFixedRole $true)
    Check 'a certificate-backed principal stays' (Test-SystemPrincipal -PrincipalId 5 -Name '##MS_PolicyEventProcessingLogin##' -Type 'S')
    Check 'a SQL user goes' (-not (Test-SystemPrincipal -PrincipalId 5 -Name 'appuser' -Type 'S'))
    Check 'a Windows user goes' (-not (Test-SystemPrincipal -PrincipalId 6 -Name 'CONTOSO\jo' -Type 'U'))
    Check 'a Windows group goes' (-not (Test-SystemPrincipal -PrincipalId 7 -Name 'CONTOSO\Reporting' -Type 'G'))
    Check 'an Entra user goes' (-not (Test-SystemPrincipal -PrincipalId 8 -Name 'jo@contoso.com' -Type 'E'))

    Write-Host '  sizes and stamps, whatever the server is set to' -ForegroundColor Gray
    $was = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in 'en-GB', 'en-US', 'de-DE') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
            Check "gigabytes under $culture" ((Format-Size 3221225472) -eq '3.0 GB') (Format-Size 3221225472)
            Check "megabytes under $culture" ((Format-Size 5242880) -eq '5 MB') (Format-Size 5242880)
            $stamp = Format-Stamp ([System.DateTimeOffset]::new(2026, 10, 15, 10, 50, 17, [TimeSpan]::Zero)) -Utc
            Check "a stamp under $culture" ($stamp -eq '15 Oct 2026 10:50 UTC') $stamp
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $was }
    Check 'and a stamp says UTC, because that is what it is' ((Format-Stamp ([datetime]::UtcNow) -Utc) -match ' UTC$')

    Write-Host '  whether this instance can encrypt anything' -ForegroundColor Gray
    # PowerShell refuses to add two hashtables that share a key, so a changed copy is made by hand
    function With([hashtable] $Base, [hashtable] $Change) {
        $copy = @{}
        foreach ($key in $Base.Keys) { $copy[$key] = $Base[$key] }
        foreach ($key in $Change.Keys) { $copy[$key] = $Change[$key] }
        $copy
    }
    # and -match against a list returns the matching items rather than a yes or no
    function Problems([hashtable] $Facts) { @(Get-TdeProblem @Facts) -join ' | ' }
    function ProblemCount([hashtable] $Facts) { @(Get-TdeProblem @Facts).Count }

    $ready = @{ EngineEdition = 3; MajorVersion = 16; Edition = 'Enterprise Edition'; HasMasterKey = $true
                CertificateName = 'MolehillTde'; FoundCertificate = 'MolehillTde'; PrivateKeyType = 'ENCRYPTED_BY_MASTER_KEY' }
    Check 'a ready instance has nothing to report' ((Problems $ready) -eq '')
    Check 'Standard from 2019 is fine' ((Problems (With $ready @{ EngineEdition = 2; MajorVersion = 15; Edition = 'Standard Edition' })) -eq '')
    $express = With $ready @{ EngineEdition = 4; MajorVersion = 17; Edition = 'Express Edition (64-bit)' }
    Check 'Express has none at any version, as the engine itself says' ((Problems $express) -match 'does not have TDE at any version')
    $old = With $ready @{ EngineEdition = 2; MajorVersion = 13; Edition = 'Standard Edition' }
    Check 'Standard before 2019 is not' ((Problems $old) -match 'needs Enterprise')
    Check 'no master key is reported with the statement that makes one' ((Problems (With $ready @{ HasMasterKey = $false })) -match 'CREATE MASTER KEY')
    Check 'a missing certificate likewise' ((Problems (With $ready @{ FoundCertificate = '' })) -match 'CREATE CERTIFICATE \[MolehillTde\]')
    Check 'a certificate with no private key is no use' ((Problems (With $ready @{ PrivateKeyType = 'NO_PRIVATE_KEY' })) -match 'no private key')
    Check 'nor is one SQL Server cannot open by itself' ((Problems (With $ready @{ PrivateKeyType = 'ENCRYPTED_BY_PASSWORD' })) -match 'unattended')
    Check 'both missing keys are reported together, not one at a time' ((ProblemCount (With $ready @{ HasMasterKey = $false; FoundCertificate = '' })) -eq 2)

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# The run
#==============================================================================
$DestinationInstance = $DestinationInstance.Trim()
$dryRun = ($WhatIfPreference -eq $true)

# powershell.exe -File hands every argument over as one string, so -Database Sales,Stock arrives as
# a single element rather than two. A job step is exactly where this ends up.
$named = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($named.Count -eq 1 -and $named[0] -match ',') { $named = @($named[0] -split ',') }
$databases = @($named | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($databases.Count -eq 0) {
    Write-Host '  -Database is needed (one name, or several).' -ForegroundColor Red
    exit 2
}
foreach ($required in 'StorageAccountName', 'ContainerName') {
    if (-not (Get-Variable -Name $required -ValueOnly)) {
        Write-Host "  -$required is needed." -ForegroundColor Red
        Write-Host '  Try: Get-Help .\Clone-DatabasesFromBlob.ps1 -Detailed' -ForegroundColor Gray
        exit 2
    }
}
if ($AddUserRole -and -not $AddUser) {
    Write-Host '  -AddUserRole only means something with -AddUser.' -ForegroundColor Red
    exit 2
}

# worked out now rather than per database: naming a database that is not being restored is a typo,
# and finding out afterwards means a user silently missing from a copy already handed over
$userGrants = @()
if ($AddUser) {
    try { $resolved = Resolve-UserGrant -Entries $AddUser -DefaultRoles $AddUserRole -Databases $databases }
    catch {
        Write-Host ('  ' + ($_.Exception.Message -split "`r?`n")[0]) -ForegroundColor Red
        exit 2
    }
    if ($resolved.Unknown.Count) {
        Write-Host ('  -AddUser names database(s) that are not in -Database: ' + ($resolved.Unknown -join '; ')) -ForegroundColor Red
        Write-Host ('  the databases being cloned are: ' + ($databases -join ', ')) -ForegroundColor Gray
        exit 2
    }
    $userGrants = $resolved.Grants
}

$runStart = Get-Date
$setupDone = $false
$results = New-Object System.Collections.Generic.List[object]
# the databases whose encryption was started and has still to be waited for
$encrypting = New-Object System.Collections.Generic.List[string]
$script:ExitBad = $false

try {
    Write-Log ('Cloning {0} database(s) from {1}/{2} onto {3}' -f $databases.Count, $StorageAccountName, $ContainerName, $DestinationInstance)
    Write-Detail ("PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName)")
    if ($dryRun) { Write-Log 'WhatIf: everything is worked out and reported, and nothing is changed.' -Level WARN }

    #region The destination
    Start-Step 'Look at the destination'
    $dstInfo = (Invoke-Sql -Server $DestinationInstance -Query @'
SELECT  ServerName   = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')),
        Version      = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')),
        Major        = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')),
        Edition      = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
        DefaultData  = CONVERT(nvarchar(400), SERVERPROPERTY('InstanceDefaultDataPath')),
        DefaultLog   = CONVERT(nvarchar(400), SERVERPROPERTY('InstanceDefaultLogPath')),
        LoginName    = SUSER_SNAME(),
        IsSysadmin   = IS_SRVROLEMEMBER('sysadmin')
'@).Rows[0]
    Write-Log ('{0}, {1} {2}, connected as {3}' -f $dstInfo['ServerName'], $dstInfo['Edition'], $dstInfo['Version'], $dstInfo['LoginName'])
    if (-not [bool]$dstInfo['IsSysadmin']) {
        Write-Log 'The account this runs as is not a sysadmin. Restoring, dropping users and encrypting all need more than it may have; a failure below may be a permission rather than a fault.' -Level WARN
    }
    if ([int]$dstInfo['Major'] -lt 16) {
        throw ('restoring straight from a container with a managed identity needs SQL Server 2022 or later, and {0} is major version {1}. On an older instance the credential has to hold a shared access signature instead.' -f
               $DestinationInstance, $dstInfo['Major'])
    }

    $defaultData = if ($DataPath) { $DataPath } else { [string]$dstInfo['DefaultData'] }
    $defaultLog = if ($LogPath) { $LogPath } else { [string]$dstInfo['DefaultLog'] }
    if (-not $defaultData -or -not $defaultLog) {
        throw 'this instance does not report a default data or log path, so -DataPath and -LogPath have to say where the files should go'
    }
    Write-Detail ('  data files to {0}, log files to {1}' -f $defaultData, $defaultLog)
    Complete-Step
    #endregion

    <#
      Everything this run needs before it touches a database, checked together.

      Together on purpose: a job being set up for the first time usually has more than one of these
      waiting - the credential is not there, the certificate is not there, the identity has no role
      on the container - and finding them one run at a time is three runs and three waits.
    #>
    $setupProblems = New-Object System.Collections.Generic.List[string]

    Start-Step 'Check the credential SQL Server reads the container with'
    $credential = Test-BlobCredential -Server $DestinationInstance -Account $StorageAccountName `
                                      -Container $ContainerName -EndpointSuffix $BlobEndpointSuffix
    if (-not $credential.Found) {
        # the server's own name rather than what was typed: "." reads badly at the start of a
        # sentence, and a job's output is read by someone who does not know which box it ran on
        $setupProblems.Add(("{0} has no credential for {1}, so SQL Server cannot read the backups. Run this on it once, as a sysadmin:`r`n        {2}" -f
                            $dstInfo['ServerName'], $credential.ContainerUrl, $credential.Statement))
        Complete-Step -Result 'FAILED'
    }
    else {
        if ($credential.Identity -notmatch 'MANAGED IDENTITY') {
            Write-Log ("The credential {0} is a '{1}' one rather than a managed identity. It will be used as it is; if it holds a shared access signature that has expired, the restore is where you will find out." -f
                       $credential.Name, $credential.Identity) -Level WARN
        }
        else { Write-Log ('SQL Server reads the container as a managed identity, through the credential {0}' -f $credential.Name) }
        Complete-Step
    }

    if ($EnableTde) {
        Start-Step 'Check it can encrypt'
        $tdeReady = Test-TdeReadiness -Server $DestinationInstance -CertificateName $TdeCertificateName
        if (-not $tdeReady.Ok) {
            foreach ($problem in $tdeReady.Problems) { $setupProblems.Add($problem) }
            Complete-Step -Result 'FAILED'
        }
        else {
            Write-Log ('Will encrypt with the certificate {0} ({1}{2})' -f $TdeCertificateName, $tdeReady.Subject,
                       $(if ($tdeReady.Expiry) { ', expires ' + (Format-Stamp $tdeReady.Expiry -Utc) } else { '' }))
            Write-Log 'Encrypting any database encrypts tempdb for the whole instance, permanently - a decision about the server, not just these copies.' -Level WARN
            Complete-Step
        }
    }

    Start-Step 'Get a token for the storage account'
    $token = $null
    try {
        $token = Get-MiToken -ClientId $ManagedIdentityClientId
        Write-Log ('Listing the container as {0}' -f $(if ($ManagedIdentityClientId) { "the identity $ManagedIdentityClientId" } else { "this machine's own identity" }))
        Complete-Step
    }
    catch {
        $setupProblems.Add($_.Exception.GetBaseException().Message)
        Complete-Step -Result 'FAILED'
    }

    if ($setupProblems.Count) {
        throw ("nothing has been restored, because {0}:`r`n  - {1}" -f
               $(if ($setupProblems.Count -eq 1) { 'this has to be sorted out first' } else { "these $($setupProblems.Count) things have to be sorted out first" }),
               ($setupProblems -join "`r`n  - "))
    }

    $setupDone = $true

    foreach ($dbName in $databases) {
        $script:StepPrefix = if ($databases.Count -gt 1) { $dbName } else { '' }
        $outcome = [pscustomobject]@{
            Database = $dbName; Result = 'FAILED'; Blob = $null; Bytes = 0; BackupTaken = $null
            Users = ''; Encryption = ''; Seconds = 0; Detail = ''
        }
        $results.Add($outcome)
        $dbTimer = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host ''
        Write-Log ('---- {0} ----' -f $dbName)

        try {
            #region Find it
            Start-Step 'Find the newest backup in the container'
            $prefix = Get-BlobPrefix -Pattern $BlobPathPattern -DatabaseName $dbName
            $blobs = @(Get-ContainerBlob -Account $StorageAccountName -Container $ContainerName -Prefix $prefix `
                                         -Token $token -EndpointSuffix $BlobEndpointSuffix)
            $choice = Select-LatestBackupBlob -Blobs $blobs
            if (-not $choice.Chosen) {
                throw ("there is no backup file under {0} in {1}/{2}. Check -BlobPathPattern against how the container is laid out." -f
                       $prefix, $StorageAccountName, $ContainerName)
            }
            $blob = $choice.Chosen
            $outcome.Blob = $blob.Name
            $outcome.Bytes = $blob.Length
            Write-Log ('Newest backup: {0} ({1}, written {2})' -f $blob.Name, (Format-Size $blob.Length), (Format-Stamp $choice.ChosenWhen -Utc))
            Write-Detail ('  {0} backup file(s) under that prefix' -f $choice.Considered)
            $urls = @(Get-BlobUrl -Account $StorageAccountName -Container $ContainerName -BlobName $blob.Name -EndpointSuffix $BlobEndpointSuffix)
            Complete-Step
            #endregion

            #region Prove it is what it says
            Start-Step 'Read the backup header'
            # before the existing copy is touched: a backup of the wrong database, a log backup, or
            # a credential that cannot read the container all show up here, while nothing is broken
            try { $header = Read-BackupHeader -Server $DestinationInstance -Urls $urls }
            catch {
                $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                # one file of a striped set is not reported as striped, it is refused: so try again
                # with the blobs written beside it before giving up
                if ($choice.Siblings.Count -and $message -match 'media famil|media set') {
                    Write-Detail ('  that is one file of a set written across several; trying it with the {0} blob(s) written beside it' -f $choice.Siblings.Count)
                    $urls = @($urls) + @($choice.Siblings | ForEach-Object {
                        Get-BlobUrl -Account $StorageAccountName -Container $ContainerName -BlobName $_.Name -EndpointSuffix $BlobEndpointSuffix
                    })
                    $header = Read-BackupHeader -Server $DestinationInstance -Urls $urls
                }
                elseif ($message -match 'Operating system error|Cannot open backup device|40(2|3)') {
                    throw ("SQL Server could not read the backup: $message This is the credential or the identity's access to the container rather than the backup itself - the credential is {0}." -f $credential.Name)
                }
                else { throw ('could not read the backup header: ' + $message) }
            }

            $row = $header.Rows[0]
            $backupType = [int]$row['BackupType']
            $families = [int]$row['FamilyCount']
            $inside = [string]$row['DatabaseName']
            $taken = ConvertTo-UtcTime $row['BackupFinishDate']
            $outcome.BackupTaken = $taken
            Write-Log ('It holds a {0} backup of [{1}], finished {2}, from SQL Server major version {3}' -f
                       $(switch ($backupType) { 1 { 'full' } 2 { 'transaction log' } 5 { 'differential' } default { "type $backupType" } }),
                       $inside, (Format-Stamp $taken -Utc), $row['SoftwareVersionMajor'])

            if ($backupType -ne 1) {
                throw ("that is not a full backup, so it cannot be restored on its own. The newest file under {0} is a {1}." -f
                       $prefix, $(switch ($backupType) { 2 { 'transaction log backup' } 5 { 'differential backup' } default { "backup of type $backupType" } }))
            }
            if ($families -ne @($urls).Count) {
                throw ("that backup was written across {0} file(s) and {1} of them could be found beside it in the container. All of them have to be restored together." -f
                       $families, @($urls).Count)
            }
            if ($inside -ne $dbName) {
                Write-Log ("The backup is of [{0}] but it was found in the folder for [{1}] and will be restored as [{1}]. Check the container layout if that is not intended." -f $inside, $dbName) -Level WARN
            }
            if ([int]$row['SoftwareVersionMajor'] -gt [int]$dstInfo['Major']) {
                throw ('the backup was taken on SQL Server major version {0} and this instance is version {1}: a backup cannot be restored onto an older version' -f
                       $row['SoftwareVersionMajor'], $dstInfo['Major'])
            }
            Complete-Step
            #endregion

            #region Restore it
            Start-Step 'Restore it'
            $existing = Invoke-Sql -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                        'SELECT state_desc, is_read_only FROM sys.databases WHERE name = @db'
            $isThere = $existing.Rows.Count -gt 0
            if ($isThere) {
                Write-Detail ('  the existing copy is {0}{1}' -f ([string]$existing.Rows[0]['state_desc']).ToLower(),
                              $(if ([bool]$existing.Rows[0]['is_read_only']) { ', read-only' } else { '' }))
                $restoredHere = Get-Scalar -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                                'SELECT TOP (1) 1 FROM msdb.dbo.restorehistory WHERE destination_database_name = @db'
                if (-not $restoredHere -and -not $Force) {
                    throw ("{0} already exists here and this instance has no record of restoring it, so it has not been touched. Check the name, or use -Force to overwrite it anyway." -f $dbName)
                }
            }
            else { Write-Detail '  nothing of that name here yet' }

            # where its files should land, and whether anything else already owns those paths
            $fileList = Invoke-Sql -Server $DestinationInstance -Query ("RESTORE FILELISTONLY FROM " +
                        ((@($urls) | ForEach-Object { "URL = N'" + (Esc-Str $_) + "'" }) -join ', '))
            $moveList = @{}
            foreach ($f in $fileList.Rows) {
                $moveList[[string]$f['LogicalName']] = Get-MoveTarget -PhysicalName ([string]$f['PhysicalName']) `
                                                        -FileType ([string]$f['Type']) -DataPath $defaultData -LogPath $defaultLog
            }
            foreach ($file in $moveList.Values) {
                $fileOwner = Get-Scalar -Server $DestinationInstance -Parameters @{ '@p' = $file } -Query `
                             'SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p'
                if ($fileOwner -and [string]$fileOwner -ne $dbName) {
                    throw ("the file {0} already belongs to the database {1} on this instance. Use -DataPath or -LogPath to put the copy somewhere else." -f $file, $fileOwner)
                }
            }
            Write-Detail ('  {0} file(s) to restore' -f $moveList.Count)

            $set = [pscustomobject]@{ Urls = $urls; Position = [int]$row['Position']; HasChecksums = $true }
            # restricted from the restore itself when it is going to be encrypted: nobody reads an
            # unencrypted copy of production, not even for the few seconds it takes to start the scan
            $sql = New-RestoreCommand -Database $dbName -BackupSet $set -MoveList $moveList `
                       -Replace:$isThere -RestrictAccess:$EnableTde

            if ($dryRun) {
                Write-Log 'WhatIf: this is the statement that would run'
                foreach ($line in ($sql -split "`r?`n")) { Write-Log ('    ' + $line) }
                Write-Log ('WhatIf: then its users would be cleared, the owner set to {0} and the recovery model set to {1}{2}' -f
                           $Owner, $RecoveryModel,
                           $(if ($EnableTde) {
                                 ". It would be shut to everyone but its owners by the restore itself, encryption started, and the next database begun. Once every restore is done, this run would wait for all of them to finish encrypting - up to $TdeWaitMinutes minute(s) - and only then let people in" +
                                 $(if ($ReadOnly) { ' and set it read-only' } else { '' })
                             } else {
                                 ', and it would be opened up' + $(if ($ReadOnly) { ' and set read-only' } else { '' })
                             }))
                $outcome.Result = 'DRY RUN'
                Complete-Step -Result 'SKIPPED'
                continue
            }

            if ($isThere) {
                Write-Log "Taking $dbName offline (rolling back open transactions)"
                [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET OFFLINE WITH ROLLBACK IMMEDIATE;' -f (Esc-Name $dbName)))
            }

            $r = Invoke-LongRunningSql -Server $DestinationInstance -Sql $sql -Label 'restore'
            if (-not $r.Ok) {
                if ($isThere) {
                    Write-Log "The restore failed; putting $dbName back online" -Level WARN
                    try { [void](Invoke-Sql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET ONLINE;' -f (Esc-Name $dbName))) }
                    catch { Write-Log ('  could not bring it back online: ' + $_.Exception.Message) -Level ERROR }
                }
                throw ('the restore failed: ' + $r.Error)
            }
            Write-Log ('Restored{0} in {1}s{2}' -f $(if ($r.Megabytes) { " $($r.Megabytes) MB" } else { '' }), $r.Seconds,
                       $(if ($EnableTde) { ', and shut to everyone but its owners until it is encrypted' } else { '' }))
            Complete-Step
            #endregion

            # and settle it before the next one is even looked at
            Complete-RestoredDatabase -Server $DestinationInstance -DatabaseName $dbName -Outcome $outcome `
                -OwnerLogin (Resolve-OwnerLogin -Server $DestinationInstance -Wanted $Owner) `
                -Grants @($userGrants | Where-Object { $_.Database -eq $dbName })

            if ($EnableTde) {
                # started, not waited for: the scan runs in the background and every database's can
                # run at once, so they are all started here and all waited for at the end
                Start-Step 'Start encrypting it'
                $started = Start-DatabaseEncryption -Server $DestinationInstance -DatabaseName $dbName -CertificateName $TdeCertificateName
                if ($started.Already) {
                    Write-Log 'It was already encrypted, so there is nothing to wait for'
                    $outcome.Result = 'RESTORED'
                }
                else {
                    Write-Log 'Encrypting in the background; it stays shut until that has finished'
                    $outcome.Result = 'ENCRYPTING'
                }
                $encrypting.Add($dbName)
                Complete-Step
            }
            else {
                # nothing to wait for, so it can be opened up now
                Start-Step 'Open it up'
                Open-RestoredDatabase -Server $DestinationInstance -DatabaseName $dbName -ReadOnly:$ReadOnly
                Complete-Step
                Write-DatabaseState -Server $DestinationInstance -DatabaseName $dbName -Outcome $outcome
                $outcome.Result = 'DONE'
            }
        }
        catch {
            # the whole message, not its first line: a SQL Server error puts the detail on the
            # lines after it, and the refusals written here put the statement to run there
            $message = $_.Exception.GetBaseException().Message
            if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
            Write-Log ("[$dbName] " + $message) -Level ERROR
            Write-Deep ('full exception: ' + $_.Exception.ToString())
            $outcome.Result = 'FAILED'
            # one line for the summary table at the end, which is a line per database
            $outcome.Detail = ($message -split "`r?`n")[0]
        }
        finally {
            $dbTimer.Stop()
            $outcome.Seconds = [math]::Round($dbTimer.Elapsed.TotalSeconds, 1)
            $script:StepPrefix = ''
        }
    }

    #region Wait for the encryption, then let people in
    <#
      One wait for all of them, at the end.

      Every scan has been running since its database landed, so by the time the last restore has
      finished the first database is usually encrypted already and this returns at once. Nothing is
      opened up before its scan has finished: a copy of production that is readable but not yet
      encrypted is the thing this is here to prevent.
    #>
    if ($encrypting.Count) {
        Write-Host ''
        Start-Step ('Wait for {0} database(s) to finish encrypting' -f $encrypting.Count)
        $waits = @(Wait-DatabaseEncryption -Server $DestinationInstance -DatabaseName $encrypting.ToArray() -WaitMinutes $TdeWaitMinutes)
        Complete-Step -Result $(if (@($waits | Where-Object { -not $_.Encrypted }).Count) { 'FAILED' } else { 'OK' })

        foreach ($wait in $waits) {
            $outcome = @($results | Where-Object { $_.Database -eq $wait.Name })[0]
            $script:StepPrefix = if ($encrypting.Count -gt 1) { $wait.Name } else { '' }

            if ($wait.Encrypted) {
                Write-Log ('{0}: encrypted with {1} ({2}-bit) after {3}s' -f $wait.Name, $wait.Algorithm, $wait.KeyLength, $wait.Seconds)
                $outcome.Encryption = '{0} {1}-bit' -f $wait.Algorithm, $wait.KeyLength
                try {
                    Start-Step 'Open it up'
                    Open-RestoredDatabase -Server $DestinationInstance -DatabaseName $wait.Name -ReadOnly:$ReadOnly
                    Complete-Step
                    Write-DatabaseState -Server $DestinationInstance -DatabaseName $wait.Name -Outcome $outcome
                    $outcome.Result = 'DONE'
                }
                catch {
                    $message = $_.Exception.GetBaseException().Message
                    Complete-Step -Result 'FAILED'
                    Write-Log ("[$($wait.Name)] " + $message) -Level ERROR
                    $outcome.Result = 'FAILED'
                    $outcome.Detail = ($message -split "`r?`n")[0]
                }
            }
            else {
                # left shut on purpose. The scan carries on by itself; when it reaches 100% the two
                # statements below are all that is left to run, and they are printed so that nobody
                # has to work them out at the time.
                $outcome.Result = 'ENCRYPTING'
                $outcome.Encryption = '{0}% after {1}s' -f $wait.Percent, $wait.Seconds
                $outcome.Detail = 'still encrypting, so it has been left shut'
                $why = if ($wait.Stalled) {
                           'it has not moved for minutes, which is not how a scan behaves - look at what else is running on the instance'
                       } else {
                           'it is still going, which a big database does'
                       }
                Write-Log ("{0} is {1}% encrypted after {2}s and {3}. It is still RESTRICTED_USER, so nothing can read it unencrypted. When it finishes, this is all that is left:`r`n    ALTER DATABASE {4} SET MULTI_USER;{5}" -f
                           $wait.Name, $wait.Percent, $wait.Seconds, $why, (Esc-Name $wait.Name),
                           $(if ($ReadOnly) { "`r`n    ALTER DATABASE $(Esc-Name $wait.Name) SET READ_ONLY WITH ROLLBACK IMMEDIATE;" } else { '' })) -Level WARN
                Write-Log ('Watch it with: SELECT encryption_state, percent_complete FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID({0});' -f ("'" + (Esc-Str $wait.Name) + "'"))
            }
            $script:StepPrefix = ''
        }
    }
    #endregion
}
catch {
    if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
    # every line of it: the setup refusals above are several lines, and the one that matters most -
    # the CREATE CREDENTIAL to run - is not the first of them
    Write-Log $_.Exception.GetBaseException().Message -Level ERROR
    Write-Deep ('full exception: ' + $_.Exception.ToString())
}
finally {
    $elapsed = (Get-Date) - $runStart
    Write-Host ''
    Write-Log '---------------- Run summary ----------------' -Min Quiet
    Write-Log ('From:         {0}/{1}' -f $StorageAccountName, $ContainerName) -Min Quiet
    Write-Log ('Onto:         {0}' -f $DestinationInstance) -Min Quiet
    foreach ($outcome in $results) {
        $line = '{0,-12} {1}' -f $outcome.Result, $outcome.Database
        if ($outcome.BackupTaken) { $line += ' (data as at {0})' -f (Format-Stamp $outcome.BackupTaken -Utc) }
        if ($outcome.Encryption) { $line += ' - ' + $outcome.Encryption }
        if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
        Write-Log $line -Level $(if ($outcome.Result -eq 'FAILED') { 'ERROR' } else { 'INFO' }) -Min Quiet
    }
    if ($script:Level -ge $script:LevelRank['Normal']) {
        foreach ($step in $script:Steps) { Write-Log ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
    }
    # a database still encrypting is not done: it is shut, and something has to be run on it later
    $failedCount = @($results | Where-Object { $_.Result -in 'FAILED', 'ENCRYPTING' }).Count
    $doneCount = @($results | Where-Object { $_.Result -in 'DONE', 'RESTORED', 'DRY RUN' }).Count
    $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
               elseif ($failedCount -gt 0 -and $doneCount -gt 0) { "PARTLY DONE ($doneCount of $($results.Count))" }
               elseif ($failedCount -gt 0) { 'FAILED' }
               elseif ($doneCount -gt 0) { 'DONE' }
               else { 'NOTHING DONE' }
    $bad = (-not $setupDone) -or $failedCount -gt 0
    Write-Log ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) -Level $(if ($bad) { 'ERROR' } else { 'INFO' }) -Min Quiet
    if ($script:LogFilePath) { Write-Log "Log file:     $script:LogFilePath" -Min Quiet }
    $script:ExitBad = $bad
}

if (-not $setupDone) { exit 2 }
if ($script:ExitBad) { exit 1 }
exit 0
