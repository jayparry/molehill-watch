/*
===============================================================================
 Molehill Admin - worked example / template for signing up a new client
-------------------------------------------------------------------------------
 Run in SSMS against your MolehillAdmin database.
 SAFE TO RUN AS-IS: everything happens inside a transaction that is ROLLED BACK
 at the end, so you can see the results without keeping the example data.

 To use as a template for a real client: replace the values, and change the
 ROLLBACK at the bottom to COMMIT.
===============================================================================
*/
USE MolehillAdmin;
SET NOCOUNT ON;
BEGIN TRAN;

/* 1. Client and contacts ---------------------------------------------------*/
EXEC dbo.usp_Client_Add
     @ClientName   = N'Example Widgets Ltd',
     @Address      = N'Unit 4, Example Park
Exampletown
EX1 2MP',
     @BillingEmail = N'accounts@example-widgets.co.uk';

EXEC dbo.usp_Contact_Add @ClientName = N'Example Widgets Ltd', @FullName = N'Sam Example', @Email = N'sam@example-widgets.co.uk',
     @Phone = N'01234 567890', @IsNamedContact = 1;          -- named point of contact for tickets
EXEC dbo.usp_Contact_Add @ClientName = N'Example Widgets Ltd', @FullName = N'Alex Accounts', @Email = N'accounts@example-widgets.co.uk',
     @IsBillingContact = 1;

/* 2. Agreement (billing cycles run from the start date) ---------------------*/
EXEC dbo.usp_Agreement_Create
     @ClientName    = N'Example Widgets Ltd',
     @StartDate     = '2026-10-01',
     @SignedDate    = '2026-09-20',
     @TicketChannel = N'E-mail to jay@jayparry.co.uk (subject starting "Molehill ticket")';

DECLARE @Client nvarchar(200) = N'Example Widgets Ltd';   -- client name or agreement ref (e.g. MWA-0001) both work

/* 3. Covered instances -------------------------------------------------------
   Role: Standalone | AGPrimary | AGSecondary | LogShippingSecondary | MirrorSecondary | FCI
   Pricing is automatic: 1st/2nd production = 450, 3rd+ = 375, secondaries = 225,
   FCI = one instance whatever the node count, non-production needs @AgreedMonthlyFee. */
EXEC dbo.usp_Instance_Add @Client = @Client, @InstanceName = N'EXSQL01',       @Role = 'AGPrimary',   @AvailabilityGroup = N'AG-ERP',
     @SqlVersion = '2022', @Edition = N'Standard', @OsVersion = N'Windows Server 2022';
EXEC dbo.usp_Instance_Add @Client = @Client, @InstanceName = N'EXSQL02',       @Role = 'AGSecondary', @AvailabilityGroup = N'AG-ERP',
     @PrimaryInstanceName = N'EXSQL01', @SqlVersion = '2022', @Edition = N'Standard', @OsVersion = N'Windows Server 2022';
EXEC dbo.usp_Instance_Add @Client = @Client, @InstanceName = N'EXSQLFCI\FIN',  @Role = 'FCI', @FciNodes = N'EXNODE1, EXNODE2',
     @SqlVersion = '2019', @Edition = N'Enterprise';
EXEC dbo.usp_Instance_Add @Client = @Client, @InstanceName = N'EXLEGACY',      @SqlVersion = '2014', @Edition = N'Standard',
     @OsVersion = N'Windows Server 2012 R2';                  -- unsupported: prints a warning

/* 4. Onboarding ----------------------------------------------------------------*/
EXEC dbo.usp_Instance_RecordRiskAcceptance @Client = @Client, @InstanceName = N'EXLEGACY', @AcceptedBy = N'Sam Example (IT Manager)';
EXEC dbo.usp_Onboarding_Complete @Client = @Client, @ItemCode = 'TICKET_CHANNEL';
EXEC dbo.usp_Onboarding_Complete @Client = @Client, @ItemCode = 'REMOTE_ACCESS', @Notes = N'VPN account issued';
-- after running Install-MolehillWatch.ps1 on each server:
EXEC dbo.usp_Instance_Update @Client = @Client, @InstanceName = N'EXSQL01', @MonitoringInstalledDate = '2026-09-28';
EXEC dbo.usp_Onboarding_Show @Client = @Client;

/* 5. A support ticket -----------------------------------------------------------*/
EXEC dbo.usp_Ticket_Open @Client = @Client, @Title = N'Nightly backup job failed', @Severity = 'Critical',
     @InstanceName = N'EXSQL01', @ContactName = N'Sam Example', @RaisedAt = '2026-10-05 10:15';

DECLARE @Ticket varchar(20) = (SELECT MAX(TicketRef) FROM dbo.Ticket);
EXEC dbo.usp_Ticket_Respond @TicketRef = @Ticket, @RespondedAt = '2026-10-05 10:40';
EXEC dbo.usp_Time_Log @TicketRef = @Ticket, @Minutes = 45, @Description = N'Backup share full; cleared old files, re-ran backup', @WorkStart = '2026-10-05 10:40';
EXEC dbo.usp_Ticket_Close @TicketRef = @Ticket, @Resolution = N'Backup share full. Old files removed and retention job fixed.';

/* 6. Weekly report delivered ----------------------------------------------------*/
EXEC dbo.usp_WeeklyReport_Log @Client = @Client, @InstanceName = N'EXSQL01', @OverallStatus = 'Amber', @CriticalCount = 0, @WarningCount = 2,
     @WeekEnding = '2026-10-04', @Notes = N'Autogrowth settings and CHECKDB schedule recommended.';

/* 7. Billing ---------------------------------------------------------------------
   Normally the scheduled daily task does this. Draft invoices appear on the dashboard. */
EXEC dbo.usp_Billing_Run @AsOfDate = '2026-11-01', @Client = @Client;
EXEC dbo.usp_Agreement_Usage @Client = @Client, @AsOfDate = '2026-11-05';

/* 8. What notice would mean today -----------------------------------------------*/
EXEC dbo.usp_Notice_Give @Client = @Client, @NoticeDate = '2026-12-10', @WhatIf = 1;

/* 9. Dashboard -------------------------------------------------------------------*/
EXEC dbo.usp_Dashboard;

ROLLBACK;   -- change to COMMIT to keep the data
PRINT N'Example rolled back - nothing was saved.';
