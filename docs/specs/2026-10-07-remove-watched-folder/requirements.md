# Requirements: remove a watched folder

Owner decision, 2026-10-06 (question tool, after the sitrep), answer "Unwatch + hide its repos". The recommendation it accepted: stop watching the folder, hide only the repos that folder found (repos another watched folder also finds stay), unassign but never close their panes, and add it as a command (spec catalog plus IPC).

| Id | Need |
|---|---|
| U1 | The user can stop watching a folder they watched before. Once removed, the app no longer scans or watches it, and this survives a restart. |
| U2 | Repos that only the removed folder found disappear from the workspace (sidebar, command bar, IPC repo lists). Repos that another still-watched folder finds stay exactly as they are. |
| U3 | Panes are never closed by this. A pane whose repo disappears stays where it is, keeps its working directory, and simply loses its repo/worktree link (no git chip). |
| U4 | Removing a watched folder is a real command: it appears in the command bar and is callable over IPC, through the command spec catalog like Watch Folder. |

Out of scope:
- deleting repo rows (this hides them)
- recording which folder found which repo (provenance storage)
- a sidebar or settings list of watched folders
- a confirmation dialog
- any change to Watch Folder, Remove Repo, or pane relinking

Why it matters: watched folders can be added but never removed. `WorkspaceMutationCoordinator.removeWatchedPath` exists but has no caller, and no command reaches it. After the owner moved repos from ~/Documents to ~/code, the old folder kept 276 stale repo rows with no way to clear them (sitrep 2026-10-06).
