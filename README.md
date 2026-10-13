# Molehill Watch – SQL Server Support Package toolkit

The monitoring side is Molehill Watch. The admin database behind it, **Molehill Admin**, bills everything Molehill Data Services does: Molehill Watch support agreements, consultancy at a day rate, and one-off invoices typed by hand.

*Catching molehills before they're mountains.*

Everything Molehill Data Services needs to deliver the **Molehill Watch SQL Server Support Package** once a client signs up.

It has two halves:

| | Where it runs | What it does |
|---|---|---|
| **Client** (`Client\`) | Each covered client SQL Server or **Azure SQL Managed Instance** (and every AG replica) | Objects in an `mw` schema, in the `MolehillWatch` database or the client's existing DBA database, plus Agent jobs. They collect health data and build the **weekly status report**. |
| **Client, Azure SQL Database** (`Client\Get-AzureSqlDatabaseReport.ps1`) | The client's jump box. Nothing is installed in Azure. | A read-only weekly report per logical server or elastic pool. |
| **Admin** (`Admin\`) | Your own SQL Server (Express is fine) | The `MolehillAdmin` database: clients, agreements, pricing (including Azure SQL), **tickets and SLA times**, time logging, **included hours**, billing cycles, **invoices**, notice periods and a daily **dashboard**. **Molehill Manager** (`Admin\MolehillManager`) is a terminal front end for all of it. |

---

## Quick start

### 1. Once: install Molehill Admin on your own machine

```powershell
cd Admin
.\Install-MolehillAdmin.ps1 -SqlInstance .\SQLEXPRESS -PaymentDetails "Account name, sort code, account number"
```

This creates the database and schedules a daily 07:00 run. Each run creates draft invoices when they're due and writes `Dashboard.html` plus the invoice HTML files to `Documents\Molehill Admin`.

Then open `Admin\Example-NewClient.sql` in SSMS and press F5. It's a full worked example that rolls itself back.

For everyday use, **Molehill Manager** is a terminal front end for clients, agreements, instances, onboarding, tickets, time and invoices. It calls the same stored procedures, so the rules are identical. See its [README](Admin/MolehillManager/README.md).

```powershell
cd Admin\MolehillManager
dotnet publish -c Release -r win-x64 -o publish    # one self-contained MolehillManager.exe
.\publish\MolehillManager.exe                      # first run asks for the server and sign-in, saves them to MolehillManager.config.json
```

Passwords are only saved if you ask, and then encrypted for your Windows account (DPAPI). If the database isn't there, Molehill Manager offers to create it and install MolehillAdmin itself, and it offers to upgrade an older one. You only need `Install-MolehillAdmin.ps1` to schedule the daily billing run.

### 2. Per client: install Molehill Watch on each covered SQL Server

Copy the `Client` folder to the client's jump box (or the server itself) and run it as a sysadmin:

```powershell
cd Client
.\Install-MolehillWatch.ps1 -SqlInstance SQL01,SQL02 -ClientName "Contoso Ltd" -MolehillLogin "CONTOSO\svc-molehill"
```

**Client already has a DBA database?** Install into it instead of creating another database:

```powershell
.\Install-MolehillWatch.ps1 -SqlInstance SQL01 -ClientName "Contoso Ltd" -Database DBA
```

* `MolehillWatch` is the default, and is the **only** database the installer will ever create.
* A database given with `-Database` must already exist. Its settings (recovery model, owner and so on) are never changed.
* Everything goes in its own `mw` schema, so it can't clash with the client's objects, and the read-only login can't see anything outside it.
* The installer refuses a database that's read-only, in an Availability Group (each replica needs its own writable copy), or has a different collation from the server.
* Pass the same `-Database` to `Export-WeeklyReports.ps1` and `Update-PatchReference.ps1`.

**No domain (SQL authentication only)?** Connect with a SQL sysadmin login, and let the installer create a SQL login for you:

```powershell
.\Install-MolehillWatch.ps1 -SqlInstance 10.0.0.4,10.0.0.5 -ClientName "Contoso Ltd" -SqlCredential (Get-Credential) `
    -MolehillLogin molehill_support -MolehillLoginPassword (Read-Host "Password for molehill_support" -AsSecureString)
```

The SQL login is created with password policy on and expiry off. Every instance after the first gets the **same SID**, so access survives an Availability Group failover. An existing login keeps its password. You get a warning if the SID doesn't match, or if the server only allows Windows authentication. Use `Export-WeeklyReports.ps1 -SqlCredential (Get-Credential)` to export with that login.

That's the whole install. It creates the database, collectors, report builder and 4 Agent jobs. It grants read-only access to your login, runs a first collection and builds a baseline report. It is safe to re-run, and re-running upgrades an existing install in place.

**Azure SQL Managed Instance?** Install the same way. The instance has no Windows logins, so give `-MolehillLogin` a Microsoft Entra user, group or app (`molehill@contoso.com`) or a SQL login. The report knows it's a Managed Instance:

* Patching, automated backups and HA are shown as Microsoft's. There are no false "no backup" or "unsupported SQL Server 2014" alarms, because a Managed Instance reports version 12.
* Storage is checked against the instance's reserved storage.
* Everything else (Agent jobs, error log, queries, integrity, configuration) is the same as SQL Server.

**Azure SQL Database?** There is nothing to install. See step 3.

*Manual alternative:* open `MolehillWatch_Install.sql` in SSMS and select the target database in the drop-down. That's `MolehillWatch` (create it first; the commands are at the top of the script) or the client's DBA database. Press F5, then run the short CONFIGURE block at the bottom.

### 3. Every Monday: weekly reports

On the client jump box:

```powershell
.\Export-WeeklyReports.ps1 -ServerList .\servers.txt -UpdatePatchReference
```

This writes an `index.html` with the RAG status and live patch status of every server. Next to it are the full reports and an Availability Group job/login parity check. `-UpdatePatchReference` first refreshes Microsoft's latest SQL Server and Windows Server build data, and needs internet access.

**If the jump box has no internet access:** on your own PC run `.\Update-PatchReference.ps1 -OutFile patch-reference.json`, copy the file across, then on the jump box run `.\Update-PatchReference.ps1 -InFile patch-reference.json -ServerList .\servers.txt`.

**Azure SQL Database** (per logical server; elastic pools are reported within their server):

```powershell
az login        # or Connect-AzAccount, or -SqlCredential for SQL authentication
.\Get-AzureSqlDatabaseReport.ps1 -Server contoso-sql -ClientName "Contoso Ltd" -AzurePlatformChecks
```

This covers the areas the agreement lists:

* backup retention and the earliest restore point
* DTU/vCore use, throttling and storage against the tier limit
* the top queries from Query Store
* elastic job failures (`-ElasticJobServer`/`-ElasticJobDatabase`)
* geo-replication and failover groups
* firewall rules, TDE, auditing and Defender for SQL
* cost observations: over-provisioned databases, pooling candidates, serverless, and reserved capacity

`-AzurePlatformChecks` reads the settings that live only in Azure (retention policies, auditing, Defender, failover groups) through the Azure CLI with Reader access. It also skips auto-paused serverless databases, so the report doesn't wake them up and start billing. The script is read-only.

Review the reports, send them to the client, then log each one. Use Molehill Manager (agreement > Weekly reports, F2) or:

```sql
EXEC MolehillAdmin.dbo.usp_WeeklyReport_Log @Client = N'Contoso Ltd', @InstanceName = N'SQL01', @OverallStatus = 'Amber';
```

See **[Docs/Admin-Guide.md](Docs/Admin-Guide.md)** for the everyday commands. **[Docs/Client-Onboarding-Guide.md](Docs/Client-Onboarding-Guide.md)** is written for you to send to the client.

---

## What's in the box

```
MolehillWatch\
├─ README.md
├─ Client\                                  ← copy to client
│  ├─ Install-MolehillWatch.ps1             one-command installer (1..n instances)
│  ├─ MolehillWatch_Install.sql             the database, collectors, report and jobs (SSMS-runnable)
│  ├─ MolehillWatch_Uninstall.sql           removes jobs + database
│  ├─ Export-WeeklyReports.ps1              saves reports as HTML + AG parity check + patch status
│  ├─ Update-PatchReference.ps1             loads Microsoft's latest SQL/Windows build data
│  ├─ Get-AzureSqlDatabaseReport.ps1        weekly report for Azure SQL Database (read-only, run from the jump box)
│  ├─ Invoke-MolehillCollect.ps1            collector for Express edition (Task Scheduler)
│  └─ servers.example.txt
├─ Admin\                                   ← your machine only
│  ├─ Install-MolehillAdmin.ps1
│  ├─ MolehillAdmin_Install.sql
│  ├─ Invoke-MolehillDaily.ps1              billing run + dashboard/invoice HTML
│  ├─ Example-NewClient.sql                 worked example / template
│  └─ MolehillManager\                      C# terminal front end: clients, tickets, billing
├─ Docs\
│  ├─ Admin-Guide.md                        your day-to-day runbook
│  └─ Client-Onboarding-Guide.md            send to the client
└─ Tools\
   ├─ Get-PatchStatus.ps1                   standalone patch check for any server (no install)
   ├─ Test-DatabaseStatus.ps1               "is everything back?" after a patch, reboot or restore
   ├─ Restore-DatabaseCopy.ps1              restores databases to another server, directly or via Azure Blob Storage
   ├─ Export-BackupHistory.sql              run on a source you cannot connect to, feeds the above
   ├─ Restore-LatestAzureBackup.ps1         restores the newest backup in a container, then tidies each copy
   ├─ Test-SqlTlsHandshake.ps1              why an instance will not negotiate encryption (old servers)
   ├─ Get-SqlLicensingAudit.ps1             what needs licensing across an estate, and the total to cover it
   ├─ Export-DatabaseSample.ps1             a random sample of every table, as zipped CSVs
   ├─ Test-SqlConnectionString.ps1          tests a list of connection strings (one-shot, no UI)
   ├─ SqlConnectionTester.ps1               the same app in PowerShell, for sites that forbid .exe files
   └─ SqlConnectionTester\                  C# terminal app: build, save and test connection strings
```

## Standalone patch check (`Tools\Get-PatchStatus.ps1`)

A single script, separate from Molehill Watch, for a quick "how out of date is this?" check. It's useful for prospects, one-off health checks and locked-down environments. It installs nothing and only runs read-only queries.

```powershell
.\Get-PatchStatus.ps1                                             # the server it's run on
.\Get-PatchStatus.ps1 -ComputerName SQL01, SQL02, 'SQL03\SALES'   # or -ServerList .\servers.txt
```

* **Finds SQL instances without WinRM:** first SQL Browser (UDP 1434), then the Windows service list (RPC), then the default instance. `SERVER\INSTANCE` or `SERVER,port` can be listed directly.
* **Reads Windows' security update level** through SQL Server (`xp_regread`, needs sysadmin), otherwise Remote Registry, otherwise the local registry when run on the server itself.
* **Compares** against the same Microsoft data as Molehill Watch, using the same rules, and writes an HTML report (`-CsvPath` for CSV too).
* **Exit code** is 0 (OK), 1 (warnings) or 2 (critical).
* **No internet on the server?** Run `.\Get-PatchStatus.ps1 -SaveReference patch-reference.json` somewhere with internet, and copy that file next to the script. It's picked up automatically.

## Database status check (`Tools\Test-DatabaseStatus.ps1`)

For straight after a patch, a reboot, a failover or a VM snapshot restore, when the only question is whether every database is back and connectable. It takes seconds, changes nothing, and gives a green line per database or a red one with the reason.

```powershell
.\Test-DatabaseStatus.ps1                   # asks for the instance
.\Test-DatabaseStatus.ps1 SQL01\SALES       # press R to run it again while a database recovers
.\Test-DatabaseStatus.ps1 SQL01 -NonInteractive -CsvPath .\status.csv
```

* **Every database, system ones included**: state (`RECOVERY_PENDING`, `SUSPECT`, `OFFLINE`, an unfinished `RESTORING`), user access (`SINGLE_USER` and `RESTRICTED_USER` keep applications out), read-only, standby, auto-close, suspect pages recorded in msdb, and Availability Group role, synchronisation state and health.
* **It actually connects** to each database and runs `SELECT 1`, which is the real proof that something else can. `-Quick` skips that on instances with hundreds of databases.
* **Instance header**: version and patch level, how long it has been up, and the SQL Server and SQL Agent services - an Agent set to start automatically but sitting stopped is a failure, because nothing will run the jobs or the backups.
* **Not a health check**: no DBCC CHECKDB, no backup history, nothing that takes minutes. Molehill Watch covers that side.
* **Exit code** is 0 (all green), 1 (something to check) or 2 (a failure), so it can go in a post-patch script.
* `-SelfTest` checks the pass/fail rules without needing a server.

## Licensing audit (`Tools\Get-SqlLicensingAudit.ps1`)

Takes a list of instances and produces the number you need before a licensing conversation: every licensable product in the estate, and the total to cover all of it. Read-only, installs nothing.

```powershell
.\Get-SqlLicensingAudit.ps1 -SqlInstance SQL01, SQL02, 'SQL03\SALES'
.\Get-SqlLicensingAudit.ps1 -ServerList .\servers.txt -IncludeHostInventory -SoftwareAssurance -Open
```

* **Counts by OS environment, not by instance.** Several instances on one server share one set of core licences, so instances are grouped by host first. The highest edition on a host licenses its cores and covers the ones below it through downgrade rights.
* **Where the processor numbers come from is stated on every row.** SQL Server 2012 and later report sockets and cores per socket. Older versions report only logical CPUs and a hyperthread ratio, which give the socket count but cannot say whether hyperthreading is on, so Windows is asked instead (`Win32_Processor` over RPC). If that is blocked, the count is inferred assuming hyperthreading is off - the higher number, which cannot leave you short - and the row says so. `-HardwareOverride @{ 'OLDSQL01' = '4x4' }` overrides the lot when you have looked it up yourself.
* **The rules it applies**: every physical core with a minimum of four per socket; every vCPU with a minimum of four per VM; two-core packs rounded up; Enterprise core-based only from 2012; Standard either core-based or Server + CAL, with both shown.
* **Free editions are listed and never totalled** - and flagged: Developer in production is the classic audit finding, Evaluation stops after 180 days, and an Express database near 10 GB is about to need a licence.
* **Passive failover replicas** are counted by default and shown separately as waivable, so you can see the number with and without Software Assurance. An AG secondary that allows reads or takes backups is reported as active, because it is.
* `-IncludeHostInventory` reads each host's service list over RPC to find Analysis, Reporting and Integration Services. Those need the host licensed and cannot be seen from a SQL connection, so an audit without them undercounts.
* **Money is optional.** Give `-CorePackPrice`, `-ServerLicencePrice` and `-CalPrice` and it totals cost and compares per core against Server + CAL at your `-UserCount`. Nothing is assumed: no list prices are baked in.
* Writes the same style of HTML report as the patch check, plus `-CsvPath`. **Exit code** is 0 (nothing to question), 1 (something to look at) or 2 (nothing audited).
* It counts what the estate needs. Entitlements - Software Assurance, agreement terms, existing packs, CAL counts - are on no server, so this is one half of the sum and your paperwork is the other.

## Restoring a copy to another server (`Tools\Restore-DatabaseCopy.ps1`)

Three jobs that turn out to be one script: refreshing a copy of a database onto another server, moving a large database with minutes of downtime instead of hours, and doing either of those when the two servers cannot see each other. It reads the source's backup history from `msdb`, works out the chain, and runs plain T-SQL restores on the destination. No modules at all unless you use the Azure option, which needs `Az.Storage`.

**Refresh**, safe to run on a schedule - it skips the work when that same backup is already restored there:

```powershell
.\Restore-DatabaseCopy.ps1 -SourceInstance SQL01 -DestinationInstance SQL02 -Database Sales
```

**Log shipping by hand**, for a cutover. Seed the copy whenever suits, catch it up as often as you like, then switch:

```powershell
.\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -KeepRestoring          # the full, the diff, the logs
.\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -KeepRestoring          # whenever: just the logs since
.\Restore-DatabaseCopy.ps1 SQL01 SQL02 Sales -Cutover -TailLog       # the ten minutes that matter
```

**Through Azure Blob Storage**, for when the destination cannot see the source's backup share - an old server being retired, another site, another network. Several databases in one run:

```powershell
.\Restore-DatabaseCopy.ps1 -SourceInstance OLDSQL -DestinationInstance NEWSQL `
    -Database Sales,Stock,Payroll -From AzureBlob -StorageAccountName mycompany `
    -ContainerName legacybackup -BlobPrefix OLDSQL -SasToken (Get-Secret -Name LegacyBackupSas) `
    -LocalBackupPath D:\RestoreStaging -TrustServerCertificate -RepairOrphanUsers
```

* **Where the files come from is the only difference between the two modes.** `-From Path` (default) uses the paths msdb recorded, as the destination sees them - `-BackupPathMap` translates one, and a local path on another machine is retried through its admin share (`\\SOURCE\D$\...`) automatically. `-From AzureBlob` pulls them out of a container into a staging folder first. Everything after that is identical, including rolling restores: each run downloads only the logs it still needs.
* **A source it cannot connect to is not a blocker.** `-SourceHistoryFile` reads the backup history from a CSV instead, produced by running `Tools\Export-BackupHistory.sql` on the source itself; the source is then never contacted. That is the answer for an out-of-support instance a current client cannot complete a TLS handshake with - the history was the only thing it ever read from there. `-TailLog` and `-DisconnectSource` still need a live source and are refused with it.
* **"Has this already been restored?"** is answered from the backup set's own id (`backup_set_uuid`) against the restore history on the destination, so it holds across servers and reboots rather than guessing from dates.
* **It will not use a half-uploaded backup.** With storage in the way, a backup msdb knows about but whose blob has not finished committing is passed over with the reason - and a rolling restore simply stops at the last log that made it across.
* **Catching up** reads how far the copy got from its own restore history and applies only what comes next, walking the chain by taking the backup that reaches furthest forward each time. That copes with copy-only backups and a second job writing its own files. A chain that does not join up is reported, with the LSN where it breaks.
* **It checks before it breaks anything**: the destination can read every file, the backup header matches the database it claims to be, the destination is not an older version than the backup, the target file paths are free, and the database it would overwrite really is a copy of the source (an unrelated database of that name needs `-Force`). If a restore fails, the destination is put back as it was found rather than left offline.
* **The source is read-only** unless you ask for `-TailLog` or `-DisconnectSource`. Those ask once, up front, and name exactly what they will do - a tail log leaves the source in a restoring state, which is the point of a cutover but has no undo.
* **Once it is online**: `-DatabaseOwner`, `-CompatibilityLevel`, `-RepairOrphanUsers` (which reports the users it cannot remap, and why, rather than failing), `-UpdateStatistics` and `-RunCheckDb`. `PAGE_VERIFY CHECKSUM` is set either way, and a copy of a single-user database is opened back up to `MULTI_USER`.
* **Connection problems are explained, not just reported.** `-TestConnectionOnly` runs the checks on their own. A failure gives what SQL Server said, what it means and what to try - the login error number and state, a refused or silently dropped port, SQL Browser for a named instance, and the two separate encryption traps: an untrusted certificate (add `-TrustServerCertificate`) and a TLS version mismatch (SQL Server 2008 R2 before SP3 + KB3135244 speaks TLS 1.0 only, which `-TrustServerCertificate` will not fix).
* `-Standby` leaves the copy readable between log restores, `-StopAt` restores to a point in time, `-LogLevel Quiet|Normal|Verbose|Debug` sets how much it says (`-Verbose`/`-Debug` raise it by themselves), `-LogFile` appends it all to a file, `-CsvPath` writes a row per database, `-WhatIf` prints the exact RESTORE statements and runs nothing, and `-SelfTest` checks the chain, statement and path logic with no server at all.
* **Several databases per run**, one pair of instances. A failure on one is reported and the rest carry on, with `PARTLY DONE (2 of 3)` in the summary. **Exit code** is 0 (done, or a clean dry run), 1 (something failed) or 2 (could not start).

## Refreshing from a container (`Tools\Restore-LatestAzureBackup.ps1`)

For keeping a set of databases topped up from backups that are already in blob storage, and handing the copies out in a known state. There is no source SQL Server in this one at all: the container is the source of truth, and the newest backup in each database's folder is the one restored.

The layout it expects is one folder per database:

```
FULL/DAILY/<database name>/<something>.bak
```

```powershell
.\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales,Stock `
    -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
    -LocalBackupPath D:\RestoreStaging

# refreshed, tidied, and handed to the reporting team read-only
.\Restore-LatestAzureBackup.ps1 -DestinationInstance SQL02 -Database Sales `
    -StorageAccountName mycompany -ContainerName backups -SasToken $sas `
    -LocalBackupPath D:\RestoreStaging -AddUser REPORTS\BiTeam -AddUserRole db_datareader -ReadOnly
```

* **Newest wins, by when the blob was written**, because there is no `msdb` here to ask. Only backup files are considered, so an upload log sitting in the folder is ignored. `-BlobPathPattern` changes the shape, with `{db}` standing in for the name.
* **It checks the file before touching the database**: the header has to say it is a full backup, of the database it claims to be, from a version this instance can restore. A log or differential backup, or one stripe of a set written across several files, is refused with what it actually is rather than failing inside `RESTORE`. That check also proves the SQL Server service account can read the staging folder, which is the usual reason a staged restore fails.
* **Then, with every database copied**, each one is tidied: users dropped except the built-in ones, owner set to `sa`, recovery model set to `SIMPLE`. A user owning a schema or a role has it handed to `dbo` first, because otherwise it cannot be dropped, and anything that still refuses is reported with the reason.
* `-AddUser` creates users for logins expected to exist already, **warning rather than failing** where one does not. `-AddUserRole` puts them in a role - without it they have no permissions at all. `-ReadOnly` is applied last, since a read-only database cannot be changed any further, and `-KeepUsers` opts out of the clearing.
* **`AUTO_CLOSE` silently undoes `READ_ONLY`** - a database that closes and reopens comes back read-write - so where it is on it is turned off first, and the read-only state is read back afterwards rather than assumed.
* Needs `Az.Storage` and nothing else; the restores are plain T-SQL. `-WhatIf` lists the backup it would use and changes nothing, `-SelfTest` checks the folder paths, the newest-backup choice and which principals are spared with nothing installed. **Exit code** is 0 (all done, or a clean dry run), 1 (at least one failed) or 2 (could not start).

**Run it on the destination server if you can.** `-LocalBackupPath` has to be readable by the SQL Server service account, not just by you, so a path under `C:\Users` will not do.

## Why encryption will not negotiate (`Tools\Test-SqlTlsHandshake.ps1`)

SQL Server encrypts the login packet whatever else you ask for, so every connection begins with a TLS handshake - and on an old instance that is where connections die. The error a client hands back ("pre-login handshake", "certificate chain", "no common algorithm") rarely says which side refused or why, and `-TrustServerCertificate` only fixes one of the possible causes.

```powershell
.\Test-SqlTlsHandshake.ps1 LEGACYSERVER2008R2
.\Test-SqlTlsHandshake.ps1 -ServerList .\legacy-servers.txt   # a whole estate at once
.\Test-SqlTlsHandshake.ps1 -ClientOnly                        # just what this machine will agree to
```

It speaks TDS directly: opens the socket, sends a PRELOGIN packet, and runs the TLS handshake itself - wrapped in TDS packets, the way a real client does - once per TLS version. No login is attempted and no credentials are needed.

* **Per TLS version**, whether the handshake succeeded and with which cipher, or the exact error. It also tries "whatever Windows picks by default", which is what real clients ask for - an instance can manage TLS 1.0 while a default client is never offered it.
* **The certificate it presents**: subject, issuer, signature algorithm, key size and dates. A self-signed 1024-bit SHA1 certificate is normal on an old instance, and a common reason a modern client walks away.
* **What this machine will agree to**, by handshaking with itself, so the client can be ruled out rather than suspected - including whether the old cipher suites an out-of-support instance may be limited to (3DES, RC4) are still enabled here. On current Windows they often are not, and a missing cipher looks exactly like a protocol problem.
* **It tells a reset apart from a refusal**, which is the distinction that matters most. An old TLS stack that cannot parse a modern ClientHello closes the socket instead of replying, and the client reports only "An existing connection was forcibly closed by the remote host" - which says nothing about the cause unless you know how to read it. Where that is what happened it says so, and sends you to the instance's own error log, to anything inspecting TLS in between, and to the ways of doing the job without connecting to it at all.
* **What it means**, spelled out for each combination: a working handshake sends you back to the login; only a named version working points at the instance's patch level (KB3135244 adds TLS 1.2 to SQL Server 2008, 2008 R2 and 2012, on specific builds per service pack); "no common algorithm" points at the cipher suites, or at the certificate when it is the weak one an old instance generates for itself. Where a registry change is the answer it gives the exact commands, says plainly that it weakens the machine's TLS policy for everything on it, and tells you how to undo it.
* `-SelfTest` checks that reasoning - how it reads each combination of results - without a server or a socket.
* **Exit code** is 0 (something negotiated), 1 (nothing did) or 2 (could not get that far).

## Table samples as CSV (`Tools\Export-DatabaseSample.ps1`)

Takes a random sample of rows from every user table in a database, writes one CSV per table and zips the lot. For handing a developer realistic shaped data, reproducing a problem somewhere safe, or seeing what is actually in a database you have just been given.

```powershell
.\Export-DatabaseSample.ps1 -SqlInstance SQLPROD01 -Database Sales -TrustServerCertificate
.\Export-DatabaseSample.ps1 -SqlInstance myserver.database.windows.net -Database Sales -SqlCredential (Get-Credential) -Top 500
```

* `SELECT TOP (n) ... ORDER BY NEWID()` per table, 200 rows by default (`-Top`, or `-n`), to `<OutputPath>\<Database>\<schema>.<table>.csv` and then into `<Database>.zip`. `-RemoveFolderAfterZip` leaves just the zip.
* **Works anywhere**: SQL Server on-premises or on an IaaS VM, Azure SQL Managed Instance and Azure SQL Database. It connects straight to the database, so there is no `USE` to trip over on Azure SQL Database. Windows, SQL and Entra ID authentication (`-UseEntraId` needs `Az.Accounts`; `-AccessToken` if you bring your own).
* **The awkward columns are handled**: `geography`, `geometry` and `hierarchyid` are converted server side so no client assemblies are needed; `binary` and `rowversion` come out as `0x` hex; dates are ISO 8601 and numbers invariant; files are UTF-8 with a BOM and CRLF so Excel opens them without a fight; values are quoted per RFC 4180 only where they need to be. Empty tables still get a header row.
* **It keeps going**: a table whose column list fails - graph tables, say - is retried once with `SELECT *`, external and diagram tables are skipped, and a failure is reported per table rather than stopping the run. `-ReadUncommitted` keeps it off the locks on a busy production table.
* Prints a run summary and **returns a result object** (`Exported`, `Failed`, `TotalRows`, `ZipPath`, `Tables`) rather than setting an exit code, so pipe it or assign it when scripting.
* No modules needed for the SQL Server and SQL authentication paths; ADO.NET only, on PowerShell 5.1 or 7.

**It copies real data out of a database.** Where that data is personal or confidential, a sample is still personal or confidential: mind where the zip goes, and whether you should be using masked or synthetic data instead.

## Connection string tester (`Tools\Test-SqlConnectionString.ps1`)

Takes a list of SQL Server connection strings, reads `dbo.TestConnection` (one column `TestText`, one row) through each, and reports `ConnectionString`, `TestText`, `Status` and `ErrorMessage`. Useful when an application can't connect and you need to prove which strings work, from which machine, as which account.

```powershell
.\Test-SqlConnectionString.ps1 -ConnectionString $strings | Format-List
.\Test-SqlConnectionString.ps1 -Path .\connections.txt -CsvPath .\results.csv
```

* **The error is complete**: every error in the `SqlException` collection (message number, severity, state, procedure, line, server), every inner exception, and the client connection id. Nothing is shortened.
* Results are objects, so pipe them to `Format-List`, `Export-Csv` or `-CsvPath`. A plain run shows PowerShell's table, which shortens long errors on screen - use `-Detailed` or `Format-List` to read them.
* `-MaskPasswords` replaces passwords in the returned connection strings before you share the results. `-ConnectTimeoutSeconds` overrides slow timeouts.
* Read-only: it creates and changes nothing.

## Connection tester app (`Tools\SqlConnectionTester`)

A C# terminal app (Terminal.Gui) that does the same test as the PowerShell script, but lets you build and keep connection strings interactively and covers every SQL Server sign-in method, including Entra ID interactive/MFA, device code, service principal, managed identity and default. See its [README](Tools/SqlConnectionTester/README.md).

```powershell
cd Tools\SqlConnectionTester
dotnet run                     # the app: F2 add, F5 test, F7 full error, F8 export CSV
dotnet run -- --test           # headless, for scripts
```

**Cannot run an .exe at a client site?** `Tools\SqlConnectionTester.ps1` is the same app written in PowerShell, with the same screen, keys and JSON file, so the two can share a connections file:

```powershell
.\SqlConnectionTester.ps1                        # the app
.\SqlConnectionTester.ps1 -Test                  # headless
.\SqlConnectionTester.ps1 'Server=SQL01;...'     # test one connection string
```

It needs no modules. Windows and SQL logins always work; the Entra ID methods need Microsoft.Data.SqlClient, which it finds in the SqlServer module, SSMS or Azure Data Studio (or `-SqlClientDll`), and it marks the methods it cannot do rather than failing oddly later.

Saved connections live in a JSON file (`--file` for one per client); passwords are only kept if you ask, and are then encrypted for your Windows account. Publish a single self-contained `.exe` for servers without .NET:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o publish
```

## How the contract maps to the toolkit

| Contract clause | Implemented by |
|---|---|
| Weekly report: backups and backup failures | Last full/diff/log per database vs thresholds; backup failures in the error log; backups on the same drive as data; AG backup-preference aware. Identifies the backup tool (native, Azure Backup / Recovery Services vault, backup to URL, third-party, VM/VSS snapshot), flags log backups split across more than one tool and databases whose only fulls are VM snapshots. Vault-side health (recovery points, retention, vault alerts) isn't visible from SQL Server; missed vault backups surface through the overdue thresholds. |
| Weekly report: error log issues | Hourly error-log capture, classified by editable patterns (corruption, dumps, storage latency, memory, AG, login failures…) with recommendations |
| Weekly report: failed Agent jobs | Hourly capture of failed job history (survives msdb purges), Agent service status |
| Weekly report: top 10 poorly performing queries | Hourly plan-cache snapshots, ranked by CPU used during the week |
| Weekly report: capacity (disk, database growth) | Daily disk and file snapshots: % free, days-to-full projection, 7/30-day growth, log usage, max-size and autogrowth risks |
| Weekly report: AG health, latency, failover readiness | 5-minute AG samples: sync state, send/redo queue, lag, failover readiness, disconnected replicas; plus mirroring, log shipping, FCI nodes |
| Weekly report: patching (extra) | **Windows Server 2016–2025:** the installed OS build (`CurrentBuild.UBR`) compared with the build that contains each month's security update, from Microsoft's MSRC security API. Info within the 14-day grace period after Patch Tuesday, Warning after that, Critical once two monthly updates are missed. Feature/preview updates are ignored. **SQL Server:** the build compared with Microsoft's published CU/GDR list on the branch in use (CU or GDR). Warning when behind the latest CU for 30+ days, Critical at 3+ CUs behind, Info when a newer "CU + GDR" security release exists on top of the latest CU. |
| Secondary replicas: job parity between replicas | `Export-WeeklyReports.ps1` compares jobs (steps, enabled) and logins (incl. SQL login SIDs) across replicas |
| Obvious risks / recommendations | CHECKDB overdue, suspect pages, DBs not online, auto-shrink/close, page verify, max memory, blocking chains |
| Unsupported versions recorded and noted weekly | Lifecycle table on both sides; risk acceptance recorded in Admin and shown in every weekly report |
| Severity response targets, business hours, UK bank holidays | `fn_ResponseDue`: Critical = same business day, Standard = end of next business day; out-of-hours tickets start the next business day |
| 3 included hours per month, no roll-over | Tracked per billing cycle; `usp_Agreement_Usage`; dashboard warns at 80% |
| >1 hour work flagged with an estimate | `usp_Time_Log` warns; dashboard lists tickets needing an estimate |
| £75 BH / £115 OOH, 1 hour minimum per ticket | Applied when invoicing arrears (see *Minimum charge* below) |
| £450 / £375 from 3rd server / £225 secondaries, FCI per instance, non-prod by agreement | `fn_AgreementFees` |
| Azure SQL Managed Instance priced as a production instance and counts towards the tiers | `usp_Instance_Add @Platform = 'AzureSqlManagedInstance'` |
| Azure SQL Database: £300 per logical server or elastic pool up to 5 databases, £40 per extra database, geo-replicas included, outside the tiers | `usp_Instance_Add @Platform = 'AzureSqlDatabaseServer'` / `'AzureSqlDatabaseElasticPool'`, `@DatabaseCount`; `@Role = 'GeoReplica'` for failover group secondaries. Keep the count current with `usp_Instance_Update @DatabaseCount` (or Molehill Manager). |
| Managed Instance: same weekly report and coverage as SQL Server | Molehill Watch detects EngineEdition 8. Microsoft-managed areas (patching, automated backups, HA, OS) are reported as such, and storage is checked against the instance's reserved storage. |
| Azure SQL Database weekly report (retention, DTU/vCore, storage headroom, throttling, Query Store, elastic jobs, geo-replication, firewall, auditing, Defender, cost/tier) | `Client\Get-AzureSqlDatabaseReport.ps1` (read-only; `-AzurePlatformChecks` adds the Azure Resource Manager settings) |
| Pre-paid support hours as an add-on (hours and rate negotiable) | `usp_Prepaid_Add` / `_Show` / `_Update` / `_Cancel`. Invoiced up front. Arrears billing uses them for business-hours time after the included hours and before the business-hours rate, soonest-expiring first. Out-of-hours work is never taken from them. Optional expiry; dashboard alerts when hours are low, used up or expiring. |
| Out-of-hours: Azure tier changes, migrations, failover tests | Open the ticket with `@WorkType = 'PlannedOutOfHours'` and log the time `OutOfHours` |
| Invoiced monthly in advance from start date, arrears for extra time, 14 days, no VAT, no pro-rata | `usp_Billing_Run` creates draft invoices; `usp_Invoice_Html` renders them |
| Late payment may pause support | Dashboard overdue alerts; `usp_Agreement_PauseSupport`; ticket warnings |
| 3-month initial term, review, 1 full calendar month's notice to end of billing cycle | `fn_EndDateForNotice`, `usp_Notice_Give`, review reminder on the dashboard |
| Price review max once a year with 1 month's notice | `usp_PriceChange_Schedule` refuses changes that break either rule |
| Onboarding and access checklist | Created automatically with each agreement; shown on the dashboard until done |
| Client data stays on client infrastructure | Reports are stored in the client's own database and exported on the client's jump box. E-mail is off by default and never includes query text unless enabled. |

## Requirements

* **Client side:** SQL Server 2012 or later on Windows. SQL Server Agent is used where available. **Express edition** has no Agent, so run the installer on the server with `-UseTaskScheduler`; this grants `NT AUTHORITY\SYSTEM` sysadmin so the scheduled tasks can collect, so agree that with the client first. The installer needs Windows PowerShell 5.1 or PowerShell 7 and no extra modules.
* **Azure SQL Managed Instance:** the same installer, from a machine that can reach the instance. SQL Agent is always available.
* **Azure SQL Database:** Windows PowerShell 5.1 or PowerShell 7 on the jump box. Sign in with the Azure CLI (`az login`), Az PowerShell, or `-SqlCredential`. The account needs VIEW DATABASE STATE in each database and access to master. `-AzurePlatformChecks` also needs the Azure CLI with Reader on the resource group.
* **Admin side:** SQL Server 2017 or later (Express/Developer fine) on a Windows machine you control. Molehill Manager needs the .NET 8 SDK to run from source, or nothing at all as a published single `.exe`.

## Decisions and assumptions to review

1. **Minimum charge.** The contract says "minimum charge of 1 hour per ticket" but doesn't say how that interacts with included hours. The default (`MinimumChargeMode = Fair`) uses included hours at the actual time worked. Once a ticket spills into chargeable time, it's billed so its total is at least 1 hour. `Strict` applies the 1-hour minimum before included hours are deducted, so three 10-minute tickets would use all 3 included hours. Change it with `UPDATE MolehillAdmin.dbo.Setting SET Value = 'Strict' WHERE Name = 'MinimumChargeMode'`.
2. **Critical tickets** raised in business hours are due by 17:30 the same day. Tickets raised outside hours are treated as received at 09:00 the next business day.
3. **"1 full calendar month's notice"** runs to the end of the calendar month after the notice date. The agreement then ends at the close of the billing cycle current at that point, and never before the initial term ends.
4. **New instances** are billed from the first cycle that starts after they're covered (no pro-rata). The exception is instances added before the agreement's first invoice (onboarding): these are covered from the start date, so the first month is charged. Instances with a bespoke `@AgreedMonthlyFee` don't count towards the multi-server tiers. A cycle with nothing to charge produces no invoice, not a £0 one.
5. **Bank holidays** are England & Wales, seeded to 2030. The dashboard reminds you to add more. Scotland/NI clients: edit `dbo.BankHoliday`.
6. **Lifecycle dates** for SQL Server and Windows are seeded from Microsoft's published dates. SQL Server 2025 is left blank. Check them at learn.microsoft.com/lifecycle.
7. **Patching checks** cover the monthly Windows OS security update only, not .NET, drivers or other software. Windows Server 2012/2012 R2 can't be checked automatically (their update level isn't in the registry in a comparable form), and neither can hotpatch-only months on Windows Server 2025 Azure Edition. The build data is refreshed by `Update-PatchReference.ps1`; the report warns if it is more than 40 days old. Thresholds are settings in `mw.Setting` (`SqlPatchGraceDays`, `SqlCuBehindCritical`, `SqlSecurityUpdateSeverity`, `WindowsPatchGraceDays`).
8. **Testing:** everything was installed and exercised end-to-end on **SQL Server 2019 and SQL Server 2025** (LocalDB/Express), including 59 automated checks of the commercial rules on both (fresh install and upgrade). Molehill Manager has a read-only self-test of every screen and form, and a scripted run that submits every form against a test database (60 checks). It has not been run on SQL 2012–2017, or on a live Availability Group or FCI. Those code paths are version-guarded, but do a first install on a non-critical instance.
9. **Error log reading on LocalDB:** `xp_readerrorlog` returns nothing on SQL Server 2025 LocalDB (and ends .NET connections with a severity 20 error). Real instances are unaffected - the SQL Server 2025 instance used for testing reads its log normally. The weekly report raises a Monitoring warning when the error log cannot be read, so an empty error log section is never mistaken for a clean one, and error log collection runs last so nothing else is lost.
10. **Azure pricing details the agreement doesn't spell out:**
    * A Managed Instance geo-replica or failover-group secondary is charged at the £225 secondary rate. The agreement only says "included" for Azure SQL Database.
    * An Azure SQL Database geo-replica is £0 and needs no database count.
    * Very large or sprawling Azure SQL Database estates are "quoted on a bespoke basis". Use `@AgreedMonthlyFee` for those.
11. **Azure was not available for testing.**
    * **Managed Instance:** the handling was exercised on SQL Server 2025 LocalDB with the testing-only setting `TestAsManagedInstance = 1` (leave it at 0). The things only a real instance has, `sys.server_resource_stats` and Entra `FROM EXTERNAL PROVIDER` logins, have not been run.
    * **Azure SQL Database report:** the connection, Query Store, findings and HTML code was run against LocalDB, and every Azure-only DMV (`sys.resource_stats`, `sys.dm_database_backups`, geo-replication, firewall) degrades to a "could not check" line rather than failing. The Azure queries and the `az` calls themselves have not been run against Azure.
    * Do the first run of each with the client's DBA watching.
12. **Pre-paid hours:**
    * They cover business-hours work only. Out-of-hours work is always billed at the out-of-hours rate.
    * The 1-hour minimum per ticket still applies. A ticket with 15 minutes of chargeable business-hours time uses 1 pre-paid hour, just as it would be billed 1 hour.
    * Unused hours are lost at expiry; the dashboard warns 30 days before. Extend with `usp_Prepaid_Update`.

## Uninstall

* Client: run `Client\MolehillWatch_Uninstall.sql` in the database Molehill Watch was installed into. It removes the jobs and everything in the `mw` schema. It drops the database only if it's the default `MolehillWatch` and is left empty; a client's DBA database is never dropped. The header lists anything left for manual removal.
* Admin: `DROP DATABASE MolehillAdmin;` and `Unregister-ScheduledTask -TaskName 'Molehill Admin - Daily'`.
