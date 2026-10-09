# Requirements: repositories keep their identity when folders move

[Specification](specification.md) · [Program design](program-design.md)

Extends [Repository and checkout lifecycle](../2026-09-11-repository-lifecycle/requirements.md) (U1–U7) and [Remove a watched folder](../2026-10-07-remove-watched-folder/requirements.md) (its U1–U4). Rows not changed here still apply.

## Why

On 2026-10-04 the owner moved repositories from `~/Documents/dev/...` to `~/code/...`. Each moved checkout became a new row. The old rows were hidden, and their pins and pane links stayed behind. Production state on 2026-10-09 (read-only copy of `~/.agentstudio/core.sqlite`):

- 281 hidden repository rows: 222 under `~/Documents/dev/open-source` and 54 under `~/Documents/dev/project-dev`. Between them they hold 3 pins, 0 notes and 0 tags.
- 22 of 50 panes report a working directory under `~/Documents/dev/` that no longer exists. None of them has a repository link.
- `~/Documents/dev/open-source` no longer exists on disk, so its scans are never authoritative. Its 222 hidden rows can never be collected.

The September lifecycle realized U3 ("handle moves automatically within the evidence available") without any move proof ("there is no admitted automatic cross-path move proof", [specification C1](../2026-09-11-repository-lifecycle/specification.md)). So a move never keeps identity today.

## Needs

| Id | Need | Owner authority |
|---|---|---|
| M1 | When a checkout folder moves to a new location inside a watched folder, it keeps its identity automatically, with no user action. The identity includes the row, pin, note, tags, recents and local activity. A family follows its main checkout. | 2026-10-08 "we want stable merging when folders are moved"; Sep 11 U3 "i dont want users to do this" |
| M2 | Merge only on proof that the new location is the same folder that moved. When proof is missing or ambiguous, the new location stays independent, as today. A wrong merge is worse than a missed one. | Sep 11 U3 "do not claim two locations are the same without proof" |
| M3 | Separate checkouts and independent clones of one project never merge, even with identical history, remote and name. | Sep 11 U6 |
| M4 | Git identity guards the merge. Git must still resolve the moved folder to the same Git directory, in the same role (main or linked checkout). Shared history, remote or name is never enough on its own. | 2026-10-08 "we also did use the git identities to help no? to prevent reassociation?" |
| M5 | A terminal pane inside a moved folder shows its true location and gets its repository link back. This covers the panes broken by the 2026-10-04 move. Panes are never closed, restarted or sent commands. | Inferred: the owner agreed to "stable merging" after a sitrep that listed pane links among what does not follow. To confirm. Sep 11 U4. |
| M6 | Remove Watched Folder stops watching the folder and hides the repositories only it found. Panes are unlinked, never closed. | 2026-10-06 "Unwatch + hide its repos" (Oct 7 U1–U4) |
| M7 | Git facts come through agentstudio-git. Scans and checks keep the UI responsive. Nothing is written into user folders or Git metadata. | Sep 11 U7 and protected scope |

## Out of scope

- A manual Locate, Repair or merge action (superseded by Sep 11 U3).
- Following a folder that moved outside every watched folder, or to another volume. Copy-then-delete is not a move. These stay independent, and the old row retires normally.
- Merging rows whose folders moved before this ships. No folder identity was recorded for them (see decision D3).
- Changing the 30-day retention interval.

## Open owner decisions

- **D1.** Which signal proves a move. Recommended: the identity of the folder itself, as the filesystem records it (Specification E3).
- **D2.** Today a row stays hidden forever when its watched folder is removed or no longer exists. Should such rows retire 30 days after they were hidden? This affects U5, "avoid permanent abandoned data".
- **D3.** What happens to the legacy rows from the 2026-10-04 move: 281 hidden rows and 3 pins.
