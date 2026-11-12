/*
  07_endpoint_demo.sql - Make the same SB_Sender -> SB_Receiver conversation travel over TCP.

  The two databases are on one instance, so an endpoint is NOT needed (see 06_twodb_run.sql).
  Here we add one anyway, bound to loopback only, to show the pieces that cross-instance
  messaging needs:

    ENDPOINT : a TCP listener owned by the instance (one SERVICE_BROKER endpoint per instance).
    ROUTE    : a per-database entry that maps a service name to a network address.
    PERMS    : CONNECT on the endpoint for the remote login, SEND on the target service.

  Remove everything with 04_cleanup.sql.
*/
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.service_broker_endpoints)
    CREATE ENDPOINT BrokerDemoEndpoint
        STATE = STARTED
        AS TCP (LISTENER_PORT = 4022, LISTENER_IP = (127.0.0.1))
        FOR SERVICE_BROKER (AUTHENTICATION = WINDOWS, ENCRYPTION = REQUIRED ALGORITHM AES, MESSAGE_FORWARDING = DISABLED);
GO
-- With Windows authentication the calling instance's service account needs CONNECT.
IF SUSER_ID(N'NT SERVICE\MSSQLSERVER') IS NOT NULL
    GRANT CONNECT ON ENDPOINT::BrokerDemoEndpoint TO [NT SERVICE\MSSQLSERVER];
GO

-- Sender side: "to reach //TwoDb/ReceiverService, connect to this address".
-- A route naming the service wins over the wildcard AutoCreatedLocal route.
USE SB_Sender;
GO
IF EXISTS (SELECT 1 FROM sys.routes WHERE name = N'ReceiverViaTcp') DROP ROUTE ReceiverViaTcp;
CREATE ROUTE ReceiverViaTcp WITH SERVICE_NAME = N'//TwoDb/ReceiverService', ADDRESS = N'TCP://127.0.0.1:4022';
-- Replies come back to the sender's service, so it must accept them as well.
GRANT CONNECT TO guest;
GRANT SEND ON SERVICE::[//TwoDb/SenderService] TO [public];
GO

-- Receiver side: the return route. In a real two-server setup this points at the sender's server.
USE SB_Receiver;
GO
IF EXISTS (SELECT 1 FROM sys.routes WHERE name = N'SenderViaTcp') DROP ROUTE SenderViaTcp;
CREATE ROUTE SenderViaTcp WITH SERVICE_NAME = N'//TwoDb/SenderService', ADDRESS = N'TCP://127.0.0.1:4022';
GO

SET NOCOUNT ON;
EXEC SB_Sender.dbo.SendOrder 6001;
EXEC SB_Sender.dbo.SendOrder 6002;
WAITFOR DELAY '00:00:03';

SELECT 'SB_Receiver.ProcessedOrders' AS TableName, OrderId FROM SB_Receiver.dbo.ProcessedOrders WHERE OrderId >= 6000;
SELECT 'SB_Sender.Replies'           AS TableName, OrderId, Status FROM SB_Sender.dbo.Replies WHERE OrderId >= 6000;

SELECT 'Endpoint' AS Info, sbe.name, sbe.state_desc, te.port, te.ip_address,
       sbe.connection_auth_desc, sbe.encryption_algorithm_desc
FROM sys.service_broker_endpoints sbe JOIN sys.tcp_endpoints te ON te.endpoint_id = sbe.endpoint_id;

SELECT 'Routes' AS Info, name, remote_service_name, address FROM SB_Sender.sys.routes
UNION ALL
SELECT 'Routes (receiver)', name, remote_service_name, address FROM SB_Receiver.sys.routes;

-- Proof that traffic used the network layer.
SELECT 'Broker connections' AS Info, state_desc, login_state_desc, encryption_algorithm_desc,
       total_bytes_sent, total_bytes_received
FROM sys.dm_broker_connections;
