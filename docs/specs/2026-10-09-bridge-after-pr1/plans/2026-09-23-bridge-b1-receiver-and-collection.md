# Bridge B1 — Stable Receiver and Multi-Root Collection — Implementation Plan

planning result: ready
originating planner: plan-implementation
governing planning basis:
  kind: reviewed-three-artifact-design
  Requirements: docs/specs/2026-09-12-bridge-navigation/2026-09-12-requirements.md
  Specification: docs/specs/2026-09-12-bridge-navigation/2026-09-12-bridge-navigation.md
  Program Design: docs/specs/2026-09-12-bridge-navigation/program-design.md
  review: independent Review Sidekick codex-local 01a0cdd9-6e1c-78c0-b719-38a8470fb0a9 (gpt-6-astra high); re-review needs-revision (board seq 852), corrections e7fdaf285/0a8a86f78, round-2 needs-revision (seq 953), corrections ad5327711/cde95df28, verified ready for planning (seq 973, root 01a0cdcc-152d-70e2-9bb2-b05260b06ca7); R19 count meaning is a parked owner default (B3 only)
  current applicability: branch `bridge-multi-root` at 5f014a420 (docs) on origin/main 18cbc3e02
delivery context:
  requested terminal: pr-ready-unmerged
  delivery grouping: selected:stack-B-layer-B1 (owner-selected layers B1 → B2 → B3, S26/S46)
  PR topology: separate-prs (B1 is the bottom PR of stack B; B2 and B3 stack on it)
planned at: agent-studio.bridge-multi-root, branch bridge-multi-root, HEAD 5f014a420

## Goal and scope

B1 delivers Specification R1–R4, R14–R16 and contracts C1–C4, C7: one stable
receiving Bridge per terminal (and per standalone Bridge tab) whose navigation
record survives companion replacement, restart and close/undo; Files over all
member worktrees plus exact loose documents with collection-wide search; Review
of one member and its retained comparison; known-worktree membership with CWD
injection/protection and removal; local-file annotations; receivers for
terminals outside Git; and IPC reachability of the receiver through the
terminal handle.

Not in B1: agent file open, Open view, ⌘-click (B2); multi-PR summary (B3);
Command-P/selector UI; any vendored-project change.

## Prerequisites and merge order

- **A1** (`agent-studio.ipc-improvements`, in progress) must merge first for
  slice S9 (agent eligibility of `bridge.*` and B1 commands). S1–S8 do not
  depend on A1. Before S9, rebase B1 onto main after A1 merges; if A1 is not
  merged when S1–S8 finish, stop and report instead of implementing S9.
- **Stability PR #356** changes `BridgePaneMountView`'s inner hosting sizing
  (`sizingOptions = []`). Rebase onto main after #356 merges and preserve that
  line and its test; do not reintroduce intrinsic sizing in any hosting change.
- The drawer PR (`drawer-changes`) touches drawer geometry only; no expected
  collision beyond docs, which are identical copies.

## Repository rules the implementer must follow

`CLAUDE.md` / `AGENTS.md` and `BridgeWeb/AGENTS.md`: Swift 6 Testing only; no
wall-clock waits, no `.timeLimit`; causal barriers and event/quiescence waits;
blocking waits off the cooperative pool; WebKit suites in the serialized WebKit
lane with qualified filters; atoms only assign/publish, SQL in repositories;
MainActor publishes only, file I/O `@concurrent`/off-main; commands through the
command spec; BridgeWeb uses its owned primitives and the Vite loop for UI
iteration; `mise run lint`, `mise run test` green on the PR head.

## Obligation ledger (Program Design section → owners)

| Obligation | PD section | Owners / paths | Proof |
| --- | --- | --- | --- |
| Receiver identity and record | Navigation state and identity; Owners and dependency direction | new Core `BridgeReceiver`, `DocumentLocation`, `NavigationRecord`, `BridgeNavigationRules`, `BridgeNavigationAtom` | rule tables/properties (R3, R15, R16) |
| Drawer caller resolution | Drawer caller resolution | App target resolver | integration (drawer caller → owner receiver) |
| CWD injection, protection, removal, unregistration | CWD injection and worktree removal | rules + command handler | rule tables + integration |
| B1 commands | Commands and the IPC boundary (B1 rows) | `AppCommand` catalog: `activateBridgeFile`, `activateBridgeReview`, `selectBridgeWorktree`, `addBridgeWorktree`, `removeBridgeWorktree`, `closeBridgeFile`, `searchBridgeFiles` | command tests |
| Exact document admission | Loading, showing and Open view (admission paragraphs only) | `BridgeDocumentAdmission` (off-main), existing descriptor reader | real temp files outside Git, symlink/race, unsupported content |
| Files collection | Activation and source replacement | `BridgeFileCollectionSource`; native/product/worker/display contracts; BridgeWeb display model and `BridgeCommWorkerFileQueryProjection` | Swift + BridgeWeb tests, equal paths, dedupe, partial member failure |
| File/Review source split | Activation and source replacement | controller construction from two inputs; Review binder keyed by member/comparison | integration: Review switch keeps Files |
| Draft barrier and arrival | Activation and source replacement | editor preparation / `draft.flush` barrier, generation-matched arrival, teardown fence | real draft flush before selection/teardown; failure keeps old editor |
| Companion from record; no-Git receivers | Receivers without a known worktree; How multiple worktrees work in fullscreen | `WorkspaceSurfaceCoordinator+ZoomCompanion.swift` context resolution | cd-to-/tmp keeps members; new no-Git terminal shows loose files |
| Local-file annotations | Annotations for Git and local documents; How feedback gets back to the agent | annotation subject model, schema/codec migration, batch projector, output coordinator | migration on populated data; local-file capture/save/restart; copy/export labels |
| Persistence and cutover | Persistence, restore and owner lifecycle | `local_bridge_navigation` rows, save capture/hydration, undo retention, legacy `BridgePaneState.source` ordered conversion, legacy writer table | real SQLite: populated legacy import, restart, close/undo, failure keeps legacy |
| Refresh and concurrency | Refresh, concurrency and failure boundaries | refresh routing by explicit bindings; per-receiver sequencing | stale result rejection, owner removal cancels |
| IPC reachability | Commands and the IPC boundary ("Reaching the receiver through IPC") | `AgentStudioIPCBridgeAdapter` resolution; A1 eligibility flip | IPC integration via `self` (terminal and drawer terminal), other terminal refused, unmounted → unavailable |

## Slices

### S1 — Navigation contract (contract)
Core values, pure `BridgeNavigationRules` (membership inject/dedupe/protect,
removal with file clear and ordered Review fallback, catalog unregistration,
Files/Review selection independence, per-member comparison memory), and
`BridgeNavigationAtom` (live values, revision, equality suppression). Proof:
table/property tests derived from R3, R4, R15, R16 text. Consumers: S2–S9.

### S2 — Persistence and cutover (migration/cutover)
Requires S1. Local rows, capture/hydration ordered before mounts, undo
retention using core pane IDs and undo members, legacy `source` ordered import
(local commit and acknowledgement, then core payload rewrite; restart resumes
only the missing step), and removal of every legacy writer/reader in the PD
cutover table. Proof: real SQLite including a populated legacy database,
import failure keeping legacy data, restart and close/undo.

### S3 — Admission and Files collection (vertical)
Requires S1. `BridgeDocumentAdmission` and `BridgeFileCollectionSource`;
source-qualified rows through native/product/worker/display contracts;
existing Pierre tree rendering. Proof: Swift integration with real files and
two worktrees with equal relative paths; BridgeWeb unit tests for the display
model and query projection; deduplication; partial member failure.

### S4 — Source split, companion from record, no-Git receivers (vertical)
Requires S2, S3. Controller built from File and Review inputs; companion
context from the navigation record; Files-only receivers; receiver survives
companion replacement, hide/show and Zoom exit. Proof: coordinator
integration; the cd-to-/tmp and new no-Git cases; serialized WebKit lane for
mount behavior. Preserve #356's hosting sizing.

### S5 — Activation, draft barrier, close (vertical)
Requires S4. `activateBridgeFile` / `activateBridgeReview` / `closeBridgeFile`,
awaited `draft.flush` barrier for selection, Markdown replacement and
teardown; generation-matched arrival; partial/unsaved outcomes. Proof: real
draft flush acknowledgement; failure keeps old editor/document; stale
generation ignored.

### S6 — Membership commands and CWD (vertical)
Requires S4. `addBridgeWorktree`, `selectBridgeWorktree`,
`removeBridgeWorktree`; CWD injection/protection on admitted CWD changes;
catalog unregistration propagation. Proof: integration per R16 (protected
refusal, removed-file clearing without reclassification, Review fallback,
last-member removal, temporary unavailability ≠ removal).

### S7 — Collection search (vertical)
Requires S3, S4. `searchBridgeFiles` through the mounted worker's query
projection across members and loose files; unmounted → unavailable. Proof:
BridgeWeb query tests + Swift integration with stale/cancelled queries.

### S8 — Local-file annotations (vertical)
Requires S3, S5. Subject model local-file case, schema/codec migration of
existing Git annotations, batch projector and output coordinator subject-aware.
Proof: migration on populated data; capture/save/restart; copy/export with
truthful local vs Git labels; historical output bytes untouched.

### S9 — IPC reachability (integration)
Requires S5, S6 and A1 merged into main (rebase first). Bridge adapter resolves
terminal handle → receiver → current controller; unmounted → unavailable for
page methods; flip `bridge.*` reads/in-Bridge navigation, `searchBridgeFiles`
and `addBridgeWorktree` to `ownPane`; human-only B1 commands stay
`notYetAllowed`. Proof: IPC integration with real registry: terminal agent and
drawer-terminal agent via `self`, another terminal's handle refused, unmounted
receiver.

### S10 — Native and performance proof (proof-only)
Requires S1–S9. Orchestrator-run with a GPT-6 Sol computer-control agent on a
PID-targeted debug app: fullscreen Review switching frontend → backend →
frontend retaining Files; no-Git terminal; restart restoring inventory and
selections; local-file annotation copy. Marker-scoped performance for
activation and search.

## Edges

S1 → S2, S3 · S2 + S3 → S4 · S4 → S5, S6, S7 · S3 + S5 → S8 · S5 + S6 + A1 → S9
· all → S10.

## Integration gates

After S4: a zoomed terminal shows its receiver's collection with Files and
Review from the record. After S9: the full IPC suite passes. Final: `mise run
lint`, `mise run test` (including BridgeWeb lanes) exit 0 on the PR head.

## False-green risks and stop conditions

- Migration tested only on an empty database; BridgeWeb tests passing while the
  native contract is stale; WebKit suites filtered to zero tests.
- Stop and return to the orchestrator if: A1 is not merged when S9 is reached;
  #356's sizing contract conflicts with a hosting change; the legacy conversion
  cannot keep the ordered local-then-core commit; the annotation migration would
  rewrite historical output bytes; any change needs a new atom/store beyond
  `BridgeNavigationAtom` (owner-confirmed, S47).
