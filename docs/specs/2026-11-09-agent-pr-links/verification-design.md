# Agent PR links: Verification Design

How each requirement will be shown to hold. This is a plan; nothing here has been observed. Upstream: [Requirements](requirements.md), [Specification](specification.md) (proof obligations V1–V17), [Program Design](program-design.md) (trace table seams).

## Proven by

| Need | In the owner's words | Proven by | Stays unverified |
| --- | --- | --- | --- |
| U1 | Any agent adds a PR to a pane by naming it | In a debug app, a shell in pane A runs `agentstudio pr add` for pane B; B's PR list then shows that PR added by A's agent, and every refusal prints its documented line. | A server agent behind the Router (it reaches the installed app, so it needs a release that contains this). |
| U2 | Explicit PRs, not only the worktree's | A pane whose worktree has an open PR, plus two added PRs, shows all three, the worktree one first and labelled. | — |
| U3 | A well-designed popover with details | Clicking the PR button opens the popover; rows show the right details; open, remove and every key work with real clicks and key presses; frames are judged against the design you approve. | The design itself until you approve frames. |
| U4 | GitHub only, named in the GitHub family | Non-GitHub inputs are refused; the CLI verb and every label read as "pr" / "Pull Requests" with the PR icon. | GitHub Enterprise hosts (refused by design). |
| U5 | Authors; agents remove only their own | Remove by the author, by someone else and by you each behave as specified, in the CLI and the popover; a forged author is ignored. | — |
| U6 | Details stay current | With a fake GitHub and a controlled clock: loading, then details, refetch only after 180 s, nothing for hidden panes. In the app, a real PR's details appear after opening. | Real GitHub rate-limit behaviour. |
| U7 | PRs survive restart and follow the pane | The list is identical after quitting and relaunching the debug app on the same data; closing a pane hides its PRs, Undo restores them. | Permanent-deletion timing (about a day) beyond the purge test. |

## Coverage rows

### U1: add from any agent (R1, R2, R3, R6, R7)

| Field | Plan |
| --- | --- |
| requirement | U1 → R1 add records one contribution by the caller's author; R2 input forms; R3 targeting; R6 list; R7 author stamped by the app |
| proven by | A shell in pane A runs the real CLI against main pane B; `pr list` on B and the popover show one row with A's agent as author; each refusal prints its line. |
| reference | Specification CLI table; R3 cases identical to the `drawer browse` table in `docs/architecture/commands/ipc.md` |
| target and journey | Debug build of the branch head via `verify-agentstudio` J1. **needed: J11 "PR links via CLI"** (lasting): drives `"$AGENTSTUDIO_CLI" pr add/remove/list` from new pane shells A and B with `--target` and `--target-env`, reads printed lines, exit codes from pane-written `.rc` files, and `pr list`. It includes the **server-agent case**: a background process started from pane S's shell (so it holds S's credential, as a server agent does) runs `pr add --target B` with `CODEX_THREAD_ID` set to a fresh UUIDv7 that has no Sessions binding in S. `PaneCLICommandRunner.swift:356–362` turns that variable into the writer claim. The journey mints that id just before the add, so no earlier binding can hold it. It then confirms absence with a read-only `sqlite3 -readonly` count of the debug data root's binding rows (current and ended) for the id, because `session.query` returns only the current summary (`AgentStudioIPCSessionsAdapter.swift:122–143`). `CLAUDE_CODE_SESSION_ID` is unset in the child, because `PaneCLICommandRunner` checks it first. The stamped author "an agent in S" (rather than a provider name) shows that the unbound branch ran. Shared observation **O-CLI** below. |
| passes when | B (not A) has exactly one row `o/r#7`, author = A's agent; a repeat add leaves one row; a drawer child target prints `not a main pane: <id>` exit 1; no credential is refused; the server-agent case lands in B with author "an agent in S", not B's or S's bound session. Fails for a build that adds to the caller's own pane, duplicates rows, redirects drawer targets, or labels the server process with S's bound session. |
| reuses | none as proof. The plan adds real-server CLI tests on `PaneAgentControlHarness` (the harness `DrawerBrowseCLIRealServerTests` uses: real CLI, real App IPC server, real decoder) for every CLI-table line, and a parser test table for R2. |
| R7 detail | Focused adapter tests, no app launch: params carrying an extra author field are refused by strict decoding; a writer claim bound in the source pane gives a session author; a claim bound in another pane, or bound nowhere, gives the source pane alone; an ended binding still counts; the same conversation after a rebind removes its own add; a different conversation from the same pane gets `addedBySomeoneElse`; an automation principal adds as "an automation client" and, on a second separately authenticated exchange with the same credential (a new principalId), sees `alreadyPresent` for a repeat add and removes its own add; a different credential gets `addedBySomeoneElse`. |
| unverified | A real Codex behind the Router against an installed build containing this change: deferred by the owner on 2026-11-09 (choice 6); it runs on the first beta that contains this change. |

### U2: explicit PRs beside the worktree PR (R11 ordering, E5 join)

| Field | Plan |
| --- | --- |
| requirement | U2 → R11 one row per PR, worktree PR first and labelled |
| proven by | A pane whose worktree branch has an open PR and two added PRs shows three rows in the specified order; adding the worktree's own PR does not make a fourth. |
| reference | R11 and E5 identity rule |
| target and journey | Focused row-builder test table (pure ordering and de-duplication; no app). In the app: **needed: J12 "PR popover"** (lasting), observation **O-POP**. |
| passes when | Order worktree → newest added; an added worktree PR is one row with both sources; removing its contributions (agent or person) leaves the worktree row with no remove; a worktree-only pane lists its row in both `pr list` and the popover with details read by number; an association change moves the worktree label. Fails for a build that lists the worktree PR twice, orders by number, hides remove on a mixed row, or deletes the worktree row. |
| reuses | none |
| unverified | — |

### U3: the popover (R8, R9, R10, R11, R12, R13, R15)

| Field | Plan |
| --- | --- |
| requirement | U3 → R4 the 20-PR cap; R8 no focus change or notice; R9 button enable/open; R10 summary; R11 rows and fields; R12 open and remove; R13 keys; R15 unavailable rows |
| R4 detail | Focused service test on a real SQLite file, no app: 20 distinct PRs added, the 21st distinct add returns `paneFull` with the list unchanged, and a new author's add to one of the 20 still succeeds (a contribution, not a new row). Fails for an unlimited build or one that refuses contributions at capacity. |
| proven by | With Computer Use on the debug app: click the PR button, read the popover's rows, open one, remove one, drive every key, and compare frames with the approved design. |
| reference | R8–R15; the owner-approved popover frames (V11); `verify-agentstudio/references/visual-quality.md` for the taste verdict |
| target and journey | J1 debug launch; existing **J4 drawer toolbar** extended to read the PR button's count and colour; **needed: J12 "PR popover"** (lasting): opens it by the button, reads rows from the accessibility tree and Computer Use screenshots (never `pane-chrome.sh`, whose capture and inventory call Peekaboo), drives arrows/Return/Command-Delete/Escape with real key presses (Computer Use only, frontmost-gated), reads focus before and after. |
| passes when | Rows match R11 for the seeded list (worktree PR, two authors, one other repo); Return opens the selected PR's URL, read back as the default browser's front-tab URL via accessibility; Command-Delete removes the selected added row and its CLI `pr list` agrees; Escape closes and focus returns to the prior responder, read as the focused accessibility element before and after; the add in U1 leaves A's and B's focus, tab and drawer unchanged with no new notice (R8), read as unchanged notice counts from `pane.context.get` for A and B. A nonexistent PR number shows `unavailable: not found` while other rows load (R15). Fails for a build whose keys act on the wrong row, whose remove leaves contributions, or that steals focus. |
| reuses | Key routing focused tests on `SelectablePopoverKeyboardRouter` (plan); summary colour table for R10 (focused). |
| unverified | Taste until the owner approves frames. |

### U4: GitHub only, GitHub names (R2, C1, C2)

| Field | Plan |
| --- | --- |
| requirement | U4 → R2, C1 refuse non-GitHub; C2 names |
| proven by | Parser table refuses other hosts, issue and commit URLs; the spec catalog and CLI help show "pr" / "Pull Requests" with the PR octicon. |
| reference | C1, C2 |
| target and journey | none: focused parser test and structural catalog check (display projection test). |
| passes when | Every non-GitHub input refused with the exact line; no "link" wording in any display. Fails for a build that accepts `gitlab.com/...` or labels "Links". |
| reuses | Existing command-catalog display tests extended (plan). |
| unverified | — |

### U5: authors and removal (R5, R7, R12)

| Field | Plan |
| --- | --- |
| requirement | U5 → R5 remove rules; R7 stamping; R12 person remove |
| proven by | Service tests over a real SQLite file for: own remove, last-author remove, someone else's remove, absent remove; CLI lines via O-CLI; person remove via O-POP. |
| reference | R5 and the CLI table |
| target and journey | Focused service tests (real storage, no app); O-CLI and O-POP for the real entries. |
| passes when | Lines, exits and list state match each case; person remove deletes all contributions. Fails for a build that lets agent B remove agent A's contribution. |
| reuses | none |
| unverified | — |

### U6: details stay current (R14, R15, C4)

| Field | Plan |
| --- | --- |
| requirement | U6 → R14 demand and freshness; R15 per-row failure; C4 no fetch for hidden panes |
| proven by | Actor tests with a fake GitHub provider and a controlled clock show: no details → loading → loaded; no refetch before 180 s; after 180 s a refresh that keeps the old details visible until the new ones land; no request for hidden panes; the worktree identity demanded like added ones; and loaded → failed (details kept, `couldn't refresh` with reason) → recovered. In the app, O-POP shows real details arriving after opening. |
| reference | R14 (180 s from the existing forge freshness policy), R15, C4 |
| target and journey | Focused actor tests (`TestPushClock`, fake provider counting requests); O-POP for the real fetch. |
| passes when | Request counts and states match each step. Fails for a build that fetches on every open or for every pane. |
| reuses | Existing `ForgeActor` test fakes as a pattern only. |
| unverified | Real rate limiting. |

### U7: lifetime (R16, R17)

| Field | Plan |
| --- | --- |
| requirement | U7 → R16 restart; R17 close, Undo, purge |
| proven by | Storage round-trip and lifecycle tests on a real SQLite file; in the app, quit and relaunch the debug app on the same data root and see the same list; close pane B, Undo, see its PRs back. |
| reference | R16, R17 |
| target and journey | Focused storage and lifecycle tests; J1 owned quit and relaunch with the same `n`-code data root inside **J11**. |
| passes when | Identical rows before and after; hidden after close; restored by Undo; purged by permanent retirement. Fails for a build that drops rows on relaunch or keeps them after purge. |
| reuses | Existing pane-context lifecycle purge tests extended (plan). |
| unverified | Exact purge delay in real time. |

## Fixtures

All of these are declared for O-CLI and O-POP:
- **Worktree PR:** a debug-app pane whose worktree is a checkout of a branch with an open PR on this repository. `feat/drawer-browser` (PR #680) is the default while #680 is open.
- **Added PRs:** that same PR added by an agent (the de-duplication case); a second open PR in this repository; and one open PR in another public repository, for the other-repository field.
- **Unavailable row:** a nonexistent number, such as `ShravanSunder/agentstudio#999999`.
- **Authors:** pane A's agent, an unbound background process from pane S, and the debug client credential for the automation-client case.

Details come from the app's existing `gh` access on this Mac. When `gh` is unauthenticated, the U6 real-fetch cell is UNKNOWN, not passed.

## Shared observations

- **O-CLI:** real CLI in debug-app pane shells; exit codes read from pane-written `.rc` files (the method R18 used on #680); serves U1, U5, U7.
- **O-POP:** the PR popover opened by a real click in the debug app, rows read from the accessibility tree and Computer Use screenshots, keys sent only while the debug app is frontmost; serves U2, U3, U5, U6.

## Journeys still needed

| Journey | Lifetime | Entry | Reads |
| --- | --- | --- | --- |
| J11 PR links via CLI | lasting | `"$AGENTSTUDIO_CLI" pr …` in new pane shells | printed lines, `.rc` exits, `pr list` |
| J12 PR popover | lasting | the drawer toolbar PR button | popover rows, URL opened, focus, keys |

Both go into `verify-agentstudio` before the observations that depend on them, by the Verifier.
