# DS01 — Service contracts and protocol

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [All 57 app RPC methods: sources, effects and proposed placement](rpc-operation-map.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Host-qualified identities, operation outcomes, frontend versus Host-local entry, protocol lanes, schema ownership and supported pairing. Support the macOS/iOS Gateway under S28 and independent session/connection lifetimes; qualify mobile runtime hosting separately.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U1/U2/U3/U6/U9/U12/U16/U17/U18/U19.
- Specification: [this design's capability contracts](specification.md), owning K13; apply R1/R3/R7/R11/R12/R13 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: Existing global requirements and domain definitions; no preceding design cycle.

## What this design must settle

- Exact method exposure, bounds, incompatible-pair refusal and request/result semantics.
- Ordinary Mac CLI routing remains unresolved; attached-machine targeting does not settle its physical route.
- Which workloads and observations can discriminate socket, codec and remote transport choices without confusing echo with visible terminal response?

## Result consumed by later designs

A shared contract vocabulary and operation-envelope/schema boundaries that the domain designs can consume. S32 selects Quinn for the remote transport and the browser/native entry split. Codec and RPC semantics remain separate candidates; no speed winner is inferred. The [bounded transport design](../../increments/00-qualification/bridge-gateway-transport/index.md) carries this refinement.

## Evidence to reopen

- [2026-10-15-daemon-extraction-survey.md](../../research/extraction-survey.md)
- [2026-10-15-daemon-route-performance-experiment.md](../11-operations-integration/experiments/route-performance.md)
- [Swift/socket compatibility qualification](experiments/swift-socket-compatibility.md): the concrete E2/A13 and I0 producer/consumer, framing, semantic-admission and supported-pair procedure; unexecuted.
- [command-surface-inventory.md](../../research/evidence/2026-10-15-daemon-extraction-survey/command-surface-inventory.md)
- [Current CLI/socket targeting trace](../../research/evidence/2026-10-16-daemon-targeting/research-ledger.md): endpoint discovery, friendly selectors, durable target validation, caller authority and submission/custody distinctions; source evidence only.

## Proof boundary

Real Swift/Rust Unix-socket interoperability and supported mixed Host/Gateway pairs; independent control/terminal/content traffic, malformed input, interruption and bounded slow consumers. E5/E6 inform the design; no results are claimed.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
