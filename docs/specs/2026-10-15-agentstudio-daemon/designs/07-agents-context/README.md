# DS07 — Agents, provider input and retained context

## Read this folder

- [Folder HTML reader](index.html).
- [Specification: Markdown](specification.md) · [HTML](specification.html).
- [Context counts: Host classification, Gateway view composition and exact internal family values](context-count-preparation.md).
- [Shared Requirements](../../user-requirements.md) · [overall Specification](../../2026-10-15-agentstudio-daemon.md).

Provider evidence, conversation/binding provenance, Host-local authorized hooks, title/line ordering, notices, asks, answers and retained settlements independent of pane presence.

## Contract and inputs

- Requirements: [shared authoritative source](../../user-requirements.md), scoped to U4/U9/U13/U15.
- Specification: [this design's capability contracts](specification.md), owning K7, K8; apply R2/R6/R9/R10 and the shared [observable spine](../../2026-10-15-agentstudio-daemon.md).
- Domain definitions: [global identity appendix](../../domain-entities.md) and E1–E6 in the spine. This folder creates no new identity merely by being separate.
- Required contract inputs: [DS04](../04-terminal-runtime/README.md), [DS05](../05-git-discovery/README.md)

## What this design must settle

- Set exact method/scope/credential contracts while preserving authorized input with Swift and every Gateway (macOS or iOS) absent.
- Preserve message/binding/intake-cursor atomicity, answer versus EOF/deadline races and stale writer refusal.
- Classify baseline CLI notice queues without inventing a universal outbox, hook spool or exactly-once operation journal.

## Result consumed by later designs

One Host-local admission and retained-workflow contract with distinct provider/session/binding/request identities and operation-specific duplicate/uncertain outcomes.

## Evidence to reopen

- [Host-local agents and context lifecycle proposal](host-context-lifecycle-design.md)
- [2026-10-15-daemon-host-autonomy-experiment.md](experiments/host-autonomy.md)
- [data-agent-context-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/data-agent-context-evidence.md)
- [e2-agent-admission-evidence.md](../../research/evidence/2026-10-15-daemon-extraction-survey/e2-agent-admission-evidence.md)

## Proof boundary

Actual provider-shaped input, stale-generation and denied-scope cases, retained notice/ask outcomes and failed cursor commits, including no-view/no-Gateway operation. E2/E3.

## Design cycle

Use the [common cycle and completion rule](../README.md#each-design-cycle). The scoped Specification here contains carried-forward draft contracts, not a completed Program Design. Author its structural realization after the affected meaning is settled, then complete Verification Design and independent four-document review. Bring only actual unresolved owner decisions to Sun; there is no generic structural-confirmation gate. There is no empty `program-design.md` standing in for unfinished work. Required missing meaning remains explicit, and unrelated source research can proceed.
