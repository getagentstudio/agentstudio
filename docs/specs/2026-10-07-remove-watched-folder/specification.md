# Specification: remove a watched folder

Requirements: `requirements.md` (U1–U4).

## Entities
- **E1 Watched folder**: one per entry in the persisted watched-folder list. Identity is its id; two entries never share a path key (`stableKey`). It is in the list, or it is not.
- **E2 Repo**: identity is its id (matched to disk by path or stable key). Observable states: visible, or hidden (unavailable). The stored row is kept either way. A hidden repo and its worktrees are absent from every reader that lists repos: the sidebar, the command bar's repo and worktree target lists (including the empty-query list), and the repository list of IPC `workspace.list` / `workspace.current`. The state survives restart. This holds for every hidden repo, whatever hid it.
- **E3 Folder reference**: a repo is referenced by a watched folder when that folder's current scan inventory contains the repo's clone path. A repo can be referenced by several folders, by nesting (`~/code` and `~/code/projects`).
- **E4 Pane link**: a pane's repo/worktree association. Clearing it keeps the pane, its tab or drawer position, its session and its working directory.

## Obligations
| Id | Must | Traces |
|---|---|---|
| S1 | After Remove Watched Folder for folder F, F is no longer in the watched list, now and after a restart, and the app holds no filesystem watch or scan for F. | U1 |
| S2 | Every repo that F referenced and that no remaining watched folder references becomes hidden (E2), and stays hidden after a restart. Every repo that a remaining folder references is unchanged and still listed by every E2 reader. | U2 |
| S3 | Every pane linked to a worktree of a repo hidden by S2 stays open in place, keeps its working directory, and has its repo/worktree link cleared. No pane, tab, drawer or session is closed. | U3 |
| S4 | One command, "Remove Watched Folder", appears in the command bar. Its target list is exactly the current watched folders. With nothing watched, the list is empty, as Remove Repo's is with no repos. A target that has left the list since the bar opened cannot run. Over IPC it takes the window plus the directory path of a watched folder, the same arguments as Watch Folder. An unwatched path is refused with no applicable target. A watched path is accepted even if the directory no longer exists on disk, and returns an accepted receipt (reconciliation finishes asynchronously). Its IPC exposure, privilege and agent eligibility match Watch Folder. | U4 |
| S5 | Removing the last watched folder leaves an empty watched list. Every scanned repo is then unreferenced and is hidden by S2. | U1, U2 |
| S6 | Watching the same folder again rescans it, and its repos become visible again (existing rediscovery behavior, unchanged). | U1, U2 |

## Known limits (unmeasured frequency; no mechanism added)
- **Incomplete inventory elsewhere.** An ordinary removal waits for an active manual refresh. But if another watched folder's inventory is incomplete when F is removed (a callback or fallback refresh still running, or a partial scan outcome), a repo that folder would reference can be hidden, and its pane links cleared. That folder's next complete scan makes the repo visible again (S6 path). Whether panes relink after that is not verified.
- **Pre-existing launch repair.** A hidden repo with no valid main worktree can be rescanned at launch and made visible again by the existing missing-main repair. This is unchanged behavior and rare.

## Proof
- Unit:
  - removing a watched path filters only that entry
  - the persisted watched list round-trips without it
  - catalog and IPC projection exhaustiveness for the new command
- Integration (filesystem actor, with a real FSEvents stand-in as today):
  - two folders where one is nested in the other; removing the outer one emits repo-removed only for clones the inner one does not reference
  - removing the last folder emits removal for every clone
- Integration (App):
  - from the command's execution through `repoRemoved` handling, the exclusive repo is hidden and its pane is unlinked but still present
  - the shared repo is untouched
  - before and after a persisted restore, IPC `workspace.list` / `workspace.current` and the command bar's empty-query repo and worktree target lists exclude the hidden repo and keep the shared one
  - targeted dispatch: a current folder id runs; a stale id is refused
  - an unwatched IPC path is refused, and a watched path whose directory was deleted is accepted
- Real app (debug build):
  - watch two folders, then remove one with `command.execute`
  - `pane.snapshot` shows the affected pane still present with no worktree
  - the repo lists exclude only the exclusive repos
  - after a restart the folder and the hidden repos stay gone
