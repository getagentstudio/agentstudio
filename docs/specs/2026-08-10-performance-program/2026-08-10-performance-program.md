# Performance Program — Specification

What must be observably true for AgentStudio to stop blocking the MainActor
and stop burning CPU on work that changes nothing — and how each claim is
proven. Traces to [requirements.md](requirements.md) (U1–U8).

**Artifact set** — [Requirements](requirements.md) (WHY) → Specification
(this file, WHAT) → [Program Design](program-design.md) (HOW: components,
seams, ownership, call paths) · supporting:
[doc-drift inventory](doc-drift-inventory.md) · per-slice implementation
plans under [plans/](plans/) (mechanics only — never design) · tracking:
[Linear — AgentStudio Performance](https://linear.app/askluna/project/agentstudio-performance-af1a052f81d5)

## The problem in one map

```
 terminal / filesystem / git / forge facts        owner-user actions
        │  (necessary triggers)                   (cmd bar, tab move,
        ▼                                          dividers, Cmd+R)
 ┌────────────────────────────────────────┐              │
 │ admission: should this reach compute?  │◄─── today: equality is
 └────────────────────────────────────────┘     checked AFTER compute
        ▼                                        (95.1% of tabbar
 ┌────────────────────────────────────────┐      outcomes are `equal`)
 │ computation: how big, how scoped?      │◄─── today: full git scans,
 └────────────────────────────────────────┘     whole-topology capture
        ▼
 ┌────────────────────────────────────────┐
 │ placement: MainActor or off-main?      │◄─── today: capture/diff/
 └────────────────────────────────────────┘     startup surface creation
        ▼                                       sit on the MainActor
 published UI state ──► what the owner feels
```

Two failure types: **blocking the MainActor** (felt as hitches on common
actions and at startup) and **burning CPU over time** (felt as heat, fans,
battery). Two contributing conditions: a lane can fire too **often**, and each
firing can be too **heavy**. Every obligation below targets one stage of the
chain: trigger, admission, computation, or placement.

## Current observable reality (evidence)

Production stable `0.0.76` (contains PR #251 and the eager Tab Bar work),
measured from the shared Victoria stack, 2026-08-10:

- Terminal title-deadline drain: p95 ≈ 1.67 s across 18,532 events; Tab Bar
  invalidation p95 ≈ 1.80 s with **95.1 % of outcomes `equal`** — the
  dominant measured lane is work whose result is discarded. (The Tab Bar
  metric fires on generic observation invalidation — largely terminal/title
  facts — and is NOT a measurement of any user interaction.)
- Git status: 6,683 full scans, p95 ≈ 788 ms; git-unavailable timeout
  p95 ≈ 1.17 s.
- Sidebar MainActor apply: p95 ≈ 0.24 ms (a prior fix that worked; the
  pattern to repeat).
- Not measurable today: Repo Explorer outline diffing and Ghostty renderer
  cost (no OTel probes; known only from 2026-08-07 OS stack samples, where
  outline diffing held 55.9 % of a high-CPU main-thread sample), and all
  owner interaction latencies (no probes at all).
- Source-verified (2026-08-10 research, static): the Repo Explorer capture
  closure reads the whole repository topology and every sidebar entity, so
  unrelated writes still wake it; the eager off-main seam exists but has one
  adopter and copies full topology as input; git coalescing is a fixed
  500 ms window that replaces (not unions) path sets; sidebar visibility
  gates cadence but not eligibility; the event bus delivers every post to
  every global subscriber.

Evidence base: `docs/wip/debugging/2026-08-07-agentstudio-production-hotspots/`
(merged evidence collection) plus the 2026-08-10 research ledger (worktree
`tmp/research-workflows/2026-08-10-mainactor-perf-triggers/`, absorbed into
this spec; the ledger is not normative).

## Consumers and surfaces

```
                    ┌───────────────────────────┐
  owner-user ──────►│                           │──── telemetry ────► Victoria stack
  (daily app use)   │       AgentStudio         │     (OTLP, marker-scoped,
                    │      (opaque system)      │      source-scrubbed)
  agents ──────────►│                           │
  (edit this repo)  └───────────────────────────┘
        │                     ▲
        │ read                │ gate
        ▼                     │
  AGENTS/CLAUDE directive   lint + test gates (mise)
                              ▲
  automation ── runs ──► `mise run perf:report` ── queries ──► Victoria stack

  non-consumers: end users other than the owner (single-user product today);
  the Linear project tracks progress but consumes no runtime contract.
```

## Owner journey — common actions (U1)

```
 step (owner's job)          today (pain, evidence)            required difference
 ─────────────────────────   ───────────────────────────────   ─────────────────────────
 open/close command bar      occasional hitch; command-bar     no perceptible hitch;
                             filtering runs on MainActor        latency measured (V1)
 move a tab                  unmeasured (no tab-move probe;     probe lands (R1); invalidation
                             the 1.8 s Tab Bar lane is          only when something
                             terminal-fact invalidation)        changed (V2)
 drag a split divider        per-frame work during gestures     gesture path free of
                             (prior BonSplit findings)          non-essential compute (V1)
 Cmd+R / animations          animation side effects re-enter    animations do not admit
                             invalidation paths                 recompute of equal state (V1,V2)
 heavy terminal output       title/CWD events drain into        equal projections dropped
 while working elsewhere     main-actor applies                 before the MainActor hop (V2)
```

## Vocabulary (normative for this program)

- **Lane**: one named path from a fact source to published UI state or
  telemetry (e.g. "terminal title", "git status fold", "repo-explorer
  projection").
- **Admission**: the decision point where a fact either proceeds to
  computation/publication or is dropped/coalesced.
- **Equal outcome**: a computed projection whose published value equals the
  currently published value.
- **Waste ratio**: equal outcomes ÷ total outcomes for a lane, measured over
  a marker-scoped window.
- **Lane class**: `often` (fires ≥ ~10×/min under normal use) and/or `heavy`
  (unit cost ≥ ~1 ms on the MainActor or ≥ ~50 ms off it). Declared, not
  precise — the declaration forces the admission-policy conversation.

## Outcomes

- O1 Common owner actions have no perceptible hitch and admit no equal-state
  recompute (U1).
- O2 Facts that produce equal outcomes stop before the MainActor hop (U2, U3).
- O3 Git and forge work is bounded: adaptive cadence, union coalescing,
  eligibility gating, single-flight (U3).
- O4 Heavy derivation runs off-main through the keyed/eager path; the
  MainActor binds and publishes only (U2, U4).
- O5 Startup does not block the MainActor in synchronous surface creation (U2).
- O6 Every priority surface is measurable; a headless report ranks lanes and
  waste (U5, U7).
- O7 The failure classes are guarded by lint and directive so they do not
  return (U6, U7).

## Non-goals and negative space

A capable implementer may assume, but must NOT build:

- a replacement for the atom/observation system or any third-party layout,
  split, or reactive framework;
- vendor (ghostty/zmx) modifications — if slice 5 needs upstream API changes,
  that returns as a report, not a patch;
- per-emitter trace environment variables, new `#if DEBUG` test hooks, or
  changes to OTLP source-scrubbing and stable-channel tracing defaults;
- steady-state renderer/Metal optimization (measure first via V6);
- dual code paths or compatibility shims — every cutover is hard;
- suppression that changes final state: dropping work is only legal when the
  published end state is unchanged (see R-INV).

## Normative requirements

Grouped by slice. Every R cites its U basis; C and V identifiers resolve in
the contracts and proof sections. "Priority surface" = command bar
open/close, tab move, divider drag, Cmd+R, plus the slice-named lanes.

### Program invariant

- **R-INV (lossless suppression)** — basis U1–U3. Gates come in two kinds
  with distinct equivalence checkpoints:
  - *Suppression gates* (drop/coalesce equal or redundant work): for any
    sequence of facts on the lane, the published end state with gating MUST
    equal the end state without it, at sequence end.
  - *Deferral gates* (legitimately postpone work until demanded/visible,
    e.g. R12): hidden state MAY lag while undemanded; the equivalence
    checkpoint is the first settled demanded/visible point, where the
    published state MUST equal the ungated reference within the gate's
    stated interval.
  If a gate cannot decide equality (or deferral eligibility) cheaply, the
  fact MUST proceed to computation rather than be dropped. Failure
  expectation: a dropped-but-changed value at the applicable checkpoint is
  a correctness bug, not a performance tradeoff. Proof: V3 (automated
  behavior, per gated lane; deferral-gate tests prove zero hidden admission
  while undemanded AND checkpoint equality after demand).

### Slice 1 — Rails (LUNA-400)

- **R1 (interaction probes)** — basis U1, U5. The system MUST emit
  marker-scopable latency telemetry for each priority surface interaction
  (command bar open/close, tab move, divider drag, Cmd+R). The measurement
  boundary is normative: it starts at the user input event that initiates
  the interaction and ends when that interaction's terminal UI state is
  published with no further invalidation pending from that input. Per
  surface:

  | Interaction | Start | Terminal state | Settled when |
  |---|---|---|---|
  | command bar open | invoking shortcut key-down / click | bar presented, input focused, initial result set published | no invalidation pending from the open |
  | command bar close | non-executing dismissal input only (Esc, click-away) | bar removed, focus returned to prior surface | no invalidation pending from the close; selection-triggered execution is NOT part of close latency (the executed command's own surface owns it) |
  | tab move | the input that commits the reorder (drag release or move command) | tab strip published in final order, moved tab's pane still presented | no invalidation pending from the move |
  | divider drag | the input sample admitted for the measured frame (one sample per frame after coalescing) | the layout frame published for that admitted sample | per-frame: the measured unit is the frame, gated by a frame budget |
  | Cmd+R | command key-down | the invoked command's target surface publishes its post-command state | no invalidation pending from the dispatch |

  Two independent implementations MUST select the same start/end events from
  this table. Presentation animation triggered by the settled terminal state
  is OUTSIDE the measured work window — the gate bounds computation, and
  "animation is the rest" (owner decision 2026-08-10), with animation
  behavior governed by R23. Interaction gates are frame-based: work-settle
  p95 ≤ 2 frames and p99 ≤ 4 frames of the active display refresh interval
  (divider: ≤ 1 frame per admitted sample). Proof: V1.
- **R2 (lane probes)** — basis U5. Where a slice targets a lane with no
  probe (Repo Explorer outline apply; startup time-to-usable; renderer
  cost), that slice MUST ship the probe before or with its change, and the
  probe MUST expose outcome classification (`equal` vs `changed`) where the
  lane publishes projections. The outline probe's measurement boundary is
  the outline apply call (invocation → return) with row-count context —
  explicitly NOT native framework diff completion, which is not observable
  from app source; this defined proxy boundary is the normative one.
  Proof: V2.
- **R3 (headless report)** — basis U5, U7. When `mise run perf:report` runs
  with the shared stack reachable, it MUST produce, without app interaction:
  lane ranking, p95 durations, waste ratios, and deltas versus a named
  baseline (version or marker). When the stack is unreachable it MUST fail
  with a distinct exit code and name the endpoint — never fabricate or fall
  back silently. Contract: C2. Proof: V4.
- **R4 (guard lints, advisory first)** — basis U7. `mise run lint` MUST
  report (initially without blocking): broad snapshot/whole-collection reads
  inside observation capture closures; sort/reduce/group/hash over
  unbounded collections in `@MainActor` types outside an allowlist; timing
  or threshold literals outside `AppPolicies`; blocking I/O in
  `nonisolated async` without `@concurrent`. Contract: C3. Proof: V5.
- **R5 (agent directive)** — basis U6, U7. The repo agent instructions MUST
  contain a performance contract of at most ~10 lines requiring: lane class
  declaration (often/heavy) and admission policy for new event lanes;
  equality before the MainActor hop; keyed observation reads; off-main
  heavy derivation; constants in `AppPolicies`; probes shipped with lanes.
  Proof: V7 (inspection).

### Slice 2 — Admission and equality (LUNA-401)

- **R6 (equal outcomes stop early)** — basis U1, U2, U3. When a terminal
  title, CWD, or activity fact produces a projection equal to the published
  value, the system MUST NOT schedule MainActor invalidation for it; the
  lane's waste ratio MUST drop from ≈95 % to the plan-level target. Failure:
  under R-INV, uncertain equality proceeds. Proof: V2, V3, V8.
- **R7 (single CWD publication)** — basis U3. When one distinct CWD change
  occurs, the system MUST publish it to coordinators exactly once (today:
  two paths, two lookups). Proof: V3.
- **R8 (targeted delivery)** — basis U3. When an event is posted on the
  runtime bus, only subscribers whose declared interest matches the event
  MUST incur per-event work; posts MUST NOT fan out to unrelated global
  subscribers for filtering after delivery. Proof: V3, V8.

### Slice 3 — Git and forge triggers (LUNA-402)

- **R9 (adaptive cadence)** — basis U3. While a worktree's successive status
  results are unchanged, the system MUST lengthen that worktree's refresh
  interval per a policy owned by `AppPolicies`; when a change is detected it
  MUST restore prompt cadence. Proof: V8.
- **R10 (union coalescing)** — basis U3. When filesystem bursts coalesce,
  the resulting refresh MUST cover the union of affected paths across the
  coalesced window; path sets MUST NOT be replaced by latest-wins. Failure:
  a dropped path that hides a real change violates R-INV. Proof: V3.
- **R11 (scoped refresh)** — basis U3. When a watched-folder refresh
  triggers, only worktrees whose paths are affected MUST refresh; an
  explicit user "refresh all" remains available and exempt. Proof: V3, V8.
- **R12 (eligibility gating)** — basis U3. While a worktree is not visible
  in any sidebar surface and not otherwise demanded (active pane, explicit
  request), its enrichment work MUST NOT be admitted — not merely
  deprioritized. When it becomes visible, enrichment MUST be admitted within
  one normal refresh interval of the visibility change. Proof: V3, V8.
- **R13 (forge admission)** — basis U3. For each repo, at most one forge
  poll MUST be in flight; failures MUST back off; an unchanged count map
  MUST NOT be republished. Proof: V3.
- **R21 (bounded filesystem ingress)** — basis U3. Filesystem event ingress
  MUST be admission-bounded (no unbounded buffering between the FSEvent
  stream and coalescing), and bounding MUST be lossless under R-INV: a
  burst that exceeds the bound degrades to a coarser refresh covering the
  affected scope, never to dropped changes. Proof: V3.
- **R22 (Bridge invalidation eligibility)** — basis U3. Bridge product
  invalidation and activity recapture MUST run only for events that pass
  the affected-key pane/worktree filter; an unrelated pane or CWD event
  MUST NOT admit Bridge product work. Proof: V3, V2.

### Slice 4 — Keyed observation and off-main derivation (LUNA-403)

- **R14 (keyed wakes)** — basis U1, U4. When an atom write concerns an
  entity or facet outside a consumer's rendered/derived set, that consumer's
  observation MUST NOT wake. Specifically: Repo Explorer capture MUST NOT
  recompute for writes to unrelated worktrees, unrelated tabs/arrangements/
  panes, or bridge-attendance changes it does not render. Proof: V3, V2.
- **R15 (facet-scoped rows)** — basis U1, U4. Row-level facts (inbox unread
  counts, zoom/capability presentation) MUST re-render only their owning
  rows through keyed reads, not bypass or wake whole-surface projection.
  Proof: V3.
- **R16 (off-main derivation)** — basis U2, U4. Heavy projection/snapshot
  composition for the Repo Explorer surface MUST execute off the MainActor;
  the MainActor portion is bounded to bind/publish. The eager seam's input
  MUST be scoped to the consumer's declared keys, not a full-topology copy.
  Proof: V2, V8.

### Slice 5 — Startup (LUNA-404)

- **R17 (non-blocking startup surface creation)** — basis U2. When the app
  launches and restores terminal surfaces, surface preparation MUST NOT
  execute synchronously on the MainActor; time-to-usable MUST be measured
  (R2) and MUST improve versus the pre-slice baseline. If preparation fails,
  the app MUST still reach an interactive state with the failed surface in
  its existing health/recovery flow. Proof: V2, V6, V8.

- **R23 (animation admission)** — basis U1. When an animation runs on a
  priority surface (including divider/layout animations and their side
  effects), it MUST NOT admit recompute or side-effectful work whose
  outcome is equal state; animation-driven invalidation is subject to
  R-INV suppression semantics, and implicit/global animation MUST NOT
  extend invalidation beyond the animating surface. Proof: V2, V3.

### Every slice

- **R18 (docs currency)** — basis U6. When a slice changes admission,
  observation, cadence, or placement behavior, the owning architecture doc
  MUST be updated in the same PR. The admitted stale-claim set is the
  closed inventory in [doc-drift-inventory.md](doc-drift-inventory.md)
  (D1–D16, M1–M12): every item carries exactly one owning slice, plans may
  re-assign with a note, exclusions require owner authorization recorded in
  the inventory, and the program is not complete while any item is
  unresolved. Proof: V7.
- **R19 (guards become blocking)** — basis U7. When a slice cleans a
  surface, the R4 lint rules covering that surface MUST flip from advisory
  to blocking in the same PR. Proof: V5.
- **R20 (interaction gates)** — basis U1, U5. Each priority interaction has
  a numeric p95 (or per-frame, for gestures) threshold set in the owning
  slice's plan before that slice's implementation starts (owner decision
  2026-08-10). Each slice MUST show R1 interaction latencies at-or-better
  versus the prior baseline, and the program is not complete while any
  priority interaction misses its threshold. A plan without its numbers is
  not ready. Proof: V1, V8.

## Observable contracts

- **C1 telemetry lanes** — Lane telemetry uses the existing trace-tag
  selection surface and OTLP scrub rules; families are marker-scopable and
  carry outcome classification (`equal`/`changed`) where R2 applies. Exact
  family names are program-design/plan detail; their *existence, scoping,
  and outcome fields* are the contract. Undefined: retention, dashboards.
- **C2 `mise run perf:report`** — Inputs: optional baseline selector
  (version or marker), optional candidate selector (version or marker),
  optional lane filter. A marker-scoped window is *completed* when its
  run's completion marker record exists in the stack (the same
  marker/verifier convention the repo's proof runners already write); an
  in-flight window is never selected by default. Channel identity is the
  `dev.release.channel` resource label; when no channel is supplied, the
  default is `stable`. A workload window's completion record is the
  end-of-run record the owning proof runner already writes for that
  window's marker id, resolved through a resolver table owned by the report
  script that maps each known runner family to its exact end-record message;
  a window whose runner family is not in the table, or whose end record is
  absent, is in-flight (never selected by default) — extending the table is
  a reviewed change. When
  the candidate selector is omitted, the candidate MUST resolve to the most
  recent completed window for the channel; when the baseline selector is omitted,
  the baseline MUST resolve to the most recent completed window preceding
  the candidate for the same channel. If either cannot resolve, the report
  MUST fail with a distinct non-zero exit naming which selection failed —
  never silently pick a different window. Output: human-readable report to
  stdout containing BOTH the resolved candidate and baseline identities,
  lane ranking, p95s, waste ratios, and deltas;
  exit 0 on success; distinct non-zero exit and endpoint name when the
  stack is unreachable; no app launch, no telemetry generation. Partial
  data (some lanes absent) is reported as absent, never interpolated.
- **C3 lint gates** — Each R4 rule has a stable identifier in the
  architecture-lint inventory doc, a report-only or blocking state per
  surface, and appears in `mise run lint` output. Flipping to blocking is a
  PR-visible change (R19).
- **C4 agent directive** — Lives with the repo agent instructions; readable
  in one screen; changing it is a reviewed change like any contract.

## Cross-cutting obligations

- **Correctness**: R-INV governs every gate; suppression is lossless.
- **Observability**: all new telemetry obeys the existing OTLP source-scrub
  allowlist (no raw paths/UUIDs/payloads); collector absence stays fail-open
  for app startup; stable-channel defaults unchanged.
- **Testing**: no wall-clock sleeps; injected clocks for cadence/debounce
  policies (existing repo rules apply to all new admission machinery).
- **Compatibility**: no user-visible behavior change other than
  responsiveness; published UI end-state identical (R-INV); no persistence
  schema changes are required by this program — a slice that discovers a
  schema need returns to design rather than migrating silently.
- **Security/privacy**: not applicable beyond the OTLP scrub rules already
  stated — no new data classes are collected; interaction telemetry carries
  timings and outcome classes, never content.

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

## Proof obligations

| V | Evidence class | Proves | Boundary |
|----|---------------|--------|----------|
| V1 | metric observation | interaction latency per priority surface (R1, R20) | user input → published UI state, marker-scoped window |
| V2 | metric observation | lane duration + outcome classification, waste ratio (R2, R6, R16, R17, R22) | lane admission → publication |
| V3 | automated behavior | admission/equality/coalescing/keying semantics incl. R-INV, R7, R8, R10–R15, R21, R22 | deterministic tests with injected clocks and fake sources |
| V4 | CLI transcript | perf:report contract C2 incl. failure exit | headless shell, stack up and stack down |
| V5 | lint output | R4 rules exist and report; R19 flips are blocking | `mise run lint` on current tree |
| V6 | performance measurement | startup time-to-usable delta (R17) | app launch under the standard debug-observability runner |
| V7 | inspection | directive exists (R5); docs updated per slice (R18) | PR diff |
| V8 | performance measurement | per-slice before/after workload comparison via perf:report baseline (R6, R9, R11, R12, R16, R17, R20) | marker-scoped workload runs on the shared stack |

Numeric pass thresholds for V1/V6/V8 are set in each slice's plan before
implementation (owner decisions 2026-08-10; a plan without its numbers is
not ready). The V1 measurement boundary itself is normative in R1 and is
not plan-adjustable.

## Coverage

| U | Problem | Outcome | Requirements | Contracts | Proof |
|----|---------|---------|--------------|-----------|-------|
| U1 | interaction hitches; 95 % equal-outcome invalidation | O1, O2 | R-INV, R1, R6, R14, R15, R20, R23 | C1 | V1, V2, V3, V8 |
| U2 | MainActor blocked by capture/diff/startup work | O2, O4, O5 | R6, R16, R17 | C1 | V2, V6, V8 |
| U3 | over-aggressive / under-coalesced triggers | O2, O3 | R6–R13, R21, R22 | C1 | V2, V3, V8 |
| U4 | atom seam unsystematic; broad capture reads | O4 | R14, R15, R16 | C1 | V2, V3 |
| U5 | improvements unprovable; blind surfaces | O6 | R1, R2, R3, R20 | C1, C2 | V1, V2, V4, V8 |
| U6 | doc drift misleads agents | O7 | R5, R18 | C4 | V7 |
| U7 | no guardrails; failure classes recur | O6, O7 | R3, R4, R5, R19 | C2, C3, C4 | V4, V5, V7 |
| U8 | delivery boundary (5 PRs, Linear) | — | constrains slicing only | — | — |

## Slices and tracking

Docs are truth; tickets track. Slice ↔ ticket: 1 → [LUNA-400](https://linear.app/askluna/issue/LUNA-400)
(rails), 2 → [LUNA-401](https://linear.app/askluna/issue/LUNA-401)
(admission/equality), 3 → [LUNA-402](https://linear.app/askluna/issue/LUNA-402)
(git/forge triggers), 4 → [LUNA-403](https://linear.app/askluna/issue/LUNA-403)
(keyed observation + off-main derivation), 5 →
[LUNA-404](https://linear.app/askluna/issue/LUNA-404) (startup). Slices 2–5
are blocked by slice 1. Structural realization for all five slices lives in
[program-design.md](program-design.md); per-slice plans under
[plans/](plans/) (`yyyy-mm-dd-<slice>.md`, just-in-time) contain
implementation mechanics only and never author design.

## Open decisions and evidence gaps

- Numeric V1/V6/V8 thresholds: plan-level, per owner decisions 2026-08-10;
  the V1 measurement boundary is fixed by R1.
- Outline-diff attribution (atom-edge vs SwiftUI identity/animation): open;
  slice 4's plan starts with one marker-correlated `performance,atoms`
  workload run if attribution still matters after the R2 probe lands.
- Renderer cost ranking: unknown until the slice-5 probe exists; steady-state
  renderer work is out of scope until it demands otherwise.
- Startup block reproduction at current HEAD: re-verified as slice 5's first
  checklist item (evidence is from 2026-08-07 samples).
