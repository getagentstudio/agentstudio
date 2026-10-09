# Bridge: native subscription lifecycle is not modeled (design gap)

Status: open. Tracked in Linear LUNA-408 (https://linear.app/askluna/issue/LUNA-408). Recorded 2026-10-09 at the owner's request, after Bridge PR1 (#463). To be designed and fixed after PR1 merges, when the owner has bandwidth. Not part of PR1.

## Summary

The Bridge stability redesign holds up: keyed sealed batches, per-installation authority (E1), one reconciler per surface, explicit region states and the R13 recovery budget all survived the heaviest proof we have. Every PR1 product lane passed on Sunclaw at load 85-120, and each bug found in the final gates was local. None forced a redesign.

What the design did not specify is where those bugs lived. The page side has an explicit lifecycle owner per subscription (Program Design W2, "one per subscription, generic"). The **native** side does not. Its per-subscription lifecycle is the combination of loose containers inside `BridgePaneProductMetadataCoordinator`, and some combinations of those containers are illegal yet reachable.

```
DESIGNED (Program Design)                      NOT DESIGNED (left to implementation)
──────────────────────────                     ─────────────────────────────────────
W2: page-side subscription lifecycle           native-side subscription lifecycle,
W4: atomic batch install                         spread across the coordinator (7 files, 2,588 lines)
File surface reconciler: attempts, outcomes    ordering rules across `await`
Prose rules ("a transient refusal is never       (which work may run between the steps of
  terminal", "lifetimes are separate")            one multi-step transition)
```

## Where the native lifecycle lives today

Measured on #463 at `4b9fd2a4e`:

| Container | Declared at | Write sites |
|---|---|---|
| `subscriptionKindById: [String: BridgeProductSubscriptionKind]` | `BridgePaneProductMetadataCoordinator.swift:54` | 10, in 3 files |
| `deferredOpenSubscriptionIds: Set<String>` | `BridgePaneProductMetadataCoordinator.swift:56` | 10, in 3 files |
| `openedSourceSubscriptionIds: Set<String>` | `BridgePaneProductMetadataCoordinator.swift:57` | 6, in 2 files |
| `bootstrapTaskBySubscriptionId` | `BridgePaneProductMetadataProducerTaskLifecycle` (`+ProducerLifecycle.swift:19`) | via `startBootstrapTask` and completion |

Two other owners hold related state: `BridgeFileSurfaceReconciler` (335 lines; it already models build attempts and outcomes) and the session's subscription and view-scope records.

The state of one subscription is "whatever these containers hold together". Nothing in the types prevents a combination such as *not deferred, not open, no bootstrap task, and an accepted view that expects a source*. That is exactly the stuck state GO19 reached.

## Bugs this gap produced in PR1's final gates

All three were found by hosted 3-core CI or Sunclaw under load, then fixed with deterministic red tests and independently reviewed. Each is an ordering bug, not a logic bug: every step was correct in isolation, but a multi-step transition crossed an `await` and other work ran in between.

| ID | What happened | Shape |
|---|---|---|
| GO11 | A File source open awaited `emit(sourceAccepted)`, which awaited a delivery drain that came after a held step: a circular wait (a reconnect hang on 3 cores). | a transition step waited on work that depended on the transition finishing |
| GO12 | A failed progressive File build failed its current readers, then removed its entry; a reader that arrived after the removal got an unknown-lease error instead of `missingRoot`. | the result of a terminal transition was dropped with the entry |
| GO19 | `resumeForegroundWork` cleared the File's deferred-reopen marker *before* `startSubscriptionOpen`, which backed off on `.rest` because a competing source-less demand attempt existed. That attempt then finished as `.built`, so nothing reopened and the **File view silently stopped updating**. | a marker cleared before the work it promised was committed |

The fixes are correct and minimal, but they are point fixes: each moves one step of one transition into a safe order. The class remains possible wherever the lifecycle is spread across containers.

## Proposed direction (to be designed, not decided)

**Model each subscription's native lifecycle as an explicit state machine.**

- One per-subscription value replaces the loose containers, roughly: `closed`, `opening(task)`, `open`, `pendingReopen(cause)`, `retired`. The exact states come out of the design cycle.
- Transition methods are pure. They take an event and return the next state plus the effects to run (start a bootstrap, request a recovery snapshot, retire).
- Rule: **state change and effect registration happen in one actor turn, before any `await`**. GO19's fix already applied this rule to one transition ("consume the pending reopen only when the bootstrap task registers"), so the pattern is proven in this code.
- Illegal combinations become unrepresentable; the GO19 stuck state cannot be constructed.
- `BridgeFileSurfaceReconciler` already models attempts, so it plugs in as the File build sub-machine rather than being rewritten.
- Proof: the existing behavior suites (File restart, reconnect, PanePublication, construction, the reconciler) are the safety net, plus model-based tests that drive event interleavings through the transition function.

**Difficulty: moderate.** About 26 write sites move, in 3 coordinator files. The hard part is not the enum but the async effects: opening a source is async, so each transition must commit its state and register its effect before awaiting.

It is a production change, so it needs its own design cycle (Requirements and Specification touchpoints, a Program Design element for the native lifecycle, independent review) and its own PR. It should land **before PR2 builds more on this coordinator**.

## Related improvements (same root causes)

| # | Idea | Product | Tests and CI |
|---|---|---|---|
| 1 | Native lifecycle state machine (this doc) | yes | |
| 2 | One writer per status: separate typed statuses for delivery recovery and render health, combined by the region renderer (GO15 showed the render watchdog writing the delivery budget) | yes | |
| 3 | The owner announces, the test awaits: replace remaining polls with owner facts; each missing signal becomes a small production fact (TQ21 is one) | yes, small signals | yes |
| 4 | A reusable test-resource owner for BridgeWeb browser tests (the GO17-R3 idea, built carefully outside a PR crunch) | | yes |
| 5 | A scheduled stress lane (throttled cores plus load), so races surface before a PR's final gate | | yes (CI) |
| 6 | Always-on failure timelines: event ledger plus install and receipt sequence in every failure artifact | yes (telemetry) | yes |
| 7 | Reduce the surface: split the large coordinator and test-support files by responsibility | yes | yes |

## Why PR1 had so many late problems (context for prioritizing)

1. **This gap.** Multi-step native transitions across `await` (GO11, GO12, GO19).
2. **PR1's size.** About 620 commits; product code +72,850/−33,959 across 744 files; tests +41,691/−14,200 across 342 files. A rewrite in one PR means races appear only at the final, expensive gates. PR2 and PR3 should be smaller vertical slices.
3. **Tests that sample instead of awaiting owner facts.** Polls, frame waits, stale DOM rows and leaked harness state failed under load with no product bug (GO13, 14, 16, 17, 18, 20). This was most of the final-day churn.
4. **Proof-environment friction.** The local machine cannot build the merged head (vendor pin); helpers could not pair the native and page halves; some CI failures shipped empty event logs. Each diagnosis needed about an hour of remote gate time.

Only item 1 is a design gap. Item 2 is a delivery-shape choice, item 3 is test-infrastructure debt, and item 4 is tooling.

## References

- Program Design: `docs/specs/2026-09-24-bridge-stability-redesign/2026-09-24-bridge-stability-program-design.md` (W2 at the component table; the "lifetimes are separate" and "transient refusal is never terminal" rules near :251-252).
- PR1: getagentstudio/agentstudio#463.
- GO19 fix: commit `40ab04ab0` ("preserve deferred File reopen until bootstrap registration").
- GO12 fix: commit `c79161e98`. GO11 fix: commit `9078cdd70`. GO15 fix: commits `28d7f5265`, `5e26fb884`.
