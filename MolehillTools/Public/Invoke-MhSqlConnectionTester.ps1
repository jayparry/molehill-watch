$script:TesterDefaultQuery = 'SELECT TestText FROM dbo.TestConnection'

$script:TesterAuthMethods = @(
    [pscustomobject]@{ Id = 0; Name = 'WindowsIntegrated';    Label = 'Windows authentication';       Hint = 'The signed-in Windows account';                         NeedsUser = $false; NeedsPassword = $false; Keyword = $null }
    [pscustomobject]@{ Id = 1; Name = 'SqlLogin';             Label = 'SQL Server authentication';    Hint = 'SQL login and password';                                NeedsUser = $true;  NeedsPassword = $true;  Keyword = $null }
    [pscustomobject]@{ Id = 2; Name = 'EntraPassword';        Label = 'Entra ID - password';          Hint = 'Entra user name and password (no MFA)';                 NeedsUser = $true;  NeedsPassword = $true;  Keyword = 'Active Directory Password' }
    [pscustomobject]@{ Id = 3; Name = 'EntraIntegrated';      Label = 'Entra ID - integrated';        Hint = 'Domain-joined single sign-on';                          NeedsUser = $false; NeedsPassword = $false; Keyword = 'Active Directory Integrated' }
    [pscustomobject]@{ Id = 4; Name = 'EntraInteractive';     Label = 'Entra ID - interactive (MFA)'; Hint = 'Opens a browser prompt; user name optional';            NeedsUser = $true;  NeedsPassword = $false; Keyword = 'Active Directory Interactive' }
    [pscustomobject]@{ Id = 5; Name = 'EntraDeviceCode';      Label = 'Entra ID - device code';       Hint = 'Shows a code to enter on another device';                NeedsUser = $false; NeedsPassword = $false; Keyword = 'Active Directory Device Code Flow' }
    [pscustomobject]@{ Id = 6; Name = 'EntraServicePrincipal';Label = 'Entra ID - service principal'; Hint = 'Application (client) id and secret';                     NeedsUser = $true;  NeedsPassword = $true;  Keyword = 'Active Directory Service Principal' }
    [pscustomobject]@{ Id = 7; Name = 'EntraManagedIdentity'; Label = 'Entra ID - managed identity';  Hint = 'Azure VM identity; user = client id for user-assigned';  NeedsUser = $true;  NeedsPassword = $false; Keyword = 'Active Directory Managed Identity' }
    [pscustomobject]@{ Id = 8; Name = 'EntraDefault';         Label = 'Entra ID - default';           Hint = 'Environment, managed identity, Azure CLI, then browser'; NeedsUser = $true;  NeedsPassword = $false; Keyword = 'Active Directory Default' }
)

<#
.SYNOPSIS
    The SQL Connection Tester: a full-screen console app to build, save and test SQL Server
    connection strings, and the same thing without a screen for scripts.

.DESCRIPTION
    Each connection is opened and one row is read from dbo.TestConnection, giving the connection
    string, the text it read, a status and - the point of the tool - the complete error, inner
    exceptions and all SQL errors included, rather than the one line a connection failure usually
    gives you.

    It reads and writes the same JSON file as the C# app of the same name, so the two are
    interchangeable: build the list in whichever is to hand. Passwords are stored with DPAPI
    against the current user, and only when the connection says to save them.

    Read-only: it creates and changes nothing on the server.

    Authentication: Windows and SQL logins always work. The Entra ID methods need
    Microsoft.Data.SqlClient, which is looked for in the SqlServer module, SSMS and Azure Data
    Studio, or taken from -SqlClientDll. Without it the built-in client is used and the methods it
    cannot do are shown as unavailable rather than failing oddly later.

    With -Test, -Csv or -ConnectionString it needs no console and returns the results, so it can be
    scheduled. Without them it draws the app, which needs a real console window.

    Keys: F2 add, F3 edit, F4 delete, F5 test, F6 test all, F7 full result, F8 export CSV,
          F9 duplicate, Ctrl+S save, Esc/Ctrl+Q quit, Enter edit, arrows/PgUp/PgDn move.

.PARAMETER File
    The JSON file of saved connections. Defaults to the same path the C# app uses:
    %APPDATA%\SqlConnectionTester\connections.json

.PARAMETER Test
    Test every saved connection and return the results, with no screen.

.PARAMETER Csv
    Write the results to this CSV as well. Implies -Test.

.PARAMETER ConnectionString
    Test these connection strings rather than, or as well as, the saved ones. Implies -Test, so
    this is the form to use from a script or another tool.

.PARAMETER SqlClientDll
    Path to a Microsoft.Data.SqlClient.dll to use, for a machine where it is somewhere unusual.

.PARAMETER Remaining
    Connection strings given without -ConnectionString, which is what happens when a wrapper is
    started with powershell.exe -File and a comma separated list.

.OUTPUTS
    One result object per connection tested: Name, ConnectionString (password masked), TestText,
    Status, ErrorMessage, TestedAt and ElapsedMs. Nothing, when the app was drawn.

.EXAMPLE
    Invoke-MhSqlConnectionTester

    The app.

.EXAMPLE
    Invoke-MhSqlConnectionTester -Test

    Tests every saved connection and returns the results.

.EXAMPLE
    Invoke-MhSqlConnectionTester -ConnectionString 'Server=SQL01;Database=AppDb;Integrated Security=SSPI'

.EXAMPLE
    Invoke-MhSqlConnectionTester -ConnectionString (Get-MhSqlConnectionString)

    Builds the string on the connect screen, then tests it and shows the whole error if it fails.

.NOTES
    Molehill Data Services. Read-only throughout.
#>

function Invoke-MhSqlConnectionTester {
    [CmdletBinding()]
    param(
        [string] $File,
        [switch] $Test,
        [string] $Csv,
        [Parameter(Position = 0)] [string[]] $ConnectionString,
        [string] $SqlClientDll,
        [string[]] $Remaining
    )

    $ErrorActionPreference = 'Stop'

    # the DLL to prefer is a parameter here but is read by a function at module scope
    $script:TesterSqlClientDll = $SqlClientDll
    Initialize-TesterSqlClient
    $script:TesterDefaultFile = Join-Path $env:APPDATA 'SqlConnectionTester\connections.json'
    if (-not $File) { $File = $script:TesterDefaultFile }
    foreach ($extra in $Remaining) {
        if ($extra -match '=') { $ConnectionString += $extra }
        else {
            Write-Error "Unexpected argument '$extra'. Connection strings must contain '='." `
                -Category InvalidArgument -ErrorId 'MhBadArgument' -ErrorAction Stop
        }
    }
    $profiles = Import-TesterProfiles $File
    foreach ($cs in $ConnectionString) {
        $p = New-TesterProfile
        $p.Name = if ($cs.Length -gt 40) { $cs.Substring(0, 40) + '...' } else { $cs }
        $p.UseRawConnectionString = $true
        $p.RawConnectionString = $cs
        [void]$profiles.Add($p)
    }
    $headless = $Test -or $Csv -or $ConnectionString
    if (-not $headless) {
        if (-not (Test-TesterInteractive)) {
            Write-Error 'This needs a real console window. For a script use -Test, -Csv or -ConnectionString, which do not.' `
                -ErrorId 'MhNoConsole' -ErrorAction Stop
        }
        try {
            Show-TesterMainScreen $File $profiles
        }
        finally {
            try { [Console]::CursorVisible = $true; [Console]::ResetColor(); [Console]::Clear() } catch { }
        }
        return
    }
    if ($profiles.Count -eq 0) {
        Write-Error "No connections to test. Add some in the app, or pass -ConnectionString '...'." `
            -Category InvalidArgument -ErrorId 'MhBadArgument' -ErrorAction Stop
    }
    $results = foreach ($p in $profiles) {
        $r = Test-TesterProfile $p
        Write-Host "ConnectionString : $($r.ConnectionString)"
        Write-Host "TestText         : $($r.TestText)"
        Write-Host "Status           : $($r.Status)" -ForegroundColor $(if ($r.Status -eq 'Success') { 'Green' } else { 'Red' })
        if ($r.ErrorMessage) { Write-Host "ErrorMessage     : $($r.ErrorMessage)" -ForegroundColor $(if ($r.Status -eq 'Success') { 'Yellow' } else { 'Red' }) }
        Write-Host ''
        $r
    }
    if ($Csv) {
        $results | Select-Object Name, ConnectionString, TestText, Status, ErrorMessage, TestedAt, ElapsedMs |
            Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
        Write-Host "Results saved to $Csv"
    }
    $failed = @($results | Where-Object Status -ne 'Success').Count
    Write-Host "$(@($results).Count - $failed) of $(@($results).Count) connection(s) succeeded."
    $results
}

function Find-TesterSqlClientDll {
    $candidates = New-Object System.Collections.Generic.List[string]

    $module = Get-Module -ListAvailable SqlServer -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) {
        # the DLL beside the module is the .NET Framework build; PowerShell 7 needs the one under
        # coreclr, and asking for the wrong one is a BadImageFormatException rather than a miss
        if ($PSVersionTable.PSEdition -eq 'Core') {
            foreach ($found in (Resolve-Path (Join-Path $module.ModuleBase 'coreclr\runtimes\win\lib\net*\Microsoft.Data.SqlClient.dll') -ErrorAction SilentlyContinue)) {
                $candidates.Add($found.Path)
            }
        }
        else {
            $candidates.Add((Join-Path $module.ModuleBase 'Microsoft.Data.SqlClient.dll'))
        }
    }

    foreach ($root in @(
            "$env:ProgramFiles\Microsoft SQL Server Management Studio*\Release\Common7\IDE",
            "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*\Common7\IDE",
            "$env:ProgramFiles\Azure Data Studio",
            "$env:LOCALAPPDATA\Programs\Azure Data Studio")) {
        foreach ($dir in (Resolve-Path $root -ErrorAction SilentlyContinue)) {
            $dll = Join-Path $dir.Path 'Microsoft.Data.SqlClient.dll'
            if (Test-Path $dll) { $candidates.Add($dll) }
        }
    }
    return $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Use-TesterModernClient([type] $Type, [string] $From) {
    # prove it can actually build a connection (native SNI present and loadable)
    try { ($Type::new('Server=(probe);Connect Timeout=1')).Dispose() } catch { return $false }

    # and that its authentication providers set up, which happens on the first Open rather than
    # here: a copy loaded from a folder without its Microsoft.Identity.Client beside it builds a
    # connection object quite happily and then fails EVERY connection, Windows authentication
    # included. Finding that out now is the difference between picking another copy and telling
    # someone their server is unreachable.
    $provider = $Type.Assembly.GetType('Microsoft.Data.SqlClient.SqlAuthenticationProvider')
    $method = $Type.Assembly.GetType('Microsoft.Data.SqlClient.SqlAuthenticationMethod')
    if ($provider -and $method) {
        try { $null = $provider::GetProvider([Enum]::Parse($method, 'ActiveDirectoryPassword')) }
        catch { return $false }
    }

    $script:TesterConnectionType = $Type
    $script:TesterDriverName = "Microsoft.Data.SqlClient ($From)"
    $script:TesterDriverIsModern = $true
    return $true
}

function Import-TesterClientDll([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    try { Add-Type -Path $Path -ErrorAction Stop } catch { return $false }
    $type = [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient', $false)
    if (-not $type) { return $false }
    return (Use-TesterModernClient $type ([System.IO.Path]::GetFileName((Split-Path $Path -Parent))))
}

function Initialize-TesterSqlClient {
    # the app, a headless run and the registered checks all ask for this, and Add-Type on the same
    # assembly twice is at best wasted work
    if ($script:TesterConnectionType -and $script:TesterClientLoadedFrom -eq $script:TesterSqlClientDll) { return }
    $script:TesterClientLoadedFrom = $script:TesterSqlClientDll

    # Microsoft.Data.SqlClient first, because it is the only one that can do every Entra method.
    # A DLL named on the command line wins outright.
    if ($script:TesterSqlClientDll) {
        if (Import-TesterClientDll $script:TesterSqlClientDll) { return }
        Write-Warning "Could not load Microsoft.Data.SqlClient from $($script:TesterSqlClientDll); looking elsewhere."
    }

    # then one already in the session, which costs nothing to try
    $loaded = 'Microsoft.Data.SqlClient.SqlConnection' -as [type]
    if ($loaded -and (Use-TesterModernClient $loaded 'already loaded')) { return }

    # then the SqlServer module. This is the slow one - a few seconds - but it has to come before
    # loading a DLL by path, not after: the module resolves its own dependencies, and a path load
    # does not. Worse, a failed path load is not free to walk away from, because the half-working
    # copy it leaves in the session is what the type name resolves to from then on, module import
    # included. Ask the one that works first.
    if (Get-Module -ListAvailable SqlServer -ErrorAction SilentlyContinue) {
        if ((Get-MhSqlClientNamespace -Microsoft) -eq 'Microsoft.Data.SqlClient') {
            $type = 'Microsoft.Data.SqlClient.SqlConnection' -as [type]
            if ($type -and (Use-TesterModernClient $type 'SqlServer module')) { return }
        }
    }

    # and then the copies SSMS and Azure Data Studio leave on disk, for a machine with no module
    foreach ($dll in Find-TesterSqlClientDll) { if (Import-TesterClientDll $dll) { return } }

    Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue
    $script:TesterConnectionType = [System.Data.SqlClient.SqlConnection]
    $script:TesterDriverName = 'System.Data.SqlClient (built in)'
    $script:TesterDriverIsModern = $false
}

function Test-TesterAuthSupported([int] $AuthId) {
    if ($AuthId -le 1) { return $true }                       # Windows / SQL login: always
    if ($script:TesterDriverIsModern) { return $true }              # Microsoft.Data.SqlClient: all of them
    # built-in client: .NET Framework manages password/integrated/interactive, .NET Core only the first two
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $AuthId -in @(2, 3, 4) }
    return $AuthId -in @(2, 3)
}

function Get-TesterAuthMethod([int] $Id) { $script:TesterAuthMethods | Where-Object Id -eq $Id }

function New-TesterProfile {
    [pscustomobject]@{
        Name                   = 'New connection'
        UseRawConnectionString = $false
        RawConnectionString    = ''
        Server                 = ''
        Database               = ''
        Authentication         = 0
        UserId                 = ''
        ProtectedPassword      = $null
        SavePassword           = $false
        Password               = ''
        Encrypt                = 'Mandatory'
        TrustServerCertificate = $false
        HostNameInCertificate  = ''
        ApplicationName        = 'SQL Connection Tester'
        ReadOnlyIntent         = $false
        MultiSubnetFailover    = $false
        FailoverPartner        = ''
        ConnectTimeoutSeconds  = 15
        CommandTimeoutSeconds  = 30
        Query                  = $script:TesterDefaultQuery
    }
}

function Add-TesterPart([System.Text.StringBuilder] $Sb, [string] $Key, $Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return }
    $text = "$Value"
    if ($text -match '[;"'']') { $text = '"' + $text.Replace('"', '""') + '"' }
    if ($Sb.Length -gt 0) { [void]$Sb.Append(';') }
    [void]$Sb.Append("$Key=$text")
}

function Build-TesterConnectionString($Profile) {
    if ($Profile.UseRawConnectionString) { return $Profile.RawConnectionString }

    $sb = New-Object System.Text.StringBuilder
    Add-TesterPart $sb 'Data Source' $Profile.Server
    Add-TesterPart $sb 'Initial Catalog' $Profile.Database

    $auth = Get-TesterAuthMethod $Profile.Authentication
    switch ($Profile.Authentication) {
        0 { Add-TesterPart $sb 'Integrated Security' 'True' }
        1 {
            Add-TesterPart $sb 'User ID' $Profile.UserId
            Add-TesterPart $sb 'Password' $Profile.Password
        }
        default {
            Add-TesterPart $sb 'Authentication' $auth.Keyword
            if ($auth.NeedsUser) { Add-TesterPart $sb 'User ID' $Profile.UserId }
            if ($auth.NeedsPassword) { Add-TesterPart $sb 'Password' $Profile.Password }
        }
    }

    if ($script:TesterDriverIsModern) {
        Add-TesterPart $sb 'Encrypt' $Profile.Encrypt                     # Mandatory / Optional / Strict
    }
    else {
        Add-TesterPart $sb 'Encrypt' $(if ($Profile.Encrypt -eq 'Optional') { 'False' } else { 'True' })
    }
    if ($Profile.TrustServerCertificate) { Add-TesterPart $sb 'Trust Server Certificate' 'True' }
    if ($Profile.HostNameInCertificate -and $script:TesterDriverIsModern) { Add-TesterPart $sb 'Host Name In Certificate' $Profile.HostNameInCertificate }
    if ($Profile.ReadOnlyIntent) { Add-TesterPart $sb 'ApplicationIntent' 'ReadOnly' }
    if ($Profile.MultiSubnetFailover) { Add-TesterPart $sb 'MultiSubnetFailover' 'True' }
    Add-TesterPart $sb 'Failover Partner' $Profile.FailoverPartner
    Add-TesterPart $sb 'Connect Timeout' $Profile.ConnectTimeoutSeconds
    Add-TesterPart $sb 'Application Name' $Profile.ApplicationName
    Add-TesterPart $sb 'Pooling' 'False'                                   # never reuse a pooled connection for a test
    return $sb.ToString()
}

function Hide-TesterPassword([string] $Text) {
    if (-not $Text) { return $Text }
    return ($Text -replace '(?i)\b(password|pwd)\s*=\s*[^;]*', '$1=***')
}

function Get-TesterProfileDescription($Profile) {
    if ($Profile.UseRawConnectionString) { return 'Raw connection string' }
    $bits = @((Get-TesterAuthMethod $Profile.Authentication).Label)
    if ($Profile.Database) { $bits += "database $($Profile.Database)" }
    $bits += "encrypt $($Profile.Encrypt)$(if ($Profile.TrustServerCertificate) { ' (trust cert)' })"
    if ($Profile.ReadOnlyIntent) { $bits += 'read-only intent' }
    if ($Profile.MultiSubnetFailover) { $bits += 'multi-subnet failover' }
    return ($bits -join ', ')
}

function Get-TesterFullErrorText($Exception) {
    $lines = New-Object System.Collections.Generic.List[string]
    $e = $Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
    $level = 0
    while ($e) {
        $prefix = if ($level -eq 0) { '' } else { "Inner exception ($level): " }
        $lines.Add("$prefix[$($e.GetType().FullName)] $($e.Message)")
        if ($e.GetType().Name -eq 'SqlException') {
            try { if ($e.ClientConnectionId -and $e.ClientConnectionId -ne [guid]::Empty) { $lines.Add("Client connection id: $($e.ClientConnectionId)") } } catch { }
            $n = 0
            foreach ($err in $e.Errors) {
                $n++
                $detail = "SQL error $n of $($e.Errors.Count): Msg $($err.Number), Level $($err.Class), State $($err.State)"
                if ($err.Procedure) { $detail += ", Procedure $($err.Procedure)" }
                if ($err.LineNumber) { $detail += ", Line $($err.LineNumber)" }
                if ($err.Server) { $detail += ", Server $($err.Server)" }
                $lines.Add($detail)
                $lines.Add($err.Message)
            }
        }
        $e = $e.InnerException
        $level++
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-TesterProfile($Profile) {
    $connectionString = Build-TesterConnectionString $Profile
    $result = [pscustomobject]@{
        Name             = $Profile.Name
        ConnectionString = Hide-TesterPassword $connectionString
        TestText         = $null
        Status           = 'Failure'
        ErrorMessage     = $null
        TestedAt         = Get-Date
        ElapsedMs        = 0
    }

    if (-not $Profile.UseRawConnectionString -and -not (Test-TesterAuthSupported $Profile.Authentication)) {
        $result.ErrorMessage = "$((Get-TesterAuthMethod $Profile.Authentication).Label) needs Microsoft.Data.SqlClient, which was not found on this machine. " +
                               "Install the SqlServer PowerShell module or SSMS, or pass -SqlClientDll, or use the C# app."
        return $result
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = $null
    try {
        $connection = $script:TesterConnectionType::new($connectionString)
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = if ($Profile.Query) { $Profile.Query } else { $script:TesterDefaultQuery }
        $command.CommandTimeout = $Profile.CommandTimeoutSeconds
        $reader = $command.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)

        if ($table.Rows.Count -eq 0) {
            $result.ErrorMessage = 'Connected and read the test table, but it contains no rows.'
        }
        else {
            $value = $table.Rows[0][0]
            $result.TestText = if ($value -is [DBNull]) { $null } else { [string]$value }
            $result.Status = 'Success'
            if ($table.Rows.Count -gt 1) { $result.ErrorMessage = "Note: the test table returned $($table.Rows.Count) rows; the first was used." }
        }
    }
    catch {
        $result.ErrorMessage = Get-TesterFullErrorText $_.Exception
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
    $result.ElapsedMs = $watch.ElapsedMilliseconds
    return $result
}

function Protect-TesterSecret([string] $Value) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser'))
}

function Unprotect-TesterSecret([string] $Value) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value), $null, 'CurrentUser')
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Import-TesterProfiles([string] $Path) {
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path $Path)) { return ,$list }
    $json = Get-Content -Raw -Path $Path
    if (-not $json.Trim()) { return ,$list }
    # Windows PowerShell 5.1 hands back the whole JSON array as one object, PowerShell 7 emits each element
    $parsed = $json | ConvertFrom-Json
    $items = if ($parsed -is [System.Array]) { $parsed } else { @($parsed) }
    foreach ($item in $items) {
        $p = New-TesterProfile
        foreach ($property in $item.PSObject.Properties) {
            if ($p.PSObject.Properties[$property.Name]) { $p.($property.Name) = $property.Value }
        }
        if ($p.ProtectedPassword) {
            try { $p.Password = Unprotect-TesterSecret $p.ProtectedPassword } catch { $p.Password = '' }
        }
        [void]$list.Add($p)
    }
    return ,$list          # the comma keeps it a list: PowerShell would otherwise unroll a single item
}

function Export-TesterProfiles([string] $Path, $Profiles) {
    $out = foreach ($p in $Profiles) {
        $copy = $p | Select-Object * -ExcludeProperty Password
        $copy.ProtectedPassword = if ($p.SavePassword -and $p.Password) { Protect-TesterSecret $p.Password } else { $null }
        $copy
    }
    $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    # an array stays an array in the file, so the C# app reads it too
    ConvertTo-Json @($out) -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Test-TesterInteractive {
    try { $null = [Console]::WindowWidth; return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Get-TesterSize {
    $width = [Math]::Max(80, [Console]::WindowWidth)
    $height = [Math]::Max(24, [Console]::WindowHeight)
    return @{ Width = $width - 1; Height = $height }
}

function Write-TesterAt([int] $X, [int] $Y, [string] $Text, $Fore = 'Gray', $Back = 'Black') {
    if ($Y -lt 0 -or $Y -ge [Console]::WindowHeight) { return }
    $max = [Console]::WindowWidth - $X - 1
    if ($max -le 0) { return }
    if ($Text.Length -gt $max) { $Text = $Text.Substring(0, $max) }
    [Console]::SetCursorPosition($X, $Y)
    Write-Host $Text -NoNewline -ForegroundColor $Fore -BackgroundColor $Back
}

function Write-TesterBar([int] $Y, [string] $Text, $Fore = 'Black', $Back = 'Gray') {
    $size = Get-TesterSize
    $padded = $Text.PadRight($size.Width)
    if ($padded.Length -gt $size.Width) { $padded = $padded.Substring(0, $size.Width) }
    Write-TesterAt 0 $Y $padded $Fore $Back
}

function Draw-TesterBox([int] $X, [int] $Y, [int] $Width, [int] $Height, [string] $Title, $Fore = 'DarkGray') {
    $top = '+' + ('-' * [Math]::Max(0, $Width - 2)) + '+'
    if ($Title) {
        $label = " $Title "
        if ($label.Length -lt $Width - 2) { $top = '+' + $label + ('-' * ($Width - 2 - $label.Length)) + '+' }
    }
    Write-TesterAt $X $Y $top $Fore
    for ($i = 1; $i -lt $Height - 1; $i++) {
        Write-TesterAt $X ($Y + $i) '|' $Fore
        Write-TesterAt ($X + $Width - 1) ($Y + $i) '|' $Fore
    }
    Write-TesterAt $X ($Y + $Height - 1) ('+' + ('-' * [Math]::Max(0, $Width - 2)) + '+') $Fore
}

function Clear-TesterArea([int] $X, [int] $Y, [int] $Width, [int] $Height) {
    $blank = ' ' * $Width
    for ($i = 0; $i -lt $Height; $i++) { Write-TesterAt $X ($Y + $i) $blank }
}

function Split-TesterText([string] $Text, [int] $Width) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw.Length -le $Width) { $lines.Add($raw); continue }
        $remaining = $raw
        while ($remaining.Length -gt $Width) {
            $break = $remaining.LastIndexOf(' ', [Math]::Min($Width, $remaining.Length - 1))
            if ($break -lt 20) { $break = $Width }
            $lines.Add($remaining.Substring(0, $break))
            $remaining = $remaining.Substring($break).TrimStart()
        }
        if ($remaining) { $lines.Add($remaining) }
    }
    return $lines
}

function Show-TesterMessage([string] $Title, [string] $Text, $TitleColour = 'White') {
    $size = Get-TesterSize
    $width = $size.Width - 6
    $height = $size.Height - 6
    $x = 3
    $y = 2
    $lines = Split-TesterText $Text ($width - 4)
    $offset = 0
    $pageSize = $height - 4

    while ($true) {
        Clear-TesterArea $x $y $width $height
        Draw-TesterBox $x $y $width $height $Title $TitleColour
        for ($i = 0; $i -lt $pageSize; $i++) {
            $index = $offset + $i
            if ($index -ge $lines.Count) { break }
            Write-TesterAt ($x + 2) ($y + 1 + $i) $lines[$index] 'Gray'
        }
        $more = if ($lines.Count -gt $pageSize) { "  line $($offset + 1)-$([Math]::Min($offset + $pageSize, $lines.Count)) of $($lines.Count)   PgUp/PgDn to scroll" } else { '' }
        Write-TesterAt ($x + 2) ($y + $height - 2) "Esc or Enter to close$more" 'DarkGray'

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Escape' { return }
            'Enter' { return }
            'Q' { return }
            'DownArrow' { if ($offset + $pageSize -lt $lines.Count) { $offset++ } }
            'UpArrow' { if ($offset -gt 0) { $offset-- } }
            'PageDown' { if ($offset + $pageSize -lt $lines.Count) { $offset = [Math]::Min($offset + $pageSize, $lines.Count - $pageSize) } }
            'PageUp' { $offset = [Math]::Max(0, $offset - $pageSize) }
            'Home' { $offset = 0 }
            'End' { $offset = [Math]::Max(0, $lines.Count - $pageSize) }
        }
    }
}

function Confirm-TesterAction([string] $Title, [string] $Question) {
    $size = Get-TesterSize
    $width = [Math]::Min($size.Width - 10, [Math]::Max(40, $Question.Length + 8))
    $x = [int](($size.Width - $width) / 2)
    $y = [int]($size.Height / 2) - 3
    Clear-TesterArea $x $y $width 6
    Draw-TesterBox $x $y $width 6 $Title 'Yellow'
    Write-TesterAt ($x + 2) ($y + 2) $Question 'White'
    Write-TesterAt ($x + 2) ($y + 4) 'Y = yes,  N or Esc = no' 'DarkGray'
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Y') { return $true }
        if ($key.Key -eq 'N' -or $key.Key -eq 'Escape') { return $false }
    }
}

function Read-TesterFieldValue([int] $X, [int] $Y, [int] $Width, [string] $Value, [bool] $Secret) {
    $text = "$Value"
    while ($true) {
        $shown = if ($Secret) { '*' * $text.Length } else { $text }
        if ($shown.Length -ge $Width) { $shown = $shown.Substring($shown.Length - $Width + 1) }
        Write-TesterAt $X $Y ($shown.PadRight($Width)) 'White' 'DarkBlue'
        [Console]::SetCursorPosition([Math]::Min($X + $shown.Length, $X + $Width - 1), $Y)
        [Console]::CursorVisible = $true
        $key = [Console]::ReadKey($true)
        [Console]::CursorVisible = $false
        switch ($key.Key) {
            'Enter' { return $text }
            'Escape' { return $Value }
            'Backspace' { if ($text.Length -gt 0) { $text = $text.Substring(0, $text.Length - 1) } }
            default {
                if ($key.KeyChar -and [char]::IsControl($key.KeyChar) -eq $false) { $text += $key.KeyChar }
            }
        }
    }
}

function Show-TesterProfileForm($Profile, [string] $Title) {
    $work = $Profile | Select-Object *
    $encryptChoices = @('Mandatory', 'Optional', 'Strict')

    while ($true) {
        $auth = Get-TesterAuthMethod $work.Authentication
        $raw = [bool]$work.UseRawConnectionString

        $fields = @(
            @{ Label = 'Name';                 Key = 'Name';                   Type = 'text' }
            @{ Label = 'Use raw string';       Key = 'UseRawConnectionString'; Type = 'bool' }
            @{ Label = 'Raw connection string';Key = 'RawConnectionString';    Type = 'text';   Enabled = $raw }
            @{ Label = 'Server';               Key = 'Server';                 Type = 'text';   Enabled = -not $raw }
            @{ Label = 'Database';             Key = 'Database';               Type = 'text';   Enabled = -not $raw }
            @{ Label = 'Authentication';       Key = 'Authentication';         Type = 'auth';   Enabled = -not $raw }
            @{ Label = 'User / client id';     Key = 'UserId';                 Type = 'text';   Enabled = (-not $raw -and $auth.NeedsUser) }
            @{ Label = 'Password / secret';    Key = 'Password';               Type = 'secret'; Enabled = (-not $raw -and $auth.NeedsPassword) }
            @{ Label = 'Save password';        Key = 'SavePassword';           Type = 'bool';   Enabled = (-not $raw -and $auth.NeedsPassword) }
            @{ Label = 'Encrypt';              Key = 'Encrypt';                Type = 'choice'; Choices = $encryptChoices; Enabled = -not $raw }
            @{ Label = 'Trust server cert';    Key = 'TrustServerCertificate'; Type = 'bool';   Enabled = -not $raw }
            @{ Label = 'Read-only intent';     Key = 'ReadOnlyIntent';         Type = 'bool';   Enabled = -not $raw }
            @{ Label = 'MultiSubnetFailover';  Key = 'MultiSubnetFailover';    Type = 'bool';   Enabled = -not $raw }
            @{ Label = 'Failover partner';     Key = 'FailoverPartner';        Type = 'text';   Enabled = -not $raw }
            @{ Label = 'Connect timeout (s)';  Key = 'ConnectTimeoutSeconds';  Type = 'int';    Enabled = -not $raw }
            @{ Label = 'Query timeout (s)';    Key = 'CommandTimeoutSeconds';  Type = 'int' }
            @{ Label = 'Query';                Key = 'Query';                  Type = 'text' }
        )
        if (-not $script:FormIndex) { $script:FormIndex = 0 }
        if ($script:FormIndex -ge $fields.Count) { $script:FormIndex = 0 }

        $size = Get-TesterSize
        [Console]::Clear()
        Write-TesterBar 0 "  $Title " 'Black' 'Cyan'
        Draw-TesterBox 1 1 ($size.Width - 2) ($fields.Count + 7) '' 'DarkGray'

        for ($i = 0; $i -lt $fields.Count; $i++) {
            $f = $fields[$i]
            $enabled = -not $f.ContainsKey('Enabled') -or $f.Enabled
            $value = switch ($f.Type) {
                'bool'   { if ($work.($f.Key)) { '[x]' } else { '[ ]' } }
                'secret' { if ($work.Password) { '*' * ([Math]::Min(20, $work.Password.Length)) } else { '' } }
                'auth'   { (Get-TesterAuthMethod $work.Authentication).Label + $(if (Test-TesterAuthSupported $work.Authentication) { '' } else { '  (not available with this SQL client)' }) }
                default  { "$($work.($f.Key))" }
            }
            $selected = ($i -eq $script:FormIndex)
            $labelColour = if (-not $enabled) { 'DarkGray' } elseif ($selected) { 'Yellow' } else { 'Gray' }
            $valueColour = if (-not $enabled) { 'DarkGray' } elseif ($selected) { 'White' } else { 'Gray' }
            $back = if ($selected) { 'DarkBlue' } else { 'Black' }
            Write-TesterAt 3 (2 + $i) ("$($f.Label):".PadRight(22)) $labelColour
            Write-TesterAt 25 (2 + $i) ($value.PadRight($size.Width - 28)) $valueColour $back
        }

        $y = $fields.Count + 3
        Write-TesterAt 3 $y ("Hint: " + $auth.Hint).PadRight($size.Width - 6) 'DarkCyan'
        $preview = Hide-TesterPassword (Build-TesterConnectionString $work)
        foreach ($line in (Split-TesterText "Preview: $preview" ($size.Width - 8)) | Select-Object -First 3) {
            $y++
            Write-TesterAt 3 $y $line.PadRight($size.Width - 6) 'DarkGreen'
        }

        Write-TesterBar ($size.Height - 1) ' Up/Down move   Enter or type = edit   Space toggles   Left/Right changes   F10 save   Esc cancel ' 'Black' 'Gray'

        $key = [Console]::ReadKey($true)
        $field = $fields[$script:FormIndex]
        $editable = -not $field.ContainsKey('Enabled') -or $field.Enabled

        switch ($key.Key) {
            'UpArrow'   { $script:FormIndex = [Math]::Max(0, $script:FormIndex - 1); continue }
            'DownArrow' { $script:FormIndex = [Math]::Min($fields.Count - 1, $script:FormIndex + 1); continue }
            'Tab'       { $script:FormIndex = ($script:FormIndex + 1) % $fields.Count; continue }
            'Escape'    { return $null }
            'F10'       { break }
            'Spacebar' {
                if ($editable -and $field.Type -eq 'bool') { $work.($field.Key) = -not $work.($field.Key) }
                continue
            }
            { $_ -in 'LeftArrow', 'RightArrow' } {
                if (-not $editable) { continue }
                $step = if ($key.Key -eq 'RightArrow') { 1 } else { -1 }
                switch ($field.Type) {
                    'auth' {
                        $next = ($work.Authentication + $step) % $script:TesterAuthMethods.Count
                        if ($next -lt 0) { $next += $script:TesterAuthMethods.Count }
                        $work.Authentication = $next
                    }
                    'choice' {
                        $index = [Math]::Max(0, [Array]::IndexOf($field.Choices, "$($work.($field.Key))"))
                        $index = ($index + $step) % $field.Choices.Count
                        if ($index -lt 0) { $index += $field.Choices.Count }
                        $work.($field.Key) = $field.Choices[$index]
                    }
                    'bool' { $work.($field.Key) = -not $work.($field.Key) }
                    'int' {
                        $value = [int]$work.($field.Key) + $step
                        if ($value -ge 1) { $work.($field.Key) = $value }
                    }
                }
                continue
            }
            'Enter' {
                if (-not $editable) { continue }
                switch ($field.Type) {
                    'bool'   { $work.($field.Key) = -not $work.($field.Key) }
                    'auth'   { }
                    default {
                        $secret = $field.Type -eq 'secret'
                        $current = if ($secret) { $work.Password } else { "$($work.($field.Key))" }
                        $entered = Read-TesterFieldValue 25 (2 + $script:FormIndex) ($size.Width - 28) $current $secret
                        if ($field.Type -eq 'int') { if ($entered -match '^\d+$' -and [int]$entered -gt 0) { $work.($field.Key) = [int]$entered } }
                        else { $work.($field.Key) = $entered }
                    }
                }
                continue
            }
            default {
                # typing a printable character starts editing a text field with that character
                if ($editable -and $key.KeyChar -and -not [char]::IsControl($key.KeyChar) -and $field.Type -in 'text', 'secret', 'int') {
                    $secret = $field.Type -eq 'secret'
                    $entered = Read-TesterFieldValue 25 (2 + $script:FormIndex) ($size.Width - 28) "$($key.KeyChar)" $secret
                    if ($field.Type -eq 'int') { if ($entered -match '^\d+$' -and [int]$entered -gt 0) { $work.($field.Key) = [int]$entered } }
                    else { $work.($field.Key) = $entered }
                }
                continue
            }
        }

        # F10: validate and return
        if (-not $work.Name) { Show-TesterMessage 'Add' 'Give the connection a name.' 'Red'; continue }
        if (-not $work.UseRawConnectionString -and -not $work.Server) { Show-TesterMessage 'Add' 'Give a server.' 'Red'; continue }
        if ($work.UseRawConnectionString -and -not $work.RawConnectionString) { Show-TesterMessage 'Add' 'Give a raw connection string.' 'Red'; continue }
        if (-not $work.Query) { $work.Query = $script:TesterDefaultQuery }
        return $work
    }
}

function Show-TesterMainScreen([string] $Path, $Profiles) {
    $script:Results = @{}
    $selected = 0
    $dirty = $false
    [Console]::CursorVisible = $false

    while ($true) {
        $size = Get-TesterSize
        $listWidth = [int]($size.Width * 0.42)
        $detailX = $listWidth + 1
        $detailWidth = $size.Width - $detailX
        $bodyHeight = $size.Height - 3

        [Console]::Clear()
        Write-TesterBar 0 "  SQL Connection Tester   -   $($script:TesterDriverName)" 'Black' 'Cyan'
        Draw-TesterBox 0 1 $listWidth $bodyHeight 'Connections'
        Draw-TesterBox $detailX 1 $detailWidth $bodyHeight 'Details'

        if ($Profiles.Count -eq 0) {
            Write-TesterAt 2 3 'No connections yet.' 'DarkGray'
            Write-TesterAt 2 4 'Press F2 to add one.' 'DarkGray'
        }
        for ($i = 0; $i -lt $Profiles.Count -and $i -lt $bodyHeight - 2; $i++) {
            $p = $Profiles[$i]
            $result = $script:Results[$p.Name]
            $state = if (-not $result) { '[    ]' } elseif ($result.Status -eq 'Success') { '[ OK ]' } else { '[FAIL]' }
            $stateColour = if (-not $result) { 'DarkGray' } elseif ($result.Status -eq 'Success') { 'Green' } else { 'Red' }
            $back = if ($i -eq $selected) { 'DarkBlue' } else { 'Black' }
            $text = " $($p.Name)  -  $(if ($p.UseRawConnectionString) { 'raw' } else { $p.Server })"
            Write-TesterAt 1 (2 + $i) $state.PadRight(7) $stateColour $back
            Write-TesterAt 8 (2 + $i) $text.PadRight($listWidth - 9) $(if ($i -eq $selected) { 'White' } else { 'Gray' }) $back
        }

        if ($Profiles.Count -gt 0) {
            $p = $Profiles[$selected]
            $result = $script:Results[$p.Name]
            $detail = "$($p.Name)`n`n$(Get-TesterProfileDescription $p)`n`nConnection string:`n$(Hide-TesterPassword (Build-TesterConnectionString $p))`n`nQuery:`n$($p.Query)`n"
            if ($result) {
                $detail += "`nLast test: $($result.TestedAt.ToString('dd MMM yyyy HH:mm:ss')) ($($result.ElapsedMs) ms)`nStatus: $($result.Status)`n"
                if ($result.TestText) { $detail += "TestText: $($result.TestText)`n" }
                if ($result.ErrorMessage) { $detail += "`n$($result.ErrorMessage)`n" }
            }
            else { $detail += "`nNot tested yet (F5)." }

            $row = 2
            foreach ($line in (Split-TesterText $detail ($detailWidth - 4))) {
                if ($row -ge $bodyHeight) { Write-TesterAt ($detailX + 2) ($row - 1) '... F7 for the full result' 'DarkGray'; break }
                $colour = 'Gray'
                if ($line -like 'Status: Success*') { $colour = 'Green' }
                elseif ($line -like 'Status: Failure*') { $colour = 'Red' }
                elseif ($line -like 'TestText:*') { $colour = 'Cyan' }
                Write-TesterAt ($detailX + 2) $row $line $colour
                $row++
            }
        }

        $ok = @($script:Results.Values | Where-Object Status -eq 'Success').Count
        $fail = @($script:Results.Values | Where-Object Status -ne 'Success').Count
        Write-TesterBar ($size.Height - 2) " $($Profiles.Count) connection(s)   tested: $ok succeeded, $fail failed   file: $Path$(if ($dirty) { ' *' })" 'Black' 'DarkCyan'
        Write-TesterBar ($size.Height - 1) ' F2 add  F3 edit  F4 delete  F5 test  F6 test all  F7 result  F8 export  F9 copy  ^S save  Esc quit ' 'Black' 'Gray'

        $key = [Console]::ReadKey($true)
        $current = if ($Profiles.Count -gt 0) { $Profiles[$selected] } else { $null }

        if ($key.Modifiers -band [ConsoleModifiers]::Control) {
            switch ($key.Key) {
                'S' { Export-TesterProfiles $Path $Profiles; $dirty = $false; Show-TesterMessage 'Saved' "Saved $($Profiles.Count) connection(s) to:`n$Path"; continue }
                'Q' { if ($dirty -and (Confirm-TesterAction 'Quit' 'Save changes before quitting?')) { Export-TesterProfiles $Path $Profiles }; return }
            }
            continue
        }

        switch ($key.Key) {
            'UpArrow'   { if ($selected -gt 0) { $selected-- } }
            'DownArrow' { if ($selected -lt $Profiles.Count - 1) { $selected++ } }
            'Home'      { $selected = 0 }
            'End'       { $selected = [Math]::Max(0, $Profiles.Count - 1) }
            'Escape'    { if ($dirty -and (Confirm-TesterAction 'Quit' 'Save changes before quitting?')) { Export-TesterProfiles $Path $Profiles }; return }
            'F2' {
                $script:FormIndex = 0
                $new = Show-TesterProfileForm (New-TesterProfile) 'Add connection'
                if ($new) { [void]$Profiles.Add($new); $selected = $Profiles.Count - 1; $dirty = $true }
            }
            'F3' {
                if ($current) {
                    $script:FormIndex = 0
                    $edited = Show-TesterProfileForm $current 'Edit connection'
                    if ($edited) { $Profiles[$selected] = $edited; $dirty = $true }
                }
            }
            'Enter' {
                if ($current) {
                    $script:FormIndex = 0
                    $edited = Show-TesterProfileForm $current 'Edit connection'
                    if ($edited) { $Profiles[$selected] = $edited; $dirty = $true }
                }
            }
            'F4' {
                if ($current -and (Confirm-TesterAction 'Delete' "Delete '$($current.Name)'?")) {
                    $script:Results.Remove($current.Name)
                    $Profiles.RemoveAt($selected)
                    if ($selected -ge $Profiles.Count) { $selected = [Math]::Max(0, $Profiles.Count - 1) }
                    $dirty = $true
                }
            }
            'F5' {
                if ($current) {
                    Write-TesterBar ($size.Height - 2) " Testing $($current.Name)..." 'Black' 'Yellow'
                    $script:Results[$current.Name] = Test-TesterProfile $current
                    Show-TesterTestResult $script:Results[$current.Name]
                }
            }
            'F6' {
                foreach ($p in $Profiles) {
                    Write-TesterBar ($size.Height - 2) " Testing $($p.Name)..." 'Black' 'Yellow'
                    $script:Results[$p.Name] = Test-TesterProfile $p
                }
                $ok = @($script:Results.Values | Where-Object Status -eq 'Success').Count
                Show-TesterMessage 'Test all' "$ok of $($Profiles.Count) connection(s) succeeded."
            }
            'F7' {
                if ($current) {
                    if ($script:Results[$current.Name]) { Show-TesterTestResult $script:Results[$current.Name] }
                    else { Show-TesterMessage 'Result' 'This connection has not been tested yet (F5).' }
                }
            }
            'F8' {
                if ($script:Results.Count -eq 0) { Show-TesterMessage 'Export' 'Nothing tested yet (F6 tests everything).'; continue }
                $default = Join-Path (Get-Location) 'connection-test-results.csv'
                $size2 = Get-TesterSize
                Clear-TesterArea 3 3 ($size2.Width - 6) 5
                Draw-TesterBox 3 3 ($size2.Width - 6) 5 'Export CSV' 'Yellow'
                Write-TesterAt 5 4 'File:' 'Gray'
                $target = Read-TesterFieldValue 11 4 ($size2.Width - 16) $default $false
                if ($target) {
                    try {
                        @($Profiles | Where-Object { $script:Results[$_.Name] } | ForEach-Object { $script:Results[$_.Name] }) |
                            Select-Object Name, ConnectionString, TestText, Status, ErrorMessage, TestedAt, ElapsedMs |
                            Export-Csv -Path $target -NoTypeInformation -Encoding UTF8
                        Show-TesterMessage 'Export' "Saved $($script:Results.Count) result(s) to:`n$target"
                    }
                    catch { Show-TesterMessage 'Export' (Get-TesterFullErrorText $_.Exception) 'Red' }
                }
            }
            'F9' {
                if ($current) {
                    try {
                        Set-Clipboard -Value (Build-TesterConnectionString $current)
                        Show-TesterMessage 'Copy' 'The connection string (including any password) was copied to the clipboard.'
                    }
                    catch { Show-TesterMessage 'Copy' (Get-TesterFullErrorText $_.Exception) 'Red' }
                }
            }
            'D' {
                if ($current) {
                    $copy = $current | Select-Object *
                    $copy.Name = "$($current.Name) (copy)"
                    [void]$Profiles.Add($copy)
                    $selected = $Profiles.Count - 1
                    $dirty = $true
                }
            }
        }
    }
}

function Show-TesterTestResult($Result) {
    $text = "Connection : $($Result.Name)`n" +
            "Status     : $($Result.Status)`n" +
            "TestText   : $($Result.TestText)`n" +
            "Tested     : $($Result.TestedAt.ToString('dd MMM yyyy HH:mm:ss')) ($($Result.ElapsedMs) ms)`n`n" +
            "Connection string:`n$($Result.ConnectionString)`n"
    if ($Result.ErrorMessage) { $text += "`nError:`n$($Result.ErrorMessage)" }
    Show-TesterMessage $(if ($Result.Status -eq 'Success') { 'Success' } else { 'Failure' }) $text $(if ($Result.Status -eq 'Success') { 'Green' } else { 'Red' })
}

Register-MhSelfTest -Name 'Invoke-MhSqlConnectionTester' -Test {
    Initialize-TesterSqlClient
    Test-MhSection "SQL client: $($script:TesterDriverName)"

    foreach ($method in $script:TesterAuthMethods) {
        $p = New-TesterProfile
        $p.Name = $method.Label; $p.Server = 'SQL01'; $p.Database = 'AppDb'; $p.Authentication = $method.Id
        $p.UserId = 'someone'; $p.Password = 'secret-value'
        $cs = Build-TesterConnectionString $p
        $expected = if ($method.Keyword) { $cs -like "*Authentication=$($method.Keyword)*" } elseif ($method.Id -eq 0) { $cs -like '*Integrated Security=True*' } else { $cs -like '*User ID=someone*' }
        Test-MhCheck "builds a connection string for $($method.Label)" $expected $cs
    }

    $p = New-TesterProfile
    $p.Server = 'SQL01'; $p.Authentication = 1; $p.UserId = 'sa'; $p.Password = 'secret-value'
    Test-MhCheck 'password is masked for display' ((Hide-TesterPassword (Build-TesterConnectionString $p)) -notlike '*secret-value*')

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "sct-selftest-$PID.json"
    try {
        $p.Name = 'round trip'; $p.SavePassword = $true
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add($p)
        Export-TesterProfiles $temp $list
        $raw = Get-Content -Raw $temp
        Test-MhCheck 'saved file does not contain the password in clear text' ($raw -notlike '*secret-value*')
        $loaded = @(Import-TesterProfiles $temp)
        Test-MhCheck 'saved connection loads back' ($loaded.Count -eq 1 -and $loaded[0].Name -eq 'round trip')
        Test-MhCheck 'encrypted password decrypts for this user' ($loaded[0].Password -eq 'secret-value')
        $p.SavePassword = $false
        Export-TesterProfiles $temp $list
        $loaded2 = @(Import-TesterProfiles $temp)
        Test-MhCheck 'password is not stored when not asked for' (-not $loaded2[0].Password)
    }
    finally { Remove-Item $temp -ErrorAction SilentlyContinue }

    Test-MhSection 'Choosing the SQL client'

    # the checks below can reject a client, and rejecting sets nothing - but a check that passed a
    # working type would replace the one this session loaded, so it is put back either way
    $heldType = $script:TesterConnectionType
    $heldName = $script:TesterDriverName
    $heldModern = $script:TesterDriverIsModern
    try {
        Test-MhCheck 'a type that cannot build a connection is refused' (-not (Use-TesterModernClient ([string]) 'a string, which is not a client'))
        Test-MhCheck 'refusing a client leaves the loaded one alone' ($script:TesterConnectionType -eq $heldType -and $script:TesterDriverName -eq $heldName)

        Test-MhCheck 'a DLL path that does not exist is refused' (-not (Import-TesterClientDll (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-sqlclient.dll')))
        Test-MhCheck 'an empty DLL path is refused' (-not (Import-TesterClientDll ''))

        $notAnAssembly = Join-Path ([System.IO.Path]::GetTempPath()) "mh-not-an-assembly-$PID.dll"
        try {
            Set-Content -Path $notAnAssembly -Value 'this is not an assembly' -Encoding UTF8
            Test-MhCheck 'a file that is not an assembly is refused rather than thrown' (-not (Import-TesterClientDll $notAnAssembly))
        }
        finally { Remove-Item $notAnAssembly -ErrorAction SilentlyContinue }

        $found = @(Find-TesterSqlClientDll)
        Test-MhCheck 'every DLL offered actually exists' (-not @($found | Where-Object { -not (Test-Path -LiteralPath $_) }).Count) ($found -join ', ')
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # the DLL beside the SqlServer module is the .NET Framework build: offering it here
            # only produces a BadImageFormatException to swallow
            $frameworkCopy = @($found | Where-Object { $_ -notmatch 'coreclr' -and $_ -match '\\Modules\\SqlServer\\' })
            Test-MhCheck 'the module .NET Framework build is not offered to PowerShell 7' (-not $frameworkCopy.Count) ($frameworkCopy -join ', ')
        }
        else {
            Test-MhSkip 'the module .NET Framework build is not offered to PowerShell 7' 'only applies to PowerShell 7'
        }
    }
    finally {
        $script:TesterConnectionType = $heldType
        $script:TesterDriverName = $heldName
        $script:TesterDriverIsModern = $heldModern
    }

    # whatever this machine ended up with, the auth matrix has to agree with it
    Test-MhCheck 'Windows and SQL authentication are available on any client' ((Test-TesterAuthSupported 0) -and (Test-TesterAuthSupported 1))
    if ($script:TesterDriverIsModern) {
        Test-MhCheck 'every Entra method is available on Microsoft.Data.SqlClient' (-not @($script:TesterAuthMethods | Where-Object { -not (Test-TesterAuthSupported $_.Id) }).Count)
    }
    else {
        Test-MhCheck 'the methods the built-in client cannot do are marked unavailable' (-not (Test-TesterAuthSupported 6)) 'service principal needs Microsoft.Data.SqlClient'
    }

    # the guard that stops the client being loaded twice
    $before = $script:TesterDriverName
    Initialize-TesterSqlClient
    Test-MhCheck 'asking for the client again keeps the one already loaded' ($script:TesterDriverName -eq $before) $script:TesterDriverName
}
