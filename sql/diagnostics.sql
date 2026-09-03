USE [VistaERP];
GO

SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DatabaseName, databases.is_cdc_enabled,
       tracking.is_auto_cleanup_on AS ChangeTrackingAutoCleanup,
       tracking.retention_period AS ChangeTrackingRetentionPeriod,
       tracking.retention_period_units_desc AS ChangeTrackingRetentionUnits,
       CHANGE_TRACKING_CURRENT_VERSION() AS ChangeTrackingVersion
FROM sys.databases AS databases
LEFT JOIN sys.change_tracking_databases AS tracking ON tracking.database_id = databases.database_id
WHERE databases.database_id = DB_ID();

SELECT tables.name AS TableName, tables.is_tracked_by_cdc,
       CONVERT(bit, CASE WHEN change_tables.object_id IS NULL THEN 0 ELSE 1 END) AS is_tracked_by_change_tracking,
       change_tables.begin_version AS ChangeTrackingBeginVersion,
       CHANGE_TRACKING_MIN_VALID_VERSION(tables.object_id) AS ChangeTrackingMinValidVersion
FROM sys.tables AS tables
LEFT JOIN sys.change_tracking_tables AS change_tables ON change_tables.object_id = tables.object_id
WHERE tables.schema_id = SCHEMA_ID(N'dbo')
  AND tables.name IN ('Projects', 'Equipment', 'WorkOrders', 'JobCosts', 'Invoices', 'DemoHeartbeat')
ORDER BY tables.name;

EXEC sys.sp_cdc_help_jobs;

SELECT TOP (10) session_id, start_time, end_time, duration, scan_phase, error_count,
       tran_count, command_count, last_commit_time, last_commit_cdc_time, latency
FROM sys.dm_cdc_log_scan_sessions
ORDER BY session_id DESC;

SELECT TOP (10) entry_time, error_number, error_severity, error_state, error_message
FROM sys.dm_cdc_errors
ORDER BY entry_time DESC;

SELECT HeartbeatId, SequenceNumber, BusinessMarker, EmittedUtc,
       DATEDIFF(second, EmittedUtc, SYSUTCDATETIME()) AS HeartbeatAgeSeconds
FROM dbo.DemoHeartbeat;

SELECT total_physical_memory_kb, available_physical_memory_kb, system_memory_state_desc
FROM sys.dm_os_sys_memory;

SELECT physical_memory_in_use_kb, process_physical_memory_low, process_virtual_memory_low
FROM sys.dm_os_process_memory;

SELECT DB_NAME(database_id) AS DatabaseName, total_log_size_in_bytes / 1048576.0 AS LogSizeMb,
       used_log_space_in_bytes / 1048576.0 AS UsedLogMb, used_log_space_in_percent AS UsedLogPercent
FROM sys.dm_db_log_space_usage;
GO