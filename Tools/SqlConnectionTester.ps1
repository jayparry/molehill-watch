#Requires -Version 5.1

<#
.SYNOPSIS
    SQL Connection Tester - PowerShell edition. A full-screen console app to build, save and test
    SQL Server connection strings, for places where running an .exe is not allowed.

.DESCRIPTION
    Molehill Data Services | SqlConnectionTester

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Invoke-MhSqlConnectionTester). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    Same job as Tools\SqlConnectionTester (the C# app): each connection is opened and one row is
    read from dbo.TestConnection, giving the connection string, the text it read, a status and the
    complete error - inner exceptions and every SQL error included. It reads and writes the same
    JSON file as the C# app, so the two are interchangeable.

    Read-only: it creates and changes nothing on the server.

    Authentication: Windows and SQL logins always work. The Entra ID methods need
    Microsoft.Data.SqlClient, which is taken from the SqlServer module, SSMS or Azure Data Studio,
    or from -SqlClientDll. Without it the built-in client is used and the methods it cannot do are
    shown as unavailable rather than failing oddly later.

    Keys: F2 add, F3 edit, F4 delete, F5 test, F6 test all, F7 full result, F8 export CSV,
          F9 duplicate, Ctrl+S save, Esc/Ctrl+Q quit, Enter edit, arrows/PgUp/PgDn move.

    Exit code: 0 = every connection succeeded, or the app was closed; 2 = one or more failed, or
    the module is missing; 64 = nothing to test or a bad argument; 1 = could not run at all.

.PARAMETER File
    The JSON file of saved connections. Default: %APPDATA%\SqlConnectionTester\connections.json

.PARAMETER Test
    Test every saved connection and print the results, with no screen.

.PARAMETER Csv
    Write the results to this CSV as well. Implies -Test.

.PARAMETER ConnectionString
    Test these connection strings rather than, or as well as, the saved ones. Implies -Test.

.PARAMETER SqlClientDll
    Path to a Microsoft.Data.SqlClient.dll to use, for a machine where it is somewhere unusual.

.PARAMETER SelfTest
    Check the connection-string building and the saved-file round trip, with no server at all.

.EXAMPLE
    .\SqlConnectionTester.ps1
    # the app

.EXAMPLE
    .\SqlConnectionTester.ps1 -Test
    # test every saved connection and print the results (no UI)

.EXAMPLE
    .\SqlConnectionTester.ps1 -ConnectionString 'Server=SQL01;Database=AppDb;Integrated Security=SSPI' -Csv .\results.csv

.EXAMPLE
    .\SqlConnectionTester.ps1 'Server=SQL01;...' 'Server=SQL02;...'
    # several connection strings can simply follow each other

.EXAMPLE
    .\SqlConnectionTester.ps1 -File D:\client-a.json
    # keep a separate list per client (same file format as the C# app)

.NOTES
    Molehill Data Services. Read-only throughout.
#>
[CmdletBinding()]
param(
    [string] $File,
    [switch] $Test,
    [string] $Csv,
    [Parameter(Position = 0)] [string[]] $ConnectionString,   # only this one is positional
    [string] $SqlClientDll,
    [switch] $SelfTest,
    # extra connection strings given without -ConnectionString (handy when the script is started with
    # powershell.exe -File, where comma separated arrays do not bind)
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Remaining
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Invoke-MhSqlConnectionTester.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Invoke-MhSqlConnectionTester'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# handed through by asking the function what it takes, rather than by a list here that can
# drift: two shims were quietly dropping parameters that way, which looks exactly like the tool
# ignoring you
$takes = @((Get-Command Invoke-MhSqlConnectionTester).Parameters.Keys)
$arguments = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($takes -contains $name) { $arguments[$name] = $PSBoundParameters[$name] }
}

try {
    $results = Invoke-MhSqlConnectionTester @arguments
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    # the function tags the ones that are the caller's own fault, so they keep their own exit code
    if ($_.FullyQualifiedErrorId -like '*MhBadArgument*') { exit 64 }
    exit 1
}

# nothing comes back when the app was drawn rather than a list tested
if (-not $results) { exit 0 }
exit $(if (@($results | Where-Object Status -ne 'Success').Count) { 2 } else { 0 })
