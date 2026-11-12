/* 04_cleanup.sql - Drop everything the demos created (other databases are untouched). */
USE master;
GO
IF DB_ID('ServiceBrokerDemo') IS NOT NULL
BEGIN
    ALTER DATABASE ServiceBrokerDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ServiceBrokerDemo;
END
IF DB_ID('SB_Sender') IS NOT NULL
BEGIN
    ALTER DATABASE SB_Sender SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SB_Sender;
END
IF DB_ID('SB_Receiver') IS NOT NULL
BEGIN
    ALTER DATABASE SB_Receiver SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SB_Receiver;
END
IF EXISTS (SELECT 1 FROM sys.service_broker_endpoints WHERE name = N'BrokerDemoEndpoint')
    DROP ENDPOINT BrokerDemoEndpoint;
GO
