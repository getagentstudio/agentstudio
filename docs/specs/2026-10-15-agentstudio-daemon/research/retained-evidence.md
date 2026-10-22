# Research that travels with this design

The design keeps its source surveys and bounded experiment reports under `research/evidence/`. Their recorded dates, source pins and proof limits still apply. Preserving a report does not adopt an old proposal or turn a source check into runtime proof; current Requirements and the owning contracts remain authoritative.

Use the [research library](../explainer/research.html) to read the reports as HTML, or [all documents](../documents.md) for their Markdown sources. The [retention manifest](evidence-manifest.json) records each original path and hash, its current home and hash, and whether only Markdown link destinations were adapted.

## What is preserved

- **Capability and operation surveys:** commands, Bridge/annotation operations, agents, Git/worktrees, terminal behavior and platform boundaries.
- **Storage evidence:** schema/column inventories, ordinary writers and readers, transaction groups, key constraints and proposed data placement.
- **Experiment reports:** observed backend restoration, coordination, contraction and handoff outcomes, together with their stated target and limits.

The initial retained set contains 80 files: 70 source surveys and 10 experiment-observation reports. The two later Capture-results/next-experiments sources are a separately recorded delta. Originals remain available in this worktree; readers and spec links use the retained homes.

## What still needs local evidence

Large raw archives, per-case payloads, probe drivers and some transitive evidence are not bundled here. Reports can therefore remain readable from a checkout while a runtime claim still needs its separately retained raw evidence. The manifest does not certify a complete replay bundle.

Fifteen mixed owner/advice/review records remain in scratch as historical provenance. Their source-only sections have been inventoried, but are not copied wholesale into the design: extracting them can lose their source pin, supersession or advice context. The current [Bridge owner quotations](owner-inputs/bridge-transport-direction-2026-10-22.md) are preserved in their attributed input record. Review history, commissioning and discussion stay outside the design. Their presence in the local reader is historical context, not an additional specification or owner approval.
