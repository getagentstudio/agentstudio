# FSEvents overload: Verification Design

Plans how [the Requirements](2026-11-04-fsevents-overload-requirements.md) are shown to hold. It uses the obligations and proof obligations in [the Specification](2026-11-04-fsevents-overload-specification.md) and the seams in [the Program Design trace table](2026-11-04-fsevents-overload-program-design.md#trace-table). This is a plan: nothing in it has been run or observed.

## Proven by

| Requirement | Proven by | Stays unverified |
| --- | --- | --- |
| **U1** "don't do excess work walking the tree" | In a debug build watching disposable repositories, create and remove a worktree inside a watched folder, then count that folder's scans in telemetry: **at most 2 per operation**, and coarse recoveries at least 90% below the v0.0.124 baseline on the same workload. | The owner's real 274-registration workspace isn't replayed; the fixture approximates it. |
| **U2** "don't look at files that don't matter" | Feed bursts of more than 256 changes strictly inside a known checkout into a saturated intake: **no scan** of the watched folder starts. A new Git marker, a removed checkout and a new candidate folder each still start one. | — |
| **U3** "admission, then a debounce" | Drive many triggers, including during a running scan, against a controlled clock: **one** pending obligation per folder, and a scan only after 2 s of quiet. | — |
| **U4** "min 2s, max 30" | Against a controlled clock: no scan sooner than 2 s after the last change or the previous scan. Under a trigger every second for 2 minutes, a scan about every 30 s, never later. | Wall-clock timing on a loaded machine; the clock is controlled. |
| **U5** "add logging and tracing" | The workload's telemetry shows each scan's folder tag, reason, start and completion, wait and folded-trigger count, **with no paths**. | — |
| **U6** "full change and design to properly fix this" | Every row above and below passes on the delivered PR's head. The documents trace every obligation. | — |
| **U7** discovery stays correct | A worktree created during a burst appears after the covering scan. Lost OS events still produce one scan. Adding a folder or refreshing is as immediate as before. Deferred work publishes no absence. | Nested-repository edge cases beyond the scanner's current rules (unchanged by this work). |

## Coverage rows

### Shared observation A: controlled-clock watched-folder actor

`FilesystemActor` runs with `TestPushClock` and the existing fake stream client from `WatchedFolderActorFixture` (`Tests/AgentStudioTests/Core/PaneRuntime/Sources/FilesystemActorWatchedFolderTests.swift`). The fixture already lets tests send batches and overflow recoveries, and wait on admitted watched scans. What it observes: watched-scan submissions to the real `WatchedFolderScanScheduler`, the moments they happen on the controlled clock, and the recorded `watched_scan` telemetry through a recorder fake. It keeps real the actor, the pacing reducer, the topology rule and the scheduler. Only the OS stream and time are replaced. This is the boundary where a wrong pacing or routing build shows up. **Needed case additions:** the fixture must be constructible with `TestPushClock`, and it must expose a submission log with its clock times.

### Shared observation B: watched-folder burst workload (performance)

**`needed:` a lasting journey.** It's a sibling of `verify-git-refresh-performance-workload` (observability doc, "Performance workload"):
- creates disposable fixture repositories and worktrees under one watched folder;
- launches the declared debug build with `run-debug-observability`;
- drives one worktree removal and one creation of at least 100k files;
- queries marker-scoped VictoriaLogs and Metrics for `performance.filesystem.watched_scan` (by phase and reason) and `performance.filesystem.stage_outcome` coarse recoveries.

The same workload runs once against a v0.0.124 build to set the baseline. **Lifetime: lasting.** Any later change to ingress, admission or pacing can bring the storm back.

| U | R | Seam | Observation | Target / journey or reused test | Passes when | Wrong build that fails it | Unverified |
| --- | --- | --- | --- | --- | --- | --- | --- |
| U1 U2 | R1 | `filterBatch` pure; stream client with injected stream factory and a capacity-1 buffer | the batches the client yields; the admitted scans in shared observation A | focused tests at `WatchedFolderTopologyAdmission` and `DarwinFSEventStreamClient`, plus A. Reuses `WatchedFolderTopologyAdmissionTests` (nested Git churn, held destinations, overflow cases at `:202-376`) and extends them over the snapshot. | For more than 256 distinct changes strictly inside a known checkout, the client yields nothing for the watched registration and 0 scans are admitted. A new `.git` marker, a removed checkout root and a new directory outside known checkouts each yield a batch and admit 1 scan. | a build that filters only accepted batches, so overflow still coarsens to a scan; a build that drops the checkout-root removal | the real kernel stream's event shapes beyond what the injected factory sends |
| U3 U7 | R2 | pacing reducer; A | the obligation count per folder; which submitted scan closes it | focused reducer test, plus A | 50 triggers across 10 drains, during a running scan, give exactly 1 open obligation. A trigger after the submission keeps it open after the first scan completes, and exactly one more scan follows. | a build that closes the obligation on any scan completion (it loses the post-start trigger); a build that submits per trigger | — |
| U3 U4 | R3 | reducer `decision(at:)`; A | the submission times on `TestPushClock` | focused reducer test, plus A | A trigger at t=0 with none after gives a submission at t=2 s, not before. With the previous scan completed at t=10, a trigger at t=9.5 gives a submission at t≥12 s. | an undebounced build that submits at t=0; a build ignoring the post-scan gap | wall-clock behavior under load |
| U4 U7 | R4 | reducer forced branch; A | the submission times under a sustained burst | focused reducer test, plus A | With a trigger every 1 s for 120 s, submissions happen about every 30 s, at most ⌈120/30⌉+1 = 5 in total, and no unserved trigger is older than 30 s at any submission. With a submitted scan that never returns a result, the next forced submission still happens by 30 s. | a pure trailing debounce (0 scans during the burst); a build that waits forever on a lost result | — |
| U7 | R5 | `filterBatch` keeps coverage loss; actor overflow path | admitted scans after a loss signal | focused test, plus A (extends `FilesystemActorWatchedFolderTests:11`) | A `UserDropped` observation whose only paths are inside known checkouts opens 1 obligation, giving 1 paced scan. A coarse intake recovery does the same. | a build that filters coverage loss as irrelevant | real `KernelDropped` timing from the OS |
| U7 | R6 | actor explicit-submit path; A | submission times for `initialAdd` and `manual` | A | `initialAdd` and `manual` submit at the trigger time, t+0, and an open obligation is closed by that submission. | a build that paces explicit demands | — |
| U7 | R7 | existing result application; A plus existing discovery integration tests | the published checkout set after the covering scan; absence publication | A, plus reuse of `WatchedFolderObservationCurrentnessTests`, `RepositoryNestedDiscoveryContinuityTests` and `WatchedFolderPublicationHoldIntegrationTests` (they drive real scans in temp repos) | A checkout created during a burst is published after the covering scan. No absence is published while an obligation is open. The existing discovery tests still pass unchanged. | a build that marks a checkout absent from a deferred or incomplete scan | — |
| U5 | R8 | recorder fake in A; production-class Victoria in B | `watched_scan` attributes | A, plus B | Every submission and completion has the folder tag, reason, phase, wait in ms and folded count. No attribute value contains a path separator or a fixture name. | a build that logs paths; a build that records only submissions | — |
| U1 | performance (V9) | B | watched-scan counts per operation; coarse recoveries vs baseline | B, against the debug build of the PR head and against v0.0.124 | At most 2 `watched_scan` phase `submitted` with reason `relevantChange` or `*CoverageLoss` per operation for the watched folder, and coarse recoveries at least 90% lower than the v0.0.124 run on the same fixture. | the current main (v0.0.124 behavior) | the owner's real workspace size; other volumes |
| U6 | all | the documents and the PR | structural | the four documents' trace; the PR's gate run | Every R1–R8 row passes on the PR head and `mise run test` passes there. | — | — |

### Tests whose expectations change

These are the existing tests that today assert an **immediate** scan after a callback or overflow, such as `FilesystemActorWatchedFolderTests` "one ingress batch records multiple watched overflow admissions once". They become paced expectations on `TestPushClock`. That's the intended behavior change (R3), not a weakened proof. Every such test keeps its scan-count assertion, now taken after the pacing deadline.
