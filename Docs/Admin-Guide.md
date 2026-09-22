# Molehill Admin – day-to-day guide

All commands run in SSMS against **MolehillAdmin**. Wherever a procedure takes `@Client`, you can pass the **client name** (`N'Contoso Ltd'`) or the **agreement ref** (`'MWA-0001'`).

Times are UK local time. Leave date/time parameters out to mean "now".

**Prefer not to type SQL?** Every step below can also be done in **Molehill Manager** (`MolehillManager.exe`; the first run asks for the connection and saves it to `MolehillManager.config.json`). It has tabs for Dashboard, Clients, Tickets and Billing. Press Enter on an agreement for its instances, onboarding, contacts, tickets and weekly reports. F2 adds, and Enter on a row offers what you can do with it. It calls the same procedures shown here, and shows any warnings they print.

---

## Every morning (2 minutes)

Open `Documents\Molehill Admin\Dashboard.html`, or run:

```sql
EXEC dbo.usp_Dashboard;
```

The **To do** list covers:

* ticket responses due or overdue
* tickets needing an estimate
* weekly reports outstanding
* draft invoices to send and overdue payments
* onboarding gaps
* initial-term reviews
* agreements ending
* unsupported versions without risk acceptance
* included hours nearly used
* bank holidays running out

---

## Signing up a new client

Work through `Admin\Example-NewClient.sql`. It's the same steps with example values. Change `ROLLBACK` to `COMMIT` for real use.

1. **Client and contacts.** Each contact has two ticks:
   * **Raises tickets** (`@IsNamedContact`): the agreement needs at least one named point of contact.
   * **Receives invoices** (`@IsBillingContact`): this is the only billing setting. Invoices are addressed to every current contact with it ticked, and the dashboard tells you who to send drafts to.

   A shared finance mailbox is simply a contact with only **Receives invoices** ticked.
   ```sql
   EXEC dbo.usp_Client_Add @ClientName = N'Contoso Ltd', @Address = N'...';
   EXEC dbo.usp_Contact_Add @ClientName = N'Contoso Ltd', @FullName = N'Sam Smith', @Email = N'sam@contoso.co.uk', @IsNamedContact = 1;
   EXEC dbo.usp_Contact_Add @ClientName = N'Contoso Ltd', @FullName = N'Accounts', @Email = N'accounts@contoso.co.uk', @IsBillingContact = 1;
   ```
2. **Agreement.** The start date drives billing cycles, the 3-month term and notice dates.
   ```sql
   EXEC dbo.usp_Agreement_Create @ClientName = N'Contoso Ltd', @StartDate = '2026-10-15', @SignedDate = '2026-10-01';
   ```
3. **Covered instances.** Pricing tiers are worked out for you.
   ```sql
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'SQL01', @SqlVersion = '2019';
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'SQL02', @Role = 'AGSecondary', @AvailabilityGroup = N'AG1', @PrimaryInstanceName = N'SQL01', @SqlVersion = '2019';
   ```
   Roles: `Standalone`, `AGPrimary`, `AGSecondary`, `LogShippingSecondary`, `MirrorSecondary`, `FCI`, `GeoReplica` (Azure only).
   * A busy readable secondary quoted as full: add `@PricedAsFullInstance = 1`.
   * Non-production or bespoke pricing: add `@AgreedMonthlyFee = 150` (required for non-production).
   * Instances added before the first invoice are covered from the agreement start. Instances added later are charged from the next cycle start. `@CoveredFrom` overrides both.

   **Azure SQL.** A Managed Instance is priced like any other instance and counts towards the tiers. Azure SQL Database is priced per logical server or elastic pool: the unit covers 5 databases, and each extra database is charged separately. Give the number of databases:
   ```sql
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'contoso-mi', @Platform = 'AzureSqlManagedInstance';
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'contoso-sql', @Platform = 'AzureSqlDatabaseServer', @DatabaseCount = 7;
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'contoso-pool', @Platform = 'AzureSqlDatabaseElasticPool', @DatabaseCount = 12;
   EXEC dbo.usp_Instance_Add @Client = N'Contoso Ltd', @InstanceName = N'contoso-sql-dr', @Platform = 'AzureSqlDatabaseServer', @Role = 'GeoReplica', @PrimaryInstanceName = N'contoso-sql';
   ```
   When databases are added or dropped, update the count. The fee changes from the next invoice.
   ```sql
   EXEC dbo.usp_Instance_Update @Client = N'Contoso Ltd', @InstanceName = N'contoso-sql', @DatabaseCount = 8;
   ```
4. **Send the client** `Docs\Client-Onboarding-Guide.md` (the access checklist).
5. **Install Molehill Watch** on every covered instance, every AG replica and every Managed Instance, using `Client\Install-MolehillWatch.ps1`. A Managed Instance needs an Entra or SQL login for `-MolehillLogin`. Azure SQL Database has nothing to install; its weekly report runs from the jump box. Then record the install:
   ```sql
   EXEC dbo.usp_Instance_Update @Client = N'Contoso Ltd', @InstanceName = N'SQL01', @MonitoringInstalledDate = '2026-10-10';
   ```
6. **Unsupported versions.** Get the client's written acceptance and record it. The procedure prints the matching command for the client server, so it appears in their weekly reports.
   ```sql
   EXEC dbo.usp_Instance_RecordRiskAcceptance @Client = N'Contoso Ltd', @InstanceName = N'LEGACY01', @AcceptedBy = N'Sam Smith (IT Manager)';
   ```
7. **Tick off onboarding** as items arrive:
   ```sql
   EXEC dbo.usp_Onboarding_Show @Client = N'Contoso Ltd';
   EXEC dbo.usp_Onboarding_Complete @Client = N'Contoso Ltd', @ItemCode = 'REMOTE_ACCESS';
   ```
   Item codes: `SIGNED`, `NAMED_CONTACT`, `TICKET_CHANNEL`, `REMOTE_ACCESS`, `SSMS_ACCESS`, `PERMISSIONS`, `MONITORING`, `VERSION_REVIEW`, `FIRST_REPORT`, `CONFIDENTIALITY` (optional).

---

## Contacts

Contacts are never deleted. Removing someone ends their current period as a contact; adding them back starts a new one. Their tickets and history stay linked to the same person.

| Step | Command |
|---|---|
| Add (optionally from a date) | `EXEC dbo.usp_Contact_Add @ClientName = N'Contoso Ltd', @FullName = N'Sam Smith', @Email = N'sam@contoso.co.uk', @IsNamedContact = 1, @StartDate = '2026-10-01';` |
| Correct details (only what you pass changes; `''` clears e-mail or phone) | `EXEC dbo.usp_Contact_Update @Client = N'Contoso Ltd', @FullName = N'Sam Smith', @Email = N'sam.smith@contoso.co.uk';` |
| Remove (soft delete; the end date is their last day, not in the future) | `EXEC dbo.usp_Contact_Remove @Client = N'Contoso Ltd', @FullName = N'Sam Smith', @EndDate = '2026-12-31', @Reason = N'Left the company';` |
| Add back later | `EXEC dbo.usp_Contact_Add ...` with the same name, or `EXEC dbo.usp_Contact_Reinstate @Client = N'Contoso Ltd', @FullName = N'Sam Smith', @StartDate = '2027-03-01';` |
| Contacts and their dates | `EXEC dbo.usp_Contact_Show @Client = N'Contoso Ltd';` (`@IncludeRemoved = 0` for current only) |

* `@Client` takes the client name or agreement ref, or use `@ContactId` from `usp_Contact_Show`.
* E-mail addresses that are obviously malformed are rejected.
* A new start date must be after their last end date.
* Removing the only contact who raises tickets, or the only one who receives invoices, prints a warning. The dashboard flags any agreement without a current contact who raises tickets, or without anyone who receives invoices.
* A ticket logged for a removed contact is still linked to them, with a warning to check the request is authorised. When no contact is given, the default is a current named contact.

In **Molehill Manager**: open the agreement and go to the **Contacts** tab. Removed contacts are hidden unless you tick **Show removed contacts**. Enter on a contact offers Edit, Remove or Add back, plus History.

---

## Tickets

| Step | Command |
|---|---|
| Log a ticket when it arrives | `EXEC dbo.usp_Ticket_Open @Client = N'Contoso Ltd', @Title = N'Backup job failed', @Severity = 'Critical', @InstanceName = N'SQL01';` |
| First response (starts the SLA clock) | `EXEC dbo.usp_Ticket_Respond @TicketRef = 'MW-00012';` |
| Log time | `EXEC dbo.usp_Time_Log @TicketRef = 'MW-00012', @Minutes = 40, @Description = N'Investigated';` |
| Over 1 hour: send an estimate first | `EXEC dbo.usp_Ticket_Estimate @TicketRef = 'MW-00012', @EstimateHours = 3;` |
| Client approves the estimate | `EXEC dbo.usp_Ticket_Estimate @TicketRef = 'MW-00012', @Approved = 1;` |
| Close | `EXEC dbo.usp_Ticket_Close @TicketRef = 'MW-00012', @Resolution = N'...';` |
| Included hours this cycle | `EXEC dbo.usp_Agreement_Usage @Client = N'Contoso Ltd';` |

* **Severity.** `Critical` covers server down, backups failing or severe blocking, and is due by end of the same business day. `Standard` is due by end of the next full business day.
* **Rate type.** It's chosen from `@WorkStart`: Mon–Fri 09:00–17:30 outside bank holidays is `BusinessHours`, anything else is `OutOfHours`. Override with `@RateType`.
* **Planned out-of-hours work** (patching, releases, and for Azure: service tier changes, migrations and failover tests): open the ticket with `@WorkType = 'PlannedOutOfHours'`.
* **Non-billable time** (e.g. your own mistake): `@IsBillable = 0`.
* **Project work** (health checks, upgrades, migrations): open with `@WorkType = 'Project'`, then `EXEC dbo.usp_Quote_Add ...`. Project time is never billed through the support invoices.

---

## Weekly reports (Mondays)

The client's **Molehill Watch - Weekly Report** job builds the report at 06:30 every Monday.

1. On each client's jump box:
   ```powershell
   .\Export-WeeklyReports.ps1 -ServerList .\servers.txt -UpdatePatchReference
   ```
   `-UpdatePatchReference` refreshes Microsoft's latest SQL Server CU and Windows security update data (needs internet). With no internet on the jump box, create the file on your PC with `.\Update-PatchReference.ps1 -OutFile patch-reference.json`, then load it with `-InFile`.
   For **Azure SQL Database**, run the report per logical server, signed in with `az login` or with `-SqlCredential`:
   ```powershell
   .\Get-AzureSqlDatabaseReport.ps1 -Server contoso-sql,contoso-sql-dr -ClientName 'Contoso Ltd' -AzurePlatformChecks
   ```
   Add `-ElasticJobServer`/`-ElasticJobDatabase` if the client uses elastic jobs. Once a month, check the retention (PITR/LTR) and Defender settings it reports against what the client needs.
2. Open `index.html`. Review each report, check the **Patching** table, and check the **AG parity** page where there is one. Out-of-date patching is a natural prompt to offer planned out-of-hours patching work.
3. Send the reports to the client. Raise tickets for anything that needs follow-up work.
4. Log each report. For Azure SQL Database, use the logical server or pool name as the instance.
   ```sql
   EXEC dbo.usp_WeeklyReport_Log @Client = N'Contoso Ltd', @InstanceName = N'SQL01', @OverallStatus = 'Amber', @CriticalCount = 0, @WarningCount = 2, @Notes = N'Recommended CHECKDB schedule';
   ```

On the client server, `EXEC mw.usp_ShowReport;` shows the latest findings as a grid. Run it in the database Molehill Watch was installed into: `MolehillWatch`, or the client's DBA database.

To rebuild a report on demand (needs sysadmin): `EXEC mw.usp_BuildWeeklyReport;`.

If a client's Molehill Watch lives in their own DBA database, add `-Database <name>` to `Export-WeeklyReports.ps1` and `Update-PatchReference.ps1`.

---

## Billing

The daily task runs `usp_Billing_Run`. On each client's cycle start date it creates a **draft invoice** containing:

* that cycle's monthly fees (in advance)
* any chargeable support from earlier cycles (in arrears), with included hours and minimum charges applied

Draft invoices are written to `Documents\Molehill Admin\Invoices\`. Open one in a browser and print it to PDF. A cycle with nothing covered and nothing owed gets no invoice, and the billing run tells you so. That usually means an instance's covered-from date is wrong.

| Step | Command |
|---|---|
| Add a credit or extra line to a draft | `EXEC dbo.usp_Invoice_Adjust @InvoiceNo = 'MDS-2026-0004', @Description = N'Goodwill credit', @Amount = -50;` |
| Re-export one invoice | `.\Invoke-MolehillDaily.ps1 -SqlInstance .\SQLEXPRESS -InvoiceNo MDS-2026-0004 -NoBillingRun` |
| Mark sent (resets invoice date and due date to today + 14) | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Sent';` |
| Mark paid | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Paid';` |
| Void, so the next billing run rebuilds it | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Void';` |
| Pause support for late payment | `EXEC dbo.usp_Agreement_PauseSupport @Client = N'Contoso Ltd';` (lifted automatically once paid) |

### Pre-paid hours (add-on)

A client can buy a block of business-hours support in advance at a reduced rate. You agree the number of hours and their rate. You can also agree an expiry date; by default the hours never expire.

Pre-paid hours only ever cover business-hours work. Out-of-hours work is never taken from them and is always billed at the out-of-hours rate.

| Step | Command |
|---|---|
| Sell a package (a draft invoice for hours × rate is created) | `EXEC dbo.usp_Prepaid_Add @Client = N'Contoso Ltd', @Hours = 20, @HourlyRate = 62.50, @ValidMonths = 12;` |
| Packages, what's left, and where the hours went | `EXEC dbo.usp_Prepaid_Show @Client = N'Contoso Ltd';` |
| Extend or remove the expiry | `EXEC dbo.usp_Prepaid_Update @PackageRef = 'PH-0001', @ExpiresOn = '2027-12-31';` (or `@NoExpiry = 1`) |
| Cancel an unused package (voids its invoice if it hasn't been paid) | `EXEC dbo.usp_Prepaid_Cancel @PackageRef = 'PH-0001', @Reason = N'...';` |

How the hours are used at each arrears billing:

1. The month's included hours are used first. They're free and don't roll over.
2. Chargeable business-hours time, with the 1-hour minimum per ticket applied, comes out of pre-paid hours. The package that expires soonest is used first, and a package is only used for work done between its start and expiry dates.
3. Any business-hours time left over is billed at the business-hours rate.
4. Out-of-hours time is always billed at the out-of-hours rate.

On the invoice:

* Time covered by pre-paid hours appears as £0 lines, and a note shows what's left.
* Voiding an arrears invoice gives its pre-paid hours back.
* A package's own invoice can't be voided once any of its hours have been used; credit the client with an adjustment instead.

The dashboard flags packages that are running low (20% or less left), used up (so you can offer a top-up), or have unused hours expiring within 30 days. In **Molehill Manager**, use the agreement's **Pre-paid hours** tab: F2 sells a package, and Enter on one shows its usage, changes its expiry or cancels it.

**Time logged late.** If you log time for a cycle that has already been invoiced, it goes on a small separate invoice at the next billing run.

---

## Term, notice and prices

| Step | Command |
|---|---|
| Record the 3-month review | `EXEC dbo.usp_Agreement_RecordReview @Client = N'Contoso Ltd', @Notes = N'Happy, continuing monthly';` |
| Check an end date without recording notice | `EXEC dbo.usp_Notice_Give @Client = N'Contoso Ltd', @WhatIf = 1;` |
| Record notice | `EXEC dbo.usp_Notice_Give @Client = N'Contoso Ltd', @GivenBy = 'Client';` |
| Stop covering one instance | `EXEC dbo.usp_Instance_Remove @Client = N'Contoso Ltd', @InstanceName = N'SQL03';` |

When the agreement ends:

1. Remove your access.
2. Offer to run `MolehillWatch_Uninstall.sql` on the client's servers.
3. The final arrears invoice is created automatically.

### Price changes

The rules are no more than once a year, with at least one full calendar month's notice.

1. Add a new row to `dbo.PriceList` (copy the Standard row and change the values).
2. Schedule the change:
   ```sql
   EXEC dbo.usp_PriceChange_Schedule @NewPriceListName = N'Standard 2027', @NotifiedDate = '2027-05-10', @EffectiveDate = '2027-07-01';
   ```
   Leave out `@Client` to apply it to all agreements. The procedure refuses changes that break either rule.

---

## Settings

`SELECT * FROM dbo.Setting;` then `UPDATE dbo.Setting SET Value = ... WHERE Name = ...;`

| Setting | Default | Notes |
|---|---|---|
| `PaymentDetails`, `BusinessAddress` | blank | Printed on invoices |
| `InvoicePrefix` | `MDS` | Invoice numbers look like MDS-2026-0001 |
| `VatRegistered` / `VatRatePct` | `0` / `20` | Tell clients before switching VAT on |
| `MinimumChargeMode` | `Fair` | See README, *Decisions and assumptions* |
| `BusinessHoursStart` / `End` | `09:00` / `17:30` | |
| `ReportGraceDays` | `2` | Days after Sunday before a missing weekly report is flagged |
| `AlertEmailProfile` / `Recipients` | blank | E-mails the dashboard daily; needs Database Mail, not available on Express |

Bank holidays live in `dbo.BankHoliday`. Add each new year from gov.uk/bank-holidays.
