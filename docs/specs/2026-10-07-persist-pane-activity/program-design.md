# Program design: pane activity survives an app restart

Spec: `specification.md` (S1–S6). Grounded at main 1673b2b21. It follows the existing per-workspace local-state precedents: `local_repository_activity` and drawer-presentation retention (`WorkspaceSQLiteStoreBackend.retainedDrawerPresentationOwnerPaneIds`).

## Storage (app-wide local.sqlite, a "current" table by write pattern)
New migration `028_add_local_pane_activity`, registered in **`bootRequiredMigrator`** (WorkspaceLocalMigrations.swift:4). Pre-window restore only opens the boot-required schema. All existing migration identifiers are unchanged; local migrations currently run through `027_sessions_hook_admission_cleanup`. local.sqlite is ONE app-wide database shared by every workspace facade (AppDataPaths.swift:81, WorkspaceSQLiteDatastoreActor.swift:16-20).
```sql
CREATE TABLE local_pane_activity (
    pane_id TEXT PRIMARY KEY,
    activity_at REAL NOT NULL,   -- wall time, seconds since 1970 (UTC)
    source TEXT NOT NULL         -- "hook" | "terminal", parsed in Swift; no enum CHECK
)
```
A row whose `source` can't be parsed is skipped and logged, never defaulted.

## Components (no new atom, no new store class)
- `WorkspaceLocalRepository+PaneActivity.swift`: `commitPaneActivity(_:)` (upserts + deletes, one transaction), `fetchPaneActivity()`, `prunePaneActivity(retaining:)`.
- `WorkspaceCoreRepository`: one read query, `fetchRetainedPaneActivityPaneIDs()`. It returns every persisted core pane id in EVERY workspace (layout panes and drawer children) ∪ every member of an available Undo record in ANY workspace, following the drawer-presentation retention rule but app-wide, because the table is app-wide.
- `WorkspaceSQLiteDatastoreActor`: `loadPaneActivity(workspaceId:)` and `commitPaneActivity(_:)`, with all I/O off the MainActor.
  - `loadPaneActivity` first prunes rows outside the app-wide retain set. If the membership read throws, it logs and deletes nothing.
  - It then returns ONLY the rows for the requested workspace's retained panes: that workspace's live panes plus its available-Undo members.
- `PaneActivityRecord` / `PaneActivityCommit`: value types next to `PaneActivityOccurrence`.

## Flows
- **Restore (S2, S3, S4):** inside `bootEstablishRuntimeBus`, immediately after `let undoRecovery = await bootRecoverUndoJournal()` (AppDelegate+WorkspaceBoot.swift:365).
  - At that point canonical composition is installed and Undo recovery is done (boot-expired Undo retirements happen here, before the clock exists, so they never reach `.remove`; the prune covers them).
  - The clock is attached later (`bootInstallShellRuntimeOwners`), and the window is created only after presentation prerequisites return (WorkspaceBootSequence.swift:49/76 → AppDelegate.swift:209). So the first sidebar projection sees restored values.
  - Steps:
    1. `await sqliteDatastore.loadPaneActivity(workspaceId:)`, which prunes;
    2. on the MainActor, apply `.set` for every retained record (live panes AND available-Undo members) whose atom value is nil (live wins), with ordering instant `ContinuousClock.now − max(0, Date.now − at)` (the same pair the projection uses). The sidebar renders only live panes, so Undo members' values sit unseen until Undo reinserts the pane, which then shows its pre-restart activity (S4).
    3. A runtime permanent retirement (Undo expiry or a final close) already reaches the clock as `.remove`, which drops the atom value and deletes the row.
- **Save (S1, S4, S5):** the existing clock sink (AppDelegate+TerminalActivityBoot.swift) applies each batch to `PaneActivityTimeAtom` first, then awaits `sqliteDatastore.commitPaneActivity(batch)`:
  - `.set` becomes an upsert; `.remove` becomes a delete;
  - the clock drains serially and awaits its sink, so commits stay in publication order with no new queue;
  - ingress (`submit`) stays non-awaiting, and the MainActor suspends rather than blocks.
  - Known cost: the next publication, deadline scheduling and `settled()` wait for the commit. This is acceptable for a small upsert, and nothing gets a timer, retry or forced flush.
- **Failure and quit (S6):** load or commit errors are logged. Shutdown behaves as today: pending unpublished activity may be lost, and a `.shutDown` result is not a durability receipt.

## Not added
No new atom, store class, timer, debounce, queue, retry, bus event, coordinator responsibility or IPC change.
