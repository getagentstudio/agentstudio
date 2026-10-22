# DS11 — Rust standards, operation and integrated design

Start with the [whole migration map](migration-map.md), [hierarchical feature checklist](migration-feature-checklist.md), [operation crosswalk](migration-operation-crosswalk.md) and [near-term remote-session slice](near-term-migration.md). They connect responsibilities and dependencies across both repositories while keeping future detail open.

The [smaller migration branches](migration-detail-branches.md) name native, browser, approval, Git-support and retained-contract paths inside those broad feature homes.

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

System composition, shared Rust crate/dependency graph, toolchain/lints/naming/no-unsafe interpretation, installation and pairing, observability/privacy, shutdown/recovery and integrated proof.

- [Capability acquisition and placement map](capability-placement-map.md): all eighteen surveyed families, their actual data inputs, proposed Host/Gateway/native responsibilities, state/view boundaries and contract gaps.
- [Rust engineering realization](rust-engineering-design.md): concrete workspace/dependency/type/task-custody proposal, with its remaining gaps.
- [Checked Router Rust baseline](research/router-rust-standards.md): inspected conventions and their transfer limits.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U1/U3/U4/U6/U7/U8/U9/U10/U11/U12/U19/U20/U21.
- Specification: [this design's capability contracts](specification.md), owning K15; apply R1/R2/R3/R4/R5/R6/R7/R8/R9/R10/R11/R12/R13/R14/R15/R16 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS06](../06-worktree-fork/README.md), [DS07](../07-agents-context/README.md), [DS08](../08-files-review-output/README.md), [DS09](../09-gateway-cli/README.md), [DS10](../10-swift-client/README.md)

## What this design must settle

- Qualify concrete native/dependency bindings under IP6: first-party unsafe is forbidden, including generated scaffolding; pinned dependencies through safe interfaces are permitted.
- Complete supported artifact/channel/backend/version/privacy/TCC and configuration/credential custody contracts.
- Check shared Tokio lifetime ownership, cross-cycle DAG and error/partial/unknown shapes; define measurable integrated acceptance and hard-cutover boundaries.

## Result consumed by later designs

The composed system Program Design linking the bounded designs, without copying their contracts. Reconcile every entity/owner/interface and the end-to-end public operations before planning.

## Evidence to reopen

- [2026-10-15-daemon-primary-experiments.md](../../experiments/primary-experiments.md)
- [2026-10-15-daemon-extraction-survey.md](../../research/extraction-survey.md)
- [observability_and_traceability.md](../../../../architecture/observability/observability_and_traceability.md)

## Proof boundary

Per-cycle real-path evidence composed with supported installation/start/stop/pairing, compiled lint/type/format/dependency gates, source-scrubbed observability and matched end-to-end performance. All E1-E6 remain proposals until executed; no review or implementation readiness follows from a document split.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
