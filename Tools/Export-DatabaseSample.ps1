#Requires -Version 5.1

<#
.SYNOPSIS
    Exports a random sample of rows from every user table in a database to CSV, then zips the lot.

.DESCRIPTION
    Molehill Data Services | Export-DatabaseSample

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Export-MhDatabaseSample). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    For handing a developer realistically shaped data, reproducing a problem somewhere safe, or
    seeing what is actually in a database you have just been given.

    SELECT TOP (n) ... ORDER BY NEWID() per table, to <OutputPath>\<Database>\<schema>.<table>.csv
    and then into <Database>.zip. Every file has a header row, including the ones for empty tables.
    geography, geometry and hierarchyid are converted server side, binary comes out as 0x hex,
    dates are ISO 8601, and the files are UTF-8 with a BOM so Excel opens them without a fight.

    For a screen that builds the connection and lets you pick the tables, run
    Start-DatabaseSampleTui.ps1, which calls this.

    IT COPIES REAL DATA OUT OF A DATABASE. Where that data is personal or confidential, a sample
    of it is still personal or confidential: mind where the zip goes.

    Returns a summary object rather than setting an exit code, so pipe it or assign it.

.PARAMETER SqlInstance
    Server or instance name.

.PARAMETER Database
    The database to sample. Also used as the output folder and zip file name.

.PARAMETER ConnectionString
    Use this connection string instead of building one. -Database is taken from its Initial
    Catalog unless given separately.

.PARAMETER UseMicrosoftDataSqlClient
    Connect with Microsoft.Data.SqlClient rather than System.Data.SqlClient.

.PARAMETER IncludeTable
    Export only these tables: schema.table, a bare name, or a wildcard.

.PARAMETER ExcludeTable
    Export everything except these. Applied after -IncludeTable.

.PARAMETER Top
    Rows to sample per table. Default 200.

.PARAMETER OutputPath
    An existing folder to receive the folder and the zip. Default: here.

.PARAMETER SqlCredential
    SQL authentication. Omit every authentication parameter for Windows authentication.

.PARAMETER UseEntraId
    Entra ID authentication with a token from Get-AzAccessToken. Needs Az.Accounts.

.PARAMETER AccessToken
    Your own Entra ID access token for https://database.windows.net/

.PARAMETER TrustServerCertificate
    Skip certificate validation, which an on-premises instance with a self-signed one needs.

.PARAMETER ReadUncommitted
    Sample under READ UNCOMMITTED, so no shared locks are taken.

.PARAMETER CommandTimeout
    Per-table query timeout in seconds. Default 600.

.PARAMETER RemoveFolderAfterZip
    Delete the folder once the zip is made.

.PARAMETER Force
    Replace an existing folder and zip of the same name.

.PARAMETER SelfTest
    Check the table filtering, with no server at all.

.EXAMPLE
    .\Export-DatabaseSample.ps1 -SqlInstance SQLPROD01 -Database Sales -TrustServerCertificate

.EXAMPLE
    .\Export-DatabaseSample.ps1 -SqlInstance SQLPROD01 -Database Sales -ExcludeTable '*Audit*', 'staging.*'

.NOTES
    Molehill Data Services. It reads data and writes files locally; nothing on the server changes.
#>
[CmdletBinding(DefaultParameterSetName = 'Windows')]
param(
    [Parameter(Position = 0)] [string]$SqlInstance,
    [Parameter(Position = 1)] [string]$Database,
    [string]$ConnectionString,
    [switch]$UseMicrosoftDataSqlClient,
    [string[]]$IncludeTable,
    [string[]]$ExcludeTable,
    [Alias('n')] [ValidateRange(1, 2147483647)] [int]$Top = 200,
    [string]$OutputPath = (Get-Location).ProviderPath,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$UseEntraId,
    [string]$AccessToken,
    [switch]$TrustServerCertificate,
    [switch]$ReadUncommitted,
    [ValidateRange(0, 86400)] [int]$CommandTimeout = 600,
    [switch]$RemoveFolderAfterZip,
    [switch]$Force,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Export-MhDatabaseSample.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Export-MhDatabaseSample'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# only what was actually asked for: the function's parameter sets decide what goes together, and
# passing an empty -SqlInstance alongside -ConnectionString would break that
$arguments = @{ Top = $Top; OutputPath = $OutputPath; CommandTimeout = $CommandTimeout }
foreach ($name in 'SqlInstance', 'Database', 'ConnectionString', 'UseMicrosoftDataSqlClient',
                  'IncludeTable', 'ExcludeTable', 'SqlCredential', 'UseEntraId', 'AccessToken',
                  'TrustServerCertificate', 'ReadUncommitted', 'RemoveFolderAfterZip', 'Force') {
    if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
}

Export-MhDatabaseSample @arguments
