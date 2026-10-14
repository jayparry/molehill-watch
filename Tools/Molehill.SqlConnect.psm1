<#
    Molehill.SqlConnect

    The connect-to-SQL-Server screen, on its own, so that anything can use it.

    Why a module rather than more copied code: the connect screen, the authentication matrix and
    the connection string building were written for the sample export, and none of it is about
    sampling. Get-SqlConnectionString.ps1 shows the screen and hands the string to the pipeline;
    Start-DatabaseSampleTui.ps1 shows the same screen and then goes on to pick tables. Anything
    else that needs a connection can do either.

    Import it by path, because it lives beside the scripts rather than in a module folder:

        Import-Module (Join-Path $PSScriptRoot 'Molehill.SqlConnect.psm1')

    WHAT IS IN HERE
      The screen          Show-SqlConnectDialog, Show-SqlConnectForm, Show-SqlConnectOptions
      The settings        New-SqlConnectSettings, Test-SqlConnectSettings
      The string          New-SqlConnectionString, Hide-SqlSecret
      Authentication      Get-SqlAuthMethods, Get-SqlAuthMethod, Get-SqlAuthAvailability
      The driver          Get-SqlClientNamespace, Select-SqlClientNamespace
      Talking to SQL      Open-SqlConnection, Invoke-SqlQueryTable, Get-SqlServerInfo,
                          Get-SqlDatabaseList, Get-SqlConnectExplanation
      Console plumbing    Read-TuiKey, ConvertTo-TuiKeys, Set-TuiKeyScript, Write-Tui,
                          Write-TuiTitle, Write-TuiKeys, Write-TuiField, Clear-TuiScreen,
                          Get-TuiScreenWidth, Add-TuiChar, Remove-TuiChar
      Its own tests       Test-SqlConnectModule

    Everything drawn goes to the host with Write-Host, never to the output stream, so a script
    built on this can put its result on the pipeline and nothing else.

    Molehill Data Services.
#>

# No Set-StrictMode here on purpose: every function in this module was written and tested without
# it, and turning it on now would change how they behave in paths the tests do not reach.

#==============================================================================
# The keyboard
#
# Every key a screen reads comes through Read-TuiKey, which either reads the console or takes the
# next key off a scripted list. That is what makes the screens testable at all: a console read
# cannot be faked from outside, so the only way to walk them without a person sitting there is to
# hand them keys.
#==============================================================================
$script:KeyQueue = New-Object System.Collections.Generic.Queue[object]
$script:Scripted = $false

<#
  Hands the screens a list of keystrokes to read instead of the keyboard.

  While a script is loaded the screens also stop clearing the console, so the whole walk can be
  read afterwards, and a screen that runs out of keys leaves rather than hanging.
#>
function Set-TuiKeyScript {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Script)

    $script:KeyQueue.Clear()
    $script:Scripted = $false
    if (-not $Script -or @($Script).Count -eq 0) { return }
    foreach ($key in (ConvertTo-TuiKeys $Script)) { $script:KeyQueue.Enqueue($key) }
    $script:Scripted = $true
}
function New-TuiKey([string] $Name, [char] $Char = [char]0) {
    [pscustomobject]@{ Name = $Name; Char = $Char }
}
<#
  Turns a readable keystroke list into keys.

  'Down', 'Enter', 'Esc', 'Space', 'F5' and the rest name themselves; 'text:Sales' types the word
  a character at a time, which is what a person does; anything else one character long is that
  character.
#>
function ConvertTo-TuiKeys {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Script)

    $named = @{
        'up' = 'UpArrow'; 'down' = 'DownArrow'; 'left' = 'LeftArrow'; 'right' = 'RightArrow'
        'enter' = 'Enter'; 'return' = 'Enter'; 'esc' = 'Escape'; 'escape' = 'Escape'
        'tab' = 'Tab'; 'backspace' = 'Backspace'; 'delete' = 'Delete'; 'del' = 'Delete'
        'home' = 'Home'; 'end' = 'End'; 'pageup' = 'PageUp'; 'pagedown' = 'PageDown'
        'f1' = 'F1'; 'f2' = 'F2'; 'f3' = 'F3'; 'f4' = 'F4'; 'f5' = 'F5'; 'f6' = 'F6'
        'f7' = 'F7'; 'f8' = 'F8'; 'f9' = 'F9'; 'f12' = 'F12'
    }
    $keys = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Script)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if (-not $text) { continue }
        $lower = $text.ToLowerInvariant()
        if ($named.ContainsKey($lower)) { $keys.Add((New-TuiKey $named[$lower])); continue }
        if ($lower -eq 'space') { $keys.Add((New-TuiKey 'Spacebar' ' ')); continue }
        if ($lower.StartsWith('text:')) {
            foreach ($c in $text.Substring(5).ToCharArray()) { $keys.Add((New-TuiKey 'Character' $c)) }
            continue
        }
        if ($text.Length -eq 1) { $keys.Add((New-TuiKey 'Character' $text[0])); continue }
        throw "Don't know the key '$text'. Use a name (Down, Enter, Esc, Space, F5), a single character, or text:something."
    }
    $keys.ToArray()
}
function Read-TuiKey {
    if ($script:KeyQueue.Count -gt 0) { return $script:KeyQueue.Dequeue() }
    if ($script:Scripted) { return New-TuiKey 'Escape' }   # the script ran out: leave rather than hang
    $pressed = [Console]::ReadKey($true)
    $name = $pressed.Key.ToString()
    if ($name -eq 'Spacebar') { return New-TuiKey 'Spacebar' ' ' }
    if ($pressed.KeyChar -and [char]::IsLetterOrDigit($pressed.KeyChar) -or
        ($pressed.KeyChar -and [char]::IsPunctuation($pressed.KeyChar)) -or
        ($pressed.KeyChar -and [char]::IsSymbol($pressed.KeyChar))) {
        # a printable key is reported as the character as well as the key, so a field can take it
        return [pscustomobject]@{ Name = $name; Char = $pressed.KeyChar }
    }
    return New-TuiKey $name $pressed.KeyChar
}

#==============================================================================
# Drawing
#
# Guarded throughout: when the output is redirected - which is how the tests run - there is no
# console to clear, no window width to ask for and no colour to set.
#==============================================================================
$script:HasConsole = $false
try { $null = [Console]::WindowWidth; $script:HasConsole = $true } catch { $script:HasConsole = $false }
function Get-TuiScreenWidth {
    if (-not $script:HasConsole) { return 100 }
    try { return [math]::Max(80, [math]::Min(120, [Console]::WindowWidth - 1)) } catch { return 100 }
}
function Clear-TuiScreen {
    if ($script:HasConsole -and -not $script:Scripted) { try { [Console]::Clear() } catch { } }
    else { Write-Host '' }
}
function Write-Tui([string] $Text = '', [ConsoleColor] $Colour = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Colour
}
function Write-TuiTitle([string] $Text) {
    $width = Get-TuiScreenWidth
    Write-Tui ('=' * $width) Cyan
    Write-Tui ("  $Text") Cyan
    Write-Tui ('=' * $width) Cyan
}
function Write-TuiKeys([string] $Text) {
    Write-Tui ('-' * (Get-TuiScreenWidth)) DarkGray
    Write-Tui "  $Text" DarkGray
}
function Write-TuiField {
    param(
        [Parameter(Mandatory)][string] $Label,
        [AllowEmptyString()][string] $Value,
        [bool] $Focused = $false,
        [bool] $Enabled = $true,
        [AllowEmptyString()][string] $Note = ''
    )
    $marker = if ($Focused) { '>' } else { ' ' }
    $shown = if ($Enabled) { $Value } else { '' }
    $line = '{0} {1,-26}{2}' -f $marker, ($Label + ':'), $shown
    $colour = if (-not $Enabled) { [ConsoleColor]::DarkGray }
              elseif ($Focused) { [ConsoleColor]::White }
              else { [ConsoleColor]::Gray }
    Write-Tui $line $colour
    if ($Note) { Write-Tui ('   {0,-26}{1}' -f '', $Note) DarkGray }
}

#==============================================================================
# Editing a field
#==============================================================================
function Add-TuiChar {
    param([AllowEmptyString()] [string] $Value, [char] $Char)
    if ([int]$Char -lt 32 -or [int]$Char -eq 127) { return $Value }
    return $Value + $Char
}
function Remove-TuiChar {
    param([AllowEmptyString()] [string] $Value)
    if (-not $Value) { return '' }
    return $Value.Substring(0, $Value.Length - 1)
}

#==============================================================================
# Which driver, and what it can do
#==============================================================================
function Get-SqlClientNamespace {
    param([switch] $Microsoft)

    if (-not $Microsoft) { return 'System.Data.SqlClient' }
    if ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) { return 'Microsoft.Data.SqlClient' }
    try { Import-Module SqlServer -DisableNameChecking -ErrorAction Stop } catch { return $null }
    if ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) { return 'Microsoft.Data.SqlClient' }
    return $null
}
function New-ConnectionStringBuilder([string] $Namespace) {
    New-Object "$Namespace.SqlConnectionStringBuilder"
}
<#
  The authentication methods, in the order and under the names SSMS uses.

  Keyword is what goes into the connection string; $null means the method is not a connection
  string keyword at all - Windows authentication is Integrated Security, SQL authentication is a
  user and password, and an access token is set on the connection object afterwards.
#>
$script:AuthMethods = @(
    [pscustomobject]@{ Id = 'Windows';      Name = 'Windows Authentication';               Keyword = $null
                       User = 'none';   Secret = 'none';     Hint = 'the account running this PowerShell' }
    [pscustomobject]@{ Id = 'Sql';          Name = 'SQL Server Authentication';            Keyword = $null
                       User = 'required'; Secret = 'password'; Hint = 'a login created on the instance' }
    [pscustomobject]@{ Id = 'EntraMfa';     Name = 'Microsoft Entra MFA';                  Keyword = 'Active Directory Interactive'
                       User = 'optional'; Secret = 'none';     Hint = 'opens a browser to sign in; leave the user blank to be asked' }
    [pscustomobject]@{ Id = 'EntraPassword'; Name = 'Microsoft Entra Password';            Keyword = 'Active Directory Password'
                       User = 'required'; Secret = 'password'; Hint = 'no MFA on the account' }
    [pscustomobject]@{ Id = 'EntraIntegrated'; Name = 'Microsoft Entra Integrated';        Keyword = 'Active Directory Integrated'
                       User = 'none';   Secret = 'none';     Hint = 'a domain joined to Entra, signed in already' }
    [pscustomobject]@{ Id = 'EntraServicePrincipal'; Name = 'Microsoft Entra Service Principal'; Keyword = 'Active Directory Service Principal'
                       User = 'required'; Secret = 'password'; Hint = 'application id as the user, client secret as the password' }
    [pscustomobject]@{ Id = 'EntraManagedIdentity'; Name = 'Microsoft Entra Managed Identity'; Keyword = 'Active Directory Managed Identity'
                       User = 'optional'; Secret = 'none';     Hint = 'on an Azure VM; the user is the client id of a user-assigned identity' }
    [pscustomobject]@{ Id = 'EntraDeviceCode'; Name = 'Microsoft Entra Device Code';       Keyword = 'Active Directory Device Code Flow'
                       User = 'optional'; Secret = 'none';     Hint = 'for a server with no browser: sign in on another device' }
    [pscustomobject]@{ Id = 'EntraDefault'; Name = 'Microsoft Entra Default';              Keyword = 'Active Directory Default'
                       User = 'optional'; Secret = 'none';     Hint = 'whatever the machine is already signed in as' }
    [pscustomobject]@{ Id = 'Token';        Name = 'Access token';                         Keyword = $null
                       User = 'none';   Secret = 'token';    Hint = 'paste a token for https://database.windows.net/' }
)
<#
  Which of those this driver will actually accept, asked of the driver rather than assumed.

  The answer depends on the driver and on the edition of PowerShell: System.Data.SqlClient under
  Windows PowerShell understands Authentication = Active Directory Interactive, and the same
  namespace under PowerShell 7 does not understand the keyword at all. Rather than keeping a table
  of which is which and hoping it stays true, each keyword is set on a throwaway builder and the
  ones that throw are marked unavailable.
#>
function Get-SqlAuthAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Namespace)

    $builder = New-ConnectionStringBuilder $Namespace
    $result = [ordered]@{}
    foreach ($method in $script:AuthMethods) {
        if (-not $method.Keyword) { $result[$method.Id] = $true; continue }
        $ok = $false
        try {
            $builder['Authentication'] = $method.Keyword
            $ok = $true
        }
        catch { $ok = $false }
        $result[$method.Id] = $ok
    }
    $result
}
function Get-SqlAuthMethod([string] $Id) {
    foreach ($method in $script:AuthMethods) { if ($method.Id -eq $Id) { return $method } }
    $null
}
function Get-SqlAuthUnavailableReason {
    param([Parameter(Mandatory)] [string] $Namespace)

    if ($Namespace -eq 'Microsoft.Data.SqlClient') { return 'this build of Microsoft.Data.SqlClient does not have it' }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return 'System.Data.SqlClient has no Entra support on PowerShell 7 - press D for Microsoft.Data.SqlClient, or run this in Windows PowerShell'
    }
    return 'press D to switch to Microsoft.Data.SqlClient (Install-Module SqlServer)'
}

<#
  The driver to start on, and a word about it if it is not the one you would want.

  Microsoft.Data.SqlClient when it is available, because it is the one that can do every Entra
  method and Encrypt = Strict; System.Data.SqlClient when it is not, because it needs nothing
  installed and is the only one that will talk to SQL Server 2000 or 2005.
#>
function Select-SqlClientNamespace {
    [CmdletBinding()]
    param([switch] $PreferSystemData, [switch] $RequireMicrosoftData, [switch] $Quiet)

    if ($PreferSystemData) { return 'System.Data.SqlClient' }

    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) -and
        (Get-Module -ListAvailable SqlServer -ErrorAction SilentlyContinue) -and -not $Quiet) {
        Write-Host '  Loading the SqlServer module for Microsoft.Data.SqlClient...' -ForegroundColor DarkGray
    }
    $wanted = Get-SqlClientNamespace -Microsoft
    if ($wanted) { return $wanted }

    if (-not $Quiet) {
        if ($RequireMicrosoftData) {
            Write-Host '  Microsoft.Data.SqlClient is not available here, so this starts on System.Data.SqlClient.' -ForegroundColor Yellow
            Write-Host '  Install-Module SqlServer -Scope CurrentUser  - in this edition of PowerShell.' -ForegroundColor Gray
        }
        else {
            Write-Host '  System.Data.SqlClient: the SqlServer module is not installed, so the Entra methods are not on offer.' -ForegroundColor DarkGray
            Write-Host '  Install-Module SqlServer -Scope CurrentUser  adds them. Windows and SQL authentication work as they are.' -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    'System.Data.SqlClient'
}

# the methods, in the order and under the names SSMS uses
function Get-SqlAuthMethods { , $script:AuthMethods }

#==============================================================================
# The connection string
#==============================================================================
$script:EncryptChoices = @{
    'System.Data.SqlClient'    = @('Yes', 'No')
    'Microsoft.Data.SqlClient' = @('Mandatory', 'Optional', 'Strict')
}

<#
  A fresh set of connection settings, with the defaults that suit the driver.

  Encrypt is a yes or no on System.Data.SqlClient and one of three named levels on
  Microsoft.Data.SqlClient, so its default has to come from the namespace rather than be a
  constant - which is also why changing driver on the screen resets it.
#>
function New-SqlConnectSettings {
    [CmdletBinding()]
    param(
        [string] $Namespace = 'System.Data.SqlClient',
        [AllowEmptyString()] [string] $Server = '',
        [AllowEmptyString()] [string] $Database = '',
        [AllowEmptyString()] [string] $ApplicationName = 'Molehill SQL tools'
    )

    if (-not $script:EncryptChoices.ContainsKey($Namespace)) {
        throw "Don't know a driver called '$Namespace'. It is System.Data.SqlClient or Microsoft.Data.SqlClient."
    }
    [pscustomobject]@{
        Namespace       = $Namespace
        Server          = ([string]$Server).Trim()
        AuthId          = 'Windows'
        User            = ''
        Password        = ''
        Token           = ''
        Database        = ([string]$Database).Trim()
        Encrypt         = $script:EncryptChoices[$Namespace][0]
        TrustCert       = $true
        HostNameInCert  = ''
        TimeoutSeconds  = 15
        ApplicationName = $ApplicationName
        ReadOnlyIntent  = $false
        MultiSubnet     = $false
    }
}
<#
  The connection string for these settings, built by the driver's own builder so that what is
  shown is exactly what will be used - including the driver's own spelling of the keywords.
#>
function New-SqlConnectionString {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $builder = New-ConnectionStringBuilder $Settings.Namespace
    if ($Settings.Server) { $builder['Data Source'] = $Settings.Server }
    if ($Settings.Database) { $builder['Initial Catalog'] = $Settings.Database }
    if ($Settings.ApplicationName) { $builder['Application Name'] = $Settings.ApplicationName }
    $builder['Connect Timeout'] = $Settings.TimeoutSeconds

    # Encrypt is a yes or no on one driver and three named levels on the other
    if ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') { $builder['Encrypt'] = $Settings.Encrypt }
    else { $builder['Encrypt'] = ($Settings.Encrypt -eq 'Yes') }
    $builder['TrustServerCertificate'] = [bool]$Settings.TrustCert

    if ($Settings.HostNameInCert) {
        try { $builder['Host Name In Certificate'] = $Settings.HostNameInCert } catch { }
    }
    if ($Settings.ReadOnlyIntent) { try { $builder['ApplicationIntent'] = 'ReadOnly' } catch { } }
    if ($Settings.MultiSubnet) { try { $builder['MultiSubnetFailover'] = $true } catch { } }

    $method = Get-SqlAuthMethod $Settings.AuthId
    if ($method.Id -eq 'Windows') { $builder['Integrated Security'] = $true }
    if ($method.Keyword) { $builder['Authentication'] = $method.Keyword }
    if ($method.User -ne 'none' -and $Settings.User) { $builder['User ID'] = $Settings.User }
    if ($method.Secret -eq 'password' -and $Settings.Password) { $builder['Password'] = $Settings.Password }

    $builder.ConnectionString
}
function Hide-SqlSecret {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $ConnectionString)
    [regex]::Replace($ConnectionString, '(?i)(password\s*=\s*)("(?:[^"]|"")*"|''(?:[^'']|'''')*''|[^;]*)', '$1********')
}
function Test-SqlConnectSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Settings.Server.Trim()) { $problems.Add('a server name') }
    $method = Get-SqlAuthMethod $Settings.AuthId
    if ($method.User -eq 'required' -and -not $Settings.User.Trim()) {
        $problems.Add($(if ($method.Id -eq 'EntraServicePrincipal') { 'the application id, in the user box' } else { 'a user name' }))
    }
    if ($method.Secret -eq 'password' -and -not $Settings.Password) {
        $problems.Add($(if ($method.Id -eq 'EntraServicePrincipal') { 'the client secret, in the password box' } else { 'a password' }))
    }
    if ($method.Secret -eq 'token' -and -not $Settings.Token.Trim()) { $problems.Add('an access token') }
    $problems.ToArray()
}

#==============================================================================
# The screens
#==============================================================================
function Show-SqlConnectForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $fields = @('Server', 'Auth', 'User', 'Password', 'Database')
    $focus = 0
    $showSecret = $false
    $message = ''
    $availability = Get-SqlAuthAvailability -Namespace $Settings.Namespace

    while ($true) {
        $method = Get-SqlAuthMethod $Settings.AuthId
        Clear-TuiScreen
        Write-TuiTitle 'Connect to Server'
        Write-Tui ''
        Write-Tui ('   {0,-26}{1}' -f 'Server type:', 'Database Engine') DarkGray
        Write-TuiField -Label 'Server name' -Value $Settings.Server -Focused ($fields[$focus] -eq 'Server') `
                       -Note 'SQLPROD01, SQLPROD01\INST2, SQL01,14330, myserver.database.windows.net'
        $authNote = $method.Hint
        if (-not $availability[$method.Id]) { $authNote = 'NOT AVAILABLE: ' + (Get-SqlAuthUnavailableReason -Namespace $Settings.Namespace) }
        Write-TuiField -Label 'Authentication' -Value ("$($method.Name)   (left/right to change)") `
                       -Focused ($fields[$focus] -eq 'Auth') -Note $authNote

        $userLabel = if ($method.Id -eq 'EntraServicePrincipal') { 'Application id' }
                     elseif ($method.Id -eq 'EntraManagedIdentity') { 'Client id (optional)' }
                     else { 'User name' }
        $userValue = if ($method.Id -eq 'Windows') { "$([Environment]::UserDomainName)\$([Environment]::UserName)" } else { $Settings.User }
        Write-TuiField -Label $userLabel -Value $userValue -Focused ($fields[$focus] -eq 'User') `
                       -Enabled ($method.User -ne 'none')

        if ($method.Secret -eq 'token') {
            $shown = if ($showSecret) { $Settings.Token } else { '*' * [math]::Min(32, $Settings.Token.Length) }
            Write-TuiField -Label 'Access token' -Value $shown -Focused ($fields[$focus] -eq 'Password') `
                           -Note 'paste it; S shows it'
        }
        else {
            $secretLabel = if ($method.Id -eq 'EntraServicePrincipal') { 'Client secret' } else { 'Password' }
            $shown = if ($showSecret) { $Settings.Password } else { '*' * $Settings.Password.Length }
            Write-TuiField -Label $secretLabel -Value $shown -Focused ($fields[$focus] -eq 'Password') `
                           -Enabled ($method.Secret -eq 'password')
        }
        Write-TuiField -Label 'Database' -Value $Settings.Database -Focused ($fields[$focus] -eq 'Database') `
                       -Note 'leave blank to pick from a list once connected'

        Write-Tui ''
        Write-Tui "   Driver:               $($Settings.Namespace)" DarkGray
        Write-Tui ("   Encryption:           Encrypt = {0}, TrustServerCertificate = {1}{2}" -f
                   $Settings.Encrypt, $Settings.TrustCert,
                   $(if ($Settings.HostNameInCert) { ", HostNameInCertificate = $($Settings.HostNameInCert)" } else { '' })) DarkGray

        Write-Tui ''
        Write-Tui '  Connection string' Cyan
        $connectionString = ''
        $buildError = ''
        try { $connectionString = New-SqlConnectionString -Settings $Settings }
        catch { $buildError = $_.Exception.GetBaseException().Message }
        if ($buildError) { Write-Tui "    cannot be built: $buildError" Red }
        else {
            $display = if ($showSecret) { $connectionString } else { Hide-SqlSecret $connectionString }
            foreach ($chunk in ($display -split '(?<=;)' | Where-Object { $_ })) { Write-Tui "    $chunk" Yellow }
        }

        if ($message) { Write-Tui ''; Write-Tui "  $message" Yellow }
        Write-TuiKeys 'Up/Down field   Left/Right change   type to edit   F2 options   F3 driver   F4 show secrets   F6 copy string   F5 connect   Esc quit'

        $key = Read-TuiKey
        $message = ''
        $handled = $true
        switch ($key.Name) {
            'UpArrow'    { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow'  { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Tab'        { $focus = ($focus + 1) % $fields.Count }
            'Escape'     { return $null }
            'F5'         { $handled = $false }
            'F2'         { Show-SqlConnectOptions -Settings $Settings }
            'F3'         {
                $wanted = if ($Settings.Namespace -eq 'System.Data.SqlClient') { 'Microsoft.Data.SqlClient' } else { 'System.Data.SqlClient' }
                $got = Get-SqlClientNamespace -Microsoft:($wanted -eq 'Microsoft.Data.SqlClient')
                if (-not $got) {
                    $message = 'Microsoft.Data.SqlClient is not here. Run: Install-Module SqlServer -Scope CurrentUser (in this edition of PowerShell), then start this again.'
                }
                else {
                    $Settings.Namespace = $got
                    $Settings.Encrypt = $script:EncryptChoices[$got][0]
                    $availability = Get-SqlAuthAvailability -Namespace $got
                }
            }
            'F4'         { $showSecret = -not $showSecret }
            'F6'         {
                try { Set-Clipboard -Value $connectionString; $message = 'Connection string copied, password and all.' }
                catch { $message = 'Could not reach the clipboard here.' }
            }
            'Backspace'  {
                switch ($fields[$focus]) {
                    'Server'   { $Settings.Server = Remove-TuiChar $Settings.Server }
                    'User'     { $Settings.User = Remove-TuiChar $Settings.User }
                    'Password' { if ($method.Secret -eq 'token') { $Settings.Token = Remove-TuiChar $Settings.Token } else { $Settings.Password = Remove-TuiChar $Settings.Password } }
                    'Database' { $Settings.Database = Remove-TuiChar $Settings.Database }
                }
            }
            'LeftArrow'  {
                if ($fields[$focus] -eq 'Auth') {
                    $index = [array]::IndexOf(@($script:AuthMethods.Id), $Settings.AuthId)
                    $Settings.AuthId = $script:AuthMethods[($index - 1 + $script:AuthMethods.Count) % $script:AuthMethods.Count].Id
                }
            }
            'RightArrow' {
                if ($fields[$focus] -eq 'Auth') {
                    $index = [array]::IndexOf(@($script:AuthMethods.Id), $Settings.AuthId)
                    $Settings.AuthId = $script:AuthMethods[($index + 1) % $script:AuthMethods.Count].Id
                }
            }
            default      { $handled = $false }
        }
        if ($handled) { continue }

        if ($key.Name -eq 'F5') {
            if (-not $availability[$Settings.AuthId]) {
                $message = "$($method.Name) is not available on this driver. " + (Get-SqlAuthUnavailableReason -Namespace $Settings.Namespace)
                continue
            }
            $missing = Test-SqlConnectSettings -Settings $Settings
            if ($missing.Count) { $message = 'Still needs: ' + ($missing -join ', '); continue }
            return $connectionString
        }

        # Everything printable belongs to the box the caret is in. The commands are function keys
        # precisely so that they cannot be mistaken for typing: a letter used as a command only
        # works while the caret happens to be somewhere you cannot type, which on a form is most
        # of the time wrong.
        $char = if ($key.Char) { [string]$key.Char } else { '' }
        if ($char) {
            switch ($fields[$focus]) {
                'Server'   { $Settings.Server = Add-TuiChar $Settings.Server $key.Char }
                'User'     { if ($method.User -ne 'none') { $Settings.User = Add-TuiChar $Settings.User $key.Char } }
                'Password' {
                    if ($method.Secret -eq 'token') { $Settings.Token = Add-TuiChar $Settings.Token $key.Char }
                    elseif ($method.Secret -eq 'password') { $Settings.Password = Add-TuiChar $Settings.Password $key.Char }
                }
                'Database' { $Settings.Database = Add-TuiChar $Settings.Database $key.Char }
                'Auth'     {
                    # jump to the first method whose name starts with that letter, as a dropdown does
                    $match = @($script:AuthMethods | Where-Object { $_.Name.StartsWith($char, [StringComparison]::OrdinalIgnoreCase) })
                    if ($match.Count) { $Settings.AuthId = $match[0].Id }
                }
            }
        }
    }
}
function Show-SqlConnectOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $fields = @('Encrypt', 'TrustCert', 'HostNameInCert', 'TimeoutSeconds', 'ApplicationName', 'ReadOnlyIntent', 'MultiSubnet')
    $focus = 0
    while ($true) {
        Clear-TuiScreen
        Write-TuiTitle 'Connection Properties'
        Write-Tui ''
        $choices = $script:EncryptChoices[$Settings.Namespace]
        Write-TuiField -Label 'Encrypt' -Value ($Settings.Encrypt + '   (' + ($choices -join ' / ') + ')') -Focused ($fields[$focus] -eq 'Encrypt') `
                       -Note $(if ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') { 'Strict is TDS 8, for SQL Server 2022 and later' } else { 'the login packet is always encrypted whatever this says' })
        Write-TuiField -Label 'Trust server certificate' -Value $Settings.TrustCert -Focused ($fields[$focus] -eq 'TrustCert') `
                       -Note 'needed for a self-signed certificate, which is most on-premises instances'
        Write-TuiField -Label 'Host name in certificate' -Value $Settings.HostNameInCert -Focused ($fields[$focus] -eq 'HostNameInCert') `
                       -Enabled ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') -Note 'when the name you connect by is not the name on the certificate'
        Write-TuiField -Label 'Connect timeout (s)' -Value $Settings.TimeoutSeconds -Focused ($fields[$focus] -eq 'TimeoutSeconds')
        Write-TuiField -Label 'Application name' -Value $Settings.ApplicationName -Focused ($fields[$focus] -eq 'ApplicationName') `
                       -Note 'what the DBA sees in sys.dm_exec_sessions'
        Write-TuiField -Label 'Read-only intent' -Value $Settings.ReadOnlyIntent -Focused ($fields[$focus] -eq 'ReadOnlyIntent') `
                       -Note 'routes to a readable secondary in an availability group'
        Write-TuiField -Label 'Multi-subnet failover' -Value $Settings.MultiSubnet -Focused ($fields[$focus] -eq 'MultiSubnet')
        Write-TuiKeys 'Up/Down field   Left/Right or Space change   type to edit text   F5 or Esc back'

        $key = Read-TuiKey
        if ($key.Name -in 'Escape', 'Enter', 'F5') { return }
        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow' { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Backspace' {
                switch ($fields[$focus]) {
                    'HostNameInCert'  { $Settings.HostNameInCert = Remove-TuiChar $Settings.HostNameInCert }
                    'ApplicationName' { $Settings.ApplicationName = Remove-TuiChar $Settings.ApplicationName }
                    'TimeoutSeconds'  { $Settings.TimeoutSeconds = [int]((Remove-TuiChar ([string]$Settings.TimeoutSeconds)) + '0') }
                }
            }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        $cycle = ($key.Name -in 'LeftArrow', 'RightArrow', 'Spacebar')
        if ($cycle) {
            switch ($fields[$focus]) {
                'Encrypt' {
                    $index = [array]::IndexOf($choices, $Settings.Encrypt)
                    if ($index -lt 0) { $index = 0 }
                    $step = if ($key.Name -eq 'LeftArrow') { -1 } else { 1 }
                    $Settings.Encrypt = $choices[(($index + $step) + $choices.Count) % $choices.Count]
                }
                'TrustCert'      { $Settings.TrustCert = -not $Settings.TrustCert }
                'ReadOnlyIntent' { $Settings.ReadOnlyIntent = -not $Settings.ReadOnlyIntent }
                'MultiSubnet'    { $Settings.MultiSubnet = -not $Settings.MultiSubnet }
            }
            continue
        }

        if ($key.Char) {
            switch ($fields[$focus]) {
                'HostNameInCert'  { if ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') { $Settings.HostNameInCert = Add-TuiChar $Settings.HostNameInCert $key.Char } }
                'ApplicationName' { $Settings.ApplicationName = Add-TuiChar $Settings.ApplicationName $key.Char }
                'TimeoutSeconds'  {
                    if ([char]::IsDigit($key.Char)) {
                        $text = ([string]$Settings.TimeoutSeconds) + $key.Char
                        if ($text.Length -le 3) { $Settings.TimeoutSeconds = [int]$text }
                    }
                }
            }
        }
    }
}

#==============================================================================
# Talking to the server
#==============================================================================
function Open-SqlConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ConnectionString)

    $connection = New-Object "$($Settings.Namespace).SqlConnection" $ConnectionString
    if ($Settings.AuthId -eq 'Token') { $connection.AccessToken = $Settings.Token.Trim() }
    $connection.Open()
    $connection
}
function Invoke-SqlQueryTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection,
        [Parameter(Mandatory)] [string] $Query
    )
    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = 60
    $table = New-Object System.Data.DataTable
    $reader = $null
    try {
        $reader = $command.ExecuteReader()
        $table.Load($reader)
    }
    finally {
        if ($reader) { $reader.Dispose() }
        $command.Dispose()
    }
    , $table
}
function Get-SqlServerInfo {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection)

    $table = Invoke-SqlQueryTable -Connection $Connection -Query @'
SELECT  EngineEdition   = CAST(SERVERPROPERTY('EngineEdition') AS int),
        ProductVersion  = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
        Edition         = CAST(SERVERPROPERTY('Edition') AS nvarchar(128)),
        ServerName      = CAST(SERVERPROPERTY('ServerName') AS nvarchar(256)),
        LoggedInAs       = SUSER_SNAME(),
        CurrentDatabase = DB_NAME()
'@
    $row = $table.Rows[0]
    $edition = [int]$row['EngineEdition']
    [pscustomobject]@{
        Platform = switch ($edition) { 5 { 'Azure SQL Database' } 8 { 'Azure SQL Managed Instance' } 6 { 'Azure Synapse' } default { 'SQL Server' } }
        EngineEdition = $edition
        Version = [string]$row['ProductVersion']
        Major = [int](([string]$row['ProductVersion']).Split('.')[0])
        Edition = [string]$row['Edition']
        ServerName = [string]$row['ServerName']
        LoggedInAs = [string]$row['LoggedInAs']
        CurrentDatabase = [string]$row['CurrentDatabase']
    }
}
function Get-SqlDatabaseList {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection, [Parameter(Mandatory)] $Info)

    if ($Info.EngineEdition -eq 5) {
        # Azure SQL Database: no cross-database view worth the name, and master lists what it can
        $query = "SELECT Name = name, State = 'ONLINE' FROM sys.databases ORDER BY name"
    }
    elseif ($Info.Major -lt 9) {
        $query = "SELECT Name = name, State = 'ONLINE' FROM master.dbo.sysdatabases ORDER BY name"
    }
    else {
        $query = @"
SELECT Name = name, State = state_desc
FROM sys.databases
WHERE database_id = 1 OR database_id > 4
ORDER BY name
"@
    }
    Write-Output -NoEnumerate @((Invoke-SqlQueryTable -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_['Name']; State = [string]$_['State'] }
    })
}
function Get-SqlConnectExplanation {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Message, [Parameter(Mandatory)] $Settings)

    $text = $Message
    if ($text -match 'Login failed for user') {
        return 'The server was reached and the sign-in was refused. Check the user and password, and that the login exists on that instance.'
    }
    if ($text -match 'pre-login handshake|certificate chain|SSL Provider|forcibly closed') {
        $extra = if (-not $Settings.TrustCert) { ' Press O and turn on Trust server certificate: most on-premises instances have a self-signed one.' } else { '' }
        return ('Encryption could not be negotiated, which is not about the password - the login packet is encrypted whatever else you ask for.' + $extra +
                ' Test-SqlTlsHandshake.ps1 in this folder says which protocol and cipher the instance will accept.')
    }
    if ($text -match 'network-related or instance-specific|not found or was not accessible|No such host|network path was not found|server was not found') {
        return 'The name did not resolve, or nothing answered on it. Check the spelling, the port, and whether a named instance needs the SQL Browser service running.'
    }
    if ($text -match 'Cannot authenticate using Kerberos|SSPI') {
        return 'Windows authentication could not be completed - a Kerberos or SPN problem rather than a wrong password. A SQL login, or running this as a domain account that can reach the server, gets round it.'
    }
    if ($text -match 'timeout period elapsed|Connection Timeout Expired') {
        return 'It did not answer in time. That is a firewall or a wrong port far more often than a wrong password; raise the timeout with O if the server is simply slow to wake.'
    }
    if ($text -match 'AADSTS|Entra|Active Directory|token') {
        return 'Entra authentication did not complete. Check the account, and that the method on offer matches how that server expects you to sign in.'
    }
    if ($text -match 'Cannot open database|not able to access the database') {
        return 'The sign-in worked but that database would not open. Check the name, and that this login is a user in it.'
    }
    return ''
}

#==============================================================================
# The dialog: the form, then proving the connection works
#==============================================================================
<#
  Shows the connect screen and gives back a connection string that has been tried.

  The form on its own builds a string; this wraps it in the part that matters - opening the
  connection, and sending you back to the form with an explanation when it will not open. What
  comes back is the string, the settings behind it and what the server said about itself.

  -SkipTest returns the string as typed, without connecting, for when the string is the whole
  point and the server is somewhere else.
#>
function Show-SqlConnectDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings, [switch] $SkipTest)

    while ($true) {
        $connectionString = Show-SqlConnectForm -Settings $Settings
        if (-not $connectionString) { return $null }

        $method = Get-SqlAuthMethod $Settings.AuthId
        if ($SkipTest) {
            return [pscustomobject]@{
                ConnectionString = $connectionString; Settings = $Settings
                Namespace = $Settings.Namespace; AuthMethod = $method.Name
                AccessToken = $Settings.Token; Database = $Settings.Database; ServerInfo = $null
            }
        }

        $connection = $null
        try {
            Clear-TuiScreen
            Write-TuiTitle 'Connecting'
            Write-Tui ''
            Write-Tui ("  {0} as {1}, via {2}" -f $Settings.Server, $method.Name, $Settings.Namespace)
            $connection = Open-SqlConnection -Settings $Settings -ConnectionString $connectionString
            $info = Get-SqlServerInfo -Connection $connection
            Write-Tui ''
            Write-Tui ("  Connected to {0}" -f $info.ServerName) Green
            Write-Tui ("  {0} {1} ({2})" -f $info.Platform, $info.Version, $info.Edition)
            Write-Tui ("  signed in as {0}, database [{1}]" -f $info.LoggedInAs, $info.CurrentDatabase)
            return [pscustomobject]@{
                ConnectionString = $connectionString; Settings = $Settings
                Namespace = $Settings.Namespace; AuthMethod = $method.Name
                AccessToken = $Settings.Token; Database = $info.CurrentDatabase; ServerInfo = $info
            }
        }
        catch {
            $message = $_.Exception.GetBaseException().Message
            Write-Tui ''
            Write-Tui ("  Could not connect: {0}" -f (($message -split "`r?`n")[0])) Red
            $explain = Get-SqlConnectExplanation -Message $message -Settings $Settings
            if ($explain) { Write-Tui "  $explain" Yellow }
            Write-Tui ''
            Write-TuiKeys 'any key to go back to the connect screen, Esc to give up'
            if ((Read-TuiKey).Name -eq 'Escape') { return $null }
        }
        finally { if ($connection) { $connection.Dispose() } }
    }
}

#==============================================================================
# The module's own tests
#==============================================================================
<#
  Checks the parts that can be checked without a server: the string built for every method, how
  secrets are masked, the keystroke handling, what the form insists on, and how a failure to
  connect is explained. Both scripts that use this module call it from their own -SelfTest.
#>
function Test-SqlConnectModule {
    [CmdletBinding()]
    param()

    $script:failed = 0
    $script:skipped = 0
    $script:failed = 0
    $script:skipped = 0
    function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
        if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failed++ }
    }
    function Skip([string] $Name, [string] $Why) {
        Write-Host "  SKIP  $Name ($Why)" -ForegroundColor DarkGray
        $script:skipped++
    }
    function Settings([hashtable] $Change) {
        $s = New-SqlConnectSettings
        foreach ($key in $Change.Keys) { $s.$key = $Change[$key] }
        $s
    }


    Write-Host '  the keyboard' -ForegroundColor Gray
    Check 'a named key' ((ConvertTo-TuiKeys @('Down'))[0].Name -eq 'DownArrow')
    Check 'however it is spelled' ((ConvertTo-TuiKeys @('DOWN'))[0].Name -eq 'DownArrow')
    Check 'enter' ((ConvertTo-TuiKeys @('Enter'))[0].Name -eq 'Enter')
    Check 'escape' ((ConvertTo-TuiKeys @('Esc'))[0].Name -eq 'Escape')
    Check 'space carries its character' (
        ((ConvertTo-TuiKeys @('Space'))[0].Name -eq 'Spacebar') -and ((ConvertTo-TuiKeys @('Space'))[0].Char -eq ' '))
    Check 'typed text becomes one key per character' ((ConvertTo-TuiKeys @('text:Sales')).Count -eq 5)
    Check 'and keeps the characters' ((-join (ConvertTo-TuiKeys @('text:Sales')).Char) -eq 'Sales')
    Check 'a single character is itself' ((ConvertTo-TuiKeys @('x'))[0].Char -eq 'x')
    Check 'a list is taken in order' ((-join (ConvertTo-TuiKeys @('text:ab', 'Enter', 'c')).Name) -match 'CharacterCharacterEnterCharacter')
    Check 'nothing is nothing' ((ConvertTo-TuiKeys @()).Count -eq 0)
    $threw = $false
    try { [void](ConvertTo-TuiKeys @('Wingding')) } catch { $threw = $true }
    Check 'a key it does not know is refused, not guessed at' $threw
    Check 'the function keys the screens use' (
        (-join (ConvertTo-TuiKeys @('F2', 'F3', 'F4', 'F5', 'F6', 'F7')).Name) -eq 'F2F3F4F5F6F7')
    Check 'and a letter is still just a letter' ((ConvertTo-TuiKeys @('D'))[0].Name -eq 'Character')

    Write-Host '  editing a field' -ForegroundColor Gray
    Check 'a character is added' ((Add-TuiChar 'SQL' 'A') -eq 'SQLA')
    Check 'a control character is not' ((Add-TuiChar 'SQL' ([char]9)) -eq 'SQL')
    Check 'backspace removes one' ((Remove-TuiChar 'SQL') -eq 'SQ')
    Check 'and stops at empty' ((Remove-TuiChar '') -eq '')

    Write-Host '  the connection string it builds' -ForegroundColor Gray
    $windows = New-SqlConnectionString -Settings (Settings @{ Server = 'SQL01'; Database = 'Sales'; AuthId = 'Windows' })
    Check 'Windows authentication is integrated security' ($windows -match 'Integrated Security=True')
    Check 'with the server' ($windows -match 'Data Source=SQL01')
    Check 'and the database' ($windows -match 'Initial Catalog=Sales')
    Check 'and no user name' ($windows -notmatch 'User ID')
    $sql = New-SqlConnectionString -Settings (Settings @{ Server = 'SQL01'; AuthId = 'Sql'; User = 'sa'; Password = 'p@ss;word' })
    Check 'a SQL login carries its user' ($sql -match 'User ID=sa')
    Check 'and its password, quoted because of the semicolon' ($sql -match 'Password="p@ss;word"')
    Check 'and is not integrated security' ($sql -notmatch 'Integrated Security=True')
    $token = New-SqlConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = 'Token' })
    Check 'an access token puts nothing in the string' (($token -notmatch 'Authentication') -and ($token -notmatch 'User ID') -and ($token -notmatch 'Password'))
    $named = New-SqlConnectionString -Settings (Settings @{ Server = 'SQL01'; ApplicationName = 'Molehill TUI'; TimeoutSeconds = 45 })
    Check 'the application name goes in' ($named -match 'Application Name="?Molehill TUI"?')
    Check 'and the timeout' ($named -match 'Connect Timeout=45')
    $plain = New-SqlConnectionString -Settings (Settings @{ Server = 'SQL01'; Encrypt = 'No'; TrustCert = $false })
    Check 'encryption can be turned off on this driver' ($plain -match 'Encrypt=False')
    Check 'and trust with it' ($plain -match 'TrustServerCertificate=False')

    Write-Host '  the Entra methods, where the driver has them' -ForegroundColor Gray
    $available = Get-SqlAuthAvailability -Namespace 'System.Data.SqlClient'
    Check 'every method gets an answer' ($available.Count -eq $script:AuthMethods.Count)
    Check 'Windows is always there' ($available['Windows'])
    Check 'so is SQL' ($available['Sql'])
    Check 'and an access token' ($available['Token'])
    foreach ($id in 'EntraMfa', 'EntraPassword', 'EntraIntegrated') {
        $method = Get-SqlAuthMethod $id
        if ($available[$id]) {
            $built = New-SqlConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = $id; User = 'me@contoso.com'; Password = 'pw' })
            Check "$($method.Name) names its keyword" ($built -match [regex]::Escape($method.Keyword))
        }
        else { Skip "$($method.Name)" 'not on System.Data.SqlClient in this PowerShell' }
    }
    $mdsNamespace = Get-SqlClientNamespace -Microsoft
    if ($mdsNamespace) {
        $mdsAvailable = Get-SqlAuthAvailability -Namespace $mdsNamespace
        foreach ($id in 'EntraServicePrincipal', 'EntraManagedIdentity', 'EntraDeviceCode', 'EntraDefault') {
            $method = Get-SqlAuthMethod $id
            if (-not $mdsAvailable[$id]) { Skip "$($method.Name) on Microsoft.Data.SqlClient" 'this build does not have it'; continue }
            $built = New-SqlConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'x.database.windows.net'; AuthId = $id; User = 'appid'; Password = 'secret'; Encrypt = 'Mandatory' })
            Check "$($method.Name) builds on Microsoft.Data.SqlClient" ($built -match 'Authentication=')
        }
        $strict = New-SqlConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'SQL01'; Encrypt = 'Strict'; HostNameInCert = 'sql01.contoso.com' })
        Check 'Encrypt = Strict is accepted there' ($strict -match 'Encrypt=Strict')
        Check 'and a host name in the certificate' ($strict -match 'Host Name In Certificate=sql01\.contoso\.com')
    }
    else { Skip 'Microsoft.Data.SqlClient' 'the SqlServer module is not available in this PowerShell' }

    Write-Host '  keeping the password off the screen' -ForegroundColor Gray
    Check 'a password is masked' ((Hide-SqlSecret 'Data Source=x;Password=hunter2;Encrypt=True') -eq 'Data Source=x;Password=********;Encrypt=True')
    Check 'a quoted one too' ((Hide-SqlSecret 'Password="p;w";Encrypt=True') -eq 'Password=********;Encrypt=True')
    Check 'however it is spelled' ((Hide-SqlSecret 'password=abc') -eq 'password=********')
    Check 'and nothing else is touched' ((Hide-SqlSecret 'Data Source=x;User ID=sa') -eq 'Data Source=x;User ID=sa')

    Write-Host '  what it insists on before connecting' -ForegroundColor Gray
    Check 'a server name' ((Test-SqlConnectSettings -Settings (Settings @{ })) -contains 'a server name')
    Check 'a user for SQL authentication' ((Test-SqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql' })) -contains 'a user name')
    Check 'and a password' ((Test-SqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql'; User = 'sa' })) -contains 'a password')
    Check 'the application id for a service principal' (
        (Test-SqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraServicePrincipal' })) -contains 'the application id, in the user box')
    Check 'a token when that is the method' ((Test-SqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Token' })) -contains 'an access token')
    Check 'Windows authentication needs nothing else' ((Test-SqlConnectSettings -Settings (Settings @{ Server = 'x' })).Count -eq 0)
    Check 'and Entra integrated needs nothing else' ((Test-SqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraIntegrated' })).Count -eq 0)

    Write-Host '  explaining a failure to connect' -ForegroundColor Gray
    $s = New-SqlConnectSettings
    Check 'a refused login is not blamed on the network' ((Get-SqlConnectExplanation -Message "Login failed for user 'sa'." -Settings $s) -match 'refused')
    Check 'a handshake failure mentions the certificate switch' (
        (Get-SqlConnectExplanation -Message 'A connection was successfully established ... pre-login handshake' -Settings (Settings @{ TrustCert = $false })) -match 'Trust server certificate')
    Check 'and sends you to the TLS tool' ((Get-SqlConnectExplanation -Message 'pre-login handshake' -Settings $s) -match 'Test-SqlTlsHandshake')
    Check 'a timeout blames the firewall, not the password' ((Get-SqlConnectExplanation -Message 'Connection Timeout Expired' -Settings $s) -match 'firewall')
    Check 'a name that does not resolve is explained' ((Get-SqlConnectExplanation -Message 'The network path was not found.' -Settings $s) -match 'did not resolve')
    Check 'and a named instance is pointed at SQL Browser' ((Get-SqlConnectExplanation -Message 'error: 26 - Error Locating Server/Instance Specified, server was not found' -Settings $s) -match 'SQL Browser')
    Check 'an SSPI failure is not called a bad password' ((Get-SqlConnectExplanation -Message 'The target principal name is incorrect. Cannot generate SSPI context.' -Settings $s) -match 'Kerberos')
    Check 'an unknown error explains nothing rather than guessing' ((Get-SqlConnectExplanation -Message 'Something odd' -Settings $s) -eq '')

    Write-Host ''
    [pscustomobject]@{ Failed = $script:failed; Skipped = $script:skipped }
}

Export-ModuleMember -Function @(
    'Show-SqlConnectDialog', 'Show-SqlConnectForm', 'Show-SqlConnectOptions',
    'New-SqlConnectSettings', 'Test-SqlConnectSettings',
    'New-SqlConnectionString', 'Hide-SqlSecret',
    'Get-SqlAuthMethods', 'Get-SqlAuthMethod', 'Get-SqlAuthAvailability', 'Get-SqlAuthUnavailableReason',
    'Get-SqlClientNamespace', 'Select-SqlClientNamespace',
    'Open-SqlConnection', 'Invoke-SqlQueryTable', 'Get-SqlServerInfo', 'Get-SqlDatabaseList',
    'Get-SqlConnectExplanation',
    'Read-TuiKey', 'ConvertTo-TuiKeys', 'New-TuiKey', 'Set-TuiKeyScript',
    'Write-Tui', 'Write-TuiTitle', 'Write-TuiKeys', 'Write-TuiField',
    'Clear-TuiScreen', 'Get-TuiScreenWidth', 'Add-TuiChar', 'Remove-TuiChar',
    'Test-SqlConnectModule'
)
