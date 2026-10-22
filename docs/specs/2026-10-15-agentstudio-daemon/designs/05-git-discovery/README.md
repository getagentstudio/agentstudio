# DS05 — Git operations, discovery and observations

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [All 44 Git SDK operations: acquisition, effects and Host integration](git-operation-map.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Non-fork AgentStudio Git behavior, repository/worktree identity, refs/index/status/diff/remotes, discovery, membership, watchers and refresh/currentness on macOS and Linux.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U4/U6/U9/U11/U13.
- Specification: [this design's capability contracts](specification.md), owning K1, K3; apply R2/R4 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS01](../01-service-contracts/README.md), [DS02](../02-data-ownership-replication/README.md), [DS03](../03-authority-control-plane/README.md)

## What this design must settle

- Select the public subset and supported byte-name/path/filesystem/remote/credential profiles.
- Preserve partial effects, indeterminate ref changes, exact-candidate discovery and source/coverage failures.
- Define watcher continuity and demand/currentness without making a Swift view another repository owner.

## Result consumed by later designs

Operation-specific Git/platform contracts and source-qualified repository observations. The 42 surveyed non-fork SDK operations are classified without becoming 42 automatic public RPC methods.

## Evidence to reopen

- [2026-10-15-daemon-extraction-survey.md](../../research/extraction-survey.md)
- [capability-git-contract-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/capability-git-contract-evidence.md)
- [e2-git-operation-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/e2-git-operation-evidence.md)

## Proof boundary

Real repository/ref/index/filesystem/remote interactions with raced mutations, cancellation, watcher loss and explicit residue on both platforms. E2/E4; leaf feasibility is not complete parity.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
