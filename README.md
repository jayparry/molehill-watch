# Molehill Watch – SQL Server Support Package toolkit

*Catching molehills before they're mountains.*

Everything Molehill Data Services needs to deliver the **Molehill Watch SQL Server Support Package** once a client signs up.

It has two halves:

| | Where it runs | What it does |
|---|---|---|
| **Client** (`Client\`) | Each covered client SQL Server (and every AG replica) | Objects in an `mw` schema, in the `MolehillWatch` database or the client's existing DBA database, plus Agent jobs. They collect health data and build the **weekly status report**. |
| **Admin** (`Admin\`) | Your own SQL Server (Express is fine) | The `MolehillAdmin` database: clients, agreements, pricing, **tickets and SLA times**, time logging, **included hours**, billing cycles, **invoices**, notice periods and a daily **dashboard**. |

---

## Quick start

### 1. Once: install Molehill Admin on your own machine

```powershell
cd Admin
.\Install-MolehillAdmin.ps1 -SqlInstance .\SQLEXPRESS -PaymentDetails "Account name, sort code, account number"
```

This creates the database and schedules a daily 07:00 run. Each run creates draft invoices when they're due and writes `Dashboard.html` plus the invoice HTML files to `Documents\Molehill Admin`.

Then open `Admin\Example-NewClient.sql` in SSMS and press F5. It's a full worked example that rolls itself back.

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

*Manual alternative:* open `MolehillWatch_Install.sql` in SSMS and select the target database in the drop-down. That's `MolehillWatch` (create it first; the commands are at the top of the script) or the client's DBA database. Press F5, then run the short CONFIGURE block at the bottom.

### 3. Every Monday: weekly reports

On the client jump box:

```powershell
.\Export-WeeklyReports.ps1 -ServerList .\servers.txt -UpdatePatchReference
```

This writes an `index.html` with the RAG status and live patch status of every server. Next to it are the full reports and an Availability Group job/login parity check. `-UpdatePatchReference` first refreshes Microsoft's latest SQL Server and Windows Server build data, and needs internet access.

**If the jump box has no internet access:** on your own PC run `.\Update-PatchReference.ps1 -OutFile patch-reference.json`, copy the file across, then on the jump box run `.\Update-PatchReference.ps1 -InFile patch-reference.json -ServerList .\servers.txt`. Review them, send them to the client, then log each one:

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
│  ├─ Invoke-MolehillCollect.ps1            collector for Express edition (Task Scheduler)
│  └─ servers.example.txt
├─ Admin\                                   ← your machine only
│  ├─ Install-MolehillAdmin.ps1
│  ├─ MolehillAdmin_Install.sql
│  ├─ Invoke-MolehillDaily.ps1              billing run + dashboard/invoice HTML
│  └─ Example-NewClient.sql                 worked example / template
├─ Docs\
│  ├─ Admin-Guide.md                        your day-to-day runbook
│  └─ Client-Onboarding-Guide.md            send to the client
└─ Tools\
   ├─ Get-PatchStatus.ps1                   standalone patch check for any server (no install)
   ├─ Test-SqlConnectionString.ps1          tests connection strings by reading dbo.TestConnection
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
| Invoiced monthly in advance from start date, arrears for extra time, 14 days, no VAT, no pro-rata | `usp_Billing_Run` creates draft invoices; `usp_Invoice_Html` renders them |
| Late payment may pause support | Dashboard overdue alerts; `usp_Agreement_PauseSupport`; ticket warnings |
| 3-month initial term, review, 1 full calendar month's notice to end of billing cycle | `fn_EndDateForNotice`, `usp_Notice_Give`, review reminder on the dashboard |
| Price review max once a year with 1 month's notice | `usp_PriceChange_Schedule` refuses changes that break either rule |
| Onboarding and access checklist | Created automatically with each agreement; shown on the dashboard until done |
| Client data stays on client infrastructure | Reports are stored in the client's own database and exported on the client's jump box. E-mail is off by default and never includes query text unless enabled. |

## Requirements

* **Client side:** SQL Server 2012 or later on Windows. SQL Server Agent is used where available. **Express edition** has no Agent, so run the installer on the server with `-UseTaskScheduler`; this grants `NT AUTHORITY\SYSTEM` sysadmin so the scheduled tasks can collect, so agree that with the client first. The installer needs Windows PowerShell 5.1 or PowerShell 7 and no extra modules.
* **Admin side:** SQL Server 2017 or later (Express/Developer fine) on a Windows machine you control.

## Decisions and assumptions to review

1. **Minimum charge.** The contract says "minimum charge of 1 hour per ticket" but doesn't say how that interacts with included hours. The default (`MinimumChargeMode = Fair`) uses included hours at the actual time worked. Once a ticket spills into chargeable time, it's billed so its total is at least 1 hour. `Strict` applies the 1-hour minimum before included hours are deducted, so three 10-minute tickets would use all 3 included hours. Change it with `UPDATE MolehillAdmin.dbo.Setting SET Value = 'Strict' WHERE Name = 'MinimumChargeMode'`.
2. **Critical tickets** raised in business hours are due by 17:30 the same day. Tickets raised outside hours are treated as received at 09:00 the next business day.
3. **"1 full calendar month's notice"** runs to the end of the calendar month after the notice date. The agreement then ends at the close of the billing cycle current at that point, and never before the initial term ends.
4. **New instances** are billed from the first cycle that starts after they're covered (no pro-rata). Instances with a bespoke `@AgreedMonthlyFee` don't count towards the multi-server tiers.
5. **Bank holidays** are England & Wales, seeded to 2030. The dashboard reminds you to add more. Scotland/NI clients: edit `dbo.BankHoliday`.
6. **Lifecycle dates** for SQL Server and Windows are seeded from Microsoft's published dates. SQL Server 2025 is left blank. Check them at learn.microsoft.com/lifecycle.
7. **Patching checks** cover the monthly Windows OS security update only, not .NET, drivers or other software. Windows Server 2012/2012 R2 can't be checked automatically (their update level isn't in the registry in a comparable form), and neither can hotpatch-only months on Windows Server 2025 Azure Edition. The build data is refreshed by `Update-PatchReference.ps1`; the report warns if it is more than 40 days old. Thresholds are settings in `mw.Setting` (`SqlPatchGraceDays`, `SqlCuBehindCritical`, `SqlSecurityUpdateSeverity`, `WindowsPatchGraceDays`).
8. **Testing:** everything was installed and exercised end-to-end on **SQL Server 2019 and SQL Server 2025** (LocalDB/Express), including 39 automated checks of the commercial rules on both. It has not been run on SQL 2012–2017, or on a live Availability Group or FCI. Those code paths are version-guarded, but do a first install on a non-critical instance.
9. **Error log reading on LocalDB:** `xp_readerrorlog` returns nothing on SQL Server 2025 LocalDB (and ends .NET connections with a severity 20 error). Real instances are unaffected - the SQL Server 2025 instance used for testing reads its log normally. The weekly report raises a Monitoring warning when the error log cannot be read, so an empty error log section is never mistaken for a clean one, and error log collection runs last so nothing else is lost.

## Uninstall

* Client: run `Client\MolehillWatch_Uninstall.sql` in the database Molehill Watch was installed into. It removes the jobs and everything in the `mw` schema. It drops the database only if it's the default `MolehillWatch` and is left empty; a client's DBA database is never dropped. The header lists anything left for manual removal.
* Admin: `DROP DATABASE MolehillAdmin;` and `Unregister-ScheduledTask -TaskName 'Molehill Admin - Daily'`.
