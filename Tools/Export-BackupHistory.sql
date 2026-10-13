/*
===============================================================================
 Molehill Data Services - export backup history for Restore-DatabaseCopy.ps1
-------------------------------------------------------------------------------
 Run this ON the source server, and hand the result to Restore-DatabaseCopy.ps1
 as -SourceHistoryFile. The restore then needs no connection to this server at
 all: it reads the history out of the file and does everything else on the
 destination.

 That matters for an old instance a modern machine cannot connect to. SQL
 Server encrypts the login packet whatever you ask for, and Windows Server
 2008 R2 will sometimes drop a modern client's TLS handshake outright - the
 client sees "An existing connection was forcibly closed by the remote host".
 Running this locally sidesteps the whole question, because a connection made
 on the server itself does not have to cross that gap.

 WHAT IT READS
   msdb.dbo.backupset and msdb.dbo.backupmediafamily. Nothing else, and
   nothing is written or changed anywhere.

 HOW TO RUN IT

   On the server, in a command prompt:

     sqlcmd -S . -i Export-BackupHistory.sql -o history.csv -s"," -W -h-1

   -s"," separates the columns with commas, -W trims the padding, and -h-1
   leaves the header out. The script does not need the header - it knows the
   column order from this file - and leaving it out avoids the row of dashes
   sqlcmd puts underneath it.

   Or in SQL Server Management Studio: open this file, edit the two settings
   below, run it, then right-click the results grid and choose
   "Save Results As..." and save as CSV. That writes a header line, which is
   equally fine: the script accepts the file either way.

   If a backup path has a comma in it, export with -s"|" instead; the script
   works out the separator from the file.

   Either way, copy the file to wherever you are running the PowerShell from.

 THE TWO SETTINGS

   @Databases  a comma separated list of database names, or leave it as NULL
               for every database on the instance.
   @Days       how far back to look. 180 matches the script's own default.

 Dates come out in ISO 8601 (2026-10-13T09:15:42.000) so that no regional
 setting at either end can change their meaning. The large LSN numbers come out
 as plain digits for the same reason.
===============================================================================
*/
SET NOCOUNT ON;

DECLARE @Databases nvarchar(max) = NULL;    -- e.g. N'Sales,Stock,Payroll'
DECLARE @Days      int           = 180;

DECLARE @Wanted TABLE (DatabaseName sysname PRIMARY KEY);

IF @Databases IS NOT NULL
BEGIN
    /* split the list by hand: STRING_SPLIT does not exist before SQL Server 2016,
       and this has to run on whatever old instance you are leaving behind */
    DECLARE @rest nvarchar(max) = @Databases + N',';
    DECLARE @one  nvarchar(max);
    WHILE CHARINDEX(N',', @rest) > 0
    BEGIN
        SET @one = LTRIM(RTRIM(LEFT(@rest, CHARINDEX(N',', @rest) - 1)));
        SET @rest = SUBSTRING(@rest, CHARINDEX(N',', @rest) + 1, LEN(@rest));
        IF @one <> N'' AND NOT EXISTS (SELECT 1 FROM @Wanted WHERE DatabaseName = @one)
            INSERT @Wanted (DatabaseName) VALUES (@one);
    END
END

SELECT  bs.backup_set_id,
        backup_set_uuid    = CONVERT(varchar(36), bs.backup_set_uuid),
        bs.type,
        bs.position,
        first_lsn          = CONVERT(varchar(40), bs.first_lsn),
        last_lsn           = CONVERT(varchar(40), bs.last_lsn),
        checkpoint_lsn     = CONVERT(varchar(40), bs.checkpoint_lsn),
        database_backup_lsn = CONVERT(varchar(40), ISNULL(bs.database_backup_lsn, 0)),
        backup_start_date  = CONVERT(varchar(23), bs.backup_start_date, 126),
        backup_finish_date = CONVERT(varchar(23), bs.backup_finish_date, 126),
        bs.database_name,
        family_guid        = CONVERT(varchar(36), bs.family_guid),
        is_copy_only       = CONVERT(int, bs.is_copy_only),
        has_backup_checksums = CONVERT(int, ISNULL(bs.has_backup_checksums, 0)),
        backup_size        = CONVERT(varchar(40), CONVERT(decimal(38,0), bs.backup_size)),
        bs.software_major_version,
        key_algorithm      = ISNULL(CONVERT(varchar(32), bs.key_algorithm), ''),
        mf.physical_device_name,
        mf.family_sequence_number
FROM    msdb.dbo.backupset AS bs
JOIN    msdb.dbo.backupmediafamily AS mf
        ON mf.media_set_id = bs.media_set_id
       AND mf.mirror = 0                     -- primary media only, ignore MIRROR TO copies
WHERE   bs.is_damaged = 0
AND     mf.device_type IN (2, 102)           -- disk, and logical disk device
AND     bs.backup_finish_date >= DATEADD(day, -@Days, GETDATE())
AND     (NOT EXISTS (SELECT 1 FROM @Wanted)
         OR bs.database_name IN (SELECT DatabaseName FROM @Wanted))
ORDER BY bs.database_name, bs.backup_finish_date, bs.backup_set_id, mf.family_sequence_number;
