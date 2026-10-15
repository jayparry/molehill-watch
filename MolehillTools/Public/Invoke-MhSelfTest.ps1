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
    Only the tools whose file name matches this - a wildcard is fine, so 'Copy*' or '*Sample*'.
    The module's own checks always run.

.PARAMETER ToolPath
    Where the tool scripts are. Default: the Tools folder beside the module.

.PARAMETER ModuleOnly
    Just the module's own checks, skipping the tool scripts.

.PARAMETER Detailed
    Show every check from every tool, not just the failures.

.OUTPUTS
    One object per thing tested, with Name, Passed, Failed, Skipped, ExitCode and Result.

.EXAMPLE
    Invoke-MhSelfTest

.EXAMPLE
    Invoke-MhSelfTest -Name '*Access*' -Detailed

.EXAMPLE
    # for a build step: nothing failed if this is zero
    @(Invoke-MhSelfTest | Where-Object { $_.Result -ne 'PASS' }).Count
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

    # the module's own, which print as they go because they are this module's detail
    Write-Host '  MolehillTools (the connect screen and the pickers)' -ForegroundColor Gray
    $connect = $null
    if ($Detailed) { $connect = Test-ConnectLayer }
    else {
        $captured = Test-ConnectLayer 6>&1
        $connect = @($captured | Where-Object { $_ -is [pscustomobject] })[-1]
        foreach ($line in ($captured | Where-Object { $_ -is [string] -and $_ -match '^\s*FAIL\s' })) {
            Write-Host "    $line" -ForegroundColor Red
        }
    }
    Write-Host ("    {0} failed, {1} skipped" -f $connect.Failed, $connect.Skipped) `
        -ForegroundColor $(if ($connect.Failed) { 'Red' } else { 'Green' })
    $results.Add([pscustomobject]@{
        Name = 'MolehillTools'; Passed = $null; Failed = $connect.Failed
        Skipped = $connect.Skipped; ExitCode = $(if ($connect.Failed) { 1 } else { 0 })
        Result = $(if ($connect.Failed -eq 0) { 'PASS' } else { 'FAIL' })
    })

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

                $results.Add([pscustomobject]@{
                    Name = $script.Name; Passed = $passed; Failed = $failedLines.Count
                    Skipped = $skipped; ExitCode = $exitCode
                    Result = $(if ($ok) { 'PASS' } else { 'FAIL' })
                })
            }
        }
    }

    $bad = @($results | Where-Object { $_.Result -ne 'PASS' })
    Write-Host ''
    if ($bad.Count -eq 0) {
        Write-Host ("All {0} checked, all passed." -f $results.Count) -ForegroundColor Green
    }
    else {
        Write-Host ("{0} of {1} failed: {2}" -f $bad.Count, $results.Count, (($bad | ForEach-Object Name) -join ', ')) -ForegroundColor Red
    }
    Write-Host ''

    $results.ToArray()
}
