# Program design: remove a watched folder

Spec: `specification.md` (S1–S6). Grounded at main d7cf957e5.

## Crux
Hiding "only what this folder alone found" sounds like it needs provenance, a record of which folder found each repo. It does not, because the filesystem actor already does exactly that when the watched list shrinks:
1. `reconcileWatchedFolderRegistrations` (FilesystemActor+WatchedFolderScanning.swift:198-283) retires the removed folder's FSEvents registration and inventory.
2. It then calls `emitRemovedClones(noLongerReferencedByAnyWatchedFolder:)` (FilesystemActor.swift:860). That emits `.topology(.repoRemoved)` only for clones that no remaining inventory references.
3. `WorkspaceCacheCoordinator.handleRepoRemoved` (…+TopologyIngress.swift:236-278) answers that event:
   - `markRepoUnavailable` hides the repo, persisted in `unavailable_repo_retention`;
   - `clearPaneAssociations(forRemovedWorktreeID:)` unlinks panes and keeps them and their cwd;
   - `topologyDidChange` follows.

What is missing is only the entry point. `removeWatchedPath` (WorkspaceMutationCoordinator+RepositoryTopology.swift:197) has no caller, there is no command, and nothing pushes the shrunken list to the pipeline. The add flow pushes it explicitly at AppDelegate.swift:659, and nothing observes `watchedPaths`.

Selected: wire a command into the existing chain. Rejected: a provenance table. It is new persisted state no requirement needs, because S2 is defined by current folder references (E3), which the actor already computes.

## Flow
```mermaid
sequenceDiagram
    participant U as Command bar / IPC
    participant H as AppDelegate shell handler
    participant M as WorkspaceMutationCoordinator
    participant P as FilesystemGitPipeline / FilesystemActor
    participant C as WorkspaceCacheCoordinator
    U->>H: removeWatchedFolder (watched folder id, or IPC directory path)
    H->>H: await waitForRetentionCommit()
    H->>M: removeWatchedPath(id)  [atom; store persists watched_path]
    H->>P: refreshWatchedFolders(remaining list)
    P->>P: retire F's registration + inventory
    P-->>C: repoRemoved(path) for each clone no remaining folder references
    C->>M: markRepoUnavailable + clearPaneAssociations (panes stay open)
```

## Components (no new atom, store, table, migration, bus event or coordinator responsibility)
- **Command identity (Core/Actions/Commands):**
  - new `AppCommand.removeWatchedFolder` with an `AppCommandSpec`: label "Remove Watched Folder", icon `folderBadgeMinus`, help "Stop watching a folder and hide the repositories only it found", surface `.exposed([.commandBar])`, `targeting: .targeted([.watchedFolder])`, group "Repo";
  - new `SearchItemType.watchedFolder` case.
- **IPC projection (AppCommand+IPCProjection.swift):**
  - classified in the same change: argument `[.directory]`, exposure `.debugTesting`, execution mode `.headless`, privilege `.layoutMutate`, result `[.accepted]`, agent `.notYetAllowed`;
  - target kinds `[.window]`. These are the same rows as `.watchFolder` (:147-148, :215, :276, :356, :399, :467, :547).
- **Command bar (Features/CommandBar):**
  - targeted rows list `repositoryTopologyAtom.watchedPaths` (label: the folder path) as `.dispatchTargeted(.removeWatchedFolder, target: watchedPath.id, targetType: .watchedFolder)`;
  - `isSearchItemAvailable` checks that the id is still in the list;
  - with no watched folders the command has no rows, so it is not offered (S4).
- **Execution owner (App/Boot):**
  - `handleRemoveWatchedFolderRequested(_ watchedPathID: UUID) async` mirrors `handleWatchFolderRequested`: it awaits `workspaceCacheCoordinator.waitForRetentionCommit()`, then calls `store.mutationCoordinator.removeWatchedPath(id)`, then awaits `watchedFolderCommands.refreshWatchedFolders(store.repositoryTopologyAtom.watchedPaths)`;
  - `removeWatchedPath` is promoted from internal to `package` (the narrowest visibility the App target needs);
  - interactive entry: the shell handler's targeted `execute(_:target:targetType:)`;
  - IPC entry: the headless directory-argument handler. It maps the path to the watched entry by `StableKey.fromPath`. With no match it returns `.unavailable(.noApplicableTarget)`; otherwise it starts the handler task and returns `.accepted(operationId: nil)`, like `executeWatchFolderCommand`.

## State and persistence
- Watched list: `RepositoryTopologyStore` already observes `watchedPaths` and persists a debounced topology snapshot (`watched_path` table rewritten). Removal rides the same path as add, so S1 holds across restarts as add does.
- Hidden repos: the unavailable set is persisted by the same store. After a restart the removed folder is absent from the list, so boot never rediscovers its exclusive repos, and they stay hidden. Rediscovery through Watch Folder clears the flag (`addRepo` subtracts from the unavailable set, …+RepositoryTopology.swift:12-16), which is S6.

## Failure and ordering
- Removal is ordered after any in-flight retention commit (the same guard as add).
- The bus already logs a dropped `repoRemoved` delivery. Such a repo stays visible until a later reconciliation (spec known limit).
- If a remaining folder's inventory is incomplete during removal, a repo can be hidden and then reappear through rediscovery (spec known limit). No retry, timer or provenance is added for these rare cases.

## Proof seams
- `FilesystemActorWatchedFolderTests` (extends the existing :509 shrink case): a nested pair where removing the outer folder emits removal only for the outer folder's exclusive clones, plus the empty-list case.
- `PaneContextRepositoryRemovalTests` / `WorkspaceCacheCoordinatorIntegrationTests`: command execution leads to an exclusive repo becoming unavailable and its pane unlinked but present, with the shared repo unchanged.
- `AppCommandTests` and the IPC owner-coverage tests: catalog plus exhaustive IPC classification, and refusal of an unknown path.
- Real app: debug build, `command.execute removeWatchedFolder --arg directory=...`, `pane.snapshot`, repo lists, restart.
