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
