<#
.SYNOPSIS
    SQL Connection Tester - PowerShell edition. A full-screen console app to build, save and test
    SQL Server connection strings, for places where running an .exe is not allowed.

.DESCRIPTION
    Same job as Tools\SqlConnectionTester (the C# app): each connection is opened and one row is read
    from dbo.TestConnection, giving ConnectionString, TestText, Status and the complete error.
    It reads and writes the same JSON file as the C# app, so the two are interchangeable.

    Read-only: it creates and changes nothing on the server. No modules and no installation needed.

    Authentication: Windows and SQL logins always work. The Entra ID methods need Microsoft's newer
    SQL client (Microsoft.Data.SqlClient). The script looks for it in the SqlServer PowerShell module,
    SSMS and Azure Data Studio, or takes -SqlClientDll. Without it, the built-in client is used and the
    methods it cannot do are shown as unavailable rather than failing oddly later.

    Keys: F2 add, F3 edit, F4 delete, F5 test, F6 test all, F7 full result, F8 export CSV, F9 duplicate,
          Ctrl+S save, Esc/Ctrl+Q quit, Enter edit, arrows/PgUp/PgDn move.

.EXAMPLE
    .\SqlConnectionTester.ps1
    # the app

.EXAMPLE
    .\SqlConnectionTester.ps1 -Test
    # test every saved connection and print the results (no UI)

.EXAMPLE
    .\SqlConnectionTester.ps1 -ConnectionString 'Server=SQL01;Database=AppDb;Integrated Security=SSPI' -Csv .\results.csv

.EXAMPLE
    .\SqlConnectionTester.ps1 'Server=SQL01;...' 'Server=SQL02;...'
    # several connection strings can simply follow each other

.EXAMPLE
    .\SqlConnectionTester.ps1 -File D:\client-a.json
    # keep a separate list per client (same file format as the C# app)
#>
[CmdletBinding()]
param(
    [string] $File,
    [switch] $Test,
    [string] $Csv,
    [Parameter(Position = 0)] [string[]] $ConnectionString,   # only this one is positional
    [string] $SqlClientDll,
    [switch] $SelfTest,
    # extra connection strings given without -ConnectionString (handy when the script is started with
    # powershell.exe -File, where comma separated arrays do not bind)
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Remaining
)

$ErrorActionPreference = 'Stop'
$script:DefaultQuery = 'SELECT TestText FROM dbo.TestConnection'
$script:DefaultFile = Join-Path $env:APPDATA 'SqlConnectionTester\connections.json'
if (-not $File) { $File = $script:DefaultFile }

#region ---------------------------------------------------------------- SQL client

# Authentication methods, in the same order as the C# app so the JSON files match.
$script:AuthMethods = @(
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

function Find-SqlClientDll {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($SqlClientDll) { $candidates.Add($SqlClientDll) }

    $module = Get-Module -ListAvailable SqlServer -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) { $candidates.Add((Join-Path $module.ModuleBase 'Microsoft.Data.SqlClient.dll')) }

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

function Initialize-SqlClient {
    # Prefer Microsoft.Data.SqlClient (all Entra methods); fall back to the built-in System.Data.SqlClient.
    foreach ($dll in Find-SqlClientDll) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            $type = [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient', $false)
            if (-not $type) { $type = [Microsoft.Data.SqlClient.SqlConnection] }
            # prove it can actually build a connection (native SNI present and loadable)
            $probe = $type::new('Server=(probe);Connect Timeout=1')
            $probe.Dispose()
            $script:ConnectionType = $type
            $script:DriverName = "Microsoft.Data.SqlClient ($([System.IO.Path]::GetFileName((Split-Path $dll -Parent))))"
            $script:DriverIsModern = $true
            return
        }
        catch { continue }
    }

    Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue
    $script:ConnectionType = [System.Data.SqlClient.SqlConnection]
    $script:DriverName = 'System.Data.SqlClient (built in)'
    $script:DriverIsModern = $false
}

function Test-AuthSupported([int] $AuthId) {
    if ($AuthId -le 1) { return $true }                       # Windows / SQL login: always
    if ($script:DriverIsModern) { return $true }              # Microsoft.Data.SqlClient: all of them
    # built-in client: .NET Framework manages password/integrated/interactive, .NET Core only the first two
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $AuthId -in @(2, 3, 4) }
    return $AuthId -in @(2, 3)
}

function Get-AuthMethod([int] $Id) { $script:AuthMethods | Where-Object Id -eq $Id }

#endregion

#region ---------------------------------------------------------------- model

function New-ConnectionProfile {
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
        Query                  = $script:DefaultQuery
    }
}

function Add-Part([System.Text.StringBuilder] $Sb, [string] $Key, $Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return }
    $text = "$Value"
    if ($text -match '[;"'']') { $text = '"' + $text.Replace('"', '""') + '"' }
    if ($Sb.Length -gt 0) { [void]$Sb.Append(';') }
    [void]$Sb.Append("$Key=$text")
}

function Build-ConnectionString($Profile) {
    if ($Profile.UseRawConnectionString) { return $Profile.RawConnectionString }

    $sb = New-Object System.Text.StringBuilder
    Add-Part $sb 'Data Source' $Profile.Server
    Add-Part $sb 'Initial Catalog' $Profile.Database

    $auth = Get-AuthMethod $Profile.Authentication
    switch ($Profile.Authentication) {
        0 { Add-Part $sb 'Integrated Security' 'True' }
        1 {
            Add-Part $sb 'User ID' $Profile.UserId
            Add-Part $sb 'Password' $Profile.Password
        }
        default {
            Add-Part $sb 'Authentication' $auth.Keyword
            if ($auth.NeedsUser) { Add-Part $sb 'User ID' $Profile.UserId }
            if ($auth.NeedsPassword) { Add-Part $sb 'Password' $Profile.Password }
        }
    }

    if ($script:DriverIsModern) {
        Add-Part $sb 'Encrypt' $Profile.Encrypt                     # Mandatory / Optional / Strict
    }
    else {
        Add-Part $sb 'Encrypt' $(if ($Profile.Encrypt -eq 'Optional') { 'False' } else { 'True' })
    }
    if ($Profile.TrustServerCertificate) { Add-Part $sb 'Trust Server Certificate' 'True' }
    if ($Profile.HostNameInCertificate -and $script:DriverIsModern) { Add-Part $sb 'Host Name In Certificate' $Profile.HostNameInCertificate }
    if ($Profile.ReadOnlyIntent) { Add-Part $sb 'ApplicationIntent' 'ReadOnly' }
    if ($Profile.MultiSubnetFailover) { Add-Part $sb 'MultiSubnetFailover' 'True' }
    Add-Part $sb 'Failover Partner' $Profile.FailoverPartner
    Add-Part $sb 'Connect Timeout' $Profile.ConnectTimeoutSeconds
    Add-Part $sb 'Application Name' $Profile.ApplicationName
    Add-Part $sb 'Pooling' 'False'                                   # never reuse a pooled connection for a test
    return $sb.ToString()
}

function Hide-Password([string] $Text) {
    if (-not $Text) { return $Text }
    return ($Text -replace '(?i)\b(password|pwd)\s*=\s*[^;]*', '$1=***')
}

function Get-ProfileDescription($Profile) {
    if ($Profile.UseRawConnectionString) { return 'Raw connection string' }
    $bits = @((Get-AuthMethod $Profile.Authentication).Label)
    if ($Profile.Database) { $bits += "database $($Profile.Database)" }
    $bits += "encrypt $($Profile.Encrypt)$(if ($Profile.TrustServerCertificate) { ' (trust cert)' })"
    if ($Profile.ReadOnlyIntent) { $bits += 'read-only intent' }
    if ($Profile.MultiSubnetFailover) { $bits += 'multi-subnet failover' }
    return ($bits -join ', ')
}

#endregion

#region ---------------------------------------------------------------- testing

function Get-FullErrorText($Exception) {
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

function Test-ConnectionProfile($Profile) {
    $connectionString = Build-ConnectionString $Profile
    $result = [pscustomobject]@{
        Name             = $Profile.Name
        ConnectionString = Hide-Password $connectionString
        TestText         = $null
        Status           = 'Failure'
        ErrorMessage     = $null
        TestedAt         = Get-Date
        ElapsedMs        = 0
    }

    if (-not $Profile.UseRawConnectionString -and -not (Test-AuthSupported $Profile.Authentication)) {
        $result.ErrorMessage = "$((Get-AuthMethod $Profile.Authentication).Label) needs Microsoft.Data.SqlClient, which was not found on this machine. " +
                               "Install the SqlServer PowerShell module or SSMS, or pass -SqlClientDll, or use the C# app."
        return $result
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = $null
    try {
        $connection = $script:ConnectionType::new($connectionString)
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = if ($Profile.Query) { $Profile.Query } else { $script:DefaultQuery }
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
        $result.ErrorMessage = Get-FullErrorText $_.Exception
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
    $result.ElapsedMs = $watch.ElapsedMilliseconds
    return $result
}

#endregion

#region ---------------------------------------------------------------- storage (same format as the C# app)

function Protect-Secret([string] $Value) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser'))
}

function Unprotect-Secret([string] $Value) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Value), $null, 'CurrentUser')
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Import-Profiles([string] $Path) {
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path $Path)) { return ,$list }
    $json = Get-Content -Raw -Path $Path
    if (-not $json.Trim()) { return ,$list }
    # Windows PowerShell 5.1 hands back the whole JSON array as one object, PowerShell 7 emits each element
    $parsed = $json | ConvertFrom-Json
    $items = if ($parsed -is [System.Array]) { $parsed } else { @($parsed) }
    foreach ($item in $items) {
        $p = New-ConnectionProfile
        foreach ($property in $item.PSObject.Properties) {
            if ($p.PSObject.Properties[$property.Name]) { $p.($property.Name) = $property.Value }
        }
        if ($p.ProtectedPassword) {
            try { $p.Password = Unprotect-Secret $p.ProtectedPassword } catch { $p.Password = '' }
        }
        [void]$list.Add($p)
    }
    return ,$list          # the comma keeps it a list: PowerShell would otherwise unroll a single item
}

function Export-Profiles([string] $Path, $Profiles) {
    $out = foreach ($p in $Profiles) {
        $copy = $p | Select-Object * -ExcludeProperty Password
        $copy.ProtectedPassword = if ($p.SavePassword -and $p.Password) { Protect-Secret $p.Password } else { $null }
        $copy
    }
    $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    # an array stays an array in the file, so the C# app reads it too
    ConvertTo-Json @($out) -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

#endregion

#region ---------------------------------------------------------------- console helpers

function Test-Interactive {
    try { $null = [Console]::WindowWidth; return -not [Console]::IsOutputRedirected } catch { return $false }
}

function Get-Size {
    $width = [Math]::Max(80, [Console]::WindowWidth)
    $height = [Math]::Max(24, [Console]::WindowHeight)
    return @{ Width = $width - 1; Height = $height }
}

function Write-At([int] $X, [int] $Y, [string] $Text, $Fore = 'Gray', $Back = 'Black') {
    if ($Y -lt 0 -or $Y -ge [Console]::WindowHeight) { return }
    $max = [Console]::WindowWidth - $X - 1
    if ($max -le 0) { return }
    if ($Text.Length -gt $max) { $Text = $Text.Substring(0, $max) }
    [Console]::SetCursorPosition($X, $Y)
    Write-Host $Text -NoNewline -ForegroundColor $Fore -BackgroundColor $Back
}

function Write-Bar([int] $Y, [string] $Text, $Fore = 'Black', $Back = 'Gray') {
    $size = Get-Size
    $padded = $Text.PadRight($size.Width)
    if ($padded.Length -gt $size.Width) { $padded = $padded.Substring(0, $size.Width) }
    Write-At 0 $Y $padded $Fore $Back
}

function Draw-Box([int] $X, [int] $Y, [int] $Width, [int] $Height, [string] $Title, $Fore = 'DarkGray') {
    $top = '+' + ('-' * [Math]::Max(0, $Width - 2)) + '+'
    if ($Title) {
        $label = " $Title "
        if ($label.Length -lt $Width - 2) { $top = '+' + $label + ('-' * ($Width - 2 - $label.Length)) + '+' }
    }
    Write-At $X $Y $top $Fore
    for ($i = 1; $i -lt $Height - 1; $i++) {
        Write-At $X ($Y + $i) '|' $Fore
        Write-At ($X + $Width - 1) ($Y + $i) '|' $Fore
    }
    Write-At $X ($Y + $Height - 1) ('+' + ('-' * [Math]::Max(0, $Width - 2)) + '+') $Fore
}

function Clear-Area([int] $X, [int] $Y, [int] $Width, [int] $Height) {
    $blank = ' ' * $Width
    for ($i = 0; $i -lt $Height; $i++) { Write-At $X ($Y + $i) $blank }
}

function Split-Text([string] $Text, [int] $Width) {
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

# Scrollable message window; used for the full error text
function Show-Message([string] $Title, [string] $Text, $TitleColour = 'White') {
    $size = Get-Size
    $width = $size.Width - 6
    $height = $size.Height - 6
    $x = 3
    $y = 2
    $lines = Split-Text $Text ($width - 4)
    $offset = 0
    $pageSize = $height - 4

    while ($true) {
        Clear-Area $x $y $width $height
        Draw-Box $x $y $width $height $Title $TitleColour
        for ($i = 0; $i -lt $pageSize; $i++) {
            $index = $offset + $i
            if ($index -ge $lines.Count) { break }
            Write-At ($x + 2) ($y + 1 + $i) $lines[$index] 'Gray'
        }
        $more = if ($lines.Count -gt $pageSize) { "  line $($offset + 1)-$([Math]::Min($offset + $pageSize, $lines.Count)) of $($lines.Count)   PgUp/PgDn to scroll" } else { '' }
        Write-At ($x + 2) ($y + $height - 2) "Esc or Enter to close$more" 'DarkGray'

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

function Confirm-Action([string] $Title, [string] $Question) {
    $size = Get-Size
    $width = [Math]::Min($size.Width - 10, [Math]::Max(40, $Question.Length + 8))
    $x = [int](($size.Width - $width) / 2)
    $y = [int]($size.Height / 2) - 3
    Clear-Area $x $y $width 6
    Draw-Box $x $y $width 6 $Title 'Yellow'
    Write-At ($x + 2) ($y + 2) $Question 'White'
    Write-At ($x + 2) ($y + 4) 'Y = yes,  N or Esc = no' 'DarkGray'
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Y') { return $true }
        if ($key.Key -eq 'N' -or $key.Key -eq 'Escape') { return $false }
    }
}

# Inline text editor for one field
function Read-FieldValue([int] $X, [int] $Y, [int] $Width, [string] $Value, [bool] $Secret) {
    $text = "$Value"
    while ($true) {
        $shown = if ($Secret) { '*' * $text.Length } else { $text }
        if ($shown.Length -ge $Width) { $shown = $shown.Substring($shown.Length - $Width + 1) }
        Write-At $X $Y ($shown.PadRight($Width)) 'White' 'DarkBlue'
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

#endregion

#region ---------------------------------------------------------------- edit form

function Show-ProfileForm($Profile, [string] $Title) {
    $work = $Profile | Select-Object *
    $encryptChoices = @('Mandatory', 'Optional', 'Strict')

    while ($true) {
        $auth = Get-AuthMethod $work.Authentication
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

        $size = Get-Size
        [Console]::Clear()
        Write-Bar 0 "  $Title " 'Black' 'Cyan'
        Draw-Box 1 1 ($size.Width - 2) ($fields.Count + 7) '' 'DarkGray'

        for ($i = 0; $i -lt $fields.Count; $i++) {
            $f = $fields[$i]
            $enabled = -not $f.ContainsKey('Enabled') -or $f.Enabled
            $value = switch ($f.Type) {
                'bool'   { if ($work.($f.Key)) { '[x]' } else { '[ ]' } }
                'secret' { if ($work.Password) { '*' * ([Math]::Min(20, $work.Password.Length)) } else { '' } }
                'auth'   { (Get-AuthMethod $work.Authentication).Label + $(if (Test-AuthSupported $work.Authentication) { '' } else { '  (not available with this SQL client)' }) }
                default  { "$($work.($f.Key))" }
            }
            $selected = ($i -eq $script:FormIndex)
            $labelColour = if (-not $enabled) { 'DarkGray' } elseif ($selected) { 'Yellow' } else { 'Gray' }
            $valueColour = if (-not $enabled) { 'DarkGray' } elseif ($selected) { 'White' } else { 'Gray' }
            $back = if ($selected) { 'DarkBlue' } else { 'Black' }
            Write-At 3 (2 + $i) ("$($f.Label):".PadRight(22)) $labelColour
            Write-At 25 (2 + $i) ($value.PadRight($size.Width - 28)) $valueColour $back
        }

        $y = $fields.Count + 3
        Write-At 3 $y ("Hint: " + $auth.Hint).PadRight($size.Width - 6) 'DarkCyan'
        $preview = Hide-Password (Build-ConnectionString $work)
        foreach ($line in (Split-Text "Preview: $preview" ($size.Width - 8)) | Select-Object -First 3) {
            $y++
            Write-At 3 $y $line.PadRight($size.Width - 6) 'DarkGreen'
        }

        Write-Bar ($size.Height - 1) ' Up/Down move   Enter or type = edit   Space toggles   Left/Right changes   F10 save   Esc cancel ' 'Black' 'Gray'

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
                        $next = ($work.Authentication + $step) % $script:AuthMethods.Count
                        if ($next -lt 0) { $next += $script:AuthMethods.Count }
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
                        $entered = Read-FieldValue 25 (2 + $script:FormIndex) ($size.Width - 28) $current $secret
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
                    $entered = Read-FieldValue 25 (2 + $script:FormIndex) ($size.Width - 28) "$($key.KeyChar)" $secret
                    if ($field.Type -eq 'int') { if ($entered -match '^\d+$' -and [int]$entered -gt 0) { $work.($field.Key) = [int]$entered } }
                    else { $work.($field.Key) = $entered }
                }
                continue
            }
        }

        # F10: validate and return
        if (-not $work.Name) { Show-Message 'Add' 'Give the connection a name.' 'Red'; continue }
        if (-not $work.UseRawConnectionString -and -not $work.Server) { Show-Message 'Add' 'Give a server.' 'Red'; continue }
        if ($work.UseRawConnectionString -and -not $work.RawConnectionString) { Show-Message 'Add' 'Give a raw connection string.' 'Red'; continue }
        if (-not $work.Query) { $work.Query = $script:DefaultQuery }
        return $work
    }
}

#endregion

#region ---------------------------------------------------------------- main screen

function Show-MainScreen([string] $Path, $Profiles) {
    $script:Results = @{}
    $selected = 0
    $dirty = $false
    [Console]::CursorVisible = $false

    while ($true) {
        $size = Get-Size
        $listWidth = [int]($size.Width * 0.42)
        $detailX = $listWidth + 1
        $detailWidth = $size.Width - $detailX
        $bodyHeight = $size.Height - 3

        [Console]::Clear()
        Write-Bar 0 "  SQL Connection Tester   -   $($script:DriverName)" 'Black' 'Cyan'
        Draw-Box 0 1 $listWidth $bodyHeight 'Connections'
        Draw-Box $detailX 1 $detailWidth $bodyHeight 'Details'

        if ($Profiles.Count -eq 0) {
            Write-At 2 3 'No connections yet.' 'DarkGray'
            Write-At 2 4 'Press F2 to add one.' 'DarkGray'
        }
        for ($i = 0; $i -lt $Profiles.Count -and $i -lt $bodyHeight - 2; $i++) {
            $p = $Profiles[$i]
            $result = $script:Results[$p.Name]
            $state = if (-not $result) { '[    ]' } elseif ($result.Status -eq 'Success') { '[ OK ]' } else { '[FAIL]' }
            $stateColour = if (-not $result) { 'DarkGray' } elseif ($result.Status -eq 'Success') { 'Green' } else { 'Red' }
            $back = if ($i -eq $selected) { 'DarkBlue' } else { 'Black' }
            $text = " $($p.Name)  -  $(if ($p.UseRawConnectionString) { 'raw' } else { $p.Server })"
            Write-At 1 (2 + $i) $state.PadRight(7) $stateColour $back
            Write-At 8 (2 + $i) $text.PadRight($listWidth - 9) $(if ($i -eq $selected) { 'White' } else { 'Gray' }) $back
        }

        if ($Profiles.Count -gt 0) {
            $p = $Profiles[$selected]
            $result = $script:Results[$p.Name]
            $detail = "$($p.Name)`n`n$(Get-ProfileDescription $p)`n`nConnection string:`n$(Hide-Password (Build-ConnectionString $p))`n`nQuery:`n$($p.Query)`n"
            if ($result) {
                $detail += "`nLast test: $($result.TestedAt.ToString('dd MMM yyyy HH:mm:ss')) ($($result.ElapsedMs) ms)`nStatus: $($result.Status)`n"
                if ($result.TestText) { $detail += "TestText: $($result.TestText)`n" }
                if ($result.ErrorMessage) { $detail += "`n$($result.ErrorMessage)`n" }
            }
            else { $detail += "`nNot tested yet (F5)." }

            $row = 2
            foreach ($line in (Split-Text $detail ($detailWidth - 4))) {
                if ($row -ge $bodyHeight) { Write-At ($detailX + 2) ($row - 1) '... F7 for the full result' 'DarkGray'; break }
                $colour = 'Gray'
                if ($line -like 'Status: Success*') { $colour = 'Green' }
                elseif ($line -like 'Status: Failure*') { $colour = 'Red' }
                elseif ($line -like 'TestText:*') { $colour = 'Cyan' }
                Write-At ($detailX + 2) $row $line $colour
                $row++
            }
        }

        $ok = @($script:Results.Values | Where-Object Status -eq 'Success').Count
        $fail = @($script:Results.Values | Where-Object Status -ne 'Success').Count
        Write-Bar ($size.Height - 2) " $($Profiles.Count) connection(s)   tested: $ok succeeded, $fail failed   file: $Path$(if ($dirty) { ' *' })" 'Black' 'DarkCyan'
        Write-Bar ($size.Height - 1) ' F2 add  F3 edit  F4 delete  F5 test  F6 test all  F7 result  F8 export  F9 copy  ^S save  Esc quit ' 'Black' 'Gray'

        $key = [Console]::ReadKey($true)
        $current = if ($Profiles.Count -gt 0) { $Profiles[$selected] } else { $null }

        if ($key.Modifiers -band [ConsoleModifiers]::Control) {
            switch ($key.Key) {
                'S' { Export-Profiles $Path $Profiles; $dirty = $false; Show-Message 'Saved' "Saved $($Profiles.Count) connection(s) to:`n$Path"; continue }
                'Q' { if ($dirty -and (Confirm-Action 'Quit' 'Save changes before quitting?')) { Export-Profiles $Path $Profiles }; return }
            }
            continue
        }

        switch ($key.Key) {
            'UpArrow'   { if ($selected -gt 0) { $selected-- } }
            'DownArrow' { if ($selected -lt $Profiles.Count - 1) { $selected++ } }
            'Home'      { $selected = 0 }
            'End'       { $selected = [Math]::Max(0, $Profiles.Count - 1) }
            'Escape'    { if ($dirty -and (Confirm-Action 'Quit' 'Save changes before quitting?')) { Export-Profiles $Path $Profiles }; return }
            'F2' {
                $script:FormIndex = 0
                $new = Show-ProfileForm (New-ConnectionProfile) 'Add connection'
                if ($new) { [void]$Profiles.Add($new); $selected = $Profiles.Count - 1; $dirty = $true }
            }
            'F3' {
                if ($current) {
                    $script:FormIndex = 0
                    $edited = Show-ProfileForm $current 'Edit connection'
                    if ($edited) { $Profiles[$selected] = $edited; $dirty = $true }
                }
            }
            'Enter' {
                if ($current) {
                    $script:FormIndex = 0
                    $edited = Show-ProfileForm $current 'Edit connection'
                    if ($edited) { $Profiles[$selected] = $edited; $dirty = $true }
                }
            }
            'F4' {
                if ($current -and (Confirm-Action 'Delete' "Delete '$($current.Name)'?")) {
                    $script:Results.Remove($current.Name)
                    $Profiles.RemoveAt($selected)
                    if ($selected -ge $Profiles.Count) { $selected = [Math]::Max(0, $Profiles.Count - 1) }
                    $dirty = $true
                }
            }
            'F5' {
                if ($current) {
                    Write-Bar ($size.Height - 2) " Testing $($current.Name)..." 'Black' 'Yellow'
                    $script:Results[$current.Name] = Test-ConnectionProfile $current
                    Show-TestResult $script:Results[$current.Name]
                }
            }
            'F6' {
                foreach ($p in $Profiles) {
                    Write-Bar ($size.Height - 2) " Testing $($p.Name)..." 'Black' 'Yellow'
                    $script:Results[$p.Name] = Test-ConnectionProfile $p
                }
                $ok = @($script:Results.Values | Where-Object Status -eq 'Success').Count
                Show-Message 'Test all' "$ok of $($Profiles.Count) connection(s) succeeded."
            }
            'F7' {
                if ($current) {
                    if ($script:Results[$current.Name]) { Show-TestResult $script:Results[$current.Name] }
                    else { Show-Message 'Result' 'This connection has not been tested yet (F5).' }
                }
            }
            'F8' {
                if ($script:Results.Count -eq 0) { Show-Message 'Export' 'Nothing tested yet (F6 tests everything).'; continue }
                $default = Join-Path (Get-Location) 'connection-test-results.csv'
                $size2 = Get-Size
                Clear-Area 3 3 ($size2.Width - 6) 5
                Draw-Box 3 3 ($size2.Width - 6) 5 'Export CSV' 'Yellow'
                Write-At 5 4 'File:' 'Gray'
                $target = Read-FieldValue 11 4 ($size2.Width - 16) $default $false
                if ($target) {
                    try {
                        @($Profiles | Where-Object { $script:Results[$_.Name] } | ForEach-Object { $script:Results[$_.Name] }) |
                            Select-Object Name, ConnectionString, TestText, Status, ErrorMessage, TestedAt, ElapsedMs |
                            Export-Csv -Path $target -NoTypeInformation -Encoding UTF8
                        Show-Message 'Export' "Saved $($script:Results.Count) result(s) to:`n$target"
                    }
                    catch { Show-Message 'Export' (Get-FullErrorText $_.Exception) 'Red' }
                }
            }
            'F9' {
                if ($current) {
                    try {
                        Set-Clipboard -Value (Build-ConnectionString $current)
                        Show-Message 'Copy' 'The connection string (including any password) was copied to the clipboard.'
                    }
                    catch { Show-Message 'Copy' (Get-FullErrorText $_.Exception) 'Red' }
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

function Show-TestResult($Result) {
    $text = "Connection : $($Result.Name)`n" +
            "Status     : $($Result.Status)`n" +
            "TestText   : $($Result.TestText)`n" +
            "Tested     : $($Result.TestedAt.ToString('dd MMM yyyy HH:mm:ss')) ($($Result.ElapsedMs) ms)`n`n" +
            "Connection string:`n$($Result.ConnectionString)`n"
    if ($Result.ErrorMessage) { $text += "`nError:`n$($Result.ErrorMessage)" }
    Show-Message $(if ($Result.Status -eq 'Success') { 'Success' } else { 'Failure' }) $text $(if ($Result.Status -eq 'Success') { 'Green' } else { 'Red' })
}

#endregion

#region ---------------------------------------------------------------- entry point

Initialize-SqlClient

if ($SelfTest) {
    $failures = 0
    function Check([string] $Name, [bool] $Condition, [string] $Detail = '') {
        if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failures++ }
    }
    Write-Host "SQL client: $($script:DriverName)"
    Write-Host "Self test"
    $script:failures = 0

    foreach ($method in $script:AuthMethods) {
        $p = New-ConnectionProfile
        $p.Name = $method.Label; $p.Server = 'SQL01'; $p.Database = 'AppDb'; $p.Authentication = $method.Id
        $p.UserId = 'someone'; $p.Password = 'secret-value'
        $cs = Build-ConnectionString $p
        $expected = if ($method.Keyword) { $cs -like "*Authentication=$($method.Keyword)*" } elseif ($method.Id -eq 0) { $cs -like '*Integrated Security=True*' } else { $cs -like '*User ID=someone*' }
        Check "builds a connection string for $($method.Label)" $expected $cs
    }

    $p = New-ConnectionProfile
    $p.Server = 'SQL01'; $p.Authentication = 1; $p.UserId = 'sa'; $p.Password = 'secret-value'
    Check 'password is masked for display' ((Hide-Password (Build-ConnectionString $p)) -notlike '*secret-value*')

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) "sct-selftest-$PID.json"
    try {
        $p.Name = 'round trip'; $p.SavePassword = $true
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add($p)
        Export-Profiles $temp $list
        $raw = Get-Content -Raw $temp
        Check 'saved file does not contain the password in clear text' ($raw -notlike '*secret-value*')
        $loaded = @(Import-Profiles $temp)
        Check 'saved connection loads back' ($loaded.Count -eq 1 -and $loaded[0].Name -eq 'round trip')
        Check 'encrypted password decrypts for this user' ($loaded[0].Password -eq 'secret-value')
        $p.SavePassword = $false
        Export-Profiles $temp $list
        $loaded2 = @(Import-Profiles $temp)
        Check 'password is not stored when not asked for' (-not $loaded2[0].Password)
    }
    finally { Remove-Item $temp -ErrorAction SilentlyContinue }

    Write-Host ""
    if ($script:failures -eq 0) { Write-Host "All self tests passed." -ForegroundColor Green; exit 0 }
    Write-Host "$($script:failures) self test(s) failed." -ForegroundColor Red
    exit 1
}

foreach ($extra in $Remaining) {
    if ($extra -match '=') { $ConnectionString += $extra }
    else { Write-Error "Unexpected argument '$extra'. Connection strings must contain '='."; exit 64 }
}

$profiles = Import-Profiles $File
foreach ($cs in $ConnectionString) {
    $p = New-ConnectionProfile
    $p.Name = if ($cs.Length -gt 40) { $cs.Substring(0, 40) + '...' } else { $cs }
    $p.UseRawConnectionString = $true
    $p.RawConnectionString = $cs
    [void]$profiles.Add($p)
}

$headless = $Test -or $Csv -or $ConnectionString

if (-not $headless) {
    if (-not (Test-Interactive)) {
        Write-Error "This needs a real console window. For scripts use: .\SqlConnectionTester.ps1 -Test"
        exit 1
    }
    try {
        Show-MainScreen $File $profiles
    }
    finally {
        try { [Console]::CursorVisible = $true; [Console]::ResetColor(); [Console]::Clear() } catch { }
    }
    exit 0
}

if ($profiles.Count -eq 0) {
    Write-Error "No connections to test. Add some in the app, or pass -ConnectionString '...'."
    exit 64
}

$results = foreach ($p in $profiles) {
    $r = Test-ConnectionProfile $p
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
exit $(if ($failed -eq 0) { 0 } else { 2 })

#endregion
