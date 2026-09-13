# Molehill Watch – SQL Server Support Package toolkit

*Catching molehills before they're mountains.*

Everything Molehill Data Services needs to deliver the **Molehill Watch SQL Server Support Package** once a client signs up.

It has two halves:

| | Where it runs | What it does |
|---|---|---|
| **Client** (`Client\`) | Each covered client SQL Server (and every AG replica) | The `MolehillWatch` database and Agent jobs. They collect health data and build the **weekly status report**. |
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

That's the whole install. It creates the database, collectors, report builder and 4 Agent jobs. It grants read-only access to your login, runs a first collection and builds a baseline report. It is safe to re-run, and re-running upgrades an existing install in place.

*Manual alternative:* open `MolehillWatch_Install.sql` in SSMS, press F5, then run the short CONFIGURE block at the bottom.

### 3. Every Monday: weekly reports

On the client jump box:

```powershell
.\Export-WeeklyReports.ps1 -ServerList .\servers.txt
```

This writes an `index.html` with the RAG status of every server. Next to it are the full reports and an Availability Group job/login parity check. Review them, send them to the client, then log each one:

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
│  ├─ Export-WeeklyReports.ps1              saves reports as HTML + AG parity check
│  ├─ Invoke-MolehillCollect.ps1            collector for Express edition (Task Scheduler)
│  └─ servers.example.txt
├─ Admin\                                   ← your machine only
│  ├─ Install-MolehillAdmin.ps1
│  ├─ MolehillAdmin_Install.sql
│  ├─ Invoke-MolehillDaily.ps1              billing run + dashboard/invoice HTML
│  └─ Example-NewClient.sql                 worked example / template
└─ Docs\
   ├─ Admin-Guide.md                        your day-to-day runbook
   └─ Client-Onboarding-Guide.md            send to the client
```

## How the contract maps to the toolkit

| Contract clause | Implemented by |
|---|---|
| Weekly report: backups and backup failures | Last full/diff/log per database vs thresholds; backup failures in the error log; backups on the same drive as data; AG backup-preference aware |
| Weekly report: error log issues | Hourly error-log capture, classified by editable patterns (corruption, dumps, storage latency, memory, AG, login failures…) with recommendations |
| Weekly report: failed Agent jobs | Hourly capture of failed job history (survives msdb purges), Agent service status |
| Weekly report: top 10 poorly performing queries | Hourly plan-cache snapshots, ranked by CPU used during the week |
| Weekly report: capacity (disk, database growth) | Daily disk and file snapshots: % free, days-to-full projection, 7/30-day growth, log usage, max-size and autogrowth risks |
| Weekly report: AG health, latency, failover readiness | 5-minute AG samples: sync state, send/redo queue, lag, failover readiness, disconnected replicas; plus mirroring, log shipping, FCI nodes |
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
7. **Testing:** everything was installed and exercised end-to-end on SQL Server 2019 (LocalDB/Express), including 39 automated checks of the commercial rules. It has not been run on SQL 2012–2017 or on a live Availability Group or FCI. Those code paths are version-guarded, but do a first install on a non-critical instance.

## Uninstall

* Client: run `Client\MolehillWatch_Uninstall.sql` (removes the jobs and the `MolehillWatch` database; the header lists anything left for manual removal).
* Admin: `DROP DATABASE MolehillAdmin;` and `Unregister-ScheduledTask -TaskName 'Molehill Admin - Daily'`.
