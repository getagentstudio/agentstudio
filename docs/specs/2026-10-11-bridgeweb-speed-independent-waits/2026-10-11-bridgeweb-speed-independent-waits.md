# BridgeWeb speed-independent test waits

Status: owner-approved direction (2026-10-11, "Yes, all four"). Test infrastructure only; no product code.

## Problem

BridgeWeb tests pass on a fast Mac and fail on the 3-core hosted runner or a loaded proof Mac. On 2026-10-11 alone: two E2E journeys failed at a Playwright 30 s per-step timeout (TQ69 an explicit `timeout:` option, TQ71 a navigation default); a Retry test treated "sent during this time window" as "caused by Retry" (TQ57, fixed in #528). (Correction, 2026-10-11 review: TQ74 was first attributed here to a 1 s `expect.element` poll; it is a different defect, a synchronous `.element()` read that throws inside a DOM-observation helper while the element is momentarily absent, and needs its own fix.)

The rule already exists (`BridgeWeb/AGENTS.md` "Test Waits", `docs/architecture/testing/testing_architecture.md` "One hang bound, never tuned"): a wait completes because an application event, a DOM condition or an owner fact happened; the only elapsed-time bound is the runner-owned hang bound, declared once in shared configuration. Enforcement covers only part of it.

## Where machine speed still leaks in

| How a test waits | Speed-dependent | Counted by the timed-wait lint | Sites (2026-10-11) |
| --- | --- | --- | --- |
| `setTimeout`, sleep helpers, `waitForTimeout` | yes | yes (debt ledger) | 9 after #528 |
| `expect.element` | no in practice: `@vitest/browser` 4.1.10 `processTimeoutOptions` sets the poll timeout to the remaining test time minus 100 ms inside a test (`dist/context.js:125-153`) | n/a | ~560 |
| bare `expect.poll` | yes: Vitest 4.1.10 default `timeout = defaults.timeout ?? 1e3`; our configs set no `expect.poll` | no | ~118 |
| `vi.waitFor` / `vi.waitUntil` | yes: per-call default 1 s, no config default | no | included above |
| Playwright per-step timeouts (`page.goto`, `waitForFunction`, `waitForResponse`, locators) | yes: 30 s default plus explicit `timeout:` options | no | ~202 explicit, plus every default |
| Owner facts (deferreds, recorders) | no | n/a | ad hoc in ~43 files |
| Runner hang bounds (`vitest-hang-bounds.ts`) | only for hangs | n/a | declared once |

## Design

### 1. Shared-config defaults: one hang bound per lane (PR A)
- `vitest.browser.config.ts`: declare `expect.poll` `timeout` from a new shared constant `browserExpectPollHangBoundMilliseconds` in `tests/vitest-hang-bounds.ts`, set below `browserIntegrationTestTimeoutMilliseconds` so the poll's named failure ("Cannot find element with locator …") reports before the generic test timeout. A bare `expect.poll` then waits for its condition until the hang bound instead of 1 s (`expect.element` already uses the remaining test time). Interval unchanged. The E2E config declares its own poll bound the same way, so burning down an explicit E2E poll timeout does not fall back to 1 s.
- Unit and node-integration configs: the same pattern with their own declared constants where `expect.poll` is used.
- Playwright (E2E harness `tests/e2e/bridge-viewer-vite-e2e-browser.ts` and the verifier's `scripts/verify-bridge-viewer-worktree-dev-server/browser-session.ts`): set the context's default action and navigation timeouts to none (`0`). The E2E lane's declared test and hook bounds (600 s / 60 s) and the verifier's journey deadlines remain the only bounds. Several E2E files already do this per page; it moves to the shared launcher.
- No bound is raised to make a test pass; existing per-test `timeout:` options are not touched by this step (they are counted and burned down by step 2).

### 2. Lint and ledger for the hidden budgets (PR A)
Extend `scripts/check-bridgeweb-architecture-timed-waits.ts` to count, as new rule ids in `architecture-debt-ledger.tsv`:
- an explicit `timeout`/`interval` option on `expect.poll`, `expect.element`, `vi.waitFor`, `vi.waitUntil`;
- any `vi.waitFor` / `vi.waitUntil` call (no config default exists; the replacement is an owner fact);
- an explicit numeric or constant `timeout:` option on a Playwright page/locator/wait call in `tests/e2e` and the verifier scripts.
Seed the counts in a new ledger file (`BridgeWeb/architecture-debt-ledger-wait-budgets.tsv`) added to `Tools/AgentStudioArchitectureLint/check-ledger-ratchet.sh`: the merge-base ratchet rejects new rows in an existing ledger and admits only a ledger file absent at the base, so a separate file uses that existing bootstrap without changing the ratchet; from the next PR its rows may only fall. Each rule has permanent fixture tests.

### 3. Shared fact recorder (PR B)
One typed test-support module, `BridgeTestFactRecorder<TFact>`, modelled on the Swift typed-facts harness (`FactRecorder`): `record(fact)`, `waitFor(predicate, label)` (resolves on a matching recorded or future fact), `expectNone(predicate, closingFact)` (a negative proven up to the owner's closing fact), `close(error)` (rejects pending waits with the label and the last recorded facts), and no timer of its own; the runner hang bound covers hangs. Migrate a first batch of the ad-hoc deferred recorders, starting with those #528 introduced (preparation drain observation, DOM observation, context focus, File shell resource, Retry setup-selection fact). Later migrations follow the ledger burn-down.

### 4. Slow mode (PR C, after A)
`mise run test:bridge-web:slow`: the browser lane with a setup file that applies Chrome CPU throttling through Vitest's `cdp()` context API (`@vitest/browser/context`, verified in 4.1.10; Playwright `newCDPSession` underneath) and a worker count of 3; the E2E launcher applies the same throttling through Playwright's CDP session. It reproduces 3-core timing assumptions locally before hosted CI finds them. It is not a pull-request gate; it runs on demand and nightly.

## Sequence
1. #528 merges (it changes the same config, hang-bounds and ledger files).
2. PR A (1 + 2) and PR B (3) in parallel worktrees: disjoint files except `tests/vitest-hang-bounds.ts`, which only PR A edits.
3. PR C after PR A lands, so slow mode exercises the new defaults.

## Proof per PR
- PR A: a planted new site of each new rule fails the lint (red), the ledger equals the counted sites, and `mise run test:bridge-web` passes at the exact head; the failing-run output of a deliberately missing element shows the poll's named failure, not the generic test timeout.
- PR B: each migrated wait keeps its original red (a mutation that removes the fact makes the test fail by label) and passes 3 times; `mise run test:bridge-web` green.
- PR C: slow mode reproduces at least one known timing failure class on the pre-A head and passes on the post-A head.

## Trade-offs
- A genuinely broken test fails at its hang bound (up to ~50–60 s) instead of 1 s. Failure messages still name the locator, label or step.
- DOM-condition polls still poll every 50 ms; the rule allows a DOM condition. A MutationObserver wait stays available where a poll is too coarse.
- Out of scope: the Swift side (already enforced by `agentstudio_no_polling_wait_in_tests`, `FactRecorder` and `TestPushClock`), Swift lane parallelisation (pending the fast-lane profile), and Code quality job speed (owner: lowest priority).
