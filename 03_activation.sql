/*
  03_activation.sql - Internal activation: SQL Server runs a stored procedure automatically
  whenever messages arrive on the target queue. No polling, no external app needed.
*/
USE ServiceBrokerDemo;
GO

CREATE OR ALTER PROCEDURE dbo.ProcessOrderQueue
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @handle UNIQUEIDENTIFIER, @type SYSNAME, @body XML, @orderId INT, @reply NVARCHAR(200);

    WHILE 1 = 1
    BEGIN
        SELECT @handle = NULL;

        BEGIN TRANSACTION;

        WAITFOR (
            RECEIVE TOP (1)
                @handle = conversation_handle,
                @type   = message_type_name,
                @body   = CAST(message_body AS XML)
            FROM dbo.OrderTargetQueue
        ), TIMEOUT 5000;

        IF @handle IS NULL
        BEGIN
            COMMIT;
            BREAK;
        END

        IF @type = N'//Demo/OrderRequest'
        BEGIN
            SET @orderId = @body.value('(/Order/Id)[1]', 'INT');
            INSERT dbo.ProcessedOrders (OrderId, ProcessedBy) VALUES (@orderId, N'activation');

            SET @reply = N'<Reply><Id>' + CAST(@orderId AS NVARCHAR(20)) + N'</Id><Status>Processed</Status></Reply>';
            SEND ON CONVERSATION @handle MESSAGE TYPE [//Demo/OrderReply] (@reply);
            END CONVERSATION @handle;
        END
        ELSE IF @type IN (N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog',
                          N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
            END CONVERSATION @handle;

        COMMIT;
    END
END;
GO

-- Attach the procedure to the queue. Activation starts up to MAX_QUEUE_READERS copies on demand.
ALTER QUEUE dbo.OrderTargetQueue
    WITH ACTIVATION
    (
        STATUS = ON,
        PROCEDURE_NAME = dbo.ProcessOrderQueue,
        MAX_QUEUE_READERS = 2,
        EXECUTE AS OWNER
    );
GO

-- The initiator queue also needs draining (reply + EndDialog); do it with a tiny procedure.
CREATE OR ALTER PROCEDURE dbo.ProcessInitiatorQueue
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
            FROM dbo.OrderInitiatorQueue
        ), TIMEOUT 5000;

        IF @handle IS NULL BEGIN COMMIT; BREAK; END

        IF @type = N'//Demo/OrderReply'
            PRINT CONCAT('Reply received: ', CAST(@body AS NVARCHAR(MAX)));
        ELSE IF @type IN (N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog',
                          N'http://schemas.microsoft.com/SQL/ServiceBroker/Error')
            END CONVERSATION @handle;
        COMMIT;
    END
END;
GO

ALTER QUEUE dbo.OrderInitiatorQueue
    WITH ACTIVATION
    (
        STATUS = ON,
        PROCEDURE_NAME = dbo.ProcessInitiatorQueue,
        MAX_QUEUE_READERS = 1,
        EXECUTE AS OWNER
    );
GO

-- Send 5 orders in a single transaction, each on its own conversation.
DECLARE @handle UNIQUEIDENTIFIER, @i INT = 1, @msg NVARCHAR(100);

BEGIN TRANSACTION;
WHILE @i <= 5
BEGIN
    BEGIN DIALOG CONVERSATION @handle
        FROM SERVICE [//Demo/OrderInitiatorService]
        TO SERVICE   '//Demo/OrderTargetService'
        ON CONTRACT  [//Demo/OrderContract]
        WITH ENCRYPTION = OFF;

    SET @msg = N'<Order><Id>' + CAST(2000 + @i AS NVARCHAR(10)) + N'</Id></Order>';
    SEND ON CONVERSATION @handle MESSAGE TYPE [//Demo/OrderRequest] (@msg);
    SET @i += 1;
END
COMMIT;

-- Activation runs in the background; give it a moment, then look at the result.
WAITFOR DELAY '00:00:03';

SELECT * FROM dbo.ProcessedOrders ORDER BY Id;
SELECT name, is_activation_enabled, activation_procedure FROM sys.service_queues WHERE name LIKE 'Order%';
GO
