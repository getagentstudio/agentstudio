# Agent PR links: Program Design

How Agent Studio realizes the [Specification](specification.md). Built on branch `feat/agent-pr-links`, which starts at PR #680's head (`28b08f32e`) because `drawer browse` targeting and the shared popover keyboard parts live there. Code anchors are to that tree.

## Structure decision

**Selected; owner chose A on 2026-11-09 (choice 5)** ([Requirements](requirements.md#open-owner-choices)): agent-added PRs are **pane-context records**. The pane-context service (an actor, off the main thread) owns them, stores them in the pane-context lane of `local.sqlite`, retires them with the pane's other records, and publishes the pane's PR list through the existing `PaneContextDisplay.pullRequests` slot. A new small forge actor reads PR details by identity. The drawer toolbar's PR button opens a new shared `PullRequestsPopover`.

| Alternative | Gain | Cost | Why not |
| --- | --- | --- | --- |
| **A. Pane-context records (selected)** | One owner already has pane scope, authenticated IPC writes, retirement after the pane is gone, close/Undo behaviour, and a `pullRequests` presentation slot. | Two new tables in an existing lane; the 09-26 design put links in Bridge's membership. | — |
| B. Implement #376's `PaneLinkMembershipPort` in Bridge (N9/S11) | Matches the 09-26 design. | The port also requires worktree members, pending-removal settlement and removal facts, none of which this scope wants; its contributor requires a bound session, which U1 drops; Bridge has no pane retirement. | Scope is GitHub PRs only (U4); half-implementing a port breaks its contract. |
| C. Extend `ForgeActor` and the branch-keyed repo cache with explicit PRs | One forge owner. | The repo cache is keyed by repository and branch, memory-only, and fed by worktree demand; explicit PRs are pane-keyed, durable and authored. | Two truths with different keys and lifetimes in one owner. |

**Falsifiers that reopen it:** the owner wants worktree links in the same feature (then B); PR lists must be shared across panes or windows (then a workspace-level owner); `local.sqlite` loss on corruption recovery is unacceptable for this data (then the core lane).

**Deviation, authorized by the owner on 2026-11-09 (choice 5):** S11/R18–R19 (2026-09-26) placed links in Bridge's membership as its only writer, with a bound-session gate. U1 (owner, 2026-11-09) removes the gate and U4 narrows the scope to GitHub PRs; neither decides a new owner. This design proposes pane context as the owner for PR links only, leaves `PaneLinkMembershipPort` untouched for future worktree links, and accepts that a quarantined `local.sqlite` loses the list as it loses messages.

## Components

```text
 agentstudio CLI (AgentStudioIPCClientCore)
   PullRequestCLI ── PaneTargetFlags (shared with DrawerBrowseCLI)
        │ pane.pullRequest.add | remove | list   (JSON-RPC over the app socket)
        ▼
 AgentStudioAppIPC ── authenticates the credential → principal (source pane, bound session?)
        │ descriptor: .anyTarget, paneContextWrite/Read, executionOwner .paneContextService
        ▼
 App/IPCComposition
   AgentStudioIPCPanePullRequestAdapter ── MainPaneTargetValidation (shared with drawer.browse)
        │ stamps PanePullRequestAuthor from the principal
        ▼
 Core/PaneContext  PaneContextService (actor)          ◄── owner of E2, E3
   +PullRequests: add / remove / list / removeAll(person)
   PaneContextStorage+PullRequests ── local.sqlite: pane_pull_request, pane_pull_request_contribution
        │ publishes PaneContextDisplay.pullRequests (PanePullRequestList)
        ▼
 PaneContextPresentationAtom (MainActor, existing) ──► drawer toolbar PR button (summary)
                                                   └─► PaneContextPreparedPopoverHost .pullRequests
                                                          └─► SharedComponents PullRequestsPopover
 Core/RuntimeEventSystem/Forge
   ForgePullRequestDetailsActor (new)                   ◄── owner of E6 (memory-only)
     demand: pane PR identities for visible toolbars ∪ open popovers
     GitHubCLIForgeStatusProvider.pullRequestDetails(identities:)  (gh api graphql, by number)
        └─► details facts ──► PaneContextService joins rows ──► atom
 Worktree PR (E5): WorkspaceSurfaceCoordinator captures keyed facts (pane→worktree, worktree→branch key,
   branch key→PR URL, visibility) as one snapshot; PaneContextService joins them (see Inputs to the list).
```

Forbidden edges: SharedComponents never imports Core or App (the popover takes prepared values and callbacks); the CLI never stamps an author; nothing on the main thread fetches, joins or sorts rows (the actor prepares them, the atom only stores the prepared list).

## Entity binding

| E | Semantic owner | Home | Type home | Shape at each boundary | Role | Convention | Storage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 GitHub PR | Core models | existing | Three homes, one per boundary: (1) new `GitHubPullRequestReference.parse(_:) -> IPCPanePullRequestIdentity` in `AgentStudioProgrammaticControl` (the CLI's existing dependency) turns a URL or `owner/repo#n` into the existing wire identity (`IPCPaneMessageValues.swift:48`), lower-casing host, owner and repository; (2) the app adapter maps wire → `ForgePullRequestIdentity` through the existing `AgentStudioIPCPaneContextMapping` and refuses any host but `github.com` (the trusted check; it never re-parses strings); (3) `ForgePullRequestIdentity` is the Core and storage identity | CLI arg string → wire `IPCPanePullRequestIdentity {host, owner, repository, number}` → Core identity → SQL columns `host, owner, repository, number` (lower-cased) → presentation `PullRequestIdentityModel` | persisted inside E2 | existing wire and Core types; no new dependency edge | existing GRDB lane |
| E2 Pane PR | `PaneContextService` | new `PaneContextService+PullRequests.swift`, `PaneContextStorage+PullRequests.swift` | new table `pane_pull_request` (`pane_id`, host, owner, repository, number, `created_at`), unique `(pane_id, host, owner, repository, number)` | IPC result `IPCPanePullRequestAddResult` (closed: `added`, `alreadyPresent`, `paneFull`) | persisted | pane-context migrations (`WorkspaceLocalMigrations+PaneContext`) | local.sqlite, existing GRDB, existing migration tool (`033_create_pane_pull_requests` (next free local migration; 026–032 are taken on this branch, renumber if main adds more before merge)) |
| E3 Contribution | `PaneContextService` | same files | new table `pane_pull_request_contribution` (E2 key + `author_key`, `created_at`), unique on all; deleting the last contribution deletes the E2 row in the same transaction | IPC remove result (closed: `removed`, `notOnPane`, `addedBySomeoneElse`) | persisted | as E2 | as E2 |
| E4 Author | `AgentStudioIPCPanePullRequestAdapter` stamps; Core defines | new `PanePullRequestAuthor` (`Core/PaneContext/Contracts/`): `.paneAgent(sourcePaneId, conversation: (provider, conversationId)?)`, `.client(credentialKey)`, `.person`; percent-encoded `author_key` codec beside it (`agent:<pane>`, `agent:<pane>:<provider>:<conversationId>`, `client:<credentialKey>`, `person`). The key has no binding generation. | Principal `.spawnedPaneAgent(boundPaneId)` or `.paneClaim(paneId)` → pane agent with that source pane; `.automationClient`, `.futureMCPClient`, `.unsafeDebugClient` → `.client(credentialKey)` (U1 keeps every authenticated caller). `principalId` is minted fresh on every login (`AgentStudioIPCAuthentication.swift:488–497`) and each CLI call is its own exchange, so it never keys an author. `credentialKey` comes from the request's `connectionContext.authenticatedContext.credentialIdentity` (`AgentStudioAppIPCServer.swift:334`): `diagnostic:<generationID>` for the installed debug credential (stable across logins until it is reinstalled), and the fixed `unsafe-debug` for an explicit no-authentication debug connection, which has no credential and gets a fresh generation per connection. A future client credential kind keys by its record id. `unsafe-debug` is never a fallback: an unknown credential kind or a missing credential identity is refused, not grouped. Global principal semantics are unchanged. Conversation: the CLI sends its existing optional `IPCPaneWriterClaim` (the one `PaneCLICommandRunner` already builds); the adapter resolves it with the same Sessions lookup as `resolveWriter` (`AgentStudioIPCPaneContextAdapter.swift:256`) against the source pane. That lookup returns active and ended bindings; either one counts (the conversation was bound there), so a rebind or an ended session keeps the same key and the agent can still remove its own adds. No binding in the source pane (a server agent whose conversation lives elsewhere, or a forged claim) → source pane alone, never an error. Removal compares keys exactly; a different conversation from the same pane is a different author and gets `addedBySomeoneElse`. Presentation `PullRequestAuthorModel`: provider name, "an agent in <pane title>", "an automation client" or "You". | persisted as `author_key` | closed enum, like `BridgeLinkContributor` | as E2 |
| E5 Worktree PR | `ForgeActor` / `RepoCacheAtom` for the fact; `PaneContextService` for its place in the list | existing fact; one snapshot input (see Inputs to the list) | `PullRequestFacts` keyed by `RepoBranchKey` (repository + branch); a worktree's branch comes from its `WorktreeEnrichment` | Joined off the main thread in `PaneContextService` from the snapshot's pane → worktree, worktree → branch key and branch key → URL maps. Title and updated time come from E6 like every row. | derived, memory-only | existing | none |
| E6 PR details | new `ForgePullRequestDetailsActor` | new `Core/RuntimeEventSystem/Forge/ForgePullRequestDetailsActor.swift`; provider method `pullRequestDetails(identities:)` in `GitHubCLIForgeStatusProvider` (GraphQL `repository(owner,name){pullRequest(number:)}` aliases: title, state, isDraft, reviewDecision, mergeable, mergeStateStatus, statusCheckRollup, updatedAt, url) | new `ForgePullRequestDetailsEntry { last: ForgePullRequestDetails?, lastGoodReadAt?, health: fresh \| refreshing \| failed(reason) }`, reasons closed: `noAccess`, `notFound`, `rateLimited`, `offline`, `failed`. Row display: `loading` (no `last`, refreshing), `unavailable(reason)` (no `last`, failed), details, details + `couldn't refresh` (has `last`, failed) | `gh api graphql` response → entry → presentation row fields | cached, memory-only, keyed by E1 | existing forge status mapping | none |

**Inputs to the list.** One App-owned capture hands `PaneContextService` a complete snapshot of keyed facts. The main thread copies values; it never joins, filters or picks affected keys.

| Field of `PanePullRequestContextSnapshot` | Read from (MainActor atoms) | Key → value |
| --- | --- | --- |
| `paneFactsByPaneId` | pane graph per-key facts | pane id → raw placement (main or drawer child), residency and association worktree id, for every pane in `paneIDs`. The pane graph has no main-pane index, so the service derives main panes and the pane → worktree map off the main thread. |
| visibility inputs | the same raw values `captureRepositoryFactDemandInput` reads: active tab layout pane ids, active-residency panes, minimized panes, Zoom source and visible companion, window presentation | as captured |
| `enrichmentBranchByWorktreeId` | `RepoCacheAtom` worktree enrichment | worktree id → raw `(repoId, branch)` exactly as enrichment holds it, an empty branch included. The service builds `RepoBranchKey` and drops worktrees whose branch is empty (`RepoBranchKey.init?` rejects it). |
| `pullRequestURLByBranchKey` | `RepoCacheAtom` pull-request facts | `RepoBranchKey` → exact PR URL |

**Producer and contract.**
- **Producer:** `WorkspaceSurfaceCoordinator`, with an observation-tracked capture beside `captureRepositoryFactDemandInput` and the same generation pattern. The first capture runs when the coordinator binds.
- **Snapshots, not changes:** every capture is a whole snapshot, sent only when it differs from the last one sent. A removed pane, worktree, branch or PR is simply absent from the next snapshot.
- **Ordering:** snapshots travel in order through one `AsyncStream` with explicit buffering. Under the latest-state rule, the service may skip to the newest snapshot, which is safe because each one is complete.
- **Restart:** the service gets the bind-time snapshot, so there's no change log to lose.
- **No forwarding from `WorkspaceCacheCoordinator`:** it has many removal sites, and forwarding each one would invite missed changes.

**Join (off the main thread).** `PaneContextService` derives main panes and their worktrees from `paneFactsByPaneId`, then builds `RepoBranchKey` from the raw repository and branch and resolves pane → worktree → key → URL → E1, which gives the worktree PR per main pane, including hidden panes, so `pr list` stays exact (R6). It derives the visible main panes from the raw visibility inputs with a pure projection that follows `PullRequestDemandProjection`'s rules but is keyed by pane. It recomposes only the panes whose joined inputs changed, then sends the details actor the demand: rows of visible panes plus open popovers (C4).

**Cost and proof.** The capture fires on every enrichment change, so it is an `often` MainActor lane, and its cost is measured rather than assumed.
- **Marker:** S5 wraps the capture plus its equality comparison in one marker-scoped span on the existing performance trace recorder (`AgentStudioPerformanceTraceRecorder`). It runs with real-sized state: at least 60 panes, 120 worktrees and 60 PR facts.
- **Proof:** a run that records p50, p95 and the fire rate.
- **Decision:** if p95 of capture plus compare reaches 1 ms (the CLAUDE.md `heavy` MainActor bound), S5 splits the enrichment-branch read into its own narrower observation, re-measures, and the fix still stays a copy of keyed values with no join. Below 1 ms, the single capture stands.

**One list owner.** `PaneContextService` composes each pane's PR list from its E2/E3 rows, the E5 identity forwarded above, and the E6 entries it receives from the details actor, merging rows by E1 (sources `worktree: Bool` plus `authors: [PanePullRequestAuthor]`). Both `pane.pullRequest.list` and the published presentation read that one composition, so the CLI and the popover cannot disagree. A change to any of the three inputs recomposes the pane and republishes only when the result differs. The service also sends the details actor the demanded identities: every row of each pane whose toolbar is visible or popover open, the worktree row included.

The pane's list presentation reshapes the existing `PullRequestSummaryDetail` (today `notApplicable` everywhere; its member rows are worktree-only and nothing produces `.summary`) into `PanePullRequestList`: ordered rows of `{identity, isWorktree: Bool, authors: [author], details: loading | loaded(details, refreshFailure?) | unavailable(reason), canRemove: !authors.isEmpty}` plus the button summary `{count, worstChecks}`. A person's remove on a row that is also the worktree PR deletes the E2 and leaves the row with `isWorktree` only. The IPC `pane.context.get` mapping of that slot follows the new shape.

## Interfaces

| Interface | Caller → callee | Guarantee |
| --- | --- | --- |
| `pane.pullRequest.add {targetPaneHandle, pullRequest, correlationId}` | CLI → app | Authenticated only; `.anyTarget`; target must be an existing main pane (`notMainPane`, `targetNotFound`, `noActiveWindow` encodings exactly as `drawer.browse`); idempotent per (pane, PR, author); result `added | alreadyPresent | paneFull`. Never waits for GitHub. |
| `pane.pullRequest.remove {…}` | CLI → app | Withdraws only the caller's contribution; result `removed | notOnPane | addedBySomeoneElse`. |
| `pane.pullRequest.list {targetPaneHandle}` | CLI → app | Read-only (`paneContextRead`); rows in popover order with last known state. |
| `PaneContextService.addPullRequest(pane, identity, author)` etc. | adapter → actor | One transaction per call; publishes the pane's new list after commit; never runs on MainActor. |
| `PaneContextService.removePullRequestForPerson(pane, identity)` | popover action → actor | Removes every contribution; same publication. |
| `ForgePullRequestDetailsActor.setDemand(identities)` / entry stream | `PaneContextService` → actor → service | Reads only demanded identities, at most once per identity per 180 s (`AppPolicies.ForgeRefresh` freshness), with the existing backoff on rate limits. Each read moves the entry's health `refreshing` → `fresh` (new `last`, `lastGoodReadAt`) or `failed(reason)` (keeps `last`); the next good read clears `failed`. Publishes every health change. |
| `PullRequestsPopover(rows:, controls:, onOpen:, onRemove:, onClose:)` | App host → SharedComponents | Values in, callbacks out; `PopoverPanel` chrome, compound rows, `SelectablePopoverKeyboardRouter` (arrows, Return, Command-Delete via `.commandDelete`, Escape). |

New spec entries: `AppCommand.showPanePullRequests` ("Pull Requests", help "Show this pane's pull requests", `.octicon(.gitPullRequest)`) replaces `openPullRequest` on the drawer toolbar; `openPullRequest` stays for the terminal-zoom toolbar and command bar. `LocalActionSpec.openPanePullRequest` ("Open in Browser") and `LocalActionSpec.removePanePullRequest` ("Remove") drive the row controls. The new AppCommand is classified in `ipcSpec` as not exposed over IPC (the `pane.pullRequest.*` transport methods are the agent surface).

## Call paths

**Add (R1–R4, R7, R8)**, new path; no predecessor:

```text
agentstudio pr add https://github.com/o/r/pull/7 --target <B>
  PullRequestCLI.parse ── GitHubPullRequestReference.parse, PaneTargetFlags  (exit 2 / "not a GitHub pull request")
  → socket call pane.pullRequest.add {targetPaneHandle: B, pullRequest: {github.com,o,r,7}}
  → AppIPC auth: credential → principal(sourcePane A, session S?)       (no credential → -32001)
  → descriptor gate .anyTarget                                         (own-pane check skipped)
  → AgentStudioIPCPanePullRequestAdapter
       MainPaneTargetValidation(B)                                     (targetNotFound | notMainPane | noActiveWindow)
       wire identity → ForgePullRequestIdentity, host must be github.com  (invalidParams "notGitHub")
       source pane A from the principal                                (non-pane principal → author .client(credentialKey))
       writer claim (if sent) → Sessions binding (active or ended) in A? → .paneAgent(A, conv) else .paneAgent(A, nil)
  → PaneContextService.addPullRequest(B, id, author)   [actor]
       storage txn: insert E2 if absent (refuse paneFull at 20), insert E3 if absent
       → added | alreadyPresent | paneFull
       after commit: rebuild B's PanePullRequestList, publish to the mailbox
  → PaneContextPresentationAtom (MainActor) applies B's display  → toolbar button summary
  → details demand updated if B's toolbar is visible → ForgePullRequestDetailsActor reads E6 later
  ← CLI prints "added o/r#7 to the pane", exit 0
```

**Open the popover (R9–R15):** the toolbar button and `showPanePullRequests` both go through an app-owned, local `@Observable` presentation request for the location-target pane, following `PaneNotePresentation`. `PaneTabViewController` owns and composes it. The dispatcher sets the request and moves no focus. `DrawerOverlay.TrailingActions` gains a `pullRequestsPopoverContent: AnyView?` slot at the PR control's current position, like its existing note, inbox and pane-context slots. The App fills that slot with `PaneContextPreparedPopoverHost`'s `.pullRequests` surface, built from the already-published list without waiting on GitHub. The host consumes the request, opens anchored to the PR control, and adds the list's identities to details demand. Details arrive, the service republishes, and rows update in place under the panel's height latch. Local UI state, not an atom, per the coordination table.

**Changed edges:** `WorkspaceSurfaceCoordinator` gains the PR-context snapshot capture beside the repository-fact demand capture; the drawer toolbar's PR control changes from `openPullRequest` (open the worktree URL) to `showPanePullRequests` (open the popover); `PanePullRequestToolbarActionFactory` builds the summary from `PanePullRequestList` instead of the single worktree fact; `DrawerBrowseCLI` and `drawer.browse`'s adapter move their target parsing and main-pane validation into the shared `PaneTargetFlags` and `MainPaneTargetValidation` with unchanged behaviour (their existing tests are the guard).

## State, failure and concurrency

| Case | Behaviour |
| --- | --- |
| Duplicate add, same author | `alreadyPresent`; unique constraints make it idempotent under retries. |
| Two agents add the same PR concurrently | Actor serializes; both contributions recorded on one E2. |
| Add and person-remove race | Actor order decides; the loser sees `notOnPane` or a fresh E2. |
| Pane closed | Existing pane-context retirement hides and later purges; `033` rows are included in the purge list and the reset list. Undo restores because rows aren't deleted until permanent retirement. |
| `local.sqlite` unavailable or quarantined | Writes return the pane-context service's existing unavailable failure (`Agent Studio refused the call: storage unavailable`, exit 1); lists after recreation are empty (documented loss, same as messages). |
| GitHub read fails | Entry health `failed(reason)`: with earlier details the row shows them plus `couldn't refresh` with the reason and last good time; with none, `unavailable(reason)`. Backoff follows the `ForgeRefresh` policy; other rows unaffected; the next good read clears it (R15). |
| Worktree association changes | the next snapshot carries the pane's new worktree (or none), and any branch or PR change arrives the same way; the service recomposes; an added contribution on the old worktree PR keeps its row as an added row. |
| Caller is an automation or MCP client (no pane) | Accepted with author `.client(credentialKey)`; the same credential on a later, separately authenticated call is the same author and removes its own adds. Reinstalling the debug credential makes a new author. All no-authentication debug connections share one author. |
| App quits mid-call | One transaction; either both rows or none. CLI prints unreachable. |

## Cross-cutting

- **Trust:** authors come only from the authenticated principal (R7); `.anyTarget` limits the method to these three PR operations, recorded in the IPC inventory like `drawer.browse`.
- **Performance:** main-thread work is limited to the keyed snapshot capture, which is measured under the rule in Inputs to the list, and applying a prepared list; details demand is visible-toolbar or open-popover only (C4); batched GraphQL by alias, like the branch query.
- **Privacy/telemetry:** PR titles and session ids are not recorded (C5); counts and outcomes only.
- **Accessibility:** rows and controls carry spec-projected labels; keyboard-only use per R13.

## Trace

| U | R | E | Owner | Interface | Shape and home | State | Failure | Proof seam |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| U1 U5 | R1 | E1–E4 | PaneContextService | `pane.pullRequest.add` | params `{targetPaneHandle, pullRequest}`; tables 033 | E2/E3 present | storage unavailable | real CLI → app; storage read-back |
| U1 U4 | R2 | E1 | CLI + adapter | `GitHubPullRequestReference.parse` | string → identity | — | refused, no change | parser unit table; real CLI |
| U1 | R3 | E2 E4 | adapter | `MainPaneTargetValidation`, `.anyTarget` | IPC error encodings | — | targetNotFound / notMainPane / -32001 | real server CLI tests beside drawer browse |
| U3 | R4 | E2 | PaneContextService | add txn | count check in txn | 20 max | paneFull | service test |
| U5 | R5 | E2–E4 | PaneContextService | `pane.pullRequest.remove` | author_key match | withdrawn / E2 deleted | addedBySomeoneElse | service + CLI test |
| U1 | R6 | E2 E5 E6 | PaneContextService (one composition) | `pane.pullRequest.list` | `PanePullRequestList` rows | — | — | CLI list vs popover rows for the same pane, including a worktree-only pane |
| U5 | R7 | E4 | `AgentStudioIPCPanePullRequestAdapter` | principal → source pane; writer claim → Sessions lookup against the source pane | `author_key` | — | unbound or forged claim → source pane alone; non-pane principal → `.client(credentialKey)` | adapter tests: bound, ended binding, unbound, claim bound to another pane, same conversation after rebind (still own), different conversation same pane (someone else), automation principal |
| U3 | R8 | E2 | adapter | no focus/notice calls on the path | — | — | — | real app focus/responder readback |
| U3 U4 | R9 | E2 E5 | toolbar factory + AppCommand | `showPanePullRequests` | spec display | enabled/disabled | — | real app button state |
| U3 | R10 | E2 E5 E6 | toolbar factory | `PanePullRequestList.summary` | `{count, worstChecks}` | — | — | summary unit table |
| U2 U3 | R11 | E1 E2 E5 E6 | service list builder + `PullRequestsPopover` | prepared rows | row model | ordering | — | row-builder unit table; frames vs approved design |
| U3 U5 | R12 | E2 E3 E5 | popover host + service | `onOpen`, `onRemove` → `removePullRequestForPerson` | — | E2 deleted | — | real app open/remove |
| U3 | R13 | E2 | `PullRequestsPopover` | keyboard router | — | selection | — | key-event tests; native key rows |
| U6 | R14 | E5 E6 | ForgePullRequestDetailsActor | demand from PaneContextService + entry stream | `ForgePullRequestDetailsEntry` | refreshing → fresh | — | actor test with fake provider and push clock |
| U3 U6 | R15 | E6 | ForgePullRequestDetailsActor + row builder | entry health | `failed(reason)` with or without `last` | fresh → failed → fresh | per-row only | provider-failure sequence test; real nonexistent PR in the app |
| U7 | R16 | E2 E3 | PaneContextStorage | migration 033 | tables | persisted | — | restart round-trip test |
| U7 | R17 | E2 | PaneContextService lifecycle | retirement purge | purge list | hidden → purged | — | lifecycle test; close/Undo in app |

Deviations and unresolved decisions: the S11 Bridge-membership deviation above; GitHub Enterprise hosts refused (C1); the popover's visual design is iterated with the owner on real frames before test hardening.
