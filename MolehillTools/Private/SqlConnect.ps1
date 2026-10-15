<#
    The connect screen, the pickers and everything behind them.

    This is the whole of what used to be Tools\Molehill.SqlConnect.psm1. It sits in Private
    because the manifest decides what leaves the module; the functions named there with an Mh
    prefix are exported from here unchanged.
#>

#==============================================================================
# The keyboard
#
# Every key a screen reads comes through Read-MhTuiKey, which either reads the console or takes the
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
function Set-MhTuiKeyScript {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Script)

    $script:KeyQueue.Clear()
    $script:Scripted = $false
    if (-not $Script -or @($Script).Count -eq 0) { return }
    foreach ($key in (ConvertTo-MhTuiKeys $Script)) { $script:KeyQueue.Enqueue($key) }
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
function ConvertTo-MhTuiKeys {
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
function Read-MhTuiKey {
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
function Clear-MhTuiScreen {
    if ($script:HasConsole -and -not $script:Scripted) { try { [Console]::Clear() } catch { } }
    else { Write-Host '' }
}
function Write-MhTui([string] $Text = '', [ConsoleColor] $Colour = [ConsoleColor]::Gray) {
    Write-Host $Text -ForegroundColor $Colour
}
function Write-MhTuiTitle([string] $Text) {
    $width = Get-TuiScreenWidth
    Write-MhTui ('=' * $width) Cyan
    Write-MhTui ("  $Text") Cyan
    Write-MhTui ('=' * $width) Cyan
}
function Write-MhTuiKeys([string] $Text) {
    Write-MhTui ('-' * (Get-TuiScreenWidth)) DarkGray
    Write-MhTui "  $Text" DarkGray
}
function Write-MhTuiField {
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
    Write-MhTui $line $colour
    if ($Note) { Write-MhTui ('   {0,-26}{1}' -f '', $Note) DarkGray }
}

#==============================================================================
# Editing a field
#==============================================================================
function Add-MhTuiChar {
    param([AllowEmptyString()] [string] $Value, [char] $Char)
    if ([int]$Char -lt 32 -or [int]$Char -eq 127) { return $Value }
    return $Value + $Char
}
function Remove-MhTuiChar {
    param([AllowEmptyString()] [string] $Value)
    if (-not $Value) { return '' }
    return $Value.Substring(0, $Value.Length - 1)
}

#==============================================================================
# Picking things off a list
#
# Neither of these knows what it is showing. The caller says how to label a row and, if it wants,
# how to add a detail on the right and when to grey one out; everything else - paging, the filter,
# the ticking, the counting - is the same whether the rows are tables, databases or servers.
#
# The ticks are kept here rather than written onto the caller's objects: a picker that adds a
# property to what it was handed makes every caller build objects shaped for the picker.
#==============================================================================

# runs a caller's label or detail block with the row bound to $_
function Invoke-TuiBlock {
    [CmdletBinding()]
    param([AllowNull()] [scriptblock] $Block, [AllowNull()] $Item)

    if ($null -eq $Block) { return '' }
    [string](ForEach-Object -InputObject $Item -Process $Block)
}

<#
  The rows a filter leaves showing, matched on the label rather than on the object, because the
  label is what the person can see to type.

  Like everything else here it emits its rows one at a time, and callers wrap the call in @().
  That is the convention throughout this module, and it is deliberate: Write-Output -NoEnumerate
  would save a caller from remembering the @(), but a caller who wraps it anyway gets a single
  item holding an array - a list screen with one row whose label is every label at once.
#>
function Select-TuiRows {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Rows, [AllowEmptyString()] [string] $Filter)

    if (-not $Filter) { return $Rows }
    $needle = $Filter.Trim()
    $Rows | Where-Object { $_.Text -like "*$needle*" }
}

<#
  What the three modes mean, which is the one thing on a tick list worth getting right.

  All means all, whatever is ticked. Include means only what is ticked. Exclude means everything
  except what is ticked - so ticking all of them is a way of asking for nothing, and the screen
  needs to say so before Enter rather than after.
#>
function Get-MhTuiSelectionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('All', 'Include', 'Exclude')] [string] $Mode,
        [int] $Total, [int] $Ticked,
        [string] $ItemNoun = 'item', [string] $Action = 'used'
    )

    $plural = if ($Total -eq 1) { $ItemNoun } else { $ItemNoun + 's' }
    switch ($Mode) {
        'All' {
            return [pscustomobject]@{ Count = $Total; Text = "ALL - all $Total $plural will be $Action" }
        }
        'Include' {
            return [pscustomobject]@{ Count = $Ticked; Text = "INCLUDE - $Ticked of $Total $plural ticked, so $Ticked will be $Action" }
        }
        default {
            $left = $Total - $Ticked
            return [pscustomobject]@{ Count = $left; Text = "EXCLUDE - $Ticked of $Total $plural ticked, so $left will be $Action" }
        }
    }
}

# the rows a picker works with: labels worked out once, ticks kept beside them
function New-TuiRows {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Items,
        [AllowNull()] [scriptblock] $Label, [AllowNull()] [scriptblock] $Detail, [AllowNull()] [scriptblock] $Dim
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($item in @($Items)) {
        $rows.Add([pscustomobject]@{
            Index  = $index
            Item   = $item
            Text   = $(if ($Label) { Invoke-TuiBlock $Label $item } else { [string]$item })
            Detail = Invoke-TuiBlock $Detail $item
            Dim    = $(if ($Dim) { [bool](ForEach-Object -InputObject $item -Process $Dim) } else { $false })
            Ticked = $false
        })
        $index++
    }
    # .ToArray() rather than the list itself: @($genericList) throws "Argument types do not match"
    # on Windows PowerShell 5.1
    $rows.ToArray()
}

<#
  Pick one thing off a list.

  Returns the item the caller gave, not a copy of it, so the caller gets its own object back with
  whatever else was on it. Esc gives back nothing.
#>
function Show-MhTuiList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items,
        [string] $Title = 'Choose one',
        [scriptblock] $Label, [scriptblock] $Detail, [scriptblock] $Dim,
        [ValidateRange(5, 60)] [int] $Window = 15,
        [switch] $AllowFilter
    )

    $rows = @(New-TuiRows -Items $Items -Label $Label -Detail $Detail -Dim $Dim)
    if ($rows.Count -eq 0) { return $null }
    $index = 0
    $filter = ''
    $filtering = $false

    while ($true) {
        $visible = @(Select-TuiRows -Rows $rows -Filter $filter)
        if ($index -ge $visible.Count) { $index = [math]::Max(0, $visible.Count - 1) }

        Clear-MhTuiScreen
        Write-MhTuiTitle $Title
        Write-MhTui ''
        if ($filtering -or $filter) {
            Write-MhTui ("  Filter: '{0}'{1} - {2} of {3} shown" -f $filter,
                       $(if ($filtering) { ' (typing; Enter or Esc to stop)' } else { '' }),
                       $visible.Count, $rows.Count) $(if ($filtering) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray })
            Write-MhTui ''
        }
        if ($visible.Count -eq 0) { Write-MhTui '    nothing matches that filter' DarkGray }

        $first = [math]::Max(0, [math]::Min($index - [int]($Window / 2), $visible.Count - $Window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $Window, $visible.Count); $i++) {
            $row = $visible[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White } elseif ($row.Dim) { [ConsoleColor]::DarkGray } else { [ConsoleColor]::Gray }
            Write-MhTui ('  {0} {1,-50} {2}' -f $marker, $row.Text, $row.Detail) $colour
        }
        Write-MhTui ''
        Write-MhTui ("  {0} of {1}" -f $(if ($visible.Count) { $index + 1 } else { 0 }), $visible.Count) DarkGray
        if ($filtering) { Write-MhTuiKeys 'type to narrow the list   Backspace   Enter or Esc to stop filtering' }
        elseif ($AllowFilter) { Write-MhTuiKeys 'Up/Down   F7 filter   Enter choose   Esc back' }
        else { Write-MhTuiKeys 'Up/Down   Enter choose   Esc back' }

        $key = Read-MhTuiKey
        if ($filtering) {
            switch ($key.Name) {
                'Enter'     { $filtering = $false }
                'Escape'    { $filtering = $false; $filter = ''; $index = 0 }
                'Backspace' { $filter = Remove-MhTuiChar $filter; $index = 0 }
                'UpArrow'   { $index = [math]::Max(0, $index - 1) }
                'DownArrow' { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + 1) }
                default     { if ($key.Char) { $filter = Add-MhTuiChar $filter $key.Char; $index = 0 } }
            }
            continue
        }
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $Window) }
            'PageDown'  { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + $Window) }
            'Home'      { $index = 0 }
            'End'       { $index = [math]::Max(0, $visible.Count - 1) }
            'F7'        { if ($AllowFilter) { $filtering = $true } }
            'Escape'    { return $null }
            'Enter'     { if ($visible.Count) { return $visible[$index].Item } }
            default     { if ($AllowFilter -and $key.Char -eq '/') { $filtering = $true } }
        }
    }
}

<#
  Pick some things off a list, or say that you want all of them, or all but these.

  Gives back the mode and the items ticked - the caller's own objects, and their labels - leaving
  it to the caller to turn that into whatever its tool takes. Esc gives back nothing.
#>
function Show-MhTuiCheckList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Items,
        [string] $Title = 'Choose',
        [scriptblock] $Label, [scriptblock] $Detail, [scriptblock] $Dim,
        [string] $ItemNoun = 'item', [string] $Action = 'used',
        [ValidateRange(5, 60)] [int] $Window = 15
    )

    $rows = @(New-TuiRows -Items $Items -Label $Label -Detail $Detail -Dim $Dim)
    $mode = 'All'
    $index = 0
    $filter = ''
    $filtering = $false
    $message = ''

    while ($true) {
        $visible = @(Select-TuiRows -Rows $rows -Filter $filter)
        if ($index -ge $visible.Count) { $index = [math]::Max(0, $visible.Count - 1) }
        $ticked = @($rows | Where-Object { $_.Ticked }).Count
        $summary = Get-MhTuiSelectionSummary -Mode $mode -Total $rows.Count -Ticked $ticked -ItemNoun $ItemNoun -Action $Action

        Clear-MhTuiScreen
        Write-MhTuiTitle $Title
        Write-MhTui ''
        Write-MhTui ('  Mode: ' + $summary.Text) $(if ($summary.Count -eq 0) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })
        if ($filtering -or $filter) {
            Write-MhTui ("  Filter: '{0}'{1} - {2} of {3} shown" -f $filter,
                       $(if ($filtering) { ' (typing; Enter or Esc to stop)' } else { '' }),
                       $visible.Count, $rows.Count) $(if ($filtering) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray })
        }
        Write-MhTui ''
        if ($visible.Count -eq 0) { Write-MhTui '    nothing matches that filter' DarkGray }

        $first = [math]::Max(0, [math]::Min($index - [int]($Window / 2), $visible.Count - $Window))
        if ($first -lt 0) { $first = 0 }
        for ($i = $first; $i -lt [math]::Min($first + $Window, $visible.Count); $i++) {
            $row = $visible[$i]
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $box = if ($mode -eq 'All') { '   ' } elseif ($row.Ticked) { '[x]' } else { '[ ]' }
            $colour = if ($i -eq $index) { [ConsoleColor]::White }
                      elseif ($row.Dim -or ($mode -eq 'Exclude' -and $row.Ticked)) { [ConsoleColor]::DarkGray }
                      else { [ConsoleColor]::Gray }
            Write-MhTui ('  {0} {1} {2,-50} {3,14}' -f $marker, $box, $row.Text, $row.Detail) $colour
        }
        Write-MhTui ''
        Write-MhTui ("  {0} of {1} listed" -f $(if ($visible.Count) { $index + 1 } else { 0 }), $visible.Count) DarkGray
        if ($message) { Write-MhTui "  $message" Yellow }
        if ($filtering) { Write-MhTuiKeys 'type to narrow the list   Backspace   Enter or Esc to stop filtering' }
        else { Write-MhTuiKeys "Up/Down   Space tick   F2 mode (All/Include/Exclude)   F3 all shown   F4 none   F6 invert shown   F7 filter   Enter continue   Esc back" }

        $key = Read-MhTuiKey
        $message = ''

        if ($filtering) {
            switch ($key.Name) {
                'Enter'     { $filtering = $false }
                'Escape'    { $filtering = $false; $filter = ''; $index = 0 }
                'Backspace' { $filter = Remove-MhTuiChar $filter; $index = 0 }
                'UpArrow'   { $index = [math]::Max(0, $index - 1) }
                'DownArrow' { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + 1) }
                default     { if ($key.Char) { $filter = Add-MhTuiChar $filter $key.Char; $index = 0 } }
            }
            continue
        }

        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $index = [math]::Max(0, $index - 1) }
            'DownArrow' { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + 1) }
            'PageUp'    { $index = [math]::Max(0, $index - $Window) }
            'PageDown'  { $index = [math]::Min([math]::Max(0, $visible.Count - 1), $index + $Window) }
            'Home'      { $index = 0 }
            'End'       { $index = [math]::Max(0, $visible.Count - 1) }
            'Escape'    { return $null }
            'Spacebar'  {
                if ($mode -eq 'All') { $message = "Ticking does nothing in ALL mode. Press F2 to include or exclude." }
                elseif ($visible.Count) { $visible[$index].Ticked = -not $visible[$index].Ticked }
            }
            'F2'        { $mode = switch ($mode) { 'All' { 'Include' } 'Include' { 'Exclude' } default { 'All' } } }
            'F3'        {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press F2 to include or exclude.' }
                else { foreach ($row in $visible) { $row.Ticked = $true } }
            }
            'F4'        { foreach ($row in $rows) { $row.Ticked = $false } }
            'F6'        {
                if ($mode -eq 'All') { $message = 'Ticking does nothing in ALL mode. Press F2 to include or exclude.' }
                else { foreach ($row in $visible) { $row.Ticked = -not $row.Ticked } }
            }
            'F7'        { $filtering = $true }
            'Enter'     { $handled = $false }
            default     { $handled = $false }
        }
        if ($handled) { continue }

        if ($key.Name -eq 'Enter') {
            if ($mode -eq 'All') {
                return [pscustomobject]@{ Mode = 'All'; Items = @($rows | ForEach-Object { $_.Item }); Labels = @($rows | ForEach-Object { $_.Text }) }
            }
            $chosen = @($rows | Where-Object { $_.Ticked })
            if ($chosen.Count -eq 0) {
                $message = "Nothing is ticked. Tick some with Space, or press F2 for ALL."
                continue
            }
            if ($mode -eq 'Exclude' -and $chosen.Count -eq $rows.Count) {
                $message = "Every $ItemNoun is ticked to be excluded, which would leave nothing."
                continue
            }
            return [pscustomobject]@{
                Mode = $mode
                Items = @($chosen | ForEach-Object { $_.Item })
                Labels = @($chosen | ForEach-Object { $_.Text })
            }
        }

        # nothing on this screen is typed into, so the old letters still work as shortcuts
        if ($key.Char) {
            switch (([string]$key.Char).ToUpperInvariant()) {
                '/' { $filtering = $true }
                'M' { $mode = switch ($mode) { 'All' { 'Include' } 'Include' { 'Exclude' } default { 'All' } } }
                'A' { if ($mode -ne 'All') { foreach ($row in $visible) { $row.Ticked = $true } } }
                'N' { foreach ($row in $rows) { $row.Ticked = $false } }
                'V' { if ($mode -ne 'All') { foreach ($row in $visible) { $row.Ticked = -not $row.Ticked } } }
                default { $message = "Nothing is bound to '$($key.Char)'. F7 or / filters by name." }
            }
        }
    }
}

#==============================================================================
# Which driver, and what it can do
#==============================================================================
function Get-MhSqlClientNamespace {
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
function Get-MhSqlAuthAvailability {
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
function Select-MhSqlClientNamespace {
    [CmdletBinding()]
    param([switch] $PreferSystemData, [switch] $RequireMicrosoftData, [switch] $Quiet)

    if ($PreferSystemData) { return 'System.Data.SqlClient' }

    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type]) -and
        (Get-Module -ListAvailable SqlServer -ErrorAction SilentlyContinue) -and -not $Quiet) {
        Write-Host '  Loading the SqlServer module for Microsoft.Data.SqlClient...' -ForegroundColor DarkGray
    }
    $wanted = Get-MhSqlClientNamespace -Microsoft
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
function Get-MhSqlAuthMethods { , $script:AuthMethods }

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
function New-MhSqlConnectSettings {
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
function New-MhSqlConnectionString {
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
<#
  Masks the password in a connection string for anything that is going to be read by someone:
  a log, a ticket, the screen.

  Both spellings - Password and Pwd - and a quoted value, which is the case that matters: a
  password containing a semicolon is quoted, and a pattern that stops at the first semicolon
  shows the rest of it.
#>
function Hide-MhSqlSecret {
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $ConnectionString)
    [regex]::Replace($ConnectionString, '(?i)\b(password|pwd)(\s*=\s*)("(?:[^"]|"")*"|''(?:[^'']|'''')*''|[^;]*)', '$1$2********')
}
function Test-MhSqlConnectSettings {
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
    $availability = Get-MhSqlAuthAvailability -Namespace $Settings.Namespace

    while ($true) {
        $method = Get-SqlAuthMethod $Settings.AuthId
        Clear-MhTuiScreen
        Write-MhTuiTitle 'Connect to Server'
        Write-MhTui ''
        Write-MhTui ('   {0,-26}{1}' -f 'Server type:', 'Database Engine') DarkGray
        Write-MhTuiField -Label 'Server name' -Value $Settings.Server -Focused ($fields[$focus] -eq 'Server') `
                       -Note 'SQLPROD01, SQLPROD01\INST2, SQL01,14330, myserver.database.windows.net'
        $authNote = $method.Hint
        if (-not $availability[$method.Id]) { $authNote = 'NOT AVAILABLE: ' + (Get-SqlAuthUnavailableReason -Namespace $Settings.Namespace) }
        Write-MhTuiField -Label 'Authentication' -Value ("$($method.Name)   (left/right to change)") `
                       -Focused ($fields[$focus] -eq 'Auth') -Note $authNote

        $userLabel = if ($method.Id -eq 'EntraServicePrincipal') { 'Application id' }
                     elseif ($method.Id -eq 'EntraManagedIdentity') { 'Client id (optional)' }
                     else { 'User name' }
        $userValue = if ($method.Id -eq 'Windows') { "$([Environment]::UserDomainName)\$([Environment]::UserName)" } else { $Settings.User }
        Write-MhTuiField -Label $userLabel -Value $userValue -Focused ($fields[$focus] -eq 'User') `
                       -Enabled ($method.User -ne 'none')

        if ($method.Secret -eq 'token') {
            $shown = if ($showSecret) { $Settings.Token } else { '*' * [math]::Min(32, $Settings.Token.Length) }
            Write-MhTuiField -Label 'Access token' -Value $shown -Focused ($fields[$focus] -eq 'Password') `
                           -Note 'paste it; S shows it'
        }
        else {
            $secretLabel = if ($method.Id -eq 'EntraServicePrincipal') { 'Client secret' } else { 'Password' }
            $shown = if ($showSecret) { $Settings.Password } else { '*' * $Settings.Password.Length }
            Write-MhTuiField -Label $secretLabel -Value $shown -Focused ($fields[$focus] -eq 'Password') `
                           -Enabled ($method.Secret -eq 'password')
        }
        Write-MhTuiField -Label 'Database' -Value $Settings.Database -Focused ($fields[$focus] -eq 'Database') `
                       -Note 'leave blank to pick from a list once connected'

        Write-MhTui ''
        Write-MhTui "   Driver:               $($Settings.Namespace)" DarkGray
        Write-MhTui ("   Encryption:           Encrypt = {0}, TrustServerCertificate = {1}{2}" -f
                   $Settings.Encrypt, $Settings.TrustCert,
                   $(if ($Settings.HostNameInCert) { ", HostNameInCertificate = $($Settings.HostNameInCert)" } else { '' })) DarkGray

        Write-MhTui ''
        Write-MhTui '  Connection string' Cyan
        $connectionString = ''
        $buildError = ''
        try { $connectionString = New-MhSqlConnectionString -Settings $Settings }
        catch { $buildError = $_.Exception.GetBaseException().Message }
        if ($buildError) { Write-MhTui "    cannot be built: $buildError" Red }
        else {
            $display = if ($showSecret) { $connectionString } else { Hide-MhSqlSecret $connectionString }
            foreach ($chunk in ($display -split '(?<=;)' | Where-Object { $_ })) { Write-MhTui "    $chunk" Yellow }
        }

        if ($message) { Write-MhTui ''; Write-MhTui "  $message" Yellow }
        Write-MhTuiKeys 'Up/Down field   Left/Right change   type to edit   F2 options   F3 driver   F4 show secrets   F6 copy string   F5 connect   Esc quit'

        $key = Read-MhTuiKey
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
                $got = Get-MhSqlClientNamespace -Microsoft:($wanted -eq 'Microsoft.Data.SqlClient')
                if (-not $got) {
                    $message = 'Microsoft.Data.SqlClient is not here. Run: Install-Module SqlServer -Scope CurrentUser (in this edition of PowerShell), then start this again.'
                }
                else {
                    $Settings.Namespace = $got
                    $Settings.Encrypt = $script:EncryptChoices[$got][0]
                    $availability = Get-MhSqlAuthAvailability -Namespace $got
                }
            }
            'F4'         { $showSecret = -not $showSecret }
            'F6'         {
                try { Set-Clipboard -Value $connectionString; $message = 'Connection string copied, password and all.' }
                catch { $message = 'Could not reach the clipboard here.' }
            }
            'Backspace'  {
                switch ($fields[$focus]) {
                    'Server'   { $Settings.Server = Remove-MhTuiChar $Settings.Server }
                    'User'     { $Settings.User = Remove-MhTuiChar $Settings.User }
                    'Password' { if ($method.Secret -eq 'token') { $Settings.Token = Remove-MhTuiChar $Settings.Token } else { $Settings.Password = Remove-MhTuiChar $Settings.Password } }
                    'Database' { $Settings.Database = Remove-MhTuiChar $Settings.Database }
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
            $missing = Test-MhSqlConnectSettings -Settings $Settings
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
                'Server'   { $Settings.Server = Add-MhTuiChar $Settings.Server $key.Char }
                'User'     { if ($method.User -ne 'none') { $Settings.User = Add-MhTuiChar $Settings.User $key.Char } }
                'Password' {
                    if ($method.Secret -eq 'token') { $Settings.Token = Add-MhTuiChar $Settings.Token $key.Char }
                    elseif ($method.Secret -eq 'password') { $Settings.Password = Add-MhTuiChar $Settings.Password $key.Char }
                }
                'Database' { $Settings.Database = Add-MhTuiChar $Settings.Database $key.Char }
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
        Clear-MhTuiScreen
        Write-MhTuiTitle 'Connection Properties'
        Write-MhTui ''
        $choices = $script:EncryptChoices[$Settings.Namespace]
        Write-MhTuiField -Label 'Encrypt' -Value ($Settings.Encrypt + '   (' + ($choices -join ' / ') + ')') -Focused ($fields[$focus] -eq 'Encrypt') `
                       -Note $(if ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') { 'Strict is TDS 8, for SQL Server 2022 and later' } else { 'the login packet is always encrypted whatever this says' })
        Write-MhTuiField -Label 'Trust server certificate' -Value $Settings.TrustCert -Focused ($fields[$focus] -eq 'TrustCert') `
                       -Note 'needed for a self-signed certificate, which is most on-premises instances'
        Write-MhTuiField -Label 'Host name in certificate' -Value $Settings.HostNameInCert -Focused ($fields[$focus] -eq 'HostNameInCert') `
                       -Enabled ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') -Note 'when the name you connect by is not the name on the certificate'
        Write-MhTuiField -Label 'Connect timeout (s)' -Value $Settings.TimeoutSeconds -Focused ($fields[$focus] -eq 'TimeoutSeconds')
        Write-MhTuiField -Label 'Application name' -Value $Settings.ApplicationName -Focused ($fields[$focus] -eq 'ApplicationName') `
                       -Note 'what the DBA sees in sys.dm_exec_sessions'
        Write-MhTuiField -Label 'Read-only intent' -Value $Settings.ReadOnlyIntent -Focused ($fields[$focus] -eq 'ReadOnlyIntent') `
                       -Note 'routes to a readable secondary in an availability group'
        Write-MhTuiField -Label 'Multi-subnet failover' -Value $Settings.MultiSubnet -Focused ($fields[$focus] -eq 'MultiSubnet')
        Write-MhTuiKeys 'Up/Down field   Left/Right or Space change   type to edit text   F5 or Esc back'

        $key = Read-MhTuiKey
        if ($key.Name -in 'Escape', 'Enter', 'F5') { return }
        $handled = $true
        switch ($key.Name) {
            'UpArrow'   { $focus = [math]::Max(0, $focus - 1) }
            'DownArrow' { $focus = [math]::Min($fields.Count - 1, $focus + 1) }
            'Backspace' {
                switch ($fields[$focus]) {
                    'HostNameInCert'  { $Settings.HostNameInCert = Remove-MhTuiChar $Settings.HostNameInCert }
                    'ApplicationName' { $Settings.ApplicationName = Remove-MhTuiChar $Settings.ApplicationName }
                    'TimeoutSeconds'  { $Settings.TimeoutSeconds = [int]((Remove-MhTuiChar ([string]$Settings.TimeoutSeconds)) + '0') }
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
                'HostNameInCert'  { if ($Settings.Namespace -eq 'Microsoft.Data.SqlClient') { $Settings.HostNameInCert = Add-MhTuiChar $Settings.HostNameInCert $key.Char } }
                'ApplicationName' { $Settings.ApplicationName = Add-MhTuiChar $Settings.ApplicationName $key.Char }
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
function Open-MhSqlConnection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $ConnectionString)

    $connection = New-Object "$($Settings.Namespace).SqlConnection" $ConnectionString
    if ($Settings.AuthId -eq 'Token') { $connection.AccessToken = $Settings.Token.Trim() }
    $connection.Open()
    $connection
}
function Invoke-MhSqlQuery {
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
function Get-MhSqlServerInfo {
    param([Parameter(Mandatory)] [System.Data.Common.DbConnection] $Connection)

    $table = Invoke-MhSqlQuery -Connection $Connection -Query @'
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
function Get-MhSqlDatabaseList {
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
    (Invoke-MhSqlQuery -Connection $Connection -Query $query).Rows | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_['Name']; State = [string]$_['State'] }
    }
}
function Get-MhSqlConnectExplanation {
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
function Show-MhSqlConnectDialog {
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
            Clear-MhTuiScreen
            Write-MhTuiTitle 'Connecting'
            Write-MhTui ''
            Write-MhTui ("  {0} as {1}, via {2}" -f $Settings.Server, $method.Name, $Settings.Namespace)
            $connection = Open-MhSqlConnection -Settings $Settings -ConnectionString $connectionString
            $info = Get-MhSqlServerInfo -Connection $connection
            Write-MhTui ''
            Write-MhTui ("  Connected to {0}" -f $info.ServerName) Green
            Write-MhTui ("  {0} {1} ({2})" -f $info.Platform, $info.Version, $info.Edition)
            Write-MhTui ("  signed in as {0}, database [{1}]" -f $info.LoggedInAs, $info.CurrentDatabase)
            return [pscustomobject]@{
                ConnectionString = $connectionString; Settings = $Settings
                Namespace = $Settings.Namespace; AuthMethod = $method.Name
                AccessToken = $Settings.Token; Database = $info.CurrentDatabase; ServerInfo = $info
            }
        }
        catch {
            $message = $_.Exception.GetBaseException().Message
            Write-MhTui ''
            Write-MhTui ("  Could not connect: {0}" -f (($message -split "`r?`n")[0])) Red
            $explain = Get-MhSqlConnectExplanation -Message $message -Settings $Settings
            if ($explain) { Write-MhTui "  $explain" Yellow }
            Write-MhTui ''
            Write-MhTuiKeys 'any key to go back to the connect screen, Esc to give up'
            if ((Read-MhTuiKey).Name -eq 'Escape') { return $null }
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
Register-MhSelfTest -Name 'The connect screen and the pickers' -Test {
    function Settings([hashtable] $Change) {
        $s = New-MhSqlConnectSettings
        foreach ($key in $Change.Keys) { $s.$key = $Change[$key] }
        $s
    }


    Test-MhSection 'the keyboard'
    Test-MhCheck 'a named key' ((ConvertTo-MhTuiKeys @('Down'))[0].Name -eq 'DownArrow')
    Test-MhCheck 'however it is spelled' ((ConvertTo-MhTuiKeys @('DOWN'))[0].Name -eq 'DownArrow')
    Test-MhCheck 'enter' ((ConvertTo-MhTuiKeys @('Enter'))[0].Name -eq 'Enter')
    Test-MhCheck 'escape' ((ConvertTo-MhTuiKeys @('Esc'))[0].Name -eq 'Escape')
    Test-MhCheck 'space carries its character' (
        ((ConvertTo-MhTuiKeys @('Space'))[0].Name -eq 'Spacebar') -and ((ConvertTo-MhTuiKeys @('Space'))[0].Char -eq ' '))
    Test-MhCheck 'typed text becomes one key per character' ((ConvertTo-MhTuiKeys @('text:Sales')).Count -eq 5)
    Test-MhCheck 'and keeps the characters' ((-join (ConvertTo-MhTuiKeys @('text:Sales')).Char) -eq 'Sales')
    Test-MhCheck 'a single character is itself' ((ConvertTo-MhTuiKeys @('x'))[0].Char -eq 'x')
    Test-MhCheck 'a list is taken in order' ((-join (ConvertTo-MhTuiKeys @('text:ab', 'Enter', 'c')).Name) -match 'CharacterCharacterEnterCharacter')
    Test-MhCheck 'nothing is nothing' ((ConvertTo-MhTuiKeys @()).Count -eq 0)
    $threw = $false
    try { [void](ConvertTo-MhTuiKeys @('Wingding')) } catch { $threw = $true }
    Test-MhCheck 'a key it does not know is refused, not guessed at' $threw
    Test-MhCheck 'the function keys the screens use' (
        (-join (ConvertTo-MhTuiKeys @('F2', 'F3', 'F4', 'F5', 'F6', 'F7')).Name) -eq 'F2F3F4F5F6F7')
    Test-MhCheck 'and a letter is still just a letter' ((ConvertTo-MhTuiKeys @('D'))[0].Name -eq 'Character')

    Test-MhSection 'editing a field'
    Test-MhCheck 'a character is added' ((Add-MhTuiChar 'SQL' 'A') -eq 'SQLA')
    Test-MhCheck 'a control character is not' ((Add-MhTuiChar 'SQL' ([char]9)) -eq 'SQL')
    Test-MhCheck 'backspace removes one' ((Remove-MhTuiChar 'SQL') -eq 'SQ')
    Test-MhCheck 'and stops at empty' ((Remove-MhTuiChar '') -eq '')

    Test-MhSection 'the connection string it builds'
    $windows = New-MhSqlConnectionString -Settings (Settings @{ Server = 'SQL01'; Database = 'Sales'; AuthId = 'Windows' })
    Test-MhCheck 'Windows authentication is integrated security' ($windows -match 'Integrated Security=True')
    Test-MhCheck 'with the server' ($windows -match 'Data Source=SQL01')
    Test-MhCheck 'and the database' ($windows -match 'Initial Catalog=Sales')
    Test-MhCheck 'and no user name' ($windows -notmatch 'User ID')
    $sql = New-MhSqlConnectionString -Settings (Settings @{ Server = 'SQL01'; AuthId = 'Sql'; User = 'sa'; Password = 'p@ss;word' })
    Test-MhCheck 'a SQL login carries its user' ($sql -match 'User ID=sa')
    Test-MhCheck 'and its password, quoted because of the semicolon' ($sql -match 'Password="p@ss;word"')
    Test-MhCheck 'and is not integrated security' ($sql -notmatch 'Integrated Security=True')
    $token = New-MhSqlConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = 'Token' })
    Test-MhCheck 'an access token puts nothing in the string' (($token -notmatch 'Authentication') -and ($token -notmatch 'User ID') -and ($token -notmatch 'Password'))
    $named = New-MhSqlConnectionString -Settings (Settings @{ Server = 'SQL01'; ApplicationName = 'Molehill TUI'; TimeoutSeconds = 45 })
    Test-MhCheck 'the application name goes in' ($named -match 'Application Name="?Molehill TUI"?')
    Test-MhCheck 'and the timeout' ($named -match 'Connect Timeout=45')
    $plain = New-MhSqlConnectionString -Settings (Settings @{ Server = 'SQL01'; Encrypt = 'No'; TrustCert = $false })
    Test-MhCheck 'encryption can be turned off on this driver' ($plain -match 'Encrypt=False')
    Test-MhCheck 'and trust with it' ($plain -match 'TrustServerCertificate=False')

    Test-MhSection 'the Entra methods, where the driver has them'
    $available = Get-MhSqlAuthAvailability -Namespace 'System.Data.SqlClient'
    Test-MhCheck 'every method gets an answer' ($available.Count -eq $script:AuthMethods.Count)
    Test-MhCheck 'Windows is always there' ($available['Windows'])
    Test-MhCheck 'so is SQL' ($available['Sql'])
    Test-MhCheck 'and an access token' ($available['Token'])
    foreach ($id in 'EntraMfa', 'EntraPassword', 'EntraIntegrated') {
        $method = Get-SqlAuthMethod $id
        if ($available[$id]) {
            $built = New-MhSqlConnectionString -Settings (Settings @{ Server = 'x.database.windows.net'; AuthId = $id; User = 'me@contoso.com'; Password = 'pw' })
            Test-MhCheck "$($method.Name) names its keyword" ($built -match [regex]::Escape($method.Keyword))
        }
        else { Test-MhSkip "$($method.Name)" 'not on System.Data.SqlClient in this PowerShell' }
    }
    $mdsNamespace = Get-MhSqlClientNamespace -Microsoft
    if ($mdsNamespace) {
        $mdsAvailable = Get-MhSqlAuthAvailability -Namespace $mdsNamespace
        foreach ($id in 'EntraServicePrincipal', 'EntraManagedIdentity', 'EntraDeviceCode', 'EntraDefault') {
            $method = Get-SqlAuthMethod $id
            if (-not $mdsAvailable[$id]) { Test-MhSkip "$($method.Name) on Microsoft.Data.SqlClient" 'this build does not have it'; continue }
            $built = New-MhSqlConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'x.database.windows.net'; AuthId = $id; User = 'appid'; Password = 'secret'; Encrypt = 'Mandatory' })
            Test-MhCheck "$($method.Name) builds on Microsoft.Data.SqlClient" ($built -match 'Authentication=')
        }
        $strict = New-MhSqlConnectionString -Settings (Settings @{ Namespace = $mdsNamespace; Server = 'SQL01'; Encrypt = 'Strict'; HostNameInCert = 'sql01.contoso.com' })
        Test-MhCheck 'Encrypt = Strict is accepted there' ($strict -match 'Encrypt=Strict')
        Test-MhCheck 'and a host name in the certificate' ($strict -match 'Host Name In Certificate=sql01\.contoso\.com')
    }
    else { Test-MhSkip 'Microsoft.Data.SqlClient' 'the SqlServer module is not available in this PowerShell' }

    Test-MhSection 'keeping the password off the screen'
    Test-MhCheck 'a password is masked' ((Hide-MhSqlSecret 'Data Source=x;Password=hunter2;Encrypt=True') -eq 'Data Source=x;Password=********;Encrypt=True')
    Test-MhCheck 'a quoted one too' ((Hide-MhSqlSecret 'Password="p;w";Encrypt=True') -eq 'Password=********;Encrypt=True')
    Test-MhCheck 'however it is spelled' ((Hide-MhSqlSecret 'password=abc') -eq 'password=********')
    Test-MhCheck 'and nothing else is touched' ((Hide-MhSqlSecret 'Data Source=x;User ID=sa') -eq 'Data Source=x;User ID=sa')

    Test-MhSection 'what it insists on before connecting'
    Test-MhCheck 'a server name' ((Test-MhSqlConnectSettings -Settings (Settings @{ })) -contains 'a server name')
    Test-MhCheck 'a user for SQL authentication' ((Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql' })) -contains 'a user name')
    Test-MhCheck 'and a password' ((Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Sql'; User = 'sa' })) -contains 'a password')
    Test-MhCheck 'the application id for a service principal' (
        (Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraServicePrincipal' })) -contains 'the application id, in the user box')
    Test-MhCheck 'a token when that is the method' ((Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'Token' })) -contains 'an access token')
    Test-MhCheck 'Windows authentication needs nothing else' ((Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x' })).Count -eq 0)
    Test-MhCheck 'and Entra integrated needs nothing else' ((Test-MhSqlConnectSettings -Settings (Settings @{ Server = 'x'; AuthId = 'EntraIntegrated' })).Count -eq 0)

    Test-MhSection 'the three ways to pick things off a list'
    Test-MhCheck 'all means all' ((Get-MhTuiSelectionSummary -Mode All -Total 10 -Ticked 0).Count -eq 10)
    Test-MhCheck 'and says so, in the caller words' ((Get-MhTuiSelectionSummary -Mode All -Total 10 -Ticked 3 -ItemNoun 'table' -Action 'exported').Text -match 'all 10 tables will be exported')
    Test-MhCheck 'include takes what is ticked' ((Get-MhTuiSelectionSummary -Mode Include -Total 10 -Ticked 3).Count -eq 3)
    Test-MhCheck 'exclude takes the rest' ((Get-MhTuiSelectionSummary -Mode Exclude -Total 10 -Ticked 3).Count -eq 7)
    Test-MhCheck 'excluding everything leaves nothing' ((Get-MhTuiSelectionSummary -Mode Exclude -Total 10 -Ticked 10).Count -eq 0)
    Test-MhCheck 'including nothing leaves nothing' ((Get-MhTuiSelectionSummary -Mode Include -Total 10 -Ticked 0).Count -eq 0)
    Test-MhCheck 'one of a kind is not pluralised' ((Get-MhTuiSelectionSummary -Mode All -Total 1 -ItemNoun 'database').Text -match 'all 1 database will be')

    $sample = @(
        [pscustomobject]@{ Schema = 'dbo'; Table = 'Orders'; Rows = 100 }
        [pscustomobject]@{ Schema = 'dbo'; Table = 'CustomerAudit'; Rows = 5 }
        [pscustomobject]@{ Schema = 'staging'; Table = 'Load'; Rows = 2 }
    )
    $rows = @(New-TuiRows -Items $sample -Label { "$($_.Schema).$($_.Table)" } -Detail { '{0} rows' -f $_.Rows })
    Test-MhCheck 'a row is labelled by the caller block' ($rows[0].Text -eq 'dbo.Orders')
    Test-MhCheck 'and detailed by it too' ($rows[0].Detail -eq '100 rows')
    Test-MhCheck 'the caller object comes back as it was given' ($rows[0].Item.Table -eq 'Orders')
    Test-MhCheck 'and the picker does not write a Ticked property onto it' ($null -eq $sample[0].PSObject.Properties['Ticked'])
    Test-MhCheck 'nothing is ticked to start with' (@($rows | Where-Object { $_.Ticked }).Count -eq 0)
    Test-MhCheck 'no filter shows everything' (@(Select-TuiRows -Rows $rows -Filter '').Count -eq 3)
    Test-MhCheck 'a filter narrows it' (@(Select-TuiRows -Rows $rows -Filter 'audit').Count -eq 1)
    Test-MhCheck 'and matches the whole label, schema included' (@(Select-TuiRows -Rows $rows -Filter 'staging').Count -eq 1)
    Test-MhCheck 'and nothing is nothing' (@(Select-TuiRows -Rows $rows -Filter 'zzz').Count -eq 0)
    Test-MhCheck 'wrapped in @() a single row counts as one, which is the convention here' (
        @(Select-TuiRows -Rows $rows -Filter 'CustomerAudit').Count -eq 1)
    Test-MhCheck 'two rows in, two rows out' (@(New-TuiRows -Items $sample).Count -eq 3)
    Test-MhCheck 'one row in, one row out rather than one row holding three' (@(New-TuiRows -Items @($sample[0])).Count -eq 1)
    Test-MhCheck 'an empty list makes no rows' (@(New-TuiRows -Items @()).Count -eq 0)
    Test-MhCheck 'and a list with no label block falls back to the object itself' ((@(New-TuiRows -Items @('SQL01')))[0].Text -eq 'SQL01')

    Test-MhSection 'explaining a failure to connect'
    $s = New-MhSqlConnectSettings
    Test-MhCheck 'a refused login is not blamed on the network' ((Get-MhSqlConnectExplanation -Message "Login failed for user 'sa'." -Settings $s) -match 'refused')
    Test-MhCheck 'a handshake failure mentions the certificate switch' (
        (Get-MhSqlConnectExplanation -Message 'A connection was successfully established ... pre-login handshake' -Settings (Settings @{ TrustCert = $false })) -match 'Trust server certificate')
    Test-MhCheck 'and sends you to the TLS tool' ((Get-MhSqlConnectExplanation -Message 'pre-login handshake' -Settings $s) -match 'Test-SqlTlsHandshake')
    Test-MhCheck 'a timeout blames the firewall, not the password' ((Get-MhSqlConnectExplanation -Message 'Connection Timeout Expired' -Settings $s) -match 'firewall')
    Test-MhCheck 'a name that does not resolve is explained' ((Get-MhSqlConnectExplanation -Message 'The network path was not found.' -Settings $s) -match 'did not resolve')
    Test-MhCheck 'and a named instance is pointed at SQL Browser' ((Get-MhSqlConnectExplanation -Message 'error: 26 - Error Locating Server/Instance Specified, server was not found' -Settings $s) -match 'SQL Browser')
    Test-MhCheck 'an SSPI failure is not called a bad password' ((Get-MhSqlConnectExplanation -Message 'The target principal name is incorrect. Cannot generate SSPI context.' -Settings $s) -match 'Kerberos')
    Test-MhCheck 'an unknown error explains nothing rather than guessing' ((Get-MhSqlConnectExplanation -Message 'Something odd' -Settings $s) -eq '')

}
