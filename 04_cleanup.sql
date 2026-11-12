/* 04_cleanup.sql - Drop the demo database (leaves all other databases untouched). */
USE master;
GO
IF DB_ID('ServiceBrokerDemo') IS NOT NULL
BEGIN
    ALTER DATABASE ServiceBrokerDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE ServiceBrokerDemo;
END
GO
