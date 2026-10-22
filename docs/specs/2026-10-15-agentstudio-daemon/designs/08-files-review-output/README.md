# DS08 — Files, reviews, annotations and output

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [All 16 Bridge semantic calls: source work versus native application](bridge-operation-map.md).
- [All 22 annotation operations: state, edit custody and output](annotation-operation-map.md).
- [Client data needs: metadata, finite content and native application](client-read-needs.md).
- [Direct browser/Gateway transport: requirements, contracts, structure and proof](../../increments/00-qualification/bridge-gateway-transport/index.md).
- [Structural proposal: annotation output across Host and native client](annotation-output-lifecycle-design.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

File/review products, finite content, source/revision currentness, annotation drafts/edit ownership, immutable prepared output and effect/finalization outcomes.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U3/U4/U9/U13 and S32/U25 for browser delivery.
- Specification: [this design's capability contracts](specification.md), owning K9, K10; apply R2/R4 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS05](../05-git-discovery/README.md)

## What this design must settle

- Select exact content/name/size/version/currentness and cancellation boundaries.
- Preserve exact output membership, saved revisions, edit fences and atomic finalization.
- Define destination locality, consent/refusal, effect-before-finalization failure and uncertain repeat without automatically replaying a native effect.

## Result consumed by later designs

Content and annotation contracts whose domain work stays at the addressed Host and whose declared native destinations remain client effects. Output bytes, effect and SQL finalization are separate observations.

## Evidence to reopen

- [bridge-surface-inventory.md](../../research/evidence/2026-10-15-daemon-extraction-survey/bridge-surface-inventory.md)
- [capability-bridge-output-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/capability-bridge-output-evidence.md)
- [data-client-review-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/data-client-review-evidence.md)

## Proof boundary

Actual source bytes/currentness races, annotation transactions and exact output destination bytes/residue, including known external success with failed SQL finalization. E2/E5; digest correctness is not rendered-pixel proof.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
