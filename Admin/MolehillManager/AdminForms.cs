using System.Data;

namespace MolehillManager;

/// <summary>
/// Every form in the app, and the stored procedure each one calls. The field names match the procedure
/// parameters, and --selftest-write fills in and submits these same forms against a test database.
/// </summary>
public static class AdminForms
{
    public static readonly string[] Platforms = { "SqlServer", "AzureSqlManagedInstance", "AzureSqlDatabaseServer", "AzureSqlDatabaseElasticPool" };
    public static readonly string[] Roles = { "Standalone", "AGPrimary", "AGSecondary", "LogShippingSecondary", "MirrorSecondary", "FCI", "GeoReplica" };
    public static readonly string[] Environments = { "Production", "NonProduction" };
    public static readonly string[] Severities = { "Standard", "Critical" };
    public static readonly string[] WorkTypes = { "Support", "PlannedOutOfHours", "Project" };
    private const string Auto = "(automatic)";

    // ticket rate choices shown in forms, and the value the database stores
    public static readonly (string Label, string? Value)[] TicketRates =
    {
        ("Standard for the work type", null),              // business hours; out of hours for planned out-of-hours work
        ("Business hours", "BusinessHours"),
        ("Out of hours", "OutOfHours"),
        ("By time of work", "ByTimeOfWork")
    };
    private static string? RateValue(string label) => TicketRates.FirstOrDefault(r => r.Label == label).Value;
    public static string RateLabel(string? value) => value switch
    {
        "BusinessHours" => "Business hours", "OutOfHours" => "Out of hours", "ByTimeOfWork" => "By time of work", _ => value ?? ""
    };
    private const string AllClients = "(all clients)";
    private const string NoEngagement = "(nothing in particular)";
    private const string LatestStandard = "(latest standard price list)";

    private static ProcResult Merge(params ProcResult?[] results)
    {
        var all = new ProcResult();
        foreach (var r in results.Where(r => r != null))
        {
            all.Messages.AddRange(r!.Messages);
            all.Tables.AddRange(r.Tables);
        }
        return all;
    }

    // ------------------------------------------------------------------ your business

    private static readonly (string Name, string Label, bool Memo, string Help)[] BusinessSettings =
    {
        ("BusinessName", "Business name", false, ""),
        ("BusinessEmail", "E-mail", false, ""),
        ("BusinessWebsite", "Website", false, ""),
        ("BusinessAddress", "Postal address", true, ""),
        ("PaymentDetails", "Payment details", true, ""),
        ("InvoicePrefix", "Invoice prefix", false, "MDS -> MDS-2026-0001"),
        ("PaymentTermsDays", "Payment terms (days)", false, "")
    };

    /// <summary>The details printed on invoices and the dashboard (dbo.Setting).</summary>
    public static FormSpec BusinessDetails(AdminDb db)
    {
        var current = db.Query("SELECT Name, Value FROM dbo.Setting;").Rows.Cast<DataRow>()
                        .ToDictionary(r => (string)r["Name"], r => r["Value"] as string ?? "");
        string Cur(string n) => current.TryGetValue(n, out var v) ? v : "";
        return new FormSpec
        {
            Title = "Business and invoice details",
            Intro = "Printed on every invoice and on the dashboard. Change them any time from File > Business and invoice details.",
            Fields = BusinessSettings.Select(b => b.Name == "PaymentTermsDays"
                        ? Field.Int(b.Name, b.Label, required: true, def: Cur(b.Name))
                        : b.Memo ? Field.Memo(b.Name, b.Label, def: Cur(b.Name))
                        : Field.Text(b.Name, b.Label, required: b.Name is "BusinessName" or "InvoicePrefix", def: Cur(b.Name), help: b.Help)).ToList(),
            Submit = v =>
            {
                foreach (var b in BusinessSettings)
                    db.Execute("UPDATE dbo.Setting SET Value = @v WHERE Name = @n;", ("@v", v[b.Name].Trim()), ("@n", b.Name));
                var r = new ProcResult();
                r.Messages.Add("Saved. New invoices use these details.");
                return r;
            }
        };
    }

    // ------------------------------------------------------------------ clients and agreements

    public static FormSpec NewClient(AdminDb db)
    {
        var priceLists = new[] { LatestStandard }.Concat(Queries.PriceLists(db)).ToArray();
        return new FormSpec
        {
            Title = "New client",
            Intro = "Creates the client, a first contact and the agreement (with its onboarding checklist). Add more contacts, and the " +
                    "instances, from the agreement afterwards - a shared accounts address can be a contact that only receives invoices.",
            Fields =
            {
                Field.Text("ClientName", "Client name", required: true),
                Field.Text("Address", "Address"),
                Field.Text("ContactName", "First contact", help: "leave blank to add later"),
                Field.Text("ContactEmail", "Contact e-mail"),
                Field.Text("ContactPhone", "Contact phone"),
                Field.Bool("ContactRaisesTickets", "Raises tickets", def: true, help: "named point of contact"),
                Field.Bool("ContactReceivesInvoices", "Receives invoices", def: true),
                Field.Date("StartDate", "Agreement start", required: true, def: DateTime.Today.ToString("yyyy-MM-dd"), help: "billing cycles run from here"),
                Field.Date("SignedDate", "Signed on"),
                Field.Text("TicketChannel", "Ticket channel", help: "blank = the standard e-mail address"),
                Field.Text("AgreementRef", "Agreement ref", help: "blank = next MWA-0000 number"),
                Field.Choice("PriceListName", "Price list", priceLists),
                Field.Memo("Notes", "Client notes")
            },
            Submit = v =>
            {
                var name = v.Str("ClientName")!;
                if (db.Scalar("SELECT 1 FROM dbo.Client WHERE ClientName = @n", ("@n", name)) != null)
                    throw new FormatException($"'{name}' already exists. To start another agreement for them, use 'New agreement for an existing client'.");

                var client = db.Proc("dbo.usp_Client_Add", ("@ClientName", name), ("@Address", v.Str("Address")), ("@Notes", v.Str("Notes")));
                ProcResult? contact = null;
                if (v.Str("ContactName") != null)
                    contact = db.Proc("dbo.usp_Contact_Add", ("@ClientName", name), ("@FullName", v.Str("ContactName")),
                        ("@Email", v.Str("ContactEmail")), ("@Phone", v.Str("ContactPhone")),
                        ("@IsNamedContact", v.Bool("ContactRaisesTickets")), ("@IsBillingContact", v.Bool("ContactReceivesInvoices")));
                ProcResult agreement;
                try
                {
                    agreement = CreateAgreement(db, name, v);
                }
                catch (Exception ex)
                {
                    throw new InvalidOperationException(
                        $"The client was created, but the agreement was not:\n{AdminDb.Describe(ex)}\n\nFix it and use 'New agreement for an existing client'.");
                }
                return Merge(client, contact, agreement);
            }
        };
    }

    private static ProcResult CreateAgreement(AdminDb db, string clientName, FormValues v)
    {
        var priceList = v.Str("PriceListName");
        return db.Proc("dbo.usp_Agreement_Create", ("@ClientName", clientName), ("@StartDate", v.Date("StartDate")),
            ("@SignedDate", v.Date("SignedDate")), ("@TicketChannel", v.Str("TicketChannel")), ("@AgreementRef", v.Str("AgreementRef")),
            ("@PriceListName", priceList == LatestStandard ? null : priceList));
    }

    public static FormSpec NewAgreement(AdminDb db)
    {
        var clients = Queries.ClientNames(db);
        if (clients.Count == 0) clients.Add("");
        var priceLists = new[] { LatestStandard }.Concat(Queries.PriceLists(db)).ToArray();
        return new FormSpec
        {
            Title = "New agreement for an existing client",
            Fields =
            {
                Field.Choice("ClientName", "Client", clients.ToArray()),
                Field.Date("StartDate", "Agreement start", required: true, def: DateTime.Today.ToString("yyyy-MM-dd")),
                Field.Date("SignedDate", "Signed on"),
                Field.Text("TicketChannel", "Ticket channel", help: "blank = the standard e-mail address"),
                Field.Text("AgreementRef", "Agreement ref", help: "blank = next number"),
                Field.Choice("PriceListName", "Price list", priceLists)
            },
            Submit = v => CreateAgreement(db, v.Str("ClientName") ?? throw new FormatException("Add a client first."), v)
        };
    }

    public static FormSpec AddContact(AdminDb db, string clientName) => new()
    {
        Title = $"Add contact - {clientName}",
        Intro = "Someone who was removed earlier is added back as the same contact, with a new start date (their history is kept).",
        Fields =
        {
            Field.Text("FullName", "Name", required: true),
            Field.Text("Email", "E-mail"),
            Field.Text("Phone", "Phone"),
            Field.Bool("IsNamedContact", "Raises tickets", help: "named point of contact"),
            Field.Bool("IsBillingContact", "Receives invoices", help: "e.g. a shared accounts@ address"),
            Field.Date("StartDate", "Contact from", help: "blank = today")
        },
        Submit = v => db.Proc("dbo.usp_Contact_Add", ("@ClientName", clientName), ("@FullName", v.Str("FullName")),
            ("@Email", v.Str("Email")), ("@Phone", v.Str("Phone")),
            ("@IsNamedContact", v.Bool("IsNamedContact")), ("@IsBillingContact", v.Bool("IsBillingContact")),
            ("@StartDate", v.Date("StartDate")))
    };

    /// <summary>A value from the database as a form field shows it: dates as yyyy-mm-dd, money without trailing zeros.</summary>
    private static string Cur(DataRow? row, string col) => row == null || row[col] is DBNull ? ""
        : row[col] is DateTime dt ? (dt.TimeOfDay == TimeSpan.Zero ? dt.ToString("yyyy-MM-dd") : dt.ToString("yyyy-MM-dd HH:mm"))
        : row[col] is decimal m ? m.ToString("0.##")
        : row[col].ToString() ?? "";

    // ------------------------------------------------------------------ pre-paid hours

    /// <summary>Sell a package of support hours in advance at a negotiated rate.</summary>
    public static FormSpec SellPrepaid(AdminDb db, string agreementRef)
    {
        var standard = db.Scalar("""
            SELECT p.BusinessHoursRate FROM dbo.Agreement a
            JOIN dbo.PriceList p ON p.PriceListId = dbo.fn_PriceListIdOn(a.AgreementId, CAST(dbo.fn_UkNow() AS date))
            WHERE a.AgreementRef = @Ref;
            """, ("@Ref", agreementRef));
        var rateHelp = standard is decimal d ? $"negotiated; standard is £{d:0.00}/h" : "negotiated";
        return new FormSpec
        {
            Title = $"Sell pre-paid hours - {agreementRef}",
            Intro = "Business-hours support bought in advance at a reduced rate. Each month's included hours are used first; after that, " +
                    "chargeable business-hours time comes out of these hours (soonest-expiring package first). Out-of-hours work is never " +
                    "taken from them: it is always billed at the out-of-hours rate.",
            Fields =
            {
                Field.Decimal("Hours", "Hours", required: true),
                Field.Decimal("HourlyRate", "Rate per hour (£)", required: true, help: rateHelp),
                Field.Int("ValidMonths", "Use within (months)", help: "blank = no expiry"),
                Field.Date("ExpiresOn", "Or use by", help: "instead of months"),
                Field.Date("PurchasedOn", "Bought on", help: "blank = today; also the invoice date"),
                Field.Date("StartsOn", "Usable from", help: "blank = the day bought"),
                Field.Bool("Invoice", "Invoice it now", def: true, help: "a draft invoice for hours x rate"),
                Field.Text("Notes", "Notes")
            },
            Submit = v => db.Proc("dbo.usp_Prepaid_Add", ("@Client", agreementRef), ("@Hours", v.Dec("Hours")), ("@HourlyRate", v.Dec("HourlyRate")),
                ("@PurchasedOn", v.Date("PurchasedOn")), ("@StartsOn", v.Date("StartsOn")), ("@ExpiresOn", v.Date("ExpiresOn")),
                ("@ValidMonths", v.Int("ValidMonths")), ("@Notes", v.Str("Notes")),
                ("@Invoice", v.Bool("Invoice")))
        };
    }

    /// <summary>What can be changed after purchase: the expiry and notes.</summary>
    public static FormSpec UpdatePrepaid(AdminDb db, string packageRef)
    {
        var row = Queries.PrepaidPackage(db, packageRef);
        string Cur(string col) => row == null || row[col] is DBNull ? "" : row[col] is DateTime dt ? dt.ToString("yyyy-MM-dd") : row[col] is decimal m ? m.ToString("0.##") : row[col].ToString() ?? "";
        return new FormSpec
        {
            Title = $"Change expiry - {packageRef}",
            Intro = "Applies to support billed from now on; hours already taken are not changed. The hours and rate can't be changed once sold: " +
                    "cancel an unused package and sell a new one instead.",
            Fields =
            {
                Field.Date("ExpiresOn", "Use by", def: Cur("ExpiresOn")),
                Field.Bool("NoExpiry", "No expiry"),
                Field.Text("Notes", "Notes", def: Cur("Notes"))
            },
            Submit = v => db.Proc("dbo.usp_Prepaid_Update", ("@PackageRef", packageRef), ("@ExpiresOn", v.Date("ExpiresOn")), ("@NoExpiry", v.Bool("NoExpiry")),
                ("@Notes", v.Str("Notes")))
        };
    }

    public static FormSpec CancelPrepaid(AdminDb db, string packageRef) => new()
    {
        Title = $"Cancel pre-paid hours - {packageRef}",
        Intro = "Only a package none of whose hours have been used can be cancelled. Its invoice is voided if it hasn't been paid.",
        Fields = { Field.Text("Reason", "Reason") },
        Submit = v => db.Proc("dbo.usp_Prepaid_Cancel", ("@PackageRef", packageRef), ("@Reason", v.Str("Reason")))
    };

    /// <summary>Correct a contact's details. Clearing the e-mail or phone removes it.</summary>
    public static FormSpec EditContact(AdminDb db, int contactId)
    {
        var row = Queries.Contact(db, contactId);
        return new FormSpec
        {
            Title = $"Edit contact - {Cur(row, "FullName")}",
            Fields =
            {
                Field.Text("FullName", "Name", required: true, def: Cur(row, "FullName")),
                Field.Text("Email", "E-mail", def: Cur(row, "Email"), help: "blank = none"),
                Field.Text("Phone", "Phone", def: Cur(row, "Phone"), help: "blank = none"),
                Field.Bool("IsNamedContact", "Raises tickets", def: row?["IsNamedContact"] is true, help: "named point of contact"),
                Field.Bool("IsBillingContact", "Receives invoices", def: row?["IsBillingContact"] is true)
            },
            // every field is sent: an emptied e-mail or phone is cleared ('' clears, NULL would leave it)
            Submit = v => db.Proc("dbo.usp_Contact_Update", ("@ContactId", contactId), ("@NewFullName", v["FullName"].Trim()),
                ("@Email", v["Email"].Trim()), ("@Phone", v["Phone"].Trim()),
                ("@IsNamedContact", v.Bool("IsNamedContact")), ("@IsBillingContact", v.Bool("IsBillingContact")))
        };
    }

    /// <summary>Soft delete: the contact's current period ends; their record, history and tickets are kept.</summary>
    public static FormSpec RemoveContact(AdminDb db, int contactId) => new()
    {
        Title = $"Remove contact - {Cur(Queries.Contact(db, contactId), "FullName")}",
        Intro = "They stop being a contact from the day after the date given. Nothing is deleted: their details, dates and tickets are kept, and they can be added back later.",
        Fields =
        {
            Field.Date("EndDate", "Last day as contact", help: "blank = today; not in the future"),
            Field.Text("Reason", "Reason", help: "optional, e.g. left the company")
        },
        Submit = v => db.Proc("dbo.usp_Contact_Remove", ("@ContactId", contactId), ("@EndDate", v.Date("EndDate")), ("@Reason", v.Str("Reason")))
    };

    /// <summary>Brings a removed contact back with a new period; details can be updated at the same time.</summary>
    public static FormSpec ReaddContact(AdminDb db, int contactId)
    {
        var row = Queries.Contact(db, contactId);
        return new FormSpec
        {
            Title = $"Add back - {Cur(row, "FullName")}",
            Intro = "Starts a new period as a contact. The earlier period(s) stay in their history.",
            Fields =
            {
                Field.Date("StartDate", "Contact again from", help: "blank = today"),
                Field.Text("Email", "E-mail", def: Cur(row, "Email")),
                Field.Text("Phone", "Phone", def: Cur(row, "Phone")),
                Field.Bool("IsNamedContact", "Raises tickets", def: row?["IsNamedContact"] is true),
                Field.Bool("IsBillingContact", "Receives invoices", def: row?["IsBillingContact"] is true)
            },
            Submit = v => db.Proc("dbo.usp_Contact_Reinstate", ("@ContactId", contactId), ("@StartDate", v.Date("StartDate")),
                ("@Email", v["Email"].Trim()), ("@Phone", v["Phone"].Trim()),
                ("@IsNamedContact", v.Bool("IsNamedContact")), ("@IsBillingContact", v.Bool("IsBillingContact")))
        };
    }

    // ------------------------------------------------------------------ instances

    public static FormSpec AddInstance(AdminDb db, string agreementRef) => new()
    {
        Title = $"Add instance - {agreementRef}",
        Intro = "SQL Server and Managed Instances are priced per instance (multi-server rate from the 3rd). " +
                "An Azure SQL Database logical server or elastic pool is one unit covering 5 databases, plus a fee per extra database: " +
                "give its database count. Geo-replicas and secondaries need the primary's name.",
        Fields =
        {
            Field.Text("InstanceName", "Name", required: true, help: "SQL01\\INST, mi-name, sql-server-name"),
            Field.Choice("Platform", "Platform", Platforms),
            Field.Choice("Role", "Role", Roles),
            Field.Int("DatabaseCount", "Databases", help: "Azure SQL Database only"),
            Field.Choice("Environment", "Environment", Environments),
            Field.Text("PrimaryInstanceName", "Primary", help: "secondaries and geo-replicas"),
            Field.Text("AvailabilityGroup", "Availability group"),
            Field.Text("FciNodes", "FCI nodes"),
            Field.Text("SqlVersion", "SQL version", help: "e.g. 2019; blank for Azure SQL Database"),
            Field.Text("Edition", "Edition", help: "or Azure service tier"),
            Field.Text("OsVersion", "OS version"),
            Field.Bool("PricedAsFullInstance", "Priced as full", help: "busy readable secondary"),
            Field.Decimal("AgreedMonthlyFee", "Agreed monthly fee", help: "required for non-production"),
            Field.Date("CoveredFrom", "Covered from", help: "blank = start date while onboarding, else today")
        },
        Submit = v => db.Proc("dbo.usp_Instance_Add", ("@Client", agreementRef), ("@InstanceName", v.Str("InstanceName")),
            ("@Role", v.Str("Role")), ("@Platform", v.Str("Platform")), ("@DatabaseCount", v.Int("DatabaseCount")),
            ("@Environment", v.Str("Environment")), ("@SqlVersion", v.Str("SqlVersion")), ("@Edition", v.Str("Edition")),
            ("@OsVersion", v.Str("OsVersion")), ("@AvailabilityGroup", v.Str("AvailabilityGroup")),
            ("@PrimaryInstanceName", v.Str("PrimaryInstanceName")), ("@FciNodes", v.Str("FciNodes")),
            ("@PricedAsFullInstance", v.Bool("PricedAsFullInstance")), ("@AgreedMonthlyFee", v.Dec("AgreedMonthlyFee")),
            ("@CoveredFrom", v.Date("CoveredFrom")))
    };

    public static FormSpec UpdateInstance(AdminDb db, string agreementRef, string instanceName)
    {
        var row = Queries.Instance(db, agreementRef, instanceName);
        string Cur(string col) => row == null || row[col] is DBNull ? "" : row[col] is DateTime d ? d.ToString("yyyy-MM-dd") : row[col].ToString() ?? "";
        return new FormSpec
        {
            Title = $"Update {instanceName}",
            Intro = "Blank fields are left as they are. Changing the database count of an Azure SQL Database server or pool changes its fee from the next invoice.",
            Fields =
            {
                Field.Text("SqlVersion", "SQL version", def: Cur("SqlVersion")),
                Field.Text("Edition", "Edition / tier", def: Cur("Edition")),
                Field.Text("OsVersion", "OS version", def: Cur("OsVersion")),
                Field.Int("DatabaseCount", "Databases", def: Cur("DatabaseCount"), help: "Azure SQL Database only"),
                Field.Date("MonitoringInstalledDate", "Monitoring installed", def: Cur("MonitoringInstalledDate")),
                Field.Memo("Notes", "Notes", def: Cur("Notes"))
            },
            Submit = v => db.Proc("dbo.usp_Instance_Update", ("@Client", agreementRef), ("@InstanceName", instanceName),
                ("@SqlVersion", v.Str("SqlVersion")), ("@Edition", v.Str("Edition")), ("@OsVersion", v.Str("OsVersion")),
                ("@MonitoringInstalledDate", v.Date("MonitoringInstalledDate")), ("@Notes", v.Str("Notes")),
                ("@DatabaseCount", v.Int("DatabaseCount")))
        };
    }

    public static FormSpec RemoveInstance(AdminDb db, string agreementRef, string instanceName) => new()
    {
        Title = $"Remove {instanceName}",
        Intro = "Stops cover (and the monthly fee) from the date given. The history is kept.",
        Fields = { Field.Date("CoveredTo", "Last covered day", help: "blank = today") },
        Submit = v => db.Proc("dbo.usp_Instance_Remove", ("@Client", agreementRef), ("@InstanceName", instanceName), ("@CoveredTo", v.Date("CoveredTo")))
    };

    public static FormSpec RiskAcceptance(AdminDb db, string agreementRef, string instanceName) => new()
    {
        Title = $"Unsupported version risk accepted - {instanceName}",
        Intro = "Record that the client accepted, in writing, the risk of running a version Microsoft no longer supports.",
        Fields =
        {
            Field.Text("AcceptedBy", "Accepted by", required: true),
            Field.Date("AcceptedDate", "Accepted on", help: "blank = today"),
            Field.Bool("HasExtendedSecurityUpdates", "Has ESUs")
        },
        Submit = v => db.Proc("dbo.usp_Instance_RecordRiskAcceptance", ("@Client", agreementRef), ("@InstanceName", instanceName),
            ("@AcceptedBy", v.Str("AcceptedBy")), ("@AcceptedDate", v.Date("AcceptedDate")),
            ("@HasExtendedSecurityUpdates", v.Bool("HasExtendedSecurityUpdates")))
    };

    public static FormSpec WeeklyReport(AdminDb db, string agreementRef, string instanceName) => new()
    {
        Title = $"Weekly report sent - {instanceName}",
        Fields =
        {
            Field.Choice("OverallStatus", "Overall status", new[] { "Green", "Amber", "Red" }),
            Field.Int("CriticalCount", "Critical findings"),
            Field.Int("WarningCount", "Warnings"),
            Field.Date("WeekEnding", "Week ending", help: "blank = last Sunday"),
            Field.Text("FollowUpTicketRef", "Follow-up ticket", help: "MW-00001"),
            Field.Memo("Notes", "Notes")
        },
        Submit = v => db.Proc("dbo.usp_WeeklyReport_Log", ("@Client", agreementRef), ("@InstanceName", instanceName),
            ("@OverallStatus", v.Str("OverallStatus")), ("@CriticalCount", v.Int("CriticalCount")), ("@WarningCount", v.Int("WarningCount")),
            ("@WeekEnding", v.Date("WeekEnding")), ("@Notes", v.Str("Notes")), ("@FollowUpTicketRef", v.Str("FollowUpTicketRef")))
    };

    // ------------------------------------------------------------------ agreement lifecycle

    public static FormSpec CompleteOnboarding(AdminDb db, string agreementRef, string itemCode, string description) => new()
    {
        Title = $"Onboarding done - {itemCode}",
        Intro = description,
        Fields = { Field.Date("CompletedDate", "Completed on", help: "blank = today"), Field.Text("Notes", "Notes") },
        Submit = v => db.Proc("dbo.usp_Onboarding_Complete", ("@Client", agreementRef), ("@ItemCode", itemCode),
            ("@CompletedDate", v.Date("CompletedDate")), ("@Notes", v.Str("Notes")))
    };

    public static FormSpec RecordReview(AdminDb db, string agreementRef) => new()
    {
        Title = $"Initial review delivered - {agreementRef}",
        Fields = { Field.Date("ReviewDate", "Delivered on", help: "blank = today"), Field.Memo("Notes", "Notes") },
        Submit = v => db.Proc("dbo.usp_Agreement_RecordReview", ("@Client", agreementRef), ("@ReviewDate", v.Date("ReviewDate")), ("@Notes", v.Str("Notes")))
    };

    public static FormSpec GiveNotice(AdminDb db, string agreementRef) => new()
    {
        Title = $"Notice - {agreementRef}",
        Intro = "One calendar month's notice after the initial term. Leave 'Preview only' ticked to see the end date without recording anything.",
        Fields =
        {
            Field.Date("NoticeDate", "Notice given on", help: "blank = today"),
            Field.Choice("GivenBy", "Given by", new[] { "Client", "Molehill" }),
            Field.Bool("WhatIf", "Preview only", def: true)
        },
        Submit = v => db.Proc("dbo.usp_Notice_Give", ("@Client", agreementRef), ("@NoticeDate", v.Date("NoticeDate")),
            ("@GivenBy", v.Str("GivenBy")), ("@WhatIf", v.Bool("WhatIf")))
    };

    public static FormSpec PauseSupport(AdminDb db, string agreementRef, bool pause) => pause
        ? new FormSpec
        {
            Title = $"Pause support (late payment) - {agreementRef}",
            Intro = "The agreement allows support to be paused until overdue invoices are paid. The dashboard shows it as Paused.",
            Fields = { Field.Date("PauseDate", "Paused from", help: "blank = today") },
            Submit = v => db.Proc("dbo.usp_Agreement_PauseSupport", ("@Client", agreementRef), ("@Pause", true), ("@PauseDate", v.Date("PauseDate")))
        }
        : new FormSpec
        {
            Title = $"Resume support - {agreementRef}",
            Intro = "Support resumes straight away. Save to confirm.",
            Submit = _ => db.Proc("dbo.usp_Agreement_PauseSupport", ("@Client", agreementRef), ("@Pause", false))
        };

    public static FormSpec PriceChange(AdminDb db)
    {
        var lists = Queries.PriceLists(db).ToArray();
        return new FormSpec
        {
            Title = "Schedule a price change",
            Intro = "Moves agreements onto another price list from the effective date. The agreement requires 30 days' written notice.",
            Fields =
            {
                Field.Choice("NewPriceListName", "New price list", lists.Length == 0 ? new[] { "" } : lists),
                Field.Date("NotifiedDate", "Clients told on", required: true, def: DateTime.Today.ToString("yyyy-MM-dd")),
                Field.Date("EffectiveDate", "Effective from", required: true),
                Field.Choice("Client", "Agreement", new[] { AllClients }.Concat(Queries.AgreementChoices(db)).ToArray())
            },
            Submit = v => db.Proc("dbo.usp_PriceChange_Schedule", ("@NewPriceListName", v.Str("NewPriceListName")),
                ("@NotifiedDate", v.Date("NotifiedDate")), ("@EffectiveDate", v.Date("EffectiveDate")),
                ("@Client", v.Str("Client") == AllClients ? null : Queries.RefFromChoice(v["Client"])))
        };
    }

    public static FormSpec AddQuote(AdminDb db, string agreementRef) => new()
    {
        Title = $"Project quote - {agreementRef}",
        Fields =
        {
            Field.Text("Title", "Title", required: true),
            Field.Memo("Scope", "Scope"),
            Field.Decimal("EstimatedHours", "Estimated hours"),
            Field.Decimal("Price", "Price"),
            Field.Text("TicketRef", "Ticket", help: "MW-00001, optional")
        },
        Submit = v => db.Proc("dbo.usp_Quote_Add", ("@Client", agreementRef), ("@Title", v.Str("Title")), ("@Scope", v.Str("Scope")),
            ("@EstimatedHours", v.Dec("EstimatedHours")), ("@Price", v.Dec("Price")), ("@TicketRef", v.Str("TicketRef")))
    };

    // ------------------------------------------------------------------ tickets

    public static FormSpec OpenTicket(AdminDb db, string? agreementRef = null)
    {
        var choices = Queries.AgreementChoices(db);
        if (choices.Count == 0) choices.Add("");
        var def = agreementRef == null ? choices[0] : choices.FirstOrDefault(c => Queries.RefFromChoice(c) == agreementRef) ?? choices[0];
        return new FormSpec
        {
            Title = "Open ticket",
            Intro = "The response-due time is worked out from the severity and UK business hours (bank holidays included).",
            Fields =
            {
                Field.Choice("Client", "Client", choices.ToArray(), def),
                Field.Text("Title", "Title", required: true),
                Field.Choice("Severity", "Severity", Severities),
                Field.Choice("WorkType", "Work type", WorkTypes, help: "e.g. planned: tier change, failover test"),
                Field.Choice("RateType", "Rate", TicketRates.Select(r => r.Label).ToArray(), help: "out of hours only if planned"),
                Field.Text("InstanceName", "Instance", help: "optional"),
                Field.Text("ContactName", "Raised by", help: "named contact"),
                Field.DateTime("RaisedAt", "Raised at", help: "blank = now (UK)"),
                Field.Text("Channel", "Channel", def: "E-mail"),
                Field.Memo("Description", "Description")
            },
            Submit = v => db.Proc("dbo.usp_Ticket_Open", ("@Client", Queries.RefFromChoice(v["Client"])), ("@Title", v.Str("Title")),
                ("@Severity", v.Str("Severity")), ("@InstanceName", v.Str("InstanceName")), ("@ContactName", v.Str("ContactName")),
                ("@Description", v.Str("Description")), ("@RaisedAt", v.DateTime("RaisedAt")), ("@Channel", v.Str("Channel")),
                ("@WorkType", v.Str("WorkType")), ("@RateType", RateValue(v["RateType"])))
        };
    }

    public static FormSpec RespondTicket(AdminDb db, string ticketRef) => new()
    {
        Title = $"First response - {ticketRef}",
        Fields =
        {
            Field.DateTime("RespondedAt", "Responded at", help: "blank = now (UK)"),
            Field.Choice("Status", "New status", new[] { "InProgress", "AwaitingClient", "AwaitingEstimateApproval" })
        },
        Submit = v => db.Proc("dbo.usp_Ticket_Respond", ("@TicketRef", ticketRef), ("@RespondedAt", v.DateTime("RespondedAt")), ("@Status", v.Str("Status")))
    };

    public static FormSpec EstimateTicket(AdminDb db, string ticketRef) => new()
    {
        Title = $"Estimate - {ticketRef}",
        Intro = "Work likely to go beyond the included hours needs an estimate the client approves first. " +
                "Give the hours to record the estimate as sent; tick Approved when the client agrees.",
        Fields =
        {
            Field.Decimal("EstimateHours", "Estimate (hours)"),
            Field.Bool("Approved", "Client approved")
        },
        Submit = v => db.Proc("dbo.usp_Ticket_Estimate", ("@TicketRef", ticketRef), ("@EstimateHours", v.Dec("EstimateHours")), ("@Approved", v.Bool("Approved")))
    };

    public static FormSpec LogTime(AdminDb db, string ticketRef)
    {
        var ticketRate = db.Scalar("SELECT RateType FROM dbo.Ticket WHERE TicketRef = @r;", ("@r", ticketRef)) as string;
        var ticketChoice = $"Ticket's rate ({RateLabel(ticketRate).ToLowerInvariant()})";
        return new FormSpec
        {
            Title = $"Log time - {ticketRef}",
            Fields =
            {
                Field.Int("Minutes", "Minutes", required: true),
                Field.Text("Description", "Work done", required: true),
                Field.DateTime("WorkStart", "Started at", help: "blank = now minus the minutes"),
                Field.Choice("RateType", "Rate", new[] { ticketChoice, "Business hours", "Out of hours" }, help: "this entry only"),
                Field.Bool("IsBillable", "Billable", def: true)
            },
            Submit = v => db.Proc("dbo.usp_Time_Log", ("@TicketRef", ticketRef), ("@Minutes", v.Int("Minutes")), ("@Description", v.Str("Description")),
                ("@WorkStart", v.DateTime("WorkStart")), ("@RateType", v["RateType"] == ticketChoice ? null : RateValue(v["RateType"])),
                ("@IsBillable", v.Bool("IsBillable")))
        };
    }

    /// <summary>Correct time that has not been invoiced (wrong date, minutes, rate or description).</summary>
    public static FormSpec EditTimeEntry(AdminDb db, int timeEntryId)
    {
        var row = Queries.TimeEntry(db, timeEntryId);
        string Cur(string col) => row == null || row[col] is DBNull ? "" : row[col].ToString() ?? "";
        var started = row?["WorkStart"] is DateTime d ? d.ToString("yyyy-MM-dd HH:mm") : "";
        return new FormSpec
        {
            Title = $"Correct time - {Cur("TicketRef")}",
            Intro = "Time is only billed when it falls inside the agreement's billing period, so a wrong date means it is never invoiced " +
                    "and never uses included or pre-paid hours.",
            Fields =
            {
                Field.DateTime("WorkStart", "Started at", def: started),
                Field.Int("Minutes", "Minutes", def: Cur("Minutes")),
                Field.Text("Description", "Work done", def: Cur("Description")),
                Field.Choice("RateType", "Rate", new[] { "Business hours", "Out of hours" }, def: RateLabel(Cur("RateType"))),
                Field.Bool("IsBillable", "Billable", def: row?["IsBillable"] is true)
            },
            Submit = v => db.Proc("dbo.usp_Time_Update", ("@TimeEntryId", timeEntryId), ("@WorkStart", v.DateTime("WorkStart")),
                ("@Minutes", v.Int("Minutes")), ("@Description", v.Str("Description")), ("@RateType", RateValue(v["RateType"])),
                ("@IsBillable", v.Bool("IsBillable")))
        };
    }

    public static FormSpec DeleteTimeEntry(AdminDb db, int timeEntryId)
    {
        var row = Queries.TimeEntry(db, timeEntryId);
        return new FormSpec
        {
            Title = $"Remove time - {(row == null ? "" : row["TicketRef"])}",
            Intro = $"Remove {(row == null ? "this" : row["Minutes"])} minutes logged on {(row?["WorkStart"] is DateTime d ? d.ToString("dd MMM yyyy HH:mm") : "")}"
                    + " from this ticket? Only time that has not been invoiced can be removed. Save to confirm.",
            Submit = _ => db.Proc("dbo.usp_Time_Delete", ("@TimeEntryId", timeEntryId))
        };
    }

    /// <summary>Change the rate a ticket's time is charged at (business hours, out of hours or by time of work).</summary>
    public static FormSpec SetTicketRate(AdminDb db, string ticketRef)
    {
        var current = db.Scalar("SELECT RateType FROM dbo.Ticket WHERE TicketRef = @r;", ("@r", ticketRef)) as string;
        return new FormSpec
        {
            Title = $"Change rate - {ticketRef}",
            Intro = $"Currently: {RateLabel(current).ToLowerInvariant()}. Time already invoiced is never changed (void the invoice to re-bill it).",
            Fields =
            {
                Field.Choice("RateType", "Charge at", TicketRates.Skip(1).Select(r => r.Label).ToArray(), def: RateLabel(current)),
                Field.Bool("ApplyToUnbilled", "Re-rate time not yet invoiced", def: true)
            },
            Submit = v => db.Proc("dbo.usp_Ticket_SetRate", ("@TicketRef", ticketRef), ("@RateType", RateValue(v["RateType"])),
                ("@ApplyToUnbilled", v.Bool("ApplyToUnbilled")))
        };
    }

    public static FormSpec CloseTicket(AdminDb db, string ticketRef) => new()
    {
        Title = $"Close - {ticketRef}",
        Fields =
        {
            Field.Memo("Resolution", "Resolution", required: true),
            Field.Choice("Status", "Status", new[] { "Resolved", "Closed" })
        },
        Submit = v => db.Proc("dbo.usp_Ticket_Close", ("@TicketRef", ticketRef), ("@Resolution", v.Str("Resolution")), ("@Status", v.Str("Status")))
    };

    // ------------------------------------------------------------------ billing

    public static FormSpec RunBilling(AdminDb db) => new()
    {
        Title = "Run billing",
        Intro = "Creates draft invoices: Molehill Watch fees in advance for each cycle that has started, support in arrears for cycles that " +
                "have ended, and consultancy days for each month that has ended. Safe to run as often as you like; nothing is invoiced twice.",
        Fields =
        {
            Field.Date("AsOfDate", "As of", help: "blank = today"),
            Field.Choice("Client", "For", new[] { AllClients }.Concat(Queries.EngagementChoices(db, consultancyOnly: false)).ToArray())
        },
        Submit = v =>
        {
            var r = db.Proc("dbo.usp_Billing_Run", ("@AsOfDate", v.Date("AsOfDate")),
                ("@Client", v["Client"] == AllClients ? null : Queries.RefFromChoice(v["Client"])));
            if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
            return r;
        }
    };

    // ------------------------------------------------------------------ consultancy engagements

    public static readonly (string Label, string Value)[] BillingModes =
    {
        ("Day rate", "DayRate"), ("Hourly", "Hourly"), ("Fixed price", "FixedPrice")
    };
    public static readonly (string Label, string? Value)[] Roundings =
    {
        ("Standard (half days)", null), ("Half days", "HalfDay"), ("Whole days", "WholeDay"), ("Exact hours", "Exact")
    };

    /// <summary>A piece of consultancy work for a client: day rate, hourly or fixed price.</summary>
    public static FormSpec NewEngagement(AdminDb db, string? clientName = null)
    {
        var clients = Queries.ClientNames(db);
        if (clients.Count == 0) clients.Add("");
        if (clientName != null && clients.Contains(clientName)) clients = clients.OrderBy(c => c == clientName ? 0 : 1).ToList();
        return new FormSpec
        {
            Title = "New consultancy engagement",
            Intro = "Work for a client that is not Molehill Watch support: a project, a review, advice. Log the days against it as you go, " +
                    "and the billing run invoices each month once that month has ended. Fixed-price work is invoiced when you mark it finished.",
            Fields =
            {
                Field.Choice("ClientName", "Client", clients.ToArray()),
                Field.Text("Name", "What is it?", required: true, help: "e.g. Data warehouse migration"),
                Field.Choice("BillingMode", "Billed as", BillingModes.Select(m => m.Label).ToArray()),
                Field.Decimal("DayRate", "Day rate (£)", help: "day-rate work"),
                Field.Decimal("HourlyRate", "Hourly rate (£)", help: "hourly work"),
                Field.Decimal("FixedPrice", "Fixed price (£)", help: "fixed-price work"),
                Field.Decimal("OutOfHoursRate", "Out-of-hours rate (£/h)", help: "blank = out-of-hours work is billed at the day rate"),
                Field.Choice("DayRounding", "Rounding", Roundings.Select(r => r.Label).ToArray()),
                Field.Date("StartDate", "Starts", def: DateTime.Today.ToString("yyyy-MM-dd")),
                Field.Date("EndDate", "Expected to end", help: "blank = open ended"),
                Field.Text("PurchaseOrder", "Client PO", help: "printed on the invoice"),
                Field.Text("EngagementRef", "Reference", help: "blank = next CON-0000 number"),
                Field.Memo("Notes", "Notes")
            },
            Submit = v => db.Proc("dbo.usp_Engagement_Add",
                ("@Client", v.Str("ClientName") ?? throw new FormatException("Add a client first.")),
                ("@Name", v.Str("Name")),
                ("@BillingMode", BillingModes.First(m => m.Label == v["BillingMode"]).Value),
                ("@DayRate", v.Dec("DayRate")), ("@HourlyRate", v.Dec("HourlyRate")), ("@FixedPrice", v.Dec("FixedPrice")),
                ("@OutOfHoursRate", v.Dec("OutOfHoursRate")),
                ("@DayRounding", Roundings.First(r => r.Label == v["DayRounding"]).Value),
                ("@StartDate", v.Date("StartDate")), ("@EndDate", v.Date("EndDate")),
                ("@PurchaseOrder", v.Str("PurchaseOrder")), ("@EngagementRef", v.Str("EngagementRef")), ("@Notes", v.Str("Notes")))
        };
    }

    public static FormSpec EditEngagement(AdminDb db, string engagementRef)
    {
        var row = Queries.Engagement(db, engagementRef);
        string Now(string col) => Cur(row, col);
        return new FormSpec
        {
            Title = $"Change {engagementRef}",
            Intro = "A new rate applies to every day that has not been invoiced yet, including work already logged.",
            Fields =
            {
                Field.Text("Name", "What is it?", def: Now("Name")),
                Field.Decimal("DayRate", "Day rate (£)", def: Now("DayRate")),
                Field.Decimal("HourlyRate", "Hourly rate (£)", def: Now("HourlyRate")),
                Field.Decimal("FixedPrice", "Fixed price (£)", def: Now("FixedPrice")),
                Field.Decimal("OutOfHoursRate", "Out-of-hours rate (£/h)", def: Now("OutOfHoursRate")),
                Field.Date("StartDate", "Starts", def: Now("StartDate")),
                Field.Date("EndDate", "Expected to end", def: Now("EndDate")),
                Field.Text("PurchaseOrder", "Client PO", def: Now("PurchaseOrder")),
                Field.Choice("Status", "Status", new[] { "Active", "OnHold" }, def: Now("Status") == "OnHold" ? "OnHold" : "Active"),
                Field.Memo("Notes", "Notes", def: Now("Notes"))
            },
            Submit = v => db.Proc("dbo.usp_Engagement_Update", ("@Engagement", engagementRef), ("@Name", v.Str("Name")),
                ("@DayRate", v.Dec("DayRate")), ("@HourlyRate", v.Dec("HourlyRate")), ("@FixedPrice", v.Dec("FixedPrice")),
                ("@OutOfHoursRate", v.Dec("OutOfHoursRate")), ("@StartDate", v.Date("StartDate")), ("@EndDate", v.Date("EndDate")),
                ("@PurchaseOrder", v.Str("PurchaseOrder")), ("@Status", v.Str("Status")), ("@Notes", v.Str("Notes")))
        };
    }

    public static FormSpec CompleteEngagement(AdminDb db, string engagementRef)
    {
        // an engagement with an end date almost always finished on it, so start there
        var expectedEnd = Cur(Queries.Engagement(db, engagementRef), "EndDate");
        return new FormSpec
        {
            Title = $"Finish {engagementRef}",
            Intro = "Marks the work finished. The next billing run invoices whatever is left - and, for fixed-price work, the agreed price. "
                    + "The invoice is dated the day you give here.",
            Fields = { Field.Date("CompletedOn", "Finished on", def: expectedEnd,
                                  help: expectedEnd == "" ? "blank = today" : "the end date on the engagement; change it if it really finished another day") },
            Submit = v => db.Proc("dbo.usp_Engagement_Complete", ("@Engagement", engagementRef), ("@CompletedOn", v.Date("CompletedOn")))
        };
    }

    public static FormSpec CancelEngagement(AdminDb db, string engagementRef) => new()
    {
        Title = $"Cancel {engagementRef}",
        Intro = "For work that never happened. Anything already invoiced stops it being cancelled - finish it instead.",
        Fields = { Field.Text("Reason", "Reason") },
        Submit = v => db.Proc("dbo.usp_Engagement_Cancel", ("@Engagement", engagementRef), ("@Reason", v.Str("Reason")))
    };

    /// <summary>A day (or part of one) worked on a consultancy engagement.</summary>
    public static FormSpec LogWork(AdminDb db, string engagementRef)
    {
        var row = Queries.Engagement(db, engagementRef);
        var hourly = Cur(row, "BillingMode") == "Hourly";
        var ooh = row != null && row["OutOfHoursRate"] is decimal;
        return new FormSpec
        {
            Title = $"Log work - {engagementRef}",
            Intro = hourly ? "Give the hours worked. They are invoiced at the end of the month."
                           : "Give days (1, 0.5) or the hours worked - hours become days using the rounding set on the engagement. "
                             + "Everything done on one day counts together as that day's work.",
            Fields =
            {
                Field.Date("WorkDate", "Day", required: true, def: DateTime.Today.ToString("yyyy-MM-dd")),
                Field.Decimal("Days", "Days", help: hourly ? "or use hours" : "1 = a full day, 0.5 = half a day"),
                Field.Decimal("Hours", "or hours", help: "whichever is easier"),
                Field.Text("Description", "What you did", required: true),
                Field.Choice("RateType", "Rate", ooh ? new[] { "Business hours", "Out of hours" } : new[] { "Business hours" }),
                Field.Bool("IsBillable", "Billable", def: true, help: "untick for work you are not charging for")
            },
            Submit = v => db.Proc("dbo.usp_Work_Log", ("@Engagement", engagementRef), ("@Description", v.Str("Description")),
                ("@Days", v.Dec("Days")), ("@Hours", v.Dec("Hours")), ("@WorkDate", v.Date("WorkDate")),
                ("@RateType", v["RateType"] == "Out of hours" ? "OutOfHours" : "BusinessHours"),
                ("@IsBillable", v.Bool("IsBillable")))
        };
    }

    // ------------------------------------------------------------------ invoices typed by hand

    public static FormSpec NewInvoice(AdminDb db, string? engagementRef = null)
    {
        var clients = Queries.ClientNames(db);
        if (clients.Count == 0) clients.Add("");
        var engagements = new[] { NoEngagement }.Concat(Queries.EngagementChoices(db, consultancyOnly: false)).ToArray();
        var against = engagementRef == null ? NoEngagement : engagements.FirstOrDefault(e => e.StartsWith(engagementRef + " ")) ?? NoEngagement;
        return new FormSpec
        {
            Title = "New invoice (typed by hand)",
            Intro = "For anything the billing run does not produce: licences bought for a client, a one-off charge, expenses re-charged. " +
                    "It starts empty - add the lines to it afterwards.",
            Fields =
            {
                Field.Choice("ClientName", "Client", clients.ToArray()),
                Field.Date("InvoiceDate", "Invoice date", help: "blank = today"),
                Field.Choice("Engagement", "Against", engagements, def: against),
                Field.Text("Notes", "Note on the invoice")
            },
            Submit = v => db.Proc("dbo.usp_Invoice_Create", ("@Client", v.Str("ClientName") ?? throw new FormatException("Add a client first.")),
                ("@InvoiceDate", v.Date("InvoiceDate")),
                ("@Engagement", v["Engagement"] == NoEngagement ? null : Queries.RefFromChoice(v["Engagement"])),
                ("@Notes", v.Str("Notes")))
        };
    }

    public static FormSpec AddInvoiceLine(AdminDb db, string invoiceNo) => new()
    {
        Title = $"Add a line to {invoiceNo}",
        Intro = "Either an amount on its own, or a quantity and a unit price.",
        Fields =
        {
            Field.Text("Description", "Description", required: true),
            Field.Decimal("Amount", "Amount (£)", help: "or fill in the two below"),
            Field.Decimal("Quantity", "Quantity"),
            Field.Decimal("UnitPrice", "Unit price (£)")
        },
        Submit = v => db.Proc("dbo.usp_Invoice_AddLine", ("@InvoiceNo", invoiceNo), ("@Description", v.Str("Description")),
            ("@Amount", v.Dec("Amount")), ("@Quantity", v.Dec("Quantity")), ("@UnitPrice", v.Dec("UnitPrice")))
    };

    public static FormSpec RemoveInvoiceLine(AdminDb db, string invoiceNo, int invoiceLineId, string description) => new()
    {
        Title = $"Remove a line from {invoiceNo}",
        Intro = $"Removing: {description}",
        Fields = { },
        Submit = _ => db.Proc("dbo.usp_Invoice_RemoveLine", ("@InvoiceLineId", invoiceLineId))
    };

    public static FormSpec AdjustInvoice(AdminDb db, string invoiceNo) => new()
    {
        Title = $"Adjust {invoiceNo}",
        Intro = "Adds a line to a draft invoice. Use a negative amount for a credit.",
        Fields =
        {
            Field.Text("Description", "Description", required: true),
            Field.Decimal("Amount", "Amount (£)", required: true)
        },
        Submit = v => db.Proc("dbo.usp_Invoice_Adjust", ("@InvoiceNo", invoiceNo), ("@Description", v.Str("Description")), ("@Amount", v.Dec("Amount")))
    };

    public static FormSpec SetInvoiceStatus(AdminDb db, string invoiceNo, string status) => new()
    {
        Title = $"{invoiceNo} - mark {status.ToLowerInvariant()}",
        Fields = { Field.Date("StatusDate", status == "Void" ? "Voided on" : $"{status} on", help: "blank = today") },
        Submit = v => db.Proc("dbo.usp_Invoice_SetStatus", ("@InvoiceNo", invoiceNo), ("@Status", status), ("@StatusDate", v.Date("StatusDate")))
    };

    /// <summary>Writes the invoice HTML to a file and returns the path.</summary>
    public static string SaveInvoiceHtml(AdminDb db, string invoiceNo, string folder)
    {
        var r = db.Proc("dbo.usp_Invoice_Html", ("@InvoiceNo", invoiceNo), ("@Select", true));
        var html = r.First is { Rows.Count: > 0 } t && t.Rows[0]["Html"] is string s ? s
            : throw new InvalidOperationException($"No HTML came back for {invoiceNo}.");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"{invoiceNo}.html");
        File.WriteAllText(path, html);
        return path;
    }

    public static string SaveDashboardHtml(AdminDb db, string folder)
    {
        var r = db.Proc("dbo.usp_DashboardHtml", ("@Select", true));
        var html = r.First is { Rows.Count: > 0 } t ? t.Rows[0][t.Columns.Count - 1] as string : null;
        if (html == null) throw new InvalidOperationException("No HTML came back from usp_DashboardHtml.");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, $"Dashboard-{DateTime.Now:yyyy-MM-dd}.html");
        File.WriteAllText(path, html);
        return path;
    }

    /// <summary>Where invoice and dashboard HTML is saved (OutputFolder in the config file).</summary>
    public static string OutputFolder { get; set; } = AppConfig.DefaultOutputFolder;
}
