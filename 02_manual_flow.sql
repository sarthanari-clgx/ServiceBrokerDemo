/*
  02_manual_flow.sql - One full request/reply round trip, done by hand step by step.
  Run the numbered steps one at a time (or the whole file) and read the result sets.
*/
USE ServiceBrokerDemo;
GO

-- STEP 1: Initiator opens a conversation (a "dialog") and sends a request.
DECLARE @handle UNIQUEIDENTIFIER;

BEGIN TRANSACTION;

BEGIN DIALOG CONVERSATION @handle
    FROM SERVICE [//Demo/OrderInitiatorService]
    TO SERVICE   '//Demo/OrderTargetService'
    ON CONTRACT  [//Demo/OrderContract]
    WITH ENCRYPTION = OFF;

SEND ON CONVERSATION @handle
    MESSAGE TYPE [//Demo/OrderRequest] (N'<Order><Id>1001</Id></Order>');

COMMIT;
GO

-- STEP 2: The message is now sitting in the target queue (delivery is asynchronous).
SELECT 'Target queue' AS QueueName, message_type_name, CAST(message_body AS XML) AS body
FROM dbo.OrderTargetQueue;
GO

-- STEP 3: Target receives the request, does the work, replies, and ends its side.
DECLARE @handle UNIQUEIDENTIFIER, @type SYSNAME, @body XML, @orderId INT;

BEGIN TRANSACTION;

WAITFOR (
    RECEIVE TOP (1)
        @handle = conversation_handle,
        @type   = message_type_name,
        @body   = CAST(message_body AS XML)
    FROM dbo.OrderTargetQueue
), TIMEOUT 2000;

IF @type = N'//Demo/OrderRequest'
BEGIN
    SET @orderId = @body.value('(/Order/Id)[1]', 'INT');

    INSERT dbo.ProcessedOrders (OrderId, ProcessedBy) VALUES (@orderId, N'manual');

    DECLARE @reply NVARCHAR(200) =
        N'<Reply><Id>' + CAST(@orderId AS NVARCHAR(20)) + N'</Id><Status>Processed</Status></Reply>';

    SEND ON CONVERSATION @handle MESSAGE TYPE [//Demo/OrderReply] (@reply);
    END CONVERSATION @handle;   -- target is done; sends an EndDialog message to the initiator
END

COMMIT;
GO

-- STEP 4: Initiator receives the reply and then the EndDialog message.
-- Both messages arrive on the same conversation; loop until the queue is empty.
DECLARE @handle UNIQUEIDENTIFIER, @type SYSNAME, @body XML;

WHILE 1 = 1
BEGIN
    SELECT @handle = NULL;

    BEGIN TRANSACTION;

    WAITFOR (
        RECEIVE TOP (1)
            @handle = conversation_handle,
            @type   = message_type_name,
            @body   = CAST(message_body AS XML)
        FROM dbo.OrderInitiatorQueue
    ), TIMEOUT 2000;

    IF @handle IS NULL
    BEGIN
        COMMIT;
        BREAK;
    END

    SELECT @type AS MessageTypeReceivedByInitiator, @body AS Body;

    IF @type = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
        END CONVERSATION @handle;   -- both sides must end it to close the dialog

    COMMIT;
END
GO

-- STEP 5: Check the result. Conversation endpoints should be gone (or CLOSED briefly).
SELECT * FROM dbo.ProcessedOrders;
SELECT COUNT(*) AS OpenConversationEndpoints FROM sys.conversation_endpoints;
GO
