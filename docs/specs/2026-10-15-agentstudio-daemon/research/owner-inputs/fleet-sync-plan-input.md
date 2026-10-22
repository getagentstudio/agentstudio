# Owner-supplied shared replication plan

Source: direct owner message in the AgentStudio Lead conversation, 2026-10-16. Preserved as supplied research/design direction; it is not a runtime or release result. The preceding owner instruction closed the Advisor and asked that it not be messaged to save tokens. That instruction remains active.

The text below supplies the shared-repository mechanism and asks for continued data/replication research. AgentStudio unit/schema selection, registry deployment, lease configuration and native/execution effects still need their own consumer contracts. This supplement does not modify the five originally frozen owner-source files.

```text
How it fits together

 agent-fleet-sync (shared repo)                      who uses it
 ─────────────────────────────────────────────       ──────────────────────────
 fleet-sync-protocol    frames and payloads          everyone
 fleet-sync-session     session: client half +       Router, Host (client);
                        server rules                 central, service (server)
 fleet-sync-transport-  WebSocket client and         Router, Host, service
   websocket            Tokio server
 fleet-sync-writer      the replicated database,     Router (under ProjectStore),
                        capture, sending, retention  AgentStudio Host
 fleet-sync-lease       registry rules, holder       central, service; writer
                        half, write gate
 fleet-sync-receiver    copy apply, snapshots,       central, service
                        hook outbox
 fleet-sync-service     Tokio host for receiver      AgentStudio Gateways
                        and registry ("as a service")
 owned SQLx drivers     sqlx-turso, Durable Object   all of the above
                        driver, query generator

- Rules decide; hosts carry out. The receiver, the registry and the session's server side each decide inside a transaction they're handed. They return a closed list of things to do: send an answer, call another object, set an alarm, or do consumer work after the commit. That's the shape M3's copy and registry rules already have.
- The board plugs in through traits:
  - its schema and tables;
  - ProjectSummary as the annotation on each piece;
  - the directory update as its receiver hook, delivered at least once after commit;
  - the archive check as a durable gate on claims;
  - Access plus the machine credential as its authenticator.
- Central's ConnectionObject becomes SessionObject. It holds the session and knows its current connection. A dropped connection now marks the session detached instead of deleting it.

One path: a write reaching its copies

admission ─ begin_write ─► ReplicatedDatabase (the lease gate checks the writer state)
   commit ─► Turso capture
ReplicationSender ─ reads capture after each copy's position
   ─ groups transactions; turns a key change into delete-old + upsert-new
   ─ one Piece per copy, sent independently ─► SessionClient ─► WebSocket
host (central or service) ─ apply_piece inside a transaction
   ─ the consumer hook runs inside it ─ commit
   ─ deliver after-commit items ─ send Acked{through}
sender ─ records that copy's position ─ prunes per retention this is the plan ok lets continue reserach amke a tree of wah tare diciosn for data structure what rejplciation kunlcos etc
```

Current continuation: [data/replication decision map](../../designs/02-data-ownership-replication/research/data-replication-decisions.md). Source-file coverage and the distinction between the shared design and AgentStudio decisions are in the [research ledger](../../../../../tmp/practices-research/2026-10-16-fleet-sync-data-decisions/research-ledger.md).
