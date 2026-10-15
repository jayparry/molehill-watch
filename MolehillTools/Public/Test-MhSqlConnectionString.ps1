<#
.SYNOPSIS
    Tests a list of SQL Server connection strings and says, for each one, whether it connects and
    what it connected to.

.DESCRIPTION
    For when an application has a connection string that does not work and nobody can say why.
    Each string is tried as written - no tidying, no defaults added - so what is tested is what
    the application is using.

    For each one: whether it opened, how long it took, the server and database it reached, the
    edition and version, who it signed in as, and whether the connection was encrypted. Where it
    failed, the error as the driver gave it, with the SQL Server error number where there is one.

    Nothing is changed on any server: it opens a connection, asks what it is talking to, and
    closes it.

.PARAMETER ConnectionString
    The strings to test. Also takes a pipeline, including objects with a ConnectionString
    property, so the output of Get-MhSqlConnectionString can be piped straight in.

.PARAMETER Path
    A file of connection strings, one per line. Blank lines and # comments are ignored.

.PARAMETER ConnectTimeoutSeconds
    Override the timeout in the strings themselves. Left alone when not given, because the
    timeout is part of what is being tested.

.PARAMETER CommandTimeoutSeconds
    How long the "what are you" query may take. Default 30.

.PARAMETER MaskPasswords
    Mask the password in anything printed, for a string that is going into a ticket.

.PARAMETER Detailed
    Print everything found about each connection rather than one line per string.

.PARAMETER CsvPath
    Write the results to this file as well.

.OUTPUTS
    One object per string, with Status, Server, Database, Edition, Version, LoginName, Encrypted,
    ElapsedMs and ErrorMessage.

.EXAMPLE
    Test-MhSqlConnectionString 'Server=SQL01;Database=Sales;Integrated Security=True'

.EXAMPLE
    Test-MhSqlConnectionString -Path .\strings.txt -MaskPasswords -CsvPath .\results.csv

.EXAMPLE
    # the screen builds one, this tests it
    Get-MhSqlConnectionString -SkipTest | Test-MhSqlConnectionString -Detailed

.NOTES
    Molehill Data Services. Read-only: it connects and asks what it reached.
#>

function Test-MhSqlConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)] [string[]] $ConnectionString,
        [string] $Path,
        [int] $ConnectTimeoutSeconds,
        [ValidateRange(1, 86400)] [int] $CommandTimeoutSeconds = 30,
        [string] $Query = 'SELECT TestText FROM dbo.TestConnection;',
        [switch] $MaskPasswords,
        [switch] $Detailed,
        [string] $CsvPath
    )

    begin {
            $ErrorActionPreference = 'Stop'
            $all = New-Object System.Collections.Generic.List[string]
            $results = New-Object System.Collections.Generic.List[object]
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
                $connected = $false   # per string: one that connects must not make the next look connected
                $testText = $null
                $errorText = $null
                $reached = $null
                $encryptOption = $null
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $conn = $null
                $display = if ($MaskPasswords) { Hide-MhSqlSecret $cs } else { $cs }

                try {
                    $effective = $cs
                    if ($PSBoundParameters.ContainsKey('ConnectTimeoutSeconds')) {
                        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $cs   # throws on a malformed string
                        $builder['Connect Timeout'] = $ConnectTimeoutSeconds
                        $effective = $builder.ConnectionString
                    }

                    $conn = New-Object System.Data.SqlClient.SqlConnection $effective
                    $conn.Open()
                    $connected = $true

                    # what it actually reached, which is most of the point of testing a string:
                    # best effort, because a login with no rights to ask still connected
                    try { $reached = Get-MhSqlServerInfo -Connection $conn } catch { $reached = $null }
                    try {
                        $encryptOption = [string](Invoke-MhSqlQuery -Connection $conn -Query `
                            'SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID').Rows[0][0]
                    }
                    catch { $encryptOption = $null }   # needs VIEW SERVER STATE

                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = $Query
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

                $timer.Stop()
                $result = [pscustomobject]@{
                    Connected        = $connected
                    ConnectionString = $display
                    Server           = $(if ($reached) { $reached.ServerName } else { $null })
                    Database         = $(if ($reached) { $reached.CurrentDatabase } else { $null })
                    Platform         = $(if ($reached) { $reached.Platform } else { $null })
                    Edition          = $(if ($reached) { $reached.Edition } else { $null })
                    Version          = $(if ($reached) { $reached.Version } else { $null })
                    LoginName        = $(if ($reached) { $reached.LoggedInAs } else { $null })
                    Encrypted        = $encryptOption
                    ElapsedMs        = [int]$timer.Elapsed.TotalMilliseconds
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
                    Write-Host "Connected        : $connected" -ForegroundColor $(if ($connected) { 'Green' } else { 'Red' })
                    if ($reached) {
                        Write-Host "Server           : $($reached.ServerName)  ($($reached.Platform) $($reached.Version), $($reached.Edition))"
                        Write-Host "Database         : $($reached.CurrentDatabase)"
                        Write-Host "LoginName        : $($reached.LoggedInAs)"
                    }
                    Write-Host "Encrypted        : $(if ($null -eq $encryptOption) { 'could not tell (needs VIEW SERVER STATE)' } else { $encryptOption })"
                    Write-Host "ElapsedMs        : $([int]$timer.Elapsed.TotalMilliseconds)"
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
}

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

Register-MhSelfTest -Name 'Test-MhSqlConnectionString' -Test {
    Test-MhSection 'keeping the password out of what it prints'

    $masked = Hide-MhSqlSecret 'Server=SQL01;User ID=sa;Password=hunter2;Encrypt=True'
    Test-MhCheck 'a password is masked' ($masked -notmatch 'hunter2' -and $masked -match 'Password=\*+') $masked
    Test-MhCheck 'and the rest of the string is left alone' ($masked -match 'Server=SQL01' -and $masked -match 'Encrypt=True')
    $masked = Hide-MhSqlSecret 'Server=SQL01;Pwd=hunter2;'
    Test-MhCheck 'the Pwd spelling counts too' ($masked -notmatch 'hunter2') $masked
    # the case that matters: a password with a semicolon in it is quoted, and a pattern that stops
    # at the first semicolon would show the rest of it
    $masked = Hide-MhSqlSecret 'Server=SQL01;Password="hun;ter2";Encrypt=True'
    Test-MhCheck 'a quoted password is masked whole' ($masked -notmatch 'ter2' -and $masked -match 'Encrypt=True') $masked
    $masked = Hide-MhSqlSecret 'Server=SQL01;Integrated Security=SSPI'
    Test-MhCheck 'a string with no password is not changed' ($masked -eq 'Server=SQL01;Integrated Security=SSPI')
    Test-MhCheck 'and nothing at all is still nothing' ((Hide-MhSqlSecret '') -eq '')

    Test-MhSection 'reading the strings to test'

    # nothing listening on port 1 of this machine, so each of these fails at once rather than
    # waiting: what is being checked is which strings it read, not what the server said
    $file = Join-Path ([System.IO.Path]::GetTempPath()) "mh-strings-$PID.txt"
    try {
        Set-Content -LiteralPath $file -Encoding UTF8 -Value @(
            '# a comment, which is not a connection string',
            '',
            'Server=127.0.0.1,1;Connect Timeout=1',
            '   Server=127.0.0.1,1;Database=Other;Connect Timeout=1   '
        )
        $results = @(Test-MhSqlConnectionString -Path $file -MaskPasswords 6>$null)
        Test-MhCheck 'comments and blank lines are left out' ($results.Count -eq 2) ("$($results.Count) tested")
        Test-MhCheck 'and the lines are trimmed' ($results[1].ConnectionString -eq 'Server=127.0.0.1,1;Database=Other;Connect Timeout=1') $results[1].ConnectionString
        Test-MhCheck 'a string that cannot connect says so rather than throwing' (-not $results[0].Connected -and $results[0].Status -ne 'Success')
        Test-MhCheck 'with the error it got' ([bool]$results[0].ErrorMessage) $results[0].ErrorMessage
        Test-MhCheck 'and how long it took' ($null -ne $results[0].ElapsedMs)
    }
    finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }

    $threw = ''
    try { $null = Test-MhSqlConnectionString -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'mh-no-such-file.txt') 6>$null }
    catch { $threw = $_.Exception.Message }
    Test-MhCheck 'a file that is not there is said so by name' ($threw -match 'not found') $threw
}
