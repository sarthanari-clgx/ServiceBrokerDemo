/*
  06_twodb_run.sql - Send orders from SB_Sender; watch them get processed in SB_Receiver.

  No endpoint is involved: both databases live in the same instance, so the broker delivers
  the messages internally using the built-in route "AutoCreatedLocal" (ADDRESS = LOCAL).
*/
SET NOCOUNT ON;

EXEC SB_Sender.dbo.SendOrder 5001;
EXEC SB_Sender.dbo.SendOrder 5002;
EXEC SB_Sender.dbo.SendOrder 5003;

WAITFOR DELAY '00:00:03';   -- activation + delivery are asynchronous

SELECT 'SB_Sender.OutgoingOrders'   AS TableName, OrderId, SentAt        FROM SB_Sender.dbo.OutgoingOrders   ORDER BY Id;
SELECT 'SB_Receiver.ProcessedOrders' AS TableName, OrderId, ProcessedAt  FROM SB_Receiver.dbo.ProcessedOrders ORDER BY Id;
SELECT 'SB_Sender.Replies'          AS TableName, OrderId, Status, ReceivedAt FROM SB_Sender.dbo.Replies     ORDER BY Id;

-- How did the sender find the receiver? Look at its routing table.
SELECT 'SB_Sender routes' AS Info, name, remote_service_name, address FROM SB_Sender.sys.routes;

-- Messages stuck on the way would show here (should be empty).
SELECT 'SB_Sender transmission queue' AS Info, COUNT(*) AS PendingMessages FROM SB_Sender.sys.transmission_queue;
