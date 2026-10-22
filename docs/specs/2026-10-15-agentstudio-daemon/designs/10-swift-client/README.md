# DS10 — Swift clients, commands and native interaction

## Read this folder

- [Folder HTML reader](index.html).
- [Command operation map](command-operation-map.md): all 154 current identities, their source-checked exposure/mode, current dispatch path and the backend/native mapping still to bind.
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [All 154 commands: current execution owners and proposed integration](command-execution-map.md).
- [Sidebar client read needs: source fields, prepared rows and native application](sidebar-read-needs.md).
- [Session/context/native read needs: fields, publication and read-side effects](session-native-read-needs.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Native publication and interaction, command catalog/targets, workspace/layout meaning, terminal display/input and declared clipboard/editor/browser/Finder/chooser/platform ingress.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U4/U6/U9/U11/U13/U14/U16/U17/U19.
- Specification: [this design's capability contracts](specification.md), owning K6, K12; apply R1/R3/R5/R7/R13 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS02](../02-data-ownership-replication/README.md), [DS04](../04-terminal-runtime/README.md), [DS08](../08-files-review-output/README.md), [DS09](../09-gateway-cli/README.md)

## What this design must settle

- Realize the client-arrangement scope selected in design 02; Host execution identity and native implementation convenience do not choose the data owner.
- Preserve the command/display/IPC catalog and current unavailable features; do not resurrect dormant capabilities.
- Set remote-origin native effect policy, consent/refusal and phone/native lifecycle outcomes. Sockets do not require Rust-Swift FFI.

## Result consumed by later designs

A thin Swift client boundary with domain work and derivation off MainActor, publication at the native owner, authoritative schemas and explicit native target/effect identity.

## Evidence to reopen

- [2026-10-15-daemon-coordination-experiment.md](experiments/coordination.md)
- [e3-swift-publication-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/e3-swift-publication-evidence.md)
- [command-surface-inventory.md](../../research/evidence/2026-10-15-daemon-extraction-survey/command-surface-inventory.md)
- [2026-10-16-daemon-data-ownership-survey.md](../02-data-ownership-replication/research/data-ownership-survey.md)

## Proof boundary

Real Swift/Rust producer-consumer interoperability, exact native targets/effects/refusals, MainActor publication/unchanged suppression and matched key-to-visible/presentation observations. E3/E5/E6; UI changes need their own current-app visual design.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
