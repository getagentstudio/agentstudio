# Specification: remove a watched folder

Requirements: `requirements.md` (U1–U4).

## Entities
- **E1 Watched folder**: one per entry in the persisted watched-folder list. Identity is its id; two entries never share a path key (`stableKey`). It is in the list, or it is not.
- **E2 Repo**: identity is its id (matched to disk by path or stable key). Observable states: visible, or hidden (unavailable). Hidden repos are absent from the sidebar, command bar and IPC repo lists, and the state survives restart.
- **E3 Folder reference**: a repo is referenced by a watched folder when that folder's current scan inventory contains the repo's clone path. A repo can be referenced by several folders, by nesting (`~/code` and `~/code/projects`).
- **E4 Pane link**: a pane's repo/worktree association. Clearing it keeps the pane, its tab or drawer position, its session and its working directory.

## Obligations
| Id | Must | Traces |
|---|---|---|
| S1 | After Remove Watched Folder for folder F, F is no longer in the watched list, now and after a restart, and the app holds no filesystem watch or scan for F. | U1 |
| S2 | Every repo that F referenced and that no remaining watched folder references becomes hidden, and stays hidden after a restart. Every repo that a remaining folder references is unchanged. | U2 |
| S3 | Every pane linked to a worktree of a repo hidden by S2 stays open in place, keeps its working directory, and has its repo/worktree link cleared. No pane, tab, drawer or session is closed. | U3 |
| S4 | One command, "Remove Watched Folder", appears in the command bar targeting one folder from the current watched list. It is not offered when nothing is watched. Over IPC it takes the directory path of a watched folder: an unknown path is refused with no applicable target, and a valid one returns an accepted receipt (scan reconciliation finishes asynchronously). Its IPC exposure, privilege and agent eligibility match Watch Folder. | U4 |
| S5 | Removing the last watched folder leaves an empty watched list. Every scanned repo is then unreferenced and is hidden by S2. | U1, U2 |
| S6 | Watching the same folder again rescans it, and its repos become visible again (existing rediscovery behavior, unchanged). | U1, U2 |

## Known limits (rare, accepted)
- **Mid-scan remove.** If a remaining folder's scan inventory is incomplete at the moment of removal (for example during its first scan), a repo it would reference can be hidden and then reappear when that scan completes (S6 path).
- **Dropped event.** If the runtime bus drops the repo-removed event (already logged today), that repo stays visible until a later reconciliation.

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
  - an unknown IPC path is refused
- Real app (debug build):
  - watch two folders, then remove one with `command.execute`
  - `pane.snapshot` shows the affected pane still present with no worktree
  - the repo lists exclude only the exclusive repos
  - after a restart the folder and the hidden repos stay gone
