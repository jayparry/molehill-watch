#Requires -Version 5.1

<#
.SYNOPSIS
    Copies an Azure SQL Database to one or more target logical servers and swaps it in
    place of the existing database on each.

.DESCRIPTION
    Molehill Data Services

    For each target server (all copies run in parallel server-side):
      1. Starts CREATE DATABASE ... AS COPY OF on the target server's master database.
      2. Polls until the copy is ONLINE, fails, or times out.
      3. Renames the existing target database to <TargetDatabase>-prev-<stamp>.
      4. Renames the copy to <TargetDatabase>.
      5. Drops the previous database (unless -KeepPrevious).

    If step 4 fails, step 3 is rolled back so the environment keeps its original database.

    Safe by default: without -Execute, preflight checks run (read-only) and the planned
    SQL is printed. Nothing is created, renamed or dropped.

.PARAMETER SourceServer
    Source logical server. Short name (sql-my-ser) or FQDN (sql-my-ser.database.windows.net).

.PARAMETER SourceDatabase
    Database to copy.

.PARAMETER TargetServer
    One or more target logical servers, one per environment.

.PARAMETER TargetDatabase
    Name the database should have on each target. Defaults to SourceDatabase.

.PARAMETER ServiceObjective
    Optional service objective for the copy, e.g. S2, GP_Gen5_2. Defaults to the source's.

.PARAMETER ElasticPool
    Optional elastic pool name on the target server. Cannot be combined with ServiceObjective.

.PARAMETER SqlCredential
    The user and secret for whichever -Authentication needs one: a SQL login and its password, an
    Entra account and its password, or a service principal's application id and client secret.

.PARAMETER UserName
    Who to sign in as, without a password. For EntraMfa this is the account the browser prompt
    starts from; for EntraManagedIdentity it is the client id of a user-assigned identity. Giving
    this and nothing else means EntraMfa, because a name with no secret is a person about to be
    prompted.

.PARAMETER AccessToken
    A bearer token for https://database.windows.net/, used instead of signing in. Both drivers take
    one, so this needs no module at all:

        az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv

    It goes on the connection rather than into the connection string, and cannot be combined with
    -Authentication, because the driver refuses to have both.

.PARAMETER Authentication
    How to authenticate, under the same names the connect screen in this toolkit uses. Left out, it
    follows what else was given: -AccessToken means Token, -SqlCredential means Sql, -UserName alone
    means EntraMfa, and nothing at all means EntraDefault.

    Windows, Sql, Token                          work with no module installed
    EntraPassword, EntraMfa, EntraIntegrated     Windows PowerShell 5.1 can do these unaided
    EntraDefault, EntraManagedIdentity,
    EntraServicePrincipal, EntraDeviceCode       need Microsoft.Data.SqlClient, which arrives
                                                 with the SqlServer module

    Which driver can do what is asked of the driver rather than assumed, so the refusal comes
    before anything is created rather than at the first connection. If signing in fails, what else
    this machine could have used is printed.

    EntraDefault is the one to be careful with: it walks a chain of ways to sign in and can settle
    on integrated Windows authentication, which is not what anyone with MFA wants. Say EntraMfa.

.PARAMETER ConnectionString
    A connection string to use instead of building one, for anything the parameters above do not
    cover. Its Data Source and Initial Catalog are replaced per server, because every statement
    here runs against one master or another; everything else in it is kept as written.

.PARAMETER ConnectTimeoutSeconds
    How long to wait for a connection. Default 30.

.PARAMETER TrustServerCertificate
    Skip validating the server certificate. Azure SQL does not need this; a local instance with a
    self-signed certificate does.

.PARAMETER PollSeconds
    Seconds between status checks. Default 30.

.PARAMETER TimeoutMinutes
    Maximum wait for all copies. Default 240.

.PARAMETER KeepPrevious
    Keep the replaced database as <TargetDatabase>-prev-<stamp> instead of dropping it.

.PARAMETER Execute
    Actually run the copy, rename and drop. Without it the script is a dry run.

.PARAMETER SelfTest
    Checks the parts of this script that need no server: the name handling, the SQL it builds,
    the swap plan, and the refusal to copy a database over itself. Connects to nothing.
    Exit code: 0 = all passed, 1 = something failed.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test, sql-oof-uat -TargetDatabase oof-web

    Dry run against three environments.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test -TargetDatabase oof-web `
        -UserName jay@example.com -Execute

    Entra sign-in with MFA: a browser opens once, and every connection after that reuses the token
    the driver cached. -UserName on its own means EntraMfa, so -Authentication can be left out.

.EXAMPLE
    .\Copy-AzureSqlDatabase.ps1 -SourceServer sql-my-ser -SourceDatabase oof-web-src `
        -TargetServer sql-oof-dev, sql-oof-test -TargetDatabase oof-web `
        -ElasticPool pool-nonprod -Execute
#>
[CmdletBinding()]
param(
    # not Mandatory on purpose: a missing Mandatory parameter makes PowerShell prompt, and a prompt
    # in a pipeline or a scheduled run is a hang rather than a failure. They are checked below.
    [string]$SourceServer,
    [string]$SourceDatabase,
    [string[]]$TargetServer,
    [string]$TargetDatabase = $SourceDatabase,
    [string]$ServiceObjective,
    [string]$ElasticPool,
    [pscredential]$SqlCredential,
    [string]$UserName,
    [string]$AccessToken,
    [ValidateSet('Windows', 'Sql', 'Token', 'EntraDefault', 'EntraManagedIdentity', 'EntraServicePrincipal',
                 'EntraPassword', 'EntraIntegrated', 'EntraMfa', 'EntraDeviceCode')]
    [string]$Authentication,
    [string]$ConnectionString,
    [ValidateRange(5, 300)][int]$ConnectTimeoutSeconds = 30,
    [switch]$TrustServerCertificate,
    [ValidateRange(5, 600)][int]$PollSeconds = 30,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 240,
    [switch]$KeepPrevious,
    [switch]$Execute,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host ('{0:yyyy-MM-dd HH:mm:ss}  {1,-5}  {2}' -f (Get-Date), $Level, $Message) -ForegroundColor $colour
}

function Resolve-ServerName {
    param([string]$Name)
    $short = ($Name -split '\.')[0].ToLowerInvariant()
    $fqdn  = if ($Name -like '*.*') { $Name.ToLowerInvariant() } else { "$short.database.windows.net" }
    [pscustomobject]@{ Short = $short; Fqdn = $fqdn }
}

function ConvertTo-QuotedName {
    param([string]$Name)
    '[' + $Name.Replace(']', ']]') + ']'
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

# What each way of signing in is called in a connection string. $null means it is not a keyword at
# all: Windows authentication is Integrated Security, and SQL authentication is a user and password.
$script:AuthKeyword = @{
    Windows               = $null
    Sql                   = $null
    Token                 = $null
    EntraDefault          = 'Active Directory Default'
    EntraManagedIdentity  = 'Active Directory Managed Identity'
    EntraServicePrincipal = 'Active Directory Service Principal'
    EntraPassword         = 'Active Directory Password'
    EntraIntegrated       = 'Active Directory Integrated'
    EntraMfa              = 'Active Directory Interactive'
    EntraDeviceCode       = 'Active Directory Device Code Flow'
}

function Test-AuthKeyword {
    # Asked of the driver rather than kept in a table here, because the answer moves and a table
    # would quietly stop being true. Measured on this machine: System.Data.SqlClient under Windows
    # PowerShell 5.1 takes Active Directory Integrated, Password and Interactive; the same namespace
    # under PowerShell 7 takes no Entra keyword at all; Microsoft.Data.SqlClient takes all of them.
    param([string]$Namespace, [string]$Keyword)

    $type = "$Namespace.SqlConnectionStringBuilder" -as [type]
    if (-not $type) { return $false }
    if (-not $Keyword) { return $true }
    try {
        $builder = New-Object $type
        $builder['Authentication'] = $Keyword
        $true
    }
    catch { $false }
}

function Resolve-SqlDriver {
    # The driver that needs nothing installed is preferred, and Microsoft's is reached for only
    # when what was asked for needs it. If neither can do it, that is said here - before a database
    # is created - rather than at the first connection, with the three ways out named.
    param([string]$Authentication)

    $keyword = $script:AuthKeyword[$Authentication]
    if (Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword $keyword) { return 'System.Data.SqlClient' }

    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type])) {
        try { Import-Module SqlServer -DisableNameChecking -ErrorAction Stop } catch { }
    }
    if (Test-AuthKeyword -Namespace 'Microsoft.Data.SqlClient' -Keyword $keyword) { return 'Microsoft.Data.SqlClient' }

    throw ("-Authentication $Authentication needs the Microsoft.Data.SqlClient driver, and nothing " +
           "on this machine provides it. Install-Module SqlServer brings it; or use " +
           "-Authentication Sql with -SqlCredential; or hand a whole connection string to " +
           "-ConnectionString. On Windows PowerShell 5.1 the built-in driver can do EntraPassword, " +
           "EntraMfa and EntraIntegrated unaided.")
}

function New-MasterConnectionString {
    # Everything it needs is passed in rather than read from the script around it, so the string it
    # builds can be checked without a server to connect to.
    param(
        [string]$Namespace,
        [string]$Server,
        [string]$Database = 'master',
        [string]$Authentication,
        [pscredential]$Credential,
        [string]$User,
        [string]$Template,
        [int]$Timeout = 30,
        [bool]$Trust = $false
    )

    $builder = New-Object "$Namespace.SqlConnectionStringBuilder"

    if ($Template) {
        # handed one wholesale. The server and the database are still settled here: this script
        # talks to several servers and every statement it runs goes to one master or another, so a
        # single string cannot carry them.
        #
        # .psbase, and not $builder.ConnectionString = ..., because this class implements IDictionary
        # and PowerShell binds a property *assignment* on it to a dictionary key instead of to the
        # property. Setting it the obvious way throws "Keyword not supported: 'ConnectionString'",
        # while *reading* $builder.ConnectionString works fine - which is why only one of the two
        # needs this.
        $builder.psbase.ConnectionString = $Template
        if ($Server) { $builder['Data Source'] = $Server }
        $builder['Initial Catalog'] = $Database
        return $builder.ConnectionString
    }

    # a method nobody has heard of would otherwise fall through to no keyword, no user and no
    # integrated security, which the server answers with "Login failed for user ''" - a message
    # that describes neither the cause nor the fix
    if (-not $script:AuthKeyword.ContainsKey([string]$Authentication)) {
        throw ("There is no way of signing in called '{0}'. It has to be one of: {1}." -f
               $Authentication, (($script:AuthKeyword.Keys | Sort-Object) -join ', '))
    }

    $builder['Data Source'] = $Server
    $builder['Initial Catalog'] = $Database
    $builder['Connect Timeout'] = $Timeout
    $builder['Application Name'] = 'Copy-AzureSqlDatabase'
    # explicit, because the drivers disagree: System.Data.SqlClient defaults to no encryption and
    # Microsoft.Data.SqlClient 4.0 onwards defaults to requiring it. Azure SQL insists either way,
    # so saying so here means the string means the same thing whichever driver was picked.
    $builder['Encrypt'] = $true
    if ($Trust) { $builder['TrustServerCertificate'] = $true }

    $keyword = $script:AuthKeyword[$Authentication]
    if ($keyword) { $builder['Authentication'] = $keyword }

    # -UserName wins over the credential's user, so a name can be given without a password. That
    # matters for the interactive methods, where there is no password to give: being made to produce
    # a pscredential just to say who you are means inventing a password for a prompt that will
    # never use it.
    $who = $(if ($User) { $User } elseif ($Credential) { $Credential.UserName } else { '' })

    if ($Authentication -eq 'Windows') { $builder['Integrated Security'] = $true }
    elseif ($Authentication -eq 'Sql') {
        if (-not $Credential) { throw '-Authentication Sql needs -SqlCredential.' }
        $builder['User ID'] = $who
        $builder['Password'] = $Credential.GetNetworkCredential().Password
    }
    elseif ($Authentication -eq 'Token') {
        # nothing goes in the string for this one. The token is set on the connection object, and
        # the driver refuses to have both: "Cannot set the AccessToken property if 'Authentication'
        # has been specified in the connection string."
    }
    else {
        # the Entra methods take the user as the user ID - an account to sign in as, a service
        # principal's application id, or the client id of a user-assigned managed identity - and
        # only two of them have a secret to go with it
        if ($who) { $builder['User ID'] = $who }
        if ($Credential -and ($Authentication -eq 'EntraPassword' -or $Authentication -eq 'EntraServicePrincipal')) {
            $builder['Password'] = $Credential.GetNetworkCredential().Password
        }
    }

    $builder.ConnectionString
}

function Invoke-MasterQuery {
    param(
        [string]$Server,
        [string]$Query,
        [int]$Timeout = 60
    )
    $connectionString = New-MasterConnectionString -Namespace $script:Driver -Server $Server `
        -Authentication $script:AuthMethod -Credential $SqlCredential -User $UserName `
        -Template $ConnectionString -Timeout $ConnectTimeoutSeconds -Trust ([bool]$TrustServerCertificate)

    $connection = New-Object "$script:Driver.SqlConnection" $connectionString
    try {
        # on the object rather than in the string, which is the only place it can go. Both drivers
        # take it, so a token needs no module at all - az account get-access-token is enough.
        if ($script:AuthMethod -eq 'Token') { $connection.AccessToken = $AccessToken }
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $Timeout
        $table = New-Object System.Data.DataTable
        [void](New-Object "$script:Driver.SqlDataAdapter" $command).Fill($table)
        # the rows, not the table: that is what Invoke-Sqlcmd handed back, so everything that reads
        # a column off a result did not have to change. Emitted one at a time rather than returned
        # as an array, so a caller's @(...).Count is the number of rows and not 1.
        foreach ($row in $table.Rows) { $row }
    }
    finally { $connection.Dispose() }
}

function Test-DatabaseExists {
    param([string]$Server, [string]$Name)

    # @() and a row count, rather than reading .n off whatever came back. Under
    # Set-StrictMode -Version Latest a result that is not one row makes $r.n throw "The property
    # 'n' cannot be found on this object", and the preflight below records that against the server
    # as its reason for failing - which reads like a bug in this script rather than a server that
    # answered oddly, and sends whoever is looking at it to the wrong place entirely.
    $rows = @(Invoke-MasterQuery -Server $Server -Query "SELECT COUNT(*) AS n FROM sys.databases WHERE name = $(ConvertTo-SqlLiteral $Name);")
    if ($rows.Count -ne 1) {
        throw "Counting $Name on $Server came back as $($rows.Count) row(s) instead of one, so whether it exists is not known."
    }
    [int]$rows[0].n -gt 0
}

function Get-NameStamp {
    # The invariant culture, not the server's. 'yyyy' under a Thai or Hijri calendar gives 2569 or
    # 1448, so the same run would name its databases differently depending on the region the
    # machine happens to be set to - and nobody looking for yesterday's copy is going to search for
    # oof-web-prev-256910221700.
    param([datetime]$When = (Get-Date))
    $When.ToString('yyyyMMddHHmm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-CopyStatement {
    param(
        [string]$SourceServerShort,
        [string]$SourceDatabase,
        [string]$CopyName,
        [string]$ServiceObjective,
        [string]$ElasticPool
    )
    if ($ServiceObjective -and $ElasticPool) {
        throw 'Specify either -ServiceObjective or -ElasticPool, not both.'
    }

    $qSource = '{0}.{1}' -f (ConvertTo-QuotedName $SourceServerShort), (ConvertTo-QuotedName $SourceDatabase)

    $with = ''
    if ($ServiceObjective) {
        $with = " ( SERVICE_OBJECTIVE = '{0}' )" -f $ServiceObjective.Replace("'", "''")
    }
    elseif ($ElasticPool) {
        $with = ' ( SERVICE_OBJECTIVE = ELASTIC_POOL( name = {0} ) )' -f (ConvertTo-QuotedName $ElasticPool)
    }

    "CREATE DATABASE $(ConvertTo-QuotedName $CopyName) AS COPY OF $qSource$with;"
}

function Get-SwapPlan {
    # The statements that put the copy in place, in the order they have to happen. One function so
    # the dry run prints the plan that the swap below actually carries out, rather than a second
    # list beside it that can drift from it.
    param(
        [string]$TargetDatabase,
        [string]$CopyName,
        [string]$PreviousName,
        [bool]$TargetExists,
        [bool]$KeepPrevious
    )
    $qTarget = ConvertTo-QuotedName $TargetDatabase
    $qCopy   = ConvertTo-QuotedName $CopyName
    $qPrev   = ConvertTo-QuotedName $PreviousName

    $plan = @()
    if ($TargetExists) { $plan += "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" }
    $plan += "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;"
    # nothing to drop when there was nothing there: the copy is the first database of that name
    if ($TargetExists -and -not $KeepPrevious) { $plan += "DROP DATABASE $qPrev;" }
    $plan
}

# What a failure that is really about signing in looks like, as opposed to one about the network or
# the database. Kept in one place because two paths need the same answer, and getting it wrong in
# either direction is its own annoyance: silence when the advice was wanted, or a lecture about
# authentication when the server simply is not there.
#
# Being refused access to a database is deliberately not in here. "The server principal is not able
# to access the database" means signing in *worked* and a grant is missing, so telling someone to
# try a different way of signing in would send them the wrong way entirely.
$script:SignInPattern = '(?i)login failed|authenticat|\btoken\b|credential|AADSTS|MSAL|interactive|integrated|not supported|password'

function Get-AuthAdvice {
    # What this machine could actually sign in with, said when signing in did not work. The failure
    # that prompted this said nothing about the alternatives, and working out that PowerShell 7's
    # built-in driver takes no Entra keyword - so EntraDefault walks a chain that can land on
    # integrated Windows authentication and fail there - is not a thing anyone should have to
    # discover from a stack trace.
    param([string]$Tried, [string[]]$Available)

    $lines = @("Signing in with -Authentication $Tried did not work. On this machine you can also use:")
    foreach ($method in $Available) {
        if ($method -eq $Tried) { continue }
        $how = switch ($method) {
            'EntraMfa'              { '-Authentication EntraMfa -UserName you@yourtenant.com   (opens a browser; this is the one for MFA)' }
            'EntraDeviceCode'       { '-Authentication EntraDeviceCode                          (sign in on another device)' }
            'EntraPassword'         { '-Authentication EntraPassword -SqlCredential (Get-Credential)' }
            'EntraIntegrated'       { '-Authentication EntraIntegrated                          (domain joined to Entra, already signed in)' }
            'EntraManagedIdentity'  { '-Authentication EntraManagedIdentity                     (on an Azure VM)' }
            'EntraServicePrincipal' { '-Authentication EntraServicePrincipal -SqlCredential (app id as the user, secret as the password)' }
            'EntraDefault'          { '-Authentication EntraDefault                             (whatever this machine is signed in as)' }
            'Sql'                   { '-Authentication Sql -SqlCredential (Get-Credential)      (a login on the server)' }
            'Token'                 { '-AccessToken (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)' }
            default                 { "-Authentication $method" }
        }
        $lines += "    $how"
    }
    $lines
}

function Get-AvailableAuth {
    # The methods something here can actually carry out, asked of the drivers. Microsoft's driver is
    # loaded only when a connection needs it, so it is reached for once here as well - otherwise a
    # run that signed in with the built-in driver reports only what *that* one can do, and the
    # advice leaves out the very method that would have worked.
    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type])) {
        try { Import-Module SqlServer -DisableNameChecking -ErrorAction Stop } catch { }
    }

    $available = @()
    foreach ($method in 'Sql', 'Token', 'EntraMfa', 'EntraDeviceCode', 'EntraPassword', 'EntraIntegrated',
                        'EntraDefault', 'EntraManagedIdentity', 'EntraServicePrincipal', 'Windows') {
        $keyword = $script:AuthKeyword[$method]
        if ((Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword $keyword) -or
            (Test-AuthKeyword -Namespace 'Microsoft.Data.SqlClient' -Keyword $keyword)) {
            $available += $method
        }
    }
    $available
}

function Get-SourceClash {
    # The one refusal that matters. Copying a database over itself would rename the source aside
    # and then drop it, which is the whole environment gone rather than a failed run. Same server
    # and same name is the source; same server and a different name is an ordinary copy within one
    # logical server, and a different server with the same name is the normal case.
    param(
        [string]$TargetFqdn,
        [string]$TargetDatabase,
        [string]$SourceFqdn,
        [string]$SourceDatabase
    )
    if ($TargetFqdn -eq $SourceFqdn -and $TargetDatabase -eq $SourceDatabase) {
        return "Target $TargetFqdn / $TargetDatabase is the source database. Refusing to overwrite the source."
    }
    ''
}

#endregion

#region Self test

# Everything above that does not need a server. It runs before the setup below so that -SelfTest
# never looks for an Az context or opens a connection.
if ($SelfTest) {
    $script:failed = 0
    function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    function Threw([scriptblock]$Body) {
        try { & $Body | Out-Null; '' } catch { ($_.Exception.Message -split "`r?`n")[0] }
    }

    Write-Host 'Copy-AzureSqlDatabase self test' -ForegroundColor Cyan
    Write-Host '  server names' -ForegroundColor Gray

    # -ceq throughout, not -eq: PowerShell compares strings case-insensitively, so -eq here would
    # pass whether or not the lower-casing happened at all. These checks are about the case.
    $short = Resolve-ServerName 'sql-my-ser'
    Check 'a short name keeps its short form' ($short.Short -ceq 'sql-my-ser') $short.Short
    Check 'and gets the Azure SQL suffix' ($short.Fqdn -ceq 'sql-my-ser.database.windows.net') $short.Fqdn

    $full = Resolve-ServerName 'sql-my-ser.database.windows.net'
    Check 'an FQDN is left as it is' ($full.Fqdn -ceq 'sql-my-ser.database.windows.net') $full.Fqdn
    Check 'and still yields the short name for AS COPY OF' ($full.Short -ceq 'sql-my-ser') $full.Short

    $loud = Resolve-ServerName 'SQL-MY-SER.Database.Windows.Net'
    Check 'case is flattened, so the same server is the same server' (
        $loud.Fqdn -ceq $full.Fqdn -and $loud.Short -ceq $full.Short) "$($loud.Short) / $($loud.Fqdn)"
    Check 'and it really is lower-cased rather than merely compared loosely' (
        $loud.Short -ceq 'sql-my-ser' -and $loud.Fqdn -ceq 'sql-my-ser.database.windows.net')
        "$($loud.Short) / $($loud.Fqdn)"

    # a private endpoint or a sovereign cloud is somebody else's suffix, not ours to replace
    $other = Resolve-ServerName 'sql-my-ser.privatelink.database.chinacloudapi.cn'
    Check 'a suffix that is not ours is not rewritten' (
        $other.Fqdn -ceq 'sql-my-ser.privatelink.database.chinacloudapi.cn') $other.Fqdn

    Write-Host '  quoting' -ForegroundColor Gray
    Check 'a name is bracketed' ((ConvertTo-QuotedName 'oof-web') -eq '[oof-web]') (ConvertTo-QuotedName 'oof-web')
    Check 'a closing bracket in a name is doubled, not left to close the quoting early' (
        (ConvertTo-QuotedName 'od]d') -eq '[od]]d]') (ConvertTo-QuotedName 'od]d')
    Check 'a literal is an N string' ((ConvertTo-SqlLiteral 'oof-web') -eq "N'oof-web'") (ConvertTo-SqlLiteral 'oof-web')
    Check 'and a quote in one is doubled' ((ConvertTo-SqlLiteral "o'd") -eq "N'o''d'") (ConvertTo-SqlLiteral "o'd")

    Write-Host '  the copy statement' -ForegroundColor Gray
    $plain = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' -CopyName 'oof-web-copy-1'
    Check 'it copies from server.database, which is what AS COPY OF wants' (
        $plain -eq 'CREATE DATABASE [oof-web-copy-1] AS COPY OF [sql-my-ser].[oof-web-src];') $plain

    $sized = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' `
                               -CopyName 'oof-web-copy-1' -ServiceObjective 'GP_Gen5_2'
    Check 'a service objective is passed through' ($sized -match "SERVICE_OBJECTIVE = 'GP_Gen5_2' \)") $sized

    $pooled = New-CopyStatement -SourceServerShort 'sql-my-ser' -SourceDatabase 'oof-web-src' `
                                -CopyName 'oof-web-copy-1' -ElasticPool 'pool-nonprod'
    Check 'an elastic pool goes in as a pool, bracketed' (
        $pooled -match 'ELASTIC_POOL\( name = \[pool-nonprod\] \)') $pooled

    Check 'asking for both is refused' (
        (Threw { New-CopyStatement -SourceServerShort 's' -SourceDatabase 'd' -CopyName 'c' `
                                   -ServiceObjective 'S2' -ElasticPool 'p' }) -match 'not both')

    # the objective is a string in the statement rather than an identifier, so it is the one place
    # a quote could end the literal early
    $quoted = New-CopyStatement -SourceServerShort 's' -SourceDatabase 'd' -CopyName 'c' -ServiceObjective "S2' --"
    Check 'a quote in the objective cannot end the string early' ($quoted -match "'S2'' --'") $quoted

    Write-Host '  the swap plan' -ForegroundColor Gray
    $replace = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                              -PreviousName 'oof-web-prev-1' -TargetExists $true -KeepPrevious $false)
    Check 'replacing takes three statements' ($replace.Count -eq 3) "$($replace.Count)"
    Check 'the live one is moved aside first' ($replace[0] -eq 'ALTER DATABASE [oof-web] MODIFY NAME = [oof-web-prev-1];') $replace[0]
    Check 'then the copy takes its name' ($replace[1] -eq 'ALTER DATABASE [oof-web-copy-1] MODIFY NAME = [oof-web];') $replace[1]
    Check 'and only the one moved aside is dropped' ($replace[2] -eq 'DROP DATABASE [oof-web-prev-1];') $replace[2]

    $kept = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                           -PreviousName 'oof-web-prev-1' -TargetExists $true -KeepPrevious $true)
    Check 'keeping the previous one drops nothing' (
        $kept.Count -eq 2 -and -not @($kept | Where-Object { $_ -match 'DROP' }).Count) ($kept -join ' ')

    $fresh = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                            -PreviousName 'oof-web-prev-1' -TargetExists $false -KeepPrevious $false)
    Check 'a target that does not exist is only renamed into place' ($fresh.Count -eq 1) ($fresh -join ' ')
    Check 'and nothing is dropped when there was nothing there' (
        -not @($fresh | Where-Object { $_ -match 'DROP' }).Count) ($fresh -join ' ')

    # the check that matters: whatever the combination, the only thing a plan ever drops is the
    # database that was renamed out of the way
    foreach ($exists in $true, $false) {
        foreach ($keep in $true, $false) {
            $plan = @(Get-SwapPlan -TargetDatabase 'oof-web' -CopyName 'oof-web-copy-1' `
                                   -PreviousName 'oof-web-prev-1' -TargetExists $exists -KeepPrevious $keep)
            $drops = @($plan | Where-Object { $_ -match '^DROP' })
            Check "nothing but the moved-aside copy is dropped (exists=$exists, keep=$keep)" (
                -not @($drops | Where-Object { $_ -notmatch '\[oof-web-prev-1\];$' }).Count) ($drops -join ' ')
        }
    }

    Write-Host '  refusing to copy a database over itself' -ForegroundColor Gray
    $src = Resolve-ServerName 'sql-my-ser'
    Check 'the same server and the same name is the source, and is refused' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing to overwrite the source')
    Check 'the same server under another name is an ordinary copy' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'oof-web-dev' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -eq '')
    Check 'another server with the same name is the normal case' (
        (Get-SourceClash -TargetFqdn 'sql-oof-dev.database.windows.net' -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -eq '')
    # the comparison happens after Resolve-ServerName, so a shouted target cannot slip past it
    Check 'a differently cased server name does not get past it' (
        (Get-SourceClash -TargetFqdn (Resolve-ServerName 'SQL-MY-SER').Fqdn -TargetDatabase 'oof-web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing')
    Check 'and nor does a differently cased database name' (
        (Get-SourceClash -TargetFqdn $src.Fqdn -TargetDatabase 'OOF-Web' `
                         -SourceFqdn $src.Fqdn -SourceDatabase 'oof-web') -match 'Refusing')

    Write-Host '  which driver can do what' -ForegroundColor Gray
    Check 'a driver that is not installed cannot do anything' (
        -not (Test-AuthKeyword -Namespace 'Nonsense.Driver' -Keyword $null))
    Check 'the built-in driver needs no keyword for SQL or Windows authentication' (
        Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword $null)
    # true on both editions, measured: managed identity is Microsoft's driver or nothing
    Check 'and it cannot do managed identity on either edition' (
        -not (Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword 'Active Directory Managed Identity'))

    Check 'Windows authentication needs nothing installed' (
        (Resolve-SqlDriver -Authentication 'Windows') -eq 'System.Data.SqlClient')
    Check 'and nor does SQL authentication' (
        (Resolve-SqlDriver -Authentication 'Sql') -eq 'System.Data.SqlClient')

    # the invariant that holds whatever is installed and whichever edition this is: the driver
    # chosen is one that was asked and said yes, and if neither can, it is a refusal that says how
    # to fix it rather than a failure at the first connection
    foreach ($method in 'EntraIntegrated', 'EntraManagedIdentity', 'EntraDefault', 'EntraMfa') {
        $keyword = $script:AuthKeyword[$method]
        $builtInCan = Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword $keyword
        $chosen = ''
        $refusal = Threw { $script:chosen = Resolve-SqlDriver -Authentication $method }
        if (-not $refusal) { $chosen = $script:chosen }

        if ($builtInCan) {
            Check "$method goes to the built-in driver, which said it can" ($chosen -eq 'System.Data.SqlClient') $chosen
        }
        elseif ($chosen) {
            Check "$method goes to Microsoft's driver, which said it can" ($chosen -eq 'Microsoft.Data.SqlClient') $chosen
            Check "and that driver really does take $keyword" (Test-AuthKeyword -Namespace $chosen -Keyword $keyword)
        }
        else {
            Check "$method is refused with the way out named" (
                $refusal -match 'Install-Module SqlServer' -and $refusal -match '-Authentication Sql') $refusal
        }
    }

    Write-Host '  the connection string it builds' -ForegroundColor Gray
    $secret = "p@ss;word''s"      # a semicolon and quotes, which a connection string must survive
    $cred = New-Object pscredential 'svc_copy', (ConvertTo-SecureString $secret -AsPlainText -Force)
    function Read-Back([string]$Namespace, [string]$Text) {
        $b = New-Object "$Namespace.SqlConnectionStringBuilder"
        $b.psbase.ConnectionString = $Text      # see the note in New-MasterConnectionString
        $b
    }
    # ContainsKey first, because under Set-StrictMode -Version Latest reading a key the driver does
    # not support throws "Keyword not supported" rather than coming back empty - and whether a
    # driver supports Authentication is the very thing some of these checks are asking about
    function Setting($Builder, [string]$Key) {
        if (-not $Builder.psbase.ContainsKey($Key)) { return '' }
        $value = $null
        if (-not $Builder.psbase.TryGetValue($Key, [ref]$value)) { return '' }
        $value
    }

    $windows = Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
        -Server 'sql-oof-dev.database.windows.net' -Authentication 'Windows' -Timeout 30)
    Check 'Windows authentication is integrated security' ((Setting $windows 'Integrated Security') -eq $true)
    Check 'the database is always master' ((Setting $windows 'Initial Catalog') -ceq 'master') (Setting $windows 'Initial Catalog')
    Check 'the server is the one asked for' ((Setting $windows 'Data Source') -ceq 'sql-oof-dev.database.windows.net') (Setting $windows 'Data Source')
    Check 'the timeout is carried through' ((Setting $windows 'Connect Timeout') -eq 30) "$(Setting $windows 'Connect Timeout')"
    Check 'and it says which script opened the connection' ((Setting $windows 'Application Name') -ceq 'Copy-AzureSqlDatabase') (Setting $windows 'Application Name')
    Check 'encryption is asked for rather than left to the driver default' (
        (Setting $windows 'Encrypt') -eq $true) "$(Setting $windows 'Encrypt')"

    $sql = Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
        -Server 'sql-oof-dev.database.windows.net' -Authentication 'Sql' -Credential $cred)
    Check 'SQL authentication carries the login' ((Setting $sql 'User ID') -ceq 'svc_copy') (Setting $sql 'User ID')
    Check 'and a password with a semicolon and quotes in it survives the round trip' (
        (Setting $sql 'Password') -ceq $secret) '(not shown)'
    Check 'SQL authentication is not an Entra keyword' (-not (Setting $sql 'Authentication'))

    Check 'SQL authentication with no credential is refused by name' (
        (Threw { New-MasterConnectionString -Namespace 'System.Data.SqlClient' -Server 's' -Authentication 'Sql' }) `
        -match '-SqlCredential')

    Check 'a trusted certificate is only set when asked for' (
        -not (Setting (Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
            -Server 's' -Authentication 'Windows')) 'TrustServerCertificate'))
    Check 'and is set when it is' (
        (Setting (Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
            -Server 's' -Authentication 'Windows' -Trust $true)) 'TrustServerCertificate') -eq $true)

    # a whole connection string keeps everything in it except where it points, because this script
    # talks to several servers and one string cannot name them all
    $template = 'Data Source=somewhere-else;Initial Catalog=the-wrong-one;Application Name=Theirs;Connect Timeout=7'
    $fromTemplate = Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
        -Server 'sql-oof-test.database.windows.net' -Template $template)
    Check 'the server in a given connection string is replaced per target' (
        (Setting $fromTemplate 'Data Source') -ceq 'sql-oof-test.database.windows.net') (Setting $fromTemplate 'Data Source')
    Check 'and so is the database, because every statement here runs against master' (
        (Setting $fromTemplate 'Initial Catalog') -ceq 'master') (Setting $fromTemplate 'Initial Catalog')
    Check 'everything else in it is left exactly as written' (
        (Setting $fromTemplate 'Application Name') -ceq 'Theirs' -and (Setting $fromTemplate 'Connect Timeout') -eq 7) `
        "$(Setting $fromTemplate 'Application Name') / $(Setting $fromTemplate 'Connect Timeout')"

    $entraDriver = ''
    foreach ($candidate in 'System.Data.SqlClient', 'Microsoft.Data.SqlClient') {
        if (-not $entraDriver -and (Test-AuthKeyword -Namespace $candidate -Keyword 'Active Directory Default')) {
            $entraDriver = $candidate
        }
    }
    if (-not $entraDriver) {
        Write-Host '    SKIP  the Entra strings: no driver here takes the keywords' -ForegroundColor Yellow
    }
    else {
        $def = Read-Back $entraDriver (New-MasterConnectionString -Namespace $entraDriver `
            -Server 's' -Authentication 'EntraDefault')
        # the spaces come back out: a builder stores the keyword and hands it back as the enum name,
        # ActiveDirectoryDefault, so an assertion on the string as it went in would fail
        Check 'EntraDefault is the keyword and nothing else' (
            (Setting $def 'Authentication') -match 'Active\s*Directory\s*Default' -and
            -not (Setting $def 'User ID') -and -not (Setting $def 'Password')) `
            "$(Setting $def 'Authentication')"

        $mi = Read-Back $entraDriver (New-MasterConnectionString -Namespace $entraDriver `
            -Server 's' -Authentication 'EntraManagedIdentity' -Credential $cred)
        Check 'a user-assigned identity passes its client id as the user, with no password' (
            (Setting $mi 'User ID') -ceq 'svc_copy' -and -not (Setting $mi 'Password')) (Setting $mi 'User ID')

        $spn = Read-Back $entraDriver (New-MasterConnectionString -Namespace $entraDriver `
            -Server 's' -Authentication 'EntraServicePrincipal' -Credential $cred)
        Check 'a service principal passes both its application id and its secret' (
            (Setting $spn 'User ID') -ceq 'svc_copy' -and (Setting $spn 'Password') -ceq $secret) (Setting $spn 'User ID')
    }

    Write-Host '  signing in as a person, with no password to give' -ForegroundColor Gray
    # the whole point of -UserName: a name without having to invent a credential for a prompt that
    # will never use the password. Checked against whichever driver here takes the interactive
    # keyword - 5.1's built-in one does, 7's does not - so this runs on both editions.
    $mfaDriver = ''
    foreach ($candidate in 'System.Data.SqlClient', 'Microsoft.Data.SqlClient') {
        if (-not $mfaDriver -and (Test-AuthKeyword -Namespace $candidate -Keyword 'Active Directory Interactive')) {
            $mfaDriver = $candidate
        }
    }
    if (-not $mfaDriver) {
        Write-Host '    SKIP  the interactive user hint: no driver here takes the keyword' -ForegroundColor Yellow
    }
    else {
        $named = Read-Back $mfaDriver (New-MasterConnectionString -Namespace $mfaDriver `
            -Server 's' -Authentication 'EntraMfa' -User 'jay@example.com')
        Check 'a user name needs no credential to go with it' (
            (Setting $named 'User ID') -ceq 'jay@example.com' -and -not (Setting $named 'Password')) (Setting $named 'User ID')
        Check 'and it carries the interactive keyword, which is what opens the browser' (
            (Setting $named 'Authentication') -match 'Active\s*Directory\s*Interactive') "$(Setting $named 'Authentication')"
    }

    $both = Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
        -Server 's' -Authentication 'Sql' -Credential $cred -User 'someone.else')
    Check 'and it wins over the credential''s own user' ((Setting $both 'User ID') -ceq 'someone.else') (Setting $both 'User ID')
    Check 'while the credential still supplies the password' ((Setting $both 'Password') -ceq $secret) '(not shown)'

    $tokenString = Read-Back 'System.Data.SqlClient' (New-MasterConnectionString -Namespace 'System.Data.SqlClient' `
        -Server 's' -Authentication 'Token' -User 'ignored')
    Check 'a token puts nothing in the string: no keyword' (-not (Setting $tokenString 'Authentication'))
    Check 'no user' (-not (Setting $tokenString 'User ID')) (Setting $tokenString 'User ID')
    Check 'no password' (-not (Setting $tokenString 'Password'))
    Check 'and not integrated security either' (-not ((Setting $tokenString 'Integrated Security') -eq $true))
    Check 'a token needs no module, so the built-in driver can carry it' (
        (Resolve-SqlDriver -Authentication 'Token') -eq 'System.Data.SqlClient')
    # proven against the driver rather than assumed: this is why the token cannot go in the string
    $probe = New-Object System.Data.SqlClient.SqlConnection
    $probe.ConnectionString = 'Data Source=s'
    Check 'the connection object really does take a token' (
        -not (Threw { $probe.AccessToken = 'dummy' }))

    Write-Host '  what to try when signing in did not work' -ForegroundColor Gray
    $can = @(Get-AvailableAuth)
    Check 'SQL authentication is always possible' ($can -contains 'Sql') ($can -join ', ')
    Check 'and so is a token' ($can -contains 'Token')
    $advice = @(Get-AuthAdvice -Tried 'EntraDefault' -Available $can)
    Check 'the advice names what was tried' ($advice[0] -match 'EntraDefault did not work') $advice[0]
    Check 'and never suggests the thing that just failed' (
        -not @($advice | Select-Object -Skip 1 | Where-Object { $_ -match '-Authentication EntraDefault\b' }).Count)
    if ($can -contains 'EntraMfa') {
        Check 'MFA is offered, and says it opens a browser' (
            @($advice | Where-Object { $_ -match 'EntraMfa' -and $_ -match 'browser' }).Count -eq 1) ($advice -join ' | ')
        Check 'and it is shown with -UserName, which is how it is usable' (
            @($advice | Where-Object { $_ -match 'EntraMfa' -and $_ -match '-UserName' }).Count -eq 1)
    }
    # the pattern that decides whether the advice is wanted at all, both ways round
    Check 'a failed login counts as a sign-in problem' (
        'Login failed for user ''nosuchlogin''.' -match $script:SignInPattern)
    Check 'so does a token the server would not take' (
        'The access token is invalid.' -match $script:SignInPattern)
    # and the one that looks like it belongs here and does not: this is a grant that is missing, not
    # a sign-in that failed, so offering other ways to sign in would be pointing the wrong way
    Check 'being refused access to a database is not a sign-in problem' (
        'The server principal is not able to access the database under the current security context.' `
        -notmatch $script:SignInPattern)
    Check 'a server that is not there does not' (
        'The server was not found or was not accessible. (provider: TCP Provider, error: 0 - No such host is known.)' `
        -notmatch $script:SignInPattern)
    Check 'and nor does a database that is simply missing' (
        'Source database oof-web-src not found on sql-my-ser.database.windows.net.' -notmatch $script:SignInPattern)

    Check 'every line of advice is a thing you could type' (
        -not @($advice | Select-Object -Skip 1 | Where-Object { $_ -notmatch '-Authentication|-AccessToken' }).Count) `
        (@($advice | Select-Object -Skip 1 | Where-Object { $_ -notmatch '-Authentication|-AccessToken' }) -join ' | ')

    Write-Host '  nothing reaches for Az any more' -ForegroundColor Gray
    $own = Get-Content -Raw -LiteralPath $PSCommandPath
    # the commands this script actually calls, read from its own syntax tree rather than grepped
    # out of its text: these very checks have to name Get-AzAccessToken and Invoke-Sqlcmd to say
    # they are gone, so searching the source for the names would always find them
    $ownAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
    $called = @($ownAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    $az = @($called | Where-Object { $_ -match '^(?i)[a-z]+-Az[A-Z]' })
    Check 'no Az cmdlet is called' (-not $az.Count) ($az -join ', ')
    Check 'Invoke-Sqlcmd is not called either' (
        -not @($called | Where-Object { $_ -match '^(?i)Invoke-Sqlcmd$' }).Count)
    Check 'and no module is required for this to start at all' ($own -notmatch '(?im)^#Requires\s+-Modules')
    # SqlServer is still reached for, but only to borrow Microsoft's driver when something asked
    # for needs it, and never in a way that stops the script when it is not installed
    Check 'the SqlServer module is only ever reached for inside a try' (
        $own -match '(?s)try\s*\{\s*Import-Module SqlServer[^}]*\}\s*catch')
    # a structural check rather than a behavioural one, deliberately. A connection that is never
    # handed back cannot be caught by watching: the pool holds a hundred, and the garbage collector
    # returns the ones nobody disposed before a run this size notices. So the shape is checked
    # instead - this script polls once per interval for hours, and the hundred-and-first connection
    # failing is the sort of fault that shows up late and cannot be reproduced quickly.
    Check 'every connection it opens is handed back in a finally' (
        $own -match '(?s)\$connection\s*=\s*New-Object[^\r\n]+SqlConnection.+?finally\s*\{\s*\$connection\.Dispose\(\)\s*\}')

    Write-Host '  the stamp that goes in the names' -ForegroundColor Gray
    # the one check here that needs a culture that is not ours: th-TH counts years from a different
    # era, so a stamp built through the current culture comes out as 2569 rather than 2026
    $when = New-Object datetime 2026, 10, 22, 16, 45, 0
    $wasCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in 'en-GB', 'en-US', 'de-DE', 'th-TH') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
            Check "the same stamp under $culture" ((Get-NameStamp $when) -ceq '202610221645') (Get-NameStamp $when)
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $wasCulture }

    Write-Host '  counting a database before touching it' -ForegroundColor Gray
    # the rows Invoke-Sqlcmd would hand back, as the DataRows they really are
    function CountRows([int[]]$Counts) {
        $table = New-Object System.Data.DataTable
        [void]$table.Columns.Add('n', [int])
        foreach ($one in $Counts) { [void]$table.Rows.Add($one) }
        $table.Rows
    }
    $script:stubRows = @()
    function Invoke-MasterQuery { param([string]$Server, [string]$Query, [int]$Timeout = 60) $script:stubRows }

    $script:stubRows = @(CountRows 1)
    Check 'one row saying one means the database is there' (Test-DatabaseExists -Server 's' -Name 'd')
    $script:stubRows = @(CountRows 0)
    Check 'one row saying none means it is not' (-not (Test-DatabaseExists -Server 's' -Name 'd'))

    $script:stubRows = @()
    $noRows = Threw { Test-DatabaseExists -Server 'sql-oof-dev.database.windows.net' -Name 'oof-web' }
    Check 'no rows at all is refused, not read as a missing property' ($noRows -match 'instead of one') $noRows
    Check 'and the refusal says which database on which server' (
        $noRows -match 'oof-web' -and $noRows -match 'sql-oof-dev') $noRows
    Check 'nothing about a property that cannot be found' ($noRows -notmatch 'cannot be found') $noRows

    $script:stubRows = @(CountRows 1, 1)
    Check 'and more than one row is refused too' (
        (Threw { Test-DatabaseExists -Server 's' -Name 'd' }) -match 'instead of one')

    Write-Host ''
    if ($script:failed -eq 0) { Write-Host 'All self tests passed.' -ForegroundColor Green; exit 0 }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#endregion

#region Setup

$missing = @()
if (-not $SourceServer)   { $missing += '-SourceServer' }
if (-not $SourceDatabase) { $missing += '-SourceDatabase' }
if (-not $TargetServer)   { $missing += '-TargetServer' }
if ($missing.Count) {
    throw ('{0} {1} needed. See Get-Help .\Copy-AzureSqlDatabase.ps1 for what this takes.' -f
           ($missing -join ', '), $(if ($missing.Count -eq 1) { 'is' } else { 'are' }))
}

$stamp    = Get-NameStamp
$source   = Resolve-ServerName $SourceServer
$copyName = "$TargetDatabase-copy-$stamp"
$prevName = "$TargetDatabase-prev-$stamp"

$qCopy   = ConvertTo-QuotedName $copyName
$qTarget = ConvertTo-QuotedName $TargetDatabase
$qPrev   = ConvertTo-QuotedName $prevName

$createSql = New-CopyStatement -SourceServerShort $source.Short -SourceDatabase $SourceDatabase `
                               -CopyName $copyName -ServiceObjective $ServiceObjective -ElasticPool $ElasticPool

# What was given says what was meant. A token is a token; a credential is a SQL login; a user name
# with no secret is a person about to be prompted, which is interactive sign-in; and nothing at all
# is whatever the machine is already signed in as - the same default this had when it went through
# Az, minus the module.
# $script:AuthMethod, and not $Authentication itself: a [ValidateSet] attribute belongs to the
# *variable*, not to the parameter, so assigning the resolved method back into $Authentication is
# validated too - and the empty string it holds when nobody passed it is not in the set. Doing the
# obvious thing fails every run that did not say -Authentication explicitly, with "The variable
# cannot be validated because the value is not a valid value", which names neither the parameter
# nor the fact that it was *this* script's own assignment that did it.
$script:AuthMethod = $Authentication
if (-not $script:AuthMethod) {
    $script:AuthMethod = $(
        if ($AccessToken)       { 'Token' }
        elseif ($SqlCredential) { 'Sql' }
        elseif ($UserName)      { 'EntraMfa' }
        else                    { 'EntraDefault' }
    )
}

if ($AccessToken -and $script:AuthKeyword[$script:AuthMethod]) {
    throw ("-AccessToken cannot be combined with -Authentication $script:AuthMethod. The driver " +
           "refuses to have both: a token goes on the connection and a keyword goes in the string. " +
           "Drop -Authentication, or drop -AccessToken.")
}
if ($script:AuthMethod -eq 'Token' -and -not $AccessToken) {
    throw '-Authentication Token needs -AccessToken. az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv produces one.'
}

# settled before anything is created, so a driver that cannot do what was asked is a refusal rather
# than a half-finished run. A whole connection string carries its own authentication, so the driver
# only has to exist.
$script:Driver = $(if ($ConnectionString) {
    $(if (Test-AuthKeyword -Namespace 'System.Data.SqlClient' -Keyword $null) { 'System.Data.SqlClient' }
      else { Resolve-SqlDriver -Authentication 'Windows' })
} else {
    Resolve-SqlDriver -Authentication $script:AuthMethod
})

$targets = $TargetServer |
    ForEach-Object { Resolve-ServerName $_ } |
    Sort-Object Fqdn -Unique |
    ForEach-Object {
        $clash = Get-SourceClash -TargetFqdn $_.Fqdn -TargetDatabase $TargetDatabase `
                                 -SourceFqdn $source.Fqdn -SourceDatabase $SourceDatabase
        if ($clash) { throw $clash }
        [pscustomobject]@{
            Server       = $_.Short
            Fqdn         = $_.Fqdn
            TargetExists = $false
            Status       = 'Pending'
            Message      = ''
            Started      = $null
            Finished     = $null
        }
    }

Write-Log ("Mode: {0}" -f $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN' })) $(if ($Execute) { 'WARN' } else { 'INFO' })
Write-Log "Source: $($source.Fqdn) / $SourceDatabase"
Write-Log "Targets: $(($targets.Fqdn) -join ', ')  ->  $TargetDatabase"
Write-Log ("Signing in with {0}{1} through {2}" -f
           $(if ($ConnectionString) { 'the connection string given' } else { "-Authentication $script:AuthMethod" }),
           $(if ($UserName) { " as $UserName" } else { '' }), $script:Driver)
if ($script:AuthMethod -eq 'EntraMfa') {
    Write-Log 'A browser will open once; the connections after that reuse the token the driver keeps.'
}

#endregion

#region Preflight

Write-Log 'Preflight checks'

# The source is checked before the targets and a failure here stops everything, which makes it the
# first place a wrong way of signing in shows up - so it is also the first place that needs to say
# what else would have worked. Without this the run ends on the driver's own exception, which names
# no alternative and does not even mention that authentication was the problem.
try {
    if (-not (Test-DatabaseExists -Server $source.Fqdn -Name $SourceDatabase)) {
        throw "Source database $SourceDatabase not found on $($source.Fqdn)."
    }
}
catch {
    $why = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
    Write-Log ("Could not read the source on {0}: {1}" -f $source.Fqdn, $why) ERROR
    if ($why -match $script:SignInPattern) {
        foreach ($line in (Get-AuthAdvice -Tried $script:AuthMethod -Available (Get-AvailableAuth))) {
            Write-Log $line WARN
        }
    }
    throw $why
}

foreach ($t in $targets) {
    try {
        if (Test-DatabaseExists -Server $t.Fqdn -Name $copyName) {
            throw "Copy name $copyName already exists."
        }
        $t.TargetExists = Test-DatabaseExists -Server $t.Fqdn -Name $TargetDatabase
        Write-Log ('{0}: reachable; {1} {2}' -f $t.Fqdn, $TargetDatabase,
            $(if ($t.TargetExists) { 'exists and will be replaced' } else { 'does not exist and will be created' }))
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Preflight: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

# If nothing got through and it looks like signing in was the problem, say what else this machine
# could sign in with. The driver's own failure names none of the alternatives, which is the whole
# reason a wrong default costs an afternoon rather than a minute.
if (-not @($targets | Where-Object Status -eq 'Pending').Count) {
    $signIn = @($targets | Where-Object { $_.Message -match $script:SignInPattern })
    if ($signIn.Count) {
        foreach ($line in (Get-AuthAdvice -Tried $script:AuthMethod -Available (Get-AvailableAuth))) {
            Write-Log $line WARN
        }
    }
}

#endregion

#region Dry run

if (-not $Execute) {
    foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
        Write-Log "Planned SQL on $($t.Fqdn) (master):"
        $plan = @($createSql, '-- poll sys.databases / sys.dm_database_copies until ONLINE') +
                @(Get-SwapPlan -TargetDatabase $TargetDatabase -CopyName $copyName -PreviousName $prevName `
                               -TargetExists $t.TargetExists -KeepPrevious ([bool]$KeepPrevious))
        $plan | ForEach-Object { Write-Host "    $_" }
    }
    Write-Log 'Dry run complete. Re-run with -Execute to apply.' WARN
    return
}

#endregion

#region Start copies

foreach ($t in ($targets | Where-Object Status -eq 'Pending')) {
    try {
        Write-Log "$($t.Fqdn): starting copy as $copyName"
        Invoke-MasterQuery -Server $t.Fqdn -Query $createSql -Timeout 600 | Out-Null
        $t.Status  = 'Copying'
        $t.Started = Get-Date
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Start copy: $($_.Exception.Message)"
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Wait for copies

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$pollSql  = @"
SELECT d.state_desc, c.percent_complete, c.error_desc
FROM sys.databases AS d
LEFT JOIN sys.dm_database_copies AS c ON c.database_id = d.database_id
WHERE d.name = $(ConvertTo-SqlLiteral $copyName);
"@
$opSql = @"
SELECT TOP (1) operation, state_desc, error_desc
FROM sys.dm_operation_status
WHERE major_resource_id = $(ConvertTo-SqlLiteral $copyName)
ORDER BY start_time DESC;
"@

while ($targets | Where-Object Status -eq 'Copying') {

    foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
        try {
            $r = Invoke-MasterQuery -Server $t.Fqdn -Query $pollSql

            if (-not $r) {
                # Failed copies are dropped by Azure; look for the reason.
                $op     = Invoke-MasterQuery -Server $t.Fqdn -Query $opSql
                $detail = if ($op) { "$($op.operation) $($op.state_desc): $([string]$op.error_desc)" } else { 'no operation status recorded' }
                $t.Status  = 'Failed'
                $t.Message = "Copy database disappeared. $detail"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            elseif ($r.state_desc -eq 'ONLINE') {
                $t.Status   = 'Copied'
                $t.Finished = Get-Date
                Write-Log ('{0}: copy ONLINE after {1:hh\:mm\:ss}' -f $t.Fqdn, ($t.Finished - $t.Started)) OK
            }
            elseif ([string]$r.error_desc) {
                $t.Status  = 'Failed'
                $t.Message = "Copy error: $([string]$r.error_desc)"
                Write-Log "$($t.Fqdn): $($t.Message)" ERROR
            }
            else {
                $pct = if ($r.percent_complete -is [DBNull]) { 'n/a' } else { '{0:N1}%' -f $r.percent_complete }
                Write-Log "$($t.Fqdn): $($r.state_desc)  $pct"
            }
        }
        catch {
            Write-Log "$($t.Fqdn): poll error, will retry: $($_.Exception.Message)" WARN
        }
    }

    if ((Get-Date) -gt $deadline) {
        foreach ($t in ($targets | Where-Object Status -eq 'Copying')) {
            $t.Status  = 'Failed'
            $t.Message = "Timed out after $TimeoutMinutes minutes. Copy $copyName may still be running server-side."
            Write-Log "$($t.Fqdn): $($t.Message)" ERROR
        }
        break
    }

    if ($targets | Where-Object Status -eq 'Copying') { Start-Sleep -Seconds $PollSeconds }
}

#endregion

#region Swap

foreach ($t in ($targets | Where-Object Status -eq 'Copied')) {
    $renamedOld = $false
    try {
        if ($t.TargetExists) {
            Write-Log "$($t.Fqdn): renaming $TargetDatabase to $prevName"
            Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qTarget MODIFY NAME = $qPrev;" -Timeout 300 | Out-Null
            $renamedOld = $true
        }

        Write-Log "$($t.Fqdn): renaming $copyName to $TargetDatabase"
        Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qCopy MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null

        if ($renamedOld -and -not $KeepPrevious) {
            try {
                Write-Log "$($t.Fqdn): dropping $prevName"
                Invoke-MasterQuery -Server $t.Fqdn -Query "DROP DATABASE $qPrev;" -Timeout 600 | Out-Null
                $t.Message = 'Replaced; previous database dropped.'
            }
            catch {
                $t.Message = "Replaced, but drop of $prevName failed: $($_.Exception.Message)"
                Write-Log "$($t.Fqdn): $($t.Message)" WARN
            }
        }
        elseif ($renamedOld) {
            $t.Message = "Replaced; previous database kept as $prevName."
        }
        else {
            $t.Message = 'Created.'
        }

        $t.Status = 'Done'
        Write-Log "$($t.Fqdn): $($t.Message)" OK
    }
    catch {
        $t.Status  = 'Failed'
        $t.Message = "Swap: $($_.Exception.Message)"
        if ($renamedOld) {
            try {
                Invoke-MasterQuery -Server $t.Fqdn -Query "ALTER DATABASE $qPrev MODIFY NAME = $qTarget;" -Timeout 300 | Out-Null
                $t.Message += " Original rename rolled back; $copyName left in place."
            }
            catch {
                $t.Message += " ROLLBACK FAILED: original database is currently named $prevName."
            }
        }
        Write-Log "$($t.Fqdn): $($t.Message)" ERROR
    }
}

#endregion

#region Summary

Write-Log 'Run summary'
$targets |
    Select-Object Fqdn, Status,
        @{ n = 'CopyTime'; e = { if ($_.Started -and $_.Finished) { '{0:hh\:mm\:ss}' -f ($_.Finished - $_.Started) } } },
        Message |
    Format-Table -AutoSize -Wrap

if ($targets | Where-Object Status -ne 'Done') { exit 1 }

#endregion
