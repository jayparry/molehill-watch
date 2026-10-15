<#
    MolehillTools

    Everything in Private\ and Public\ is dot-sourced; the manifest decides what leaves. Keeping
    the export list in the manifest rather than in here means Get-Command on the module and the
    manifest can never disagree.

        Import-Module .\MolehillTools\MolehillTools.psd1

    The scripts in Tools\ are thin shims over this: they exist so that a single file can still be
    copied to a server, which is how this estate works.
#>

$ErrorActionPreference = 'Stop'

# the test harness goes first, because every other file calls Register-MhSelfTest as it loads.
# Alphabetical order used to be enough by luck; the first file to sort before SelfTest.ps1 - and
# register checks about the module itself - broke the import outright.
$harness = Join-Path $PSScriptRoot 'Private\SelfTest.ps1'
if (Test-Path -LiteralPath $harness) { . $harness }

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $path -Filter '*.ps1' -Recurse | Sort-Object FullName)) {
        if ($file.FullName -ne $harness) { . $file.FullName }
    }
}
