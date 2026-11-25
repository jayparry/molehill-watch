# What the health check needs, for whoever approves it

A Molehill Data Services SQL Server health check reviews configuration, backups, maintenance,
security, versions and recoverability. It is **read-only**: it installs nothing, writes nothing,
changes no setting, and cannot query any application table.

It needs **no access to the server itself**. Everything is read over an ordinary SQL Server
connection from a machine we control. Nobody logs on to the server and nothing is run on it.

## The short version

One login per instance. Three server-level permissions, read access to backup and job history in
`msdb`, and the error log. **No `sysadmin` and no fixed server role.** This is less than the account
used for Molehill Watch monitoring, which many clients already run.

## The ask, in full

| # | What | Where | Why |
|---|------|-------|-----|
| 1 | One login, in no privileged role | each instance | the identity the review runs as |
| 2 | `VIEW SERVER STATE` | server level | configuration, waits, memory, storage latency, HA health |
| 3 | `VIEW ANY DEFINITION` | server level | index and object definitions, to say how to fix things |
| 4 | `CONNECT ANY DATABASE` | server level (2014+) | index, statistics, space and integrity findings per database |
| 5 | Read access in `msdb` | `msdb` only | backups, Agent jobs and failures, alerts and operators |
| 6 | `EXECUTE` on `sys.xp_readerrorlog` | `master` | the error log |
| 7 | TCP access to the instance port | firewall | 1433, or the fixed port for a named instance |

```sql
CREATE LOGIN [CONTOSO\svc_mdshealth] FROM WINDOWS WITH DEFAULT_DATABASE = [master];

USE master;
GRANT VIEW SERVER STATE    TO [CONTOSO\svc_mdshealth];
GRANT VIEW ANY DEFINITION  TO [CONTOSO\svc_mdshealth];
GRANT CONNECT ANY DATABASE TO [CONTOSO\svc_mdshealth];

-- item 6 is a permission on an object, so unlike the three above it needs a user, not just a login
CREATE USER [CONTOSO\svc_mdshealth] FOR LOGIN [CONTOSO\svc_mdshealth];
GRANT EXECUTE ON sys.xp_readerrorlog TO [CONTOSO\svc_mdshealth];

USE msdb;
CREATE USER [CONTOSO\svc_mdshealth] FOR LOGIN [CONTOSO\svc_mdshealth];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [CONTOSO\svc_mdshealth];
ALTER ROLE db_datareader      ADD MEMBER [CONTOSO\svc_mdshealth];

-- No server role. No sysadmin. No user database access. Stop here.
```

If `db_datareader` on `msdb` is too wide, we will supply a script granting `SELECT` on only the
tables read: backup and restore history, suspect pages, alerts, operators, notifications, and the
Agent job tables. Note that **`SQLAgentReaderRole` does not grant `SELECT` on the Agent tables**. It
covers `sysjobs_view` and `sp_help_job`, which is enough, but a narrower grant that omits the job
tables and assumes the role covers them produces a report saying every server has no jobs.

## What this account cannot do

| Cannot | Detail |
|--------|--------|
| Query any application table | `CONNECT ANY DATABASE` permits connecting, not selecting. `SELECT` is refused |
| Create, alter, drop or write anything | no `CONTROL`, no `ALTER ANY`, no `db_owner`, no `db_ddladmin` |
| Change any setting or trace flag | `sp_configure` is refused |
| Read a password hash | login rows and policy flags are visible, which the security review needs, but `password_hash` reads as `NULL` |
| Read any secret | credentials and keys are listed by name only. Neither holds the secret, and the service master key cannot be opened |
| Run, stop or alter a job | `SQLAgentReaderRole` reads. `SQLAgentOperatorRole` would be needed to act, and is not asked for |
| Back up, restore or detach | refused. No `db_backupoperator`, no `dbcreator` |
| Reach the operating system | `xp_cmdshell` is `sysadmin` only, and not granted |

Every row was tested on a login holding exactly the permissions above, not taken from
documentation.

## What it can see that you might not expect

The query analysis reads query text and execution plans, and those can contain application data. We
tested it: with no permission to read a table, this account read a client name out of a cached
execution plan for a query that had filtered on it.

This is inherent to performance analysis rather than to these permissions. Anyone tuning a query
reads its text and its plan, your own staff included. What appears is incidental, usually literals
in ad-hoc SQL and compiled parameter values, and it cannot be queried or exported as a table of your
data. If it is unacceptable for a particular system, the performance half can run on waits, storage
latency and configuration alone, with no query text at all; the report then says which findings were
not available. Everything seen is covered by the confidentiality terms of the engagement.

## If something is refused

| Refused | What the report loses |
|---------|----------------------|
| `VIEW SERVER STATE` | Most of it: configuration, waits, storage latency, memory, tempdb, HA health, queries. **At this point the health check is not worth buying**, and we would say so rather than deliver a thin report |
| `CONNECT ANY DATABASE` | Index, statistics, space and integrity findings per database. Server-level findings survive. A user can be created in each database instead, which is more work for you and exactly as safe |
| Read access in `msdb` | Backups, restore history, Agent jobs, alerting. "Could you restore?" and "would anyone be told?" are two of the questions most worth answering |
| `EXECUTE on sys.xp_readerrorlog` | The error log review. Everything else survives |

## Two things worth knowing in advance

**Query Store, if you want the query findings to be any good.** The plan cache holds only what is
cached now, so a restart, failover or memory pressure empties it, and a server rebooted the night
before has little to say. Query Store keeps history, which is what turns "this query is slow" into
"this query became slow three weeks ago". Reading it needs nothing beyond the permissions above, but
it is per database, off by default before SQL Server 2022, and **switching it on is a change this
account cannot make**. If you want it used, it needs enabling by whoever administers the instance,
ideally a fortnight ahead so there is history to read. It is the only item here with a lead time.

**We are not asking for `sysadmin`, including for CHECKDB.** The date a database was last verified
free of corruption is read with `DBCC DBINFO`, widely documented as requiring `sysadmin`. Tested, it
works with the permissions above, provided the connection's current database is the one being
checked. That was verified on SQL Server 2025; on an older version it may be refused, in which case
the same conclusion comes less precisely from the error log and the report says it is inferred.

## Platform notes

| Platform | What changes |
|----------|--------------|
| SQL Server on someone else's VM | nothing, the script applies as written |
| Azure SQL Managed Instance | the same, using a Microsoft Entra account or a SQL login |
| Azure SQL Database | no instance in the same sense. `CONNECT ANY DATABASE` does not exist, so a user is created in each database with `VIEW DATABASE STATE` and `VIEW DEFINITION` |

Some things are visible to any login by SQL Server's own defaults rather than by this request:
which databases exist, the names of other logins, the version and edition, and backup history in
`msdb`, which has `guest` enabled on a default install.

Without operating system access we still read the Windows build, service accounts, drive free space
and whether Lock Pages in Memory is in effect, all through SQL Server. What is genuinely lost is the
event log, antivirus exclusions, power plan, page file and allocation unit size. Those become
questions in the report rather than findings.

## Summary for a change record

> A read-only SQL Server login on each instance under review, granted `VIEW SERVER STATE`,
> `VIEW ANY DEFINITION` and `CONNECT ANY DATABASE` at server level, read access to backup and SQL
> Agent history in `msdb`, and `EXECUTE` on `sys.xp_readerrorlog`. No fixed server role, no
> `sysadmin`, and no permission to query any application table. Access is over the SQL Server port
> only; nothing is installed and nobody logs on to the server. The account cannot change any
> setting, read any password or key, or run anything outside SQL Server. The performance review
> reads query text and execution plans, which can incidentally contain data values, as any
> performance analysis does.

---

*Molehill Data Services Ltd. Registered in England and Wales, company no. 17219913.*
