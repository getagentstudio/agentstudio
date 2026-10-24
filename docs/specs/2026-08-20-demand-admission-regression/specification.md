# Demand Admission Regression — Specification

Requirements: [requirements.md](requirements.md)

```text
Interactive and sidebar users
  -> real-size workspace, search, grouping, hide/show, tab selection
  -> [ Agent Studio as an opaque system ]
  <- current rows, focus, scrolling, Git/PR state, responsive interaction

Operators and maintainers
  -> bounded marker-scoped performance workload
  -> [ Agent Studio as an opaque system ]
  <- safe CPU distributions, stage outcomes, validity controls, zero-drop evidence

Outside this contract
  security/auth redesign, persistence redesign, Bridge transport, visual redesign,
  reduced fixtures, hidden demanded UI, or terminal/agent work mixed into CPU gates
```

In this contract, **read-model binding** means accepting a current derived result into the observable sidebar projection. **Visible UI update** means the subsequent row identity, diffing, layout, focus, accessibility, and rendering work. Evidence and waste ratios MUST keep those boundaries distinct.

## Observable Contract

### Classification And Admission

**S1.** Every affected input lane MUST be explicitly classified as an ordered fact, latest-state projection, burst of samples, expensive refresh, or future eligibility deadline, including any composition of those classes. Its selected suppression, coalescing, aggregation, admission, execution, and deadline mechanisms MUST preserve the corresponding obligation from the governing demand-driven contract. [U-ADMISSION-1, U-BOUNDS-1]

**S2.** Repo Explorer MUST observe only the smallest keyed inputs that can change rows rendered by the current grouping and current sidebar demand. By Repository MUST NOT observe pane activity, pane message, focus, drawer, or recency facts that cannot change its rendered rows. A hidden sidebar surface MAY retain its last materialized result but MUST NOT continue an often/heavy capture lane merely to remain warm. [U-ADMISSION-1, U-CURRENTNESS-1]

**S3.** Equality and demand admission MUST occur before construction of a full Repo Explorer projection request. A source change that cannot alter the demanded rendered meaning MUST NOT walk all repositories, worktrees, tabs, or panes and MUST NOT schedule the projection worker. [U-PERF-1, U-ADMISSION-1]

**S4.** An admitted MainActor capture MUST read already-materialized keyed values and produce one immutable bounded request or delta. It MUST NOT resolve symlinks, canonicalize filesystem paths, perform Git/SQLite/network/process work, or recreate stable repository/worktree identity from paths. [U-ISOLATION-1]

**S5.** Latest-state pane-row facts MUST use per-key distinct-until-changed and latest-value coalescing. When a changed value is temporarily ineligible, the lane MUST retain at most one latest pending invalidation and deliver it by the first demanded checkpoint. It MUST NOT discard a changed value through an unrearmed leading-edge rate limit. [U-CURRENTNESS-1, U-BOUNDS-1]

### Terminal Activity And Metadata

**S6.** Raw Ghostty callback cadence MUST NOT define Repo Explorer, MainActor, EventBus, or OTLP cadence. Title, CWD, pane activity, and terminal-derived sidebar content MUST pass through their typed source admission and publish only changed compact semantic facts required by current consumers. Exact ordered facts MUST retain ordered delivery. [U-ADMISSION-1, U-CURRENTNESS-1]

An exact `commandFinished` fact required to settle a pane MUST NOT cross a lossy subscriber or any boundary that can silently discard it. Diagnostic trace admission MUST occur after the normative typed disposition and MUST obey that disposition's volume class. [U-CURRENTNESS-1, U-OBSERVABILITY-1]

**S7.** Terminal-derived sidebar content MUST preserve the latest demanded changed line without reading or copying an unbounded viewport on every raw output event. Any settle-time Ghostty read MUST be explicitly bounded, measured, and admitted before further MainActor or publication work; unchanged content MUST be suppressed at the earliest owner capable of proving equality. [U-PERF-1, U-CURRENTNESS-1, U-ISOLATION-1]

**S8.** Known future recency transitions MUST be scheduled from the earliest demanded row deadline. The app MUST NOT periodically rebuild the complete Repo Explorer fleet to discover whether a displayed recency tier changed. [U-ADMISSION-1, U-BOUNDS-1]

### Pull-Request Loading And Forge

**S9.** Pull-request loading is a latest-state repository presentation fact. Start, stop, cancellation, invalidation, and result completion MUST converge through one repository-keyed current state. Duplicate or superseded lifecycle signals MUST NOT create multiple MainActor mutations, work-intent backlog, or whole-sidebar captures. A successful current completion MUST materialize loading completion and its confirmed facts as one consumer-visible transition; consumers MUST NOT observe an intermediate not-loading state before the corresponding confirmed result. [U-ADMISSION-1, U-CURRENTNESS-1, U-BOUNDS-1]

**S10.** Honest PR presentation MUST continue to distinguish unknown, loading, unavailable, confirmed empty, and confirmed facts. Coalescing or suppression MUST NOT erase the last confirmed current-origin facts, publish an obsolete origin/generation, or strand a repository in loading after cancellation, removal, failure, or supersession. A completion MUST pass current origin, generation, live membership, and publication-scope validation before it mutates successful-freshness or last-published equality state. A rejected completion MUST NOT become the baseline that suppresses a later valid result. Demand loss alone MUST NOT invalidate facts for a branch that retains live membership. [U-CURRENTNESS-1]

**S11.** Forge MUST retain at most one active provider request and one latest pending follow-up per repository, current demand/origin/generation validation, one reschedulable freshness deadline, and repository-batched provider execution. The repair MUST NOT add polling, per-branch provider calls, or a second refresh owner. [U-PRESERVATION-1, U-BOUNDS-1]

**S12.** Repo Explorer MUST observe a repository's loading fact once per repository key when that fact affects the current rendered grouping. It MUST NOT repeat the same repository loading read once per worktree or capture the whole loading map/set on the hot path. [U-ADMISSION-1, U-ISOLATION-1]

### Projection, Publication, And MainActor

**S13.** Expensive grouping, row indexing, branch/status merging, and render comparison MUST remain off MainActor. Execution MUST be single-flight per owned projection key with at most one latest pending invalidation; cooperative cancellation MUST settle the predecessor before a successor begins execution for that key. Superseded identity, scope, or generation MUST be rejected before publication. [U-ISOLATION-1, U-PRESERVATION-1]

**S14.** MainActor publication and read-model binding MUST accept only a compact changed result or affected-key delta. Content-equal results MUST retain the current bound value without visible UI invalidation. A visible UI update MUST be proportional to changed membership or changed row content, not total workspace size when membership is unchanged. The equality contract MUST include every value capable of changing rendered output in the current grouping, including pane title/message/note, recency text/tier, real-attention state, drawer state, and branch presentation. Unaffected keyed rows MUST retain identity and MUST NOT be reconstructed, re-identified, re-laid-out, or re-entered into focus navigation solely because an unrelated key changed. [U-PERF-1, U-CURRENTNESS-1]

### Performance And Observability

**S15.** Under one recorded real-size isolated debug workspace that watches the complete canonical `opensource` and `project-dev` roots, contains five tabs and twenty pane models, and executes no agent or terminal command/output workload inside the fixture, settled candidate-process CPU p99 MUST be `<10%` in both required variants: no mounted terminal processes, and mounted but quiescent terminal processes producing no commands or output. The pane count MUST NOT be satisfied by silently mounting one PTY per pane. The proof MUST record and bound mounted PTYs and zmx sessions before, during, and after the population, and MUST reject any leak or unexplained increase. The settled measurement MUST begin only after watched-root discovery, startup, topology construction, initial projection, rendering, and telemetry export have positively quiesced. Scheduled recency, refresh, persistence, observability, idle-shell, or other background work remains part of settled CPU when it fires during the measured window. [U-PERF-1, U-BOUNDS-1]

**S16.** Under the same recorded watched-root workspace, with no agent or terminal command/output workload executing inside the isolated debug fixture, each ordinary action class MUST have candidate-process CPU p95 `<20%` when measured independently: a complete sidebar search-and-clear cycle, sidebar grouping switching, sidebar visibility hide/show, and tab switching. Each accepted population MUST contain at least 100 successful state-changing actions or cycles and at least 200 usable one-second action samples, and MUST calculate p95 by the nearest-rank method over that population only. Every issued action MUST traverse the production input path defined below and include its complete state-changing interval through generation-matched semantic and native settled-state readback. Suppressing an action, delaying its visible result beyond ordinary interaction pacing, issuing a no-op, omitting a demanded update, excluding its settle work from the population, or allowing PTY/session growth outside the declared variant cannot satisfy the CPU bound. [U-PERF-1, U-CURRENTNESS-1, U-BOUNDS-1]

**S17.** Idle variants, action classes, startup, fixture construction, terminal or agent execution inside the candidate fixture, and exact-attribution diagnostics MUST NOT be combined into one acceptance percentile. The repaired build MUST improve over `v0.0.89` and `v0.0.90`; `v0.0.88` is a historical comparison and cannot substitute for either absolute CPU bound. Every accepted population MUST bind workload identity, canonical watched-root identities and a stable discovered-topology fingerprint, tab/pane cardinality, mounted-PTY/zmx-session counts, build identity, standard instrumentation configuration, marker window, sample cadence, ordinary-use pacing policy, action-attribution policy, exact candidate process identity, debug-owned descendant inventory, and sampler-gap limit under one versioned proof-policy identity. Acceptance CPU MUST be sampled only from the exact isolated debug process identified by the launcher's state file. Unrelated host CPU, process names, builds, tests, profilers, beta, and production MUST NOT enter, gate, or substitute for that distribution. A live debug-owned descendant invalidates the population because it would move candidate work outside the measured PID. That complete policy identity MUST govern the repaired build and its comparisons, MUST be fixed before candidate measurement, and MUST NOT be relaxed or replaced after a failed run. Breaching it invalidates the complete population rather than permitting sample trimming. [U-PERF-1, U-OBSERVABILITY-1]

**S18.** Every affected stage MUST emit bounded outcomes sufficient to calculate input-to-semantic-fact contraction, semantic-fact-to-capture admission, capture-to-execution admission, execution-to-publication, publication-to-read-model-binding, and read-model-binding-to-visible-UI-update waste ratios. Observed, equal, coalesced, admitted, deferred, capacity-limited, cancelled, superseded, stale, failed, published, bound, and visibly updated outcomes MUST remain distinct. [U-OBSERVABILITY-1]

**S19.** Telemetry MUST use controlled bounded dimensions and MUST NOT export raw paths, UUIDs, terminal text, prompts, payloads, errors, or tool output. An often/heavy diagnostic lane MUST aggregate, sample, or source-admit before the trace queue. The performance proof MUST have zero app trace-queue drops and zero collector-side loss attributable to the measured lane. [U-OBSERVABILITY-1]

**S20.** The proof surface MUST attribute each test mutation to the affected admission, read-model-binding, and visible-UI-update stage without requiring high-volume exact-event logging in the primary benchmark. The standard instrumentation population alone MUST establish each CPU percentile. Dedicated diagnostic populations MAY enable narrower instrumentation only in separate marker windows, MUST report their measured CPU and interaction-time difference from a paired standard population, and MUST NOT be pooled with or substituted for the standard population. [U-OBSERVABILITY-1]

### Ordinary-Action Population Contract

Every action population uses contiguous, non-overlapping one-second process-CPU sampling intervals from the standard instrumentation configuration. An action window begins immediately before its first production input event and ends only after both the semantic state and the corresponding native visible state report the intended generation as settled. Every complete one-second sample whose interval intersects that window belongs to that action population; if an action spans multiple samples, all of them belong. A sample that intersects only the pacing gap between completed actions does not belong. Partial sampler intervals, post-hoc boundary changes, sample trimming, and overlapping actions are prohibited. The first input of an action starts on a sampler boundary. After settlement, the next action starts on the first eligible sampler boundary and never more than one sampling interval later, so deliberate idle time cannot dilute the percentile. A population continues until both its action floor and its usable-sample floor are met.

| Population | Deterministic production input | Required semantic and native readback |
| --- | --- | --- |
| Search and clear | Begin with an empty filter. Invoke the existing Filter Sidebar command to reveal and focus the actual Repo Explorer search field; deliver one predeclared eight-character fixture query as native text-entry events at one fixed ordinary typing cadence between 80 and 120 milliseconds per character; after the query's result is visibly settled, clear it through that same text-entry control without an artificial hold. Direct filter-state mutation, a query-setting IPC method, paste-as-one-mutation, or bypass of the production debounce/filter/render path is prohibited. | The query read model and native field equal the eight-character query, the visible rows equal the generation-matched filtered result, then the read model and field are empty and the visible rows equal the generation-matched unfiltered result. One entry-and-clear round trip is one cycle; at least 100 cycles are required. |
| Grouping switch | Execute the existing Repo sidebar grouping commands through their production command-dispatch path in a predeclared Repo → Pane → Tab round-robin; the counts for the three destinations differ by at most one. Direct preference or projection mutation is prohibited. | The semantic grouping value, selected native grouping control, and visible group/row projection all match the requested generation and mode. At least 100 non-no-op switches are required. |
| Sidebar hide/show | Execute the existing Worktree Sidebar visibility command through its production command-dispatch path, alternating visible → hidden → visible with equal hide/show counts after an even action floor. Direct split-view or visibility-state mutation is prohibited. | Semantic collapsed/visible state and the native sidebar presence, geometry, focus disposition, and demanded-projection state match the requested generation before the next toggle. At least 100 non-no-op toggles are required. |
| Tab switch | Execute the existing targeted tab-selection command through its production command-dispatch path, alternating between two predeclared populated fixture tabs drawn from the five-tab/twenty-pane fixture. Direct selection-atom or tab-view mutation is prohibited. | Semantic active-tab identity, native selected-tab presentation, visible pane content, and focus disposition all match the requested generation before the next switch. At least 100 non-no-op switches are required. |

The query value, typing cadence, two tab identities, action sequence, sampler phase, readback timeout, settle definition, host-validity envelope, standard instrumentation configuration, and permitted diagnostic-instrumentation perturbation MUST be fixed in the proof-policy identity before any comparison run. A timeout, no-op, failed command, wrong generation, missing semantic readback, missing native readback, cross-class sample, sampler gap, or validity-envelope breach rejects the complete population; it MUST NOT be retried away, omitted from the denominator, converted into idle, or used to revise the policy. Diagnostic instrumentation is admissible only when its predeclared perturbation bound holds against a paired standard population; regardless of that result, only the standard population determines CPU acceptance.

## Requirement Coverage

```text
U-PERF-1
  -> P1 unnecessary derived, binding, and visible UI update work consumes the machine
  -> O1 idle and ordinary UI actions leave compute available for agents/terminals
  -> S3, S4, S7, S13-S17
  -> C1 both idle-variant p99s <10%; each of four action-class p95s <20%
  -> V1 separated real-size CPU populations + native/readback + marker-bound profiles

U-ADMISSION-1 + U-BOUNDS-1
  -> P2 source cadence becomes unnecessary capture/execution/publication
  -> O2 only current demanded semantic work crosses expensive boundaries
  -> S1-S6, S8-S9, S11-S12
  -> C2 keyed demand, equality, one active/one pending, bounded deadlines
  -> V2 deterministic admission/currentness sequences + stage contraction metrics

U-CURRENTNESS-1 + U-PRESERVATION-1
  -> P3 suppression/coalescing can lose or misclassify visible state
  -> O3 latest demanded pane/Git/PR/sidebar meaning remains exact
  -> S5-S14, S16
  -> C3 R-INV equivalence, honest PR states, exact settle, preserved sidebar UX
  -> V3 controlled sequences + reference projection + native final-state readback

U-ISOLATION-1
  -> P4 fleet derivation and identity work occupies MainActor
  -> O4 MainActor applies only compact current state and visible-bounded UI work
  -> S4, S7, S12-S14
  -> C4 no filesystem/provider/fleet diff on MainActor
  -> V4 architecture checks + duration probes + marker-bound stack/Instruments evidence

U-OBSERVABILITY-1
  -> P5 high-rate diagnostics can perturb or lose performance evidence
  -> O5 attribution remains bounded, safe, complete, and measurement-valid
  -> S17-S20
  -> C5 separated markers, bounded dimensions, zero drops, perturbation control
  -> V5 OTLP allowlist/canary + stage ratios + standard/attribution comparison
```

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

## Failure Contract

- Loss of demand cancels or defers future work without deleting current bound read-model facts.
- Cancellation, timeout, provider failure, or stale completion never counts as equality or suppression.
- Capacity limitation retains bounded latest required intent and exposes a capacity outcome; it never silently converts demand into unavailable product state.
- A missing or failed optional telemetry sink never blocks ordinary application startup, but a strict performance proof fails when required evidence is absent or dropped.
- If a compact fact cannot prove equality, the owning lane executes or retains one pending invalidation; it does not guess that the change is irrelevant.
- An idle or action CPU population that includes terminal commands or output or agent execution inside the isolated debug fixture, fixture construction, startup, another action class, a different terminal-mount variant, unbounded PTY/zmx-session growth, watched-root topology drift, diagnostic instrumentation, a partial sampler interval, an unbound action sample, a live debug-owned descendant, or a breach of its declared proof-policy identity is invalid rather than passing or failing. Unrelated resident host processes are outside the measurement and control scope.
- If a CPU threshold fails, the proof retains its marker, samples, workload metadata, and bound profile evidence. It does not discard high samples, widen the percentile, reduce the workspace, slow actions beyond ordinary use, or relabel action time as idle.
- If any issued ordinary action is a no-op, fails, times out, produces the wrong generation, or lacks either semantic or native readback, the population is rejected without replacing that action or recomputing the percentile from the remaining samples.

## Proof Obligations

- **Deterministic source admission:** changed/equal title, activity, focus, recency, drawer, PR loading, and PR fact sequences prove exact suppression/coalescing/admission counts and final state.
- **R-INV reference equivalence:** every pane-row equality/suppression and deferred latest-value sequence is compared with an ungated reference through its sequence end or first demanded checkpoint; visibly changed row fields can never complete as equal.
- **Grouping demand:** each Repo Explorer grouping proves its exact observed input set; irrelevant pane facts produce zero capture in By Repository, and hidden-surface hot facts produce zero heavy capture.
- **MainActor boundary:** automated architecture checks and duration probes prove hot capture performs no filesystem/Git/SQLite/network/process work and publishes compact changed values only.
- **Concurrency/currentness:** burst and cancellation tests prove one active plus one latest pending work item, obsolete result rejection, latest changed fact delivery, and loading-state recovery.
- **Forge publication equivalence:** in-flight demand sequences including A → B → A prove that rejected completions leave freshness/publication baselines unchanged and that a later identical valid result still reaches the materialized cache; loading completion and facts appear atomically.
- **Exact terminal delivery:** bounded-pressure integration proves `commandFinished` cannot be lost before settle/status publication and that diagnostic routing cannot bypass typed source admission.
- **Settled idle performance:** after a positive quiescence boundary, one separately marked population of at least 1,000 one-second usable samples for each required terminal-mount variant—no mounted terminals and mounted but quiescent terminals—must prove exact candidate-process CPU p99 `<10%`, record scheduled background work that fires, and retain the complete sample distribution, marker identity, terminal-mount count, exact process identity, debug-owned descendant inventory, and sampler gaps. The 1,000-sample floor exposes at least ten observations in the empirical one-percent tail instead of allowing a p99 claim to rest on only three tail observations.
- **Ordinary-action performance:** each independently marked search-and-clear, grouping-switch, sidebar-hide/show, and tab-switch population must meet both floors—at least 100 successful cycles or state changes and at least 200 complete one-second action-bearing samples—and prove nearest-rank process CPU p95 `<20%`; exact production input routing; generation-matched semantic and native settled-state readback; fixed ordinary-use pacing; complete action-window attribution; MainActor occupancy; and zero idle, failed-action, partial-window, or cross-class dilution.
- **End-to-end tagged comparison:** the same real-size workspace runs against faulty `v0.0.89`/`v0.0.90` evidence, the historical `v0.0.88` control where reproducible, and the repaired build; it records CPU, capture cadence, MainActor held/queue time, read-model-binding and visible-UI-update waste, interaction behavior, instrumentation configuration, and trace loss.
- **Native behavior:** By Repository, By Pane, and By Tab content; search and clearing; grouping and collapse; sidebar hide/show; tab switching; focus and commands; scrolling; accessibility; appearance; recency; Git/PR presentation; and terminal interaction remain visibly current and behaviorally unchanged in the packaged debug app.
- **Telemetry safety:** OTLP projection tests and current-marker negative checks prove bounded dimensions and absence of sensitive values.

## Non-Goals

- No generic admission framework, new service, persistence schema, feature flag, compatibility route, or fleet-wide polling.
- No removal of intended sidebar activity or honest PR-loading behavior.
- No unrelated Git, Bridge, authentication, security, release, visual/product redesign, or repair of the separate By Tab unassociated-pane correctness bug. An internal rendering or viewport-demand replacement is in scope only when it preserves the existing sidebar contract and is required by the CPU bounds.
