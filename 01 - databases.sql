SET NOCOUNT ON
SET ARITHABORT ON
SET NUMERIC_ROUNDABORT OFF
SET STATISTICS IO, TIME OFF

IF OBJECT_ID('tempdb.dbo.#database_size') IS NOT NULL
    DROP TABLE #database_size

CREATE TABLE #database_size (
      [db_id]          INT PRIMARY KEY
    , [data_size]      DECIMAL(32,2)
    , [data_used_size] DECIMAL(32,2)
    , [log_size]       DECIMAL(32,2)
    , [log_used_size]  DECIMAL(32,2)
)

IF OBJECT_ID('tempdb.dbo.#dbcc') IS NOT NULL
    DROP TABLE #dbcc

CREATE TABLE #dbcc (
      [key]   VARCHAR(1000)
    , [value] VARCHAR(1000)
    , [db_id] INT DEFAULT DB_ID()
)

DECLARE @sql NVARCHAR(MAX)

SELECT @sql = STUFF((
    SELECT '
USE ' + QUOTENAME([name]) + '
INSERT INTO #database_size
SELECT DB_ID()
     , SUM(CASE WHEN [type] = 0 THEN [size] END)
     , SUM(CASE WHEN [type] = 0 THEN [used_size] END)
     , SUM(CASE WHEN [type] = 1 THEN [size] END)
     , SUM(CASE WHEN [type] = 1 THEN [used_size] END)
FROM (
    SELECT [type]
         , [size] = SUM(CAST([size] AS BIGINT)) * 8. / 1024
         , [used_size] = SUM(CAST(FILEPROPERTY([name], ''SpaceUsed'') AS BIGINT) * 8. / 1024)
    FROM sys.database_files WITH(NOLOCK)
    GROUP BY [type]
) t;

INSERT INTO #dbcc ([key], [value])
EXEC(''DBCC OPENTRAN WITH TABLERESULTS'');'
    FROM sys.databases WITH(NOLOCK)
    WHERE [state] = 0
        AND ISNULL(HAS_DBACCESS([name]), 0) = 1
    FOR XML PATH(''), TYPE).value('(./text())[1]', 'NVARCHAR(MAX)'), 1, 2, '')

EXEC sys.sp_executesql @sql

IF OBJECT_ID('tempdb.dbo.#backup_size') IS NOT NULL
    DROP TABLE #backup_size

CREATE TABLE #backup_size (
      [db_name]        SYSNAME PRIMARY KEY
    , [full_last_date] DATETIME2(0)
    , [full_size]      DECIMAL(32,2)
    , [diff_last_date] DATETIME2(0)
    , [diff_size]      DECIMAL(32,2)
    , [log_last_date]  DATETIME2(0)
    , [log_size]       DECIMAL(32,2)
)

INSERT INTO #backup_size
SELECT [database_name]
     , MAX(CASE WHEN [type] = 'D' THEN [backup_finish_date] END)
     , MAX(CASE WHEN [type] = 'D' THEN [backup_size] END)
     , MAX(CASE WHEN [type] = 'I' THEN [backup_finish_date] END)
     , MAX(CASE WHEN [type] = 'I' THEN [backup_size] END)
     , MAX(CASE WHEN [type] = 'L' THEN [backup_finish_date] END)
     , MAX(CASE WHEN [type] = 'L' THEN [backup_size] END)
FROM (
    SELECT [database_name]
         , [type]
         , [backup_finish_date]
         , [backup_size] =
                CAST(CASE WHEN [backup_size] = [compressed_backup_size]
                        THEN [backup_size]
                        ELSE [compressed_backup_size]
                END / 1048576. AS DECIMAL(32,2))
         , RN = ROW_NUMBER() OVER (PARTITION BY [database_name], [type] ORDER BY [backup_finish_date] DESC)
    FROM msdb.dbo.backupset WITH(NOLOCK)
    WHERE [type] IN ('D', 'L', 'I')
        AND [is_copy_only] = 0
) t
WHERE RN = 1
GROUP BY [database_name]

SELECT [db_id]          = d.[database_id]
     , [db_name]        = d.[name]
     , [state]          = d.[state_desc]
     , [recovery_model] = d.[recovery_model_desc]
     , [log_reuse]      = d.[log_reuse_wait_desc]
     , [spid]           = t.[value]
     , [total_mb]       = s.[data_size] + s.[log_size]
     , [data_mb]        = s.[data_size]
     , [data_used_mb]   = s.[data_used_size]
     , [data_free_mb]   = s.[data_size] - s.[data_used_size]
     , [log_mb]         = s.[log_size]
     , [log_used_mb]    = s.[log_used_size]
     , [log_free_mb]    = s.[log_size] - s.[log_used_size]
     , [readonly]       = d.[is_read_only]
     , [access]         = ISNULL(HAS_DBACCESS(d.[name]), 0)
     , [durability]     = d.[delayed_durability_desc]
     , [user_access]    = d.[user_access_desc]
     , [full_last_date] = b.[full_last_date]
     , [full_mb]        = b.[full_size]
     , [diff_last_date] = b.[diff_last_date]
     , [diff_mb]        = b.[diff_size]
     , [log_last_date]  = b.[log_last_date]
     , [log_mb]         = b.[log_size]
FROM sys.databases d WITH(NOLOCK)
LEFT JOIN #database_size s ON d.[database_id] = s.[db_id]
LEFT JOIN #backup_size b ON d.[name] = b.[db_name]
LEFT JOIN #dbcc t ON d.[database_id] = t.[db_id] AND t.[key] = 'OLDACT_SPID'
ORDER BY [total_mb] DESC