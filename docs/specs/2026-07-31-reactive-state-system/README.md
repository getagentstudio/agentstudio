# Reactive State System — Program Design

This is the family-level Program Design: the integrated structural How for the
reactive-state work. Read Requirements for the authorized need, Specification
for the observable contract, then only the linked slice design that owns the
internal implementation question.

## Current Implementation Authorization

The current goal is authorized to implement exactly two pull requests:

```text
PR 1  AtomFamily + lazy DerivedAtom
      └── Repo Explorer keyed worktree-facts admission

PR 2  cancellation-only EagerDerivedAtom + EagerDerivedAtomFamily
      └── keyed per-tab projection + coherent Tab Bar publication
```

For this goal, the Requirements and Specification govern only through the
PR-specific obligations realized by the two active Program Designs below.
Their broader future-system context does not authorize implementation.
RS-15–RS-20, every persistence implementation, and deferred pane, tab,
topology, session, terminal-activity, Feature-worker, and Command Bar
migrations are outside this goal.

## Entry Point

[Reactive State System Requirements](2026-07-31-reactive-state-system-requirements.md)
is the authoritative Why: affected people, authorized needs, priorities,
boundary, and non-goals.

[Reactive State System Specification](2026-07-31-reactive-state-system-specification.md)
is the authoritative What: problems, outcomes, normative requirements
RS-01–RS-28, observable contracts, failure behavior, and proof obligations.

## Active Program Designs

| Program Design | Governing subset for this goal | Read when deciding internal How |
|---|---|---|
| [Reactive Atoms and Derived Values](2026-07-31-reactive-atoms-and-derived-values-program-design.md) | RS-01–RS-08, RS-10, and slice-specific RS-21–RS-28 only as realized by its PR 1 boundary | Source ownership, `AtomFamily`, lazy `DerivedAtom`, keyed observation, or Repo Explorer's keyed worktree-facts admission |
| [Off-Main Materialization and Lifecycle](2026-07-31-off-main-materialization-and-lifecycle-program-design.md) | RS-03–RS-05, RS-09–RS-14, and slice-specific RS-21–RS-28 only as realized by its PR 2 boundary | `EagerDerivedAtomFamily`, checked transfer, keyed latest-wins lifecycle, coherent Tab Bar publication, or its required proof |

RS-21–RS-28 are cross-cutting. Each active design owns only the guardrail,
observability, and proof realization for its slice; none introduces a parallel
lint, telemetry, benchmark, debug-launch, or test framework.

## System Map

```text
Requirements — authoritative Why
  -> Specification — authoritative What
       -> Program Design
            -> Reactive atoms — source and lazy graph HOW
            -> Off-main materialization — replaceable CPU projection HOW

Both active Program Designs extend the existing ArchitectureLint, debug IPC/UI,
Victoria/comparator, and test systems. Neither creates a parallel system.
```

## Integrated Ownership and Proof

| Accepted need | Observable contract | Structural owner | Existing proof system extended |
|---|---|---|---|
| U1, U2, U4 | Key isolation, coherent mutation, current lazy/eager output | Core/Feature product owners over Infrastructure atom primitives; App only where cross-Feature composition is required | Swift Observation behavior suites and ArchitectureLint |
| U3 | Compatibility across each hard cut | The product owner of the selected source or projection | Isolated debug interaction plus supported-state inspection and relaunch |
| U5 | Checked off-main replaceable computation | Product capture/projector plus retained keyed `EagerDerivedAtomFamily` lifecycle | Compiler-negative transfer proof and deterministic overlap/cancellation tests |
| U6, U7 | Honest enforcement and provenance-bound evidence | Existing ArchitectureLint, trace tags, Victoria workload, and comparator owners | Static, semantic, runtime, and matched-distribution gates at their actual boundaries |
| U9 | Narrow independently provable adoption | Each linked slice; no family-wide runtime coordinator | Slice inventory through the existing lint, test, debug, and performance systems |

## Pull-Request Boundary

PR 1 does not depend on eager materialization or persistence changes. PR 2
depends on the cancellation-only eager node and keyed eager-family primitive,
plus only the tab-scoped source-family corrections required to preserve
unrelated-tab isolation. It does not depend on the SQLite design or broader
pane/tab family migrations. The measurement correction described by the
off-main design is a PR 2 proof prerequisite, not a third reactive-state
implementation PR.

No third implementation slice may be added to this goal. Additional reactive or
persistence work requires separate scope authorization after these two PRs.

## Deferred Follow-Up

The [SQLite authority design](follow-ups/2026-07-31-sqlite-authority-and-update-boundaries-program-design.md)
is retained only as follow-up design context. It is not a governing input,
dependency, task source, or proof obligation for PR 1 or PR 2.

## Shared Proof Boundaries

| Concern | Existing proof system to extend |
|---|---|
| Source/derived declaration and target direction | Existing `Tools/AgentStudioArchitectureLint`; add the required executable compile-negative driver because the current excluded fixtures alone are not proof |
| Semantic observation | Swift Testing suites using real Swift Observation |
| Native behavior | Worktree-isolated LaunchServices debug app, authenticated debug IPC, and native UI inspection |
| Performance | Existing Victoria workload summaries and provenance-enforcing comparator, after the PR 2 measurement corrections make hot attributes lazy, report trace-queue completeness, and add interaction-to-visible/current-result boundaries |
| Telemetry safety | Existing OTLP allowlist and fail-open suites |

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

Program designs define seams and obligations. A later implementation plan owns
exact tasks, commands, ordering, and evidence locations.
