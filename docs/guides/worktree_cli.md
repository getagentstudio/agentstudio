# Agent Studio worktree CLI: agent manual

This guide covers the production helper's current commands and the lifecycle
additions that arrive after app PR 1 merges.

## Availability

Production Agent Studio **0.0.105** ships `new`, `fork`, and the earlier
`list` output, and its `fork` works on real Agent Studio checkouts
(agentstudio-git deac01f). Removal, pruning, list state and blockers,
the warm `new` surface below, and `remove --force` arrive in the
first release built after app PR 1 merges. Until then, archive `tmp/` and push
before removing a worktree with `wt remove <branch>`.

## Why use it

- After app PR 1, `new` makes an APFS copy-on-write clone of the main worktree
  by default. `new --from <worktree>` deliberately carries that worktree's
  uncommitted work. The first build in a copy may be partly or fully cold. Whether an incremental build
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
ASW="/Applications/AgentStudio.app/Contents/Helpers/agentstudio"   # production 0.0.105+
```

The Beta helper at `/Applications/AgentStudio Beta.app/Contents/Helpers/agentstudio`
has the same verbs, but its fork needs a Beta built on agentstudio-git deac01f or
later.

| Command | Behavior | Options |
|---|---|---|
| `"$ASW" worktree new <branch>` | Creates a new branch at the source HEAD and copies the main worktree by default, or the worktree named by `--from`. | `--repo <path>`, `--from <worktree>`, `--changes-only`, `--tracked-only`, `--from-branch <local-branch>`, `--json` |
| `"$ASW" worktree list [target...]` | Lists worktrees with branch, path, current/locked state, working changes, integration, `tmp/` evidence, blockers, and removal readiness. Targets limit the rows. | `--repo <path>`, `--no-fetch`, `--json` |
| `"$ASW" worktree remove <target...>` | Removes worktrees or branch-only targets. Processes each target and reports its result. | `--repo <path>`, `--no-fetch`, `-f` / `--force`, `-D`, `--no-delete-branch`, `--archive-to-main`, `--archive-to <path>`, `--discard-tmp`, `--remove-stale-lock`, `--dry-run`, `--json` |
| `"$ASW" worktree prune` | Previews eligible linked worktrees. Skipped rows include the reason and available remove commands. | `--repo <path>`, `--no-fetch`, `--archive-to-main`, `--archive-to <path>`, `--apply`, `--json` |

The table describes commands after app PR 1. `fork` is removed then; it
returns exit 64 with a stderr line naming `new --from`, including with `--json`.

`new --tracked-only --from-branch <local-branch>` creates the branch at the
named local branch tip. `--from-branch` requires `--tracked-only`.
`new --from <worktree> --changes-only` carries tracked changes and eligible
untracked files, excludes ignored files, and leaves the destination index at
HEAD. `--changes-only` requires `--from`; `--tracked-only` excludes both.
Invalid combinations refuse with exit 1 and options that continue.

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
- `1`: creation was refused, or remove includes a refused entry and no
  entry failed. A dry-run target that cannot be resolved also returns `1`.
- `2`: the command failed, a remove entry failed, or a prune entry failed.
- `64`: arguments are malformed. One usage line is written to stderr and
  stdout stays empty, including with `--json`.

## Which one

- `new` copies the main checkout at its HEAD. Its default source must be
  clean and on the repository's default branch. A dirty or off-branch source
  is refused with options to commit/stash, select `--from`, or use
  `--tracked-only`.
- `new --from <worktree>` copies that source as it is, including uncommitted
  work. Even explicitly naming the main checkout skips the two default-source
  checks. A declared held build lock still refuses any copy-on-write source.
- `new --from <worktree> --changes-only` starts from HEAD and carries tracked
  changes plus eligible untracked files. It excludes ignored build output.
- `new --tracked-only` creates a tracked-files checkout from the default start
  point (`origin/HEAD`, else `main`, else `master`), or the local branch named
  by `--from-branch`. Submodules stay empty and ignored build output is absent.
  In agent-studio, run `mise run setup` before building or reading vendored
  headers. Expect a cold first build.
- Production 0.0.105 still uses `fork --from <main checkout>` for a warm copy
  and `new` for a tracked-files checkout. That production fork copies ignored
  files too, including build output and `tmp/`; it takes about 20 seconds for
  the agent-studio main checkout. These production verbs remain until the
  release after app PR 1.
- To recreate a worktree on an existing branch, use
  `git worktree add <repo>.<branch> <branch>` and then `mise run setup`; `new`
  creates a new branch.
- Reuse an existing checkout when you can.

The copy-on-write `new` refuses when the source or destination is not
on APFS, crosses volumes, is not a worktree root, or the destination already
exists.

**Git LFS:** `new --tracked-only` and `new --from … --changes-only` fill LFS
pointers from the repository's local object store when those objects are available. They do not
download objects. The created result lists files that could not be filled with
their reasons; run `git -C <worktree> lfs pull` for them. An incomplete scan is
also reported with its reason and the same command.

Copy rules are declared in `<main checkout>/.agentstudio.config.json` under
`worktree.include` and `worktree.busyLocks`. The tool only reads this file;
unreadable or malformed JSON refuses `configInvalid` before creation. Stage A
still copies every ignored file with the pinned SDK and probes literal lock
paths only. Stage B adds ignored-path filtering and lock-pattern expansion.

## Rules

- Never put development worktrees in `~/dev/worktrees`,
  `~/dev/agent-studio-worktrees`, or `/private/tmp`.
- Until the first release built after app PR 1 merges is available, archive
  `tmp/`, push, then remove the worktree with `wt remove <branch>`.
- After that release is available, remove a worktree with
  `"$ASW" worktree remove --repo <repo> <branch-or-path>`.
- Problems or gaps go to the Worktrees Lead: claude-local
  `9304749a-6517-41da-952d-243201c32337`.
