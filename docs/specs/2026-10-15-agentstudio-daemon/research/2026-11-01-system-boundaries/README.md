# System boundaries and execution continuity

Open the [HTML walkthrough](index.html). It connects the existing AgentStudio feature map to Host, Gateway, provider execution, task control and messaging responsibilities. The [experiment page](experiments.html) shows what actually ran.

This is a research supplement to the [daemon design set](../../index.md). The direct owner decisions below constrain subsequent design. Proposed process placement, interfaces and qualification cases still need the owning design documents and review; this folder is not an implementation plan.

## Decisions carried forward

- Active provider turns continue through a planned Host upgrade. Qualify independent execution custody.
- Support standalone and board-linked delegation, with durable execution identity, outcome and recovery in either case.
- Keep loose messaging separate from task control. Message delivery, provider settlement and accepted task completion have distinct meanings.

Stopping one execution versus its owned delegation tree remains an open owner choice. It does not block the source inventory, interface research or the completed bounded experiment.

## Reading paths

| To understand | Start here | Detail |
| --- | --- | --- |
| Responsibilities and existing features | [System map](index.html) | [Capability boundary map](capability-boundary-map.md) |
| Reusing control across CLI, MCP and ACP | [Shared agent control](acp.html#shared-control) | [Checked reuse update](../2026-11-02-acp-control-reuse.md); the adjacent ACP Lead owns the governing design |
| Commands, facts, transactions and results | [Follow work and data](tasks.html) | [Source findings](research-ledger.md) |
| Typed interfaces and dependency direction | [Rust interface boundaries](rust-interface-boundaries.md) | Current Router source anchors are linked there |
| The selected upgrade outcome | [Execution lifetime](lifecycle.html) | [Qualification input](continuity-qualification.md) |
| What actually ran | [Native experiment](experiments.html) | [Results](native-continuity-results.md), [structured evidence](native-continuity-result.json), [retained inputs](inputs/README.md) |

The native experiment supports one precise result: a real command and the same native turn completed after their requesting CLI exited with SIGKILL, with an event observer retained as prototype custody. Full Host upgrade, last-subscriber loss, provider-process incarnation, pending approvals, durable task recovery and other target/provider profiles remain unqualified.

## Artifact roles

The HTML pages explain the model and observed evidence. The Markdown companions carry source anchors and contract gaps. The JSON result and filtered event records preserve the actual qualification evidence. Scripts in `inputs/` are exact executed snapshots, not a portable verification suite.

The existing daemon specifications and source inventory remain in their owning folders. No migration checklist item is completed by this research. Product source and configuration were unchanged; no Rust/Swift product build or test suite ran. Process history remains in `tmp/practices-research/2026-11-01-system-boundaries/`.

The five HTML reader pages contain their content inline and must travel together. The shared-control page is generated from `acp.source.html` and `../2026-11-02-acp-control-reuse.md`; retain those authoring inputs and regenerate after editing them. The other four pages remain authored inline. Demistify v1 theme, runtime, chunks and fonts require network access. Static authoring checks do not establish browser rendering or interactive walkthrough behavior.
