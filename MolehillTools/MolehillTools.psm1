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

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $path -Filter '*.ps1' -Recurse | Sort-Object FullName)) {
        . $file.FullName
    }
}
