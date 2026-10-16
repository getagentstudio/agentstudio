---
name: agentstudio-writing-tests
description: Use when writing, changing, or reviewing any Agent Studio test or test support (Swift Testing, Vitest, Playwright E2E), especially one that waits on async work, a held step, a page, a subprocess, a stream, or a timer, or one written to fix a CI red, so it cannot hang, flake on 3-core CI, or hide its failure cause. Not for production performance proof or choosing an atom or MainActor hop.
---

# Agent Studio: Writing Tests That Keep CI Green

A test is a claim about product behavior, and its verdict depends only on
program logic. CI runs it on three cooperative threads, under load, and never
reruns it, so every red has to explain itself from its own log. Write each test
so it either passes or fails promptly with its cause. It must never hang and
never depend on machine speed. The rules live in
[Testing Architecture](../../../docs/architecture/testing/testing_architecture.md);
this skill is the route through them. Cite the doc, not this file.

## Route (write or review, in order)

1. **Name the behavior.** Write one sentence that a user or caller relies on.
   A test whose only subject is a wait helper, a fixture, or the exact shape of a
   diagnostic payload is out.
   [Test the product, not the harness](../../../docs/architecture/testing/testing_architecture.md#test-the-product-not-the-harness).
2. **Place it.** Put the test in the owning target and lane.
   [Test target ownership](../../../docs/architecture/testing/testing_architecture.md#test-target-ownership),
   [Lanes](../../../docs/architecture/testing/testing_architecture.md#lanes-and-why-they-are-split).
   A test that touches AppKit, a MainActor singleton, a shared datastore, or a
   long-lived bus needs `@MainActor` plus `@Suite(..., .serialized)` and process
   isolation.
   [Process-global state and isolation](../../../docs/architecture/testing/testing_architecture.md#process-global-state-and-isolation).
3. **Write every wait on a fact, then give it an exit for every outcome.**
   - Swift Testing: await an observed state change, the owner's event or typed
     fact (`FactRecorder`), or a `HeldStep`.
     [How a test may wait](../../../docs/architecture/testing/testing_architecture.md#how-a-test-may-wait).
   - Vitest and Playwright: await an application event or a DOM condition
     (`MutationObserver`), or the shared owner waits under `BridgeWeb/tests/e2e/`.
     [BridgeWeb test waits](../../../BridgeWeb/AGENTS.md#test-waits).
   - Then list each way the awaited work can fail to arrive, and give each one
     an exit: the producing task ends, the owner fails for good, or the page or
     process is retired.
     [Every wait has an exit for every outcome](../../../docs/architecture/testing/testing_architecture.md#every-wait-has-an-exit-for-every-outcome).
     Bright line: if the task that should arrive can finish first, the wait must
     end too.
   - If nothing announces completion, the production owner is missing a
     signal. Adding a new event type or coordinator responsibility needs the
     user's approval first ([Hard Rules](../../../AGENTS.md#hard-rules)).
4. **Time and threads.**
   - When time is the subject, drive it with `TestPushClock`.
   - Never use sleeps, polls, turn or time budgets, `waitUntilIdle`, or a raised
     `.timeLimit`.
   - Never block a cooperative-pool thread.
   - In BridgeWeb, never set a per-test timeout.
   [The one rule](../../../docs/architecture/testing/testing_architecture.md#the-one-rule),
   [BridgeWeb test waits](../../../BridgeWeb/AGENTS.md#test-waits).
5. **Keep the evidence.** Keep the primary error before collecting diagnostics.
   Each diagnostic is a handled result, and observed facts stay outside the page
   or process being torn down.
   [Failure evidence survives teardown](../../../docs/architecture/testing/testing_architecture.md#failure-evidence-survives-teardown).
6. **See it fail first.** Make it go red for the stated reason, by reverting
   the fix or by driving the failure through an existing seam. Then make it
   green. A test that cannot fail proves nothing.
7. **Run the gates before calling it done.**
   - Scoped: `mise run test:<lane> -- --filter <suite>`, plus
     `swiftlint lint --strict` and `swift-format lint --strict` on changed Swift
     files. SwiftLint caps function bodies at 100 lines.
   - BridgeWeb: `pnpm -C BridgeWeb run check`.
   - Before a PR: `mise run test` at the exact head.
   - Diagnose a red CI run from its lane report and task dump; never rerun it.
     [When a run is red](../../../docs/architecture/testing/testing_architecture.md#when-a-run-is-red).

## Rationalizations

| Thought | Reality |
| --- | --- |
| "The step always arrives in practice." | Under load on three cores it did not, and the Swift fast lane hung for 600 s. Give the non-arrival an exit. |
| "It passes locally." | A developer Mac has 16 threads; CI has three. A local green proves the logic, not the CI verdict. |
| "A timeout will stop it hanging." | A timeout is a budget. End the wait on the owner's outcome instead. |
| "It's flaky; rerun it." | Make the next failure name its cause. |
| "One more test for the helper." | Test what the product promises. |

## Done when

Writing:

- The test names product behavior and sits in its owning target and lane.
- Every wait has an exit for each outcome.
- It was seen red for the stated reason.
- Scoped lint and the lane pass.
- `mise run test` passed at the PR head.

Reviewing: return each violation with its file and line, the doc section it
breaks, and the concrete failure (a hang, a vacuous pass, or a lost cause). A
violation you cannot tie to one of those is not a finding.
