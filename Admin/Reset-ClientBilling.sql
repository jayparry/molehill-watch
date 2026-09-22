/*
===============================================================================
 Molehill Admin - reset billing for one client
 Molehill Data Services  -  jay@jayparry.co.uk
-------------------------------------------------------------------------------
 Puts a client back to "billing has never run": removes their invoices, invoice
 lines and billing cycles, releases their logged time, and gives back any
 pre-paid hours those invoices took.

 KEPT: the client, agreement, instances, contacts, onboarding, tickets, time
 entries, weekly reports, quotes and pre-paid hour packages themselves.

 The next billing run rebuilds the cycles and invoices from that data, so
 invoice numbers are reused and totals come out the same (unless prices,
 instances or time have changed since).

 HOW TO USE
   1. Set @Client below (client name or agreement ref).
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

DECLARE @Client nvarchar(200) = N'Example Widgets Ltd';   -- client name or agreement ref
DECLARE @OnlyThisAgreement bit = 0;   -- 0 = every agreement the client has; 1 = only the agreement ref given above
DECLARE @KeepPackageInvoices bit = 1; -- 1 = keep invoices that sold pre-paid hours (they are sales, not billing runs).
                                      --     Set to 0 only if you also want those gone: a billing run will NOT raise them
                                      --     again, so you would have to cancel the package and sell it again.

BEGIN TRAN;

DECLARE @ClientId int = dbo.fn_ClientId(@Client);
IF @ClientId IS NULL BEGIN RAISERROR(N'Client or agreement "%s" not found.', 16, 1, @Client); ROLLBACK; RETURN; END

DECLARE @Agreements TABLE (AgreementId int PRIMARY KEY);
INSERT @Agreements
SELECT AgreementId FROM dbo.Agreement
WHERE (@OnlyThisAgreement = 1 AND AgreementRef = @Client)
   OR (@OnlyThisAgreement = 0 AND ClientId = @ClientId);

DECLARE @Invoices TABLE (InvoiceId int PRIMARY KEY);
INSERT @Invoices
SELECT i.InvoiceId FROM dbo.Invoice i
WHERE i.AgreementId IN (SELECT AgreementId FROM @Agreements)
  AND (@KeepPackageInvoices = 0 OR NOT EXISTS (SELECT 1 FROM dbo.PrepaidPackage p WHERE p.InvoiceId = i.InvoiceId));

/*--------------------------------------------------------------- what goes */
SELECT Removing = 'Invoices', i.InvoiceNo, i.InvoiceDate, i.Total, i.Status
FROM dbo.Invoice i JOIN @Invoices x ON x.InvoiceId = i.InvoiceId ORDER BY i.InvoiceNo;

SELECT Removing = 'Billing cycles', bc.CycleNumber, bc.StartDate, bc.EndDate, bc.IncludedHoursUsed
FROM dbo.BillingCycle bc WHERE bc.AgreementId IN (SELECT AgreementId FROM @Agreements) ORDER BY bc.AgreementId, bc.CycleNumber;

SELECT Releasing = 'Time entries', Entries = COUNT(*), Hours = CAST(SUM(e.Minutes) / 60.0 AS decimal(9,2))
FROM dbo.TimeEntry e WHERE e.InvoiceId IN (SELECT InvoiceId FROM @Invoices);

SELECT GivingBack = 'Pre-paid hours', p.PackageRef, Hours = SUM(u.HoursUsed)
FROM dbo.PrepaidUsage u JOIN dbo.PrepaidPackage p ON p.PackageId = u.PackageId
WHERE u.InvoiceId IN (SELECT InvoiceId FROM @Invoices) GROUP BY p.PackageRef;

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
SELECT Left_Invoices = COUNT(*) FROM dbo.Invoice WHERE AgreementId IN (SELECT AgreementId FROM @Agreements);
SELECT Left_Cycles = COUNT(*) FROM dbo.BillingCycle WHERE AgreementId IN (SELECT AgreementId FROM @Agreements);
SELECT PrepaidNow = f.PackageRef, f.Hours, f.Used, f.Remaining, f.State
FROM @Agreements a CROSS APPLY dbo.fn_PrepaidPackages(a.AgreementId, CAST(dbo.fn_UkNow() AS date)) f
ORDER BY f.PackageRef;

PRINT N'Billing reset. Run usp_Billing_Run for this client (or F6 in Molehill Manager) to rebuild the cycles and invoices.';

ROLLBACK;   -- change to COMMIT once the lists above look right
PRINT N'ROLLED BACK - nothing was changed. Change ROLLBACK to COMMIT to do it for real.';
