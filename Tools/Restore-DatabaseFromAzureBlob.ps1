#Requires -Version 7.0
<#
.SYNOPSIS
    Restores the latest completed full backup of a database from a source SQL Server onto a
    destination SQL Server, staging the backup through Azure Blob Storage and a local disk.

.DESCRIPTION
    Molehill Data Services

    The source database is the master copy at all times. Anything on the destination with the
    same name is overwritten.

    Steps:
      1. Reads full backup history for the database from msdb on the source instance.
      2. Picks the newest backup whose file(s) are all present in the storage container. A backup
         that msdb knows about but has not been uploaded yet is skipped, so a half-finished
         upload is never used (block blobs only become visible once fully committed).
      3. Downloads the file(s) to a local staging folder and checks each file size against the blob.
      4. Takes the destination database offline (rolling back open connections) and restores
         over it WITH REPLACE.
      5. Applies post-restore steps (owner, PAGE_VERIFY CHECKSUM, plus optional compatibility
         level, orphaned user repair, statistics update and DBCC CHECKDB).
      6. Removes the local copy (unless -KeepLocalCopy) and prints a run summary.

    Backup files are matched to blobs by file name: the blob name (after any folder prefix) must
    be the same as the file name recorded in msdb on the source.

    Run this script on the destination server. LocalBackupPath must be a local disk that the
    destination SQL Server service account can read.

    Supports -WhatIf: connects, reads history, lists blobs and reports the plan without
    downloading or restoring anything.

.PARAMETER SourceInstance
    SQL Server instance that took the backups. msdb backup history is read from here.

.PARAMETER DestinationInstance
    SQL Server instance to restore onto.

.PARAMETER DatabaseName
    Database name on the source instance.

.PARAMETER DestinationDatabaseName
    Database name on the destination instance. Defaults to DatabaseName.

.PARAMETER SourceSqlCredential
    SQL authentication credential for the source instance. Omit for Windows authentication.

.PARAMETER DestinationSqlCredential
    SQL authentication credential for the destination instance. Omit for Windows authentication.

.PARAMETER TrustServerCertificate
    Trusts the server certificate and disables connection encryption for this session. Usually
    needed for SQL Server 2008 R2 and for instances using self-signed certificates.

.PARAMETER StorageAccountName
    Azure Storage account holding the backups.

.PARAMETER ContainerName
    Blob container holding the backups.

.PARAMETER BlobPrefix
    Optional virtual folder inside the container, e.g. 'LEGACYSERVER2008R2/MyDB'.

.PARAMETER SasToken
    Shared Access Signature (SAS) token with at least Read and List permissions on the container.
    Accepts a plain string or a SecureString. A leading '?' is removed automatically.
    Wrap a plain string in single quotes: SAS tokens contain '&', which PowerShell treats as an
    operator outside quotes.

.PARAMETER LocalBackupPath
    Local staging folder for the downloaded backup file(s). Created if missing.

.PARAMETER DataDirectory
    Destination folder for data files. Defaults to the destination instance default.

.PARAMETER LogDirectory
    Destination folder for log files. Defaults to the destination instance default.

.PARAMETER LookbackDays
    How many days of backup history to consider on the source.

.PARAMETER DatabaseOwner
    Login to set as database owner after the restore. Pass an empty string to leave it as restored.

.PARAMETER CompatibilityLevel
    Compatibility level to set after the restore. 0 leaves it as restored (100 for SQL Server 2008 R2).

.PARAMETER RunCheckDb
    Runs DBCC CHECKDB WITH DATA_PURITY after the restore.

.PARAMETER UpdateStatistics
    Runs sp_updatestats after the restore.

.PARAMETER RepairOrphanUsers
    Remaps database users to destination logins with the same name.

.PARAMETER KeepLocalCopy
    Keeps the downloaded backup file(s) after a successful restore.

.PARAMETER InstallMissingModules
    Installs dbatools and Az.Storage for the current user if they are missing.

.PARAMETER LogFile
    Optional path of a log file to append to.

.EXAMPLE
    # Dry run
    $sas = Read-Host -AsSecureString -Prompt 'SAS token'
    .\Restore-DatabaseFromAzureBlob.ps1 -DatabaseName 'MyDB' -StorageAccountName 'mycompany' `
        -ContainerName 'legacybackup' -BlobPrefix 'LEGACYSERVER2008R2' -SasToken $sas `
        -LocalBackupPath 'D:\RestoreStaging' -TrustServerCertificate -WhatIf

.EXAMPLE
    # Unattended run with the SAS token held in a SecretManagement vault
    .\Restore-DatabaseFromAzureBlob.ps1 -DatabaseName 'MyDB' -StorageAccountName 'mycompany' `
        -ContainerName 'legacybackup' -SasToken (Get-Secret -Name 'LegacyBackupSas') `
        -LocalBackupPath 'D:\RestoreStaging' -TrustServerCertificate `
        -CompatibilityLevel 170 -RepairOrphanUsers -UpdateStatistics -RunCheckDb `
        -LogFile 'D:\Logs\Restore-MyDB.log'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # SQL Server
    [ValidateNotNullOrEmpty()]
    [string]$SourceInstance = 'LEGACYSERVER2008R2',

    [ValidateNotNullOrEmpty()]
    [string]$DestinationInstance = 'LEGACYSERVER2025',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DatabaseName,

    [string]$DestinationDatabaseName,

    [PSCredential]$SourceSqlCredential,

    [PSCredential]$DestinationSqlCredential,

    [switch]$TrustServerCertificate,

    # Azure Storage
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName,

    [string]$BlobPrefix,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$SasToken,

    # Restore
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LocalBackupPath,

    [string]$DataDirectory,

    [string]$LogDirectory,

    [ValidateRange(1, 365)]
    [int]$LookbackDays = 14,

    # Post-restore
    [string]$DatabaseOwner = 'sa',

    [ValidateSet(0, 100, 110, 120, 130, 140, 150, 160, 170)]
    [int]$CompatibilityLevel = 0,

    [switch]$RunCheckDb,

    [switch]$UpdateStatistics,

    [switch]$RepairOrphanUsers,

    # Housekeeping
    [switch]$KeepLocalCopy,

    [switch]$InstallMissingModules,

    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers

$script:LogFile     = $LogFile
$script:Steps       = [System.Collections.Generic.List[object]]::new()
$script:CurrentStep = $null
$script:StepTimer   = $null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line   = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $colour = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $colour
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -WhatIf:$false
    }
}

function Start-Step {
    param([Parameter(Mandatory)][string]$Name)
    $script:CurrentStep = $Name
    $script:StepTimer   = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "START: $Name"
}

function Complete-Step {
    param([ValidateSet('OK', 'SKIPPED', 'FAILED')][string]$Result = 'OK')
    $seconds = [math]::Round($script:StepTimer.Elapsed.TotalSeconds, 1)
    $script:Steps.Add([pscustomobject]@{ Step = $script:CurrentStep; Result = $Result; Seconds = $seconds })
    $level = if ($Result -eq 'FAILED') { 'ERROR' } else { 'INFO' }
    Write-Log "$($Result): $($script:CurrentStep) ($seconds s)" -Level $level
    $script:CurrentStep = $null
}

function Invoke-DbStatement {
    # Runs a statement against the destination database. The token {DB} is replaced with
    # QUOTENAME(database name) inside SQL Server, so identifiers are always quoted safely.
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Statement
    )
    $query = @'
DECLARE @sql nvarchar(max) = REPLACE(@Stmt, N'{DB}', QUOTENAME(@Db));
EXEC sys.sp_executesql @sql;
'@
    # QueryTimeout 0 = no timeout (restores, CHECKDB and stats can run for a long time)
    Invoke-DbaQuery -SqlInstance $Instance -Database 'master' -Query $query `
        -SqlParameter @{ Db = $Database; Stmt = $Statement } -QueryTimeout 0 -EnableException | Out-Null
}

#endregion Helpers

$SourceInstance      = $SourceInstance.ToUpperInvariant()
$DestinationInstance = $DestinationInstance.ToUpperInvariant()
if (-not $DestinationDatabaseName) { $DestinationDatabaseName = $DatabaseName }

$runStart       = Get-Date
$runSucceeded   = $false
$restored       = $false
$selected       = $null
$localFiles     = @()
$bytesNeeded    = 0

try {
    Write-Log "Restore $SourceInstance.[$DatabaseName] to $DestinationInstance.[$DestinationDatabaseName] via $StorageAccountName/$ContainerName"
    if ($WhatIfPreference) { Write-Log 'WhatIf mode: nothing will be downloaded, restored or changed' -Level WARN }

    if ($SourceInstance -eq $DestinationInstance -and $DatabaseName -eq $DestinationDatabaseName) {
        throw 'Source and destination are the same database. Refusing to overwrite the master copy.'
    }

    #region Modules
    Start-Step 'Load modules'
    foreach ($module in 'dbatools', 'Az.Storage') {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            if (-not $InstallMissingModules) {
                throw "Module '$module' is not installed. Re-run with -InstallMissingModules, or run: Install-Module $module -Scope CurrentUser"
            }
            Write-Log "Installing $module for the current user"
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
        }
        Import-Module -Name $module
    }
    if ($TrustServerCertificate) {
        # Session-only settings; nothing is persisted
        Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true
        Set-DbatoolsConfig -FullName 'sql.connection.encrypt' -Value $false
    }
    Complete-Step
    #endregion Modules

    #region Connect
    Start-Step 'Connect to SQL Server instances'
    $sourceSplat = @{ SqlInstance = $SourceInstance; EnableException = $true }
    if ($SourceSqlCredential) { $sourceSplat.SqlCredential = $SourceSqlCredential }
    $source = Connect-DbaInstance @sourceSplat

    $destinationSplat = @{ SqlInstance = $DestinationInstance; EnableException = $true }
    if ($DestinationSqlCredential) { $destinationSplat.SqlCredential = $DestinationSqlCredential }
    $destination = Connect-DbaInstance @destinationSplat

    Write-Log "Source $SourceInstance is version $($source.VersionString); destination $DestinationInstance is version $($destination.VersionString)"
    Complete-Step
    #endregion Connect

    #region Backup history
    Start-Step 'Read full backup history from source msdb'
    $historyQuery = @'
SELECT  bs.backup_set_id,
        bs.backup_finish_date,
        bs.is_copy_only,
        bmf.family_sequence_number,
        bmf.physical_device_name
FROM    msdb.dbo.backupset AS bs
JOIN    msdb.dbo.backupmediafamily AS bmf
        ON bmf.media_set_id = bs.media_set_id
WHERE   bs.database_name = @DatabaseName
AND     bs.type = 'D'                 -- full database backups
AND     bmf.device_type = 2           -- disk
AND     bmf.mirror = 0                -- primary media only, ignore MIRROR TO copies
AND     bs.backup_finish_date >= DATEADD(DAY, -@LookbackDays, GETDATE())
ORDER BY bs.backup_finish_date DESC, bmf.family_sequence_number;
'@
    $historyRows = @(Invoke-DbaQuery -SqlInstance $source -Database 'msdb' -Query $historyQuery `
            -SqlParameter @{ DatabaseName = $DatabaseName; LookbackDays = $LookbackDays } -As PSObject -EnableException)

    if ($historyRows.Count -eq 0) {
        throw "No full disk backups of [$DatabaseName] found on $SourceInstance in the last $LookbackDays day(s)."
    }

    # One candidate per backup set; striped backups have several files
    $candidates = @(
        $historyRows | Group-Object -Property backup_set_id | ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                BackupSetId = $first.backup_set_id
                Finished    = $first.backup_finish_date
                CopyOnly    = [bool]$first.is_copy_only
                Files       = @($_.Group | Sort-Object -Property family_sequence_number |
                                ForEach-Object { [System.IO.Path]::GetFileName($_.physical_device_name) })
            }
        } | Sort-Object -Property Finished -Descending
    )
    Write-Log "Found $($candidates.Count) full backup(s) in the last $LookbackDays day(s); newest finished $($candidates[0].Finished)"
    Complete-Step
    #endregion Backup history

    #region Storage
    Start-Step 'List backup blobs in storage container'
    $sasPlain = switch ($SasToken) {
        { $_ -is [SecureString] } { ConvertFrom-SecureString -SecureString $_ -AsPlainText; break }
        { $_ -is [string] }       { $_; break }
        default { throw "SasToken must be a string or SecureString, not $($SasToken.GetType().FullName)." }
    }
    $sasPlain = $sasPlain.Trim().TrimStart('?')
    if (-not $sasPlain) { throw 'SasToken is empty.' }
    $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $sasPlain
    $sasPlain       = $null

    $listSplat = @{ Container = $ContainerName; Context = $storageContext }
    if ($BlobPrefix) { $listSplat.Prefix = $BlobPrefix.Trim('/') + '/' }
    $blobs = @(Get-AzStorageBlob @listSplat)
    Write-Log "Found $($blobs.Count) blob(s) under '$ContainerName/$($BlobPrefix)'"

    # Index by file name (case-insensitive); if the same name exists in several folders, the newest wins
    $blobIndex = @{}
    foreach ($blob in $blobs) {
        $leaf = ($blob.Name -split '/')[-1]
        if (-not $blobIndex.ContainsKey($leaf) -or $blob.LastModified -gt $blobIndex[$leaf].LastModified) {
            $blobIndex[$leaf] = $blob
        }
    }

    foreach ($candidate in $candidates) {
        $missing = @($candidate.Files | Where-Object { -not $blobIndex.ContainsKey($_) })
        if ($missing.Count -eq 0) {
            $selected = $candidate
            break
        }
        Write-Log "Skipping backup finished $($candidate.Finished): not in storage yet ($($missing -join ', '))" -Level WARN
    }
    if (-not $selected) {
        throw "None of the $($candidates.Count) recent full backup(s) of [$DatabaseName] are fully present in the container. Check the upload process and BlobPrefix."
    }

    $selectedBlobs = @($selected.Files | ForEach-Object { $blobIndex[$_] })
    $bytesNeeded   = [long]($selectedBlobs | Measure-Object -Property Length -Sum).Sum
    $copyOnlyText  = if ($selected.CopyOnly) { ', copy-only' } else { '' }
    Write-Log ("Selected backup finished {0}{1}: {2} file(s), {3:N2} GB" -f $selected.Finished, $copyOnlyText, $selectedBlobs.Count, ($bytesNeeded / 1GB))
    foreach ($blob in $selectedBlobs) { Write-Log "  $($blob.Name)" }
    Complete-Step
    #endregion Storage

    #region Download
    Start-Step 'Download backup file(s) to local staging folder'
    if (-not (Test-Path -LiteralPath $LocalBackupPath)) {
        New-Item -ItemType Directory -Path $LocalBackupPath -WhatIf:$false | Out-Null
    }

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($LocalBackupPath))
    if (-not $root.StartsWith('\\')) {
        $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
        if ($freeBytes -lt ($bytesNeeded * 1.05)) {
            throw ("Not enough free space on {0}: need {1:N2} GB, have {2:N2} GB" -f $root, ($bytesNeeded / 1GB), ($freeBytes / 1GB))
        }
    }

    $downloadedAny = $false
    $localFiles = @(
        foreach ($blob in $selectedBlobs) {
            $target = Join-Path -Path $LocalBackupPath -ChildPath (($blob.Name -split '/')[-1])
            if ($PSCmdlet.ShouldProcess($blob.Name, "Download to $target")) {
                Get-AzStorageBlobContent -Container $ContainerName -Blob $blob.Name -Destination $target `
                    -Context $storageContext -Force | Out-Null
                $localLength = (Get-Item -LiteralPath $target).Length
                if ($localLength -ne $blob.Length) {
                    throw "Size mismatch for $($target): blob is $($blob.Length) bytes, local file is $localLength bytes"
                }
                $downloadedAny = $true
            }
            $target
        }
    )
    Complete-Step -Result $(if ($downloadedAny) { 'OK' } else { 'SKIPPED' })
    #endregion Download

    #region Restore
    Start-Step 'Restore database on destination'
    $target = "$DestinationInstance.[$DestinationDatabaseName]"

    if ($PSCmdlet.ShouldProcess($target, 'Take offline and restore WITH REPLACE')) {
        $existing = Get-DbaDatabase -SqlInstance $destination -Database $DestinationDatabaseName -EnableException
        if ($existing) {
            Write-Log "Taking $target offline (rolling back open transactions)"
            Set-DbaDbState -SqlInstance $destination -Database $DestinationDatabaseName -Offline -Force -EnableException | Out-Null
        }

        $restoreSplat = @{
            SqlInstance     = $destination
            Path            = $localFiles
            DatabaseName    = $DestinationDatabaseName
            WithReplace     = $true
            EnableException = $true
        }
        if ($DataDirectory) { $restoreSplat.DestinationDataDirectory = $DataDirectory }
        if ($LogDirectory)  { $restoreSplat.DestinationLogDirectory  = $LogDirectory }
        if ($DestinationDatabaseName -ne $DatabaseName) { $restoreSplat.ReplaceDbNameInFile = $true }

        $restoreResult = @(Restore-DbaDatabase @restoreSplat)
        if (-not ($restoreResult | Where-Object { $_.RestoreComplete })) {
            throw "Restore-DbaDatabase did not report a completed restore for $target"
        }
        $restored = $true
        Complete-Step
    }
    else {
        Complete-Step -Result 'SKIPPED'
    }
    #endregion Restore

    #region Post-restore
    if ($restored) {
        if ($DatabaseOwner) {
            Start-Step "Set database owner to $DatabaseOwner"
            Set-DbaDbOwner -SqlInstance $destination -Database $DestinationDatabaseName -TargetLogin $DatabaseOwner -EnableException | Out-Null
            Complete-Step
        }

        Start-Step 'Set PAGE_VERIFY CHECKSUM'
        Invoke-DbStatement -Instance $destination -Database $DestinationDatabaseName `
            -Statement 'ALTER DATABASE {DB} SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;'
        Complete-Step

        if ($CompatibilityLevel -gt 0) {
            Start-Step "Set compatibility level $CompatibilityLevel"
            Invoke-DbStatement -Instance $destination -Database $DestinationDatabaseName `
                -Statement "ALTER DATABASE {DB} SET COMPATIBILITY_LEVEL = $CompatibilityLevel;"
            Complete-Step
        }

        if ($RepairOrphanUsers) {
            Start-Step 'Repair orphaned users'
            Repair-DbaDbOrphanUser -SqlInstance $destination -Database $DestinationDatabaseName -EnableException | Out-Null
            Complete-Step
        }

        if ($UpdateStatistics) {
            Start-Step 'Update statistics'
            Invoke-DbStatement -Instance $destination -Database $DestinationDatabaseName `
                -Statement 'EXEC {DB}.sys.sp_updatestats;'
            Complete-Step
        }

        if ($RunCheckDb) {
            Start-Step 'DBCC CHECKDB WITH DATA_PURITY'
            Invoke-DbStatement -Instance $destination -Database $DestinationDatabaseName `
                -Statement 'DBCC CHECKDB ({DB}) WITH DATA_PURITY, NO_INFOMSGS, ALL_ERRORMSGS;'
            Complete-Step
        }

        if (-not $KeepLocalCopy) {
            Start-Step 'Remove local backup copy'
            foreach ($file in $localFiles) { Remove-Item -LiteralPath $file -Force }
            Complete-Step
        }
    }
    #endregion Post-restore

    $runSucceeded = $true
}
catch {
    if ($script:CurrentStep) { Complete-Step -Result 'FAILED' }
    Write-Log $_.Exception.Message -Level ERROR
    if ($localFiles.Count -gt 0) {
        Write-Log "Local backup file(s) kept in $LocalBackupPath for investigation" -Level WARN
    }
}
finally {
    $elapsed = (Get-Date) - $runStart
    Write-Log '---------------- Run summary ----------------'
    Write-Log "Source:       $SourceInstance.[$DatabaseName]"
    Write-Log "Destination:  $DestinationInstance.[$DestinationDatabaseName]"
    if ($selected) {
        Write-Log "Backup:       finished $($selected.Finished), $($selected.Files.Count) file(s), $([math]::Round($bytesNeeded / 1GB, 2)) GB"
    }
    foreach ($step in $script:Steps) {
        Write-Log ('{0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step)
    }
    $overall = if (-not $runSucceeded) { 'FAILED' } elseif ($restored) { 'SUCCEEDED' } else { 'DRY RUN' }
    Write-Log ("Result:       {0} in {1:hh\:mm\:ss}" -f $overall, $elapsed) -Level $(if ($runSucceeded) { 'INFO' } else { 'ERROR' })
}

if (-not $runSucceeded) { exit 1 }
