# Molehill Manager

A terminal front end for the **MolehillAdmin** database. It covers clients, agreements, instances, onboarding, tickets, time, billing and invoices. It runs on your own machine and is never installed on a client server.

Every change goes through the MolehillAdmin stored procedures, so the rules are the same whether you use the app or SQL. Any warnings a procedure prints are shown in the app. These include "out of Microsoft support", "priced as a secondary replica" and "no invoice for this cycle".

## Running it

Run `MolehillManager.exe`. That's all. It's a single self-contained file (about 38 MB) with nothing to install. Build it with:

```powershell
cd Admin\MolehillManager
dotnet publish -c Release -r win-x64 -o publish     # -> publish\MolehillManager.exe
```

**No MolehillAdmin yet? It sets it up for you.** The install script is built into the exe, so you get the version the app was built for. Depending on what it finds on the configured server:

| Found | It does |
|---|---|
| No database of that name | Offers to create it (under the name in the config file) and install MolehillAdmin, then asks for your business and invoice details |
| An empty database, or one with other unrelated objects | Offers to install into it |
| An older MolehillAdmin | Offers to upgrade it in place (data is kept) |
| An install that stopped part way | Offers to finish it |
| A database whose tables have MolehillAdmin's names but isn't MolehillAdmin | Leaves it alone and asks for another database name |
| A database you have no access to | Explains, and doesn't try to create anything |

Creating a database needs `CREATE ANY DATABASE` (the `dbcreator` role, or sysadmin); it warns you if the sign-in doesn't appear to have it.

The app doesn't schedule the daily billing run and HTML export. Use **F6** in the app, or run `Install-MolehillAdmin.ps1` once on that machine to schedule it.

`MolehillManager.exe --install` does the same create, install or upgrade without the screen, using the config file (for example after copying a new version of the exe into place).

The first time it runs, it asks where MolehillAdmin is and how to sign in. It tests the connection, then saves the answers to its config file. After that it starts straight into the dashboard. If the file is missing something later (for example you delete a line, or change the sign-in to one that needs a user name), it asks only for that. **File > Settings** changes anything and reconnects.

### The config file: `MolehillManager.config.json`

It's found in this order:

1. `--config <path>`, if given.
2. Next to `MolehillManager.exe`. This is portable: keep the exe and its settings together, for example on a USB stick or in a synced folder.
3. `%APPDATA%\MolehillManager\`.

A new file goes next to the exe when that folder is writable, otherwise in `%APPDATA%`. **Help > About** shows which file is in use.

```json
{
  "Connection": {
    "Server": "SQL01\\SQLEXPRESS",
    "Database": "MolehillAdmin",
    "Authentication": "SqlLogin",
    "User": "molehill_admin",
    "PasswordEncrypted": "AQAAANCMnd8BFdERjHoAwE/Cl+sB...",
    "SavePassword": true,
    "Encrypt": "Mandatory",
    "TrustServerCertificate": true,
    "ConnectTimeoutSeconds": 15
  },
  "OutputFolder": "C:\\Users\\you\\Documents\\Molehill\\Invoices",
  "AutoRefreshMinutes": 5
}
```

| Setting | Values |
|---|---|
| `Authentication` | `Windows`, `SqlLogin`, `EntraInteractive` (browser/MFA), `EntraPassword`, `EntraServicePrincipal` (User = client id, password = client secret), `EntraManagedIdentity` (User = client id for a user-assigned identity), `EntraDefault` (az login, environment, managed identity) |
| `Encrypt` | `Mandatory`, `Optional`, `Strict` |
| `OutputFolder` | Where invoice and dashboard HTML is saved |
| `AutoRefreshMinutes` | `0` = only on F5 |

**Passwords and client secrets:**

* **Remember it ticked:** the secret is stored only as `PasswordEncrypted`, encrypted with Windows DPAPI for your Windows account on that machine. Copied to another PC or read by another user, the file gives the password to no one, and the app just asks for it again.
* **Remember it not ticked:** nothing is stored, and the app asks for the password each time it starts.
* **Typed in by hand:** you can add `"Password": "..."` in plain text. The app encrypts it and removes the plain text the moment it starts.
* **Never stored:** Windows and Entra interactive, managed identity and default sign-in don't keep a secret.

Editing the file by hand is fine:

* Comments and trailing commas are allowed.
* Windows names can be typed with single backslashes (`SQL01\INST`, `D:\Reports`).
* An unreadable file is kept as `.bak` and the settings screen opens.

```powershell
MolehillManager.exe --setup                  # open the settings screen first
MolehillManager.exe --config D:\test.json    # a separate file, e.g. for a test copy of MolehillAdmin
```

Running from source (`dotnet run`) needs the .NET 8 SDK and keeps its config next to the build output.

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

They use the database in the config file, or pass `-c "connection string"` to point one somewhere else.

```powershell
MolehillManager.exe --selftest                      # read-only: every screen, agreement window and form
MolehillManager.exe --selftest-write --allow-writes # submits every form: a TEST copy of MolehillAdmin only
MolehillManager.exe --selftest-config               # config file handling and encryption (no database)
MolehillManager.exe --selftest-setup SQL01          # the first-run settings screen, driven headlessly
MolehillManager.exe --selftest-install SQL01        # create / install / upgrade scratch MolehillAdmin_selftest_* databases, then drops them
```
