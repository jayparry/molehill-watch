#Requires -Version 5.1

<#
.SYNOPSIS
    Tests a list of SQL Server connection strings and says, for each one, whether it connects and
    what it connected to.

.DESCRIPTION
    Molehill Data Services | Test-SqlConnectionString

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Test-MhSqlConnectionString). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

    For when an application has a connection string that does not work and nobody can say why.
    Each string is tried as written - no tidying, no defaults added - so what is tested is what
    the application is using.

    For each one: whether it opened, how long it took, the server and database it reached, the
    edition and version, who it signed in as, and whether the connection was encrypted. Where it
    failed, the error as the driver gave it, with the SQL Server error number where there is one.

    The query it runs by default is SELECT TestText FROM dbo.TestConnection, which is the table
    these applications expect to be able to read. Connecting and reading are reported separately,
    because "the string is wrong" and "that table is not in this database" need different fixes.
    -Query points it at something else.

    Exit code: 0 = every string succeeded, 1 = at least one did not, 2 = nothing to test.

.PARAMETER ConnectionString
    The strings to test. Also takes a pipeline, including objects with a ConnectionString
    property.

.PARAMETER Path
    A file of connection strings, one per line. Blank lines and # comments are ignored.

.PARAMETER Query
    The query to run once connected. Default: SELECT TestText FROM dbo.TestConnection;

.PARAMETER ConnectTimeoutSeconds
    Override the timeout in the strings themselves. Left alone when not given, because the
    timeout is part of what is being tested.

.PARAMETER CommandTimeoutSeconds
    How long the query may take. Default 30.

.PARAMETER MaskPasswords
    Mask the password in anything printed, for a string that is going into a ticket.

.PARAMETER Detailed
    Print everything found about each connection rather than one line per string.

.PARAMETER CsvPath
    Write the results to this file as well.

.EXAMPLE
    .\Test-SqlConnectionString.ps1 'Server=SQL01;Database=Sales;Integrated Security=True'

.EXAMPLE
    .\Test-SqlConnectionString.ps1 -Path .\strings.txt -MaskPasswords -CsvPath .\results.csv

.NOTES
    Molehill Data Services. Read-only: it connects and asks what it reached.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)] [string[]] $ConnectionString,
    [string] $Path,
    [string] $Query,
    [int] $ConnectTimeoutSeconds,
    [ValidateRange(1, 86400)] [int] $CommandTimeoutSeconds = 30,
    [switch] $MaskPasswords,
    [switch] $Detailed,
    [string] $CsvPath
)

begin {
    $ErrorActionPreference = 'Stop'

    $manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
        Write-Host "  Looked for: $manifest" -ForegroundColor Gray
        Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Test-MhSqlConnectionString.' -ForegroundColor Gray
        exit 2
    }
    Import-Module $manifest -Force

    $collected = New-Object System.Collections.Generic.List[string]
}
process {
    foreach ($one in $ConnectionString) { if ($one) { $collected.Add($one) } }
}
end {
    $arguments = @{ CommandTimeoutSeconds = $CommandTimeoutSeconds }
    if ($collected.Count) { $arguments['ConnectionString'] = $collected.ToArray() }
    foreach ($name in 'Path', 'Query', 'ConnectTimeoutSeconds', 'MaskPasswords', 'Detailed', 'CsvPath') {
        if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
    }

    $results = @(Test-MhSqlConnectionString @arguments)
    $results
    if ($results.Count -eq 0) { exit 2 }
    if (@($results | Where-Object { $_.Status -ne 'Success' }).Count) { exit 1 }
    exit 0
}
