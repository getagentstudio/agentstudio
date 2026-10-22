# Owner-supplied agent-fleet-sync update — 2026-10-17

Supplied directly to the AgentStudio Lead on 2026-10-17. The text below is preserved as the source message; it is not a new blanket dependency-adoption instruction. The named one-page file has not yet been located. Current primary-source verification and consumer consequences live in [the DS02 integration picture](../../designs/02-data-ownership-replication/research/fleet-sync-consumer-fit.md). Earlier central lease authority and writer-transfer exclusions remain in force.

> I've written the brief for an AgentStudio agent here: agent-fleet-sync-for-agentstudio.md. It's one page. It covers what agent-fleet-sync is, the six PRs with links, the crates, what a consumer has to supply, the rules that bind AgentStudio (UUIDv7 keys, explicit holder changes, copies that never block the writer), the decisions AgentStudio still owns, and what isn't proven yet. Short version to pass along:
>
> ▎ agent-fleet-sync replicates one Turso/SQLite database one way, from its single lease-holding writer to read-only copies. For AgentStudio that's a Host writing and Gateways as copies, plus durable cross-machine delivery. There are six stacked PRs in agent-collaboration/agent-fleet-sync, reviewed and green but not merged. Replicated tables must use UUIDv7, never-changing keys. AgentStudio still decides its tables and retention, where its lease registry runs, and what follower copies do on a holder change.
>
> i give you dthis see if that helps  or chagens any6thnign amke srue over arhciecture is fukly udnaratndalbe
