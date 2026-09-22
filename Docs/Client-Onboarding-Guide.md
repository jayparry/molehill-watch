# Molehill Watch – getting started

**Molehill Data Services** · jay@jayparry.co.uk · molehilldataservices.com

Welcome to the Molehill Watch SQL Server Support Package. This guide explains what we need from you, what we install on your SQL Servers and how to raise a support ticket.

---

## 1. What we need from you

Please send or arrange the following. Onboarding and your first weekly report start once these are in place.

- [ ] **A named point of contact** for support ticket queries (name, e-mail, phone)
- [ ] **An agreed channel for raising tickets.** The default is e-mail to jay@jayparry.co.uk.
- [ ] **Remote access** to each covered SQL Server, e.g. VPN, Azure Bastion or another agreed method
- [ ] **SSMS access** to each covered instance. A jump box with SQL Server Management Studio is preferred; SSMS on each server with RDP access is also fine.
- [ ] **An account for Molehill Data Services.** A Windows/AD account is preferred, e.g. `YOURDOMAIN\svc-molehill`. If your servers aren't joined to a domain or Entra ID, a SQL login is fine. The installer can create it for you (see section 3), but SQL Server must allow "SQL Server and Windows Authentication mode".
- [ ] **A list of covered instances**, including every Availability Group replica, with the SQL Server version and edition of each. For Azure, list each **Managed Instance**, and each Azure SQL Database **logical server or elastic pool** with how many databases it holds.
- [ ] **For Azure SQL**, a Microsoft Entra account for Molehill Data Services with:
  * **Reader** on the resource groups concerned, so we can check retention, auditing, Defender and failover group settings
  * a database user with `VIEW DATABASE STATE` in each covered Azure SQL Database
  * access to the logical server's `master` database (the server-level `##MS_ServerStateReader##` role covers both)
  * the jump box's IP address allowed through the server firewall, or a private endpoint
- [ ] **Someone with sysadmin rights** for about 15 minutes to run the installer (or grant temporary rights for us to do it)
- [ ] *(Optional)* a confidentiality agreement or Data Processing Agreement, if you would like one

**If any server runs a SQL Server or Windows version Microsoft no longer supports,** we'll ask you to confirm in writing that you accept the associated risks. The contract section "Unsupported SQL Server Versions" explains what that means.

---

## 2. What gets installed

We run one installer per server:

```powershell
.\Install-MolehillWatch.ps1 -SqlInstance SQL01,SQL02 -ClientName "Your Company Ltd" -MolehillLogin "YOURDOMAIN\svc-molehill"
```

It creates:

| Item | Details |
|---|---|
| Database **MolehillWatch** *(or your existing DBA database)* | Small (typically under 1 GB), SIMPLE recovery. It holds health history and weekly reports. It does **not** need backing up or adding to an Availability Group. **If you already have a DBA/admin database, we can use that instead of creating a new one.** Everything goes in its own `mw` schema, your database's settings aren't changed, and we can't see anything outside that schema. The database must not be in an Availability Group. |
| SQL Agent job **Molehill Watch - Collect Frequent** | Every 5 minutes: Availability Group health and long blocking chains. It takes milliseconds. |
| SQL Agent job **Molehill Watch - Collect Hourly** | New error log entries, failed job history, query statistics |
| SQL Agent job **Molehill Watch - Collect Daily** | 05:30: disk space and database sizes, old-history clean-up |
| SQL Agent job **Molehill Watch - Weekly Report** | Mondays 06:30: builds the weekly status report |

The jobs only **read** server metadata: DMVs, msdb history, the error log and the Windows version/update level from the registry. They don't change your databases, settings or existing jobs.

**Patching checks:** each week we compare the SQL Server version and Windows Server security update level against Microsoft's published release lists. This shows whether the latest cumulative update and monthly security patches are installed. The lists are downloaded from Microsoft by us; your servers don't need internet access.

**Express edition** has no SQL Agent. We use Windows Task Scheduler instead, which requires the local SYSTEM account to have sysadmin rights on that instance. We'll agree this with you first.

**Azure SQL Managed Instance** gets the same installer, jobs and weekly report as SQL Server. The one difference is the database, which uses FULL recovery because that is all Managed Instance supports. Microsoft looks after patching, automated backups and high availability, and the report says so rather than flagging them. We still watch the parts that remain yours:

* Agent jobs
* errors and query performance
* storage
* integrity checks
* configuration

**Azure SQL Database** has nothing installed at all. Each week we run a read-only report from your jump box. It covers:

* backup retention
* DTU/vCore use, throttling and storage headroom
* the slowest queries (from Query Store)
* elastic job failures
* geo-replication and failover groups
* firewall rules, auditing and Microsoft Defender for SQL
* cost and service tier suggestions

It creates nothing in Azure and changes nothing. Auto-paused serverless databases are skipped, so running the report never wakes them up (and adds to your bill).

---

## 3. Permissions for the Molehill Data Services account

The installer grants **read-only** visibility:

* `VIEW SERVER STATE` and `VIEW ANY DEFINITION` to see health, configuration and performance data
* `CONNECT ANY DATABASE` (SQL Server 2014+) to see database-level health information. It does **not** allow reading your data.
* Read access to SQL Agent job definitions and history, and backup history, in msdb
* Read access to the Molehill Watch objects (the `mw` schema only), plus permission to refresh its table of Microsoft's published update builds

To carry out fixes you've approved, we may need higher rights temporarily, for example to restart a job or change a setting. We'll always ask first.

**If we use a SQL login** (servers not joined to a domain):

* The installer creates it with your Windows password policy enforced. Password expiry is turned off so the weekly reports don't stop without warning.
* It has the same SID on every server, so it keeps working after an Availability Group failover.
* The password is typed in at install time and is never saved in any script or file. We keep it in our password manager.
* If you'd rather create the login yourself, create it before we run the installer and we'll only grant the permissions above.

**On an Azure SQL Managed Instance** there are no Windows logins, so we use a Microsoft Entra account (for example `molehill@yourcompany.com`) or a SQL login. It gets the same read-only permissions.

---

## 4. Your data

* All work happens remotely inside your environment. Reports are stored in the Molehill Watch database on your server and saved on your jump box. **Your data is not copied off your infrastructure.**
* We can e-mail the weekly report through your own Database Mail if you'd like. Query text is left out of e-mails by default, because it can contain personal data.

---

## 5. Raising a support ticket

E-mail your agreed ticket channel with:

* the server or instance name
* what's happening, and since when
* the business impact, so we can set the severity

| Severity | For example | Target response |
|---|---|---|
| **Critical** | Production server down or unreachable, backups failing, severe blocking affecting operations | Same business day |
| **Standard** | Configuration questions, minor performance queries, advice, small non-urgent fixes | Within 1 full business day |

**Business hours** are Monday to Friday, 9:00am to 5:30pm, excluding UK bank holidays.

A Critical issue raised outside business hours becomes top priority at the start of the next business day. Guaranteed out-of-hours emergency cover isn't part of this package, but can be arranged separately.

**Planned out-of-hours work** (patching, maintenance windows, releases, and for Azure: service tier changes, migrations and failover tests) can be booked in advance.

If a piece of work looks likely to take **more than 1 hour**, we'll send you an estimate before continuing, so your included hours aren't used up unexpectedly.

---

## 6. If you stop the service

We can remove everything in a couple of minutes: the jobs, the Molehill Watch objects (and the MolehillWatch database if we created it) and our access. An existing DBA database is left exactly as it was.
