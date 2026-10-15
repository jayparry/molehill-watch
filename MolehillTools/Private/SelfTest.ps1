<#
    The test harness the whole module shares.

    Every tool in here registers its own checks as it loads, so the checks travel with the tool
    rather than living in one growing file a long way from the code they are about.
    Invoke-MhSelfTest runs whatever has registered itself.

    The counters are module scope on purpose: a nested function assigning to an unqualified
    $failed makes its own copy and counts nothing, which is a mistake this module has already made
    once.
#>

$script:SelfTests = New-Object System.Collections.Generic.List[object]
$script:CheckFailed = 0
$script:CheckSkipped = 0
$script:CheckPassed = 0

<#
  Adds a set of checks to the list Invoke-MhSelfTest runs. Called at load time, from the bottom of
  whichever file holds the thing being checked.
#>
function Register-MhSelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Test
    )
    $script:SelfTests.Add([pscustomobject]@{ Name = $Name; Test = $Test })
}

function Test-MhSection {
    param([Parameter(Mandatory)] [string] $Name)
    Write-Host "    $Name" -ForegroundColor Gray
}

function Test-MhCheck {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [bool] $Ok,
        [AllowEmptyString()] [string] $Detail = ''
    )
    if ($Ok) {
        Write-Host "      PASS  $Name" -ForegroundColor Green
        $script:CheckPassed++
    }
    else {
        Write-Host "      FAIL  $Name $Detail" -ForegroundColor Red
        $script:CheckFailed++
    }
}

function Test-MhSkip {
    param([Parameter(Mandatory)] [string] $Name, [AllowEmptyString()] [string] $Why = '')
    Write-Host ("      SKIP  {0}{1}" -f $Name, $(if ($Why) { " ($Why)" } else { '' })) -ForegroundColor DarkGray
    $script:CheckSkipped++
}

# runs one registered set and says how it went
function Invoke-MhRegisteredTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Registered)

    $script:CheckFailed = 0
    $script:CheckSkipped = 0
    $script:CheckPassed = 0
    $broke = ''
    try { & $Registered.Test }
    catch { $broke = ($_.Exception.GetBaseException().Message -split "`r?`n")[0] }

    if ($broke) { Write-Host "      the checks themselves fell over: $broke" -ForegroundColor Red }
    [pscustomobject]@{
        Name    = $Registered.Name
        Passed  = $script:CheckPassed
        Failed  = $script:CheckFailed + $(if ($broke) { 1 } else { 0 })
        Skipped = $script:CheckSkipped
        Broke   = $broke
    }
}
