# Requirements: repositories keep their identity when folders move

[Specification](specification.md) · [Program design](program-design.md)

Extends [Repository and checkout lifecycle](../2026-09-11-repository-lifecycle/requirements.md) (U1–U7) and [Remove a watched folder](../2026-10-07-remove-watched-folder/requirements.md) (its U1–U4). Rows not changed here still apply.

**Supersedes:** the September protected-scope line "No new persistent common-directory identity or move-correlation store" (and the matching sentence "No manual reassociation or persistent move-correlation identity is requested"). The supersession covers only one thing: a folder identity recorded on existing checkout records, used to recognize a move. There is still no separate correlation store, no manual reassociation, and no common-directory identity.

## Why

On 2026-10-04 the owner moved repositories from `~/Documents/dev/...` to `~/code/...`. Each moved checkout became a new row. The old rows were hidden, and their pins and pane links stayed behind. Production state on 2026-10-09 (read-only copy of `~/.agentstudio/core.sqlite`):

- 281 hidden repository rows: 222 under `~/Documents/dev/open-source` and 54 under `~/Documents/dev/project-dev`. Between them they hold 3 pins, 0 notes and 0 tags.
- 22 of 50 panes report a working directory under `~/Documents/dev/` that no longer exists. None of them has a repository link.
- `~/Documents/dev/open-source` no longer exists on disk, so its scans are never authoritative. Its 222 hidden rows can never be collected.

The September lifecycle realized U3 ("handle moves automatically within the evidence available") without any move proof ("there is no admitted automatic cross-path move proof", [specification C1](../2026-09-11-repository-lifecycle/specification.md)). So a move never keeps identity today.

## Needs

| Id | Need | Owner authority |
|---|---|---|
| M1 | When a checkout folder moves to a new location inside a watched folder, it keeps its identity automatically, with no user action. The identity includes the row, pin, note and tags. Panes bound to that checkout keep their binding. A family follows its main checkout. Recents and local activity are kept per location, so they restart at the new one. | 2026-10-08 "we want stable merging when folders are moved"; Sep 11 U3 "i dont want users to do this" |
| M2 | Merge only on proof that the new location is the same folder that moved. When proof is missing or ambiguous, the new location stays independent, as today. A wrong merge is worse than a missed one. | Sep 11 U3 "do not claim two locations are the same without proof" |
| M3 | Separate checkouts and independent clones of one project never merge, even with identical history, remote and name. | Sep 11 U6 |
| M4 | Git identity guards the merge. Git must still resolve the moved folder to the same Git directory, in the same role (main or linked checkout). Shared history, remote or name is never enough on its own. | 2026-10-08 "we also did use the git identities to help no? to prevent reassociation?" |
| M5 | A terminal pane inside a moved folder shows its true location and gets its repository link back. This covers the panes broken by the 2026-10-04 move. Panes are never closed, restarted or sent commands. | Inferred: the owner agreed to "stable merging" after a sitrep that listed pane links among what does not follow. To confirm. Sep 11 U4. |
| M6 | Remove Watched Folder stops watching the folder and hides the repositories only it found. Panes are unlinked, never closed. | 2026-10-06 "Unwatch + hide its repos" (Oct 7 U1–U4) |
| M7 | Git facts come through agentstudio-git. Scans and checks keep the UI responsive. Nothing is written into user folders or Git metadata. | Sep 11 U7 and protected scope |

## Out of scope

- A manual Locate, Repair or merge action (superseded by Sep 11 U3).
- Following a folder that moved outside every watched folder.
- Moves on any volume other than the Mac's startup disk: external drives, disk images, snapshots and network volumes. Copy-then-delete is not a move either. All of these stay independent, and the old row retires normally.
- Merging rows whose folders moved before this ships. No folder identity was recorded for them (decision D3).
- Changing the 30-day retention interval.
- Changing the September same-path rule (R1) or resolving conflicts it governs. When a move's destination is already held by another record, or moves form a cycle, today's behavior applies unchanged.

## Open owner decisions

- **D1.** Which signal proves a move. Proposed: the identity of the folder itself, as the startup disk records it (Specification E3). Nothing in the Specification or Program Design is approved until D1 is decided.
- **D2.** Today a row stays hidden forever when its covering watched folders are removed. Should such rows retire 30 days after they were hidden? This affects U5, "avoid permanent abandoned data".
- **D3.** What happens to the legacy rows from the 2026-10-04 move: 281 hidden rows and 3 pins.
- **To acknowledge with D1:** M5 (inferred), and the restart of recents and local activity at the new location (Specification S9).
