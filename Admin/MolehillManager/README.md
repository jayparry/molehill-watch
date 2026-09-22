# Molehill Manager

A terminal front end for the **MolehillAdmin** database. It covers clients, agreements, instances, onboarding, tickets, time, billing and invoices. It runs on your own machine and is never installed on a client server.

Every change goes through the MolehillAdmin stored procedures, so the rules are the same whether you use the app or SQL. Any warnings a procedure prints are shown in the app. These include "out of Microsoft support", "priced as a secondary replica" and "no invoice for this cycle".

## Running it

```powershell
cd Admin\MolehillManager
dotnet run                                   # asks where MolehillAdmin is (remembered; the password never is)
dotnet run -- -s SQL01 -d MolehillAdmin      # Windows authentication
dotnet run -- -c "Server=...;Database=MolehillAdmin;..."
```

Sign-in can be Windows, SQL login or Entra ID (interactive/MFA). Running from source needs the .NET 8 SDK or newer. To get a single exe that needs nothing installed:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o publish
```

## Screens

| Tab | What's there | Enter / F3 |
|---|---|---|
| **Dashboard** | The daily to-do list (SLA, onboarding, versions, billing, reviews), plus money totals | Full alert text |
| **Clients** | Agreements, with status, instances, monthly fee, open tickets and onboarding left | Opens the agreement |
| **Tickets** | Open tickets (or all), with SLA due times and hours logged | Respond, log time, estimate or approve, close |
| **Billing** | Outstanding or all invoices, with their lines | Save as HTML, mark sent or paid, adjust, void |

**Agreement window** (Enter on a client):

- It has tabs for Instances, Onboarding, Contacts, Tickets and Weekly reports.
- F2 adds to whichever tab is showing.
- Enter on a row gives the actions for that row.
- F4 lists everything else: record the initial review, notice (preview or record), pause or resume support, usage this cycle, project quote, and run billing for this agreement.

## Keys

| Key | Action |
|---|---|
| F2 | New client, ticket or billing run, depending on the tab |
| F3 / Enter | Open, or actions for the selected row |
| F5 | Refresh |
| F6 | Run billing |
| Ctrl+Q | Quit |

In forms:

- `*` marks a required field.
- A blank field means "use the default": today, now, or the next reference number.
- Enter on a `[ choice ]` opens the list.
- Dates are `yyyy-mm-dd` (`dd/mm/yyyy` works too).
- Times are UK time.

## Instances and Azure SQL

| Platform | How it's priced |
|---|---|
| SqlServer | Per instance. The 3rd and later are at the multi-server rate. Secondaries are at the secondary rate. |
| AzureSqlManagedInstance | As a SQL Server instance, and it counts towards the multi-server tiers |
| AzureSqlDatabaseServer / AzureSqlDatabaseElasticPool | One unit covering 5 databases, plus a fee for each extra database. Give **Databases**, and update it when databases are added or removed. It doesn't count towards the tiers. |
| Role GeoReplica | A failover-group secondary. It's included free for Azure SQL Database, and at the secondary rate for a Managed Instance. |

Covered from:

- Instances added before the agreement's first invoice are covered from the start date.
- Instances added later are charged from the next cycle start (no pro-rata).
- An explicit **Covered from** date overrides both.

## Invoices

**Save as HTML** writes the invoice to `Documents\Molehill\Invoices\<InvoiceNo>.html` and offers to open it. From the browser, print it to PDF. **File > Save dashboard HTML** does the same for the daily dashboard.

## Self-tests

```powershell
# read-only: builds every screen, agreement window and form against a MolehillAdmin
dotnet run -- -c "..." --selftest

# writes a test client, instances, tickets and invoices through every form. Use a TEST copy only.
dotnet run -- -c "..." --selftest-write --allow-writes
```
