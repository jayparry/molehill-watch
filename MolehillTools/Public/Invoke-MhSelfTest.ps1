<#
.SYNOPSIS
    Runs the module's own checks, and the checks built into each tool script, without needing a
    SQL Server anywhere.

.DESCRIPTION
    Every tool in this package carries its own -SelfTest: a few dozen checks over the decisions it
    makes, run with no server and no modules. This runs them, and the module's own, in one go, so
    there is one command to type after a change rather than ten.

    What it checks is the reasoning, not the plumbing: the statements a tool builds, how it reads
    an error, which authentication a driver will accept, what a screen does with a keystroke. A
    tool's own tests live with the tool, because they are part of it.

    Each tool is run in the same session and its output captured, so what you see here is one line
    per tool and the detail of anything that failed. -Detailed shows every check as it runs. The
    exit code the tool gives is what decides pass or fail: counting PASS lines would only tell you
    what it managed to print before it fell over.

    The tool scripts are found beside the module, in ..\Tools. Where they are somewhere else, say
    so with -ToolPath.

.PARAMETER Name
    Only the things whose name matches this - a wildcard is fine, so 'Copy*' or '*Sample*'. It is
    matched against the registered check names as well as the tool file names.

.PARAMETER ToolPath
    Where the tool scripts are. Default: the Tools folder beside the module.

.PARAMETER ModuleOnly
    Just the module's own checks, skipping the tool scripts.

.PARAMETER Detailed
    Show every check from every tool, not just the failures.

.NOTES
    Result is PASS for a set of checks that passed, FAIL for one that did not, and SHIM for a
    tool file that ran and handed over to the module's checks - counted once, under the module.

.OUTPUTS
    One object per thing tested, with Name, Passed, Failed, Skipped, ExitCode and Result.

.EXAMPLE
    Invoke-MhSelfTest

.EXAMPLE
    Invoke-MhSelfTest -Name '*Access*' -Detailed

.EXAMPLE
    # for a build step: nothing failed if this is zero
    @(Invoke-MhSelfTest | Where-Object { $_.Result -eq 'FAIL' }).Count
#>
function Invoke-MhSelfTest {
    [CmdletBinding()]
    param(
        [string] $Name = '*',
        [string] $ToolPath,
        [switch] $ModuleOnly,
        [switch] $Detailed
    )

    $results = New-Object System.Collections.Generic.List[object]

    Write-Host ''
    Write-Host 'MolehillTools self test' -ForegroundColor Cyan

    # whatever has registered itself: each tool adds its own checks as it loads, so this list
    # grows with the module rather than being kept somewhere else and going stale
    foreach ($registered in $script:SelfTests) {
        if ($registered.Name -notlike $Name -and $Name -ne '*') { continue }
        Write-Host "  $($registered.Name)" -ForegroundColor Gray
        $outcome = Invoke-MhRegisteredTest -Registered $registered
        Write-Host ("    {0} passed, {1} failed, {2} skipped" -f $outcome.Passed, $outcome.Failed, $outcome.Skipped) `
            -ForegroundColor $(if ($outcome.Failed) { 'Red' } else { 'Green' })
        $results.Add([pscustomobject]@{
            Name = $registered.Name; Passed = $outcome.Passed; Failed = $outcome.Failed
            Skipped = $outcome.Skipped; ExitCode = $(if ($outcome.Failed) { 1 } else { 0 })
            Result = $(if ($outcome.Failed -eq 0) { 'PASS' } else { 'FAIL' })
        })
    }

    if (-not $ModuleOnly) {
        if (-not $ToolPath) { $ToolPath = Join-Path (Split-Path $PSScriptRoot -Parent) '..\Tools' }
        $ToolPath = [System.IO.Path]::GetFullPath($ToolPath)
        if (-not (Test-Path -LiteralPath $ToolPath)) {
            Write-Host "  No Tools folder at $ToolPath, so only the module was checked." -ForegroundColor Yellow
        }
        else {
            foreach ($script in (Get-ChildItem -LiteralPath $ToolPath -Filter '*.ps1' | Sort-Object Name)) {
                if ($script.BaseName -notlike $Name) { continue }

                # a tool is testable when it has a -SelfTest to offer; the rest are passed over
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$null)
                $hasSelfTest = $false
                if ($ast.ParamBlock) {
                    foreach ($parameter in $ast.ParamBlock.Parameters) {
                        if ($parameter.Name.VariablePath.UserPath -eq 'SelfTest') { $hasSelfTest = $true }
                    }
                }
                if (-not $hasSelfTest) { continue }

                # a tool that asks for a newer PowerShell than this one cannot be run here, and
                # PowerShell refuses it on the #Requires line before the script starts. That is the
                # #Requires line working, not a failing tool, so it is said and passed over rather
                # than counted as a failure of a run on 5.1.
                $needs = $ast.ScriptRequirements
                if ($needs -and $needs.RequiredPSVersion -and $needs.RequiredPSVersion -gt $PSVersionTable.PSVersion) {
                    Write-Host "  $($script.Name)" -ForegroundColor Gray
                    Write-Host ("    skipped: it asks for PowerShell {0} and this is {1}" -f
                                $needs.RequiredPSVersion, $PSVersionTable.PSVersion) -ForegroundColor Yellow
                    $results.Add([pscustomobject]@{
                        Name = $script.Name; Passed = 0; Failed = 0; Skipped = 1
                        ExitCode = 0; Result = 'SKIP'
                    })
                    continue
                }

                Write-Host "  $($script.Name)" -ForegroundColor Gray
                $global:LASTEXITCODE = 0
                # 6>&1 as well as 2>&1: a tool draws with Write-Host, which goes to the information
                # stream, and without it the output is not captured at all - it just prints, and
                # every count here reads zero
                # a tool that throws on the way in - a failed Add-Type, a missing module -
                # is a failure of that tool, not of the run: catch it, record it, carry on
                $broke = ''
                try {
                    if ($Detailed) {
                        & $script.FullName -SelfTest
                        $exitCode = $LASTEXITCODE
                        $lines = @()
                    }
                    else {
                        $lines = @(& $script.FullName -SelfTest 6>&1 2>&1)
                        $exitCode = $LASTEXITCODE
                    }
                }
                catch {
                    $broke = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                    $lines = @()
                    $exitCode = 1
                }

                $failedLines = @($lines | Where-Object { "$_" -match '^\s*FAIL\s' })
                $passed = @($lines | Where-Object { "$_" -match '^\s*PASS\s' }).Count
                $skipped = @($lines | Where-Object { "$_" -match '^\s*SKIP\s' }).Count
                foreach ($line in $failedLines) { Write-Host "    $line" -ForegroundColor Red }

                if ($broke) { Write-Host "    it would not run: $broke" -ForegroundColor Red }
                $ok = ($exitCode -eq 0) -and -not $broke
                if ($ok -and $passed -eq 0 -and $failedLines.Count -eq 0) {
                    # a shim's checks are the module's, counted once above rather than twice
                    Write-Host '    ok (its checks are the module''s)' -ForegroundColor Green
                }
                else {
                    Write-Host ("    {0} passed, {1} failed, {2} skipped (exit {3})" -f $passed, $failedLines.Count, $skipped, $exitCode) `
                        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
                }
                if (-not $ok -and $failedLines.Count -eq 0) {
                    # it did not get as far as failing a check, which is worth seeing in full
                    foreach ($line in ($lines | Select-Object -Last 6)) { Write-Host "    $line" -ForegroundColor DarkYellow }
                }

                # SHIM, not PASS: it ran and handed over to the module's checks, which were
                # counted once already. A row reading "0 passed, PASS" says the opposite.
                $delegated = $ok -and $passed -eq 0 -and $failedLines.Count -eq 0
                $results.Add([pscustomobject]@{
                    Name = $script.Name; Passed = $passed; Failed = $failedLines.Count
                    Skipped = $skipped; ExitCode = $exitCode
                    Result = $(if (-not $ok) { 'FAIL' } elseif ($delegated) { 'SHIM' } else { 'PASS' })
                })
            }
        }
    }

    $bad = @($results | Where-Object { $_.Result -eq 'FAIL' })
    $shims = @($results | Where-Object { $_.Result -eq 'SHIM' })
    $sets = @($results | Where-Object { $_.Result -eq 'PASS' })
    $unrunnable = @($results | Where-Object { $_.Result -eq 'SKIP' })
    Write-Host ''
    if ($bad.Count -eq 0) {
        $summary = 'All {0} checks in {1} set(s) passed' -f ($sets | Measure-Object Passed -Sum).Sum, $sets.Count
        if ($shims.Count) { $summary += ', and {0} shim(s) ran and handed over' -f $shims.Count }
        $summary += '.'
        # said rather than left out: "all passed" while quietly not running one of them is the
        # sort of green that hides a tool nobody has checked since the day it was written
        if ($unrunnable.Count) {
            $summary += ' {0} needed a newer PowerShell than this one: {1}.' -f
                        $unrunnable.Count, (($unrunnable | ForEach-Object Name) -join ', ')
        }
        Write-Host $summary -ForegroundColor $(if ($unrunnable.Count) { 'Yellow' } else { 'Green' })
    }
    else {
        Write-Host ("{0} of {1} failed: {2}" -f $bad.Count, $results.Count, (($bad | ForEach-Object Name) -join ', ')) -ForegroundColor Red
    }
    Write-Host ''

    $results.ToArray()
}
