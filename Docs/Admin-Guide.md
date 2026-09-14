# Molehill Admin – day-to-day guide

All commands run in SSMS against **MolehillAdmin**. Wherever a procedure takes `@Client`, you can pass the **client name** (`N'Contoso Ltd'`) or the **agreement ref** (`'MWA-0001'`).

Times are UK local time. Leave date/time parameters out to mean "now".

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

1. **Client and contacts.** Mark one contact as the named point of contact (required by the agreement).
   ```sql
   EXEC dbo.usp_Client_Add @ClientName = N'Contoso Ltd', @Address = N'...', @BillingEmail = N'accounts@contoso.co.uk';
   EXEC dbo.usp_Contact_Add @ClientName = N'Contoso Ltd', @FullName = N'Sam Smith', @Email = N'sam@contoso.co.uk', @IsNamedContact = 1, @IsBillingContact = 1;
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
   Roles: `Standalone`, `AGPrimary`, `AGSecondary`, `LogShippingSecondary`, `MirrorSecondary`, `FCI`.
   * A busy readable secondary quoted as full: add `@PricedAsFullInstance = 1`.
   * Non-production or bespoke pricing: add `@AgreedMonthlyFee = 150`.
4. **Send the client** `Docs\Client-Onboarding-Guide.md` (the access checklist).
5. **Install Molehill Watch** on every covered instance and every AG replica, using `Client\Install-MolehillWatch.ps1`. Then record it:
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
* **Planned out-of-hours work** (patching, releases): open the ticket with `@WorkType = 'PlannedOutOfHours'`.
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
2. Open `index.html`. Review each report, check the **Patching** table, and check the **AG parity** page where there is one. Out-of-date patching is a natural prompt to offer planned out-of-hours patching work.
3. Send the reports to the client. Raise tickets for anything that needs follow-up work.
4. Log each report:
   ```sql
   EXEC dbo.usp_WeeklyReport_Log @Client = N'Contoso Ltd', @InstanceName = N'SQL01', @OverallStatus = 'Amber', @CriticalCount = 0, @WarningCount = 2, @Notes = N'Recommended CHECKDB schedule';
   ```

On the client server, `EXEC MolehillWatch.dbo.usp_ShowReport;` shows the latest findings as a grid.

To rebuild a report on demand (needs sysadmin): `EXEC MolehillWatch.dbo.usp_BuildWeeklyReport;`.

---

## Billing

The daily task runs `usp_Billing_Run`. On each client's cycle start date it creates a **draft invoice** containing:

* that cycle's monthly fees (in advance)
* any chargeable support from earlier cycles (in arrears), with included hours and minimum charges applied

Draft invoices are written to `Documents\Molehill Admin\Invoices\`. Open one in a browser and print it to PDF.

| Step | Command |
|---|---|
| Add a credit or extra line to a draft | `EXEC dbo.usp_Invoice_Adjust @InvoiceNo = 'MDS-2026-0004', @Description = N'Goodwill credit', @Amount = -50;` |
| Re-export one invoice | `.\Invoke-MolehillDaily.ps1 -SqlInstance .\SQLEXPRESS -InvoiceNo MDS-2026-0004 -NoBillingRun` |
| Mark sent (resets invoice date and due date to today + 14) | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Sent';` |
| Mark paid | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Paid';` |
| Void, so the next billing run rebuilds it | `EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = 'MDS-2026-0004', @Status = 'Void';` |
| Pause support for late payment | `EXEC dbo.usp_Agreement_PauseSupport @Client = N'Contoso Ltd';` (lifted automatically once paid) |

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
