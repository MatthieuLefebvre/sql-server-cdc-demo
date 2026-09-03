USE [VistaERP];
GO

SET XACT_ABORT ON;

IF COL_LENGTH(N'dbo.WorkOrders', N'PriorityCode') IS NULL
BEGIN
    ALTER TABLE dbo.WorkOrders ADD PriorityCode varchar(20) NULL;
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM cdc.change_tables
    WHERE capture_instance = N'dbo_WorkOrders_v2'
)
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'WorkOrders',
        @capture_instance = N'dbo_WorkOrders_v2',
        @role_name = NULL,
        @supports_net_changes = 1;
END;
GO

UPDATE dbo.WorkOrders
SET PriorityCode = CASE
        WHEN PriorityCode = 'SAFETY_CRITICAL' THEN 'STANDARD'
        ELSE 'SAFETY_CRITICAL'
    END,
    LastModifiedUtc = SYSUTCDATETIME()
WHERE WorkOrderId = 7001;
GO

SELECT
    WorkOrderId,
    PriorityCode,
    LastModifiedUtc,
    (SELECT COUNT(*) FROM cdc.change_tables WHERE source_object_id = OBJECT_ID(N'dbo.WorkOrders')) AS CaptureInstanceCount
FROM dbo.WorkOrders
WHERE WorkOrderId = 7001;
GO