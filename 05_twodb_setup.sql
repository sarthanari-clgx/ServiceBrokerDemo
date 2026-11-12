/*
  05_twodb_setup.sql - Two databases on the same instance talking through Service Broker.

    SB_Sender   : owns the initiator service and queue (the "client")
    SB_Receiver : owns the target service, queue and the business tables (the "server")

  Each database has its OWN copy of the message types and contract; they only have to
  match by name. Nothing is shared except the messages that travel between the services.
  Service names here use //TwoDb/ so they do not clash with the single-database demo.

  Re-runnable: both databases are dropped and recreated.
*/
USE master;
GO
DROP DATABASE IF EXISTS SB_Sender;
DROP DATABASE IF EXISTS SB_Receiver;
GO
CREATE DATABASE SB_Sender;
CREATE DATABASE SB_Receiver;
GO
-- Each database needs the broker switch on. A DB created locally already has it on; being explicit.
ALTER DATABASE SB_Sender   SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE SB_Receiver SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
GO

/* ------------------------------- SB_Receiver ------------------------------- */
USE SB_Receiver;
GO
CREATE MESSAGE TYPE [//TwoDb/OrderRequest] VALIDATION = WELL_FORMED_XML;
CREATE MESSAGE TYPE [//TwoDb/OrderReply]   VALIDATION = WELL_FORMED_XML;
CREATE CONTRACT [//TwoDb/OrderContract]
(
    [//TwoDb/OrderRequest] SENT BY INITIATOR,
    [//TwoDb/OrderReply]   SENT BY TARGET
);
CREATE QUEUE dbo.ReceiverQueue;
CREATE SERVICE [//TwoDb/ReceiverService] ON QUEUE dbo.ReceiverQueue ([//TwoDb/OrderContract]);
GO
-- Crossing a database boundary is a security boundary too. With ENCRYPTION = OFF the dialog is
-- "anonymous": it arrives as guest/public, so both must be allowed. Without these two grants the
-- message sits in the sender's sys.transmission_queue with error 916.
GRANT CONNECT TO guest;
GRANT SEND ON SERVICE::[//TwoDb/ReceiverService] TO [public];
GO
CREATE TABLE dbo.ProcessedOrders
(
    Id          INT IDENTITY(1,1) PRIMARY KEY,
    OrderId     INT       NOT NULL,
    ProcessedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
CREATE OR ALTER PROCEDURE dbo.ProcessReceiverQueue
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @handle UNIQUEIDENTIFIER, @type SYSNAME, @body XML, @orderId INT, @reply NVARCHAR(200);

    WHILE 1 = 1
    BEGIN
        SELECT @handle = NULL;
        BEGIN TRANSACTION;

        WAITFOR (
            RECEIVE TOP (1) @handle = conversation_handle, @type = message_type_name, @body = CAST(message_body AS XML)
            FROM dbo.ReceiverQueue
        ), TIMEOUT 5000;

        IF @handle IS NULL BEGIN COMMIT; BREAK; END

        IF @type = N'//TwoDb/OrderRequest'
        BEGIN
            SET @orderId = @body.value('(/Order/Id)[1]', 'INT');
            INSERT dbo.ProcessedOrders (OrderId) VALUES (@orderId);

            SET @reply = N'<Reply><Id>' + CAST(@orderId AS NVARCHAR(20)) + N'</Id><Status>Processed</Status></Reply>';
            SEND ON CONVERSATION @handle MESSAGE TYPE [//TwoDb/OrderReply] (@reply);
            END CONVERSATION @handle;
        END
        ELSE IF @type IN (N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog',
                          N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
            END CONVERSATION @handle;

        COMMIT;
    END
END;
GO
ALTER QUEUE dbo.ReceiverQueue
    WITH ACTIVATION (STATUS = ON, PROCEDURE_NAME = dbo.ProcessReceiverQueue, MAX_QUEUE_READERS = 2, EXECUTE AS OWNER);
GO

/* -------------------------------- SB_Sender -------------------------------- */
USE SB_Sender;
GO
CREATE MESSAGE TYPE [//TwoDb/OrderRequest] VALIDATION = WELL_FORMED_XML;
CREATE MESSAGE TYPE [//TwoDb/OrderReply]   VALIDATION = WELL_FORMED_XML;
CREATE CONTRACT [//TwoDb/OrderContract]
(
    [//TwoDb/OrderRequest] SENT BY INITIATOR,
    [//TwoDb/OrderReply]   SENT BY TARGET
);
CREATE QUEUE dbo.SenderQueue;
CREATE SERVICE [//TwoDb/SenderService] ON QUEUE dbo.SenderQueue;   -- initiator side: no contract needed
GO
CREATE TABLE dbo.OutgoingOrders
(
    Id       INT IDENTITY(1,1) PRIMARY KEY,
    OrderId  INT       NOT NULL,
    SentAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE TABLE dbo.Replies
(
    Id         INT IDENTITY(1,1) PRIMARY KEY,
    OrderId    INT          NOT NULL,
    Status     NVARCHAR(50) NOT NULL,
    ReceivedAt DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
-- The business row and the message are committed together or not at all.
CREATE OR ALTER PROCEDURE dbo.SendOrder @OrderId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @handle UNIQUEIDENTIFIER,
            @msg NVARCHAR(200) = N'<Order><Id>' + CAST(@OrderId AS NVARCHAR(20)) + N'</Id></Order>';

    BEGIN TRANSACTION;
    INSERT dbo.OutgoingOrders (OrderId) VALUES (@OrderId);

    BEGIN DIALOG CONVERSATION @handle
        FROM SERVICE [//TwoDb/SenderService]
        TO SERVICE   '//TwoDb/ReceiverService'
        ON CONTRACT  [//TwoDb/OrderContract]
        WITH ENCRYPTION = OFF;

    SEND ON CONVERSATION @handle MESSAGE TYPE [//TwoDb/OrderRequest] (@msg);
    COMMIT;
END;
GO
CREATE OR ALTER PROCEDURE dbo.ProcessSenderQueue
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @handle UNIQUEIDENTIFIER, @type SYSNAME, @body XML;

    WHILE 1 = 1
    BEGIN
        SELECT @handle = NULL;
        BEGIN TRANSACTION;

        WAITFOR (
            RECEIVE TOP (1) @handle = conversation_handle, @type = message_type_name, @body = CAST(message_body AS XML)
            FROM dbo.SenderQueue
        ), TIMEOUT 5000;

        IF @handle IS NULL BEGIN COMMIT; BREAK; END

        IF @type = N'//TwoDb/OrderReply'
            INSERT dbo.Replies (OrderId, Status)
            VALUES (@body.value('(/Reply/Id)[1]', 'INT'), @body.value('(/Reply/Status)[1]', 'NVARCHAR(50)'));
        ELSE IF @type IN (N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog',
                          N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
            END CONVERSATION @handle;

        COMMIT;
    END
END;
GO
ALTER QUEUE dbo.SenderQueue
    WITH ACTIVATION (STATUS = ON, PROCEDURE_NAME = dbo.ProcessSenderQueue, MAX_QUEUE_READERS = 1, EXECUTE AS OWNER);
GO

PRINT 'Two-database setup complete.';
