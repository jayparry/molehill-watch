#Requires -Version 5.1

<#
.SYNOPSIS
    A connect-and-pick screen for Export-DatabaseSample.ps1: builds the connection the way SSMS
    does, shows you the connection string it built, lists the tables and lets you choose which
    ones to sample.

.DESCRIPTION
    Molehill Data Services | Start-DatabaseSampleTui

    Four screens, in order:

      1. CONNECT - server name, authentication, user, password, database, and an Options screen
         for encryption and the rest. Every authentication method SQL Server offers is listed,
         from Windows and SQL logins on a 2000 box through to Entra on Azure SQL Database and
         Managed Instance. The connection string it has built is shown at the bottom as you type,
         with the password masked until you ask for it.
      2. DATABASE - if you did not name one, the databases on that server, to pick from.
      3. TABLES - every table it would export, with its row count, and three ways to choose:
         ALL, only the ones you tick (include), or everything except the ones you tick (exclude).
      4. EXPORT - rows per table, where the zip goes, and the run itself.

    The export is done by Export-DatabaseSample.ps1 in the same folder, handed the exact
    connection string you saw and the exact table names you picked. Nothing is sampled until you
    confirm on the last screen.

    AUTHENTICATION, AND WHICH DRIVER CAN DO WHAT
    The methods on offer are not guessed at: each one is tried against the connection string
    builder when the screen opens, and anything the driver in use cannot do is shown greyed with
    the reason. There are two drivers and they differ:

      * System.Data.SqlClient ships with .NET and needs nothing installed. Under Windows
        PowerShell 5.1 it does Windows, SQL, and Entra interactive, password and integrated. It is
        also the only one that will talk to SQL Server 2000 or 2005. Under PowerShell 7 it loses
        the Entra methods entirely.
      * Microsoft.Data.SqlClient comes with the SqlServer module. It adds Entra service principal,
        managed identity, device code and default, and Encrypt = Strict (TDS 8). Install it with
        Install-Module SqlServer -Scope CurrentUser, in the edition of PowerShell you run this in,
        because the two editions look in different module folders.

    Press D on the connect screen to switch driver; the list of methods and options changes with
    it. No Az modules are used or needed.

.PARAMETER SqlInstance
    Fills the server box in, so you do not have to type it.

.PARAMETER Database
    Fills the database box in. Leave it out and you get the list to pick from.

.PARAMETER OutputPath
    Where the zip goes. Default: the current folder. Changeable on the export screen.

.PARAMETER Top
    Rows per table. Default 200. Changeable on the export screen.

.PARAMETER UseMicrosoftDataSqlClient
    Start on the Microsoft.Data.SqlClient driver rather than System.Data.SqlClient.

.PARAMETER KeyScript
    Drive the screens from a list of keystrokes instead of the keyboard, for testing and for
    recording a walkthrough. 'Down', 'Enter', 'Esc', 'Space', 'F5', 'text:SQLPROD01' and single
    characters are all understood.

.PARAMETER SelfTest
    Check the screen logic - the connection string built for every authentication method, how
    secrets are masked, the keystroke handling and the table picker - with no server at all.

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1 -SqlInstance SQLPROD01 -Database Sales

.EXAMPLE
    .\Start-DatabaseSampleTui.ps1 -SqlInstance myserver.database.windows.net -UseMicrosoftDataSqlClient

.NOTES
    Molehill Data Services. Reads only: it lists databases and tables, and the export it runs
    takes a sample of rows. Nothing on the server is changed.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $SqlInstance,
    [Parameter(Position = 1)] [string] $Database,
    [string] $OutputPath = (Get-Location).ProviderPath,
    [ValidateRange(1, 2147483647)] [int] $Top = 200,
    [switch] $UseMicrosoftDataSqlClient,
    [string[]] $KeyScript,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

#==============================================================================
# The keyboard
#
# Every key the screens read comes through Read-TuiKey, which either reads the console or takes
# the next key off a scripted list. That is what makes the screens testable at all: a console read
# cannot be faked from outside, so the only way to walk the screens without a person sitting there
# is to let the script hand them keys.
#==============================================================================
$script:KeyQueue = New-Object System.Collections.Generic.Queue[object]
$script:Scripted = $false

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
        'f1' = 'F1'; 'f2' = 'F2'; 'f5' = 'F5'; 'f10' = 'F10'
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
# Guarded throughout: when the output is redirected - which is how the self test runs - there is
# no console to clear, no window width to ask for and no colour to set.
#==============================================================================
$script:HasConsole = $false
try { $null = [Console]::WindowWidth; $script:HasConsole = $true } catch { $script:HasConsole = $false }

function Get-ScreenWidth {
    if (-not $script:HasConsole) { return 100 }
    try { return [math]::Max(80, [math]::Min(120, [Console]::WindowWidth - 1)) } catch { return 100 }
}

function Clear-Screen {
    if ($script:HasConsole -and -not $script:Scripted) { try { [Console]::Clear() } catch { } }
    else { Write-Host '' }
}

function Write-Tui([string] $Text = '', [ConsoleColor] $Colour = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Colour
}

function Write-TuiTitle([string] $Text) {
    $width = Get-ScreenWidth
    Write-Tui ('=' * $width) Cyan
    Write-Tui ("  $Text") Cyan
    Write-Tui ('=' * $width) Cyan
}

function Write-TuiKeys([string] $Text) {
    Write-Tui ('-' * (Get-ScreenWidth)) DarkGray
    Write-Tui "  $Text" DarkGray
}

# one line of a form: the caret marks what the keys act on
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
function Get-AuthAvailability {
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

function Get-AuthMethod([string] $Id) {
    foreach ($method in $script:AuthMethods) { if ($method.Id -eq $Id) { return $method } }
    $null
}

# why a method is not on offer, and what to do about it
function Get-AuthUnavailableReason {
    param([Parameter(Mandatory)] [string] $Namespace)

    if ($Namespace -eq 'Microsoft.Data.SqlClient') { return 'this build of Microsoft.Data.SqlClient does not have it' }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return 'System.Data.SqlClient has no Entra support on PowerShell 7 - press D for Microsoft.Data.SqlClient, or run this in Windows PowerShell'
    }
    return 'press D to switch to Microsoft.Data.SqlClient (Install-Module SqlServer)'
}

#==============================================================================
# The connection string
#==============================================================================
$script:EncryptChoices = @{
    'System.Data.SqlClient'    = @('Yes', 'No')
    'Microsoft.Data.SqlClient' = @('Mandatory', 'Optional', 'Strict')
}

function New-TuiSettings {
    [pscustomobject]@{
        Namespace       = 'System.Data.SqlClient'
        Server          = ''
        AuthId          = 'Windows'
        User            = ''
        Password        = ''
        Token           = ''
        Database        = ''
        Encrypt         = 'Yes'
        TrustCert       = $true
        HostNameInCert  = ''
        TimeoutSeconds  = 15
        ApplicationName = 'Molehill Export-DatabaseSample'
        ReadOnlyIntent  = $false
        MultiSubnet     = $false
    }
}

<#
  The connection string for these settings, built by the driver's own builder so that what is
  shown is exactly what will be used - including the driver's own spelling of the keywords.
#>
function New-TuiConnectionString {
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

    $method = Get-AuthMethod $Settings.AuthId
    if ($method.Id -eq 'Windows') { $builder['Integrated Security'] = $true }
    if ($method.Keyword) { $builder['Authentication'] = $method.Keyword }
    if ($method.User -ne 'none' -and $Settings.User) { $builder['User ID'] = $Settings.User }
    if ($method.Secret -eq 'password' -and $Settings.Password) { $builder['Password'] = $Settings.Password }

    $builder.ConnectionString
}

# a connection string is for showing people; the password in it is not
function Hide-TuiSecret {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $ConnectionString)
    [regex]::Replace($ConnectionString, '(?i)(password\s*=\s*)("(?:[^"]|"")*"|''(?:[^'']|'''')*''|[^;]*)', '$1********')
}

function Test-TuiSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Settings.Server.Trim()) { $problems.Add('a server name') }
    $method = Get-AuthMethod $Settings.AuthId
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
# Editing a field, and the small sums the screens do
#
# Every screen reads one key, decides whether that key was a command, and only then lets it fall
# through to typing. The deciding is done with a flag rather than with 'continue' inside a switch:
# that does not reliably skip the rest of the loop body, and the symptom was Space both ticking a
# table and typing a space into the filter box.
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

# what the three table modes mean, which is the one thing on that screen worth getting right
function Get-PickerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('All', 'Include', 'Exclude')] [string] $Mode,
        [int] $Total, [int] $Ticked
    )
    switch ($Mode) {
        'All' { return [pscustomobject]@{ Count = $Total; Text = "ALL TABLES - every one of the $Total will be exported" } }
        'Include' { return [pscustomobject]@{ Count = $Ticked; Text = "INCLUDE - $Ticked ticked of $Total, so $Ticked will be exported" } }
        default {
            $left = $Total - $Ticked
            return [pscustomobject]@{ Count = $left; Text = "EXCLUDE - $Ticked ticked of $Total, so $left will be exported" }
        }
    }
}

function Select-PickerRows {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Rows, [AllowEmptyString()] [string] $Filter)

    # -NoEnumerate so one match still comes back as a list: under Windows PowerShell 5.1 a single
    # object has no .Count, and counting the rows is most of what this screen does
    if (-not $Filter) { return Write-Output -NoEnumerate @($Rows) }
    $needle = $Filter.Trim()
    Write-Output -NoEnumerate @($Rows | Where-Object { "$($_.Schema).$($_.Table)" -like "*$needle*" })
}

function Format-Rows([object] $Value) {
    if ($null -eq $Value) { return '' }
    '{0:N0}' -f [int64]$Value
}

#==============================================================================
# Screen 1: connect
#==============================================================================
function Show-ConnectScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $fields = @('Server', 'Auth', 'User', 'Password', 'Database')
    $focus = 0
    $showSecret = $false
    $message = ''
    $availability = Get-AuthAvailability -Namespace $Settings.Namespace

    while ($true) {
        $method = Get-AuthMethod $Settings.AuthId
        Clear-Screen
        Write-TuiTitle 'Connect to Server'
        Write-Tui ''
        Write-Tui ('   {0,-26}{1}' -f 'Server type:', 'Database Engine') DarkGray
        Write-TuiField -Label 'Server name' -Value $Settings.Server -Focused ($fields[$focus] -eq 'Server') `
                       -Note 'SQLPROD01, SQLPROD01\INST2, SQL01,14330, myserver.database.windows.net'
        $authNote = $method.Hint
        if (-not $availability[$method.Id]) { $authNote = 'NOT AVAILABLE: ' + (Get-AuthUnavailableReason -Namespace $Settings.Namespace) }
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
        try { $connectionString = New-TuiConnectionString -Settings $Settings }
        catch { $buildError = $_.Exception.GetBaseException().Message }
        if ($buildError) { Write-Tui "    cannot be built: $buildError" Red }
        else {
            $display = if ($showSecret) { $connectionString } else { Hide-TuiSecret $connectionString }
            foreach ($chunk in ($display -split '(?<=;)' | Where-Object { $_ })) { Write-Tui "    $chunk" Yellow }
        }

        if ($message) { Write-Tui ''; Write-Tui "  $message" Yellow }
        Write-TuiKeys 'Up/Down field   Left/Right change   type to edit   O options   D driver   S show secrets   C copy string   F5 connect   Esc quit'

        $key = Read-TuiKey
        $message = ''
        $handled = $true
        switch ($key.Name) {
            'UpArrow'    { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow'  { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Tab'        { $focus = ($focus + 1) % $fields.Count }
            'Escape'     { return $null }
            'F5'         { $handled = $false }
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
                $message = "$($method.Name) is not available on this driver. " + (Get-AuthUnavailableReason -Namespace $Settings.Namespace)
                continue
            }
            $missing = Test-TuiSettings -Settings $Settings
            if ($missing.Count) { $message = 'Still needs: ' + ($missing -join ', '); continue }
            return $connectionString
        }

        # the letters that are commands rather than typing. They only mean anything while the
        # caret is not in a box you can type into, so a server called SALES01 is still typeable.
        $char = if ($key.Char) { [string]$key.Char } else { '' }
        $typeable = @('Server', 'User', 'Password', 'Database')
        if ($char -and $typeable -notcontains $fields[$focus]) {
            $command = $true
            switch ($char.ToUpperInvariant()) {
                'O' { Show-OptionsScreen -Settings $Settings }
                'D' {
                    $wanted = if ($Settings.Namespace -eq 'System.Data.SqlClient') { 'Microsoft.Data.SqlClient' } else { 'System.Data.SqlClient' }
                    $got = Get-SqlClientNamespace -Microsoft:($wanted -eq 'Microsoft.Data.SqlClient')
                    if (-not $got) {
                        $message = 'Microsoft.Data.SqlClient is not here. Run: Install-Module SqlServer -Scope CurrentUser (in this edition of PowerShell), then start this again.'
                    }
                    else {
                        $Settings.Namespace = $got
                        $Settings.Encrypt = $script:EncryptChoices[$got][0]
                        $availability = Get-AuthAvailability -Namespace $got
                    }
                }
                'S' { $showSecret = -not $showSecret }
                'C' {
                    try { Set-Clipboard -Value $connectionString; $message = 'Connection string copied, password and all.' }
                    catch { $message = 'Could not reach the clipboard here.' }
                }
                default { $command = $false }
            }
            if ($command) { continue }
        }

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

#==============================================================================
# Screen 1a: options
#==============================================================================
function Show-OptionsScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings)

    $fields = @('Encrypt', 'TrustCert', 'HostNameInCert', 'TimeoutSeconds', 'ApplicationName', 'ReadOnlyIntent', 'MultiSubnet')
    $focus = 0
    while ($true) {
        Clear-Screen
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
        Write-TuiKeys 'Up/Down field   Left/Right or Space change   type to edit text   Esc back'

        $key = Read-TuiKey
        if ($key.Name -eq 'Escape' -or $key.Name -eq 'Enter') { return }
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
function Open-TuiConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ConnectionString)

    $connection = New-Object "$($Settings.Namespace).SqlConnection" $ConnectionString
    if ($Settings.AuthId -eq 'Token') { $connection.AccessToken = $Settings.Token.Trim() }
    $connection.Open()
    $connection
}

function Invoke-TuiQuery {
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

function Get-TuiServerInfo {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection)

    $table = Invoke-TuiQuery -Connection $Connection -Query @'
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

function Get-TuiDatabaseList {
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
    Write-Output -NoEnumerate @((Invoke-TuiQuery -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_['Name']; State = [string]$_['State'] }
    })
}

<#
  The tables the export would consider, with their row counts.

  The same shape as Export-DatabaseSample's own discovery - user tables, nothing Microsoft shipped,
  no diagram support tables - so what is ticked here is what gets exported. SQL Server 2000 has
  none of those catalogue views, so it falls back to INFORMATION_SCHEMA and says what it cannot do.
#>
function Get-TuiTableList {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection, [Parameter(Mandatory)] $Info)

    if ($Info.Major -lt 9) {
        $query = @"
SELECT SchemaName = TABLE_SCHEMA, TableName = TABLE_NAME, [Rows] = CAST(0 AS bigint)
FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_SCHEMA, TABLE_NAME
"@
    }
    else {
        $query = @"
SELECT  SchemaName = s.name,
        TableName  = o.name,
        [Rows]     = ISNULL((SELECT SUM(p.rows) FROM sys.partitions AS p
                             WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)), 0)
FROM    sys.objects AS o
JOIN    sys.schemas AS s ON s.schema_id = o.schema_id
WHERE   o.type = 'U'
AND     o.is_ms_shipped = 0
AND     NOT EXISTS (SELECT 1 FROM sys.extended_properties AS ep
                    WHERE ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0
                    AND   ep.name = N'microsoft_database_tools_support')
ORDER BY s.name, o.name
"@
    }
    Write-Output -NoEnumerate @((Invoke-TuiQuery -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Schema = [string]$_['SchemaName']; Table = [string]$_['TableName']; Rows = [int64]$_['Rows']; Ticked = $false }
    })
}

#==============================================================================
# Screen 2: which database
#==============================================================================
function Show-DatabasePicker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Databases)

    if (@($Databases).Count -eq 0) { return $null }
    $index = 0
    $window = 15
    while ($true) {
        Clear-Screen
        Write-TuiTitle 'Which database'
        Write-Tui ''
        $first = [math]::Max(0, [math]::Min($index - [int]($window / 2), @($Databases).Count - $window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $window, @($Databases).Count); $i++) {
            $db = $Databases[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White } elseif ($db.State -ne 'ONLINE') { [ConsoleColor]::DarkGray } else { [ConsoleColor]::Gray }
            Write-Tui ('  {0} {1,-50} {2}' -f $marker, $db.Name, $(if ($db.State -ne 'ONLINE') { $db.State } else { '' })) $colour
        }
        Write-Tui ''
        Write-Tui ("  {0} of {1}" -f ($index + 1), @($Databases).Count) DarkGray
        Write-TuiKeys 'Up/Down   Enter choose   Esc back'

        $key = Read-TuiKey
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min(@($Databases).Count - 1, $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $window) }
            'PageDown'  { $index = [math]::Min(@($Databases).Count - 1, $index + $window) }
            'Home'      { $index = 0 }
            'End'       { $index = @($Databases).Count - 1 }
            'Enter'     { return $Databases[$index].Name }
            'Escape'    { return $null }
        }
    }
}

#==============================================================================
# Screen 3: which tables
#==============================================================================
function Show-TablePicker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Tables, [string] $DatabaseName)

    $mode = 'All'
    $index = 0
    $filter = ''
    $filtering = $false
    $window = 15
    $message = ''

    while ($true) {
        $visible = Select-PickerRows -Rows $Tables -Filter $filter
        if ($index -ge @($visible).Count) { $index = [math]::Max(0, @($visible).Count - 1) }
        $ticked = @($Tables | Where-Object { $_.Ticked }).Count
        $summary = Get-PickerSummary -Mode $mode -Total @($Tables).Count -Ticked $ticked

        Clear-Screen
        Write-TuiTitle "Tables in [$DatabaseName]"
        Write-Tui ''
        Write-Tui ("  Mode: " + $summary.Text) $(if ($summary.Count -eq 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })
        if ($filtering -or $filter) {
            Write-Tui ("  Filter: '{0}'{1} - {2} of {3} shown" -f $filter,
                       $(if ($filtering) { ' (typing; Enter or Esc to stop)' } else { '' }),
                       @($visible).Count, @($Tables).Count) $(if ($filtering) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray })
        }
        Write-Tui ''

        if (@($visible).Count -eq 0) { Write-Tui '    nothing matches that filter' DarkGray }
        $first = [math]::Max(0, [math]::Min($index - [int]($window / 2), @($visible).Count - $window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $window, @($visible).Count); $i++) {
            $row = $visible[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $box = if ($mode -eq 'All') { '   ' } elseif ($row.Ticked) { '[x]' } else { '[ ]' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White }
                      elseif ($mode -eq 'Exclude' -and $row.Ticked) { [ConsoleColor]::DarkGray }
                      else { [ConsoleColor]::Gray }
            Write-Tui ('  {0} {1} {2,-50} {3,12} rows' -f $marker, $box, "$($row.Schema).$($row.Table)", (Format-Rows $row.Rows)) $colour
        }
        Write-Tui ''
        Write-Tui ("  {0} of {1} listed" -f $(if (@($visible).Count) { $index + 1 } else { 0 }), @($visible).Count) DarkGray
        if ($message) { Write-Tui "  $message" Yellow }
        if ($filtering) { Write-TuiKeys 'type to narrow the list   Backspace   Enter or Esc to stop filtering' }
        else { Write-TuiKeys 'Up/Down   Space tick   M mode (All/Include/Exclude)   A all shown   N none   V invert shown   / filter   Enter continue   Esc back' }

        $key = Read-TuiKey
        $message = ''

        # while the filter is being typed the letters are letters, not commands
        if ($filtering) {
            switch ($key.Name) {
                'Enter'     { $filtering = $false }
                'Escape'    { $filtering = $false; $filter = ''; $index = 0 }
                'Backspace' { $filter = Remove-TuiChar $filter; $index = 0 }
                'UpArrow'   { $index = [math]::Max(0, $index - 1) }
                'DownArrow' { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + 1) }
                default     { if ($key.Char) { $filter = Add-TuiChar $filter $key.Char; $index = 0 } }
            }
            continue
        }

        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $window) }
            'PageDown'  { $index = [math]::Min([math]::Max(0, @($visible).Count - 1), $index + $window) }
            'Home'      { $index = 0 }
            'End'       { $index = [math]::Max(0, @($visible).Count - 1) }
            'Escape'    { return $null }
            'Spacebar'  {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press M to include or exclude.' }
                elseif (@($visible).Count) { $visible[$index].Ticked = -not $visible[$index].Ticked }
            }
            'Enter'     { $handled = $false }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        if ($key.Name -eq 'Enter') {
            if ($mode -eq 'All') { return [pscustomobject]@{ Mode = 'All'; Names = @() } }
            $names = @($Tables | Where-Object { $_.Ticked } | ForEach-Object { "$($_.Schema).$($_.Table)" })
            if ($names.Count -eq 0) {
                $message = 'Nothing is ticked. Tick some tables with Space, or press M for ALL.'
                continue
            }
            if ($mode -eq 'Exclude' -and $names.Count -eq @($Tables).Count) {
                $message = 'Every table is ticked to be excluded, which would export nothing.'
                continue
            }
            return [pscustomobject]@{ Mode = $mode; Names = $names }
        }

        if ($key.Char) {
            switch (([string]$key.Char).ToUpperInvariant()) {
                '/' { $filtering = $true; $message = 'Filtering.' }
                'M' { $mode = switch ($mode) { 'All' { 'Include' } 'Include' { 'Exclude' } default { 'All' } } }
                'A' { foreach ($row in $visible) { $row.Ticked = $true } }
                'N' { foreach ($row in $Tables) { $row.Ticked = $false } }
                'V' { foreach ($row in $visible) { $row.Ticked = -not $row.Ticked } }
                default { $message = "Nothing is bound to '$($key.Char)'. Press / to filter by name." }
            }
        }
    }
}

#==============================================================================
# Screen 4: the export itself
#==============================================================================
function Show-ExportScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Options, [Parameter(Mandatory)] $Choice, [Parameter(Mandatory)] [string] $DatabaseName)

    $fields = @('Top', 'OutputPath', 'ReadUncommitted', 'RemoveFolder', 'Force')
    $focus = 0
    $message = ''
    while ($true) {
        Clear-Screen
        Write-TuiTitle "Export a sample of [$DatabaseName]"
        Write-Tui ''
        Write-TuiField -Label 'Rows per table' -Value $Options.Top -Focused ($fields[$focus] -eq 'Top') -Note 'TOP (n) ... ORDER BY NEWID()'
        Write-TuiField -Label 'Output folder' -Value $Options.OutputPath -Focused ($fields[$focus] -eq 'OutputPath') `
                       -Note "the zip lands here as $DatabaseName.zip"
        Write-TuiField -Label 'Read uncommitted' -Value $Options.ReadUncommitted -Focused ($fields[$focus] -eq 'ReadUncommitted') `
                       -Note 'no shared locks taken, for a busy production table'
        Write-TuiField -Label 'Delete folder after zip' -Value $Options.RemoveFolder -Focused ($fields[$focus] -eq 'RemoveFolder')
        Write-TuiField -Label 'Replace what is there' -Value $Options.Force -Focused ($fields[$focus] -eq 'Force') `
                       -Note 'overwrite an existing folder and zip of the same name'
        Write-Tui ''
        $what = switch ($Choice.Mode) {
            'All'     { 'every table' }
            'Include' { "only these $(@($Choice.Names).Count): " + (@($Choice.Names) -join ', ') }
            default   { "everything except these $(@($Choice.Names).Count): " + (@($Choice.Names) -join ', ') }
        }
        Write-Tui "  Tables: $what" Cyan
        if ($message) { Write-Tui ''; Write-Tui "  $message" Yellow }
        Write-TuiKeys 'Up/Down field   Space toggle   type to edit   F5 export   Esc back'

        $key = Read-TuiKey
        $message = ''
        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow' { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Escape'    { return $false }
            'Backspace' {
                switch ($fields[$focus]) {
                    'Top'        { $Options.Top = [int]((Remove-TuiChar ([string]$Options.Top)) + '0') }
                    'OutputPath' { $Options.OutputPath = Remove-TuiChar $Options.OutputPath }
                }
            }
            'Spacebar'  {
                switch ($fields[$focus]) {
                    'ReadUncommitted' { $Options.ReadUncommitted = -not $Options.ReadUncommitted }
                    'RemoveFolder'    { $Options.RemoveFolder = -not $Options.RemoveFolder }
                    'Force'           { $Options.Force = -not $Options.Force }
                }
            }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        switch ($key.Name) {
            'F5'        {
                if (-not (Test-Path -LiteralPath $Options.OutputPath -PathType Container)) {
                    $message = "There is no folder called '$($Options.OutputPath)'."
                    continue
                }
                if ($Options.Top -lt 1) { $message = 'Rows per table has to be at least 1.'; continue }
                return $true
            }
        }
        if ($message) { continue }
        if ($key.Char) {
            switch ($fields[$focus]) {
                'Top' {
                    if ([char]::IsDigit($key.Char)) {
                        $text = ([string]$Options.Top) + $key.Char
                        if ($text.Length -le 9) { $Options.Top = [int]$text }
                    }
                }
                'OutputPath' { $Options.OutputPath = Add-TuiChar $Options.OutputPath $key.Char }
            }
        }
    }
}

#==============================================================================
# What went wrong, in words
#==============================================================================
function Get-TuiConnectExplanation {
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
# Self test
#==============================================================================
if ($SelfTest) {
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
        $s = New-TuiSettings
        foreach ($key in $Change.Keys) { $s.$key = $Change[$key] }
        $s
    }

    Write-Host 'Start-DatabaseSampleTui self test'

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

    Write-Host '  editing a field' -ForegroundColor Gray
    Check 'a character is added' ((Add-TuiChar 'SQL' 'A') -eq 'SQLA')
    Check 'a control character is not' ((Add-TuiChar 'SQL' ([char]9)) -eq 'SQL')
    Check 'backspace removes one' ((Remove-TuiChar 'SQL') -eq 'SQ')
    Check 'and stops at empty' ((Remove-TuiChar '') -eq '')

    Write-Host '  the connection string it builds' -ForegroundColor Gray
    $windows = New-TuiConnectionString -Settings (Settings @{ Server = 'SQL01'; Database = 'Sales'; AuthId = 'Windows' })
    Check 'Windows authentication is integrated security' ($windows -match 'Integrated Security=True')
    Check 'with the server' ($windows -match 'Data Source=SQL01')
    Check 'and the database' ($windows -match 'Initial Catalog=Sales')
    Check 'and no user name' ($windows -notmatch 'User ID')
    $sql = New-TuiConnectionString -Settings (Settings @{ Server = 'SQL01'; AuthId = 'Sql'; User = 'sa'; Password = 'p@ss;word' })
    Check 'a SQL login carries its user' ($sql -match 'User ID=sa')
    Check 'and its password, quoted because of the semicolon' ($sql -match 'Password="p@ss;word"')
    Check 'and is not integrated security' ($sql -notmatch 'Integrated Security=True')
    $token = New-TuiConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = 'Token' })
    Check 'an access token puts nothing in the string' (($token -notmatch 'Authentication') -and ($token -notmatch 'User ID') -and ($token -notmatch 'Password'))
    $named = New-TuiConnectionString -Settings (Settings @{ Server = 'SQL01'; ApplicationName = 'Molehill TUI'; TimeoutSeconds = 45 })
    Check 'the application name goes in' ($named -match 'Application Name="?Molehill TUI"?')
    Check 'and the timeout' ($named -match 'Connect Timeout=45')
    $plain = New-TuiConnectionString -Settings (Settings @{ Server = 'SQL01'; Encrypt = 'No'; TrustCert = $false })
    Check 'encryption can be turned off on this driver' ($plain -match 'Encrypt=False')
    Check 'and trust with it' ($plain -match 'TrustServerCertificate=False')

    Write-Host '  the Entra methods, where the driver has them' -ForegroundColor Gray
    $available = Get-AuthAvailability -Namespace 'System.Data.SqlClient'
    Check 'every method gets an answer' ($available.Count -eq $script:AuthMethods.Count)
    Check 'Windows is always there' ($available['Windows'])
    Check 'so is SQL' ($available['Sql'])
    Check 'and an access token' ($available['Token'])
    foreach ($id in 'EntraMfa', 'EntraPassword', 'EntraIntegrated') {
        $method = Get-AuthMethod $id
        if ($available[$id]) {
            $built = New-TuiConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = $id; User = 'me@contoso.com'; Password = 'pw' })
            Check "$($method.Name) names its keyword" ($built -match [regex]::Escape($method.Keyword))
        }
        else { Skip "$($method.Name)" 'not on System.Data.SqlClient in this PowerShell' }
    }
    $mdsNamespace = Get-SqlClientNamespace -Microsoft
    if ($mdsNamespace) {
        $mdsAvailable = Get-AuthAvailability -Namespace $mdsNamespace
        foreach ($id in 'EntraServicePrincipal', 'EntraManagedIdentity', 'EntraDeviceCode', 'EntraDefault') {
            $method = Get-AuthMethod $id
            if (-not $mdsAvailable[$id]) { Skip "$($method.Name) on Microsoft.Data.SqlClient" 'this build does not have it'; continue }
            $built = New-TuiConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'x.database.windows.net'; AuthId = $id; User = 'appid'; Password = 'secret'; Encrypt = 'Mandatory' })
            Check "$($method.Name) builds on Microsoft.Data.SqlClient" ($built -match 'Authentication=')
        }
        $strict = New-TuiConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'SQL01'; Encrypt = 'Strict'; HostNameInCert = 'sql01.contoso.com' })
        Check 'Encrypt = Strict is accepted there' ($strict -match 'Encrypt=Strict')
        Check 'and a host name in the certificate' ($strict -match 'Host Name In Certificate=sql01\.contoso\.com')
    }
    else { Skip 'Microsoft.Data.SqlClient' 'the SqlServer module is not available in this PowerShell' }

    Write-Host '  keeping the password off the screen' -ForegroundColor Gray
    Check 'a password is masked' ((Hide-TuiSecret 'Data Source=x;Password=hunter2;Encrypt=True') -eq 'Data Source=x;Password=********;Encrypt=True')
    Check 'a quoted one too' ((Hide-TuiSecret 'Password="p;w";Encrypt=True') -eq 'Password=********;Encrypt=True')
    Check 'however it is spelled' ((Hide-TuiSecret 'password=abc') -eq 'password=********')
    Check 'and nothing else is touched' ((Hide-TuiSecret 'Data Source=x;User ID=sa') -eq 'Data Source=x;User ID=sa')

    Write-Host '  what it insists on before connecting' -ForegroundColor Gray
    Check 'a server name' ((Test-TuiSettings -Settings (Settings @{ })) -contains 'a server name')
    Check 'a user for SQL authentication' ((Test-TuiSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql' })) -contains 'a user name')
    Check 'and a password' ((Test-TuiSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql'; User = 'sa' })) -contains 'a password')
    Check 'the application id for a service principal' (
        (Test-TuiSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraServicePrincipal' })) -contains 'the application id, in the user box')
    Check 'a token when that is the method' ((Test-TuiSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Token' })) -contains 'an access token')
    Check 'Windows authentication needs nothing else' ((Test-TuiSettings -Settings (Settings @{ Server = 'x' })).Count -eq 0)
    Check 'and Entra integrated needs nothing else' ((Test-TuiSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraIntegrated' })).Count -eq 0)

    Write-Host '  the three ways to choose tables' -ForegroundColor Gray
    Check 'all means all' ((Get-PickerSummary -Mode All -Total 10 -Ticked 0).Count -eq 10)
    Check 'and says so' ((Get-PickerSummary -Mode All -Total 10 -Ticked 3).Text -match 'every one of the 10')
    Check 'include exports what is ticked' ((Get-PickerSummary -Mode Include -Total 10 -Ticked 3).Count -eq 3)
    Check 'exclude exports the rest' ((Get-PickerSummary -Mode Exclude -Total 10 -Ticked 3).Count -eq 7)
    Check 'excluding everything exports nothing' ((Get-PickerSummary -Mode Exclude -Total 10 -Ticked 10).Count -eq 0)
    Check 'including nothing exports nothing' ((Get-PickerSummary -Mode Include -Total 10 -Ticked 0).Count -eq 0)

    $rows = @(
        [pscustomobject]@{ Schema = 'dbo'; Table = 'Orders' }
        [pscustomobject]@{ Schema = 'dbo'; Table = 'CustomerAudit' }
        [pscustomobject]@{ Schema = 'staging'; Table = 'Load' }
    )
    Check 'no filter shows everything' ((Select-PickerRows -Rows $rows -Filter '').Count -eq 3)
    Check 'one match is still a list, which 5.1 would otherwise not count' (
        $null -ne (Select-PickerRows -Rows $rows -Filter 'Orders').Count)
    Check 'a filter narrows it' ((Select-PickerRows -Rows $rows -Filter 'audit').Count -eq 1)
    Check 'and matches the schema too' ((Select-PickerRows -Rows $rows -Filter 'staging').Count -eq 1)
    Check 'and nothing is nothing' ((Select-PickerRows -Rows $rows -Filter 'zzz').Count -eq 0)

    Write-Host '  explaining a failure to connect' -ForegroundColor Gray
    $s = New-TuiSettings
    Check 'a refused login is not blamed on the network' ((Get-TuiConnectExplanation -Message "Login failed for user 'sa'." -Settings $s) -match 'refused')
    Check 'a handshake failure mentions the certificate switch' (
        (Get-TuiConnectExplanation -Message 'A connection was successfully established ... pre-login handshake' -Settings (Settings @{ TrustCert = $false })) -match 'Trust server certificate')
    Check 'and sends you to the TLS tool' ((Get-TuiConnectExplanation -Message 'pre-login handshake' -Settings $s) -match 'Test-SqlTlsHandshake')
    Check 'a timeout blames the firewall, not the password' ((Get-TuiConnectExplanation -Message 'Connection Timeout Expired' -Settings $s) -match 'firewall')
    Check 'a name that does not resolve is explained' ((Get-TuiConnectExplanation -Message 'The network path was not found.' -Settings $s) -match 'did not resolve')
    Check 'and a named instance is pointed at SQL Browser' ((Get-TuiConnectExplanation -Message 'error: 26 - Error Locating Server/Instance Specified, server was not found' -Settings $s) -match 'SQL Browser')
    Check 'an SSPI failure is not called a bad password' ((Get-TuiConnectExplanation -Message 'The target principal name is incorrect. Cannot generate SSPI context.' -Settings $s) -match 'Kerberos')
    Check 'an unknown error explains nothing rather than guessing' ((Get-TuiConnectExplanation -Message 'Something odd' -Settings $s) -eq '')

    Write-Host ''
    if ($script:failed -eq 0) {
        Write-Host ("All self tests passed{0}." -f $(if ($script:skipped) { ", $script:skipped skipped" } else { '' })) -ForegroundColor Green
        exit 0
    }
    Write-Host "$script:failed self test(s) failed." -ForegroundColor Red
    exit 1
}

#==============================================================================
# The run
#==============================================================================
$enginePath = Join-Path $PSScriptRoot 'Export-DatabaseSample.ps1'
if (-not (Test-Path -LiteralPath $enginePath)) {
    Write-Host "  Export-DatabaseSample.ps1 is not next to this script, and it is what does the exporting." -ForegroundColor Red
    Write-Host "  Looked in: $PSScriptRoot" -ForegroundColor Gray
    exit 2
}

if ($KeyScript) {
    $script:Scripted = $true
    foreach ($key in (ConvertTo-TuiKeys $KeyScript)) { $script:KeyQueue.Enqueue($key) }
}

$settings = New-TuiSettings
if ($SqlInstance) { $settings.Server = $SqlInstance.Trim() }
if ($Database) { $settings.Database = $Database.Trim() }
if ($UseMicrosoftDataSqlClient) {
    $wanted = Get-SqlClientNamespace -Microsoft
    if ($wanted) { $settings.Namespace = $wanted; $settings.Encrypt = $script:EncryptChoices[$wanted][0] }
    else {
        Write-Host '  Microsoft.Data.SqlClient is not available here, so this starts on System.Data.SqlClient.' -ForegroundColor Yellow
        Write-Host '  Install-Module SqlServer -Scope CurrentUser  - in this edition of PowerShell.' -ForegroundColor Gray
        Write-Host ''
    }
}

$exportOptions = [pscustomobject]@{
    Top = $Top; OutputPath = $OutputPath; ReadUncommitted = $false; RemoveFolder = $false; Force = $false
}
$exitCode = 0

while ($true) {
    $connectionString = Show-ConnectScreen -Settings $settings
    if (-not $connectionString) { Write-Host ''; Write-Host '  Nothing done.' -ForegroundColor Gray; break }

    $connection = $null
    $info = $null
    try {
        Clear-Screen
        Write-TuiTitle 'Connecting'
        Write-Tui ''
        Write-Tui "  $($settings.Server) as $((Get-AuthMethod $settings.AuthId).Name), via $($settings.Namespace)"
        $connection = Open-TuiConnection -Settings $settings -ConnectionString $connectionString
        $info = Get-TuiServerInfo -Connection $connection
        Write-Tui ''
        Write-Tui ("  Connected to {0}" -f $info.ServerName) Green
        Write-Tui ("  {0} {1} ({2})" -f $info.Platform, $info.Version, $info.Edition)
        Write-Tui ("  signed in as {0}, database [{1}]" -f $info.LoggedInAs, $info.CurrentDatabase)
        if ($info.Major -gt 0 -and $info.Major -lt 9) {
            Write-Tui '  This is SQL Server 2000. The export needs the catalogue views that arrived in 2005, so it will not run against it.' Yellow
        }
    }
    catch {
        $message = $_.Exception.GetBaseException().Message
        Write-Tui ''
        Write-Tui "  Could not connect: $(($message -split "`r?`n")[0])" Red
        $explain = Get-TuiConnectExplanation -Message $message -Settings $settings
        if ($explain) { Write-Tui "  $explain" Yellow }
        Write-Tui ''
        Write-TuiKeys 'any key to go back to the connect screen'
        [void](Read-TuiKey)
        if ($connection) { $connection.Dispose() }
        continue
    }

    try {
        # a database has to be settled before the tables can be listed, and the connection string
        # has to be rebuilt for it: Initial Catalog is part of what you were shown
        if (-not $settings.Database) {
            Write-Tui ''
            Write-Tui '  Reading the database list...' DarkGray
            $databases = Get-TuiDatabaseList -Connection $connection -Info $info
            $chosen = Show-DatabasePicker -Databases $databases
            if (-not $chosen) { $connection.Dispose(); continue }
            $settings.Database = $chosen
            $connection.Dispose()
            $connectionString = New-TuiConnectionString -Settings $settings
            $connection = Open-TuiConnection -Settings $settings -ConnectionString $connectionString
            $info = Get-TuiServerInfo -Connection $connection
        }

        Clear-Screen
        Write-TuiTitle "Reading the tables in [$($settings.Database)]"
        $tables = Get-TuiTableList -Connection $connection -Info $info
        $connection.Dispose()
        $connection = $null

        if (@($tables).Count -eq 0) {
            Write-Tui ''
            Write-Tui "  [$($settings.Database)] has no user tables to sample." Yellow
            Write-TuiKeys 'any key to go back'
            [void](Read-TuiKey)
            $settings.Database = ''
            continue
        }

        $choice = Show-TablePicker -Tables $tables -DatabaseName $settings.Database
        if (-not $choice) { $settings.Database = ''; continue }

        if (-not (Show-ExportScreen -Options $exportOptions -Choice $choice -DatabaseName $settings.Database)) { continue }

        Clear-Screen
        Write-TuiTitle "Exporting [$($settings.Database)]"
        Write-Tui ''
        $engineArgs = @{
            ConnectionString = $connectionString
            Database         = $settings.Database
            OutputPath       = $exportOptions.OutputPath
            Top              = $exportOptions.Top
        }
        if ($settings.Namespace -eq 'Microsoft.Data.SqlClient') { $engineArgs['UseMicrosoftDataSqlClient'] = $true }
        if ($settings.AuthId -eq 'Token') { $engineArgs['AccessToken'] = $settings.Token.Trim() }
        if ($exportOptions.ReadUncommitted) { $engineArgs['ReadUncommitted'] = $true }
        if ($exportOptions.RemoveFolder) { $engineArgs['RemoveFolderAfterZip'] = $true }
        if ($exportOptions.Force) { $engineArgs['Force'] = $true }
        if ($choice.Mode -eq 'Include') { $engineArgs['IncludeTable'] = $choice.Names }
        if ($choice.Mode -eq 'Exclude') { $engineArgs['ExcludeTable'] = $choice.Names }

        try {
            $result = & $enginePath @engineArgs
            if ($result -and $result.Failed -gt 0) { $exitCode = 1 }
        }
        catch {
            Write-Tui ''
            Write-Tui "  The export stopped: $(($_.Exception.GetBaseException().Message -split "`r?`n")[0])" Red
            $exitCode = 1
        }

        Write-Tui ''
        Write-TuiKeys 'any key for the connect screen, Esc to finish'
        $again = Read-TuiKey
        if ($again.Name -eq 'Escape') { break }
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
}

exit $exitCode
