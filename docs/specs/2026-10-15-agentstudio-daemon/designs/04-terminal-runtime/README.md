# DS04 — Terminal sessions, attachments and facts

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Durable execution versus temporary connection/attachment, ZMX adaptation, create/list/terminate, terminal input/resize/focus ownership, ordered restoration and independent fact collection.

**Current backend evidence:** [20 October observations](research/backend-observations-2026-10-20.md) establish viewerless-create feasibility but reject the tested Capture-plus-live reconstruction and ZMX leadership as AgentStudio control authority. The native renderer and complete service path remain unqualified; no replacement mechanism is selected.

The [execution-lifecycle design](execution-lifecycle-design.md) traces current pane/Undo cleanup to backend retirement and proposes the separate view-detach, Host termination and cutover boundaries required by R5. It leaves the named identity/control/recovery profiles open.

The [terminal API ownership map](terminal-api-ownership.md) classifies every current status/snapshot/send result field and all six wait conditions by Host execution versus native view source, including the no-view boundary. Actual versioned shapes and qualified source guarantees remain to settle.

The [internal session operation boundaries](session-operation-boundaries.md) give the Host's admitted-origin, backend-evidence, guarded-write and task-custody structure, including create-after-effect failure and the control-ordering gaps that remain.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U3/U4/U11/U14/U15/U16.
- Specification: [this design's capability contracts](specification.md), owning K5; apply R2/R5/R6/R7/R9/R10 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS01](../01-service-contracts/README.md), [DS02](../02-data-ownership-replication/README.md), [DS03](../03-authority-control-plane/README.md)

## What this design must settle

- Select ZMX version/profile and validate snapshot-to-live ordering; capture is not a universal screen-restoration guarantee.
- Resolve viewers/controllers, competing geometry, focus, input acknowledgement and uncertain input replay.
- Define natural exit, Host restart/re-adoption, ended-session records and exact view-independent title/CWD/activity/completion/exit evidence.

## Result consumed by later designs

A complete terminal lifecycle and control/fact contract with Host ownership and thin client presentation. Terminal controller transfer is distinct from the excluded database-writer transfer.

## Evidence to reopen

- [2026-10-15-daemon-terminal-restoration-experiment.md](experiments/terminal-restoration.md)
- [2026-10-15-daemon-host-autonomy-experiment.md](../07-agents-context/experiments/host-autonomy.md)
- [e1-backend-cut-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/e1-backend-cut-evidence.md)

## Proof boundary

Real ZMX/PTY/process and renderer interactions, independent session/fact witnesses, two viewports, slow viewers, disconnect/reconnect and deliberate input-result loss. E1/E2/E5.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
