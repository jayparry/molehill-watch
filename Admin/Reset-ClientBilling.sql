/*
===============================================================================
 Molehill Admin - reset billing for one client
 Molehill Data Services  -  jay@jayparry.co.uk
-------------------------------------------------------------------------------
 Puts a client back to "billing has never run": removes their invoices, invoice
 lines and billing cycles, releases their logged time, and gives back any
 pre-paid hours those invoices took. Covers every engagement they have -
 Molehill Watch support and consultancy alike.

 KEPT: the client, their engagements and agreements, instances, contacts,
 onboarding, tickets, time entries, weekly reports, quotes and pre-paid
 hour packages themselves.

 The next billing run rebuilds the cycles and invoices from that data, with the
 same dates and totals as before (unless prices, instances, rates or time have
 changed since). Molehill Watch cycles run from the agreement start date and
 consultancy periods from the engagement start date, so both land where they
 did. Invoice numbers restart from the highest one still in the database, so
 they only come out identical if nothing is being kept (see the switches).

 NEEDS Molehill Admin 2.0 or later. On an older database it stops and tells
 you to run MolehillAdmin_Install.sql first (or just start Molehill Manager
 and accept the upgrade it offers) - that keeps all your data.

 HOW TO USE
   1. Set @Client below (client name, agreement ref or engagement ref).
   2. Run it. It prints what it would remove and, because it ends with
      ROLLBACK, changes nothing.
   3. Happy? Change ROLLBACK to COMMIT at the bottom and run it again.

 Take a backup first if this is real billing:
   BACKUP DATABASE MolehillAdmin TO DISK = 'D:\MolehillAdmin.bak' WITH INIT;
===============================================================================
*/
USE MolehillAdmin;
GO
SET NOCOUNT ON;
GO
/*--------------------------------------------------------------------------
  Stop cleanly on a 1.x database rather than failing on a missing table.
--------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.Engagement') IS NULL OR OBJECT_ID(N'dbo.fn_ConsultancyWork') IS NULL
BEGIN
    DECLARE @Version nvarchar(20) = ISNULL((SELECT TOP (1) Version FROM dbo.InstallHistory ORDER BY InstallId DESC), N'unknown');
    RAISERROR(N'STOP: this database is Molehill Admin %s, and this script needs 2.0 or later. Upgrade it first - run Admin\MolehillAdmin_Install.sql, or start Molehill Manager and accept the upgrade it offers; your data is kept. Then run this again. (Nothing below has run: any "Invalid column name" errors after this one are just SQL Server reading the rest of the script.)',
              16, 1, @Version);
    SET NOEXEC ON;
END
GO

DECLARE @Client nvarchar(200) = N'Example Widgets Ltd';   -- client name, agreement ref or engagement ref
DECLARE @OnlyThisAgreement bit = 0;   -- 0 = everything the client has; 1 = only the agreement / engagement ref given above
DECLARE @KeepPackageInvoices bit = 1; -- 1 = keep invoices that sold pre-paid hours (they are sales, not billing runs).
                                      --     Set to 0 only if you also want those gone: a billing run will NOT raise them
                                      --     again, so you would have to cancel the package and sell it again.
DECLARE @KeepTypedInvoices bit = 1;   -- 1 = keep invoices you typed by hand (licences, expenses, one-off charges).
                                      --     The billing run cannot rebuild those either, so 0 deletes them for good.

BEGIN TRAN;

DECLARE @ClientId int = dbo.fn_ClientId(@Client);
IF @ClientId IS NULL BEGIN RAISERROR(N'Client or agreement "%s" not found.', 16, 1, @Client); ROLLBACK; RETURN; END

DECLARE @Engagements TABLE (EngagementId int PRIMARY KEY);
INSERT @Engagements
SELECT EngagementId FROM dbo.Engagement
WHERE (@OnlyThisAgreement = 1 AND EngagementRef = @Client)
   OR (@OnlyThisAgreement = 0 AND ClientId = @ClientId);

DECLARE @Agreements TABLE (AgreementId int PRIMARY KEY);
INSERT @Agreements
SELECT AgreementId FROM dbo.Agreement WHERE EngagementId IN (SELECT EngagementId FROM @Engagements);

DECLARE @Invoices TABLE (InvoiceId int PRIMARY KEY);
INSERT @Invoices
SELECT i.InvoiceId FROM dbo.Invoice i
WHERE (i.EngagementId IN (SELECT EngagementId FROM @Engagements)
       OR (i.EngagementId IS NULL AND i.ClientId = @ClientId AND @OnlyThisAgreement = 0))
  AND (@KeepPackageInvoices = 0 OR NOT EXISTS (SELECT 1 FROM dbo.PrepaidPackage p WHERE p.InvoiceId = i.InvoiceId))
  AND (@KeepTypedInvoices = 0 OR EXISTS (SELECT 1 FROM dbo.InvoiceLine l WHERE l.InvoiceId = i.InvoiceId
                                         AND l.LineType IN ('MonthlyFee', 'BusinessHours', 'OutOfHours', 'PrepaidDrawn', 'Consultancy', 'FixedFee')));

/*--------------------------------------------------------------- what goes */
SELECT Removing = 'Invoices', i.InvoiceNo, For_ = ISNULL(i.EngagementRef, N'(free-text)'), i.InvoiceDate, i.Total, i.Status
FROM dbo.vw_Invoice i JOIN @Invoices x ON x.InvoiceId = i.InvoiceId ORDER BY i.InvoiceNo;

SELECT Removing = 'Billing cycles', bc.CycleNumber, bc.StartDate, bc.EndDate, bc.IncludedHoursUsed
FROM dbo.BillingCycle bc WHERE bc.AgreementId IN (SELECT AgreementId FROM @Agreements) ORDER BY bc.AgreementId, bc.CycleNumber;

SELECT Releasing = 'Time entries', Entries = COUNT(*), Hours = CAST(SUM(e.Minutes) / 60.0 AS decimal(9,2)),
       SupportTime = SUM(CASE WHEN e.TicketId IS NOT NULL THEN 1 ELSE 0 END),
       ConsultancyTime = SUM(CASE WHEN e.TicketId IS NULL THEN 1 ELSE 0 END)
FROM dbo.TimeEntry e WHERE e.InvoiceId IN (SELECT InvoiceId FROM @Invoices);

SELECT GivingBack = 'Pre-paid hours', p.PackageRef, Hours = SUM(u.HoursUsed)
FROM dbo.PrepaidUsage u JOIN dbo.PrepaidPackage p ON p.PackageId = u.PackageId
WHERE u.InvoiceId IN (SELECT InvoiceId FROM @Invoices) GROUP BY p.PackageRef;

SELECT Keeping = 'Invoices the billing run cannot rebuild', i.InvoiceNo, i.InvoiceDate, i.Total, i.Status
FROM dbo.vw_Invoice i
WHERE i.ClientId = @ClientId AND i.InvoiceId NOT IN (SELECT InvoiceId FROM @Invoices)
ORDER BY i.InvoiceNo;

IF EXISTS (SELECT 1 FROM dbo.Invoice i JOIN @Invoices x ON x.InvoiceId = i.InvoiceId WHERE i.Status IN ('Sent', 'Paid'))
    PRINT N'WARNING: some of these invoices have been sent or paid. Removing them leaves the client''s records and yours out of step - only do this if they were never really issued.';

/*------------------------------------------------------------------ do it */
-- time goes back to "not yet invoiced"
UPDATE dbo.TimeEntry SET InvoiceId = NULL WHERE InvoiceId IN (SELECT InvoiceId FROM @Invoices);

-- pre-paid hours taken by those invoices are given back
DELETE dbo.PrepaidUsage WHERE InvoiceId IN (SELECT InvoiceId FROM @Invoices);

-- packages sold on an invoice that is going: keep the package, drop the link
UPDATE dbo.PrepaidPackage SET InvoiceId = NULL WHERE InvoiceId IN (SELECT InvoiceId FROM @Invoices);

-- cycles let go of their invoices, then go themselves (the next billing run rebuilds them)
UPDATE dbo.BillingCycle SET FeeInvoiceId = NULL WHERE AgreementId IN (SELECT AgreementId FROM @Agreements);

DELETE dbo.InvoiceLine WHERE InvoiceId IN (SELECT InvoiceId FROM @Invoices);
DELETE dbo.Invoice WHERE InvoiceId IN (SELECT InvoiceId FROM @Invoices);
DELETE dbo.BillingCycle WHERE AgreementId IN (SELECT AgreementId FROM @Agreements);

/*--------------------------------------------------------------- what's left */
SELECT Left_Invoices = COUNT(*) FROM dbo.Invoice WHERE ClientId = @ClientId;
SELECT Left_Cycles = COUNT(*) FROM dbo.BillingCycle WHERE AgreementId IN (SELECT AgreementId FROM @Agreements);
SELECT PrepaidNow = f.PackageRef, f.Hours, f.Used, f.Remaining, f.State
FROM @Agreements a CROSS APPLY dbo.fn_PrepaidPackages(a.AgreementId, CAST(dbo.fn_UkNow() AS date)) f
ORDER BY f.PackageRef;

SELECT ConsultancyNow = e.EngagementRef, e.Name, UnbilledDays = ISNULL(u.Days, 0), UnbilledValue = ISNULL(u.Value, 0)
FROM dbo.Engagement e JOIN @Engagements x ON x.EngagementId = e.EngagementId
OUTER APPLY (SELECT Days = SUM(w.Days), Value = SUM(w.Quantity * w.UnitPrice) FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) w) u
WHERE e.EngagementType = 'Consultancy';

PRINT N'Billing reset. Run usp_Billing_Run for this client (or F6 in Molehill Manager) to rebuild the cycles and invoices.';

ROLLBACK;   -- change to COMMIT once the lists above look right

-- table variables survive a rollback, so the invoices being back means nothing was changed
IF EXISTS (SELECT 1 FROM dbo.Invoice i JOIN @Invoices x ON x.InvoiceId = i.InvoiceId)
    PRINT N'ROLLED BACK - nothing was changed. Change ROLLBACK to COMMIT above to do it for real.';
ELSE
    PRINT N'DONE - those invoices and billing cycles are gone for good.';
GO
SET NOEXEC OFF;
