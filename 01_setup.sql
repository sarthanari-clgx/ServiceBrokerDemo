/*
  01_setup.sql - Create a demo database with Service Broker enabled and all broker objects.

  Service Broker building blocks (in dependency order):
    MESSAGE TYPE  -> names/validates a kind of message
    CONTRACT      -> says which message types each side (INITIATOR / TARGET) may send
    QUEUE         -> internal table where messages are stored (one per service)
    SERVICE       -> named endpoint bound to a queue and one or more contracts
*/
USE master;
GO

IF DB_ID('ServiceBrokerDemo') IS NULL
    CREATE DATABASE ServiceBrokerDemo;
GO

-- Requirement #1: broker must be enabled on the database (it is OFF by default for new DBs
-- restored/attached from other servers; a freshly created DB gets it ON, but be explicit).
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'ServiceBrokerDemo' AND is_broker_enabled = 0)
    ALTER DATABASE ServiceBrokerDemo SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
GO

USE ServiceBrokerDemo;
GO

-- Message types: the request carries an order id, the reply carries a status.
CREATE MESSAGE TYPE [//Demo/OrderRequest] VALIDATION = WELL_FORMED_XML;
CREATE MESSAGE TYPE [//Demo/OrderReply]   VALIDATION = WELL_FORMED_XML;
GO

-- Contract: the initiator sends requests, the target sends replies.
CREATE CONTRACT [//Demo/OrderContract]
(
    [//Demo/OrderRequest] SENT BY INITIATOR,
    [//Demo/OrderReply]   SENT BY TARGET
);
GO

-- Queues: one for each side of the conversation.
CREATE QUEUE dbo.OrderTargetQueue;
CREATE QUEUE dbo.OrderInitiatorQueue;
GO

-- Services: the target service accepts the contract; the initiator service only needs
-- a queue to receive replies and the EndDialog/Error messages.
CREATE SERVICE [//Demo/OrderTargetService]
    ON QUEUE dbo.OrderTargetQueue ([//Demo/OrderContract]);

CREATE SERVICE [//Demo/OrderInitiatorService]
    ON QUEUE dbo.OrderInitiatorQueue;
GO

-- Plain table so we can see the "business" result of processing a message.
CREATE TABLE dbo.ProcessedOrders
(
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    OrderId     INT          NOT NULL,
    ProcessedAt DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
    ProcessedBy NVARCHAR(50) NOT NULL
);
GO

PRINT 'Setup complete.';
