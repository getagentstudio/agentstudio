# DS02 — Data ownership, storage and replication

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Truth owners, database units, every current table/column/container, transaction closure, private state, faithful replicas, derived queries, semantic notifications and native publication inputs.

Start with [where each kind of state lives](storage-placement-design.md) and [the complete current table/column placement matrix](storage-placement-matrix.md). These connect the inventory to transaction, privacy, shared-layout and native boundaries. Then read [how agent-fleet-sync fits AgentStudio](research/fleet-sync-consumer-fit.md) for the current Host/Gateway/control-plane picture, four traffic lanes, actual crate responsibilities and the newer immutable-UUIDv7 key constraint.

## How to count the source inventory

- **86 current logical application tables:** the catalog's 597 named columns and placement matrix use this scope. It includes the declared producer-local CLI and in-memory search tables; it is not a list of admitted replicated tables.
- **22 additional historical names:** 9 retired logical tables, 11 transition-only names and 2 conditional drop-only names. The catalog records them so retired or renamed data is accounted for; they are not extra current features to port.
- **Migration bookkeeping:** `grdb_migrations` follows its owning database. Its explicit CLI declaration adds one distinct source name to the union above, giving 109 declared names. A name can occur in several physical databases; 109 names does not mean 109 installed runtime tables. Engine-generated sequence/FTS shadow/index objects are a further physical-schema concern.

The [catalog](research/data-catalog.json) owns these lists and exclusions. Count current logical meaning, historical migration accounting and physical engine objects separately. This source inventory neither observes a user's database nor selects a new schema/export set. Shared arrangement/read scope and corrected worktree local-Host routing/activation follow the [selected profile](../../initial-profile.md), rather than old undecided notes in source-comparison history.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U4/U9/U13/U15/U16/U18.
- Specification: [this design's capability contracts](specification.md), owning K11 and C5 scenarios; apply R6/R9/R10/R11/R15/R16 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS01](../01-service-contracts/README.md)

## What this design must settle

- Choose units and declared table membership without splitting binding/message/intake-cursor or annotation-finalization transactions.
- Realize the selected shared tabs/layout outcome: the current proposal uses a designated existing Host, consumed by design 10. Resolve exact navigation, mixed-row and Undo/custody cuts without reopening sharing.
- Define snapshot/incarnation, retention, receiver hook and acknowledgement meaning; read-serving copies are not automatically writer-recoverable snapshots.

## Result consumed by later designs

A classified target data map and replication boundary: what remains authoritative at Host, what is copied, what is private, and what is materialized. Registry ownership and application rows remain different truths.

## Evidence to reopen

- [2026-10-16-daemon-data-ownership-survey.md](research/data-ownership-survey.md)
- [2026-10-16-daemon-data-catalog.json](research/data-catalog.json)
- [Current SQL keys and replication prerequisites](research/schema-prerequisites.md)
- [Client query/table dependencies and read-side effects](research/query-data-dependencies.md)
- [Current use of every catalogued table](research/table-use-index.md)
- [2026-10-16-daemon-data-replication-decisions.md](research/data-replication-decisions.md)
- [R2-reduced-inventory.md](../../research/evidence/2026-10-16-advisor-storage-placement/R2-reduced-inventory.md)

## Proof boundary

Source-to-capture-to-receiver-to-query interactions, transaction refusal, copy refill, slow independent receivers and exact SQL/key/schema values. E2/E3/E5; the 86-table inventory is source evidence, not an adopted export schema.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
