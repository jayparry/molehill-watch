<#
    What the two restore tools both do: read a timestamp whatever shape it arrives in, turn a SAS
    token into something usable, name the files a restore has to move, write the RESTORE itself,
    fetch a blob and prove it arrived whole, and run a long statement while showing it move.

    Identical in both, so here once. The two that are not identical - connecting to a container,
    and the date format each one prints - stay with their tools.
#>

$script:MhSqlMessages = New-Object System.Collections.Generic.List[string]
$script:MhSqlLastPercent = -1
$script:MhSqlQuietProgress = $false
$script:MhSqlProgressLabel = ''

# every message the last long-running statement produced, for a caller that wants more than the
# summary line
function Get-MhSqlMessage { foreach ($message in $script:MhSqlMessages) { $message } }

<#
  Puts a timestamp into one known type, whatever shape it arrived in.

  Az.Storage hands back LastModified as a DateTimeOffset, SQL Server hands back a DateTime, and a
  file read off disk can give either or a string. Letting PowerShell convert between them is the
  trap: the conversion goes through the string form in the machine's own culture, so code that
  works on one regional setting throws "Cannot convert the ... value of type System.DateTimeOffset
  to type System.DateTime" on another. Everything here is normalised to a UTC DateTimeOffset on the
  way in, parsed with the invariant culture, and compared as that type only.
#>
function ConvertTo-MhUtcTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $Value)

    if ($null -eq $Value) { throw 'no timestamp to convert' }
    if ($Value -is [System.DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        $when = [datetime]$Value
        # an unspecified kind is treated as UTC rather than as local: blob and backup timestamps
        # are UTC, and guessing local would shift them by the server's offset
        if ($when.Kind -eq [System.DateTimeKind]::Unspecified) {
            $when = [datetime]::SpecifyKind($when, [System.DateTimeKind]::Utc)
        }
        return ([System.DateTimeOffset]$when).ToUniversalTime()
    }

    $text = ([string]$Value).Trim()
    if (-not $text) { throw 'no timestamp to convert' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse($text, $invariant, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime() }

    # the shapes SQL Server, sqlcmd and the Azure libraries produce, none of them regional
    $formats = @('yyyy-MM-ddTHH:mm:ss.fffK', 'yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-dd HH:mm:ss.fff',
                 'yyyy-MM-dd HH:mm:ss', 'M/d/yyyy h:mm:ss tt zzz', 'M/d/yyyy h:mm:ss tt',
                 'd/M/yyyy HH:mm:ss zzz', 'd/M/yyyy HH:mm:ss')
    if ([System.DateTimeOffset]::TryParseExact($text, $formats, $invariant, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    throw ("cannot make a date out of '" + $text + "'")
}

# A SecureString here, a plain string there, and a leading '?' from the portal either way.
function ConvertTo-MhPlainSas {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Token)

    if ($null -eq $Token) { throw 'SasToken is empty.' }
    $plain = $null
    if ($Token -is [System.Security.SecureString]) {
        # ConvertFrom-SecureString -AsPlainText is PowerShell 7 only, and this script runs on 5.1
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    elseif ($Token -is [string]) { $plain = $Token }
    else { throw "SasToken must be a string or a SecureString, not $($Token.GetType().FullName)." }

    $plain = $plain.Trim().TrimStart('?')
    if (-not $plain) { throw 'SasToken is empty.' }
    $plain
}

function Format-MhSize([double] $Bytes) {
    if ($Bytes -ge 1TB) { return ('{0:n1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:n1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n0} MB' -f ($Bytes / 1MB)) }
    '{0:n0} KB' -f ($Bytes / 1KB)
}

<#
  Builds one RESTORE statement. Separate from running it so that -WhatIf can print exactly what
  would have run, and so the self test can check the awkward parts (file positions, MOVE, STOPAT).
#>
function New-MhRestoreCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Database,
        [Parameter(Mandatory)] $BackupSet,          # Files, Position, HasChecksums
        [ValidateSet('Database', 'Log')] [string] $Kind = 'Database',
        [ValidateSet('NORECOVERY', 'RECOVERY', 'STANDBY')] [string] $Finish = 'NORECOVERY',
        [string] $StandbyFile,
        $MoveList,                                   # @{ LogicalName = TargetPath }
        [switch] $Replace,
        $StopAt
    )

    $verb = if ($Kind -eq 'Log') { 'RESTORE LOG' } else { 'RESTORE DATABASE' }
    $devices = (@($BackupSet.Files) | ForEach-Object { "DISK = N'" + (Esc-MhStr $_) + "'" }) -join ",`r`n     "

    $with = New-Object System.Collections.Generic.List[string]
    $with.Add('FILE = ' + [int]$BackupSet.Position)
    if ($MoveList) {
        foreach ($logical in ($MoveList.Keys | Sort-Object)) {
            $with.Add("MOVE N'" + (Esc-MhStr $logical) + "' TO N'" + (Esc-MhStr $MoveList[$logical]) + "'")
        }
    }
    if ($Replace) { $with.Add('REPLACE') }
    switch ($Finish) {
        'NORECOVERY' { $with.Add('NORECOVERY') }
        'RECOVERY'   { $with.Add('RECOVERY') }
        'STANDBY'    { $with.Add("STANDBY = N'" + (Esc-MhStr $StandbyFile) + "'") }
    }
    if ($StopAt) { $with.Add("STOPAT = N'" + $StopAt.ToString('yyyy-MM-ddTHH:mm:ss') + "'") }
    if ($BackupSet.HasChecksums) { $with.Add('CHECKSUM') }
    $with.Add('STATS = 5')

    "{0} {1}`r`nFROM {2}`r`nWITH {3};" -f $verb, (Esc-MhName $Database), $devices, ($with -join ",`r`n     ")
}

# the target path for one file out of the backup, data and log kept apart, FILESTREAM to its folder
function Get-MhMoveTarget {
    [CmdletBinding()]
    param([string] $PhysicalName, [string] $FileType, [string] $DataPath, [string] $LogPath,
          [string] $SourceDatabase, [string] $DestinationDatabase)

    $leaf = Split-Path -Leaf $PhysicalName
    # a copy restored next to the original must not be called the same thing on disk
    if ($SourceDatabase -and $DestinationDatabase -and $SourceDatabase -ne $DestinationDatabase -and
        $leaf.StartsWith($SourceDatabase, [StringComparison]::OrdinalIgnoreCase)) {
        $leaf = $DestinationDatabase + $leaf.Substring($SourceDatabase.Length)
    }
    $folder = if ($FileType -eq 'L') { $LogPath } else { $DataPath }
    ($folder.TrimEnd('\') + '\' + $leaf)
}

<#
  Runs a RESTORE or BACKUP and shows it moving. SQL Server reports progress as informational
  messages ("40 percent processed."), which arrive on the connection's InfoMessage event, so one
  connection does the work and the reporting - no polling from a second session.
#>
function Invoke-MhLongRunningSql {
    [CmdletBinding()]
    param(
        # a connection string, not a server: the credential, the certificate and the timeout for
        # this end are the caller's business, and a function at module scope cannot see them
        [Parameter(Mandatory)] [string] $ConnectionString,
        [Parameter(Mandatory)] [string] $Sql,
        [string] $Label
    )

    $script:MhSqlMessages.Clear()
    $script:MhSqlLastPercent = -1
    $quiet = [Console]::IsOutputRedirected
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($sender, $e)
        foreach ($err in $e.Errors) {
            $text = [string]$err.Message
            $script:MhSqlMessages.Add($text)
            if ($text -match '(\d+) percent processed') {
                $pct = [int]$Matches[1]
                if ($pct -gt $script:MhSqlLastPercent) {
                    $script:MhSqlLastPercent = $pct
                    if ($script:MhSqlQuietProgress) {
                        if ($pct % 25 -eq 0) { Write-Host ("    {0,-12} {1}  {2}%" -f '', $script:MhSqlProgressLabel, $pct) -ForegroundColor DarkGray }
                    }
                    else {
                        Write-Host ("`r    {0,-12} {1} {2,3}%  " -f '', $script:MhSqlProgressLabel, $pct) -NoNewline -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
    $script:MhSqlQuietProgress = $quiet
    $script:MhSqlProgressLabel = $Label

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $connection.add_InfoMessage($handler)
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        $command.CommandTimeout = 0        # a big restore takes as long as it takes
        [void]$command.ExecuteNonQuery()
        $watch.Stop()
        if (-not $quiet -and $script:MhSqlLastPercent -ge 0) { Write-Host "`r$(' ' * 60)`r" -NoNewline }

        # "RESTORE DATABASE successfully processed 134518 pages in 8.714 seconds (120.586 MB/sec)."
        $summary = @($script:MhSqlMessages | Where-Object { $_ -match 'successfully processed' }) | Select-Object -Last 1
        $mb = $null
        if ($summary -match 'processed (\d+) pages') { $mb = [math]::Round(([double]$Matches[1] * 8KB) / 1MB, 0) }
        [pscustomobject]@{
            Ok = $true; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Megabytes = $mb
            Message = $summary; Error = $null
        }
    }
    catch {
        $watch.Stop()
        if (-not $quiet -and $script:MhSqlLastPercent -ge 0) { Write-Host "`r$(' ' * 60)`r" -NoNewline }
        [pscustomobject]@{
            Ok = $false; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1); Megabytes = $null
            Message = $null; Error = ($_.Exception.GetBaseException().Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' '
        }
    }
    finally { $connection.Dispose() }
}

# Fetches one blob and proves it arrived whole: a short file would fail the restore far less clearly.
function Get-MhBlobToFile {
    [CmdletBinding()]
    param($Context, [string] $Container, $Blob, [string] $TargetPath)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Get-AzStorageBlobContent -Container $Container -Blob $Blob.Name -Destination $TargetPath `
        -Context $Context -Force | Out-Null
    $timer.Stop()
    $length = (Get-Item -LiteralPath $TargetPath).Length
    if ($length -ne $Blob.Length) {
        throw "Size mismatch for $($TargetPath): the blob is $($Blob.Length) bytes and the local file is $length bytes"
    }
    $rate = if ($timer.Elapsed.TotalSeconds -gt 0.5) { ' at {0}/s' -f (Format-MhSize ($length / $timer.Elapsed.TotalSeconds)) } else { '' }
    Write-MhLog ('  {0} ({1}) in {2:N1}s{3}' -f (Split-Path -Leaf $TargetPath), (Format-MhSize $length), $timer.Elapsed.TotalSeconds, $rate)
    $length
}

<#
  Runs one short statement against a database on the destination. The token {DB} becomes
  QUOTENAME(database name) inside SQL Server, so the identifier is always quoted safely and the
  name never has to be pasted into the statement out here.
#>
function Invoke-MhDbStatement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ConnectionString,
        [Parameter(Mandatory)] [string] $DatabaseName,
        [Parameter(Mandatory)] [string] $Statement
    )

    $query = @'
DECLARE @sql nvarchar(max) = REPLACE(@Stmt, N'{DB}', QUOTENAME(@Db));
EXEC sys.sp_executesql @sql;
'@
    Write-MhDeep ('  statement: ' + ($Statement -replace '\{DB\}', ('[' + $DatabaseName + ']')))
    [void](Invoke-MhSql -ConnectionString $ConnectionString -Query $query -Parameters @{ '@Db' = $DatabaseName; '@Stmt' = $Statement })
}

Register-MhSelfTest -Name 'The shared backup plumbing' -Test {
    Test-MhSection 'reading a timestamp whatever shape it arrives in'

    # the bug this guards against is regional: a script that works here throws on a machine set to
    # another culture, or silently shifts a backup time by the server's offset
    $expected = [System.DateTimeOffset]::new(2026, 3, 14, 9, 5, 0, [TimeSpan]::Zero)
    foreach ($shape in '2026-03-14T09:05:00Z', '2026-03-14 09:05:00', '2026-03-14T09:05:00+00:00') {
        Test-MhCheck "'$shape'" ((ConvertTo-MhUtcTime $shape) -eq $expected) (ConvertTo-MhUtcTime $shape).ToString('o')
    }
    $unspecified = [datetime]::new(2026, 3, 14, 9, 5, 0, [System.DateTimeKind]::Unspecified)
    Test-MhCheck 'a date with no kind is taken as UTC, not local' ((ConvertTo-MhUtcTime $unspecified) -eq $expected)
    Test-MhCheck 'an offset is converted rather than ignored' ((ConvertTo-MhUtcTime '2026-03-14T10:05:00+01:00') -eq $expected)
    Test-MhCheck 'something already UTC is left alone' ((ConvertTo-MhUtcTime $expected) -eq $expected)
    $threw = $false
    try { $null = ConvertTo-MhUtcTime 'the day before yesterday' } catch { $threw = $true }
    Test-MhCheck 'and nonsense is refused rather than guessed at' $threw

    Test-MhSection 'sizes and SAS tokens'

    Test-MhCheck 'bytes are shown in KB' ((Format-MhSize 2048) -eq '2 KB')
    Test-MhCheck 'megabytes in MB' ((Format-MhSize (5 * 1MB)) -eq '5 MB')
    Test-MhCheck 'and a big backup in GB' ((Format-MhSize (3.5 * 1GB)) -eq '3.5 GB')

    Test-MhCheck 'a plain token comes back as it is' ((ConvertTo-MhPlainSas 'sv=2024&sig=abc') -eq 'sv=2024&sig=abc')
    Test-MhCheck "the portal's leading question mark is dropped" ((ConvertTo-MhPlainSas '?sv=2024&sig=abc') -eq 'sv=2024&sig=abc')
    $secure = ConvertTo-SecureString '?sv=2024&sig=abc' -AsPlainText -Force
    Test-MhCheck 'and a SecureString is read without PowerShell 7 only cmdlets' ((ConvertTo-MhPlainSas $secure) -eq 'sv=2024&sig=abc')
    $threw = $false
    try { $null = ConvertTo-MhPlainSas '  ' } catch { $threw = $true }
    Test-MhCheck 'an empty one is refused' $threw

    Test-MhSection 'where a restored file goes'

    $moved = Get-MhMoveTarget -PhysicalName 'E:\Data\Sales.mdf' -FileType 'D' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs'
    Test-MhCheck 'data goes to the data path' ($moved -eq 'D:\SqlData\Sales.mdf') $moved
    $moved = Get-MhMoveTarget -PhysicalName 'E:\Logs\Sales_log.ldf' -FileType 'L' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs'
    Test-MhCheck 'and the log to the log path' ($moved -eq 'L:\SqlLogs\Sales_log.ldf') $moved
    $moved = Get-MhMoveTarget -PhysicalName 'E:\Data\Sales.mdf' -FileType 'D' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs' -SourceDatabase 'Sales' -DestinationDatabase 'SalesCopy'
    Test-MhCheck 'a copy beside the original is not given the same file name' ($moved -eq 'D:\SqlData\SalesCopy.mdf') $moved
    $moved = Get-MhMoveTarget -PhysicalName 'E:\Data\Other.mdf' -FileType 'D' -DataPath 'D:\SqlData' -LogPath 'L:\SqlLogs' -SourceDatabase 'Sales' -DestinationDatabase 'SalesCopy'
    Test-MhCheck 'a file not named after the database keeps its name' ($moved -eq 'D:\SqlData\Other.mdf') $moved
    $moved = Get-MhMoveTarget -PhysicalName 'E:\Data\Sales.mdf' -FileType 'D' -DataPath 'D:\SqlData\' -LogPath 'L:\SqlLogs'
    Test-MhCheck 'a trailing slash on the path does not double up' ($moved -eq 'D:\SqlData\Sales.mdf') $moved

    Test-MhSection 'the RESTORE itself'

    $set = [pscustomobject]@{ Files = @('\\nas\backups\Sales.bak'); Position = 2; HasChecksums = $true }
    $sql = New-MhRestoreCommand -Database 'SalesCopy' -BackupSet $set -MoveList @{ 'Sales' = 'D:\SqlData\SalesCopy.mdf'; 'Sales_log' = 'L:\SqlLogs\SalesCopy_log.ldf' }
    Test-MhCheck 'it restores the database it was told to' ($sql -match '^RESTORE DATABASE \[SalesCopy\]')
    Test-MhCheck 'from the file in the set' ($sql -like "*DISK = N'\\nas\backups\Sales.bak'*") $sql
    Test-MhCheck 'at the position in the set' ($sql -match 'FILE = 2')
    Test-MhCheck 'moving every file it was given, in a settled order' ($sql -match "(?s)MOVE N'Sales' TO .*MOVE N'Sales_log' TO")
    Test-MhCheck 'leaving it able to take more' ($sql -match 'NORECOVERY')
    Test-MhCheck 'checking the checksums the backup has' ($sql -match 'CHECKSUM')
    Test-MhCheck 'and reporting progress' ($sql -match 'STATS = 5')

    $sql = New-MhRestoreCommand -Database 'SalesCopy' -BackupSet $set -Kind Log -Finish RECOVERY -StopAt ([datetime]::new(2026, 3, 14, 9, 5, 0))
    Test-MhCheck 'a log restore says so' ($sql -match '^RESTORE LOG ')
    Test-MhCheck 'a point in time is written the one way SQL Server always reads' ($sql -match "STOPAT = N'2026-03-14T09:05:00'") $sql
    Test-MhCheck 'and finishing means finishing' ($sql -match 'RECOVERY' -and $sql -notmatch 'NORECOVERY')

    $sql = New-MhRestoreCommand -Database 'SalesCopy' -BackupSet $set -Finish STANDBY -StandbyFile 'S:\standby\SalesCopy.bak'
    Test-MhCheck 'standby names its undo file' ($sql -match "STANDBY = N'S:\\standby\\SalesCopy\.bak'") $sql

    $odd = [pscustomobject]@{ Files = @("\\nas\o'brien\Sales.bak"); Position = 1; HasChecksums = $false }
    $sql = New-MhRestoreCommand -Database "Sales]Odd" -BackupSet $odd
    Test-MhCheck 'a quote in a path is doubled, not left to break out' ($sql -match "o''brien") $sql
    Test-MhCheck 'and a bracket in a database name is escaped' ($sql -match '\[Sales\]\]Odd\]') $sql
    Test-MhCheck 'a backup with no checksums is not asked to verify them' ($sql -notmatch 'CHECKSUM')
}
