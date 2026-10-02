# Agent Studio worktree CLI: agent manual

This guide covers the Beta helper's current commands and the lifecycle
additions that arrive after app PR 1 merges.

## Availability

The installed Beta helper, 0.0.105-beta.71, supports `new`, `fork`, and the
earlier `list` output. Removal, pruning, list state and blockers,
`new --from-branch`, `fork --changes-only`, and `remove --force` arrive in the
first Beta built after app PR 1 merges. Until then, archive `tmp/` and push
before removing a worktree with `wt remove <branch>`. The stable cut comes
later.

## Why use it

- `fork` makes an APFS copy-on-write clone of a worktree, including uncommitted
  and ignored files such as `.build`, `node_modules`, and `tmp/`. The first
  build in a fork may be partly or fully cold. Whether an incremental build
  reuses the copied output has not been measured. SwiftPM `.build` and cargo
  `target/` can embed absolute paths.
- The helper calls Git through agentstudio-git. It does not shell out to `git`
  and does not need the app or IPC.
- `--json` returns machine-readable results. Exit codes report the overall
  outcome.
- Worktrees are created at `<repo>.<branch>` next to the repository, the same
  default path as `wt`. The sidebar and `wt` discover them as ordinary Git
  worktrees.

## Run it

**Never run bare `agentstudio`.** In Agent Studio panes, `PATH` can include
`AgentStudio.app/Contents/MacOS`. APFS ignores case, so `agentstudio` resolves
to the GUI app binary and starts a second app. Always use the full, quoted
Helpers path:

```bash
ASW="/Applications/AgentStudio Beta.app/Contents/Helpers/agentstudio"   # beta: has the worktree verbs
```

The stable helper at
`/Applications/AgentStudio.app/Contents/Helpers/agentstudio` does not include
the worktree verbs yet. The Beta helper gains the lifecycle additions after
app PR 1 merges; the stable cut comes later.

| Command | Behavior | Options |
|---|---|---|
| `"$ASW" worktree new <branch>` | Creates a new branch and worktree from the default start point (`origin/HEAD`, else `main`, else `master`). | `--repo <path>` (defaults to the current directory), `--from-branch <local-branch>`, `--json` |
| `"$ASW" worktree fork <branch>` | Copies the current worktree by default, including uncommitted and ignored files, onto a new branch. | `--from <worktree path>` (defaults to the current directory), `--changes-only`, `--json` |
| `"$ASW" worktree list [target...]` | Lists worktrees with branch, path, current/locked state, working changes, integration, `tmp/` evidence, blockers, and removal readiness. Targets limit the rows. | `--repo <path>`, `--no-fetch`, `--json` |
| `"$ASW" worktree remove <target...>` | Removes worktrees or branch-only targets. Processes each target and reports its result. | `--repo <path>`, `--no-fetch`, `-f` / `--force`, `-D`, `--no-delete-branch`, `--archive-to-main`, `--archive-to <path>`, `--discard-tmp`, `--remove-stale-lock`, `--dry-run`, `--json` |
| `"$ASW" worktree prune` | Previews eligible linked worktrees. Skipped rows include the reason and available remove commands. | `--repo <path>`, `--no-fetch`, `--archive-to-main`, `--archive-to <path>`, `--apply`, `--json` |

`new --from-branch <local-branch>` creates the new branch at the named local
branch tip. `fork --changes-only` carries tracked changes and eligible
untracked files, excludes ignored files, and leaves the destination index at
HEAD. Use the default `fork` when you need the source worktree's full state.

`list`, `remove`, and `prune` fetch the integration target branch before
assessing it. `--no-fetch` skips that fetch. `remove --dry-run` reports the
steps and any stop without changing the worktree lifecycle. It may still fetch;
add `--no-fetch` for a fully read-only preview.

`-f` and `--force` are aliases for discarding working changes during
`remove`. `-D` permits deleting a branch with remaining contribution, subject
to the other branch safety checks. `--no-delete-branch` keeps the branch.
`--archive-to-main` copies `tmp/` evidence to the main worktree, and
`--archive-to <path>` copies it to the selected folder. `--discard-tmp`
discards that evidence. `--remove-stale-lock` removes an identified stale lock
only after checking its identity and age. `prune` accepts neither `-f` /
`--force` nor `-D`; `--apply` performs its eligible removals.

Exit codes:

- `0`: creation or listing succeeded; remove has no refused or failed entries;
  prune has no failed entries. Prune skips still return `0`.
- `1`: creation or fork was refused, or remove includes a refused entry and no
  entry failed. A dry-run target that cannot be resolved also returns `1`.
- `2`: the command failed, a remove entry failed, or a prune entry failed.
- `64`: arguments are malformed. One usage line is written to stderr and
  stdout stays empty, including with `--json`.

## Which one

- `fork` preserves the exact current state, including uncommitted work and
  build output. It is useful when a second checkout needs the same working
  files.
- `fork --changes-only` starts from HEAD and carries tracked changes plus
  eligible untracked files. It excludes ignored files and build output.
- `new` creates a clean branch from the default start point or from the local
  branch named by `--from-branch`. It checks out **tracked files only**:
  submodules stay empty and ignored build output doesn't exist. In
  agent-studio that means `vendor/ghostty` and `vendor/zmx` are empty and
  there's no `Frameworks/`, so run `mise run setup` (as AGENTS.md says) before
  building or reading vendored headers. Expect a cold first build.
- **agent-studio default: `fork --from <main checkout>`** (the main checkout
  on its default branch, clean). That APFS-clones the populated submodules,
  `Frameworks/` and build output, so no setup is needed and nothing is
  downloaded. Use `new` + `mise run setup` only when the main checkout isn't
  clean or isn't on the default branch.
- Reuse an existing checkout when you can.

The default copy-on-write `fork` refuses when the source or destination is not
on APFS, crosses volumes, is not a worktree root, or the destination already
exists.

**Git LFS:** `new` and `fork --changes-only` fill LFS pointers from the
repository's local object store when those objects are available. They do not
download objects. The created result lists files that could not be filled with
their reasons; run `git -C <worktree> lfs pull` for them. An incomplete scan is
also reported with its reason and the same command.

## Rules

- Never put development worktrees in `~/dev/worktrees`,
  `~/dev/agent-studio-worktrees`, or `/private/tmp`.
- Until the first Beta built after app PR 1 merges is available, archive
  `tmp/`, push, then remove the worktree with `wt remove <branch>`.
- After that Beta is available, remove a worktree with
  `"$ASW" worktree remove --repo <repo> <branch-or-path>`.
- Problems or gaps go to the Worktrees Lead: claude-local
  `9304749a-6517-41da-952d-243201c32337`.
