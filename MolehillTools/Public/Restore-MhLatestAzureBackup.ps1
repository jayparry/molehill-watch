#Requires -Version 5.1

<#
.SYNOPSIS
    Restores the newest full backup sitting in an Azure Blob Storage container onto a destination
    SQL Server, then tidies each copy up: users cleared out, owner set, recovery model set, and
    optionally users added back and the database made read-only.

.DESCRIPTION
    Molehill Data Services

    For keeping a set of databases refreshed from backups that are already in blob storage. There is
    no source SQL Server in this at all: the container is the source of truth, and the newest backup
    found in each database's folder is the one restored.

    The container is expected to be laid out one folder per database:

        FULL/DAILY/<database name>/<something>.bak

    so -Database Sales,Stock reads FULL/DAILY/Sales/ and FULL/DAILY/Stock/ and takes the
    newest .bak from each. -BlobPathPattern changes that shape if yours differs.

    WHAT HAPPENS TO EACH DATABASE
      1. The newest backup in its folder is downloaded to the staging folder and its header read,
         which proves it is a full backup of the database it claims to be and that the destination
         can read the file at all.
      2. Anything of that name on the destination is taken offline and restored over.
      3. Then, straight away, before the next database is downloaded:
           * every user is dropped except the built-in ones (dbo, guest, INFORMATION_SCHEMA, sys)
             and the fixed roles. A user owning a schema has that schema handed to dbo first,
             because otherwise it cannot be dropped. Anything that still refuses is reported with
             the reason rather than passed over in silence.
           * the owner is set to sa
           * the recovery model is set to SIMPLE
           * -AddUser creates the users you name, assuming each login already exists on the
             destination - and warning, rather than failing, where one does not
           * -EnableTde encrypts it, and waits for the encryption to finish
           * -ReadOnly, last of all, sets the database read-only

    Each copy is dealt with as soon as it is restored rather than at the end of the run, so a copy
    of production does not sit with its production users still in it, and unencrypted, while the
    rest of the list downloads.

    The order within that matters and is deliberate: the users it came with go first, because that
    is what closes off access; the owner follows, so nothing clashes with sa; and read-only is left
    until the very end, because a read-only database cannot be changed further - and that includes
    creating an encryption key.

    Needs the Az.Storage module and nothing else; the restores are plain T-SQL.

    THE STAGING FOLDER
    -LocalBackupPath has to be readable by the destination SQL Server SERVICE ACCOUNT, not just by
    you. A path under C:\Users will not do. The easiest arrangement is to run this on the
    destination server with a staging folder on one of its own drives.


.PARAMETER DestinationInstance
    The instance to restore onto.

.PARAMETER Database
    One or more database names. Each names both the folder to read in the container and the
    database to restore onto the destination.

.PARAMETER StorageAccountName
    The storage account holding the backups. The account name on its own, not a URL.

.PARAMETER ContainerName
    The blob container.

.PARAMETER SasToken
    A Shared Access Signature with at least Read and List permission on the container. Takes a
    plain string or a SecureString; a leading '?' is removed. Wrap a plain string in SINGLE quotes -
    SAS tokens contain '&', which PowerShell treats as an operator otherwise.

.PARAMETER BlobPathPattern
    Where to look inside the container, with {db} standing in for the database name. Default
    'FULL/DAILY/{db}/'. Backslashes are accepted and turned into the forward slashes blob storage
    actually uses.

.PARAMETER LocalBackupPath
    Staging folder for the downloaded backup. Created if missing. Must be readable by the
    destination SQL Server service account.

.PARAMETER DataPath
    Where to put the data files. Default: the destination instance's own default data path.

.PARAMETER LogPath
    Where to put the log file. Default: the destination instance's own default log path.

.PARAMETER Owner
    The login to make the database owner. Default 'sa'. If there is no login of that name, the
    login that really is the system administrator (principal 1) is used and the substitution is
    reported - that covers an instance where sa has been renamed.

.PARAMETER RecoveryModel
    The recovery model to set once restored. Default SIMPLE.

.PARAMETER AddUser
    Users to create, each mapped to a login of the same name that is expected to exist already. A
    missing login is a warning, not a failure.

    An entry can name which database it is for, so one user need not go into all of them. Three
    shapes are accepted, and they can be mixed:

      'BiTeam'                             every database in -Database
      'Sales:BiTeam:db_datareader'         that database only, with that role
      @{ Database = 'Sales'; User = 'REPORTS\BiTeam'; Role = 'db_datareader', 'db_datawriter' }

    The colon form exists because powershell.exe -File turns every argument into a string and
    cannot pass a hashtable at all, which is what a scheduled task will be doing. Use '*' as the
    database to mean all of them. Roles can be comma separated inside the third part. Naming a
    database that is not in -Database is refused up front rather than quietly doing nothing.

.PARAMETER AddUserRole
    The role or roles to use for entries that do not name their own, e.g. db_datareader, db_owner.
    Without a role a user is created with no permissions at all, which is rarely what anyone wants.

.PARAMETER ReadOnly
    Set each database read-only once everything else is done.

.PARAMETER KeepUsers
    Leave the existing users alone instead of clearing them out.

.PARAMETER EnableTde
    Encrypt each copy with Transparent Data Encryption as soon as it is restored, with AES-256, and
    wait for the encryption to finish before moving on.

    The destination has to be ready for it first, which is a one-off: a database master key in
    master, and a server certificate for -TdeCertificateName to protect the per-database keys with.
    This refuses before anything is restored, with the statements to run, rather than creating keys
    whose backup nobody has taken.

        USE master;
        CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<a long random string>';
        CREATE CERTIFICATE MolehillTde WITH SUBJECT = 'TDE certificate for restored copies';
        BACKUP MASTER KEY TO FILE = 'D:\Keys\dmk.key' ENCRYPTION BY PASSWORD = '<another>';
        BACKUP CERTIFICATE MolehillTde TO FILE = 'D:\Keys\MolehillTde.cer'
            WITH PRIVATE KEY (FILE = 'D:\Keys\MolehillTde.pvk', ENCRYPTION BY PASSWORD = '<a third>');

    Keep those backups and their passwords somewhere that is not that server. Without the
    certificate no instance can restore or attach these databases - which for a disposable copy
    means re-running this script, but for anything else means the data is gone.

    Editions: Standard, Enterprise, Developer and Evaluation. SQL Server 2019 is what brought it to
    Standard; before that it is Enterprise or Developer only. Express does not have it at any
    version, and this says so rather than letting the restore run and the encryption fail.

    It encrypts tempdb for the whole instance as a side effect, permanently, which affects every
    other database on that instance.

.PARAMETER TdeCertificateName
    The server certificate in master that protects each database's encryption key. Default
    MolehillTde. It must already exist.

.PARAMETER TdeWaitMinutes
    How long to wait for a database's encryption to finish before moving on, in minutes. Default
    60. The encryption itself carries on in the background either way; what a timeout costs is
    -ReadOnly, which is skipped rather than applied to a database still being encrypted.

.PARAMETER KeepLocalCopy
    Keep the downloaded backup files instead of deleting them after a successful restore.

.PARAMETER Force
    Overwrite a database on the destination even when it was not put there by this script.

.PARAMETER SqlCredential
    SQL authentication for the destination. Windows authentication is used when this is left out.

.PARAMETER TrustServerCertificate
    Trust the server certificate, which an instance with a self-signed one needs.

.PARAMETER LogLevel
    How much to say. Quiet = problems and the summary only. Normal = each step and the decisions
    behind it (default). Verbose = every blob considered and every statement. Debug = Verbose plus
    raw exceptions and SQL error numbers. -Verbose or -Debug raise it by themselves.

.PARAMETER LogFile
    Append the same output to this file.

.PARAMETER CsvPath
    Write one row per database, with the outcome, to a CSV file.

.PARAMETER InstallMissingModules
    Install Az.Storage for the current user if it is missing.


.EXAMPLE
    Restore-MhLatestAzureBackup -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging

.EXAMPLE
    # refreshed, tidied, and handed to the reporting team read-only
    Restore-MhLatestAzureBackup -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser REPORTS\BiTeam -AddUserRole db_datareader -ReadOnly

.EXAMPLE
    # encrypted as each one lands, then handed over read-only
    Restore-MhLatestAzureBackup -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging -EnableTde -ReadOnly

.EXAMPLE
    # the reporting team on Sales only, the application account on both
    Restore-MhLatestAzureBackup -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser 'Sales:REPORTS\BiTeam:db_datareader', 'AppSvc' -AddUserRole db_datawriter

.EXAMPLE
    Restore-MhLatestAzureBackup -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging -WhatIf
    # lists the backup it would use and the statements it would run, and changes nothing

.NOTES
    Molehill Data Services. The container is only ever read. On the destination, the named databases
    are overwritten - that is the point - so check the names.
#>

function Restore-MhLatestAzureBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Position = 0)] [string] $DestinationInstance,
        [Parameter(Position = 1)] [Alias('DatabaseName')] [string[]] $Database,

        # the container
        [string] $StorageAccountName,
        [string] $ContainerName,
        [object] $SasToken,
        [string] $BlobPathPattern = 'FULL/DAILY/{db}/',
        [string] $LocalBackupPath,
        [switch] $KeepLocalCopy,
        [switch] $InstallMissingModules,

        # where the restored files go
        [Alias('DataDirectory')] [string] $DataPath,
        [Alias('LogDirectory')] [string] $LogPath,

        # what to do with each copy afterwards
        [string] $Owner = 'sa',
        [ValidateSet('SIMPLE', 'FULL', 'BULK_LOGGED')] [string] $RecoveryModel = 'SIMPLE',
        [object[]] $AddUser,
        [string[]] $AddUserRole,
        [switch] $ReadOnly,
        [switch] $KeepUsers,
        [switch] $EnableTde,
        [string] $TdeCertificateName = 'MolehillTde',
        [ValidateRange(1, 1440)] [int] $TdeWaitMinutes = 60,

        # connecting
        [PSCredential] $SqlCredential,
        [switch] $TrustServerCertificate,
        [ValidateRange(1, 300)] [int] $ConnectTimeoutSeconds = 15,

        # saying what happened
        [ValidateSet('Quiet', 'Normal', 'Verbose', 'Debug')] [string] $LogLevel = 'Normal',
        [string] $LogFile,
        [string] $CsvPath,
        [switch] $Force
    )

    $ErrorActionPreference = 'Stop'

    # the module's log, started for this run: -Verbose and -Debug raise the level on their own, which
    # is why it is handed $PSBoundParameters rather than being asked to work that out
    Initialize-MhLog -Level $LogLevel -LogFile $LogFile -BoundParameters $PSBoundParameters

    # the functions at module scope cannot see this function's parameters, so this run's settings are
    # copied where they can see them - every run, so nothing carries over from the last one
    $script:AzureDestinationSqlCredential = $SqlCredential
    $script:AzureTrustServerCertificate = $TrustServerCertificate
    $script:AzureConnectTimeoutSeconds = $ConnectTimeoutSeconds
    $script:AzureKeepUsers = $KeepUsers
    $script:AzureRecoveryModel = $RecoveryModel
    $script:AzureReadOnly = $ReadOnly
    $script:AzureEnableTde = $EnableTde
    $script:AzureTdeCertificateName = $TdeCertificateName
    $script:AzureTdeWaitMinutes = $TdeWaitMinutes
    $ErrorActionPreference = 'Stop'

    if (-not $DestinationInstance) {
        Stop-AzureRun "-DestinationInstance is needed. Get-Help Restore-MhLatestAzureBackup -Detailed shows what goes with it."
    }
    $named = @($Database | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($named.Count -eq 1 -and $named[0] -match ',') { $named = @($named[0] -split ',') }
    $databases = @($named | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($databases.Count -eq 0) {
        Stop-AzureRun '-Database is needed (one name, or several).'
    }
    foreach ($required in 'StorageAccountName', 'ContainerName', 'LocalBackupPath') {
        if (-not (Get-Variable -Name $required -ValueOnly)) {
            Stop-AzureRun "-$required is needed."
        }
    }
    if ($null -eq $SasToken) { Stop-AzureRun '-SasToken is needed.' }
    if ($AddUserRole -and -not $AddUser) {
        Stop-AzureRun '-AddUserRole only means something with -AddUser.'
    }
    $script:AzureuserGrants = @()
    if ($AddUser) {
        try { $resolved = Resolve-AzureUserGrant -Entries $AddUser -DefaultRoles $AddUserRole -Databases $databases }
        catch {
            Stop-AzureRun ($_.Exception.Message -split "`r?`n")[0]
        }
        if ($resolved.Unknown.Count) {
            Stop-AzureRun ('-AddUser names database(s) that are not in -Database: ' + ($resolved.Unknown -join '; ') +
                           '. The databases being restored are: ' + ($databases -join ', '))
        }
        $script:AzureuserGrants = $resolved.Grants
    }
    $DestinationInstance = $DestinationInstance.Trim()
    $dryRun = $WhatIfPreference -eq $true
    $script:AzureBlobList = $null
    $runStart = Get-Date
    $setupDone = $false
    $results = New-Object System.Collections.Generic.List[object]
    $restoredOk = New-Object System.Collections.Generic.List[object]
    try {
        Write-MhLog ("Restore {0} database(s) onto {1} from {2}/{3}" -f $databases.Count, $DestinationInstance, $StorageAccountName, $ContainerName)
        Write-MhLog ('Databases: ' + ($databases -join ', '))
        Write-MhDetail "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) as $([Environment]::UserDomainName)\$([Environment]::UserName) on $env:COMPUTERNAME; log level $LogLevel"
        if ($dryRun) { Write-MhLog 'WhatIf mode: the statements below are printed, not run' -Level WARN }

        #region The destination
        Start-MhStep 'Check the destination'
        $check = Test-MhSqlConnectivity -Instance $DestinationInstance -Credential $SqlCredential `
                                      -Trust:$script:AzureTrustServerCertificate -TimeoutSeconds $script:AzureConnectTimeoutSeconds
        Write-MhConnectivityReport -Result $check -Role 'destination'
        if (-not $check.Connected) {
            throw ("Cannot connect to $DestinationInstance. The checks above say why; -LogLevel Verbose shows every step and Debug the raw errors.")
        }

        $dstInfo = (Invoke-AzureSql -Server $DestinationInstance -Query "SELECT ServerName = CONVERT(nvarchar(128), SERVERPROPERTY('ServerName')), Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), DataPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultDataPath')), LogPath = CONVERT(nvarchar(512), SERVERPROPERTY('InstanceDefaultLogPath'))").Rows[0]
        $defaultData = [string]$dstInfo['DataPath']
        $defaultLog = [string]$dstInfo['LogPath']
        if (-not $defaultData -or -not $defaultLog) {
            $mf = Invoke-AzureSql -Server $DestinationInstance -Query "SELECT Type = type_desc, Path = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name))) FROM sys.master_files WHERE database_id = 1"
            foreach ($r in $mf.Rows) {
                if (-not $defaultData -and [string]$r['Type'] -eq 'ROWS') { $defaultData = [string]$r['Path'] }
                if (-not $defaultLog -and [string]$r['Type'] -eq 'LOG') { $defaultLog = [string]$r['Path'] }
            }
        }
        if ($DataPath) { $defaultData = $DataPath }
        if ($LogPath) { $defaultLog = $LogPath }
        Write-MhDetail ('  restored files go to {0}{1}' -f $defaultData, $(if ($defaultLog -ne $defaultData) { " and $defaultLog" } else { '' }))

        # asked now rather than per database, and before anything is downloaded: a destination that
        # cannot encrypt should say so while nothing has been restored onto it yet
        if ($script:AzureEnableTde) {
            $tdeReady = Test-AzureTdeReadiness -Server $DestinationInstance -CertificateName $script:AzureTdeCertificateName
            if (-not $tdeReady.Ok) {
                $lines = @("{0} is not set up for TDE, so nothing has been restored:" -f $DestinationInstance)
                foreach ($problem in $tdeReady.Problems) { $lines += "  * $problem" }
                throw ($lines -join "`n")
            }
            Write-MhLog ('TDE: the certificate {0} is there ({1})' -f $script:AzureTdeCertificateName, $tdeReady.Subject)
            Write-MhDetail ('  thumbprint {0}{1}' -f $tdeReady.Thumbprint,
                          $(if ($tdeReady.Expiry) { ', expires ' + (Format-AzureStamp $tdeReady.Expiry) } else { '' }))
            Write-MhLog '  that certificate and the master key behind it are the only way these databases can ever be read again. Back both up, with their passwords, somewhere that is not this server.' -Level WARN
        }

        # the owner is wanted on every copy, so settle it once and say so now rather than per database
        $ownerLogin = Resolve-AzureOwnerLogin -Server $DestinationInstance -Wanted $Owner
        if (-not $ownerLogin.Login) {
            Write-MhLog ("There is no login called '{0}' on {1} and no principal 1 either, so the owner will be left as restored." -f $Owner, $DestinationInstance) -Level WARN
        }
        elseif ($ownerLogin.Substituted) {
            Write-MhLog ("There is no login called '{0}', so the system administrator login '{1}' will be used instead." -f $Owner, $ownerLogin.Login) -Level WARN
        }
        Complete-MhStep
        #endregion

        #region The container
        Start-MhStep 'Open the storage container'
        $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
        if ($found.Count -eq 0) {
            if (-not $InstallMissingModules) {
                Write-MhDeep ('module search path: ' + ($env:PSModulePath -split ';' -join ' | '))
                throw ("The Az.Storage module is not installed for $($PSVersionTable.PSEdition) PowerShell $($PSVersionTable.PSVersion). " +
                       'Re-run with -InstallMissingModules, or: Install-Module Az.Storage -Scope CurrentUser. ' +
                       'Modules installed for Windows PowerShell 5.1 are not visible to PowerShell 7, or the other way round, so check which one you are in.')
            }
            Write-MhLog 'Installing Az.Storage for the current user'
            Install-Module -Name Az.Storage -Scope CurrentUser -Force -AllowClobber -WhatIf:$false
            $found = @(Get-Module -ListAvailable -Name Az.Storage | Sort-Object Version -Descending)
        }
        Write-MhDetail ('  Az.Storage {0} from {1}' -f $found[0].Version, $found[0].ModuleBase)
        # Import-Module has no -WhatIf of its own, but the preference reaches inside the module
        $savedWhatIf = $WhatIfPreference
        try { $WhatIfPreference = $false; Import-Module -Name Az.Storage -Verbose:$false }
        finally { $WhatIfPreference = $savedWhatIf }

        $script:AzureBlobList = Connect-AzureBlobContainer -AccountName $StorageAccountName -Container $ContainerName `
                                              -Prefix '' -Sas $SasToken

        if (-not (Test-Path -LiteralPath $LocalBackupPath)) {
            Write-MhDetail "  creating $LocalBackupPath"
            New-Item -ItemType Directory -Path $LocalBackupPath -WhatIf:$false | Out-Null
        }
        if ($LocalBackupPath -match '^[A-Za-z]:\\Users\\') {
            Write-MhLog 'The staging folder is inside a user profile. The SQL Server service account usually cannot read there, which fails the header check - a folder on one of the server''s own drives is safer.' -Level WARN
        }
        Complete-MhStep
        #endregion

        $setupDone = $true
        $allBlobs = @($script:AzureBlobList.All)

        #==========================================================================
        # Restore each database. A failure on one is recorded and the rest carry on.
        #==========================================================================
        foreach ($dbName in $databases) {
            Set-MhLogPrefix $(if ($databases.Count -gt 1) { $dbName } else { '' })
            $outcome = [pscustomobject]@{
                Database = $dbName; DestinationInstance = $DestinationInstance; Result = 'FAILED'
                Backup = $null; BackupTaken = $null; Bytes = 0; Users = $null; Encryption = $null; Detail = $null
            }
            $staged = New-Object System.Collections.Generic.List[string]
            $restored = $false

            try {
                Write-MhLog ('---- {0} ----' -f $dbName)

                #region Find it
                Start-MhStep 'Find the newest backup in the container'
                $prefix = Get-AzureBlobPrefix -Pattern $BlobPathPattern -DatabaseName $dbName
                Write-MhDetail ("  looking under {0}/{1}" -f $ContainerName, $prefix)
                $inFolder = @($allBlobs | Where-Object { ([string]$_.Name).Replace('\', '/').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
                foreach ($b in $inFolder) { Write-MhDeep ('  {0} ({1}, {2})' -f $b.Name, (Format-MhSize $b.Length), (Format-AzureStamp $b.LastModified -Utc)) }

                $pick = Select-AzureLatestBackupBlob -Blobs $inFolder
                if (-not $pick.Chosen) {
                    throw ("Nothing to restore: no .bak under {0}/{1} ({2} blob(s) in that folder altogether). Check -BlobPathPattern and the database name." -f
                           $ContainerName, $prefix, $inFolder.Count)
                }
                $blob = $pick.Chosen
                Write-MhLog ('Newest backup: {0} ({1}, written {2})' -f $blob.Name, (Format-MhSize $blob.Length), (Format-AzureStamp $blob.LastModified -Utc))
                $outcome.Backup = $blob.Name
                if ($pick.Siblings.Count) {
                    Write-MhDetail ('  {0} other file(s) written within two minutes of it, which may be stripes of the same backup' -f $pick.Siblings.Count)
                }
                Complete-MhStep
                #endregion

                #region Download it
                Start-MhStep 'Download the backup'
                $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($LocalBackupPath))
                if (-not $root.StartsWith('\\')) {
                    $freeBytes = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
                    Write-MhDetail ('  {0} has {1} free; the backup is {2}' -f $root, (Format-MhSize $freeBytes), (Format-MhSize $blob.Length))
                    if ($freeBytes -lt ($blob.Length * 1.05)) {
                        throw ('Not enough free space on {0}: need about {1}, have {2}' -f $root, (Format-MhSize ($blob.Length * 1.05)), (Format-MhSize $freeBytes))
                    }
                }
                $localFiles = @()
                if ($PSCmdlet.ShouldProcess($blob.Name, "Download to $LocalBackupPath")) {
                    $target = Join-Path -Path $LocalBackupPath -ChildPath (($blob.Name -split '/')[-1])
                    $outcome.Bytes = Get-MhBlobToFile -Context $script:AzureBlobList.Context -Container $ContainerName -Blob $blob -TargetPath $target
                    $staged.Add($target)
                    $localFiles = @($target)
                }
                Complete-MhStep -Result $(if ($localFiles.Count) { 'OK' } else { 'SKIPPED' })
                #endregion

                if ($dryRun) {
                    Write-MhLog ('Would restore {0} over {1}.[{2}], then clear its users, set the owner and the recovery model{3}{4}' -f
                               $blob.Name, $DestinationInstance, $dbName,
                               $(if ($script:AzureEnableTde) { ', encrypt it with TDE' } else { '' }),
                               $(if ($script:AzureReadOnly) { ', and make it read-only' } else { '' }))
                    $outcome.Result = 'DRY RUN'
                    continue
                }

                #region Prove it is what it says
                Start-MhStep 'Read the backup header'
                # before the existing database is touched: an unreadable staging folder or the wrong
                # file shows up here, while nothing is broken yet
                $deviceList = (@($localFiles) | ForEach-Object { "DISK = N'" + (Esc-MhStr $_) + "'" }) -join ', '
                try { $header = Invoke-AzureSql -Server $DestinationInstance -Query "RESTORE HEADERONLY FROM $deviceList" }
                catch {
                    $exception = $_.Exception.GetBaseException()
                    $number = 0
                    if ($exception -is [System.Data.SqlClient.SqlException]) { $number = $exception.Number }
                    if ($exception.Message -match 'Operating system error 5|Cannot open backup device') { $number = 3201 }
                    $explain = Get-MhSqlErrorExplanation -Number $number -Message $exception.Message
                    Write-MhDeep ('  header exception: ' + $exception.ToString())
                    throw ('Could not read the backup header: ' + ($exception.Message -split "`r?`n")[0] + $(if ($explain.Fix) { " $($explain.Fix)" } else { '' }))
                }
                $row = $header.Rows[0]
                $backupType = [int]$row['BackupType']
                $families = [int]$row['FamilyCount']
                $inside = [string]$row['DatabaseName']
                $taken = ConvertTo-MhUtcTime $row['BackupFinishDate']
                $outcome.BackupTaken = $taken
                Write-MhLog ('The file holds a {0} backup of [{1}], finished {2}, from SQL Server major version {3}' -f
                           $(switch ($backupType) { 1 { 'full' } 2 { 'transaction log' } 5 { 'differential' } default { "type $backupType" } }),
                           $inside, (Format-AzureStamp $taken), $row['SoftwareVersionMajor'])

                if ($backupType -ne 1) {
                    throw ("that is not a full backup, so it cannot be restored on its own. The newest file under {0} is a {1}." -f
                           $prefix, $(switch ($backupType) { 2 { 'transaction log backup' } 5 { 'differential backup' } default { "backup of type $backupType" } }))
                }
                if ($families -gt 1) {
                    throw ("that backup was written across {0} files (a striped backup) and only one of them is here. All {0} have to be restored together: name them in the container so they can be told apart, or take the backup to a single file." -f $families)
                }
                if ($inside -ne $dbName) {
                    Write-MhLog ("The backup is of [{0}] but it was found in the folder for [{1}] and will be restored as [{1}]. Check the container layout if that is not intended." -f $inside, $dbName) -Level WARN
                }
                if ([int]$row['SoftwareVersionMajor'] -gt [int]$dstInfo['Major']) {
                    throw ('the backup was taken on SQL Server major version {0} and {1} is version {2}: a backup cannot be restored onto an older version' -f
                           $row['SoftwareVersionMajor'], $DestinationInstance, $dstInfo['Major'])
                }
                Complete-MhStep
                #endregion

                #region Restore it
                Start-MhStep 'Restore it'
                $existing = Invoke-AzureSql -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                            'SELECT state_desc, user_access_desc, is_read_only FROM sys.databases WHERE name = @db'
                $isThere = $existing.Rows.Count -gt 0
                if ($isThere) {
                    $wasReadOnly = [bool]$existing.Rows[0]['is_read_only']
                    Write-MhDetail ('  the existing copy is {0}{1}' -f ([string]$existing.Rows[0]['state_desc']).ToLower(), $(if ($wasReadOnly) { ', read-only' } else { '' }))

                    $restoredHere = Get-AzureScalar -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                                    'SELECT TOP (1) 1 FROM msdb.dbo.restorehistory WHERE destination_database_name = @db'
                    if (-not $restoredHere -and -not $Force) {
                        throw ("{0} already exists on {1} and this instance has no record of restoring it, so it has not been touched. Check the name, or use -Force to overwrite it anyway." -f $dbName, $DestinationInstance)
                    }
                    Write-MhLog "Taking $dbName offline (rolling back open transactions)"
                    [void](Invoke-AzureSql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET OFFLINE WITH ROLLBACK IMMEDIATE;' -f (Esc-MhName $dbName)))
                }
                else { Write-MhDetail '  nothing of that name on the destination yet' }

                # where its files should land
                $fileList = Invoke-AzureSql -Server $DestinationInstance -Query ("RESTORE FILELISTONLY FROM $deviceList")
                $moveList = @{}
                foreach ($f in $fileList.Rows) {
                    $moveList[[string]$f['LogicalName']] = Get-MhMoveTarget -PhysicalName ([string]$f['PhysicalName']) -FileType ([string]$f['Type']) `
                                                            -DataPath $defaultData -LogPath $defaultLog -SourceDatabase $inside -DestinationDatabase $dbName
                }
                foreach ($file in $moveList.Values) {
                    $owner = Get-AzureScalar -Server $DestinationInstance -Parameters @{ '@p' = $file } -Query `
                             'SELECT DB_NAME(database_id) FROM sys.master_files WHERE physical_name = @p'
                    if ($owner -and [string]$owner -ne $dbName) {
                        throw ("the file {0} already belongs to the database {1} on {2}. Use -DataPath / -LogPath to put the copy somewhere else." -f $file, $owner, $DestinationInstance)
                    }
                }
                Write-MhDetail ('  {0} file(s) to {1}' -f $moveList.Count, $defaultData)

                $set = [pscustomobject]@{ Position = [int]$row['Position']; Files = $localFiles; HasChecksums = $true }
                $sql = New-MhRestoreCommand -Database $dbName -BackupSet $set -Kind 'Database' -Finish 'RECOVERY' `
                           -MoveList $moveList -Replace:$isThere
                $r = Invoke-AzureLongSql -Server $DestinationInstance -Sql $sql -Label 'restore'
                if (-not $r.Ok) {
                    if ($isThere) {
                        Write-MhLog "The restore failed; putting $dbName back online" -Level WARN
                        try { [void](Invoke-AzureSql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET ONLINE;' -f (Esc-MhName $dbName))) }
                        catch { Write-MhLog ('  could not bring it back online: ' + $_.Exception.Message) -Level ERROR }
                    }
                    throw ('the restore failed: ' + $r.Error)
                }
                $restored = $true
                $size = if ($r.Megabytes) { ', ' + (Format-MhSize ($r.Megabytes * 1MB)) } else { '' }
                Write-MhLog ('Restored in {0}s{1}' -f $r.Seconds, $size)

                # a copy of a database that was closed off comes back closed off
                $after = (Invoke-AzureSql -Server $DestinationInstance -Parameters @{ '@db' = $dbName } -Query `
                          'SELECT state_desc, user_access_desc, is_read_only FROM sys.databases WHERE name = @db').Rows[0]
                if ([string]$after['state_desc'] -ne 'ONLINE') { throw ('the restore finished but the database is {0} rather than online' -f $after['state_desc']) }
                if ([bool]$after['is_read_only']) {
                    [void](Invoke-AzureSql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET READ_WRITE;' -f (Esc-MhName $dbName)))
                    Write-MhDetail '  the backup was taken read-only, so the copy has been set read-write for the tidying up'
                }
                if ([string]$after['user_access_desc'] -ne 'MULTI_USER') {
                    [void](Invoke-AzureSql -Server $DestinationInstance -Query ('ALTER DATABASE {0} SET MULTI_USER;' -f (Esc-MhName $dbName)))
                    Write-MhDetail ('  the backup was taken {0}, so the copy has been opened up to MULTI_USER' -f ([string]$after['user_access_desc']).ToLower())
                }
                Complete-MhStep
                #endregion

                if (-not $KeepLocalCopy -and $staged.Count) {
                    Start-MhStep 'Remove the staged copy'
                    foreach ($file in $staged) {
                        Write-MhDetail "  removing $file"
                        try { Remove-Item -LiteralPath $file -Force } catch { Write-MhLog ('  could not remove ' + $file + ': ' + $_.Exception.Message) -Level WARN }
                    }
                    Complete-MhStep
                }
                $outcome.Result = 'RESTORED'
                $restoredOk.Add($dbName)

                # and straight on to settling it, in this same pass, rather than at the end of the run
                try {
                    Complete-AzureRestoredDatabase -Server $DestinationInstance -DatabaseName $dbName -Outcome $outcome `
                        -OwnerLogin $ownerLogin -Grants @($script:AzureuserGrants | Where-Object { $_.Database -eq $dbName })
                }
                catch {
                    if (Test-MhStepOpen) { Complete-MhStep -Result 'FAILED' }
                    $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
                    Write-MhLog ('[{0}] restored, but the tidying up failed: {1}' -f $dbName, $message) -Level ERROR
                    Write-MhDeep ('full exception: ' + $_.Exception.ToString())
                    $outcome.Result = 'RESTORED, NOT TIDIED'
                    $outcome.Detail = $message
                }
            }
            catch {
                if (Test-MhStepOpen) { Complete-MhStep -Result 'FAILED' }
                $exception = $_.Exception.GetBaseException()
                $outcome.Result = 'FAILED'
                $outcome.Detail = ($exception.Message -split "`r?`n")[0]
                Write-MhLog ('[{0}] {1}' -f $dbName, $outcome.Detail) -Level ERROR
                if ($exception -is [System.Data.SqlClient.SqlException]) {
                    $explain = Get-MhSqlErrorExplanation -Number $exception.Number -Message $exception.Message
                    if ($explain.Meaning) { Write-MhLog ('  what it means: ' + $explain.Meaning) -Level ERROR }
                    if ($explain.Fix) { Write-MhLog ('  what to try: ' + $explain.Fix) -Level WARN }
                }
                Write-MhDeep ('full exception: ' + $exception.ToString())
                if ($_.ScriptStackTrace) { Write-MhDeep ('at: ' + $_.ScriptStackTrace) }
                if ($staged.Count -and -not $restored) { Write-MhLog ('  the staged file has been left in {0} for investigation' -f $LocalBackupPath) -Level WARN }
                if ($databases.Count -gt 1) { Write-MhLog '  carrying on with the remaining database(s)' -Level WARN }
            }
            finally {
                Set-MhLogPrefix ''
                $results.Add($outcome)
            }
        }

    }
    catch {
        if (Test-MhStepOpen) { Complete-MhStep -Result 'FAILED' }
        $exception = $_.Exception.GetBaseException()
        Write-MhLog ($exception.Message -split "`r?`n")[0] -Level ERROR
        foreach ($extra in @(($exception.Message -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() })) {
            Write-MhLog "  $extra" -Level ERROR
        }
        Write-MhDeep ('full exception: ' + $exception.ToString())
        if ($_.ScriptStackTrace) { Write-MhDeep ('at: ' + $_.ScriptStackTrace) }
        if (-not (Test-MhLogAtLeast 'Verbose')) {
            Write-MhLog 'Run again with -LogLevel Verbose (or Debug) for more.' -Level WARN
        }
    }
    finally {
        $elapsed = (Get-Date) - $runStart
        Write-MhLog '---------------- Run summary ----------------' -Min Quiet
        Write-MhLog "Destination:  $DestinationInstance" -Min Quiet
        Write-MhLog "Container:    $StorageAccountName/$ContainerName" -Min Quiet
        if (-not $dryRun -and $restoredOk.Count) {
            Write-MhLog ("Applied to each: {0}owner {1}, recovery {2}{3}{4}{5}" -f
                       $(if ($script:AzureKeepUsers) { 'users left alone, ' } else { 'users cleared, ' }),
                       $(if ($ownerLogin -and $ownerLogin.Login) { $ownerLogin.Login } else { 'unchanged' }),
                       $script:AzureRecoveryModel,
                       $(if ($script:AzureuserGrants.Count) { ', users added per database' } else { '' }),
                       $(if ($script:AzureEnableTde) { ', TDE with ' + $script:AzureTdeCertificateName } else { '' }),
                       $(if ($script:AzureReadOnly) { ', read-only' } else { '' })) -Min Quiet
        }
        foreach ($outcome in $results) {
            $line = '{0,-20} {1}' -f $outcome.Result, $outcome.Database
            if ($outcome.BackupTaken) { $line += ' (backup of {0})' -f (Format-AzureStamp $outcome.BackupTaken) }
            elseif ($outcome.Backup) { $line += ' ({0})' -f $outcome.Backup }
            $granted = @($script:AzureuserGrants | Where-Object { $_.Database -eq $outcome.Database } | ForEach-Object { $_.User })
            if ($granted.Count) { $line += ' [+' + ($granted -join ', ') + ']' }
            if ($outcome.Encryption) { $line += ' [' + $outcome.Encryption + ']' }
            if ($outcome.Detail) { $line += ' - ' + $outcome.Detail }
            Write-MhLog $line -Level $(if ($outcome.Result -like 'FAILED*') { 'ERROR' } elseif ($outcome.Result -like '*NOT TIDIED*') { 'WARN' } else { 'INFO' }) -Min Quiet
        }
        if (Test-MhLogAtLeast 'Normal') {
            foreach ($step in (Get-MhLogStep)) { Write-MhLog ('  {0,-8} {1,8} s  {2}' -f $step.Result, $step.Seconds, $step.Step) }
        }
        $failedCount = @($results | Where-Object { $_.Result -like 'FAILED*' -or $_.Result -like '*NOT TIDIED*' }).Count
        $doneCount = @($results | Where-Object { $_.Result -in 'DONE', 'RESTORED', 'DRY RUN' }).Count
        $overall = if (-not $setupDone) { 'FAILED BEFORE STARTING' }
                   elseif ($failedCount -gt 0 -and $doneCount -gt 0) { "PARTLY DONE ($doneCount of $($results.Count))" }
                   elseif ($failedCount -gt 0) { 'FAILED' }
                   elseif ($dryRun) { 'DRY RUN' }
                   elseif ($doneCount -gt 0) { 'DONE' }
                   else { 'NOTHING DONE' }
        $bad = (-not $setupDone) -or $failedCount -gt 0
        Write-MhLog ('Result:       {0} in {1:hh\:mm\:ss}' -f $overall, $elapsed) -Level $(if ($bad) { 'ERROR' } else { 'INFO' }) -Min Quiet
        if ($LogFile) { Write-MhLog "Log file:     $LogFile" -Min Quiet }
        if ($CsvPath -and $results.Count) {
            $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
            Write-MhLog "Saved to      $CsvPath" -Min Quiet
        }
    }
    # the shim turns this into an exit code; a caller gets every database's outcome
    [pscustomobject]@{
        DestinationInstance = $DestinationInstance
        StorageAccountName  = $StorageAccountName
        ContainerName       = $ContainerName
        Databases           = $results.ToArray()   # @() on a generic list throws
        Steps               = @(Get-MhLogStep)
        Result              = $overall
        DryRun              = [bool]$dryRun
        Elapsed             = $elapsed
        Ok                  = -not $bad
    }
}

function Connect-AzureBlobContainer {
    [CmdletBinding()]
    param([string] $AccountName, [string] $Container, [string] $Prefix, [object] $Sas)

    # a quick name check first: an account that does not exist otherwise takes Azure's six retries
    # and the best part of half a minute to say so
    try { [void][System.Net.Dns]::GetHostAddresses("$AccountName.blob.core.windows.net") }
    catch {
        throw "The storage account '$AccountName' does not resolve ($AccountName.blob.core.windows.net). Check the name - it is the account name on its own, not a URL."
    }

    $sasPlain = ConvertTo-MhPlainSas -Token $Sas
    Write-MhDeep ('  SAS parameters present: ' + (($sasPlain -split '&' | ForEach-Object { ($_ -split '=')[0] }) -join ', '))
    $context = New-AzStorageContext -StorageAccountName $AccountName -SasToken $sasPlain
    $sasPlain = $null

    $listSplat = @{ Container = $Container; Context = $context }
    if ($Prefix) { $listSplat.Prefix = $Prefix.Trim('/') + '/' }
    try { $blobs = @(Get-AzStorageBlob @listSplat) }
    catch {
        $message = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
        Write-MhDeep ('  storage exception: ' + $_.Exception.ToString())
        $hint = if ($message -match '403|not authorized|AuthenticationFailed|Signature') {
            'The SAS token was refused: it may have expired, be missing List permission (sp=rl at least), be for a different account, or have a start time in the future. Check the sv, se and sp values.'
        }
        elseif ($message -match '404|ContainerNotFound|does not exist') { "No container called '$Container' in the account '$AccountName'." }
        elseif ($message -match 'No such host|could not be resolved|Retry failed after') { "Could not reach '$AccountName.blob.core.windows.net'. Check that this machine can reach Azure Storage." }
        elseif ($message -match 'Method not found') { 'Two different versions of the Azure libraries are loaded in this session. Start a fresh PowerShell session and run this again.' }
        else { '' }
        throw ("Could not list the container: $message" + $(if ($hint) { " $hint" } else { '' }))
    }

    $index = @{}
    foreach ($blob in $blobs) {
        $leaf = ($blob.Name -split '/')[-1]
        if (-not $index.ContainsKey($leaf) -or (ConvertTo-MhUtcTime $blob.LastModified) -gt (ConvertTo-MhUtcTime $index[$leaf].LastModified)) { $index[$leaf] = $blob }
        Write-MhDeep ('  blob {0} ({1})' -f $blob.Name, (Format-MhSize $blob.Length))
    }
    Write-MhLog "Found $($blobs.Count) blob(s) under '$Container/$Prefix'"
    if ($blobs.Count -eq 0) {
        Write-MhLog 'The container listing came back empty. If the backups sit in a folder, -BlobPrefix has to name it (a parent folder is enough when several databases share one).' -Level WARN
    }
    [pscustomobject]@{ Context = $context; Index = $index; All = @($blobs); Count = $blobs.Count }
}

function Format-AzureStamp {
    [CmdletBinding()]
    param([AllowNull()] $Value, [string] $Format = 'dd MMM yyyy HH:mm', [switch] $Utc)

    if ($null -eq $Value) { return '(no date)' }
    try {
        $text = (ConvertTo-MhUtcTime $Value).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($Utc) { $text + ' UTC' } else { $text }
    }
    catch { '(unreadable date)' }
}

function Get-AzureBlobPrefix {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Pattern, [Parameter(Mandatory)] [string] $DatabaseName)

    $prefix = $Pattern.Replace('\', '/').Replace('{db}', $DatabaseName)
    $prefix = $prefix.Trim('/')
    if ($prefix) { $prefix + '/' } else { '' }
}

function Select-AzureLatestBackupBlob {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Blobs,
        [string[]] $Extensions = @('.bak'),
        [int] $SiblingWindowSeconds = 120
    )

    $usable = @($Blobs | Where-Object {
        $name = ($_.Name -split '/')[-1]
        $name -and ($Extensions -contains [System.IO.Path]::GetExtension($name).ToLower())
    })
    if ($usable.Count -eq 0) { return [pscustomobject]@{ Chosen = $null; Siblings = @(); Considered = 0 } }

    # normalise every timestamp once, then only ever compare that type. Az.Storage returns a
    # DateTimeOffset and anything that coerces it to a DateTime does so through the machine's own
    # regional setting, which is how this used to fail on a server set to US dates.
    $dated = @($usable | ForEach-Object {
        [pscustomobject]@{ Blob = $_; When = (ConvertTo-MhUtcTime $_.LastModified) }
    })

    $newest = @($dated | Sort-Object When, { $_.Blob.Name } | Select-Object -Last 1)[0]
    $siblings = @($dated | Where-Object {
        $_.Blob.Name -ne $newest.Blob.Name -and
        [Math]::Abs(($_.When - $newest.When).TotalSeconds) -le $SiblingWindowSeconds
    } | Sort-Object { $_.Blob.Name } | ForEach-Object { $_.Blob })

    [pscustomobject]@{ Chosen = $newest.Blob; Siblings = $siblings; Considered = $usable.Count; ChosenWhen = $newest.When }
}

function Resolve-AzureUserGrant {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Entries,
        [AllowEmptyCollection()] [string[]] $DefaultRoles,
        [Parameter(Mandatory)] [string[]] $Databases
    )

    $grants = New-Object System.Collections.Generic.List[object]
    $unknown = New-Object System.Collections.Generic.List[string]

    function Add-Grant([string] $Database, [string] $User, [string[]] $Roles) {
        $existing = @($grants | Where-Object { $_.Database -eq $Database -and $_.User -eq $User })
        if ($existing.Count) {
            foreach ($role in $Roles) { if ($existing[0].Roles -notcontains $role) { $existing[0].Roles += $role } }
            return
        }
        $grants.Add([pscustomobject]@{ Database = $Database; User = $User; Roles = @($Roles) })
    }

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $database = '*'
        $user = ''
        $roles = @()

        if ($entry -is [System.Collections.IDictionary] -or $entry -is [pscustomobject]) {
            $get = {
                param($names)
                foreach ($name in $names) {
                    if ($entry -is [System.Collections.IDictionary]) {
                        foreach ($key in $entry.Keys) { if ([string]$key -eq $name) { return $entry[$key] } }
                    }
                    else {
                        $property = $entry.PSObject.Properties[$name]
                        if ($property) { return $property.Value }
                    }
                }
                $null
            }
            $d = & $get @('Database', 'Db', 'DatabaseName')
            $u = & $get @('User', 'UserName', 'Login', 'Name')
            $r = & $get @('Role', 'Roles')
            if ($d) { $database = ([string]$d).Trim() }
            if ($u) { $user = ([string]$u).Trim() }
            if ($r) { $roles = @($r | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
            if (-not $user) { throw "an -AddUser entry does not say who to add: $($entry | Out-String)".Trim() }
        }
        else {
            $text = ([string]$entry).Trim()
            if (-not $text) { continue }
            $parts = $text.Split(':')
            if ($parts.Count -eq 1) { $user = $parts[0].Trim() }
            elseif ($parts.Count -ge 2) {
                $database = $parts[0].Trim()
                $user = $parts[1].Trim()
                if ($parts.Count -ge 3) {
                    $roles = @(($parts[2..($parts.Count - 1)] -join ':') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
            }
            if (-not $user) { throw "cannot make sense of the -AddUser entry '$text': expected a name, or Database:User:Role." }
        }

        if ($roles.Count -eq 0) { $roles = @(@($DefaultRoles) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }

        if ($database -eq '*') {
            foreach ($db in $Databases) { Add-Grant $db $user $roles }
        }
        else {
            $match = @($Databases | Where-Object { $_ -eq $database })
            if ($match.Count -eq 0) { $unknown.Add(('{0} (for {1})' -f $database, $user)); continue }
            Add-Grant $match[0] $user $roles
        }
    }

    [pscustomobject]@{ Grants = $grants.ToArray(); Unknown = $unknown.ToArray() }
}

function Test-AzureSystemPrincipal {
    [CmdletBinding()]
    param([int] $PrincipalId, [AllowEmptyString()] [string] $Name, [AllowEmptyString()] [string] $Type, [bool] $IsFixedRole = $false)

    if ($PrincipalId -le 4) { return $true }
    if ($IsFixedRole) { return $true }
    if (([string]$Name).StartsWith('##')) { return $true }
    if (([string]$Type) -notin 'S', 'U', 'G', 'E', 'X') { return $true }   # roles, certificates, keys
    $false
}

function Get-AzureTdeProblem {
    [CmdletBinding()]
    param(
        [int] $EngineEdition, [int] $MajorVersion, [AllowEmptyString()] [string] $Edition,
        [bool] $HasMasterKey, [AllowEmptyString()] [string] $CertificateName,
        [AllowEmptyString()] [string] $FoundCertificate, [AllowEmptyString()] [string] $PrivateKeyType
    )

    $problems = New-Object System.Collections.Generic.List[string]

    if ($EngineEdition -in 5, 6, 9, 11) {
        $problems.Add('this is Azure SQL Database, where encryption at rest is managed by the platform and there is no certificate of yours to protect anything with. Leave -EnableTde off.')
    }
    elseif ($EngineEdition -eq 8) {
        $problems.Add('this is Azure SQL Managed Instance, which holds the keys itself: databases are encrypted by the instance rather than by a certificate you create. Leave -EnableTde off.')
    }
    elseif ($EngineEdition -in 1, 4) {
        $problems.Add(("{0} does not have TDE at any version: the engine refuses to create a database encryption key outright. It needs Standard, Enterprise, Developer or Evaluation." -f
                       $(if ($Edition) { $Edition } else { 'This edition' })))
    }
    elseif ($MajorVersion -gt 0 -and $MajorVersion -lt 15 -and $EngineEdition -ne 3) {
        $problems.Add(("TDE needs Enterprise, Developer or Evaluation edition before SQL Server 2019, and this is {0} (major version {1}). 2019 brought it to Standard as well." -f
                       $(if ($Edition) { $Edition } else { 'another edition' }), $MajorVersion))
    }

    if (-not $HasMasterKey) {
        $problems.Add("there is no database master key in master. Create one, back it up and keep the password: CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<a long random string>';")
    }
    if (-not $FoundCertificate) {
        $problems.Add(("there is no certificate called '{0}' in master. Create it, then back it up WITH PRIVATE KEY before anything is encrypted with it: CREATE CERTIFICATE {1} WITH SUBJECT = 'TDE certificate for restored copies';" -f
                       $CertificateName, (Esc-MhName $CertificateName)))
    }
    elseif ($PrivateKeyType -eq 'NO_PRIVATE_KEY') {
        $problems.Add(("the certificate '{0}' has no private key, so it cannot protect a database encryption key. It was restored from a .cer without its .pvk; restore it again WITH PRIVATE KEY." -f $CertificateName))
    }
    elseif ($PrivateKeyType -eq 'ENCRYPTED_BY_PASSWORD') {
        $problems.Add(("the private key of '{0}' is protected by a password rather than by the database master key, so SQL Server cannot open it unattended. Re-import it so the master key protects it." -f $CertificateName))
    }

    $problems.ToArray()
}

function Clear-AzureDatabaseUser {
    [CmdletBinding()]
    param([string] $Server, [string] $DatabaseName)

    $sql = @'
SET NOCOUNT ON;
DECLARE @outcome TABLE (UserName sysname, Result varchar(10), Detail nvarchar(400));
DECLARE @name sysname, @sql nvarchar(max);

DECLARE @doomed TABLE (PrincipalId int PRIMARY KEY, UserName sysname);
INSERT @doomed (PrincipalId, UserName)
SELECT dp.principal_id, dp.name
FROM sys.database_principals AS dp
WHERE dp.type IN ('S', 'U', 'G', 'E', 'X')
  AND dp.principal_id > 4                  -- dbo, guest, INFORMATION_SCHEMA and sys are 1 to 4
  AND dp.is_fixed_role = 0
  AND dp.name NOT LIKE '##%';              -- certificate-backed, the instance's own

-- a user owning a schema or a role cannot be dropped, so hand those to dbo first
DECLARE @owned TABLE (Kind varchar(10), ObjectName sysname, UserName sysname);
INSERT @owned (Kind, ObjectName, UserName)
SELECT 'schema', s.name, d.UserName
FROM sys.schemas AS s JOIN @doomed AS d ON d.PrincipalId = s.principal_id;
INSERT @owned (Kind, ObjectName, UserName)
SELECT 'role', r.name, d.UserName
FROM sys.database_principals AS r JOIN @doomed AS d ON d.PrincipalId = r.owning_principal_id
WHERE r.type = 'R' AND r.is_fixed_role = 0;

DECLARE @kind varchar(10), @object sysname;
DECLARE handover CURSOR LOCAL FAST_FORWARD FOR SELECT Kind, ObjectName, UserName FROM @owned;
OPEN handover;
FETCH NEXT FROM handover INTO @kind, @object, @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF @kind = 'schema' SET @sql = N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(@object) + N' TO [dbo];';
        ELSE                SET @sql = N'ALTER AUTHORIZATION ON ROLE::' + QUOTENAME(@object) + N' TO [dbo];';
        EXEC sys.sp_executesql @sql;
        INSERT @outcome (UserName, Result, Detail)
        VALUES (@name, 'handover', @kind + N' ' + @object + N' now belongs to dbo');
    END TRY
    BEGIN CATCH
        INSERT @outcome (UserName, Result, Detail)
        VALUES (@name, 'kept', N'could not hand over ' + @kind + N' ' + @object + N': ' + ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM handover INTO @kind, @object, @name;
END
CLOSE handover;
DEALLOCATE handover;

DECLARE doomed CURSOR LOCAL FAST_FORWARD FOR SELECT UserName FROM @doomed ORDER BY UserName;
OPEN doomed;
FETCH NEXT FROM doomed INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'DROP USER ' + QUOTENAME(@name) + N';';
        EXEC sys.sp_executesql @sql;
        INSERT @outcome (UserName, Result, Detail) VALUES (@name, 'dropped', NULL);
    END TRY
    BEGIN CATCH
        INSERT @outcome (UserName, Result, Detail) VALUES (@name, 'kept', ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM doomed INTO @name;
END
CLOSE doomed;
DEALLOCATE doomed;

SELECT UserName, Result, Detail FROM @outcome ORDER BY Result, UserName;
'@
    $rows = Invoke-AzureSql -Server $Server -Query $sql -DatabaseName $DatabaseName
    [pscustomobject]@{
        Dropped  = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'dropped' } | ForEach-Object { [string]$_['UserName'] })
        Handover = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'handover' } | ForEach-Object { [string]$_['Detail'] })
        Kept     = @($rows.Rows | Where-Object { [string]$_['Result'] -eq 'kept' } | ForEach-Object { '{0}: {1}' -f $_['UserName'], $_['Detail'] })
    }
}

function Add-AzureDatabaseUser {
    [CmdletBinding()]
    param([string] $Server, [string] $DatabaseName, [AllowEmptyCollection()] [object[]] $Grants)

    $created = New-Object System.Collections.Generic.List[string]
    $noLogin = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($grant in @($Grants)) {
        $name = ([string]$grant.User).Trim()
        if (-not $name) { continue }
        $login = Get-AzureScalar -Server $Server -Parameters @{ '@n' = $name } -Query `
                 "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G','E','X')"
        if (-not $login) { $noLogin.Add($name); continue }
        try {
            $statement = 'IF DATABASE_PRINCIPAL_ID(N''' + ($name -replace "'", "''") + ''') IS NULL CREATE USER ' + (Esc-MhName $name) + ' FOR LOGIN ' + (Esc-MhName $name) + ';'
            [void](Invoke-AzureSql -Server $Server -Query $statement -DatabaseName $DatabaseName)
            foreach ($role in @($grant.Roles)) {
                $r = ([string]$role).Trim()
                if (-not $r) { continue }
                [void](Invoke-AzureSql -Server $Server -DatabaseName $DatabaseName -Query `
                       ('ALTER ROLE ' + (Esc-MhName $r) + ' ADD MEMBER ' + (Esc-MhName $name) + ';'))
            }
            $created.Add($(if (@($grant.Roles).Count) { '{0} in {1}' -f $name, (@($grant.Roles) -join ', ') } else { $name }))
        }
        catch { $failed.Add(('{0}: {1}' -f $name, ($_.Exception.GetBaseException().Message -split "`r?`n")[0])) }
    }
    [pscustomobject]@{ Created = $created.ToArray(); NoLogin = $noLogin.ToArray(); Failed = $failed.ToArray() }
}

function Resolve-AzureOwnerLogin {
    [CmdletBinding()]
    param([string] $Server, [string] $Wanted)

    $exact = Get-AzureScalar -Server $Server -Parameters @{ '@n' = $Wanted } -Query `
             "SELECT name FROM sys.server_principals WHERE name = @n AND type IN ('S','U','G')"
    if ($exact) { return [pscustomobject]@{ Login = [string]$exact; Substituted = $false } }

    $sa = Get-AzureScalar -Server $Server -Query 'SELECT name FROM sys.server_principals WHERE principal_id = 1'
    if ($sa) { return [pscustomobject]@{ Login = [string]$sa; Substituted = $true } }
    [pscustomobject]@{ Login = $null; Substituted = $false }
}

function Test-AzureTdeReadiness {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $CertificateName)

    $query = @'
SELECT  EngineEdition = CONVERT(int, SERVERPROPERTY('EngineEdition')),
        Major = CONVERT(int, SERVERPROPERTY('ProductMajorVersion')),
        Edition = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
        HasMasterKey = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END),
        CertFound = ISNULL((SELECT TOP (1) c.name FROM sys.certificates c WHERE c.name = @cert), ''),
        KeyType = ISNULL((SELECT TOP (1) c.pvt_key_encryption_type_desc FROM sys.certificates c WHERE c.name = @cert), ''),
        Thumbprint = ISNULL((SELECT TOP (1) CONVERT(varchar(80), c.thumbprint, 1) FROM sys.certificates c WHERE c.name = @cert), ''),
        Subject = ISNULL((SELECT TOP (1) c.subject FROM sys.certificates c WHERE c.name = @cert), ''),
        Expiry = (SELECT TOP (1) c.expiry_date FROM sys.certificates c WHERE c.name = @cert)
'@
    $facts = (Invoke-AzureSql -Server $Server -Parameters @{ '@cert' = $CertificateName } -Query $query).Rows[0]

    $problems = @(Get-AzureTdeProblem -EngineEdition ([int]$facts['EngineEdition']) -MajorVersion ([int]$facts['Major']) `
                                 -Edition ([string]$facts['Edition']) -HasMasterKey ([bool]$facts['HasMasterKey']) `
                                 -CertificateName $CertificateName -FoundCertificate ([string]$facts['CertFound']) `
                                 -PrivateKeyType ([string]$facts['KeyType']))
    [pscustomobject]@{
        Ok         = ($problems.Count -eq 0)
        Problems   = $problems
        Subject    = [string]$facts['Subject']
        Thumbprint = [string]$facts['Thumbprint']
        Expiry     = $(if ($facts['Expiry'] -is [DBNull]) { $null } else { $facts['Expiry'] })
    }
}

function Get-AzureEncryptionState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName)

    $query = @'
SELECT encryption_state, percent_complete, key_algorithm, key_length
FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID(@db)
'@
    Invoke-AzureSql -Server $Server -Parameters @{ '@db' = $DatabaseName } -Query $query
}

function Enable-AzureDatabaseTde {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
        [Parameter(Mandatory)] [string] $CertificateName, [ValidateRange(1, 1440)] [int] $WaitMinutes = 60
    )

    $rows = @((Get-AzureEncryptionState -Server $Server -DatabaseName $DatabaseName).Rows)
    if ($rows.Count -and [int]$rows[0]['encryption_state'] -eq 3) {
        Write-MhDetail '  it is encrypted already'
        return [pscustomobject]@{ Encrypted = $true; Already = $true; TimedOut = $false; Percent = 100; Seconds = 0
                                  Algorithm = [string]$rows[0]['key_algorithm']; KeyLength = [int]$rows[0]['key_length'] }
    }

    if ($rows.Count -eq 0) {
        Write-MhDetail ('  creating the database encryption key, protected by the certificate ' + $CertificateName)
        # this one has to run inside the database: there is no way to qualify it from master
        [void](Invoke-AzureSql -Server $Server -DatabaseName $DatabaseName -Query `
               ('CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE ' + (Esc-MhName $CertificateName) + ';'))
    }
    else { Write-MhDetail '  the encryption key is already there, so only the encryption needs turning on' }

    Invoke-AzureStatement -Server $Server -DatabaseName $DatabaseName -Statement 'ALTER DATABASE {DB} SET ENCRYPTION ON;'

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $said = [datetime]::MinValue
    while ($true) {
        $rows = @((Get-AzureEncryptionState -Server $Server -DatabaseName $DatabaseName).Rows)
        if ($rows.Count -eq 0) { throw 'the database encryption key disappeared while the database was being encrypted' }
        $state = [int]$rows[0]['encryption_state']
        $percent = [double]$rows[0]['percent_complete']
        $common = @{ Algorithm = [string]$rows[0]['key_algorithm']; KeyLength = [int]$rows[0]['key_length']
                     Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1); Already = $false }

        if ($state -eq 3) { return [pscustomobject]($common + @{ Encrypted = $true; TimedOut = $false; Percent = 100 }) }
        if ($state -eq 5) { throw 'the database is being decrypted rather than encrypted; something else is working on it' }
        if ((Get-Date) -ge $deadline) {
            return [pscustomobject]($common + @{ Encrypted = $false; TimedOut = $true; Percent = $percent })
        }
        if (((Get-Date) - $said).TotalSeconds -ge 15) {
            Write-MhLog ('  encrypting: {0}% after {1}s' -f [math]::Round($percent, 1), [math]::Round($timer.Elapsed.TotalSeconds))
            $said = Get-Date
        }
        Start-Sleep -Milliseconds 1500
    }
}

function Complete-AzureRestoredDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
        [Parameter(Mandatory)] $Outcome, $OwnerLogin,
        [AllowEmptyCollection()] [object[]] $Grants = @()
    )

    if (-not $script:AzureKeepUsers) {
        Start-MhStep 'Clear out the users it came with'
        $users = Clear-AzureDatabaseUser -Server $Server -DatabaseName $DatabaseName
        foreach ($moved in $users.Handover) { Write-MhDetail ('  ' + $moved) }
        if ($users.Dropped.Count) { Write-MhLog ('Dropped {0} user(s): {1}' -f $users.Dropped.Count, ($users.Dropped -join ', ')) }
        else { Write-MhLog 'No users to drop; only the built-in ones were there' }
        foreach ($kept in $users.Kept) { Write-MhLog ('Could not drop ' + $kept) -Level WARN }
        $Outcome.Users = '{0} dropped' -f $users.Dropped.Count
        Complete-MhStep
    }

    if ($OwnerLogin -and $OwnerLogin.Login) {
        Start-MhStep ('Set the owner to {0}' -f $OwnerLogin.Login)
        Invoke-AzureStatement -Server $Server -DatabaseName $DatabaseName `
            -Statement ('ALTER AUTHORIZATION ON DATABASE::{DB} TO ' + (Esc-MhName $OwnerLogin.Login) + ';')
        Complete-MhStep
    }

    Start-MhStep ("Set the recovery model to $script:AzureRecoveryModel")
    Invoke-AzureStatement -Server $Server -DatabaseName $DatabaseName `
        -Statement ("ALTER DATABASE {DB} SET RECOVERY $script:AzureRecoveryModel;")
    Complete-MhStep

    if ($Grants.Count) {
        Start-MhStep 'Add the users asked for'
        $added = Add-AzureDatabaseUser -Server $Server -DatabaseName $DatabaseName -Grants $Grants
        if ($added.Created.Count) {
            $roleless = @($Grants | Where-Object { @($_.Roles).Count -eq 0 })
            Write-MhLog ('Added ' + ($added.Created -join '; ') +
                       $(if ($roleless.Count) { ' - no role membership, so no permissions yet' } else { '' }))
        }
        foreach ($missing in $added.NoLogin) {
            Write-MhLog ("There is no login called '{0}' on {1}, so no user was created for it. Create the login first, then run this again." -f $missing, $Server) -Level WARN
        }
        foreach ($failure in $added.Failed) { Write-MhLog ('Could not add ' + $failure) -Level WARN }
        Complete-MhStep
    }
    elseif ($script:AzureuserGrants.Count) { Write-MhDetail '  no users asked for on this one' }

    # before read-only, because a read-only database cannot have an encryption key created
    $encrypted = $false
    if ($script:AzureEnableTde) {
        Start-MhStep 'Encrypt it'
        $tde = Enable-AzureDatabaseTde -Server $Server -DatabaseName $DatabaseName `
                                  -CertificateName $script:AzureTdeCertificateName -WaitMinutes $script:AzureTdeWaitMinutes
        $encrypted = $tde.Encrypted
        if ($tde.Already) { Write-MhLog 'Already encrypted; left as it is' }
        elseif ($tde.Encrypted) {
            Write-MhLog ('Encrypted with {0} ({1}-bit) in {2}s' -f $tde.Algorithm, $tde.KeyLength, $tde.Seconds)
        }
        else {
            Write-MhLog ('Still encrypting after {0} minute(s): {1}% done. It carries on in the background; this is not a failure, but nothing that needs it finished is done to this database.' -f
                       $script:AzureTdeWaitMinutes, [math]::Round($tde.Percent, 1)) -Level WARN
        }
        $Outcome.Encryption = $(if ($tde.Encrypted) { '{0} {1}-bit' -f $tde.Algorithm, $tde.KeyLength } else { 'in progress' })
        Complete-MhStep -Result $(if ($tde.Encrypted) { 'OK' } else { 'SKIPPED' })
    }

    # last, because a read-only database cannot be changed any further
    if ($script:AzureReadOnly) {
        if ($script:AzureEnableTde -and -not $encrypted) {
            Write-MhLog 'Not setting it read-only: the encryption has not finished, and the scan needs the database writable. Run this again once it has, or set it read-only by hand.' -Level WARN
        }
        else {
            Start-MhStep 'Set it read-only'
            # AUTO_CLOSE undoes this: a database that closes and reopens comes back
            # read-write, so the setting looks applied and then quietly is not. Turning
            # AUTO_CLOSE off is the only way to make read-only mean anything, and it is
            # not something a restored copy on a server wants switched on in any case.
            $autoClose = Get-AzureScalar -Server $Server -Parameters @{ '@db' = $DatabaseName } -Query `
                         'SELECT is_auto_close_on FROM sys.databases WHERE name = @db'
            if ($autoClose -and [bool]$autoClose) {
                Invoke-AzureStatement -Server $Server -DatabaseName $DatabaseName `
                    -Statement 'ALTER DATABASE {DB} SET AUTO_CLOSE OFF;'
                Write-MhLog 'Turned AUTO_CLOSE off first: with it on, the database reverts to read-write the next time it is opened' -Level WARN
            }

            Invoke-AzureStatement -Server $Server -DatabaseName $DatabaseName `
                -Statement 'ALTER DATABASE {DB} SET READ_ONLY WITH ROLLBACK IMMEDIATE;'

            # and prove it took, rather than reporting the statement that was sent
            $nowReadOnly = Get-AzureScalar -Server $Server -Parameters @{ '@db' = $DatabaseName } -Query `
                           'SELECT is_read_only FROM sys.databases WHERE name = @db'
            if (-not ($nowReadOnly -and [bool]$nowReadOnly)) {
                throw 'the database did not stay read-only. Something else is holding it read-write; check AUTO_CLOSE and whether anything is reopening it.'
            }
            Write-MhLog 'Set read-only'
            Complete-MhStep
        }
    }

    # say what it actually is now, not what was asked for
    # -DatabaseName matters: sys.database_principals is scoped to the connection's
    # database, so without it this counted master's users instead of this one's
    $final = (Invoke-AzureSql -Server $Server -DatabaseName $DatabaseName -Parameters @{ '@db' = $DatabaseName } -Query `
              'SELECT recovery_model_desc, is_read_only, Owner = SUSER_SNAME(owner_sid), Users = (SELECT COUNT(*) FROM sys.database_principals WHERE type IN (''S'',''U'',''G'') AND principal_id > 4), Encryption = ISNULL((SELECT TOP (1) k.encryption_state FROM sys.dm_database_encryption_keys k WHERE k.database_id = DB_ID(@db)), 0) FROM sys.databases WHERE name = @db').Rows[0]
    $encryptionState = switch ([int]$final['Encryption']) {
        2 { 'encryption in progress' ; break }
        3 { 'encrypted' ; break }
        4 { 'changing its encryption key' ; break }
        5 { 'being decrypted' ; break }
        default { 'not encrypted' }
    }
    Write-MhLog ('{0} is now: owner {1}, recovery {2}, {3}, {4}, {5} user(s) besides the built-in ones' -f
               $DatabaseName, $final['Owner'], $final['recovery_model_desc'],
               $(if ([bool]$final['is_read_only']) { 'read-only' } else { 'read-write' }), $encryptionState, $final['Users'])
    $Outcome.Users = '{0} left' -f $final['Users']
    $Outcome.Result = 'DONE'
}

Register-MhSelfTest -Name 'Restore-MhLatestAzureBackup' -Test {
    # Az.Storage returns LastModified as a DateTimeOffset, so that is what the fake blobs carry.
    # The old helper handed back a DateTime, which is how a conversion bug reached a live server.
    function Blob([string] $Name, [string] $When, [int] $Length = 1048576) {
        $utc = [datetime]::SpecifyKind([datetime]::ParseExact($When, 'yyyy-MM-dd HH:mm',
                   [System.Globalization.CultureInfo]::InvariantCulture), [System.DateTimeKind]::Utc)
        [pscustomobject]@{ Name = $Name; LastModified = [System.DateTimeOffset]$utc; Length = $Length }
    }

    Test-MhSection 'where to look'
    Test-MhCheck 'the documented layout' ((Get-AzureBlobPrefix -Pattern 'FULL/DAILY/{db}/' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Test-MhCheck 'backslashes are accepted' ((Get-AzureBlobPrefix -Pattern 'FULL\DAILY\{db}\' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Test-MhCheck 'a missing trailing slash is added' ((Get-AzureBlobPrefix -Pattern 'FULL/DAILY/{db}' -DatabaseName 'Sales') -eq 'FULL/DAILY/Sales/')
    Test-MhCheck 'so Sales cannot match SalesArchive' ((Get-AzureBlobPrefix -Pattern '{db}' -DatabaseName 'Sales') -eq 'Sales/')
    Test-MhCheck 'a flat container is allowed' ((Get-AzureBlobPrefix -Pattern '/' -DatabaseName 'Sales') -eq '')
    Test-MhCheck 'the name goes in more than once if asked' ((Get-AzureBlobPrefix -Pattern 'FULL/{db}/DAILY/{db}/' -DatabaseName 'Sales') -eq 'FULL/Sales/DAILY/Sales/')

    Test-MhSection 'which backup'
    $old = Blob 'FULL/DAILY/Sales/Sales_20261011.bak' '2026-10-11 22:05'
    $mid = Blob 'FULL/DAILY/Sales/Sales_20261012.bak' '2026-10-12 22:05'
    $new = Blob 'FULL/DAILY/Sales/Sales_20261013.bak' '2026-10-13 22:05'
    $s = Select-AzureLatestBackupBlob -Blobs @($old, $new, $mid)
    Test-MhCheck 'the newest one wins' ($s.Chosen.Name -eq $new.Name)
    Test-MhCheck 'and it says how many it looked at' ($s.Considered -eq 3)
    Test-MhCheck 'with nothing mistaken for a sibling' ($s.Siblings.Count -eq 0)

    $log = Blob 'FULL/DAILY/Sales/upload.log' '2026-10-14 01:00'
    $txt = Blob 'FULL/DAILY/Sales/readme.txt' '2026-10-14 02:00'
    $s = Select-AzureLatestBackupBlob -Blobs @($mid, $new, $log, $txt)
    Test-MhCheck 'other files in the folder are ignored' ($s.Chosen.Name -eq $new.Name -and $s.Considered -eq 2)

    $a = Blob 'FULL/DAILY/Sales/Sales_1of2.bak' '2026-10-13 22:05'
    $b = Blob 'FULL/DAILY/Sales/Sales_2of2.bak' '2026-10-13 22:06'
    $s = Select-AzureLatestBackupBlob -Blobs @($mid, $a, $b)
    Test-MhCheck 'a stripe written a minute later is a candidate sibling' ($s.Siblings.Count -eq 1)
    Test-MhCheck 'and the older backup is not' (($s.Siblings | ForEach-Object { $_.Name }) -notcontains $mid.Name)

    $s = Select-AzureLatestBackupBlob -Blobs @()
    Test-MhCheck 'an empty folder chooses nothing' ($null -eq $s.Chosen -and $s.Considered -eq 0)
    $s = Select-AzureLatestBackupBlob -Blobs @($log)
    Test-MhCheck 'a folder with no backups in it chooses nothing' ($null -eq $s.Chosen)
    $s = Select-AzureLatestBackupBlob -Blobs @($mid, $new) -Extensions @('.trn')
    Test-MhCheck 'the extensions it accepts can be changed' ($null -eq $s.Chosen)

    Test-MhSection 'who gets added to what'
    $dbs = 'Sales', 'Stock'
    $g = Resolve-AzureUserGrant -Entries @('BiTeam') -DefaultRoles @('db_datareader') -Databases $dbs
    Test-MhCheck 'a bare name goes into every database' ($g.Grants.Count -eq 2 -and ($g.Grants | ForEach-Object { $_.Database }) -contains 'Stock')
    Test-MhCheck 'and picks up the default role' ($g.Grants[0].Roles -contains 'db_datareader')

    $g = Resolve-AzureUserGrant -Entries @('Sales:BiTeam') -DefaultRoles @('db_datareader') -Databases $dbs
    Test-MhCheck 'Database:User goes into that one only' ($g.Grants.Count -eq 1 -and $g.Grants[0].Database -eq 'Sales')
    Test-MhCheck 'and still takes the default role' ($g.Grants[0].Roles -contains 'db_datareader')

    $g = Resolve-AzureUserGrant -Entries @('Sales:BiTeam:db_owner') -DefaultRoles @('db_datareader') -Databases $dbs
    Test-MhCheck 'a named role beats the default' ($g.Grants[0].Roles.Count -eq 1 -and $g.Grants[0].Roles[0] -eq 'db_owner')

    $g = Resolve-AzureUserGrant -Entries @('Sales:BiTeam:db_datareader,db_datawriter') -Databases $dbs
    Test-MhCheck 'roles can be comma separated in the string form' ($g.Grants[0].Roles.Count -eq 2)

    $g = Resolve-AzureUserGrant -Entries @('*:BiTeam:db_owner') -Databases $dbs
    Test-MhCheck 'a star means every database' ($g.Grants.Count -eq 2)

    $g = Resolve-AzureUserGrant -Entries @('CONTOSO\\jo') -Databases $dbs
    Test-MhCheck 'a Windows account with a backslash is not mangled' ($g.Grants[0].User -eq 'CONTOSO\\jo')
    $g = Resolve-AzureUserGrant -Entries @('Sales:CONTOSO\\jo:db_datareader') -Databases $dbs
    Test-MhCheck 'and works in the string form too' ($g.Grants.Count -eq 1 -and $g.Grants[0].User -eq 'CONTOSO\\jo')

    $g = Resolve-AzureUserGrant -Entries @(@{ Database = 'Stock'; User = 'AppSvc'; Role = 'db_datawriter', 'db_datareader' }) -Databases $dbs
    Test-MhCheck 'a hashtable entry works' ($g.Grants.Count -eq 1 -and $g.Grants[0].Database -eq 'Stock' -and $g.Grants[0].Roles.Count -eq 2)
    $g = Resolve-AzureUserGrant -Entries @([pscustomobject]@{ DatabaseName = 'Sales'; Login = 'AppSvc'; Roles = 'db_owner' }) -Databases $dbs
    Test-MhCheck 'and the other spellings of its keys' ($g.Grants.Count -eq 1 -and $g.Grants[0].User -eq 'AppSvc')
    $g = Resolve-AzureUserGrant -Entries @(@{ User = 'AppSvc' }) -DefaultRoles @('db_datareader') -Databases $dbs
    Test-MhCheck 'a hashtable with no database means all of them' ($g.Grants.Count -eq 2)

    $g = Resolve-AzureUserGrant -Entries @('Sales:BiTeam:db_datareader', 'BiTeam') -DefaultRoles @('db_datawriter') -Databases $dbs
    Test-MhCheck 'the same user twice is merged, not duplicated' (@($g.Grants | Where-Object { $_.Database -eq 'Sales' }).Count -eq 1)
    Test-MhCheck 'and its roles are merged' ((@($g.Grants | Where-Object { $_.Database -eq 'Sales' })[0].Roles | Sort-Object) -join ',' -eq 'db_datareader,db_datawriter')

    $g = Resolve-AzureUserGrant -Entries @('Sale:BiTeam') -Databases $dbs
    Test-MhCheck 'a database that is not being restored is reported, not ignored' ($g.Grants.Count -eq 0 -and $g.Unknown.Count -eq 1)
    Test-MhCheck 'and the report says which user it was for' ($g.Unknown[0] -match 'BiTeam')

    $g = Resolve-AzureUserGrant -Entries @('BiTeam') -Databases $dbs
    Test-MhCheck 'no default role leaves the roles empty rather than inventing one' (@($g.Grants[0].Roles).Count -eq 0)
    $g = Resolve-AzureUserGrant -Entries @() -Databases $dbs
    Test-MhCheck 'nothing asked for is nothing granted' ($g.Grants.Count -eq 0)
    $threw = $false
    try { Resolve-AzureUserGrant -Entries @('Sales:') -Databases $dbs | Out-Null } catch { $threw = $true }
    Test-MhCheck 'an entry with no user is refused' $threw

    Test-MhSection 'dates, whatever the region'
    $offset = [System.DateTimeOffset]::new(2026, 10, 13, 10, 56, 59, [TimeSpan]::Zero)
    Test-MhCheck 'a DateTimeOffset comes back as itself' ((ConvertTo-MhUtcTime $offset) -eq $offset)
    $plain = [datetime]::SpecifyKind([datetime]::new(2026, 10, 13, 10, 56, 59), [System.DateTimeKind]::Utc)
    Test-MhCheck 'a DateTime is taken as UTC, not shifted' ((ConvertTo-MhUtcTime $plain).UtcDateTime -eq $plain)
    $unspecified = [datetime]::new(2026, 10, 13, 10, 56, 59)
    Test-MhCheck 'an unspecified kind is not shifted either' ((ConvertTo-MhUtcTime $unspecified).Hour -eq 10)
    Test-MhCheck 'the US string from the failing server reads correctly' ((ConvertTo-MhUtcTime '9/13/2026 10:56:59 AM +00:00').ToString('yyyy-MM-dd HH:mm:ss') -eq '2026-09-13 10:56:59')
    Test-MhCheck 'an ISO string reads correctly' ((ConvertTo-MhUtcTime '2026-10-13T10:56:59').ToString('yyyy-MM-dd HH:mm') -eq '2026-10-13 10:56')
    Test-MhCheck 'a SQL style string reads correctly' ((ConvertTo-MhUtcTime '2026-10-13 10:56:59.123').ToString('yyyy-MM-dd HH:mm') -eq '2026-10-13 10:56')
    $threw = $false
    try { ConvertTo-MhUtcTime 'not a date at all' | Out-Null } catch { $threw = $true }
    Test-MhCheck 'nonsense is refused rather than guessed at' $threw
    Test-MhCheck 'output is spelled the same way whatever the region' ((Format-AzureStamp $offset) -eq '13 Oct 2026 10:56')
    Test-MhCheck 'and says UTC only where that is true' ((Format-AzureStamp $offset -Utc) -eq '13 Oct 2026 10:56 UTC')

    # the real test: do it all again with the machine pretending to be somewhere else
    $was = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in 'en-US', 'de-DE', 'en-GB') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($culture)
            $old = Blob 'FULL/DAILY/Sales/old.bak' '2026-10-11 22:05'
            $mid = Blob 'FULL/DAILY/Sales/mid.bak' '2026-10-12 22:05'
            $new = Blob 'FULL/DAILY/Sales/new.bak' '2026-10-13 22:05'
            $pick = Select-AzureLatestBackupBlob -Blobs @($old, $new, $mid)
            Test-MhCheck ("under $culture the newest is still picked") ($pick.Chosen.Name -eq $new.Name)
            Test-MhCheck ("under $culture days apart are not mistaken for stripes") ($pick.Siblings.Count -eq 0)

            $stripe = Blob 'FULL/DAILY/Sales/new_stripe.bak' '2026-10-13 22:06'
            $pick = Select-AzureLatestBackupBlob -Blobs @($mid, $new, $stripe)
            Test-MhCheck ("under $culture a minute apart is a candidate stripe") ($pick.Siblings.Count -eq 1 -and $pick.Siblings[0].Name -eq $new.Name)
            Test-MhCheck ("under $culture the date still reads the same") ((Format-AzureStamp $new.LastModified -Utc) -eq '13 Oct 2026 22:05 UTC')
            Test-MhCheck ("under $culture a US string still converts") ((ConvertTo-MhUtcTime '9/13/2026 10:56:59 AM +00:00').Month -eq 9)
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $was }

    Test-MhSection 'which users stay'
    Test-MhCheck 'dbo stays' (Test-AzureSystemPrincipal -PrincipalId 1 -Name 'dbo' -Type 'S')
    Test-MhCheck 'guest stays' (Test-AzureSystemPrincipal -PrincipalId 2 -Name 'guest' -Type 'S')
    Test-MhCheck 'INFORMATION_SCHEMA stays' (Test-AzureSystemPrincipal -PrincipalId 3 -Name 'INFORMATION_SCHEMA' -Type 'S')
    Test-MhCheck 'sys stays' (Test-AzureSystemPrincipal -PrincipalId 4 -Name 'sys' -Type 'S')
    Test-MhCheck 'a fixed role stays' (Test-AzureSystemPrincipal -PrincipalId 16384 -Name 'db_owner' -Type 'R' -IsFixedRole $true)
    Test-MhCheck 'a certificate-backed principal stays' (Test-AzureSystemPrincipal -PrincipalId 5 -Name '##MS_PolicyEventProcessingLogin##' -Type 'S')
    Test-MhCheck 'a custom role is not a user, so it stays' (Test-AzureSystemPrincipal -PrincipalId 20 -Name 'ReportReaders' -Type 'R')
    Test-MhCheck 'a SQL user goes' (-not (Test-AzureSystemPrincipal -PrincipalId 5 -Name 'appuser' -Type 'S'))
    Test-MhCheck 'a Windows user goes' (-not (Test-AzureSystemPrincipal -PrincipalId 6 -Name 'CONTOSO\jo' -Type 'U'))
    Test-MhCheck 'a Windows group goes' (-not (Test-AzureSystemPrincipal -PrincipalId 7 -Name 'CONTOSO\Reporting' -Type 'G'))
    Test-MhCheck 'an Entra user goes' (-not (Test-AzureSystemPrincipal -PrincipalId 8 -Name 'jo@contoso.com' -Type 'E'))

    Test-MhSection 'sizes'
    Test-MhCheck 'gigabytes' ((Format-MhSize 3221225472) -eq '3.0 GB')
    Test-MhCheck 'megabytes' ((Format-MhSize 5242880) -eq '5 MB')

    Test-MhSection 'explaining failures'
    $e = Get-MhSqlErrorExplanation -Number 3201 -Message 'Cannot open backup device'
    Test-MhCheck 'a backup device error points at the service account' ($e.Fix -match 'SERVICE ACCOUNT')
    $e = Get-MhSqlErrorExplanation -Number 18456 -Message "Login failed for user 'sa'. State: 8"
    Test-MhCheck 'a refused login is explained' ($e.Meaning -match '18456')

    Test-MhSection 'whether the destination can encrypt anything'
    # PowerShell refuses to add two hashtables that share a key, so a changed copy is made by hand
    function With([hashtable] $Base, [hashtable] $Change) {
        $copy = @{}
        foreach ($key in $Base.Keys) { $copy[$key] = $Base[$key] }
        foreach ($key in $Change.Keys) { $copy[$key] = $Change[$key] }
        $copy
    }
    # and -match against a list returns the matching items rather than a yes or no, so they are
    # joined into one string first
    function Problems([hashtable] $Facts) { @(Get-AzureTdeProblem @Facts) -join ' | ' }
    function ProblemCount([hashtable] $Facts) { @(Get-AzureTdeProblem @Facts).Count }

    $ready = @{ EngineEdition = 3; MajorVersion = 16; Edition = 'Enterprise Edition'; HasMasterKey = $true
                CertificateName = 'MolehillTde'; FoundCertificate = 'MolehillTde'; PrivateKeyType = 'ENCRYPTED_BY_MASTER_KEY' }
    Test-MhCheck 'a ready instance has nothing to report' ((Problems $ready) -eq '')
    Test-MhCheck 'Standard from 2019 is fine' ((Problems (With $ready @{ EngineEdition = 2; MajorVersion = 15; Edition = 'Standard Edition' })) -eq '')
    $express = With $ready @{ EngineEdition = 4; MajorVersion = 17; Edition = 'Express Edition (64-bit)' }
    Test-MhCheck 'Express has none at any version, as the engine itself says' ((Problems $express) -match 'does not have TDE at any version')
    Test-MhCheck 'and it is named rather than hinted at' ((Problems $express) -match 'Express Edition')
    $old = With $ready @{ EngineEdition = 2; MajorVersion = 13; Edition = 'Standard Edition' }
    Test-MhCheck 'Standard before 2019 is not' ((Problems $old) -match 'needs Enterprise')
    Test-MhCheck 'and it names the edition it found' ((Problems $old) -match 'Standard Edition')
    Test-MhCheck 'but Developer before 2019 is' ((Problems (With $ready @{ EngineEdition = 3; MajorVersion = 13 })) -eq '')

    Test-MhCheck 'no master key is reported with the statement that makes one' ((Problems (With $ready @{ HasMasterKey = $false })) -match 'CREATE MASTER KEY')
    Test-MhCheck 'a missing certificate likewise' ((Problems (With $ready @{ FoundCertificate = '' })) -match 'CREATE CERTIFICATE \[MolehillTde\]')
    Test-MhCheck 'and a certificate name is quoted the long way round' ((Problems (With $ready @{ FoundCertificate = ''; CertificateName = 'Odd]Name' })) -match 'CREATE CERTIFICATE \[Odd\]\]Name\]')
    Test-MhCheck 'a certificate with no private key is no use' ((Problems (With $ready @{ PrivateKeyType = 'NO_PRIVATE_KEY' })) -match 'no private key')
    Test-MhCheck 'nor is one SQL Server cannot open by itself' ((Problems (With $ready @{ PrivateKeyType = 'ENCRYPTED_BY_PASSWORD' })) -match 'unattended')
    Test-MhCheck 'Azure SQL Database is told to leave it to the platform' ((Problems (With $ready @{ EngineEdition = 5 })) -match 'managed by the platform')
    Test-MhCheck 'and so is a managed instance' ((Problems (With $ready @{ EngineEdition = 8 })) -match 'holds the keys itself')
    Test-MhCheck 'both missing keys are reported together, not one at a time' ((ProblemCount (With $ready @{ HasMasterKey = $false; FoundCertificate = '' })) -eq 2)

}

# one way to refuse a run, tagged so the shim can tell "you asked for the impossible" from
# "something broke", and on the error stream rather than the host so a caller can catch it
function Stop-AzureRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Reason)
    Write-Error $Reason -Category InvalidArgument -ErrorId 'MhBadArgument' -ErrorAction Stop
}

<#
  This tool's four calls into SQL Server, in its own shape, over the module's one copy of each.

  There is only ever one instance here - the destination - so these take no server name at all,
  which is what the tool's own copies did by reading it out of the caller.
#>
function New-AzureConnectionString([string] $Server, [string] $DatabaseName = 'master') {
    New-MhConnectionString -Server $Server -Database $DatabaseName `
        -Credential $script:AzureDestinationSqlCredential `
        -TrustServerCertificate:$script:AzureTrustServerCertificate `
        -TimeoutSeconds $script:AzureConnectTimeoutSeconds `
        -ApplicationName 'Restore-LatestAzureBackup'
}

function Invoke-AzureSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')
    Invoke-MhSql -ConnectionString (New-AzureConnectionString $Server $DatabaseName) -Query $Query -Parameters $Parameters
}

function Get-AzureScalar {
    [CmdletBinding()]
    param([string] $Server, [string] $Query, [hashtable] $Parameters, [string] $DatabaseName = 'master')
    $table = Invoke-AzureSql -Server $Server -Query $Query -Parameters $Parameters -DatabaseName $DatabaseName
    if ($table.Rows.Count -eq 0) { return $null }
    $value = $table.Rows[0][0]
    if ($value -is [DBNull]) { $null } else { $value }
}

function Invoke-AzureLongSql {
    [CmdletBinding()]
    param([string] $Server, [string] $Sql, [string] $Label)
    Invoke-MhLongRunningSql -ConnectionString (New-AzureConnectionString $Server) -Sql $Sql -Label $Label
}

function Invoke-AzureStatement {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $DatabaseName,
          [Parameter(Mandatory)] [string] $Statement)
    Invoke-MhDbStatement -ConnectionString (New-AzureConnectionString $Server) -DatabaseName $DatabaseName -Statement $Statement
}
