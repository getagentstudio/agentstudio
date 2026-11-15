# LUNA-581 Swift stopgap: implementation plan

## Canonical record

```text
plan path: docs/specs/2026-11-04-fsevents-overload/plans/2026-11-05-fsevents-overload-stopgap.md
originating planner: plan-implementation
supersedes: none
planning result: ready
governing planning basis:
  kind: reviewed-four-document-design
  Requirements:        docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-requirements.md
  Specification:       docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-specification.md
  Program Design:      docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md
  Verification Design: docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md
  review result: spec-program-review four-document-design, integrated verdict READY at
    648ccdc4e3439e9bc9f3ba8148fa1dda587cc934 (Reviewer 01a17b21;
    agentstudio.a1-frames/tmp/gate/review-luna581-design-r1.md, -r2.md, -r2-verify.md, -r3.md)
  current applicability anchors: design branch fix/fsevents-overload at 648ccdc4e;
    product source unchanged since origin/main e196a7ec6 (fetched 2026-11-05, no new commits)
delivery context:
  requested terminal: pr-ready-unmerged, then merge and release (stable + beta) under the
    owner's standing merge/release grant, through implementation-pr-wrapup
  delivery grouping: single:luna-581-swift-stopgap
  PR topology: one-pr
  repositories: github.com/getagentstudio/agentstudio (this repository only)
```

Planned at: branch `fix/fsevents-overload`, HEAD `648ccdc4e`, base `origin/main` `e196a7ec6`.

## Goal and scope

A burst of file activity inside a watched folder costs a small, bounded number of watched-folder scans; changes that can't affect discovery cost none; discovery stays correct (Requirements goal boundary). This PR delivers the Swift stopgap only: R1–R8 of the Specification.

**Non-goals (from Requirements and U11):** tiers (U8), the injected platform-neutral source (U9), directory-level discovery events, LUNA-514 crash diagnostics, incremental scanning, global name ignores, visibility gating, a larger queue or longer latency.

**May change:** `Sources/AgentStudio/Core/RuntimeEventSystem/Filesystem/`, `AppPolicies.WatchedFolderScanning`, the OTLP taxonomy for the three new records, their tests, and one new mise task plus script for the V9 journey.

## Current evidence (verified at e196a7ec6)

- Rule owner: `WatchedFolderTopologyAdmission.swift` (115 lines). `shouldScan` `:17-58`, `mayAffectTopology` `:90-93`.
- Client: `DarwinFSEventStreamClient.swift` is **986 lines**; `emitRawEvents` yields unconditionally at `:619-650`. New client code goes in a new extension file, not this file.
- Actor: `FilesystemActor.swift` is **937 lines**; overflow recovery `:424-510`; Git-lane debounce pattern `drainPendingChanges` `:525-657`. New pacing code goes in `FilesystemActor+WatchedFolderScanPacing.swift`, not this file.
- Actor already has a generic-clock `init<C: Clock>` beside the production init (`FilesystemActor.swift:133`), and `FilesystemActorSchedulingTests` already drives it with `TestPushClock`.
- `FSEventStreamClient` (`FSEventStreamClient.swift:181-210`) already gives optional members default no-op bodies in a protocol extension. Conformers: `DarwinFSEventStreamClient`, `ControllableFSEventStreamClient`, `FilesystemFencedStreamClient`, `FetchHeadSilentFSEventStreamClient`, `SilentFSEventStreamClient`.
- Fixture: `WatchedFolderActorFixture` (`FilesystemActorWatchedFolderTests.swift:711`) builds the scheduler with `now: { .zero }` and the real acceptance gate (`WatchedFolderScanAcceptanceGate`); it has no clock parameter today.
- Sibling journey to copy: `.mise.toml:868` `verify-git-refresh-performance-workload` → `scripts/verify-git-refresh-performance-workload.sh` (LogsQL at `127.0.0.1:9428`).

## Proof layers

Source: `CLAUDE.md` (Daily Commands, Proof, No Wall-Clock Tests) and `docs/architecture/testing/testing_architecture.md`. Focused lanes: `mise run test:swift -- --filter "<function id>"` (filter by **function identifiers**, not display names). PR gate: `mise run test` and `mise run lint` on the PR head, prefixed with the Xcode-27 `DEVELOPER_DIR` on Sunbook. Waits use `FactRecorder`, the acceptance gate and `TestPushClock`; no sleeps, yields-in-loops, or time budgets.

## Slices

```text
S1 contract+vertical  filterBatch over the snapshot (pure)
S2 vertical           client snapshot handoff + actor publishes snapshots      requires S1
S3 contract           WatchedFolderScanPacing reducer + policies (pure)        parallel S1||S3
S4 integration        actor wiring: triggers, pacing task, overflow routing,
                      one submission protocol, result rule                     requires S2, S3
S5 vertical           R8 telemetry records                                     requires S4
S6 journey (Verifier) V9 burst workload + v0.0.124 baseline                     parallel with S1-S5;
                                                                               head run requires S5
```

`S2 <-> S4` and `S4 <-> S5` are serial: they write the same actor extension files. One PR; one Implementer Sidekick owns S1–S5 serially in the fix worktree. **Batch boundary:** after S5, the paired Verifier observes V9 on the PR head; wrap-up starts after that observation reports.

### S1: one relevance rule over the admission snapshot (R1, R5 filter part)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-specification.md "Entities" (E2, E4, E5) and "Proof obligations" (V1); docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "Entities and where they live" (E2, E4 rows) and "Interfaces" (`filterBatch`); docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md row R1 and row R5.
- **Write surfaces:** `WatchedFolderTopologyAdmission.swift` (add `WatchedFolderAdmissionSnapshot`, `filterBatch(_:snapshot:)`, `shouldScan(_:snapshot:)` as `filterBatch != nil`); `WatchedFolderTopologyAdmissionTests.swift`.
- **Pre-change signal:** today a >256-path routine burst inside a known checkout becomes a coarse recovery that `mayAffectTopology` admits; a filter that drops `HEAD`/`commondir` or treats `.git` itself as hidden would also pass a naive test.
- **Focused proof (oracle: Specification E4 (a)–(d) and V1; scanner bounds `RepoScanner.defaultMaxDepth = 4`, `.skipsHiddenFiles`):** one **table** over the rule — rows for routine content, ordinary files, depth 5, under a hidden directory (each → `nil`), and each V1 positive control: new `.git` marker, removed worktree root, new candidate folder, `HEAD`, `config`, `commondir`, unknown `.git` entry, coverage-loss observation with only in-checkout paths (each → batch kept with that path). The existing rule rows (`:60-91`, `:93-133`, `:288`, `:321-376`) re-run over the snapshot.
- **Rows earned (partial):** R1 pure half; R5 filter half.
- **Quality:** `mise run lint`; `mise run test:swift -- --filter <WatchedFolderTopologyAdmissionTests function ids>`.
- **Stop:** if E4 can't be expressed per path without the inventory beyond `knownCheckoutPaths`, return `program-design-gap`.

### S2: snapshot handoff into the client (R1 source half)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "Interfaces" (`updateWatchedFolderAdmission`), "Components" (forbidden edges), "The main path" steps 1–3 and 10, "Holds and registration", the failure rows for a stale snapshot; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md row R1.
- **Write surfaces:** `FSEventStreamClient.swift` (requirement `updateWatchedFolderAdmission(worktreeId:snapshot:)` with a default no-op body in the existing protocol extension, matching how the other optional members are declared); new `DarwinFSEventStreamClient+WatchedFolderAdmission.swift` (snapshot map under `lifecycleLock`, `filterBatch` before `ingressBuffer.yield` in `emitRawEvents`, the one-line call site in `DarwinFSEventStreamClient.swift` only); actor extension `FilesystemActor+WatchedFolderScanning.swift` (publish on register, on inventory change `ResultApplication:139-152`, on hold change, clear on unregister); `ControllableFSEventStreamClient.swift` records received snapshots.
- **Decision (reversible, recorded):** a default no-op body instead of a bare requirement. It matches the protocol's existing idiom and keeps silent test clients unchanged; the Darwin client and the controllable fake implement it.
- **Pre-change signal:** a build filtering only accepted batches (today's shape) still yields the routine burst into the 512-slot buffer.
- **Focused proof (oracle: R1, Program Design interface "applies to callbacks that start after it returns"):** a client test with the injected stream factory and a **capacity-1** ingress buffer: a routine burst yields no batch and leaves capacity free; holding an old snapshot during root removal, a new checkout and a hold release each still yields the relevant batch; `nil` snapshot yields unfiltered.
- **Rows earned:** R1 (complete with S4's "0 runs started" on the actor path).
- **Stop:** if the filter's callback cost exceeds 1 ms median in the ingress snapshot (Program Design reopen signal), stop and report.

### S3: the pacing reducer (R2 reducer, R3, R4)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-specification.md "Requirements" R2–R4 and "Observable contract"; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "Entities and where they live" (E6 row and policy constants), "Interfaces" (`WatchedFolderScanPacing`, eligibility), "The obligation's lifecycle" diagram and illegal states; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md rows R2, R3, R4.
- **Write surfaces:** new `FilesystemActor+WatchedFolderScanPacing.swift` (`WatchedFolderScanPacing`, `PacedScanObligation`, `OpenInterval`, `InFlightSubmission`, `WatchedFolderPacingDecision`, `WatchedFolderPacingClosure`, `WatchedFolderScanTriggerReason`, exactly as the Program Design binding table names them); `AppPolicies.swift` `WatchedFolderScanning.changeDebounce = .seconds(2)`, `changeMaximumWait = .seconds(10)`; new `WatchedFolderScanPacingTests.swift`.
- **Pre-change signal:** an undebounced reducer submits at t=0; a pure trailing debounce submits 0 times during a 60 s burst; a reducer closing on submission closes before its run.
- **Focused proof (oracle: U4 owner values, Specification R2–R4):** reducer tests with explicit `now` values: t=0 → submit at 2 s; t=0, 1.5 → 3.5 s; trigger every 1 s for 60 s → eligible at each 10 s of oldest-trigger age, at most 7; 50 triggers over 10 decisions → one obligation; a trigger while `submitted` → pending interval; `recordRunCompleted` with older coverage → `notCovered`. Plus one **seeded deterministic property**: for generated trigger traces, eligible submissions never exceed 1 + k + ⌈D/10⌉ of that trace. The property is the plan's own focused proof; it doesn't stand in for V9.
- **Rows earned (partial):** R2, R3, R4 reducer halves.

### S4: actor wiring and the one submission protocol (R2–R7)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-specification.md "Requirements" R2, R5–R7; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "One submission protocol, for every cause" table, "The main path, step by step" (all steps, explicit demands), "Failure, recovery and concurrency", the (R7 marker) binding row; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md Shared observations A and B, rows R2–R7, and "Tests whose expectations change, and how".
- **Write surfaces:** `FilesystemActor+WatchedFolderScanning.swift` (step 4(a) marker clear at trigger, 4(b) `recordTrigger` and deadline reschedule; explicit causes through the same reserve/acceptance rule; remove the unconditional restores at `:101-104` and `:324-327`); `FilesystemActor+WatchedFolderScanPacing.swift` (the pacing deadline task on `schedulingClock`, shaped like `drainPendingChanges`); `FilesystemActor.swift` overflow block `:456-483` only (coarse recovery → 4(a) + `recordTrigger(.intakeCoverageLoss)` instead of the direct submit); `FilesystemActor+WatchedFolderResultApplication.swift` (result rule before the reduction: currency, monotonic marker, settle covered submissions, close); `WatchedFolderActorFixture` (take `TestPushClock`, expose a submission log, hold one run's result).
- **Pre-change signal:** today a callback submits at once, an explicit acceptance restores the marker after a newer trigger (review F1), and an older result can move the marker back.
- **Rows earned:** R2 (actor half, both arrival orders, two-demands-same-revision), R3 and R4 (actor on `TestPushClock`), R5 (actor overflow path; repairs `FilesystemActorWatchedFolderTests:11`), R6 (explicit t+0, the manual/fallback race and its control), R7 (shared observation B, extended with a real `RepoScanner` run held after a candidate directory, plus `WatchedFolderPublicationHoldIntegrationTests`).
- **Integration gate:** the first slice where client, pacer, scheduler and result application interact. Run every row above plus the existing watched-folder, scheduler and publication-hold suites before S5.
- **Stop:** if the result rule needs scheduler state the actor can't see, or settlement can't key on `submissionSequence` as Program Design states, stop: that's a model break, back to the Lead.

### S5: telemetry records (R8)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-specification.md "Requirements" R8 and "Cross-cutting obligations"; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "Cross-cutting" (the three record definitions); docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md row R8.
- **Write surfaces:** the recorder call sites in the S4 files; `AgentStudioOTLPRepoExplorerTaxonomy` attribute sets for `watched_scan_demand`, `watched_scan_run`, `watched_scan_obligation`; recorder fake in fixture A.
- **Pre-change signal:** a build counting submissions as runs; a build logging paths.
- **Rows earned:** R8 (fixture half). Exact equality of `obligationWaitMs`, `spanMs`, `quietGapCount` and run counts against the reducer's recorded triggers under `TestPushClock`; no value contains a path separator or fixture name.
- **Check:** if any edit shifts `PaneTabViewController` lines, update the OTLP measurement anchors (memory: anchor test pins `path:line`). This slice shouldn't touch that file.

### S6: V9 burst workload journey (Verifier, sunclaw)

- **Reads:** docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-verification-design.md Shared observation C (validity preconditions) and the "performance (V9)" row; docs/specs/2026-11-04-fsevents-overload/2026-11-04-fsevents-overload-program-design.md "Cross-cutting" (record names and attributes); `docs/architecture/observability/observability_and_traceability.md` "Performance workload" and "Local proof launch".
- **Owner:** the paired 🔎 Verifier (`practices-verification-maintenance` builds the journey; `practices-verification` observes). The Implementer doesn't author it.
- **Write surfaces:** `scripts/verify-watched-folder-burst-workload.sh` and `.mise.toml` task `verify-watched-folder-burst-workload`, siblings of the git-refresh workload.
- **Target:** sunclaw, one debug app at a time, launched with `run-debug-observability` and its own `ZMX_DIR`; never the production app.
- **Runs:** (1) baseline on a v0.0.124 debug build of the same fixture, which can run as soon as the journey exists; (2) the PR head after S5.
- **Passing condition:** exactly the Verification Design V9 row and its validity preconditions. A missing or empty telemetry stream is a failed run.
- **Unverified (from VD):** the owner's real workspace, other volumes, cancelled runs without a result.

## Obligation-to-proof map

| Row | Slice that earns it | Command / journey | Runs |
| --- | --- | --- | --- |
| R1 | S1 + S2 + S4 | `test:swift` filters on TopologyAdmission, client, fixture-A tests | per slice; again at S4 gate |
| R2 | S3 + S4 | reducer tests; fixture A with acceptance gate, both orders | S3, S4 |
| R3 | S3 + S4 | reducer; fixture A on `TestPushClock` | S3, S4 |
| R4 | S3 + S4 | reducer; fixture A on `TestPushClock` | S3, S4 |
| R5 | S1 + S4 | filter table; fixture A overflow path | S1, S4 |
| R6 | S4 | fixture A, manual/fallback race + control | S4 |
| R7 | S4 | shared observation B (real scanner) + publication-hold suite | S4 |
| R8 | S5 + S6 | fixture-A recorder fake; Victoria in the journey | S5; S6 head run |
| V9 | S6 | `mise run verify-watched-folder-burst-workload` baseline + head | baseline early; head after S5 |
| U6 | PR | `mise run test` + `mise run lint` on PR head | before wrap-up |

## Existing tests

| Test | Disposition | Reason |
| --- | --- | --- |
| `FilesystemActorWatchedFolderTests` immediate-scan assertions (e.g. "one ingress batch records multiple watched overflow admissions once") | repair | move scan-start assertions after the deadline on `TestPushClock`; counts unchanged (VD) |
| `FilesystemActorWatchedFolderTests:11` | repair | becomes the R5 coarse-recovery case |
| `WatchedFolderPublicationHoldIntegrationTests:83-93` | repair | admission check moves after the debounce; hold semantics unchanged |
| `WatchedFolderObservationCurrentnessTests:36-42` | keep | invalidation stays immediate under R7; moving it would weaken proof |
| `WatchedFolderTopologyAdmissionTests` | keep + extend | existing rule rows re-run over the snapshot |
| `FilesystemActorWatchedFolderAdmissionTests` | repair where timing changes | Implementer lists each changed assertion with its reason in the receipt |
| `WatchedFolderScanScheduler*Tests` | keep | scheduler unchanged |
| `DarwinFSEventStreamClient*`, `DarwinFSEventIngress*` | keep | buffer unchanged; new client test added |

No removals are planned. A removal needs replacement, redundancy or dead-contract proof and goes to the Lead first.

## False-green risks

- A fixture test that asserts the reducer's decision instead of the scheduler's submission log would pass with the actor not wired: R2–R6 rows observe the **submission log and results applied**.
- `TestPushClock` advanced past both deadlines at once would hide the 2 s vs 10 s distinction: advance in steps the row names.
- A V9 run with no telemetry would "pass ≤ bound": the validity preconditions make it a failure.
- A filter test over an empty snapshot passes trivially: every table row sets `knownCheckoutPaths`.

## Stop and replan conditions

- A model break listed in a slice's Stop line.
- Any change to a public contract, persisted format, or ownership outside this plan.
- `FilesystemActor.swift` or `DarwinFSEventStreamClient.swift` growing beyond their current size by more than the call-site lines named above.
- V9 baseline shows no coarse recoveries on the fixture (validity precondition fails): the workload must be redesigned before the head run counts.
