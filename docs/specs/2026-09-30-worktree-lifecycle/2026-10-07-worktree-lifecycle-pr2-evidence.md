# PR 2 evidence report

Read-only evidence from a checkout of main at HEAD `e3bc09fda` (2026-10-07). Line anchors are as of that commit; re-verify them against current main before relying on one.

1. **New Worktree UI today**
   - Command catalog: `Sources/AgentStudio/Core/Actions/Commands/AppCommand+WorktreeCreationCatalog.swift:1-43` defines `New Worktree`, `From Default`, `From Branch`, and `Fork…`, with labels, icons, help text, and surface policies.
   - Command-bar hierarchy: `Sources/AgentStudio/Features/CommandBar/CommandBarDataSource+WorktreeCreation.swift:8-159`; fork/branch ordering continues at `:161-280`.
   - `WorktreeCreationCoordinator` is `@MainActor`; it holds publication, performs Git create/fork, releases the hold, and refreshes the watched folder (`Sources/AgentStudio/App/Coordination/WorktreeCreationCoordinator.swift:13-18,54-139`). From-default/from-branch use `GitCreateWorktreeRequest` (`:141-180`); fork uses copy-on-write/copy-all (`:182-210`).
   - `LocalActionSpec.forkThisWorktree` supplies row-level fork label/help/icon (`Sources/AgentStudio/Core/Actions/UIActionPresentation.swift:77-145`).

2. **Row menus**
   - Context-menu presentation: `Sources/AgentStudio/Features/RepoExplorer/RepoExplorerContextMenuPresenter.swift`; command presentation batching: `Sources/AgentStudio/App/Windows/RepoExplorerCommandPresentationBatch.swift:454-468`.
   - **Correction (Lead, 2026-10-07):** the linked-worktree row menu does NOT contain `Fork This Worktree`. A real debug-app capture shows only Create New in Tab ›, Create New in Pane ›, Open in Editor ›, Reveal in Finder and Copy Path, and `LocalActionSpec.forkThisWorktree` is referenced only by the command bar (`CommandBarDataSource+WorktreeCreation.swift:247`, `CommandBarDataSource+WorktreeRows.swift:447`). LR23's "beside Fork This Worktree" is therefore a stale position anchor. The row-menu placement requirement stands; its position within the menu is a mock question.
   - No current `removeWorktree` catalog entry or removal UI implementation was found. The intended PR-2 additions are recorded in `docs/specs/2026-09-30-worktree-lifecycle/2026-09-30-worktree-lifecycle-program-design.md:635-640`.

3. **Command bar**
   - New Worktree rows are built by `CommandBarDataSource+WorktreeCreation.swift:8-159`.
   - Worktree-targeted rows and fork action are in `CommandBarDataSource+WorktreeRows.swift:434-458,615-655`.
   - The design calls for a removal step in the command bar (`program-design.md:639-640`).

4. **IPC**
   - The design specifies `IPCWorktreeCreate/Remove/Prune/ListParams/Result`, descriptor registration, and local resolution (`program-design.md:635-638`). Mutations use `appCommandExecute`; list uses `workspaceRead` (`:637-638`).
   - LR18 requires contracts compiled into the CLI, direct app calls without per-call catalog fetch, and mutation completion only after sidebar refresh (`specification.md:131-137`).
   - Existing pane IPC snapshots include `worktreeId` (`Sources/AgentStudio/App/IPCComposition/AgentStudioIPCQueryAdapter.swift:119-131`).
   - No current `worktree.*` IPC implementation was found in this checkout; the design describes the intended PR-2 additions.

5. **Panes ↔ worktrees**
   - Pane summaries expose optional `worktreeId` (`AgentStudioIPCQueryAdapter.swift:119-131`).
   - Pane association persistence sanitizes/removes the worktree link (`Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceCoreRepository+PaneAssociations.swift:1-29`).
   - Removed worktrees are handled in topology/cache cleanup (`Sources/AgentStudio/App/Coordination/WorkspaceCacheCoordinator.swift:509-517`); ingress warns if pane-association cleanup is skipped (`WorkspaceCacheCoordinator+TopologyIngress.swift:130`).
   - LR20 states panes remain open and lose the association when a worktree disappears (`specification.md:143-148`).

6. **Confirmation/dialog patterns**
   - Shared popover primitives are under `Sources/AgentStudio/SharedComponents/SelectablePopover/`; `PopoverPanel.swift:13-91` uses `AppStyles` for layout and visual tokens.
   - No current Remove Worktree confirmation implementation was found. Intended behavior—assessment/proof, dirty state, branch disposition, archive/discard, and pane choices—is specified at `specification.md:151-156` and `program-design.md:639-640`.

7. **Leaf operations**
   - `WorktreeOperationRunner` and creation extensions: `Sources/AgentStudioWorktreeOperations/WorktreeOperationRunner.swift`, `WorktreeOperationRunner+CreationPreparation.swift`, `WorktreeOperationRunner+Creation.swift`.
   - `WorktreeRemovalRunner.run(_:)` accepts `WorktreeRemovalRequest` and returns `WorktreeRemovalReport` (`WorktreeRemovalRunner+WorktreeMutation.swift:142-150`); `runForPruneCandidate` is at `:152-155`.
   - `WorktreePruneRunner.run(_:)` accepts `WorktreePruneRequest` and returns `WorktreeOperationOutcome` (`WorktreePruneRunner.swift:10-45`).
   - Standalone CLI dispatch is `WorktreeCommandLine.dispatch` (`program-design.md:763`).

8. **Sidebar refresh after removal**
   - Creation explicitly awaits `refreshWatchedFolder` after the Git operation, including failure (`WorktreeCreationCoordinator.swift:130-138`).
   - LR20 requires scan → reconciliation to make rows appear/disappear without restart (`specification.md:143-148`).
   - The design maps LR20 to existing discovery and requires IPC mutations to await rescan (`program-design.md:630-640,760-764`).
   - `WorktreeRemovalDiscoveryIntegrationTests` was not present under this checkout by exact name; the available evidence is the existing discovery/reconciliation path and the specification/design obligations above.
