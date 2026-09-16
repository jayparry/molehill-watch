# SQL Connection Tester

A terminal app for building, saving and testing SQL Server connection strings. It opens each connection, reads one row from `dbo.TestConnection`, and reports **ConnectionString, TestText, Status and ErrorMessage**. Read-only: it creates and changes nothing on the server.

The PowerShell version (`Tools\Test-SqlConnectionString.ps1`) does the same job for a list you already have. This app is for building connection strings interactively, keeping a list of them, and covering the Entra ID sign-in methods.

## Running it

```powershell
cd Tools\SqlConnectionTester
dotnet run                                  # the app
dotnet run -- --test                        # test every saved connection, no UI
dotnet run -- -s "Server=SQL01;..."         # test one connection string (repeatable)
dotnet run -- --csv results.csv             # test everything and write a CSV
dotnet run -- --file D:\client-a.json       # use a different connections file
```

Needs the .NET 8 SDK (or newer) to run from source. Exit codes: `0` all succeeded, `2` one or more failed, `1` error, `64` bad usage.

### A single .exe for servers without .NET

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o publish
```

That produces one `SqlConnectionTester.exe` (about 77 MB) that runs anywhere, including locked-down jump boxes. The app needs a real terminal (Windows Terminal, conhost or SSH); in a pipeline use `--test`.

## Keys

| Key | Action |
|---|---|
| F2 / F3 / F4 | Add, edit, delete a connection |
| F5 / F6 | Test the selected connection / test all of them |
| F7 | Full result, including the complete error |
| F8 | Export results to CSV |
| Ctrl+S / Ctrl+Q | Save the list / quit |

Enter on a connection edits it. The menus carry the same actions plus **Copy connection string**.

## Authentication methods

| Method | Needs | Notes |
|---|---|---|
| Windows authentication | - | The signed-in Windows account |
| SQL Server authentication | login + password | |
| Entra ID - password | user + password | Deprecated by Microsoft; still works |
| Entra ID - integrated | - | Domain-joined single sign-on |
| Entra ID - interactive (MFA) | user (optional) | Opens a browser prompt |
| Entra ID - device code | - | Shows a code to enter on another device |
| Entra ID - service principal | client id + secret | |
| Entra ID - managed identity | client id (user-assigned only) | Azure VMs |
| Entra ID - default | - | Environment, managed identity, Azure CLI, then browser |

Other options per connection: database, encryption (Mandatory/Optional/Strict), trust server certificate, read-only intent, MultiSubnetFailover, connect and query timeouts, a custom test query, or a **raw connection string** pasted in whole.

## The connections file

Saved as JSON, by default in `%APPDATA%\SqlConnectionTester\connections.json`. Use `--file` for one file per client.

**Passwords are not saved unless you tick "Save password"**, and then they're encrypted with Windows DPAPI for your account on that machine: the file is useless to anyone else. Copy it to another machine and the password simply comes back blank. Displayed and exported connection strings always show `Password=***`; **Copy connection string** puts the real one on the clipboard.

## The test table

```sql
CREATE TABLE dbo.TestConnection (TestText nvarchar(200));
INSERT dbo.TestConnection VALUES (N'Connection OK - AppDb on SQL01');
```

One row, one column. Put a recognisable message in it so the app proves *which* database it reached. A different query can be set per connection if a client's table is named differently.
