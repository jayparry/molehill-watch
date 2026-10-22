<#
    Checks about the module itself rather than about any one tool.

    Every tool in here began as a standalone script where it had a file to itself, so names that
    were perfectly safe there - $script:AuthMethods, Invoke-Sql, Write-Status - now share one
    scope with every other tool. Two tools claiming the same name is silent: the file that loads
    last wins, and the first one carries on calling what it thinks is its own.

    That is not hypothetical. The connection tester arrived with its own $script:AuthMethods and
    replaced the connect screen's list of authentication methods, which only showed up as three
    puzzling failures in a set of checks that had nothing to do with it.

    The exits are the other one. In a script, exit ends the script; in a module function it ends
    the session that called it. Three ports came over with exit statements still in them, one of
    them in the middle of writing an HTML report.
#>

function Get-MhModuleFile {
    $root = Split-Path -Parent $PSScriptRoot
    Get-ChildItem -LiteralPath (Join-Path $root 'Private'), (Join-Path $root 'Public') -Filter *.ps1 -ErrorAction SilentlyContinue |
        Sort-Object FullName
}

function Get-MhFileAst([string] $Path) {
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
}

<#
  Which file claims which name, as @{ name = @(file, file) }, for the two kinds of name that can
  collide across the module: functions, and module-scope variables assigned at the top level.
#>
function Get-MhNameClaim([string] $Kind) {
    $claims = @{}
    foreach ($file in Get-MhModuleFile) {
        $ast = Get-MhFileAst $file.FullName
        $names = @()
        if ($Kind -eq 'function') {
            # top level only: a function defined inside another one lives and dies with its
            # parent, so it is not sharing the module's scope and cannot clash in it
            $names = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false).Name
        }
        else {
            # anywhere in the file, not just the top level: a $script: assignment inside a
            # function still writes a variable that belongs to the whole module, so two files
            # assigning the same name are sharing it whether they meant to or not. Two restore
            # tools each wrote $script:Blobs from inside their own functions, which this missed
            # while it only looked at the top level.
            foreach ($assignment in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $left = $assignment.Left
                if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $left.VariablePath.DriveName -eq 'script') {
                    $names += $left.VariablePath.UserPath.Substring('script:'.Length)
                }
            }
        }
        foreach ($name in $names) {
            if (-not $claims.ContainsKey($name)) { $claims[$name] = @() }
            $claims[$name] += $file.Name
        }
    }
    return $claims
}

Register-MhSelfTest -Name 'The module itself' -Test {
    $files = @(Get-MhModuleFile)
    Test-MhSection "$($files.Count) files"

    Test-MhCheck 'there are files to check' ($files.Count -gt 0)
    # the module's own files are not parse-checked here: one that does not parse fails the import,
    # so these checks would never get the chance to run and say so

    Test-MhSection 'names that only one file may claim'

    foreach ($kind in 'function', 'variable') {
        $shared = @()
        foreach ($entry in (Get-MhNameClaim $kind).GetEnumerator()) {
            $where = @($entry.Value | Select-Object -Unique)
            if ($where.Count -gt 1) { $shared += "$($entry.Key) in $($where -join ' and ')" }
        }
        Test-MhCheck "no $kind name is claimed by two files" (-not $shared.Count) ($shared -join '; ')
    }

    Test-MhSection 'nothing that would end the session'

    $exits = @()
    foreach ($file in $files) {
        $found = (Get-MhFileAst $file.FullName).FindAll({ $args[0] -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
        foreach ($one in $found) { $exits += "$($file.Name):$($one.Extent.StartLineNumber) $($one.Extent.Text)" }
    }
    Test-MhCheck 'no module file calls exit' (-not $exits.Count) ($exits -join '; ')

    Test-MhSection 'commands that are not there'

    <#
      Anything the module calls has to exist: one of its own functions, something PowerShell
      provides, or a command from a module that is expected to be absent on a locked-down server.
      That last group is listed by name rather than guessed at, because "it is probably external"
      is exactly how a typo gets through.
    #>
    $expectedElsewhere = @(
        # Az.Storage and Az.Accounts, which the restore tools install or ask for when they need them
        'Connect-AzAccount', 'Get-AzAccessToken', 'Get-AzStorageBlob', 'Get-AzStorageBlobContent',
        'New-AzStorageContext', 'Get-AzStorageContainer',
        # the SqlServer module
        'Invoke-Sqlcmd',
        # Windows features a server may not have
        'Get-TlsCipherSuite', 'New-SelfSignedCertificate', 'Get-WindowsFeature'
    )

    # every function the module defines, at any depth: a nested one is perfectly callable from
    # its parent, and Get-Command cannot see it because it only exists while the parent runs
    $defined = @{}
    foreach ($file in $files) {
        foreach ($fn in (Get-MhFileAst $file.FullName).FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $defined[$fn.Name] = $true
        }
    }

    $unknown = @()
    foreach ($file in $files) {
        $ast = Get-MhFileAst $file.FullName
        foreach ($call in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $call.GetCommandName()
            # a call through a variable or an expression has no name to check
            if (-not $name -or $name -notmatch '^[A-Za-z][\w]*-[\w]+$') { continue }
            if ($expectedElsewhere -contains $name) { continue }
            if ($defined.ContainsKey($name)) { continue }
            if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
            $unknown += "$($file.Name):$($call.Extent.StartLineNumber) $name"
        }
    }
    Test-MhCheck 'every command the module calls exists' (-not $unknown.Count) (($unknown | Select-Object -Unique) -join '; ')

    Test-MhSection 'the manifest and the files agree'

    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'MolehillTools.psd1')
    $exported = @($manifest.FunctionsToExport)
    Test-MhCheck 'the manifest exports by name rather than *' ($exported -notcontains '*')

    $missing = @($exported | Where-Object { -not (Get-Command $_ -Module MolehillTools -ErrorAction SilentlyContinue) })
    Test-MhCheck 'every exported name exists' (-not $missing.Count) ($missing -join ', ')

    # a public file is named after the function it is there to provide, so a port that never
    # reached the manifest shows up here rather than when someone tries to call it
    $unexported = @()
    foreach ($file in ($files | Where-Object { $_.DirectoryName -like '*Public' })) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($exported -notcontains $name) { $unexported += $name }
    }
    Test-MhCheck 'every public file is exported under its own name' (-not $unexported.Count) ($unexported -join ', ')

    $sorted = @($exported | Sort-Object)
    Test-MhCheck 'the export list is in order, so additions do not land anywhere' (-not (Compare-Object $exported $sorted -SyncWindow 0))

    # the shims in Tools\ are the other half of this: the module never loads them, so nothing else
    # would notice one that stopped parsing or went back to re-importing the module underneath its
    # caller. Scripts that have not been ported yet are left alone.
    $tools = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Tools') -Filter *.ps1 -ErrorAction SilentlyContinue)
    if (-not $tools.Count) {
        Test-MhSkip 'the shims beside the module' 'no Tools folder next to the module'
        return
    }

    Test-MhSection "the $($tools.Count) scripts in Tools"

    $broken = @()
    $tooNew = @()
    $forced = @()
    $shims = 0
    foreach ($tool in $tools) {
        $text = Get-Content -Raw -LiteralPath $tool.FullName

        # a script that asks for a newer PowerShell than the one running is not a broken script: it
        # is one this host cannot read. 5.1 cannot parse a ternary, so a tool written for 7 would be
        # reported as broken on every 5.1 run - which reads as a regression in the tool rather than
        # as the #Requires line doing its job. It is counted as skipped and named, so a genuinely
        # broken script cannot hide behind a #Requires line either.
        $needs = $null
        if ($text -match '(?im)^\s*#Requires\s+-Version\s+(\d+(?:\.\d+)?)') {
            $asked = $Matches[1]
            if ($asked -notmatch '\.') { $asked = "$asked.0" }
            $needs = [version]$asked
        }
        if ($needs -and $needs -gt $PSVersionTable.PSVersion) {
            $tooNew += ('{0} asks for {1}' -f $tool.Name, $needs)
            continue
        }

        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tool.FullName, [ref]$null, [ref]$errors)
        if ($errors) { $broken += "$($tool.Name): $($errors[0].Message)"; continue }

        if ($text -notmatch 'MolehillTools\.psd1') { continue }
        $shims++
        if ($text -match 'Import-Module[^\r\n]*-Force') { $forced += $tool.Name }
    }

    Test-MhCheck ('{0} of the {1} scripts in Tools parse' -f ($tools.Count - $tooNew.Count), $tools.Count) `
        (-not $broken.Count) ($broken -join '; ')
    if ($tooNew.Count) {
        Test-MhSkip 'the rest need a newer PowerShell than this one' ($tooNew -join ', ')
    }
    Test-MhCheck 'at least one of them is a shim over this module' ($shims -gt 0) "$shims found"
    Test-MhCheck 'no shim re-imports the module with -Force' (-not $forced.Count) ($forced -join ', ')

    Test-MhSection 'the shims and the functions agree'

    # a shim is only a shim if it takes the same arguments and means the same thing by them
    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
              @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    # the shims have these of their own: the self test runner, and the trailing arguments that
    # powershell.exe -File hands over as separate strings
    $shimOnlyIsFine = 'SelfTest', 'Remaining'

    $mismatched = @()
    $differentDefaults = @()
    foreach ($tool in $tools) {
        $text = Get-Content -Raw -LiteralPath $tool.FullName
        if ($text -notmatch '([A-Z][\w]+-Mh[\w]+) @arguments') { continue }
        $function = $Matches[1]
        $command = Get-Command $function -ErrorAction SilentlyContinue
        if (-not $command) { $mismatched += "$($tool.Name) calls $function, which does not exist"; continue }

        $shimAst = Get-MhFileAst $tool.FullName
        if (-not $shimAst.ParamBlock) { $mismatched += "$($tool.Name) has no param block"; continue }

        $shimParameters = @{}
        foreach ($p in $shimAst.ParamBlock.Parameters) {
            $shimParameters[$p.Name.VariablePath.UserPath] = $(if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { '' })
        }
        $functionNames = @($command.Parameters.Keys | Where-Object { $common -notcontains $_ })

        foreach ($name in $shimParameters.Keys) {
            if ($shimOnlyIsFine -contains $name) { continue }
            if ($functionNames -notcontains $name) { $mismatched += "$($tool.Name) takes -$name and $function does not" }
        }
        foreach ($name in $functionNames) {
            if (-not $shimParameters.ContainsKey($name)) { $mismatched += "$function takes -$name and $($tool.Name) does not" }
        }

        # defaults, where both sides wrote one down
        $functionAst = (Get-Command $function).ScriptBlock.Ast
        if ($functionAst.Body -and $functionAst.Body.ParamBlock) { $functionAst = $functionAst.Body }
        foreach ($p in $functionAst.ParamBlock.Parameters) {
            $name = $p.Name.VariablePath.UserPath
            if (-not $shimParameters.ContainsKey($name)) { continue }
            $theirs = $(if ($p.DefaultValue) { $p.DefaultValue.Extent.Text } else { '' })
            $ours = $shimParameters[$name]
            if ($ours -and $theirs -and $ours -ne $theirs) {
                $differentDefaults += "$($tool.Name) -$name is $ours, $function is $theirs"
            }
        }
    }

    Test-MhCheck 'every shim takes exactly what its function takes' (-not $mismatched.Count) ($mismatched -join '; ')
    Test-MhCheck 'and means the same thing by each default' (-not $differentDefaults.Count) ($differentDefaults -join '; ')
}
