:setvar TenantId "CONTOSO_NORTH"
:setvar SourceInstance "NORTH"
:setvar DataPath "F:\SQLData"

USE [master];
GO

IF DB_ID(N'VistaERP') IS NULL
BEGIN
    CREATE DATABASE [VistaERP]
        ON PRIMARY (NAME = N'VistaERP', FILENAME = N'$(DataPath)\VistaERP.mdf')
        LOG ON (NAME = N'VistaERP_log', FILENAME = N'$(DataPath)\VistaERP_log.ldf');
END;
GO

ALTER DATABASE [VistaERP] SET RECOVERY FULL;
ALTER DATABASE [VistaERP] SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE [VistaERP] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID(N'VistaERP'))
BEGIN
    ALTER DATABASE [VistaERP] SET CHANGE_TRACKING = ON
        (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
END;
GO

USE [VistaERP];
GO

ALTER AUTHORIZATION ON DATABASE::[VistaERP] TO [sa];
GO

IF OBJECT_ID(N'dbo.Projects', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Projects
    (
        ProjectId int NOT NULL CONSTRAINT PK_Projects PRIMARY KEY,
        ProjectCode varchar(30) NOT NULL,
        ProjectName nvarchar(120) NOT NULL,
        RegionCode varchar(30) NOT NULL,
        ProjectStatus varchar(20) NOT NULL,
        Budget decimal(19, 4) NOT NULL,
        LastModifiedUtc datetime2(3) NOT NULL CONSTRAINT DF_Projects_LastModifiedUtc DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.Equipment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Equipment
    (
        EquipmentId int NOT NULL CONSTRAINT PK_Equipment PRIMARY KEY,
        AssetTag varchar(40) NOT NULL,
        EquipmentName nvarchar(120) NOT NULL,
        MeterHours decimal(12, 2) NOT NULL,
        EquipmentStatus varchar(20) NOT NULL,
        LastModifiedUtc datetime2(3) NOT NULL CONSTRAINT DF_Equipment_LastModifiedUtc DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.WorkOrders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WorkOrders
    (
        WorkOrderId int NOT NULL CONSTRAINT PK_WorkOrders PRIMARY KEY,
        ProjectId int NOT NULL,
        EquipmentId int NOT NULL,
        Summary nvarchar(200) NOT NULL,
        WorkOrderStatus varchar(20) NOT NULL,
        ScheduledDate date NOT NULL,
        LastModifiedUtc datetime2(3) NOT NULL CONSTRAINT DF_WorkOrders_LastModifiedUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_WorkOrders_Projects FOREIGN KEY (ProjectId) REFERENCES dbo.Projects(ProjectId),
        CONSTRAINT FK_WorkOrders_Equipment FOREIGN KEY (EquipmentId) REFERENCES dbo.Equipment(EquipmentId)
    );
END;

IF OBJECT_ID(N'dbo.JobCosts', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.JobCosts
    (
        JobCostId bigint NOT NULL CONSTRAINT PK_JobCosts PRIMARY KEY,
        ProjectId int NOT NULL,
        CostType varchar(30) NOT NULL,
        Amount decimal(19, 4) NOT NULL,
        CostDescription nvarchar(200) NOT NULL,
        PostedUtc datetime2(3) NOT NULL,
        CONSTRAINT FK_JobCosts_Projects FOREIGN KEY (ProjectId) REFERENCES dbo.Projects(ProjectId)
    );
END;

IF OBJECT_ID(N'dbo.Invoices', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Invoices
    (
        InvoiceId bigint NOT NULL CONSTRAINT PK_Invoices PRIMARY KEY,
        ProjectId int NOT NULL,
        InvoiceNumber varchar(40) NOT NULL,
        InvoiceAmount decimal(19, 4) NOT NULL,
        InvoiceStatus varchar(20) NOT NULL,
        IssuedDate date NOT NULL,
        LastModifiedUtc datetime2(3) NOT NULL CONSTRAINT DF_Invoices_LastModifiedUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Invoices_Projects FOREIGN KEY (ProjectId) REFERENCES dbo.Projects(ProjectId)
    );
END;

IF OBJECT_ID(N'dbo.DemoHeartbeat', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DemoHeartbeat
    (
        HeartbeatId int NOT NULL CONSTRAINT PK_DemoHeartbeat PRIMARY KEY,
        SequenceNumber bigint NOT NULL,
        BusinessMarker varchar(40) NOT NULL,
        EmittedUtc datetime2(3) NOT NULL
    );
END;
GO

MERGE dbo.Projects AS target
USING (VALUES
    (1001, 'P-1001', N'$(TenantId) Transit Hub', '$(SourceInstance)', 'ACTIVE', CONVERT(decimal(19, 4), 2500000.00)),
    (1002, 'P-1002', N'$(TenantId) Civic Works', '$(SourceInstance)', 'ACTIVE', CONVERT(decimal(19, 4), 1750000.00))
) AS source (ProjectId, ProjectCode, ProjectName, RegionCode, ProjectStatus, Budget)
ON target.ProjectId = source.ProjectId
WHEN MATCHED THEN UPDATE SET
    ProjectCode = source.ProjectCode, ProjectName = source.ProjectName, RegionCode = source.RegionCode,
    ProjectStatus = source.ProjectStatus, Budget = source.Budget
WHEN NOT MATCHED THEN INSERT (ProjectId, ProjectCode, ProjectName, RegionCode, ProjectStatus, Budget)
    VALUES (source.ProjectId, source.ProjectCode, source.ProjectName, source.RegionCode, source.ProjectStatus, source.Budget);

MERGE dbo.Equipment AS target
USING (VALUES
    (501, '$(SourceInstance)-EX-501', N'$(TenantId) Excavator', CONVERT(decimal(12, 2), 1200.00), 'AVAILABLE'),
    (502, '$(SourceInstance)-CR-502', N'$(TenantId) Crane', CONVERT(decimal(12, 2), 800.00), 'IN_USE')
) AS source (EquipmentId, AssetTag, EquipmentName, MeterHours, EquipmentStatus)
ON target.EquipmentId = source.EquipmentId
WHEN MATCHED THEN UPDATE SET
    AssetTag = source.AssetTag, EquipmentName = source.EquipmentName,
    MeterHours = source.MeterHours, EquipmentStatus = source.EquipmentStatus
WHEN NOT MATCHED THEN INSERT (EquipmentId, AssetTag, EquipmentName, MeterHours, EquipmentStatus)
    VALUES (source.EquipmentId, source.AssetTag, source.EquipmentName, source.MeterHours, source.EquipmentStatus);

MERGE dbo.WorkOrders AS target
USING (VALUES
    (7001, 1001, 501, N'$(TenantId) hydraulic inspection', 'OPEN', CONVERT(date, '2026-04-15')),
    (7002, 1002, 502, N'$(TenantId) lift plan review', 'SCHEDULED', CONVERT(date, '2026-04-16'))
) AS source (WorkOrderId, ProjectId, EquipmentId, Summary, WorkOrderStatus, ScheduledDate)
ON target.WorkOrderId = source.WorkOrderId
WHEN MATCHED THEN UPDATE SET
    ProjectId = source.ProjectId, EquipmentId = source.EquipmentId, Summary = source.Summary,
    WorkOrderStatus = source.WorkOrderStatus, ScheduledDate = source.ScheduledDate
WHEN NOT MATCHED THEN INSERT (WorkOrderId, ProjectId, EquipmentId, Summary, WorkOrderStatus, ScheduledDate)
    VALUES (source.WorkOrderId, source.ProjectId, source.EquipmentId, source.Summary, source.WorkOrderStatus, source.ScheduledDate);

MERGE dbo.JobCosts AS target
USING (VALUES
    (CONVERT(bigint, 9001), 1001, 'LABOR', CONVERT(decimal(19, 4), 12500.00), N'$(TenantId) initial labor'),
    (CONVERT(bigint, 9002), 1002, 'MATERIAL', CONVERT(decimal(19, 4), 8750.00), N'$(TenantId) initial materials')
) AS source (JobCostId, ProjectId, CostType, Amount, CostDescription)
ON target.JobCostId = source.JobCostId
WHEN MATCHED THEN UPDATE SET
    ProjectId = source.ProjectId, CostType = source.CostType, Amount = source.Amount,
    CostDescription = source.CostDescription
WHEN NOT MATCHED THEN INSERT (JobCostId, ProjectId, CostType, Amount, CostDescription, PostedUtc)
    VALUES (source.JobCostId, source.ProjectId, source.CostType, source.Amount, source.CostDescription, SYSUTCDATETIME());

MERGE dbo.Invoices AS target
USING (VALUES
    (CONVERT(bigint, 8001), 1001, '$(SourceInstance)-INV-8001', CONVERT(decimal(19, 4), 42000.00), 'OPEN'),
    (CONVERT(bigint, 8002), 1002, '$(SourceInstance)-INV-8002', CONVERT(decimal(19, 4), 31500.00), 'PAID')
) AS source (InvoiceId, ProjectId, InvoiceNumber, InvoiceAmount, InvoiceStatus)
ON target.InvoiceId = source.InvoiceId
WHEN MATCHED THEN UPDATE SET
    ProjectId = source.ProjectId, InvoiceNumber = source.InvoiceNumber,
    InvoiceAmount = source.InvoiceAmount, InvoiceStatus = source.InvoiceStatus
WHEN NOT MATCHED THEN INSERT (InvoiceId, ProjectId, InvoiceNumber, InvoiceAmount, InvoiceStatus, IssuedDate)
    VALUES (source.InvoiceId, source.ProjectId, source.InvoiceNumber, source.InvoiceAmount, source.InvoiceStatus, CONVERT(date, SYSUTCDATETIME()));

MERGE dbo.DemoHeartbeat AS target
USING (VALUES (1, CONVERT(bigint, 0), '$(TenantId)', SYSUTCDATETIME()))
    AS source (HeartbeatId, SequenceNumber, BusinessMarker, EmittedUtc)
ON target.HeartbeatId = source.HeartbeatId
WHEN MATCHED THEN UPDATE SET BusinessMarker = source.BusinessMarker
WHEN NOT MATCHED THEN INSERT (HeartbeatId, SequenceNumber, BusinessMarker, EmittedUtc)
    VALUES (source.HeartbeatId, source.SequenceNumber, source.BusinessMarker, source.EmittedUtc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_cdc_enabled = 1)
BEGIN
    EXEC sys.sp_cdc_enable_db;
END;
GO

DECLARE @TrackedTables table (SchemaName sysname NOT NULL, TableName sysname NOT NULL);
INSERT @TrackedTables (SchemaName, TableName)
VALUES ('dbo', 'Projects'), ('dbo', 'Equipment'), ('dbo', 'WorkOrders'),
       ('dbo', 'JobCosts'), ('dbo', 'Invoices'), ('dbo', 'DemoHeartbeat');

DECLARE @SchemaName sysname;
DECLARE @TableName sysname;
DECLARE tracked_tables CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaName, TableName FROM @TrackedTables;
OPEN tracked_tables;
FETCH NEXT FROM tracked_tables INTO @SchemaName, @TableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.tables AS tables
        WHERE tables.object_id = OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName))
          AND tables.is_tracked_by_cdc = 1
    )
    BEGIN
        EXEC sys.sp_cdc_enable_table
            @source_schema = @SchemaName,
            @source_name = @TableName,
            @role_name = NULL,
            @supports_net_changes = 1;
    END;

    IF NOT EXISTS
    (
        SELECT 1 FROM sys.change_tracking_tables
        WHERE object_id = OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName))
    )
    BEGIN
        DECLARE @EnableChangeTrackingSql nvarchar(max) = N'ALTER TABLE '
            + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName)
            + N' ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);';
        EXEC sys.sp_executesql @EnableChangeTrackingSql;
    END;

    FETCH NEXT FROM tracked_tables INTO @SchemaName, @TableName;
END;
CLOSE tracked_tables;
DEALLOCATE tracked_tables;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'fabriccdc')
BEGIN
    CREATE USER [fabriccdc] FOR LOGIN [fabriccdc];
END;
GRANT CONNECT TO [fabriccdc];
GRANT SELECT ON SCHEMA::dbo TO [fabriccdc];
GRANT SELECT ON SCHEMA::cdc TO [fabriccdc];
GRANT VIEW DATABASE STATE TO [fabriccdc];
GO

USE [master];
GO
GRANT VIEW SERVER STATE TO [fabriccdc];
GO