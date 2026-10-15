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
            $names = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
        }
        else {
            # only the top level: a $script: assignment inside a function runs when the function
            # is called, so it cannot clash at load time the way these can
            foreach ($statement in $ast.EndBlock.Statements) {
                if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $statement.Left.Extent.Text -like '$script:*') {
                    $names += $statement.Left.Extent.Text.Substring(8)
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
    $forced = @()
    $shims = 0
    foreach ($tool in $tools) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tool.FullName, [ref]$null, [ref]$errors)
        if ($errors) { $broken += "$($tool.Name): $($errors[0].Message)"; continue }

        $text = Get-Content -Raw -LiteralPath $tool.FullName
        if ($text -notmatch 'MolehillTools\.psd1') { continue }
        $shims++
        if ($text -match 'Import-Module[^\r\n]*-Force') { $forced += $tool.Name }
    }

    Test-MhCheck 'every script in Tools parses' (-not $broken.Count) ($broken -join '; ')
    Test-MhCheck 'at least one of them is a shim over this module' ($shims -gt 0) "$shims found"
    Test-MhCheck 'no shim re-imports the module with -Force' (-not $forced.Count) ($forced -join ', ')
}
