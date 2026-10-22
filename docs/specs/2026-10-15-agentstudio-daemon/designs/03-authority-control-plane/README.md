# DS03 — Authority, leases and central control plane

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Central lease registry, Host writer validity, distinct authentication/application grants, effect-time authority, revocation, initial setup and separately composable integration.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U9/U15/U17/U20/U21.
- Specification: [this design's capability contracts](specification.md), owning K14; apply R9/R14 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS01](../01-service-contracts/README.md), [DS02](../02-data-ownership-replication/README.md)

## What this design must settle

- Pending owner choice: expiry-paused application writes versus required indefinite offline writes. No answer or grace period is inferred.
- Select duration/renewal, conservative expiry, central-unreachable behavior and the in-flight transaction/commit rule.
- Separate credential revocation, database lease, terminal control and machine orchestration. Database-writer transfer and machine move/copy implementation remain excluded.

## Result consumed by later designs

The authority contracts consumed by Host operations and Gateway clients, including the relationship between the central registry and authoritative replication copies. Building the central server remains later work.

## Evidence to reopen

- [central-control-plane-selection.json](../../research/owner-inputs/central-control-plane-selection.json)
- [2026-10-16-daemon-data-replication-decisions.md](../02-data-ownership-replication/research/data-replication-decisions.md)
- [research-ledger.md](../../../../../tmp/practices-research/2026-10-16-fleet-sync-data-decisions/research-ledger.md)

## Proof boundary

Controlled-clock expiry/renewal with every Gateway (macOS or iOS) absent, lost renewal answer, overlapping transaction, cross-scope/refused grant and revocation while a writer lease remains valid. E2/E3; no automatic promotion or transfer journey.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
