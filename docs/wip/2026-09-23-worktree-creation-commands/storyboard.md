# Worktree Creation Commands — Storyboard

Status: revision 2, 2026-09-23. It applies the owner decision on a single
entry point and the orchestrator decisions. This is a working document, not a
design doc. Every claim about existing behavior cites a `path:line` that was
read on branch `worktrees-system`. Anything not in code today is marked
**PROPOSED**. Paths are repo-relative unless absolute.

Settled inputs:

- **Two operations, two names, two `AppCommand` identities.**
  - **Worktree** (`newWorktree`): a normal `git worktree add` that gives a
    clean checkout. It uses the SDK's `createWorktree`.
  - **Worktree Fork** (`forkWorktree`): an APFS copy-on-write fork. It uses
    the SDK's `forkWorktree`, which is specified but not yet implemented.
- **One command-bar entry (owner, 2026-09-23).** `> New Worktree...` leads to
  a source-worktree picker (focused worktree first), then a branch name, then
  one Create row. The Enter modifier decides which identity is dispatched:
  - `↵` or `⌘↵` dispatches `forkWorktree`.
  - `⌥↵` dispatches `newWorktree` (clean checkout).

## 0. What exists today (the mental model this storyboard builds on)

```text
                 ┌─────────────── command identity ────────────────┐
AppCommand case ─► AppCommandSpec (catalog) ─► CommandBarDataSource row
                 └─► ipcSpec (independent, exhaustive)              │
                                                                     ▼
       CommandBarPanelController.executeItem(item, modifier) ── dismiss ──► AppCommandDispatcher
         └ modifier consulted ONLY for .worktreeAction / .quickOpen rows       │ shell first,
                                                                               │ then workspace
                                     ┌─────────────────────────────────────────┴────┐
                                     ▼                                              ▼
                     ShellCommandHandling (AppDelegate)          WorkspaceCommandHandling
                     watchFolder, updateRepositoryFacts          (PaneTabViewController)

   worktree topology is DISCOVERED, never created:
   FSEvents ─► WatchedFolderTopologyAdmission ─► RepoScanner ─► .watchedFolderReconciled
            ─► WorkspaceCacheCoordinator ─► repositoryTopologyAtom ─► sidebar / command bar rows
```

What grounds the diagram:

- **Command-bar rows come from the catalog.**
  - `Features/CommandBar/CommandBarDataSource.swift:330-341`: `visibleCommands`.
  - `CommandBarDataSource.swift:387-432`: `commandItem`.
  - Commands that prefer `.targetSelection` become drill-ins at
    `CommandBarDataSource.swift:398-418` and `:435-547`.
- **Selection dismisses the bar before it dispatches.**
  - The dispatch sites are `CommandBarPanelController.swift:392-425`, with
    `dismiss` at `:398`, `:406` and `:424`.
  - The `.dispatch` and `.dispatchTargeted` rows ignore the `modifier`
    parameter (`:394-407`).
  - The modifier only reaches `.worktreeAction` (`:426-440`) and `.quickOpen`
    (`:445`, `:500-535`).
- **Precedent for mapping a modifier to a command.**
  - `CommandBarWorktreeActionResolver.resolve(presence:modifier:canOpenInCurrentTab:)`
    turns `EnterModifier` into `.dispatch(command:target:targetType:)` or
    `.showActionsMenu` (`Features/CommandBar/CommandBarWorktreeActionResolver.swift:4-40`).
  - `executeResolvedWorktreeAction` then applies `canDispatch`, records the
    recent, dismisses and dispatches (`CommandBarPanelController.swift:710-733`).
  - Quick Open has its own copy of the modifier-to-placement switch
    (`CommandBarPanelController.swift:505-560`).
- **Dispatcher order.** The shell owner is tried before the workspace owner:
  `App/Commands/AppCommandDispatcher.swift:30-44` for contextual commands and
  `:97-121` for targeted ones.
- **The app never calls the SDK's `createWorktree`.** A grep of `Sources`
  finds only an unrelated SQL migration name at
  `Core/State/MainActor/Persistence/WorkspaceLocalMigrations.swift:189`.
- **SDK version and creation modes.**
  - The app pins `agentstudio-git` at `2816ead` (`Package.swift:31-32`).
  - At that revision, `createWorktree(_:)` is at
    `agentstudio-git@2816ead:Sources/AgentStudioGitContracts/AgentStudioGitSDK.swift:8`.
  - Its modes are defined in `…/GitWorktreeContracts.swift:69-85`:
    `.existingBranch(name:)`, `.newBranch(name:startPoint:)` and
    `.detached(startPoint:)`.
  - `forkWorktree` exists only in the spec:
    `/Users/shravansunder/Documents/dev/project-dev/agentstudio-git.worktree-fork/docs/specs/2026-08-15-apfs-cow-worktree-creation/specification.md:70-127`.
- **SDK mutation serialization is process-wide.** This resolves the
  revision-1 grounding gap.
  - `LibGit2AgentStudioGitLocalClient.init()` passes
    `writerRegistry: .shared`
    (`agentstudio-git@2816ead:Sources/AgentStudioGitLocal/LibGit2AgentStudioGitLocalClient.swift:12-15`, `:24`).
  - `GitRepositoryWriterRegistry` is an actor with
    `static let shared` (`…/Runtime/GitRepositoryWriterRegistry.swift:4-5`).
  - The app creates several client instances, but they all share one writer
    lane per repository.
- **The app deploys to macOS 26 and later only** (`Package.swift:6-7`). The
  fork's "pre-macOS 26" rejection (`specification.md:133`) can never happen
  from the app.

## 1. Command identity table

Everything in this table is **PROPOSED**. There is one root command-bar row,
`newWorktree`. `forkWorktree` is a separate identity that the Create row
dispatches but that never has its own root row.

| Field | Worktree (`newWorktree`) | Worktree Fork (`forkWorktree`) | Pattern followed |
| --- | --- | --- | --- |
| `AppCommand` case | `newWorktree` | `forkWorktree` | Uses the "new…" verbs `newTab`, `newFloatingTerminal` and `newWindow` (`Core/Actions/Commands/AppCommand.swift:13,117,119`). The fork name mirrors the SDK's `forkWorktree` (`specification.md:75`). Both go in the `// Repo commands` block (`AppCommand.swift:69-74`). |
| Label | `New Worktree...` (the root row) | `Fork Worktree` (used for IPC `command.list` and the row's accessibility label) | A trailing `...` marks a command that asks for input first, as in `Rename Tab...` (`AppCommand+Catalog.swift:36`). |
| `CommandIcon` | `.octicon(.gitWorktree)`. This needs a new `OcticonSymbol` case. | Not shown on any root row. Use the same icon, or `.octicon(.repoClone)`, which needs a new case. | `OcticonSymbol` has only 5 cases (`Core/Actions/CommandIcon.swift:109-115`). The assets `octicon-git-worktree` and `octicon-repo-clone` already ship in `Resources/Icons.xcassets/`. `octicon-git-worktree` already names worktrees at `SharedComponents/AppEntityIcon.swift:22`. The fallback `.system(.arrowTriangleBranch)` (`CommandIcon.swift:15`) is used by worktree target rows (`CommandBarDataSource.swift:532`). |
| Help text | `Create a worktree from a source worktree's HEAD` | `Fork a worktree with its uncommitted, untracked, and ignored files` | One imperative sentence, like `Watch a folder and scan it for repositories` (`AppCommand+Catalog.swift:640`). Help text is also what IPC `command.list` projects (`AppCommand+IPCProjection.swift:18-20`). |
| `surfacePolicy` | `.exposed([.commandBar])` | `.notPresented` | The owner only requires the command bar. `removeRepo` is command-bar only (`AppCommand+Catalog.swift:654`). `.notPresented` is the documented policy for a "generated-target-row" command with no presented control of its own (`command_specs.md:208-209`). It keeps `forkWorktree` out of the `>` list because `visibleCommands` filters on `.commandBar` (`CommandBarDataSource.swift:333-339`). A sidebar `.contextMenu` for either command is out of scope for v1. |
| Targeting (source) | `.contextualAndTargeted([.worktree], preferredInvocation: .targetSelection)` | `.targeted([.worktree])` | Both commands take a **source worktree**. The worktree-targeted precedent is `bridgeDefinition` (`AppCommand+CatalogHelpers.swift:380-383`). The contextual source is `CommandContext.focusedWorktreeId` (`Core/State/MainActor/Atoms/CommandContext.swift:34`). Quick Open already reads the "current worktree" from `focusedPane?.worktreeId` (`CommandBarDataSource+QuickOpen.swift:181-191`). The worktree target level is `CommandBarDataSource.swift:524-539`, which lists in topology order today. Sorting the focused worktree first is **PROPOSED**. |
| `visibleWhen` | `[]` | `[]` | Repo commands carry no requirements (`watchFolder` at `:635-645`, `removeRepo` at `:648-658`). Capability belongs to `canDispatch`, not presence (`docs/architecture/commands/command_specs.md:223-227`). |
| Shortcut | none | none | `openWorktree`, `removeRepo` and `watchFolder` have none (`AppCommand+Catalog.swift:635-677`). The Create row's `↵`/`⌥↵` are row-local Enter modifiers, not `AppShortcut` bindings. See the badge precedent below. |
| Command-bar grouping | `"Repo"`, `CommandBarGroupPriority.repo` | same, unused while `.notPresented` | Follows `worktreeDefinition` (`AppCommand+CatalogHelpers.swift:118-119`), with priority `5` (`AppCommand+CommandBarGroupPriority.swift:9`). `AppCommand+Catalog.swift` is already 928 lines, so both entries belong in a helper file such as `AppCommand+SidebarCatalog.swift`. |
| Execution owner | `ShellCommandHandling` (`AppDelegate`) | same | The docs give shell actions "that do not need pane-local focus or drawer resolution" to `AppDelegate` (`command_specs.md:317`). The precedent is `updateRepositoryFacts`, repo-targeted async git work that `AppDelegate` owns (`App/Boot/AppDelegate+ShellCommandHandling.swift:193-207`, `:296-340`). This is not a `WorkspaceActionCommand`, because topology stays owned by discovery (`App/Coordination/WorkspaceCacheCoordinator+TopologyIngress.swift:31-33`). |
| IPC classification | **DECIDED: unexposed in v1.** Every exhaustive switch still classifies it, the same way as the retired Inbox identities: `.debugTesting`, `[.noArguments]`, `[.unavailable]`. | same | `IPCMethodExposure` has only `.allChannels` and `.debugTesting` (`Sources/AgentStudioProgrammaticControl/IPCMethodDescriptorMetadata.swift:3-6`), so "unexposed" means "classified but refused". Inbox precedent: arguments at `AppCommand+IPCProjection.swift:69-76`, exposure at `:218-222`, results at `:454-463`. The owner fails closed by default (`App/Commands/AppCommandExecution.swift:94-98`). Privilege: use `.layoutMutate` as a placeholder, which is what `openWorktree` uses (`:357-358`). No repository-mutation privilege exists (`:34-61`), so G8 is deferred. Target kinds: `[.window]`, because `.worktree` has no `IPCHandleKind` (`AppCommandDispatcher.swift:292-303`). |

Other exhaustive switches must also classify both cases. I found them by
grepping for `updateRepositoryFacts`:

- `Core/Actions/ActionResolver.swift:120,165`
- `Core/Actions/Commands/AppShortcutDispatchPolicy.swift:93`
- `App/Boot/AppDelegate+ShellCommandHandling.swift`: `canExecute` at
  `:19-82`, `executeShellAction` at `:92-191`, targeted `execute` at
  `:193-`
- `App/Boot/AppDelegate+HeadlessIPCCommandHandling.swift`
- `App/Panes/PaneTabViewController.swift:3634`, which is the workspace
  `execute` ignore list

## 2. Storyboard — one flow, two identities

The layout follows `CommandBarView.swift:21-71`: status strip, search field,
breadcrumb (nested levels only), results, then footer.

- C1–C3 use only existing behavior, plus the one **PROPOSED** ordering
  change.
- C4 onward depend on the decided gap resolutions in §3.

### C1 — open the command palette

```text
┌──────────────────────────────────────────────────────────────┐
│                               ⌨ worktrees-system · terminal  │  status strip
├──────────────────────────────────────────────────────────────┤
│ »  > _                                                       │  "Run a command..."
├──────────────────────────────────────────────────────────────┤
│  Recent                                                      │
│    Open Worktree                                          ›  │
├──────────────────────────────────────────────────────────────┤
│ ↵ Open  → Drill in                                  esc Close │
└──────────────────────────────────────────────────────────────┘
```

**Emits**

- `⌘⇧P` fires `AppShortcut.showCommandBarCommands`
  (`AppShortcut.swift:440-443`).
- That goes through `AppCommandDispatcher.dispatch(.showCommandBarCommands)`
  (`AppCommandDispatcher.swift:30-44`) to `ShellCommandHandling`, which calls
  `showCommandBar(prefix: ">")`
  (`AppDelegate+ShellCommandHandling.swift:133-135`).
- `CommandBarState.show(prefix:)` sets the scope to `.commands`
  (`CommandBarState.swift:200-227`, `:91-98`).
- The empty `>` root shows recent commands
  (`CommandBarDataSource+RootProjection.swift:43-47`).
- Nothing in the workspace, topology or atoms changes.

### C2 — type "worktree": one creation row

```text
┌──────────────────────────────────────────────────────────────┐
│ »  > worktree_                                               │
├──────────────────────────────────────────────────────────────┤
│  Repo                                                        │
│ ▸ ⧉ New Worktree...                                       ›  │  PROPOSED (newWorktree)
│   ▭ Open Worktree                                         ›  │  existing
│   ◫ Open Worktree in Pane                                 ›  │  existing
│   ▣ Open Terminal in New Tab                              ›  │  existing
│  Bridge                                                      │
│   ▢ Files                                                    │  existing
├──────────────────────────────────────────────────────────────┤
│ ↵ Open  → Drill in                                  esc Close │
└──────────────────────────────────────────────────────────────┘
   (row order within a group follows search ranking; illustrative)
```

**Emits**

- Nothing is dispatched. The results come from filtering
  (`CommandBarResultSession.swift:55-110`).
- The `New Worktree...` row is built by `commandItem`
  (`CommandBarDataSource.swift:398-418`). Because it prefers
  `.targetSelection`, the row has `hasChildren: true` and the action
  `.navigate(level)`.
- There is no Fork row. `forkWorktree` is `.notPresented`, and
  `visibleCommands` drops it (`CommandBarDataSource.swift:333-339`).
- Search keywords are the label words, the help-text words and the raw case
  name (`CommandBarDataSource.swift:930-936`). "fork" matches `newWorktree`
  only if its help text contains the word "fork". Whether it should is
  cosmetic.

### C3 — pick the source worktree (focused first)

```text
┌──────────────────────────────────────────────────────────────┐
│ »  Filter..._                                                │
│  Commands › New Worktree...                                  │  breadcrumb
├──────────────────────────────────────────────────────────────┤
│  Worktrees                                                   │
│ ▸ ⎇ worktrees-system    agent-studio   ● focused pane        │  PROPOSED: focused first
│   ★ agent-studio        agent-studio                         │
│   ⎇ perf-residuals      agent-studio                         │
│   ★ agentstudio-git     agentstudio-git                      │
├──────────────────────────────────────────────────────────────┤
│ ⇧⇥ / ⌫ Back                                         esc Close │
└──────────────────────────────────────────────────────────────┘
```

**Emits**

- `executeItem(.navigate(level))` calls `CommandBarState.pushLevel`
  (`CommandBarPanelController.swift:408-409`, `CommandBarState.swift:274-278`).
- The existing `buildTargetLevel` worktree branch emits one row per worktree
  (`CommandBarDataSource.swift:524-539`). Each row is
  `.dispatchTargeted(.newWorktree, target: worktree.id, targetType: .worktree)`.
  - **PROPOSED:** for `newWorktree`, these rows become `.navigate` into the
    C4 level instead.
  - Today, choosing a row would dispatch immediately with no branch name.
  - The focused worktree comes from `CommandContext.focusedWorktreeId`
    (`CommandContext.swift:34`).
- The footer is the nested `FooterHintBuilder` branch
  (`CommandBarItem.swift:412-421`).

### C4 — type the branch name; one Create row with Enter-modifier variants

```text
┌──────────────────────────────────────────────────────────────┐
│ »  Branch name: feat/worktree-commands_                      │
│  Commands › New Worktree... › worktrees-system               │
├──────────────────────────────────────────────────────────────┤
│ ▸ ⧉ Create "feat/worktree-commands"  at worktrees-system HEAD 18cbc3e │
│     → ~/dev/project-dev/agent-studio.feat-worktree-commands  │  destination (§5 D2)
│     ↵ Fork: uncommitted, untracked, and ignored files come   │
│       along; staged changes become unstaged                  │
│     ⌥↵ Clean worktree: committed HEAD only                   │
├──────────────────────────────────────────────────────────────┤
│ ↵ Fork   ⌥↵ Clean worktree   ⇧⇥ / ⌫ Back           esc Close  │
└──────────────────────────────────────────────────────────────┘
```

**Emits (PROPOSED)**

- **The text field has to capture input.** Today the nested field only
  filters:
  - The placeholder is `"Filter..."` (`CommandBarState.swift:161-164`).
  - The query is filter-only (`CommandBarResultSession.swift:68`,
    `:119-124`).
  - Levels hold fixed `items` (`CommandBarItem.swift:308-331`).
  - The "Create" row is derived from the query. That needs a new level kind
    or a new `CommandBarAction` case (`CommandBarItem.swift:59-76`). This is
    gap G1. It is the one gap the owner's flow requires and that the
    orchestrator decisions do not settle.
- **Enter-modifier resolution.**
  - **PROPOSED** `CommandBarWorktreeCreationResolver`, a sibling of
    `CommandBarWorktreeActionResolver` (`CommandBarWorktreeActionResolver.swift:9-40`).
  - It maps `.plain` and `.command` to `forkWorktree`, and `.option` to
    `newWorktree`. It returns a resolution that `CommandBarPanelController`
    executes the same way as `executeResolvedWorktreeAction` (`:710-733`):
    `canDispatch`, then record the recent, then `dismiss`, then dispatch.
  - This is needed because `executeItem` ignores the modifier for
    `.dispatch` and `.dispatchTargeted` rows (`:394-407`). The Create row
    therefore needs its own action case that forwards the `EnterModifier`,
    the way `.worktreeAction` does (`:426-440`).
- **Hints.**
  - Footer: the precedent is the modifier-aware hints for
    `.quickOpen`/`worktreeOpenState` rows (`CommandBarItem.swift:426-464`,
    `cmd-enter` and `opt-enter`).
  - Row badge: the precedent is `terminalWorktreeActionItems`, which sets
    `ShortcutTrigger(key: .enter, modifiers: [.option])` as the row's
    `shortcutTrigger` (`CommandBarDataSource+WorktreeRows.swift:448`).
  - `⌘↵` resolves to Fork like `↵`. The footer does not list it separately.
- **Content.**
  - The fork cue restates the destination status matrix
    (`specification.md:221-227`, included state `:153-157`).
  - The source HEAD label comes from the worktree's git status enrichment,
    which the app already reads through
    `Core/RuntimeEventSystem/Git/AgentStudioGitWorkingTreeStatusProvider.swift:39`.
- **Validation before the row is enabled.** A non-empty, valid ref name is
  required, and the destination parent must be inside a watched folder
  (§5 D2). Ref-name validation code was not searched for.

### C5 — dispatch (the bar is gone)

```text
Sidebar (Repos)                         Command bar: dismissed
┌──────────────────────────────────┐    (no progress UI in v1 — §5 D6)
│ ★ agent-studio                   │
│   ├ ★ agent-studio               │
│   ├ ⎇ worktrees-system           │
│   │                              │  ← nothing appears yet: destination held (§5 D4)
└──────────────────────────────────┘
```

**Emits (PROPOSED unless cited)**

- **Dispatch.** The bar dismisses first
  (`CommandBarPanelController.swift:720-722` pattern). Then:
  - A **dedicated dispatcher method** is called, following
    `dispatchMovePaneToTab` (`AppCommand.swift:252`,
    `AppCommandDispatcher.swift:191-204`) and `dispatchQuickOpenDirectory`
    (`:206-215`). It looks like
    `dispatchWorktreeCreation(command: .forkWorktree | .newWorktree, sourceWorktreeId:, branchName:)`.
  - It re-checks `definition.targeting.supports(.worktree)` plus
    `canDispatch(command, target:, targetType: .worktree)`, as
    `dispatchMovePaneToTab` does at `:192-196`.
  - It then routes to the `ShellCommandHandling` owner.
  - Existing interactive arguments cannot carry a branch name. They are
    limited to `.noArguments` and `.typedIPC`
    (`AppCommandExecution.swift:71-76`), and `dispatch(request)` rejects
    anything else (`AppCommandDispatcher.swift:65`).
- **Owner steps, in order:**
  1. Resolve the source and the destination (§5 D2).
  2. Pre-check that the destination is inside a watched folder, or reject
     (C8).
  3. Register an **in-flight hold** for the destination with
     `FilesystemActor` (§5 D4).
  4. Call the SDK off-main:
     - Fork: `client.forkWorktree(GitForkWorktreeRequest(sourceWorktreePath:,
       destinationPath:, mode: .newBranch(name:)))`
       (`specification.md:74-92`).
     - Clean: `client.createWorktree(GitCreateWorktreeRequest(repositoryPath:,
       destinationPath:, mode: .newBranch(name:, startPoint: <source HEAD>)))`
       (`GitWorktreeContracts.swift:69-85`). I did not inspect the shape of
       `GitRevisionTarget`.
  5. Both calls serialize on the repository's process-wide writer lane (§0).
- **Filesystem facts during the call.**
  - `git_worktree_add` writes `<clone>/.git/worktrees/<name>/` and
    `<dest>/.git`.
  - A path containing `/.git/` always admits a scan
    (`WatchedFolderTopologyAdmission.swift:10`, `:46-48`).
  - **PROPOSED:** the hold keeps scan results under `<dest>` from being
    published (§2.1).
- **No progress atom.** The existing progress channel,
  `RepoCacheAtom.setRepositoryFactUpdateProgress`
  (`Core/State/MainActor/Atoms/RepoCacheAtom.swift:614`), is deliberately not
  extended in v1.

### C6 — SDK returns success → targeted refresh → sidebar row

```text
Sidebar
┌──────────────────────────────────┐
│ ★ agent-studio                   │
│   ├ ★ agent-studio               │
│   ├ ⎇ worktrees-system           │
│   └ ⎇ agent-studio.feat-work…    │  ← appears once, complete (no auto-open, §5 D3)
└──────────────────────────────────┘
```

**Emits**

- **What the SDK returns.**
  - Clean: `GitWorktreeSnapshot` (`GitWorktreeContracts.swift:11-49`).
  - Fork: `GitForkWorktreeResult { worktree, materialization }`
    (`specification.md:107-127`). The report is logged only (§5 D7).
- **The owner releases the hold (PROPOSED) and triggers a targeted refresh.**
  - It refreshes only the watched folder that contains the destination.
  - Existing seam: `FilesystemActor.refreshWatchedFolders(_:scanning:)`
    already accepts `selectedPathIDs`
    (`Core/RuntimeEventSystem/Filesystem/FilesystemActor+WatchedFolderScanning.swift:57-58`).
  - The pipeline-level `FilesystemGitPipeline.refreshWatchedFolders(_:)`
    passes the given watched paths through
    (`App/Coordination/FilesystemGitPipeline.swift:355-363`).
  - Compare the existing whole-workspace rescan:
    `refreshRegisteredWorktreesAndWatchedFolders` (`:385-391`), reached via
    `AppDelegate+LifecycleRouting.swift:83-88`.
- **The publication path is unchanged.**
  - The scan finds `<dest>/.git` as a `.linkedWorktree`
    (`RepoScanner.swift:125-152`).
  - `FilesystemActor` posts `.watchedFolderReconciled`
    (`FilesystemActor+WatchedFolderResultApplication.swift:170-189`).
  - `WorkspaceCacheCoordinator` consumes it
    (`App/Coordination/WorkspaceCacheCoordinator.swift:137-143`), then runs
    `consumeWatchedFolderObservation`, then `applyRepositoryLifecycleChange`,
    then `topologyEffectHandler.topologyDidChange`
    (`WorkspaceCacheCoordinator+ScopedTopology.swift:7-69`).
  - The row lands in `repositoryTopologyAtom`, and the sidebar and command-bar
    rows follow.
- **The new row is named after the folder.** The name is
  `lastPathComponent` of the destination, not the branch name
  (`WorkspaceCacheCoordinator+DiscoveredWorktrees.swift:20-23`).
- **Later events are ignored.** `FilesystemActor` later emits
  `.worktreeRegistered` (`FilesystemActor.swift:248`). The cache coordinator
  drops it (`WorkspaceCacheCoordinator.swift:150-153`,
  `…+TopologyIngress.swift:31-33`).
- **Nothing opens automatically.** There is no `openWorktree` dispatch
  (§5 D3).

### C7 — fork eligibility rejection (no mutation)

```text
            ┌──────────────────────────────────────────────┐
            │  ⚠  Worktree Fork not created                 │   modal NSAlert (§5 D7)
            │                                               │
            │  worktrees-system and the destination are on  │
            │  different volumes; an APFS fork needs both   │
            │  on the same volume. Nothing was changed.     │
            │                                               │
            │  Tip: ⌥↵ creates a clean worktree instead.    │
            │                                  [ OK ]       │
            └──────────────────────────────────────────────┘
```

**Emits**

- **The SDK rejects before mutating** and returns a stable typed reason
  (`specification.md:131-147`). `GitWorktreeForkError` separates preflight
  rejection from other failures (`:100-105`), so "Nothing was changed" is
  accurate.
- **Reachable reasons:**
  - The volume is not APFS.
  - The source and destination are on different volumes.
  - The volume cannot clone files.
  - The source has no `HEAD`.
  - The destination already exists.
  - The destination parent is missing.
  - The source and destination roots overlap.
  - A nested repository or submodule has admin data on another volume.
- "pre-macOS 26" cannot happen (`Package.swift:6-7`).
- **The row is always shown (§5 D5).** There is no preflight at
  presentation or `canDispatch` time. `shouldPresent` is pure
  (`AppCommandPresentationPolicy.swift:109-124`), and `canDispatch` is
  synchronous on the MainActor (`AppCommandDispatcher.swift:217-273`).
- **The owner releases the hold.** No refresh is needed because nothing was
  created.
- **There is no `NSAlert` precedent in app sources.** `grep -rn "NSAlert()"
  Sources/AgentStudio` finds nothing, so this is a new presentation site in
  the shell owner.

### C8 — app-side rejection before the SDK call

```text
            ┌──────────────────────────────────────────────┐
            │  ⚠  Worktree not created                      │
            │                                               │
            │  ~/dev/project-dev is not inside a watched    │
            │  folder, so the new worktree would never      │
            │  appear in the sidebar. Nothing was changed.  │
            │                                  [ OK ]       │
            └──────────────────────────────────────────────┘
```

**Emits**

- **The owner's precheck rejects the request (§5 D2).** Discovery only finds
  non-hidden directories (`RepoScannerSession.swift:861-865`) at most 4
  levels below a watched root (`RepoScanner.swift:38-41`). The scanner only
  validates candidates it traverses
  (`Infrastructure/RepoScannerGitDiscoveryClient.swift:21-47`).
- The watched roots are `repositoryTopologyAtom.watchedPaths`, the same
  source that `AppDelegate+LifecycleRouting.swift:84` reads.
- **Better:** C4 disables the Create row with the same reason, so this
  alert is a backstop.

### C9 — failure after mutation (rolled back, or residue)

```text
            ┌──────────────────────────────────────────────┐
            │  ⚠  Worktree Fork failed                      │
            │                                               │
            │  src/generated/out changed type while copying.│
            │  Everything created was rolled back.          │
            │   — or —                                      │
            │  Cleanup is incomplete. Left on disk:         │
            │    branch fork/worktrees-system-2             │
            │    ~/dev/…/agent-studio.fork-worktrees-sys…   │
            │                   [Reveal in Finder]  [ OK ]  │
            └──────────────────────────────────────────────┘
```

**Emits**

- **SDK behavior.**
  - Fork: the rollback order and the verified-residue error follow
    `specification.md:296-308` and `program-design.md:430-463`.
  - Clean: the SDK throws `GitDataPlaneError` (`AgentStudioGitSDK.swift:8`).
    I did not inspect its cases, so the wording of the clean-failure alert is
    TBD.
- **The owner releases the hold, then runs the targeted refresh from C6.**
  - Rolled back: the scan finds nothing new, so no row appears.
  - Residue that remains a valid linked worktree: the refresh publishes it,
    and the alert has already listed it. I have not verified whether residue
    from a partial fork looks valid to the scanner.
- **Removal path.** If a row was ever published, it is removed through
  `clearPaneAssociations`
  (`WorkspaceCacheCoordinator+ScopedTopology.swift:58-62`).

### 2.1 Publication sequence with the in-flight hold

```text
 creation owner (shell)      FilesystemActor                      SDK                       filesystem
      │ hold(dest) ────────────►│ PROPOSED: suppress entries          │                          │
      │                         │ under dest from observations        │                          │
      │ request ─────────────────────────────────────────────────────►│ git_worktree_add ───────►│ <clone>/.git/worktrees/…
      │                         │◄──────────── FSEvents ("/.git/" → scan admitted) ──────────────│ <dest>/.git
      │                         │ scan runs; dest entry HELD           │ ┌─ half-built window ─┐  │
      │                         │ (not in .watchedFolderReconciled)    │ │ clean: checkout      │  │
      │                         │                                      │ │ fork: materialize →  │  │
      │                         │◄── dir-create FSEvents (rescans) ────│ │ rehome → index →     │  │
      │                         │                                      │ │ validate             │  │
      │                         │                                      │ └──────────────────────┘  │
      │◄──────────────────────────────────────────── result / error ───│                          │
      │ release(dest) ─────────►│                                      │                          │
      │ refresh(containing watched path) ─► scan → .watchedFolderReconciled → WorkspaceCacheCoordinator → atom
```

- **Why a hold.** Without it, the destination is published half-built.
  - Git-topology paths always admit a scan
    (`WatchedFolderTopologyAdmission.swift:10`).
  - `RepoScanner` classifies `<dest>/.git` as soon as it exists
    (`RepoScanner.swift:125-152`).
  - The fork's `git_worktree_add` (GIT_CHECKOUT_NONE) runs *before*
    materialization, re-homing, index build and validation
    (`program-design.md:214-238`; states at `:240-258`).
  - The SDK does not promise that the worktree is invisible during this
    window (`specification.md:310-313`).
  - Rollback deletes the destination (`:296-302`), so an early row would
    vanish.
- **Where the hold lives (PROPOSED).**
  - Candidate: filter held paths out of the entries used to build
    `WatchedFolderTopologyObservation`
    (`FilesystemActor+WatchedFolderResultApplication.swift:170-189`). This
    sits before `.watchedFolderReconciled` is posted, so the cache
    coordinator and atoms stay unaware of it.
  - This adds new state to `FilesystemActor`.
  - Undecided: whether a held path also suppresses `.worktreeRegistered` or
    the git projector registration.
- **Rescans while the fork materializes.** A directory create outside every
  *known* checkout admits a scan (`WatchedFolderTopologyAdmission.swift:15-28`).
  The destination is not known while it is held, so a fork triggers repeated
  rescans. The hold decides *publication*, not *admission*.
  - I have not verified whether `submitWatchedFolderScan`
    (`FilesystemActor+WatchedFolderScanning.swift:314`) coalesces repeated
    submissions.
  - **PROPOSED option:** also skip admission for batches wholly under a held
    path.
- **Process death mid-creation.** The hold is in-memory. After a crash, the
  next launch discovers whatever state is left. Crash recovery is out of the
  SDK's scope (`specification.md:306-308`, `:369-376`).

## 3. Capability gaps (status after decisions)

**G1 — Free-text branch name in the command bar. OPEN, required by the owner's
flow.**

- Evidence:
  - The nested field is a filter (`CommandBarState.swift:161-164`;
    `CommandBarResultSession.swift:68`, `:119-124`).
  - Levels are static (`CommandBarItem.swift:308-331`).
  - No `CommandBarAction` submits the query (`CommandBarItem.swift:59-76`).
- The owner chose in-bar entry (C4). What remains is the shape:
  - (a) A text-entry level kind whose rows derive from the query.
  - (b) A `CommandBarAction` case that carries a `(query) -> [CommandBarItem]`
    projection.

**G1b — Enter modifier on a dispatch row. PROPOSED.**

- Evidence: `executeItem` forwards the modifier only to `.worktreeAction`
  and `.quickOpen` (`CommandBarPanelController.swift:392-445`).
- Plan: a new creation-row action case, plus a resolver that follows
  `CommandBarWorktreeActionResolver` (`:9-40`).

**G2 — Interactive dispatch with arguments. DECIDED: dedicated dispatcher
method.**

- Precedents: `dispatchMovePaneToTab` (`AppCommand.swift:252`,
  `AppCommandDispatcher.swift:191-204`) and `dispatchQuickOpenDirectory`
  (`:206-215`).

**G3 — Progress. DECIDED: no progress atom in v1.**

- The bar dismisses before dispatch (`CommandBarPanelController.swift:398,406`).
- A fork of a large, prepared worktree will show nothing until the row
  appears or an alert fires. See the note in §5 D6.

**G4 — Publication and the half-built window. DECIDED: in-flight hold in
`FilesystemActor` plus a targeted watched-folder refresh.**

- See §2.1.
- Open sub-items:
  - Where the hold filters: observations or admission.
  - Whether scans coalesce.

**G5 — Destination path policy. DECIDED: a sibling of the repo's main
worktree, and it must be inside a watched folder.** See §5 D2.

**G6 — Fork eligibility before dispatch. DECIDED: always present, and
surface the SDK's preflight rejection** (C7).

**G7 — Result and failure surface. DECIDED: failures are shown as a modal
`NSAlert`, and the success report is only logged.**

- There is no `NSAlert` precedent in the app, so this is a new site.

**G8 — IPC privilege vocabulary. DEFERRED.** IPC is unexposed in v1.

## 4. Remaining open questions for the owner

1. **Secret-shaped ignored files.** A fork copies all ignored files,
   including `.env`. Excluding them is an explicit product-policy decision
   outside the SDK (`specification.md:378-380`). Keep "copy everything" for
   v1?
2. **Fork progress.** With no progress UI in v1, a fork of a large worktree
   shows nothing for its whole duration. Is that acceptable for v1, or
   should the sidebar show a minimal non-atom cue (for example, the
   dismissed bar's recent row)?

## 5. Decisions

- **D0 (OWNER).** One command-bar entry, `New Worktree...`.
  - Flow: pick the source worktree (focused first), then type the branch
    name, then use one Create row.
  - `↵` and `⌘↵` dispatch `forkWorktree`.
  - `⌥↵` dispatches `newWorktree` (clean checkout).
  - The two identities stay distinct.
- **D1 (DECIDED by orchestrator; the owner may revise).** Both variants
  create a **new branch at the selected source worktree's HEAD**. There is
  no existing-branch checkout in v1.
  - For the fork, this is the only identity the spec allows
    (`specification.md:86-92`).
  - For the clean worktree, it is `.newBranch(name:, startPoint: source HEAD)`
    (`GitWorktreeContracts.swift:71`).
- **D2 (DECIDED by orchestrator; the owner may revise).** The destination is
  `<parent>/<repo-folder>.<branch-slug>`, where `<parent>` is the directory
  that contains the repo's **main worktree**.
  - It must be inside a watched folder, or the request is rejected before
    creation (C8).
  - The sidebar will label the row `<repo-folder>.<branch-slug>`
    (`WorkspaceCacheCoordinator+DiscoveredWorktrees.swift:20-23`).
  - The fork additionally needs the same APFS volume as the source
    (`specification.md:134-136`). A sibling of the main worktree is usually,
    but not always, on the source's volume. The source may be a linked
    worktree elsewhere, and C7 covers that case.
  - I did not choose slug rules or a collision policy. If the destination
    exists, the SDK rejects it (`specification.md:139`).
- **D3 (DECIDED by orchestrator; the owner may revise).** On success, the new
  worktree appears in the sidebar only. Nothing opens automatically in v1.
- **D4 (DECIDED by orchestrator; the owner may revise).** The half-built
  window is handled by an in-flight hold in `FilesystemActor` and a targeted
  watched-folder refresh after the SDK returns (§2.1).
- **D5 (DECIDED by orchestrator; the owner may revise).** The Create row is
  always presented. Eligibility comes from the SDK's preflight rejection
  (C7).
- **D6 (DECIDED by orchestrator; the owner may revise).** There is no
  progress atom in v1. Open question 2 asks whether this is acceptable for
  long forks.
- **D7 (DECIDED by orchestrator; the owner may revise).** Failures are shown
  as a modal `NSAlert`: C7, C8 and C9. The fork's materialization report on
  success is logged only.
- **D8 (DECIDED by orchestrator; the owner may revise).** Both identities are
  **unexposed over IPC in v1**. They are classified as `.debugTesting`,
  `[.noArguments]`, `[.unavailable]`, and the owner refuses them (§1).
- **D9 (RESOLVED grounding).** The SDK's writer lane is process-wide
  (`GitRepositoryWriterRegistry.shared`, §0).

## 6. Doc drift noticed (not fixed; outside write scope)

- `docs/architecture/commands/command_specs.md:352-355` and
  `docs/architecture/commands/ipc.md:241-242` describe `ipcSpec.exposure` as
  `.headless` / `.headlessAndInteractive`. The code splits this into two
  enums:
  - `IPCMethodExposure` with `.allChannels` and `.debugTesting`
    (`IPCMethodDescriptorMetadata.swift:3-6`).
  - `IPCCommandExecutionMode` with `.headless` and `.uiPresentation`.
  - See `AppCommand+IPCProjection.swift:5-11`, `:173-301` and
    `AppCommandDispatcher.swift:164-180`.
- `command_specs.md:24-28` calls the retired Inbox identities "unexposed".
  In code they are `.debugTesting`-classified and rejected by their owners.
  No distinct "unexposed" exposure value exists.

---

## Revision 2026-09-26 — New Worktree as a repo submenu (owner-approved; supersedes C3–C4 Enter-modifier flow)

Plan: `tmp/plan-workflows/2026-09-26-new-worktree-repo-submenu.md`. Mockups: `tmp/worktree-fork/mockups/`.

```text
 ⌘⇧P > new worktree ─► pick repo (focused first) ─┐
 ⌘⇧P # agent-vm › ─► WORKTREES "New Worktree ›" ──┴─► ⌂ › agent-vm › New Worktree
                                                        git-worktree  From Default   origin/main   → name → ↵
                                                        repo-clone    Fork…                      › → pick worktree (focused first) → name → ↵
                                                        (From Branch… — later PR)
 ⌘⇧P # agent-vm › agent-vm.oauth › ─► "Fork This Worktree" → name → ↵
```

| Case | Behavior |
|---|---|
| From Default start point | origin/HEAD target → local `main` → local `master`; no fetch; none → row dimmed "no default branch" |
| Fork unavailable (eligibility) | worktree row dimmed with reason; not actionable; no silent clean fallback |
| Fork fails mid-copy | rollback → failure sheet (changes-only fallback is a later PR) |
| Branch/folder exists, Git error | failure sheet, nothing created |
| Enter modifiers | plain ↵ only; ⌘↵/⌥↵ mapping removed |
| Breadcrumb root (`.everything`) | house icon, not "Main" |

Stacked follow-up PR (not #363): every worktree searchable at root and `#` (name, folder, branch); last root query retained and shown selected on reopen (after esc and ↵; prefix opens win; in-memory).
