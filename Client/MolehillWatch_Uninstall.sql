/*
===============================================================================
 Molehill Watch - uninstall
 Run in the database Molehill Watch was installed into (select it in the SSMS
 database drop-down first: MolehillWatch, or the client's DBA database).

 Removes:
   * the Molehill Watch SQL Agent jobs and job category
   * every object in the "mw" schema, the MolehillWatchReader role and the schema
   * the database itself ONLY if it is the default MolehillWatch database and
     nothing else is left in it (an existing DBA database is never dropped)

 Not removed (review and remove manually if no longer needed):
   * the Molehill Data Services login and its server-level grants
     (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE)
   * its users in msdb and in this database
   * Windows scheduled tasks under "\Molehill Watch\" (Express edition only):
       Get-ScheduledTask -TaskPath '\Molehill Watch\' | Unregister-ScheduledTask -Confirm:$false
===============================================================================
*/
SET NOCOUNT ON;
GO
IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
    RAISERROR('Select the database Molehill Watch was installed into first. Uninstall stopped.', 20, 1) WITH LOG;
GO

-- 1. SQL Agent jobs
DECLARE @job sysname;
DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR
    SELECT j.name FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
    WHERE c.name = N'Molehill Watch';
OPEN jobs;
FETCH NEXT FROM jobs INTO @job;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @job, @delete_unused_schedule = 1;
    PRINT N'Removed job: ' + @job;
    FETCH NEXT FROM jobs INTO @job;
END
CLOSE jobs; DEALLOCATE jobs;

IF EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'Molehill Watch' AND category_class = 1)
    EXEC msdb.dbo.sp_delete_category @class = N'JOB', @name = N'Molehill Watch';
GO

-- 2. Objects in the mw schema (foreign keys first, then everything else)
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(10)
FROM sys.foreign_keys fk
JOIN sys.tables t ON t.object_id = fk.parent_object_id
WHERE t.schema_id = SCHEMA_ID(N'mw');

SELECT @sql = @sql + N'DROP ' + CASE o.type WHEN 'U' THEN N'TABLE' WHEN 'P' THEN N'PROCEDURE' WHEN 'V' THEN N'VIEW' ELSE N'FUNCTION' END
            + N' ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';' + CHAR(10)
FROM sys.objects o
WHERE o.schema_id = SCHEMA_ID(N'mw') AND o.type IN ('U', 'P', 'V', 'FN', 'IF', 'TF')
ORDER BY CASE o.type WHEN 'P' THEN 1 WHEN 'V' THEN 2 WHEN 'U' THEN 4 ELSE 3 END;

IF @sql <> N''
BEGIN
    EXEC (@sql);
    PRINT N'Removed Molehill Watch objects from ' + QUOTENAME(DB_NAME()) + N'.';
END

IF DATABASE_PRINCIPAL_ID(N'MolehillWatchReader') IS NOT NULL
BEGIN
    SET @sql = N'';
    SELECT @sql = @sql + N'ALTER ROLE MolehillWatchReader DROP MEMBER ' + QUOTENAME(USER_NAME(member_principal_id)) + N';'
    FROM sys.database_role_members WHERE role_principal_id = DATABASE_PRINCIPAL_ID(N'MolehillWatchReader');
    SET @sql = @sql + N'DROP ROLE MolehillWatchReader;';
    EXEC (@sql);
END

IF SCHEMA_ID(N'mw') IS NOT NULL
    DROP SCHEMA mw;

-- remember which database this was, for step 3
IF OBJECT_ID('tempdb..#MolehillUninstall') IS NOT NULL DROP TABLE #MolehillUninstall;
CREATE TABLE #MolehillUninstall (DatabaseName sysname, UserObjects int);
INSERT #MolehillUninstall SELECT DB_NAME(), (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0);
GO

-- 3. Drop the database only if it is the default MolehillWatch database and now empty
USE master;
GO
DECLARE @dbName sysname, @userObjects int;
SELECT @dbName = DatabaseName, @userObjects = UserObjects FROM #MolehillUninstall;
IF @dbName = N'MolehillWatch' AND @userObjects = 0
BEGIN
    ALTER DATABASE MolehillWatch SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MolehillWatch;
    PRINT N'Removed database MolehillWatch.';
END
ELSE
    PRINT N'Database ' + QUOTENAME(@dbName) + N' kept (it is not the default MolehillWatch database, or it still contains other objects).';
DROP TABLE #MolehillUninstall;
GO
