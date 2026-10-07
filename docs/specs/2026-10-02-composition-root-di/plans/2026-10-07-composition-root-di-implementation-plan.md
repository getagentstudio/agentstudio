# Composition-root DI implementation plan

## Canonical record

- **Plan path:** `docs/specs/2026-10-02-composition-root-di/plans/2026-10-07-composition-root-di-implementation-plan.md`
- **Originating planner:** `plan-implementation`
- **Planning result:** `ready`
- **Governing planning basis:** `reviewed-three-artifact-design`
  - [Requirements](../2026-10-02-composition-root-di-requirements.md): `REQ-2026-10-02-COMPOSITION-ROOT-DI`.
  - [Specification](../2026-10-06-composition-root-di-specification.md): `SPEC-2026-10-06-COMPOSITION-ROOT-DI`.
  - [Program Design](../2026-10-06-composition-root-di-program-design.md): `DESIGN-2026-10-06-COMPOSITION-ROOT-DI`.
  - Current review/remediation result: `tmp/composition-root-di/final-verdict-2-2026-10-07.md`, the retained independent review's READY result at `c5950e82f89d12c43330bdeeb6b9e6f7e4454e5c`. Original findings DI3A-01–09 independently verified closed; all nine committed Mermaid views rendered and checked for whole labels/node/edge agreement. Prior reports are linked from that result.
- **Current applicability:** planned on branch `composition-root-di`, HEAD `c5950e82f89d12c43330bdeeb6b9e6f7e4454e5c`; merged main baseline `c49cda78529bae674585e92cb820b838462fe568` (#470). Native pin `2fb0c9cacb3fc75dbc8aedee9b7ed4321f091d33`.
- **Delivery context:** requested terminal `plan-only`; delivery grouping `single:composition-root-di`; PR topology `one-pr` for subsequent authorized delivery. This record authorizes planning only. An executor must not infer implementation permission or change the terminal from this document; explicit owner go and delivery-context admission come next.

This is the sole intended-work plan, not a progress ledger. Checkpoints, command
outputs and deviations belong in the existing work trace or ignored proof files.
Do not overwrite this ready plan's meaning during execution; a material plan
defect returns to the originating planner and gets a new canonical plan path.

## Goal, boundaries and delivery choice

Make dependency ownership visible and test fixtures independently constructible:
startup creates the selected dispatcher, registry, recorder, terminal lookup,
engine and callback handling; consumers receive specific dependencies. Delete
the named global access, fallback registry, translator object and lock/swap
helpers; demonstrate actual eligible-suite parallel execution. Preserve the
reviewed command, callback admission, native-live view and observability contracts.

Use one implementation PR, kept unmerged for review/delivery. The components
share construction and retirement contracts; splitting them into separately
mergeable PRs would encourage mutable binding slots, duplicate callback paths
or compatibility globals. Sequential local slices make proof tractable without
turning partial wiring into a separately accepted product. No stacked/parallel
branch topology is needed by this plan.

D6's responsibility order remains callback/startup → existing parameter seams
and engine → view consumers. Target all three. At the view decision gate below,
the already-authorized deferral can isolate a difficult view step, but cannot
hide a second selected object, a fallback or a dual callback path. List each
residual and its unmet R1 proof; do not call partial deletion full completion.

Protected: vendors and native ABI, IPC wire contract, command catalog/display
system, current persistence and unrelated globals. No container/service locator,
second-copy guard, daemon/multiple-engine architecture, real-engine isolation
tests, new atom/store/coordinator responsibility, bus case, recovery scheme,
timer policy or proof relaxation. Production quit does not newly free all
native surfaces or the engine. Engine-unavailable behavior is the narrowly
confirmed exception to current failure behavior.

Tracking disposition: preserve D5's existing Linear umbrella and the repository
work trace; this plan does not invoke Linear or create another tracking system.
If D6 defers work, return a named follow-up scope to that existing tracking owner.

## Execution admission and current evidence

Before executing after owner go:

1. Verify this plan, all three artifact meanings and their review result still
   apply to the worktree. Inspect any newer main changes in affected owners; do
   not rebase or merge unrelated primary working files. Preserve all dirty work.
2. Coordinate with the CI Lead for D4 lane ownership and the Sunclaw heavy-job
   slot. One build/test job at a time on this host. The selected implementation
   executor/model follows the existing owner policy; this plan commissions none.
3. Verify Xcode 27.0 / Swift 6.4 on Sunclaw using `xcodebuild -version`,
   `xcode-select -p` and `xcrun swift --version`. Do not substitute Sunbook's
   26.6, a native-build-system workaround or experimental compiler flags.
4. Run ordinary `mise run setup` to reuse prepared vendor inputs, then
   `mise run verify-vendors`. No vendor hydration or `--use-local-vendors` for
   this ordinary DI change. A failure is investigated at the existing owner,
   not an authorization for a different toolchain/vendor path.
5. Record fresh baseline source/suite inventory and focused results. Existing
   render/review evidence is design proof, not compile, test or runtime proof.

Current decisive source was inspected during design and re-anchored after #470:

| Owner / entry | Existing seam and planning consequence |
| --- | --- |
| `App/Commands/AppCommandDispatcher.swift` and Core command protocol | Singleton with mutable weak handlers/probe fields; constructor access must preserve shell-first routing, absent boot owner and observation. |
| `App/Boot/AppDelegate.swift`, `+WorkspaceBoot`, `+TerminalActivityBoot`, `+LifecycleRouting`, `+Termination` and `main.swift` | Early recorder, existing shell-install point, static callback/engine binding and bounded termination stages. Keep existing milestone and timeout meaning. |
| `App/Coordination/WorkspaceSurfaceCoordinator.swift` | Constructor overwrites callback registry; command-finished source timestamp flows to Sessions. Remove global rebinding while retaining current consumer behavior. |
| Terminal `Ghostty*.swift`, `SurfaceManager*.swift`, activity router and runtime | Existing copied-payload disposition, contracted lanes, exact barriers, lookup/handling reverse calls, weak direct-view updates and sourceInstant forwarding. Native-live undo state is distinct from pane membership. |
| `scripts/run-swift-test-task.sh`, `swift-test-helpers.sh`, `swift-test-invocation-receipts.pl` | Per-target bundle/preflight and invocation event streams are authoritative. Aggregate totals cannot establish execution of each moved suite. |
| `Tools/AgentStudioArchitectureLint` and singleton ledger | Existing SwiftSyntax lint owner and shrink-only ratchet. Add construction/reset checks here, never a separate grep lint tool. |

Current source counts and historical “about 20 suites” are discovery leads, not
success criteria. The final inventory must follow constructors/helpers/defaults
and teardown rather than count text matches.

## Slice graph and integration gates

| Slice | Type | Required predecessor | Vertical consumer / gate |
| --- | --- | --- | --- |
| S0 Current scenarios and proof inventory | proof/characterization | Execution admission | The behavior oracle for S1–S5; no new production interface. |
| S1 Checked source state and copied work | prefactoring plus behavior proof | S0 | S2 consumes the checked owners; actual current callback policy still drives fixtures. |
| S2 Startup/callback instance cutover | vertical ownership cutover | S1 | First real startup → trampoline → source handler → adapter → selected registry/lookup integration gate. |
| S3 Existing parameter/engine/command consumers, then views | vertical completion | S2 | All selected objects reach their consumers; D6 decision and absence inventory. |
| S4 Suite admission and construction enforcement | proof/static enforcement | S3, or explicit D6 partial boundary | Per-suite eligibility plus attributed normal parallel execution; construction misuse rejected. |
| S5 Aggregate and native proof | integrated runtime proof | S4 | All mandatory gates, marker-scoped real terminal/per-surface/observability behavior. |

These dependency edges are necessary: S2 consumes S1's owners, S3 consumes the
selected instances, S4 classifies the final reachable paths, and S5 proves that
same current source. The write/fixture/build surfaces overlap; no parallel
implementation lane is implied. Contract/prefactoring work is not a delivery
milestone by itself.

### S0 — establish scenario oracles and current consumer inventory

**Write surfaces:** permanent tests in the existing owning targets only when
characterization needs a missing claim; source/suite inventory and outputs under
`tmp/composition-root-di/implementation-proof/`. Keep the existing test harnesses.

Read all direct/default callers of the named objects, including unqualified
`.shared`, file-level activity binding, surface creation/undo, diagnostics,
AppKit selectors and SwiftUI closures. Map current source cases to R1–R9 and
affected suites to their helper/default/global effects. Use `rg` as discovery,
then inspect decisive bodies. Include paired module ownership in `Package.swift`.

Independent expected outcomes come from C1–C5 and the current contracted paths:
shell commands absent before shell-install, shell-first dispatch afterward;
same fixture's registration/trace/actions only; title barrier before exact
control; equality-suppressed samples create no raw bus wake; original
commandFinished sourceInstant; stale native lifetime rejected; direct pwd/size
changes allowed for native-live undo views without a pane. Establish these
assertions before refactoring, using table-driven variants when one guard covers
active/hidden/undo/retired/replaced states.

For new injection/nonreplacement claims the pre-change signal is a missing
constructor contract or shared-state coupling, not an invented timing failure.
Identify the permanent scenario, demonstrate its expected pre-change failure
when the seam is introduced in S1/S2, then keep it through the cutover. Existing
characterization scenarios must be green before changing behavior. Do not create
temporary test files or tests that merely enumerate implementation fields.

**Gate:** inventory names actual effects/expected outcomes and the focused tests
that observe them. Stop for a missing governing contract, not a guessed fixture.

### S1 — checked callback state without changing source policy

**Write surfaces:** Terminal/Ghostty accumulator, scheduler, tracing store and
pure action/payload translation; existing Terminal test target. New owned-work
and routing shapes stay in Terminal/Ghostty as reviewed; keep files cohesive
(600-line smell, 900-line split prompt). No Feature-sibling imports.

Move application callback mutable state inside `Mutex<State>` and replace the
exported mutable `DispatchWorkItem` boundary with the reviewed Sendable deadline
operation. Preserve retained keys, title/immediate lanes, search epochs, claim
tokens, follow-up drains, equality and title/control barriers. No new cadence.
Use the existing controlled scheduler/clock/fact seams to drive deadlines and
overlaps. Keep the total lock order and no-await-under-lock rule.

Keep immediate unsafe decoding private and synchronous; deferred APIs accept
only copied owned work and actor-isolated apply operations. Exercise all relevant
payload variants, including nil/nonnil pwd and sourceInstant, through the same
pure mapping used by callbacks. No experimental lifetime feature or blanket
unchecked conformance as a substitute for the checked boundary.

**Proof:** table/property-style accumulator and scheduler scenarios; exact
barrier ordering; invalid copied payload/drop results; cancellation before/after
claim and completion of an old token cannot remove a newer claim. Actual
application types compile with Swift 6.4. Use the established permanent negative
compile-fixture approach for actor/raw-input misuse where appropriate, with
expected diagnostics rather than “any compile failure”; do not claim arbitrary
C-pointer misuse is compiler-prohibited. S4's construction rule proves the
non-startup construction restriction separately.

**First focused command:**
`mise run test:swift -- --filter 'TerminalLocalActionAccumulatorTests|GhosttyActionRouterTests|GhosttyCallbackRouterTests|GhosttyAdapterTests'`.
Filters must match nonzero real tests in runner receipts; no raw SwiftPM build.

### S2 — one callback path selected by startup, with owned retirement

**Write surfaces:** `main.swift`; AppDelegate boot/lifecycle/termination;
coordinator registry construction; Terminal engine/AppHandle, callback/router
extensions, SurfaceManager lifetime/creation and activity router; App/Terminal
integration fixtures. Remove the static callback stores/bindings as their whole
consumer paths switch; do not add an old/new routing mode or service locator.

Implement the reviewed forcing/reference order: dispatcher → lookup (stores
reverse closures without calling them) → adapter → handling → context/engine.
Adapter lookup operations weakly capture the root-retained lookup, avoiding the
indirect view → handler → adapter → lookup retain cycle. Wire lookup cleanup/new
view handling, activity reverse controls, config snapshot and engine lifecycle
through those fixed operations. Remove coordinator registry override and
fallback runtime lookup; delete the translator object while retaining its pure
mapping and the sourceInstant forwarding contract.

Native userdata reconstructs context/identity synchronously. No delayed pointer
restoration or integer-encoded pointer task. Direct native-view apply uses the
reviewed active/hidden/undo lifetime guard; exact/drain guards keep current pane
checks. Tests replace native effect boundaries, not the actual decoding,
admission, accumulator, scheduler or registry interaction being proved.

Implement handler task admission/registration and retirement with the reviewed
lock order. Close/snapshot under task-owner alone; invalidate scheduler and
accumulator separately afterward; join and trace drain without locks. Include
all admitted wakeup/close/direct/exact/drain work, avoid self-join, and retain the
same retirement completion for repeated calls. Retired control returns dropped;
cleanup is idempotent. Test an interleaving where offer/enqueue races retirement,
using held steps/facts, never sleeps/yield polling.

Move the existing bounded “Ghostty action trace” termination stage immediately
before activity stop and use instance retirement/drain. Preserve the stage name,
deadline and overrun semantics; timeout is not fixture quiescence. Production
does not gain a native surface sweep/app free at quit. Keep native context alive
through actual per-surface free and conditional engine-owner release.

**Integration gate:** two independently constructed fixtures execute real
callback contraction/routing/retirement with separate registries and recording
sinks; no cross-delivery, shared swap lock or leaked work. Observe actual closing
facts/Task completion, and keep fixture teardown awaited before return.

**Focused commands:**
`mise run test:swift -- --filter 'GhosttyActionRouterTests|GhosttyActionRouterMixedPressureTests|GhosttyCallbackRouterTests|TerminalActivityRouterTests|TerminalActivityRouterCloseTests|TerminalActivityRouterAttentionTests|SurfaceManagerNativeRetirementTests|AppTerminationDrainDeadlineTests'`.
Retain expected-result checks at each boundary; do not mock away real routing.

### S3 — constructor consumers, engine availability and command observation

**Write surfaces:** App/Commands and Core command-protocol consumers; App boot,
IPCComposition, lifecycle, windows, panes and hosting; Terminal mount/runtime/
view/lookup defaults; existing command/window/native-view fixtures. New types
remain in their reviewed owning module. Use package visibility and existing
constructor dependency records where a long parameter list already has one.

Replace mutable dispatcher setup fields with fixed owner/probe/access operations.
Shell accessor remains absent until the exact existing shell-install point;
workspace lookup respects current window and registration eligibility. Pass
dispatcher through all UI/IPC/keyboard hosts without altering the command spec,
tooltip/catalog or IPC projections. Cover keyboard probe correlation, targeted
validation, unavailable owners and shell-first/workspace fallback results.

Remove engine/global lookup/default access through existing parameter seams and
all remaining views, including first-responder notification, config-cache reads,
undo creation and diagnostic selectors. One startup-selected object identity
serves every production consumer; no global alias to a new object or duplicate
engine. Explicitly prove typed engine-unavailable behavior preserves startup
milestones and current surface-creation result, with no new native-engine tests.

**DI3A-U1 observation gate:** observe the actual command-presenting host through
its existing observation/materialization seam as owner readiness/focus/window
changes. Enabled state and dispatch must update together. A dispatcher-only
return-value test cannot establish view observation. Repair a proven observation
defect at the existing host boundary; do not add an atom/bus/cache to hide it.

**D6 decision gate:** target complete view cutover. If evidence shows a view step
is difficult, name each remaining access/path, requirement and independent
delivery/proof boundary in the trace and return the permitted follow-up scope.
Ship steps 1–2 only when those paths remain fully proven and no duplicate
selected object, compatibility routing or contradictory construction is required.
Do not move suites whose remaining view/global effects still conflict. If
deferral requires a new structural bridge or changes the reviewed contracts,
stop for the Lead/design owner rather than invent that bridge.

**Focused command:**
`mise run test:swift -- --filter 'AppCommandDispatcherModePreflightTests|AppCommandDispatcherRequestCapabilityTests|AppCommandDispatcherWorktreeCreationTests|RepoExplorerCommandPresentation|ShellTabBarCommandPresentationTests|PaneLeafCommandPresentationTests|MainSplitViewControllerCompositeCommandTests|SurfaceManagerNativeRetirementTests'`.

### S4 — forbidden construction and real per-suite parallel execution

**Write surfaces:** `Tools/AgentStudioArchitectureLint` rule/registration/tests
and singleton ledger; existing test helpers/declarations; lane inventory and
per-suite evidence extraction at the CI-owned boundary if needed. No new test
runner topology or receipt format is assumed. Reconcile the sanctioned-global
architecture clauses named by the Program Design in the same source cutover.

Add the reviewed construction/reset rule in the existing SwiftSyntax lint
package. Positive and negative fixtures cover: production startup homes,
Terminal private-child construction, fake-engine test handling, forbidden
outside callsites, real-engine test construction, qualified/extension calls,
global defaults and resets of selected startup properties. Check the rule
inventory/parity integration. Delete touched singleton ledger entries in the
same change; no baseline additions/exception weakening. Keep unrelated entries.

Rewrite consumers/tests to fixture-owned construction, then delete obsolete
global override/swap helper contracts. Search source/tests for every named
access/default/alias and file-level callback binding, inspect null results, and
record any D6-authorized residual separately. Delete emptied serialized suite
shells; do not keep a discovered selector that executes zero tests.

With CI Lead, classify each affected suite's real executed constructors,
defaults, helper transitives and teardown. AppKit process state, buses, telemetry,
CoreAtomScope baseline and renderer globals can still require isolation. Remove
only justified annotation/inventory isolation; annotations are not ownership
proof. The inventory names suite IDs, residual effects, eligibility rationale
and expected proof, with historical estimates excluded as an oracle.

Run the **normal fast concurrent invocation** with existing retention enabled:

```bash
LANE_EVENT_STREAM_RETAIN_ALWAYS=1 mise run test:swift:fast
```

Use its retained `.events.jsonl` and invocation arguments/receipt to attribute
balanced, non-skipped function start/end (and positive balanced parameterized
case events) to each admitted canonical suite-ID boundary. Record function/case
IDs, counts, skips, issue outcomes and stream completeness. A suite-container
event or whole-invocation `tests_run > 0` cannot close R3. CI uploads these
streams only on failure, so capture successful local proof with O-1's retention
knob rather than assume an artifact exists. An extractor may read those existing
streams; CI Lead owns any required inventory/tool change. Do not weaken verdicts.

**Gates:** `mise run test:architecture`, `mise run lint`, meaningful per-suite
parallel evidence and no forbidden source/helper/default access. Any suite with
zero/only-skipped or unreadable evidence remains unverified, regardless of the
aggregate green result.

### S5 — current-source aggregate, native lifecycle and observability

**Write surfaces:** fixes inside the admitted source/test owners only if required
by diagnosed gate failures; evidence under ignored proof folders. Existing
diagnostic scripts remain owners; no production identity or shared stack change.

Run relevant focused checks after the final change, then `mise run test` from
root on the exact final implementation HEAD. Record commands, test counts, exit
codes, preflight/receipt identity and quality results. `mise run test` includes
lint, architecture tests, compile-negative AtomLib gate, BridgeWeb/web gates,
packaged web assets, Swift lanes/E2E and whitespace. Do not skip a lane or rerun
an unexplained red CI result; diagnose from lane report/event stream at its owner.
No timeout/width adjustment or stable toolchain substitution manufactures proof.

Complete the standard debug proof on Sunclaw/Xcode 27:

```bash
mise run observability:status
mise run run-debug-observability -- --detach
mise run verify-debug-observability
```

If the shared collector is absent, use the existing observability owner/runbook
to prepare it only within the admitted execution scope; no per-app stack or
restart workaround. Keep exporter/collector failure startup fail-open and verify
that scenario at its existing boundary. Match current worktree debug identity,
PID, marker and resource labels before every observation. Never target the
user's production app by name or kill unrelated apps.

Exercise a real native terminal through the established debug/IPC/native UI
seams: title/tab title, CWD, bell, command finish/source timestamp, ordinary and
abnormal exit, close, hidden/undo restore and final per-surface destroy. Confirm
expected existing marker events and pane/readback effects. Observe renderer-free
on actual per-surface retirement and reject late work; do not invent a quit-time
engine-free proof. For UI-only observations not covered headlessly, use the
repo-prescribed computer-use/PID-targeted debug surface.

Use `mise run verify-title-pane-performance-workload` for existing marker-scoped
title/contraction performance evidence, reading its documented debug-root and
launch policy before invocation. Compare equivalent current workloads against
the S0/current behavior baseline and existing probe contracts; capture actual
MainActor compact-apply, equal suppression, drain counts and round-trip metrics.
No test-body machine-speed assertion or unit timing substitutes for that proof.

Run relevant OTLP projection/sink/renderer-lifecycle tests plus current-marker
export safety inspection. No raw path, UUID, prompt, payload, error or output
may enter OTLP. JSONL matching/stale rows are not export privacy proof. Retain
existing early startup and terminal milestones through launch and termination.

**Delivery boundary after authorization:** implementation-owned independent
review, Advisor check and PR wrap-up operate under their phase skills with this
plan's evidence. Require successful current `mise run test` before implementation
push/PR readiness, then inspect CI/comments/threads/mergeability. This plan does
not authorize merging the PR, rewriting history or deleting worktrees.

## Obligation-to-proof map and independent oracles

| Obligation | Slices | Required observation / independent expected outcome |
| --- | --- | --- |
| R1 explicit objects, deletion and no fallback | S2–S4 | Every production consumer receives the same selected identity; missing registry entry drops rather than resolves another registry. Source/default/file-global absence and ledger reduction, with named D6 residuals only if deferred. |
| R2 fixture ownership and helper deletion | S0–S4 | Two fixture real-owner interaction results never cross; no global swaps/isolation lock; exact awaited teardown closes all fixture work. |
| R3 eligible suites actually parallel | S4 | Each inventory-admitted suite has attributable non-skipped function/case completion in the retained normal concurrent invocation stream; no count promise. |
| R4 immutable collaborators / confined construction | S2–S4 | Compiler/access or construction rule rejects rebinding/outside startup, while fake test handling is admitted and real engine tests are not. |
| R5 checked immediate/deferred ownership | S1–S2 | App callback owners have checked state; actor/raw-input negative claims fail for expected diagnostic reasons; real copied-data/contraction/barrier outcomes remain. Audit unsafe ingress separately. |
| R6 command and terminal behavior | S0, S2–S3, S5 | Same shell/workspace targeting/results, boot readiness, host observation, direct native-live view effects and original sourceInstant; real terminal effects preserve expected markers/readback. |
| R7 retirement and lifetime | S2–S3, S5 | Admission-race/token/stale-native-lifetime tables and joined fixtures; production bounded stage placement/overrun contract; actual per-surface free marker, conditional engine-free source order only. |
| R8 observations and privacy | S0, S2, S5 | Early recorder before delegate/engine, current-marker terminal/startup milestones, instance drain, contained exporter failure and scrubbed OTLP fields. |
| R9 scoped activity binding | S2–S4 | Two activity fixtures have separate accepted contexts/controls; start/stop and retired calls cannot redirect another handling. No file-global binding remains. |

Proof-layer authority is the repository's [Testing Architecture](../../../architecture/testing/testing_architecture.md#pyramid-as-applied-here)
and [Observability Proof Model](../../../architecture/observability/observability_and_traceability.md#proof-model):
module units for logic; real owner interactions for integration; debug native
launch/markers for smoke and performance. Independent oracles are the reviewed
C1–C5 contracts and existing production trace semantics, not the refactored code
recomputing its own expected values.

## Existing tests: keep, repair, remove

| Tests / helper | Disposition and contract evidence |
| --- | --- |
| `AppCommandDispatcherModePreflightTests`, RequestCapability, WorktreeCreation | **Repair** fixture construction; **keep** command/probe/targeting result assertions. Add absent→installed shell and real host observation scenarios. |
| `AppCommandDispatcherTestIsolation.swift` | **Remove only after replacement:** existing async scenarios use fixture-owned dispatcher; all four swapped-field behaviors and teardown retain proof without its shared actor lock. |
| `GhosttyAdapterTests`, `GhosttyActionRouterTests` and extensions | **Repair** to pure mapping/instance construction; **keep** payload/handled/drop, sourceInstant and exact-control expectations. Remove only dead static setter/override assertions with replacement fixture isolation evidence. |
| `GhosttyCallbackRouterTests` | **Keep/repair** native callback table, clipboard ABI and copied-buffer cases; fake userdata must not accidentally dereference a sentinel in the new context path. Preserve clipboard behavior, no extra policy. |
| `TerminalLocalActionAccumulatorTests`, local drain and mixed-pressure tests | **Keep/repair** checked owners and scheduling seams, preserve contraction/epoch/equality/barrier claims; add controlled retirement/offer/completion races. |
| `SurfaceManagerNativeRetirementTests` and renderer-state tests | **Keep/repair** constructor dependencies; active/hidden/undo membership and retirement semantics retained. Fake native retirement proves lookup policy, not libghostty free. |
| `TerminalActivityRouterTests`, Close, Attention | **Repair** injected instance operations; **keep** start/stop/ordered control/context/projector outcomes and joined teardown. No global binding expectations after replacement. |
| `AppTerminationDrainDeadlineTests` | **Keep/extend** completed/timed-out reply and cancelled-quit contracts; add pre-activity handler-retirement ordering using held steps/facts, no wall-clock test. |
| Command host presentation suites and DI3A-U1 | **Keep/extend** observed enablement/materialization and dispatch consistency, not only dispatcher return values. |
| `ProcessSingletonRuleTests`, rule inventory/parity and lane isolation gate tests | **Keep/extend** construction rule and admission cases; ledger shrinks. Empty serialized shells may be removed only with zero live test contract evidence. |
| OTLP/startup/renderer-lifecycle diagnostics tests | **Keep/extend as needed** existing field allowlists and milestones; no weakening or string-only substitute for launched signal proof. |

No test is removed merely because it is inconvenient or serialized. No mocked
native test is relabelled smoke. New tests live permanently in their owning
module/App target; shared harness remains domain-neutral.

## Risks, false greens and stop/replan rules

- **Swift 6.4 feasibility remains open:** compile actual owned enums, weak actor
  closures, checked mutex owners and C trampolines. A signature/type break that
  requires different structural ownership returns to Program Design before
  implementing a workaround. Same-file Sendable-implying conformances already
  landed; retain them in `AppDelegate.swift` and coordinator's own file.
- **Observation DI3A-U1 remains open:** host presentation proof is required.
  Passing dispatcher unit tests alone cannot close it.
- **Lifetime/locking remains open runnable proof:** task-owner critical sections
  cannot call accumulator/scheduler/trace code; no pointer bits or unsafe actor
  transfer hides an escape. No production quit-time native release added.
- **R3 false green:** source text counts, preflight discovery, container events,
  aggregate receipt totals or skipped suites do not prove admitted execution.
  Use O-1 retention and per-suite event attribution; missing evidence stays open.
- **Source-versus-runtime proof:** fake engine/lookups are permitted only outside
  the interaction under test. Native terminal, per-surface markers, performance,
  startup and export privacy require the real debug path.
- **D6 is conditional partial delivery:** no difficult view silently remains in
  full R1 completion. A required new compatibility/ownership mechanism is a
  design stop, not authorized merely by the deferral permission.
- **Environment/CI:** external build slot, vendor readiness, collector and runtime
  identity must be verified after go. No toolchain/SDK/vault/production changes,
  extra global infrastructure or destructive cleanup as workaround.
- **Proof gates are protected:** no wall-clock correctness assertions, arbitrary
  sleeps/polls, raised hang bounds, rerun-red-CI shortcut, `#if DEBUG` hooks,
  disabled lint/gates or weakened field scrub.

Stop dependent work for an owner/contract/security/persistence boundary change,
loss of required proof, an actual model break or destructive unapproved effect.
Bounded diagnosed repairs preserving contracts remain within the existing owner
boundary. Record reversible calls and deferred unrelated improvements in the
trace; continue agreed work after ordinary phase/check completions.

## Ready-plan return and implementation go boundary

This plan is ready **as a plan-only deliverable**. The three-artifact design and
all nine independent findings/render coverage are closed, but every executable
proof item above remains open. Renderer provenance is local cached mermaid-cli,
not GitHub; reviewer effort is unknown and its host lacked Xcode 27 SDK access.
These limits do not claim a new review pass or executed proof.

The next owner decision is explicit implementation go for this scoped plan.
Until that answer and executable delivery-context admission, write no Sources,
Tests, configuration, build/run proof or installation changes. This plan alone
confers no implementation, production or merge authority.
