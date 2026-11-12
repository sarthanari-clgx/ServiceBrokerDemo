# SQL Server Service Broker Demo - Context

Learning project for SQL Server Service Broker: environment requirements, what was changed on this machine, how the broker works, and how it complements triggers in enterprise applications.

## 1. At a glance

```mermaid
mindmap
  root((Service Broker))
    What
      Messaging built into the database engine
      Queues are tables
      Transactional and durable
    Building blocks
      Message Type
      Contract
      Queue
      Service
      Conversation / Dialog
    Guarantees
      Exactly once
      In order per conversation
      Survives crash and restart
      Rolls back with the transaction
    Processing
      Manual RECEIVE
      Internal activation
      External activation
    Enterprise value
      Async work out of triggers
      Smaller transactions and locks
      Retry and poison message handling
      Load levelling for spikes
      Cross database / instance messaging
    Watch out
      Always END CONVERSATION
      Poison messages disable queue
      Restore / attach disables broker
      Monitor queue depth
```

## 2. System requirements

### Environment this demo was built on

| Item           | Value                                                                                    |
| -------------- | ---------------------------------------------------------------------------------------- |
| OS             | Windows 10 Enterprise (build 26100)                                                      |
| SQL Server     | 2025 RTM-GDR (17.0.1115.1), Standard Developer Edition, default instance `MSSQLSERVER` |
| Authentication | Windows authentication (`sqlcmd -S . -E -C`)                                           |
| Tooling        | `sqlcmd` (ODBC 17), PowerShell 7. No .NET code is needed.                              |

### Service Broker requirements

| # | Requirement                                                                                                        | Status here                                                |
| - | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| 1 | Edition supports Service Broker (all editions do; Developer has all features)                                      | Met                                                        |
| 2 | Database-level switch enabled: `ALTER DATABASE <db> SET ENABLE_BROKER` (`sys.databases.is_broker_enabled = 1`) | Enabled on the new demo DB                                 |
| 3 | A unique `service_broker_guid` per database                                                                      | Met (copies of a DB need `SET NEW_BROKER`)               |
| 4 | Permissions to create broker objects (`db_owner` or `CONTROL` on the DB)                                       | Met                                                        |
| 5 | Endpoint (`CREATE ENDPOINT ... FOR SERVICE_BROKER`)                                                              | Not needed for the single-DB demo (see section 10). Required only for messaging between instances. |
| 6 | Activation procedure runs under a valid principal (`EXECUTE AS OWNER` here)                                      | Met                                                        |

State found on the server before the demo:

| Database                          | `is_broker_enabled` |
| --------------------------------- | --------------------- |
| master, model                     | 0                     |
| tempdb, msdb                      | 1                     |
| DEV_IAE_MATRIX_DATA               | 1                     |
| DEV_IAE_DATA, DEV_IAE_MATRIX_LOGS | 0                     |

No `SERVICE_BROKER` endpoint existed. Existing databases were not touched.

## 3. Changes made on this machine

| Change                                                                           | Where                         | Notes                                                           |
| -------------------------------------------------------------------------------- | ----------------------------- | --------------------------------------------------------------- |
| Created database `ServiceBrokerDemo` with broker enabled                       | Local SQL Server              | Removable with `04_cleanup.sql`. |
| Created message types, contract, 2 queues, 2 services, `ProcessedOrders` table | `ServiceBrokerDemo`         | [01_setup.sql](01_setup.sql)                                     |
| Created 2 activation procedures and attached them to the queues                  | `ServiceBrokerDemo`         | [03_activation.sql](03_activation.sql)                           |
| Created demo scripts and runner                                                  | `c:\code\ServiceBrokerDemo` | See below                                                       |
| Temporary `Orders` table and trigger, used to verify section 6, then dropped   | `ServiceBrokerDemo`         | Nothing left behind                                             |

The two-database demo (section 10) later added the databases `SB_Sender` and `SB_Receiver` and a loopback-only `BrokerDemoEndpoint` on port 4022. No logins, instance settings or other databases were modified.

| File                                    | Purpose                                                  |
| --------------------------------------- | -------------------------------------------------------- |
| [01_setup.sql](01_setup.sql)             | Create DB, enable broker, create all broker objects      |
| [02_manual_flow.sql](02_manual_flow.sql) | One request/reply round trip done by hand                |
| [03_activation.sql](03_activation.sql)   | Automatic processing via internal activation, 5 messages |
| [04_cleanup.sql](04_cleanup.sql)         | Drop all demo databases and the endpoint                                         |
| [run-demo.ps1](run-demo.ps1)             | Runs 01 to 03; `-TwoDb` runs 05 and 06; `-Endpoint` runs 07; `-Cleanup` runs 04                     |

Gotcha found while building: `sqlcmd` defaults to `QUOTED_IDENTIFIER OFF`, which makes XML methods such as `.value()` fail with error 1934. Use `sqlcmd -I`, as the runner does.

## 4. Design

### 4.1 Objects

```mermaid
flowchart LR
    subgraph DB["Database: ServiceBrokerDemo (ENABLE_BROKER)"]
        direction LR
        IS["Service<br/>//Demo/OrderInitiatorService"] --- IQ[("Queue<br/>OrderInitiatorQueue")]
        TS["Service<br/>//Demo/OrderTargetService"] --- TQ[("Queue<br/>OrderTargetQueue")]
        C{{"Contract //Demo/OrderContract<br/>OrderRequest: sent by INITIATOR<br/>OrderReply: sent by TARGET"}}
        TQ -. "activation" .-> P1["dbo.ProcessOrderQueue"]
        IQ -. "activation" .-> P2["dbo.ProcessInitiatorQueue"]
        P1 --> T[("dbo.ProcessedOrders")]
    end
    IS -- "SEND OrderRequest" --> TS
    TS -- "SEND OrderReply" --> IS
    C --- TS
```

### 4.2 Message flow

```mermaid
sequenceDiagram
    autonumber
    participant App as Sender (initiator)
    participant IQ as Initiator queue
    participant TQ as Target queue
    participant Proc as ProcessOrderQueue (activated)
    App->>TQ: BEGIN DIALOG + SEND OrderRequest (in a transaction)
    Note over TQ: Message is stored durably.<br/>The sender can commit and move on.
    TQ-->>Proc: Activation launches the procedure
    Proc->>TQ: RECEIVE (message removed on commit)
    Proc->>Proc: Do the work (INSERT ProcessedOrders)
    Proc->>IQ: SEND OrderReply
    Proc->>IQ: END CONVERSATION (EndDialog message)
    IQ-->>App: RECEIVE reply, then EndDialog
    App->>App: END CONVERSATION (closes the dialog)
```

### 4.3 Conversation lifecycle

```mermaid
stateDiagram-v2
    [*] --> STARTED_OUTBOUND: BEGIN DIALOG
    STARTED_OUTBOUND --> CONVERSING: first reply / acknowledgement
    CONVERSING --> DISCONNECTED_INBOUND: other side ENDs
    CONVERSING --> DISCONNECTED_OUTBOUND: we END first
    DISCONNECTED_INBOUND --> CLOSED: END CONVERSATION
    DISCONNECTED_OUTBOUND --> CLOSED: other side ENDs
    CLOSED --> [*]: broker cleans up later
    CONVERSING --> ERROR: timeout or failure
    ERROR --> CLOSED: END CONVERSATION
```

After the demo ran, `sys.conversation_endpoints` showed CLOSED endpoints. This is normal, and the broker removes them in the background.

## 5. How Service Broker works

1. **Message type** names a kind of message and its validation (`WELL_FORMED_XML`, `NONE`, `EMPTY`, or an XML schema).
2. **Contract** lists which message types each side may send (`INITIATOR`, `TARGET` or `ANY`).
3. **Queue** is a hidden table where messages wait. It is durable, logged and recoverable like any table.
4. **Service** is a named address bound to one queue and the contracts it accepts.
5. **Conversation (dialog)** is a long-lived, bidirectional channel between two services. Messages on a conversation are delivered **exactly once and in order**.
6. **`SEND`** puts a message on the conversation, and **`RECEIVE`** takes it off the queue. Both take part in the caller's transaction, so a rollback un-sends or un-receives.
7. **Activation** starts your stored procedure when messages arrive, scaling up to `MAX_QUEUE_READERS` copies.
8. **`END CONVERSATION`** must be called by both sides. Forgotten dialogs leak rows in `sys.conversation_endpoints`.

Key properties:

- **Transactional.** The message commits or rolls back with your data change. The rollback case was verified (see section 6).
- **Asynchronous.** The sender does not wait for the receiver.
- **Reliable.** Messages survive restarts, and across instances they are retried and acknowledged.
- **Poison message protection.** After 5 consecutive rollbacks of a `RECEIVE` on a queue, SQL Server disables the queue. Handle bad messages with `TRY/CATCH` and `END CONVERSATION ... WITH ERROR`.

## 6. Service Broker and triggers

### 6.1 Problem with heavy triggers

A trigger runs **synchronously inside the caller's transaction**. Anything slow in it extends lock duration, slows every `INSERT`/`UPDATE`, and any error rolls back the user's original change. Triggers also cannot call out to other systems safely.

```mermaid
flowchart LR
    subgraph Before["Heavy trigger"]
        A1["App INSERT"] --> B1["Trigger: audit + email + call API + update report tables"] --> C1["COMMIT (slow, locks held)"]
    end
    subgraph After["Trigger + Service Broker"]
        A2["App INSERT"] --> B2["Trigger: SEND one small message"] --> C2["COMMIT (fast)"]
        C2 -. async .-> D2["Activated procedure does the heavy work"]
    end
```

### 6.2 Pattern

The trigger only enqueues. The slow work moves to an activated procedure. This was run against the demo DB and works with the existing `//Demo/OrderRequest` service and `dbo.ProcessOrderQueue`:

```sql
CREATE TRIGGER dbo.trg_Orders_Insert ON dbo.Orders AFTER INSERT AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @h UNIQUEIDENTIFIER, @m NVARCHAR(MAX);
    SET @m = (SELECT OrderId AS Id FROM inserted FOR XML PATH('Order'));

    BEGIN DIALOG CONVERSATION @h
        FROM SERVICE [//Demo/OrderInitiatorService]
        TO SERVICE '//Demo/OrderTargetService'
        ON CONTRACT [//Demo/OrderContract] WITH ENCRYPTION = OFF;

    SEND ON CONVERSATION @h MESSAGE TYPE [//Demo/OrderRequest] (@m);
END
```

Verified results:

- `INSERT` of order 3001 was processed by the `activation` procedure shortly afterwards.
- `INSERT` of order 3002 inside a transaction that was rolled back produced **no** message and no processing. The message rolled back with the data.

The trigger does a set-based insert; for multi-row `inserted`, the message contains all rows, so the receiver must handle several `<Order>` elements in production code. The demo receiver reads only the first.

### 6.3 Comparison

| Concern                          | Heavy trigger             | Trigger + Service Broker                                                          |
| -------------------------------- | ------------------------- | --------------------------------------------------------------------------------- |
| Caller latency                   | Includes all trigger work | Only the cost of one `SEND`                                                     |
| Lock duration                    | Long                      | Short                                                                             |
| Failure in downstream work       | Rolls back user's change  | Isolated; retried or handled by the receiver                                      |
| Traffic spikes                   | Hit the app directly      | Absorbed by the queue (load levelling)                                            |
| Consistency with the data change | Yes                       | Yes, the message is committed or rolled back with it                              |
| Result available immediately     | Yes                       | No, eventual consistency                                                          |
| Cross-database / instance        | Awkward                   | Built in                                                                          |
| Message to external systems      | Unsafe                    | External activation or a worker service reads the queue                           |
| Alternative                      |                           | Outbox table + polling job (simpler but needs polling, no ordering or activation) |

### 6.4 Typical enterprise use cases

- **Audit and history** written outside the user's transaction time.
- **Denormalisation / reporting tables** refreshed asynchronously.
- **Integration events** such as order created, listing changed, or cache invalidation (an external service drains the queue).
- **Batch smoothing**: bulk loads enqueue work that is processed at a controlled rate.
- **Cross-database workflows** that stay transactionally consistent on the sending side.

### 6.5 When not to use it

- The caller needs the result immediately (use a synchronous call).
- The logic must be atomic with the original change (keep it in the trigger or procedure).
- Very high volume integration across many systems where a dedicated message platform (Kafka, Azure Service Bus) is already standard. Service Broker is a good fit when the data and the work live in SQL Server.

## 7. Comic strips

### Strip 1: The slow trigger

```text
+-----------------------+-----------------------+-----------------------+
| PANEL 1               | PANEL 2               | PANEL 3               |
|                       |                       |                       |
|  (o_o)  USER:         |  [ TRIGGER ]          |  (x_x)  USER:         |
|  "Save my order!"     |  "Hold on. Sending    |  "Why is it still     |
|                       |   email... updating   |   spinning??"         |
|        INSERT         |   reports... calling  |                       |
|        =======>       |   an API..."          |   ...locks held...    |
+-----------------------+-----------------------+-----------------------+
```

### Strip 2: Enter the broker

```text
+-----------------------+-----------------------+-----------------------+
| PANEL 1               | PANEL 2               | PANEL 3               |
|                       |                       |                       |
|  (o_o)  USER:         |  [ TRIGGER ]          |  (^_^)  USER:         |
|  "Save my order!"     |  "Got it. Dropping a  |  "Done already!"      |
|                       |   note in the queue." |                       |
|        INSERT         |        [msg] ---> |Q| |   [ WORKER ] (-_-)zzz |
|        =======>       |                       |   "Woke up. Working.."|
+-----------------------+-----------------------+-----------------------+
```

### Strip 3: Rollback safety

```text
+-----------------------+-----------------------+-----------------------+
| PANEL 1               | PANEL 2               | PANEL 3               |
|                       |                       |                       |
|  APP: BEGIN TRAN      |  APP: "Oops, the      |  QUEUE: "No message   |
|  INSERT order 3002    |   payment failed."    |   for 3002? Good."    |
|  trigger SENDs [msg]  |   ROLLBACK;           |                       |
|                       |   [msg] ---> poof!    |  WORKER: "Nothing to  |
|                       |                       |   do. Back to sleep." |
+-----------------------+-----------------------+-----------------------+
```

### Strip 4: The poison message

```text
+-----------------------+-----------------------+-----------------------+
| PANEL 1               | PANEL 2               | PANEL 3               |
|                       |                       |                       |
|  WORKER: RECEIVE msg  |  WORKER: "Rollback    |  QUEUE: "5 strikes.   |
|  -> error -> ROLLBACK |   again... and again" |   I'm disabling       |
|  msg returns to queue |   x5                  |   myself."  (STATUS   |
|                       |                       |   = OFF)              |
|                       |                       |  FIX: TRY/CATCH +     |
|                       |                       |  END CONV WITH ERROR  |
+-----------------------+-----------------------+-----------------------+
```

## 8. Running the demo

```powershell
cd c:\code\ServiceBrokerDemo
.\run-demo.ps1            # setup + manual flow + activation (single database)
.\run-demo.ps1 -TwoDb      # sender and receiver in separate databases
.\run-demo.ps1 -Endpoint   # route the two-database demo through a TCP endpoint
.\run-demo.ps1 -Cleanup    # drop all demo databases and the endpoint
```

Expected: `02_manual_flow.sql` shows the request, reply and `EndDialog` messages, and `ProcessedOrders` has `manual` and `activation` rows (orders 1001 and 2001 to 2005).

## 9. Operational cheat sheet

```sql
-- Is the broker on?
SELECT name, is_broker_enabled FROM sys.databases;

-- Messages waiting
SELECT COUNT(*) FROM dbo.OrderTargetQueue WITH (NOLOCK);

-- Queue / activation state
SELECT name, is_receive_enabled, is_activation_enabled, activation_procedure FROM sys.service_queues;

-- Conversations (look for leaks and ERROR states)
SELECT state_desc, COUNT(*) FROM sys.conversation_endpoints GROUP BY state_desc;

-- Running activation procedures
SELECT * FROM sys.dm_broker_activated_tasks;

-- After restoring a copy of a database
ALTER DATABASE <db> SET ENABLE_BROKER;   -- or SET NEW_BROKER for a clone
```

Common pitfalls:

- Restore or attach disables the broker unless you use `WITH ENABLE_BROKER`.
- Forgetting `END CONVERSATION` on one side causes endpoint leaks.
- A disabled queue (poison message) stops all processing silently, so monitor `is_receive_enabled`.
- A broker-enabled database with a duplicate `service_broker_guid` (from a restore on the same instance) cannot be enabled without `NEW_BROKER`.

## 10. Two databases and the endpoint concept

### 10.1 What was added

| File | Purpose |
|---|---|
| [05_twodb_setup.sql](05_twodb_setup.sql) | Recreates `SB_Sender` (initiator service, queue, `SendOrder` procedure, `Replies` table) and `SB_Receiver` (target service, queue, activated processor, `ProcessedOrders` table) |
| [06_twodb_run.sql](06_twodb_run.sql) | Sends orders 5001 to 5003 from the sender and shows results in both databases, the route used, and the transmission queue |
| [07_endpoint_demo.sql](07_endpoint_demo.sql) | Creates a loopback-only Service Broker endpoint and routes, then sends orders 6001 and 6002 over TCP |

Each database has its own copy of the message types and contract; they only need matching names. Service names use `//TwoDb/` so they do not collide with the single-database demo.

```mermaid
flowchart LR
    subgraph Instance["One SQL Server instance"]
        subgraph S["SB_Sender"]
            SP["dbo.SendOrder<br/>INSERT OutgoingOrders + SEND"] --> SQ[("SenderQueue<br/>//TwoDb/SenderService")]
            SQ --> SA["ProcessSenderQueue<br/>INSERT Replies"]
        end
        subgraph R["SB_Receiver"]
            RQ[("ReceiverQueue<br/>//TwoDb/ReceiverService")] --> RA["ProcessReceiverQueue<br/>INSERT ProcessedOrders"]
        end
        SP == "06: AutoCreatedLocal (no endpoint)" ==> RQ
        RA == "reply" ==> SQ
        EP(("Endpoint<br/>TCP 127.0.0.1:4022"))
        SP -. "07: route ReceiverViaTcp" .-> EP -.-> RQ
    end
```

Results observed:

- Script 06: orders 5001 to 5003 were processed in `SB_Receiver` and the replies were stored in `SB_Sender.Replies`. The sender's only route was `AutoCreatedLocal` (`LOCAL`) and `sys.transmission_queue` was empty.
- Script 07: orders 6001 and 6002 were processed. `sys.dm_broker_connections` showed two connections (`LOGGED IN`, `ONLINE`, AES) with bytes sent and received, which proves the traffic used the endpoint.

### 10.2 The endpoint concept

An **endpoint** is an instance-level network listener. A Service Broker endpoint (`CREATE ENDPOINT ... FOR SERVICE_BROKER`) accepts TCP connections from other SQL Server instances and hands incoming messages to the right database and queue. It is separate from the normal SQL port 1433, and an instance can have only one Service Broker endpoint.

```mermaid
mindmap
  root((Endpoint))
    Instance level
      One per instance
      TCP listener e.g. 4022
      Separate from port 1433
    Settings
      AUTHENTICATION: WINDOWS or CERTIFICATE
      ENCRYPTION: REQUIRED with AES
      MESSAGE_FORWARDING
      LISTENER_IP
    Permissions
      GRANT CONNECT ON ENDPOINT
      Login of the calling instance
    Works with
      ROUTE
        Address book per database
        SERVICE_NAME to TCP address
      Dialog security
        End to end protection
        Certificates and remote service bindings
```

Three things are easy to confuse:

| Concept | Scope | Question it answers | Example from this demo |
|---|---|---|---|
| **Endpoint** | Instance | Where do I listen for incoming broker traffic, and who may connect? | `BrokerDemoEndpoint` on `127.0.0.1:4022` |
| **Route** | Database | Where do I send messages for service X? | `ReceiverViaTcp`: `//TwoDb/ReceiverService` to `TCP://127.0.0.1:4022` |
| **Service** | Database | What is the named address of a queue? | `//TwoDb/ReceiverService` |

When an endpoint and route are needed:

| Scenario | Endpoint | Route | Security needed |
|---|---|---|---|
| Same database | No | Built-in `AutoCreatedLocal` | None |
| Different databases, same instance (script 06) | No | Built-in `AutoCreatedLocal` | Anonymous dialog: `guest` connects to the target DB and `public` may SEND on the target service |
| Different instances or servers | Yes, on both | Explicit route in each direction | `CONNECT` on the endpoint, firewall port open, optional dialog security |

How a message finds its destination:

```mermaid
flowchart TD
    A["BEGIN DIALOG ... TO SERVICE X"] --> B{"Route for X in the sender database?"}
    B -- "Only AutoCreatedLocal (ADDRESS = LOCAL)" --> C["Look for service X in databases of this instance"]
    C --> D["Enqueue directly on the target queue"]
    B -- "ROUTE with ADDRESS = TCP://host:port" --> E["Message waits in sys.transmission_queue"]
    E --> F["Open connection to the remote endpoint and authenticate"]
    F --> G["Remote endpoint finds service X in its databases"]
    G --> D
```

A route that names the service beats the wildcard `AutoCreatedLocal` route, which is why adding `ReceiverViaTcp` switches delivery to TCP. Replies need a route back to the initiator's service, so routes are needed in both directions. Messages that cannot be delivered stay in `sys.transmission_queue`, with the reason in `transmission_status`.

```mermaid
sequenceDiagram
    autonumber
    participant App as SB_Sender
    participant TQ as sys.transmission_queue
    participant EP as Endpoint 4022
    participant Rcv as SB_Receiver
    App->>TQ: SEND (route ReceiverViaTcp)
    TQ->>EP: Connect, authenticate (Windows), encrypt (AES)
    EP->>Rcv: Enqueue on ReceiverQueue
    Rcv->>Rcv: Activated procedure processes the order
    Rcv->>EP: Reply (route SenderViaTcp)
    EP->>App: Enqueue on SenderQueue
```

Real two-server layout, for reference:

```mermaid
flowchart LR
    subgraph A["Server A"]
        DA[("Sender DB<br/>route: Receiver to TCP://serverB:4022")] --- EA(("Endpoint 4022"))
    end
    subgraph B["Server B"]
        EB(("Endpoint 4022")) --- DB2[("Receiver DB<br/>route: Sender to TCP://serverA:4022")]
    end
    EA <== "TCP, Windows or certificate auth, AES" ==> EB
```

### 10.3 Comic strip: the post office

```text
+-----------------------+-----------------------+-----------------------+
| PANEL 1               | PANEL 2               | PANEL 3               |
|                       |                       |                       |
|  SENDER DB: "Letter   |  ROUTE (address book):|  ENDPOINT (mail room  |
|  for service X!"      |  "X lives at          |  door): "Badge please. |
|                       |   TCP://serverB:4022" |  CONNECT granted?     |
|  [letter]  --->       |                       |  Come in, X is in     |
|                       |   Same building?      |  the Receiver DB."    |
|                       |   LOCAL: no door.     |                       |
+-----------------------+-----------------------+-----------------------+
```

### 10.4 Lesson from building it: crossing a database boundary is a security boundary

The first run of script 06 sent the messages but nothing arrived. They sat in `SB_Sender.sys.transmission_queue` with this status:

```text
Error: 916, State: 3. The server principal "ISC\sarthanari" is not able to access the database
"SB_Receiver" under the current security context.
```

The sender used `ENCRYPTION = OFF`, so the dialog is anonymous and arrives in the target database as `guest`/`public`. The fix, in `05_twodb_setup.sql` for the receiver and in `07_endpoint_demo.sql` for the sender's reply service, is:

```sql
GRANT CONNECT TO guest;
GRANT SEND ON SERVICE::[//TwoDb/ReceiverService] TO [public];
```

This is acceptable for a throwaway demo. In production, prefer dialog security with certificates and remote service bindings, or a dedicated user with `SEND` permission, instead of opening the service to `public`. Diagnose stuck messages with:

```sql
SELECT to_service_name, transmission_status FROM sys.transmission_queue;
```

### 10.5 Cleanup and exposure

The endpoint listens on `127.0.0.1` only, so it is not reachable from other machines. It is still running after the demo. `.\run-demo.ps1 -Cleanup` drops it, together with `SB_Sender`, `SB_Receiver` and `ServiceBrokerDemo`.

## 11. References

- Microsoft Learn: SQL Server Service Broker documentation
- `sys.databases`, `sys.service_queues`, `sys.conversation_endpoints`, `sys.dm_broker_activated_tasks`
