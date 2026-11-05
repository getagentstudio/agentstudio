# FSEvents overload: Verification Design (Swift stopgap)

Plans how [the Requirements](2026-11-04-fsevents-overload-requirements.md) in this delivery are shown to hold. It uses the obligations in [the Specification](2026-11-04-fsevents-overload-specification.md) and the seams in [the Program Design trace table](2026-11-04-fsevents-overload-program-design.md#trace-table). This is a plan: nothing in it has been run or observed. The tiers (U8) and the platform-neutral source (U9) are proven by the daemon spec, not here.

## Proven by

| Requirement | Proven by | Stays unverified |
| --- | --- | --- |
| **U1** "don't do excess work walking the tree" | A debug build watches disposable repositories. We remove and create a fixture worktree inside the watched folder, each as one continuous operation under 10 s, and count completed scan runs in telemetry: **at most 2 per operation**, with coarse recoveries at least 90% below v0.0.124 on the same workload. | The owner's real ~270-registration workspace isn't replayed. Cancelled runs with no result aren't counted. |
| **U2** "don't look at files that don't matter" | Bursts of more than 256 routine changes inside a known checkout, plus folders the scanner never visits (too deep, under hidden directories), go through both a normal and a saturated intake: **no scan run**. The positive controls still start one: a new `.git` marker, a removed worktree, a new candidate folder, a `HEAD`/`config`/`commondir` change, and an unknown `.git` entry. | — |
| **U3** "admission, then a debounce" | Against a controlled clock, many triggers, including some during an in-flight submission and some during a running scan, leave **one** obligation per folder. It closes only when a run submitted after the last trigger completes. | — |
| **U4** "2s debounce, max wait 10s" | Against a controlled clock: no submission sooner than 2 s after the last change. Under a trigger every second for a minute, one becomes eligible every 10 s, and never later. | Wall-clock timing on a loaded machine. |
| **U5** "logging and tracing" | Telemetry from the workload shows **demand** records (reason, wait, folded triggers) and **run** records (run generation, duration), with no paths. | — |
| **U6** full fix | Every row passes on the delivered PR's head. | The daemon part is proven by its own spec. |
| **U7** discovery stays correct | A restored worktree is never marked gone by an older scan. Lost OS events still produce one run. Adding a folder or refreshing is immediate. The existing discovery tests still pass, with the adaptations listed below. | Nested-repository edge cases beyond the scanner's current rules. |

## Coverage rows

### Shared observation A: controlled-clock watched-folder actor

`FilesystemActor` runs on `TestPushClock` with the fake stream client from `WatchedFolderActorFixture` (`Tests/AgentStudioTests/Core/PaneRuntime/Sources/FilesystemActorWatchedFolderTests.swift`). It drives the real `WatchedFolderScanScheduler`, `WatchedFolderScanPacing` and `WatchedFolderTopologyAdmission`, and observes demand submissions with their clock times, results applied, the newest-demand marker, and `watched_scan_demand` / `watched_scan_run` records through a recorder fake. **Case additions needed:**
- the fixture must be constructible with `TestPushClock`;
- it must expose a submission log;
- it must let a test hold the scheduler's result for one run.

### Shared observation B: real-scanner currentness

This reuses `WatchedFolderObservationCurrentnessTests` (`Tests/AgentStudioTests/Integration/`). It already builds a real `FilesystemActor` over temporary roots and checks dependent-observation invalidation, using controlled scheduler results. **Case addition needed:** a production `RepoScanner` run held after it passes a candidate directory, so the stale-absence window crosses real traversal.

### Shared observation C: watched-folder burst workload (performance)

**`needed:` a lasting journey.** It's a sibling of `verify-git-refresh-performance-workload` (observability doc, "Performance workload"):
- disposable fixture repositories and worktrees under one watched folder;
- the declared debug build launched through `run-debug-observability`;
- one fixture worktree removal and one creation, each continuous, with no internal pause of 2 s or more, completing in under 10 s;
- marker-scoped VictoriaLogs and Metrics queries for `watched_scan_run` counts by run generation, and `stage_outcome` coarse recoveries.

The same fixture runs once against v0.0.124 for the baseline. **Lifetime: lasting.** Any later ingress or pacing change can bring the storm back.

| U | R | Seam | Observation | Target / reused test | Passes when | Wrong build that fails it | Unverified |
| --- | --- | --- | --- | --- | --- | --- | --- |
| U1 U2 | R1 | `filterBatch` pure; stream client with injected stream factory and a capacity-1 buffer; A | yielded batches; runs started | extends `WatchedFolderTopologyAdmissionTests` (routine `:60-91`, discovery-sensitive `:93-133`, held paths `:288`, overflow `:321-376`) over the snapshot, plus a client test that holds an old snapshot during root removal, a new checkout and a hold release | Routine content, ordinary files, too-deep folders and folders under hidden directories yield no batch and start 0 runs on both paths. Each positive control in Specification V1 yields a batch and starts 1 run. | a build filtering only accepted batches; a build dropping `HEAD` or `commondir`; a build treating `.git` itself as hidden | the real kernel's event shapes beyond the injected factory |
| U3 U7 | R2 | reducer; A | obligation state; which run closes it | focused reducer test, plus A | 50 triggers over 10 drains give 1 obligation. A trigger during the submission await keeps it open, and the marker stays cleared. A run submitted before the last trigger doesn't close it. A stale-dropped run's demand reaches a later covering completion, which closes it. | a build closing on submission; a build closing on any completion; a build setting the marker after a mid-await trigger | — |
| U3 U4 | R3 | reducer `decision(at:)`; A | submission times on `TestPushClock` | focused reducer test, plus A | A trigger at t=0 with none after gives a submission at t=2 s, not before. Triggers at t=0 and t=1.5 give t=3.5. | an undebounced build that submits at t=0 | wall clock under load |
| U4 U7 | R4 | reducer maximum-wait branch; A | submission eligibility under a sustained burst | focused reducer test, plus A | With a trigger every 1 s for 60 s, an eligible submission occurs at each 10 s of oldest-trigger age, at most 7 in total. Eligibility isn't delayed by quiet. | a pure trailing debounce (0 during the burst); a build with no maximum wait | actual start time under a long single-flight run (by design, eligibility only) |
| U7 | R5 | `filterBatch` coverage loss; actor overflow path; A | runs after a loss signal | focused test, plus A (adapts `FilesystemActorWatchedFolderTests:11`) | A `UserDropped` signal with only in-checkout paths, and a coarse intake recovery, each open 1 obligation and give 1 run after the debounce. | a build that filters coverage loss as irrelevant | real `KernelDropped` timing |
| U7 | R6 | actor explicit path; A | submission times; obligation closure | A | `initialAdd` and `manual` submit at t+0, and their completed run closes a covered obligation. | a build debouncing explicit demands | — |
| U7 | R7 | the newest-demand marker; B | the authority of old and overlapping receipts | B (extended), plus `WatchedFolderPublicationHoldIntegrationTests` (adapted: its `:83-93` admission check moves after the debounce; its hold semantics are unchanged) | After a late trigger, with the clock **not** advanced, the old run's result applies positive-only. Neither its own receipt nor an overlapping one is current. After the covering run, both are authoritative again. A non-overlapping root's authority is unaffected throughout. | a build that clears the marker only at submission (the review's blocker) | — |
| U5 | R8 | recorder fake in A; Victoria in C | demand and run records | A, plus C | Every accepted demand has tag, reason, wait and folded count. Every completed run has tag, run generation, the demand generation served and duration. No value contains a path separator or a fixture name. | a build counting submissions as runs; a build logging paths | — |
| U1 | performance (V9) | C | completed runs per operation; coarse recoveries against the baseline | C, against the PR head's debug build and against v0.0.124 | At most 2 completed runs per operation for the watched folder, and coarse recoveries at least 90% below the v0.0.124 run on the same fixture | current main (v0.0.124 behavior) | the owner's real workspace size; other volumes; cancelled runs without a result |
| U6 | all | documents and PR | structural | the four documents' trace; the PR's gate | Every R1–R8 row passes on the PR head, and `mise run test` passes there. | — | the daemon part |

### Tests whose expectations change, and how

- **Scan-start timing assertions** that today expect an immediate scan after a callback or overflow (for example, `FilesystemActorWatchedFolderTests` "one ingress batch records multiple watched overflow admissions once") move to after the debounce deadline on `TestPushClock`. They keep their counts. This is the intended R3 change.
- **Validity or invalidation assertions** (for example, `WatchedFolderObservationCurrentnessTests:36-42`) **stay immediate**. Under R7, invalidation happens at the trigger, not at submission, so these must not move after the deadline. Moving them would weaken the proof.
