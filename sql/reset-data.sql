USE [VistaERP];
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

DELETE FROM dbo.Invoices WHERE InvoiceId >= 800001;
DELETE FROM dbo.JobCosts WHERE JobCostId >= 900001;

UPDATE dbo.Projects SET Budget = CASE ProjectId WHEN 1001 THEN 2500000.00 ELSE 1750000.00 END,
    ProjectStatus = 'ACTIVE', LastModifiedUtc = SYSUTCDATETIME();
UPDATE dbo.Equipment SET MeterHours = CASE EquipmentId WHEN 501 THEN 1200.00 ELSE 800.00 END,
    EquipmentStatus = CASE EquipmentId WHEN 501 THEN 'AVAILABLE' ELSE 'IN_USE' END,
    LastModifiedUtc = SYSUTCDATETIME();
UPDATE dbo.WorkOrders SET WorkOrderStatus = CASE WorkOrderId WHEN 7001 THEN 'OPEN' ELSE 'SCHEDULED' END,
    LastModifiedUtc = SYSUTCDATETIME();
UPDATE dbo.DemoHeartbeat SET SequenceNumber = 0, EmittedUtc = SYSUTCDATETIME() WHERE HeartbeatId = 1;

COMMIT TRANSACTION;
GO