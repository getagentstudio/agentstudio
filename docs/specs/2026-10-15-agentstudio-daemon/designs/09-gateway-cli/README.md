# DS09 — Gateway, multi-host routing and CLI adapters

S28 requires the Gateway engine on macOS and iOS. Machine-scoped worktree CLI uses its attached macOS/Linux Host daemon and activates it locally if absent; UX/frontend CLI retains the Gateway route; mobile hosting does not additionally require standalone CLI/MCP processes on iOS. The UX client accesses its device Gateway, and mobile startup/socket/lifecycle proof remains open.
## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Gateway prepared-view boundaries: inputs, typed preparation and native application](prepared-view-boundaries.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Gateway connection/subscription ownership, multiple Hosts and multiple Gateways, machine-scoped CLI/MCP adapters, explicit target resolution and provider-install entry.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U1/U2/U4/U12/U16/U17/U18.
- Specification: [this design's capability contracts](specification.md), owning K2; apply R1/R3/R7/R11/R12 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS04](../04-terminal-runtime/README.md), [DS06](../06-worktree-fork/README.md), [DS07](../07-agents-context/README.md), [DS08](../08-files-review-output/README.md)

## What this design must settle

- Apply the selected worktree CLI → attached local Host route and absent-local-Host activation. Finish explicit local admission/readiness/failure and frontend-verb classification; Mac CLI remote worktree use is required; direct connection versus local Host relay and its credential remain open.
- Define Host selection, ambiguous/missing targets, cross-Host partial results, per-host failure containment and method exposure.
- Specify CLI package/help/formatting versus backend effects and a deliberate MCP subset; no direct mode or duplicated backend is inferred.

## Result consumed by later designs

Thin frontend adapters over the same operations, with independent Host availability, unambiguous attached-machine execution and declared standalone service-absent outcomes.

## Evidence to reopen

- [Current CLI entry surface and parser boundaries](research/cli-entry-surface.md): 39 source grammar/helper groups, early dispatch, accepted options, submission/output endings and retained helper limits.

- [2026-10-15-daemon-extraction-survey.md](../../research/extraction-survey.md)
- [2026-10-15-daemon-route-performance-experiment.md](../11-operations-integration/experiments/route-performance.md)
- [advisor-many-host-implications.md](../../../../../tmp/practices-research/2026-10-15-daemon-extraction-survey/advisor-many-host-implications.md)

## Proof boundary

Real CLI and client operations through supported entries, two Gateways/one Host and one Gateway/multiple Hosts, target misrouting refusal, one failed Host and independent traffic. E5/E6 plus domain effect witnesses.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
