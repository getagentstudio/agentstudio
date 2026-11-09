# Agent PR links: Implementation Plan

```text
plan path: docs/specs/2026-11-09-agent-pr-links/plans/2026-11-09-agent-pr-links.md
originating planner: plan-implementation
supersedes: none
planning result: ready
governing planning basis:
  kind: reviewed-four-document-design
  Requirements:        docs/specs/2026-11-09-agent-pr-links/requirements.md
  Specification:       docs/specs/2026-11-09-agent-pr-links/specification.md
  Program Design:      docs/specs/2026-11-09-agent-pr-links/program-design.md
  Verification Design: docs/specs/2026-11-09-agent-pr-links/verification-design.md
  review results:      tmp/review/design-review-1.md, -recheck.md, -recheck-2.md, -recheck-3.md (converged; F2, F9 settled by the owner)
  applicability:       branch feat/agent-pr-links at 28b08f32e (PR #680's head)
delivery context:
  requested terminal: pr-ready-unmerged (the owner merges)
  delivery grouping: selected:service-first-with-early-popover
  PR topology: one-pr
  repositories: agentstudio
```

## Admission

The owner chose A for storage (choice 5) and deferred the real Router run to the first beta (choice 6), both on 2026-11-09. The design review converged after recheck 3. Nothing gates the Implementer's start.

## Goal and scope

**Goal.** Any authenticated agent adds GitHub PRs to a main pane with `agentstudio pr add|remove|list` and the `drawer browse` targeting. The drawer toolbar's PR button opens a designed PR popover with details for each PR. The popover is built on shared components (Requirements U1–U7).

**Not in scope.** Generic or worktree links, other forges, acting on PRs, telling an agent its PR was removed, and changes to `drawer.browse` behaviour. The Requirements' limits apply.

**Built provisionally.** Owner choices 1–4 (worktree row first, row fields, 180 s freshness, `pr list`) are built as proposed and confirmed on the owner's page. A change reopens the slices they touch: choice 1 or 2 touches S5 and S6, choice 3 touches S4, choice 4 touches S3.

## Grouping chosen

| Option | Order | Why not / why |
| --- | --- | --- |
| **Service first, popover early (selected)** | S1 → S2 → S3 ‖ S4 ‖ S6, then S5 joins them, then S7 | Real data reaches the popover as soon as the list composition lands. The popover itself is built in parallel from prepared values, so the owner sees real frames early. This follows the rule that UI frames come before test hardening. |
| Popover first on seeded rows | S6 → S1… | Frames come sooner, but they come from fake rows, and an owner review of fake rows gets repeated on real ones. |
| Layer by layer (storage, then IPC, then UI) | strictly serial | No real frames until the end. |

One PR. The PR stacks on #680: it can't merge before #680, and it takes `main` by merge once #680 lands.

## Slices

Each slice lists the anchors it realizes or earns. That list is the Implementer's required reading for the slice. Quality gates for every slice are `mise run format` and `mise run lint`, plus the focused `mise run test:swift -- --filter <suite function ids>` for that slice's suites. Before the PR is ready, the full `mise run test` runs on HEAD.

### S1. Shared targeting and the PR reference (prefactoring + contract)

- **Reads:** Specification R2, R3, E1, and the CLI table. Program Design: Entity binding E1, Interfaces, and "Changed edges". `Sources/AgentStudioIPCClientCore/DrawerBrowseCLI.swift`, and the drawer-browse branch in `App/IPCComposition/AgentStudioIPCLayoutAdapter.swift`. `docs/architecture/commands/ipc.md` (drawer browse table).
- **Change:** Move target-flag parsing out of `DrawerBrowseCLI` into `PaneTargetFlags`, and move main-pane validation out of the drawer-browse adapter into `MainPaneTargetValidation`. Behaviour stays the same. Add `GitHubPullRequestReference.parse(_:) -> IPCPanePullRequestIdentity` in `AgentStudioProgrammaticControl`.
- **Consumer:** S3.
- **Pre-change signal:** a parser that accepts `gitlab.com/...` or an issue URL, or a refactor that changes any drawer-browse line or exit.
- **Proof:**
  - Parser table test for R2, at the unit layer. The oracle is the R2 input forms and E1's case rule.
  - Existing `DrawerBrowseCLITests` and `DrawerBrowseCLIRealServerTests`: keep both unchanged. They guard the prefactor, and a changed line fails them.
- **Earns:** U4's parser row (Verification Design U4, focused).
- **Stop:** the drawer-browse tests need editing to pass. That means behaviour changed.

### S2. Pane PR storage and service (migration/cutover)

- **Reads:** Specification E2, E3, E4, R1, R4, R5, R16 and R17. Program Design: Entity binding E2 to E4, "One list owner", and the state/failure table. `Core/PaneContext/PaneContextService+Lifecycle.swift` (retirement, `purgeRetired`, reset list). `Core/State/MainActor/Persistence/WorkspaceLocalMigrations+PaneContext.swift`. The SQLite storage rules (no triggers, no FKs, enums as TEXT parsed in Swift).
- **Change:**
  - Add migration `033_create_pane_pull_requests` with two tables, `pane_pull_request` and `pane_pull_request_contribution`, both with unique keys.
  - Add `PanePullRequestAuthor` and its `author_key` codec.
  - Add `PaneContextStorage+PullRequests` and `PaneContextService+PullRequests`: `add`, `remove`, `removeForPerson` and `list`.
  - The 20-row cap is checked inside the add transaction.
  - Deleting the last contribution also deletes the row, in the same transaction.
  - Add both tables to the purge and reset lists.
- **Pre-change signal:**
  - a 21st PR accepted;
  - a duplicate row from a repeated add;
  - agent B removing agent A's contribution;
  - rows that survive a purge, or that vanish on relaunch.
- **Proof:** focused service tests on a real SQLite file, at the integration layer (project term: real storage, no app). They cover:
  - R4: 20 distinct PRs, then the 21st refused, and a new author's add to an existing PR still succeeds;
  - R5: own remove, last-author remove, someone else's remove, and absent remove;
  - R16: close and reopen the database, and the rows are unchanged;
  - R17: retire, Undo, purge;
  - the author key round-trip.

  Migration test on a database that already holds pane-context rows from 032 (not an empty database).
- **Earns:** Verification Design U3's R4 detail, U5 (service rows), and U7 (storage and lifecycle tests).
- **Existing tests:** extend the pane-context lifecycle purge tests to cover the new tables (`repair`: their purge expectation grows).
- **Stop:** retirement needs a new lifecycle state. That is a design break and goes to Program Design.

### S3. IPC methods and the `pr` CLI (vertical)

- **Reads:** Specification R1, R2, R3, R5, R6, R7, the CLI table and C5. Program Design: E4 binding, Interfaces, the Add call path and Cross-cutting/Trust. `App/IPCComposition/AgentStudioIPCPaneContextAdapter.swift:256` (`resolveWriter`), and `AgentStudioIPCPaneContextMapping.swift`. The IPC registry and inventory (`docs/architecture/commands/command_specs.md`, "Exhaustive interactive and IPC projections").
- **Change:**
  - Add `pane.pullRequest.add`, `remove` and `list`: `.anyTarget`, privileges `paneContextWrite`/`Read`, execution owner `.paneContextService`.
  - Add `AgentStudioIPCPanePullRequestAdapter`. It stamps the author from the principal and resolves the writer claim against the source pane.
  - Add `PullRequestCLI`, wired into `AgentStudioIPCClientCommandLineRunner`.
  - Add the inventory rows.
- **Pre-change signal:**
  - the PR lands on the caller's own pane;
  - a drawer child target is redirected;
  - a forged author field is accepted;
  - a server process is labelled with the source pane's bound session.
  - a client author keyed by the per-login `principalId`. The same automation credential on its next call can't remove its own add.
- **Proof:**
  - Adapter tests, focused, for every case in Verification Design U1's "R7 detail".
  - Real-server CLI tests on `PaneAgentControlHarness`, at the integration layer. They use the real CLI, the real App IPC server and the real decoder, beside `DrawerBrowseCLIRealServerTests`. There is one case per CLI-table line, plus `list`. The oracle is the Specification's CLI table.
- **Earns:** U1 and U5 at the CLI layer. Its real-app observation O-CLI runs in S7.
- **Client authors:** the key comes from the request's authenticated credential identity, never from `principalId` (Program Design E4, review N2). The real-server tests make two separately authenticated exchanges with one credential.
- **Stop:** the principal can't give a source pane for some pane credential kind. That is a design gap and goes to Program Design.

### S4. PR details by identity (vertical, off-main)

- **Reads:** Specification E6, R14, R15 and C4. Program Design: Entity binding E6 and the details-actor interface. `Core/RuntimeEventSystem/Forge/GitHubCLIForgeStatusProvider.swift` and its tests. The `AppPolicies.ForgeRefresh` freshness and backoff. Testing architecture, "How a test may wait".
- **Change:**
  - Add `GitHubCLIForgeStatusProvider.pullRequestDetails(identities:)`, a GraphQL query batched by alias.
  - Add `ForgePullRequestDetailsActor`: demand input, entry stream, `fresh | refreshing | failed(reason)`.
- **Pre-change signal:**
  - a refetch on every open;
  - fetches for hidden panes;
  - a failure that erases earlier details;
  - a stuck `couldn't refresh`.
- **Proof:** actor tests with a fake provider that counts requests, on `TestPushClock`. They cover:
  - none → loading → loaded;
  - no refetch before 180 s;
  - a refresh after 180 s that keeps the old details until the new ones land;
  - zero requests without demand;
  - the worktree identity demanded like the others;
  - loaded → failed → recovered.

  Provider test for response mapping and the reason codes. The oracle is R14, R15 and C4.
- **Existing tests:** keep `GitHubCLIForgeStatusProviderTests` and add cases.
- **Earns:** U6 (focused).

### S5. One list, worktree join and presentation (integration)

- **Reads:** Specification "PR list" and its sources, R6, R10, R11 and R12. Program Design: "One list owner", the E5 binding and the row shape. `Core/PaneContext/Contracts/PullRequestSummaryDetail.swift`, `PaneContextDisplay.swift` and `PaneContextService+Presentation.swift`. `App/Coordination/WorkspaceCacheCoordinator.swift`. `App/IPCComposition/AgentStudioIPCPaneContextDetailMapping.swift`. The MainActor and atom boundaries skill.
- **Change:**
  - `PaneContextService` composes `PanePullRequestList` from storage rows, the forwarded worktree identity and the detail entries. It republishes only on change and sends demand to S4.
  - `WorkspaceCacheCoordinator` forwards the worktree PR identity.
  - `PullRequestSummaryDetail` is reshaped into `PanePullRequestList`, and the `pane.context.get` mapping follows it.
  - `pr list` reads the same composition.
- **Pre-change signal:**
  - the worktree PR listed twice;
  - ordering by number instead of the specified order;
  - no remove offered on a mixed row;
  - the worktree row deleted;
  - `pr list` disagreeing with the popover.
- **Proof:**
  - Row-builder table test for ordering, de-duplication and mixed rows (U2), at the unit layer. The oracle is R11, R12 and E5.
  - Summary table test for R10.
  - Service test showing that one composition feeds both readers.
  - Detail-mapping test for the reshaped slot.
- **Existing tests:** `repair` the `PullRequestSummaryDetail` mapping tests, because the shape changes. Their "notApplicable" expectations become a dead contract under this change.
- **Earns:** U2 (focused), and R10 for U3.
- **Stop:** the join needs to run on MainActor. That is a performance-lane break and goes to Program Design.

### S6. The PR popover and toolbar button (vertical UI)

- **Reads:** Specification R8 to R13 and C2/C3. Program Design: the new spec entries, the popover interface and "Open the popover". `App/Panes/PanePullRequestToolbarActionFactory.swift`, `App/PaneContext/PaneContextPreparedPopoverHost.swift`, `SharedComponents/SelectablePopover/` and the `PopoverPanel` chrome. Style guide "Shared Shell Controls". The Command Specs decision tree and the tooltip pipeline.
- **Change:**
  - Add `AppCommand.showPanePullRequests` with its `ipcSpec` classification (not exposed).
  - Add `LocalActionSpec.openPanePullRequest` and `removePanePullRequest`.
  - Add `SharedComponents/PullRequestsPopover`: values in, callbacks out.
  - Add the `.pullRequests` surface to the prepared popover host.
  - The toolbar factory builds its summary from `PanePullRequestList`.
  - `openPullRequest` stays on the zoom toolbar and in the command bar.
- **Order inside the slice:** first the popover and its host on S5's real list, then a debug build, then frames to the owner, and only then the key-routing tests and hardening.
- **Pre-change signal:**
  - keys that act on the wrong row;
  - focus stolen on open or close;
  - labels or icons set on the view instead of coming from the spec;
  - the popover blocking or resizing while details load.
- **Proof:**
  - Key-routing tests on `SelectablePopoverKeyboardRouter` (R13).
  - Command-catalog display test extended: no "link" wording, PR octicon (U4).
  - Toolbar factory tests: `repair`, because the summary source changes.
- **Earns:** the focused rows for U3 and U4. The real-app rows run in S7.

### S7. Journeys and app observations (proof)

- **Reads:** Verification Design (all rows, O-CLI, O-POP, and the needed journeys), and `.agents/skills/verify-agentstudio/`.
- **Change (Verifier):** build the lasting journeys J11, "PR links via CLI" (including the server-process case), and J12, "PR popover", in `verify-agentstudio`. Then observe them on a debug build of the PR head.
- **Earns:** U1 (O-CLI including the server-agent case), U2/U3/U5/U6 (O-POP), and U7 (quit and relaunch, close/Undo inside J11). V11's visual verdict waits for the owner's frame review.
- **Batch boundary:** the Verifier's prebuild challenge runs after S1–S3 land (the CLI exists). J12 runs after S5 and S6.

## Dependencies

```text
S1 ──► S3 ──┐
S2 ──► S3   ├──► S5 ──► S6 (real-list frames) ──► S7 (J12)
S2 ──► S5   │
S4 ─────────┘           S3 ──► S7 (J11)
S6 popover component ‖ S2–S4  (values in, no data dependency until the host joins S5)
```

**Serial:** S3 and S5 both touch the IPC registry and mapping files, so they don't run concurrently.

## Obligation to proof

| Verification Design row | Slice | Focused command | Real-path observation |
| --- | --- | --- | --- |
| U1 add from any agent | S1, S3 | parser table; adapter tests; real-server CLI tests | J11 (O-CLI) incl. server-process case in S7 |
| U2 worktree beside added | S5 | row-builder table | J12 (O-POP) |
| U3 popover | S2 (R4), S5 (R10), S6 | cap test; summary table; key routing | J4 extended + J12; frames vs owner's design |
| U4 GitHub only, names | S1, S6 | parser table; catalog display test | — (structural) |
| U5 authors and removal | S2, S3 | service tests; adapter tests | O-CLI, O-POP |
| U6 details current | S4 | actor tests on `TestPushClock` | O-POP real fetch |
| U7 lifetime | S2 | storage round-trip, lifecycle purge | J11 quit/relaunch, close/Undo |

## Integration gates

- After S3, the real CLI reaches the real IPC server against real storage. This is the first point where the CLI, the adapter and the service meet.
- After S5, `pr list` and the published display agree for the same pane.
- After S6, a debug build exists, and real frames go to the owner before hardening.

## Risks and false greens

- A real-server test that uses an in-memory pane-context store instead of the file lane would miss R16. S2 and S3 use the real SQLite file.
- The details actor tested only with an always-succeeding fake would miss R15's kept-details rule. S4 includes the failure sequence.
- On a 3-core CI runner, the details actor and the service actor must not block the cooperative pool. Waits use facts, never polls.
- Migration numbering: `main` may add a local migration before this merges. Renumber at merge time and run the migration test again.
- #680 changes before merge: merge its head again, then rerun S1's drawer-browse guards.

## Stop and replan

- The owner changes choices 1–4 (the slices named in Scope).
- An accepted recheck finding changes a slice.
- Any design break named in a slice's Stop line.
- The owner's frame review changes R11's content (not only its layout). That goes to the Specification first.
