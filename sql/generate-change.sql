USE [VistaERP];
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @NextSequence bigint = (SELECT SequenceNumber + 1 FROM dbo.DemoHeartbeat WITH (UPDLOCK, HOLDLOCK) WHERE HeartbeatId = 1);
DECLARE @Marker varchar(40) = (SELECT BusinessMarker FROM dbo.DemoHeartbeat WHERE HeartbeatId = 1);

UPDATE dbo.DemoHeartbeat
SET SequenceNumber = @NextSequence, EmittedUtc = SYSUTCDATETIME()
WHERE HeartbeatId = 1;

UPDATE dbo.Projects
SET Budget = Budget + 1000.00,
    ProjectStatus = CASE WHEN ProjectStatus = 'ACTIVE' THEN 'REVIEW' ELSE 'ACTIVE' END,
    LastModifiedUtc = SYSUTCDATETIME()
WHERE ProjectId = 1001;

UPDATE dbo.Equipment
SET MeterHours = MeterHours + 0.25,
    LastModifiedUtc = SYSUTCDATETIME()
WHERE EquipmentId = 501;

UPDATE dbo.WorkOrders
SET WorkOrderStatus = CASE WHEN WorkOrderStatus = 'OPEN' THEN 'IN_PROGRESS' ELSE 'OPEN' END,
    LastModifiedUtc = SYSUTCDATETIME()
WHERE WorkOrderId = 7001;

INSERT dbo.JobCosts (JobCostId, ProjectId, CostType, Amount, CostDescription, PostedUtc)
VALUES (900000 + @NextSequence, 1001, 'DEMO', 100.00 + @NextSequence,
        CONCAT(@Marker, ' deterministic change ', @NextSequence), SYSUTCDATETIME());

INSERT dbo.Invoices (InvoiceId, ProjectId, InvoiceNumber, InvoiceAmount, InvoiceStatus, IssuedDate)
VALUES (800000 + @NextSequence, 1001, CONCAT('DEMO-INV-', @NextSequence),
        500.00 + @NextSequence, 'OPEN', CONVERT(date, SYSUTCDATETIME()));

COMMIT TRANSACTION;

SELECT @Marker AS BusinessMarker, @NextSequence AS SequenceNumber, SYSUTCDATETIME() AS CompletedUtc;
GO