/*
===============================================================================
 Molehill Watch - uninstall
 Removes the Molehill Watch SQL Agent jobs and the MolehillWatch database
 (including all collected history and stored reports).

 Not removed (review and remove manually if no longer needed):
   * the Molehill Data Services login and its server-level grants
     (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE)
   * its user in msdb
   * Windows scheduled tasks under "\Molehill Watch\" (Express edition only):
       Get-ScheduledTask -TaskPath '\Molehill Watch\' | Unregister-ScheduledTask -Confirm:$false
===============================================================================
*/
SET NOCOUNT ON;
USE msdb;
GO
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
USE master;
GO
IF DB_ID(N'MolehillWatch') IS NOT NULL
BEGIN
    ALTER DATABASE MolehillWatch SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE MolehillWatch;
    PRINT N'Removed database MolehillWatch.';
END
GO
