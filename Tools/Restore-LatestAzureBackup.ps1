#Requires -Version 5.1

<#
.SYNOPSIS
    Restores the newest full backup sitting in an Azure Blob Storage container onto a destination
    SQL Server, then tidies each copy up: users cleared out, owner set, recovery model set, and
    optionally users added back and the database made read-only.

.DESCRIPTION
    Molehill Data Services | Restore-LatestAzureBackup

    A single file that can be copied to a server, over the real thing: everything this does lives
    in MolehillTools (Restore-MhLatestAzureBackup). With the module imported you would call that
    directly; this exists because copying one script to a box is how this estate works.

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

    Exit code: 0 = every database done (or a clean dry run), 1 = at least one failed, 2 = could not
    start.

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

.PARAMETER SelfTest
    Check the script's own logic - picking the newest backup, the blob paths it builds, the
    principals it will and will not drop - without a server, a storage account or any module.

.EXAMPLE
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging

.EXAMPLE
    # refreshed, tidied, and handed to the reporting team read-only
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser REPORTS\BiTeam -AddUserRole db_datareader -ReadOnly

.EXAMPLE
    # encrypted as each one lands, then handed over read-only
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging -EnableTde -ReadOnly

.EXAMPLE
    # the reporting team on Sales only, the application account on both
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging `
        -AddUser 'Sales:REPORTS\BiTeam:db_datareader', 'AppSvc' -AddUserRole db_datawriter

.EXAMPLE
    .\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales `
        -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
        -LocalBackupPath D:\RestoreStaging -WhatIf
    # lists the backup it would use and the statements it would run, and changes nothing

.NOTES
    Molehill Data Services. The container is only ever read. On the destination, the named databases
    are overwritten - that is the point - so check the names.
#>
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
    [switch] $Force,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

$manifest = Join-Path $PSScriptRoot '..\MolehillTools\MolehillTools.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host '  MolehillTools is not where this script expects it.' -ForegroundColor Red
    Write-Host "  Looked for: $manifest" -ForegroundColor Gray
    Write-Host '  Copy the MolehillTools folder alongside Tools, or import it yourself and call Restore-MhLatestAzureBackup.' -ForegroundColor Gray
    exit 2
}
# not -Force: one shim can call another - the sample screen calls the export - and a forced
# re-import would reset the module underneath the caller, discarding everything it holds. A
# scripted run of the sample screen lost its input halfway through before this was guarded.
if (-not (Get-Module MolehillTools)) { Import-Module $manifest }

if ($SelfTest) {
    $results = Invoke-MhSelfTest -ModuleOnly -Name 'Restore-MhLatestAzureBackup'
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { exit 1 }
    exit 0
}

# handed through by asking the function what it takes, rather than by a list here that can
# drift: two shims were quietly dropping parameters that way, which looks exactly like the
# tool ignoring you
$takes = @((Get-Command Restore-MhLatestAzureBackup).Parameters.Keys)
$arguments = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($takes -contains $name) { $arguments[$name] = $PSBoundParameters[$name] }
}

try {
    $run = Restore-MhLatestAzureBackup @arguments
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 2
}

if (-not $run) { exit 2 }
exit $(if ($run.Ok) { 0 } else { 1 })
