<#
.SYNOPSIS
    Tests SQL Server connection strings by reading dbo.TestConnection, and reports the result of each.

.DESCRIPTION
    For every connection string given it:
      1. opens a connection using that string exactly as supplied
      2. runs  SELECT TestText FROM dbo.TestConnection
      3. returns ConnectionString, TestText, Status (Success or Failure) and ErrorMessage

    ErrorMessage is the COMPLETE error: every error in a SqlException's Errors collection (number,
    severity, state, procedure, line), every inner exception, and the client connection id. Nothing
    is truncated or reworded.

    Objects are written to the pipeline, so the full text survives:
        .\Test-SqlConnectionString.ps1 -ConnectionString $strings | Format-List
        .\Test-SqlConnectionString.ps1 -Path .\connections.txt -CsvPath .\results.csv
    A plain run prints PowerShell's default table, which shortens long errors on screen - pipe to
    Format-List (or use -Detailed) to read them in full.

    The script only reads. It creates nothing and changes nothing.

.PARAMETER ConnectionString
    One or more connection strings. Also accepted from the pipeline.

.PARAMETER Path
    A text file of connection strings, one per line. Blank lines and lines starting with # are ignored.

.PARAMETER ConnectTimeoutSeconds
    Overrides the connect timeout in every connection string. Without it, each string's own setting
    (or the 15 second default) applies.

.PARAMETER CommandTimeoutSeconds
    Query timeout. Default 30.

.PARAMETER MaskPasswords
    Replaces the password in the returned ConnectionString with ***, for results you are sharing.

.PARAMETER Detailed
    Also prints every result in full to the screen as it runs.

.PARAMETER CsvPath
    Saves the results to a CSV file as well.

.EXAMPLE
    .\Test-SqlConnectionString.ps1 -ConnectionString 'Server=SQL01;Database=AppDb;Integrated Security=SSPI' | Format-List

.EXAMPLE
    $cs = 'Server=SQL01;Database=AppDb;Integrated Security=SSPI', 'Server=SQL02,14330;Database=AppDb;User ID=app;Password=***'
    .\Test-SqlConnectionString.ps1 -ConnectionString $cs -CsvPath .\results.csv

.EXAMPLE
    Get-Content .\connections.txt | .\Test-SqlConnectionString.ps1 -Detailed
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)] [string[]] $ConnectionString,
    [string] $Path,
    [int] $ConnectTimeoutSeconds,
    [int] $CommandTimeoutSeconds = 30,
    [switch] $MaskPasswords,
    [switch] $Detailed,
    [string] $CsvPath
)

begin {
    $ErrorActionPreference = 'Stop'
    $all = New-Object System.Collections.Generic.List[string]
    $results = New-Object System.Collections.Generic.List[object]

    # Everything the exception chain knows, in full
    function Get-FullErrorText($Exception) {
        $lines = New-Object System.Collections.Generic.List[string]
        $e = $Exception
        # PowerShell wraps .NET calls in MethodInvocationException ("Exception calling ..."), which only
        # repeats the real message: start at the genuine exception instead.
        while ($e -is [System.Management.Automation.MethodInvocationException] -and $e.InnerException) { $e = $e.InnerException }
        $level = 0
        while ($e) {
            $prefix = if ($level -eq 0) { '' } else { "Inner exception ($level): " }
            $lines.Add("$prefix[$($e.GetType().FullName)] $($e.Message)")
            if ($e -is [System.Data.SqlClient.SqlException]) {
                if ($e.ClientConnectionId -and $e.ClientConnectionId -ne [guid]::Empty) { $lines.Add("Client connection id: $($e.ClientConnectionId)") }
                $n = 0
                foreach ($err in $e.Errors) {
                    $n++
                    $detail = "SQL error $n of $($e.Errors.Count): Msg $($err.Number), Level $($err.Class), State $($err.State)"
                    if ($err.Procedure) { $detail += ", Procedure $($err.Procedure)" }
                    if ($err.LineNumber) { $detail += ", Line $($err.LineNumber)" }
                    if ($err.Server) { $detail += ", Server $($err.Server)" }
                    $lines.Add($detail)
                    $lines.Add($err.Message)
                }
            }
            $e = $e.InnerException
            $level++
        }
        return ($lines -join [Environment]::NewLine)
    }

    function Hide-Password([string]$Cs) {
        return ($Cs -replace '(?i)\b(password|pwd)\s*=\s*[^;]*', '$1=***')
    }
}

process {
    foreach ($cs in $ConnectionString) { if ($cs -and $cs.Trim()) { $all.Add($cs.Trim()) } }
}

end {
    if ($Path) {
        if (-not (Test-Path $Path)) { throw "Connection string file not found: $Path" }
        Get-Content -Path $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $all.Add($_) }
    }
    if ($all.Count -eq 0) { throw 'Give at least one connection string with -ConnectionString, -Path, or from the pipeline.' }

    foreach ($cs in $all) {
        $status = 'Failure'
        $testText = $null
        $errorText = $null
        $conn = $null
        $display = if ($MaskPasswords) { Hide-Password $cs } else { $cs }

        try {
            $effective = $cs
            if ($PSBoundParameters.ContainsKey('ConnectTimeoutSeconds')) {
                $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs   # throws on a malformed string
                $builder['Connect Timeout'] = $ConnectTimeoutSeconds
                $effective = $builder.ConnectionString
            }

            $conn = New-Object System.Data.SqlClient.SqlConnection $effective
            $conn.Open()

            $cmd = $conn.CreateCommand()
            $cmd.CommandText = 'SELECT TestText FROM dbo.TestConnection;'
            $cmd.CommandTimeout = $CommandTimeoutSeconds
            $table = New-Object System.Data.DataTable
            $table.Load($cmd.ExecuteReader())

            if ($table.Rows.Count -eq 0) {
                $errorText = 'Connected and read dbo.TestConnection, but the table contains no rows.'
            }
            else {
                $value = $table.Rows[0]['TestText']
                $testText = if ($value -is [DBNull]) { $null } else { [string]$value }
                $status = 'Success'
                if ($table.Rows.Count -gt 1) { $errorText = "Note: dbo.TestConnection returned $($table.Rows.Count) rows; the first was used." }
            }
        }
        catch {
            $errorText = Get-FullErrorText $_.Exception
        }
        finally {
            if ($conn) { $conn.Dispose() }
        }

        $result = [pscustomobject]@{
            ConnectionString = $display
            TestText         = $testText
            Status           = $status
            ErrorMessage     = $errorText
        }
        $results.Add($result)

        if ($Detailed) {
            $colour = if ($status -eq 'Success') { 'Green' } else { 'Red' }
            Write-Host ''
            Write-Host "ConnectionString : $display"
            Write-Host "Status           : $status" -ForegroundColor $colour
            Write-Host "TestText         : $testText"
            if ($errorText) { Write-Host "ErrorMessage     : $errorText" -ForegroundColor $(if ($status -eq 'Success') { 'Yellow' } else { 'Red' }) }
        }
    }

    if ($CsvPath) {
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host ''
        Write-Host "Results saved: $CsvPath ($(@($results | Where-Object Status -eq 'Success').Count) of $($results.Count) succeeded)" -ForegroundColor Cyan
    }

    $results
}
