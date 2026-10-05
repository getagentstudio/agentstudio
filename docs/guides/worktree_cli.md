# Agent Studio worktree CLI: agent manual

This guide covers the worktree commands in Agent Studio 0.0.106 and later.

## Availability

Production Agent Studio **0.0.106** (released 2026-10-05) ships the full
lifecycle: a warm `new` (copy-on-write by default), `list` with state,
`remove`, and `prune`. `fork` is gone; use `new --from <worktree>`. Upgrade with
`brew upgrade --cask agent-studio`. On 0.0.105, `fork` fails on checkouts whose
build caches hold broken nested Git checkouts (see Rules).

## Why use it

- `new` makes an APFS copy-on-write clone of the main worktree
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
ASW="/Applications/AgentStudio.app/Contents/Helpers/agentstudio"   # production 0.0.106+
```

The Beta helper at `/Applications/AgentStudio Beta.app/Contents/Helpers/agentstudio`
has the same verbs once your Beta includes 0.0.106's changes. Prefer the
production helper.

| Command | Behavior | Options |
|---|---|---|
| `"$ASW" worktree new <branch>` | Creates a new branch at the source HEAD and copies the main worktree by default, or the worktree named by `--from`. | `--repo <path>`, `--from <worktree>`, `--changes-only`, `--tracked-only`, `--from-branch <local-branch>`, `--json` |
| `"$ASW" worktree list [target...]` | Lists worktrees with branch, path, current/locked state, working changes, integration, `tmp/` evidence, blockers, and removal readiness. Targets limit the rows. | `--repo <path>`, `--no-fetch`, `--json` |
| `"$ASW" worktree remove <target...>` | Removes worktrees or branch-only targets. Processes each target and reports its result. | `--repo <path>`, `--no-fetch`, `-f` / `--force`, `-D`, `--no-delete-branch`, `--archive-to-main`, `--archive-to <path>`, `--discard-tmp`, `--remove-stale-lock`, `--dry-run`, `--json` |
| `"$ASW" worktree prune` | Previews eligible linked worktrees. Skipped rows include the reason and available remove commands. | `--repo <path>`, `--no-fetch`, `--archive-to-main`, `--archive-to <path>`, `--apply`, `--json` |

`fork` is removed: it returns exit 64 with a stderr line naming `new --from`, including with `--json`.

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
  checks.
- `new --from <worktree> --changes-only` starts from HEAD and carries tracked
  changes plus eligible untracked files. It excludes ignored build output.
- `new --tracked-only` creates a tracked-files checkout from the default start
  point (`origin/HEAD`, else `main`, else `master`), or the local branch named
  by `--from-branch`. Submodules stay empty and ignored build output is absent.
  In agent-studio, run `mise run setup` before building or reading vendored
  headers. Expect a cold first build.
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

Copy rules are declared in `<main checkout>/.agentstudio.config.json`:

```json
{ "worktree": { "include": [".build*/", "Frameworks/"] } }
```

`worktree.include` uses positive gitignore patterns: `*`, `?`, `**`, a leading
`/` for a repository-root anchor, and a trailing `/` for directories. Leading
`!` negation and `#` comments are invalid entries. The tool reads the main
checkout's file and never writes it. Unknown keys are ignored. No file or no
include key means no ignored files are copied. Tracked and untracked
non-ignored files are copied; included ignored directories carry their contents.

The config is read only for a copy-on-write `new` (the default and
`new --from`). Unreadable or malformed JSON, or an invalid pattern, refuses
`configInvalid` before creation. The output names the file, the offending entry
when applicable, and the error, with the options to fix the file or use
`--tracked-only`. `--tracked-only` and `--changes-only` never read the config,
so a broken config never blocks them.

Source index problems:

- **Default `new`** first checks that the main checkout is clean. If its working
  changes can't be read, for example because the index is unreadable or in a
  sparse or split format, it refuses `changesUnknown` (options: retry,
  `--tracked-only`, or `--from <main checkout>`), because a clean source can't
  be proved.
- **`new --from <worktree>`** copies the source as it is. An unreadable source
  index refuses `sourceIndexUnreadable` (retry or `--tracked-only`), and a
  sparse or split index refuses `sourceIndexUnsupported` (`--tracked-only`).
- A missing index counts as empty.

The created copy-on-write report prints `ignoredIncludedPatterns`,
`ignoredExcludedCount` (excluded paths) and `nestedWorktreesSkipped`.

The app UI Fork continues to copy all ignored files. These repository include
rules apply to the CLI `new` copy-on-write path, including `new --from`.

## Rules

- Never put development worktrees in `~/dev/worktrees`,
  `~/dev/agent-studio-worktrees`, or `/private/tmp`.
- Remove a worktree with `"$ASW" worktree remove --repo <repo> <branch-or-path>`
  (add `--archive-to-main` to keep its `tmp/` evidence).
- If a warm `new` fails with `libgit2Failure`, a nested Git checkout inside the
  source's copied build output is broken. After the 2026-10-04 move, SwiftPM
  checkouts under `.build*/` kept `objects/info/alternates` paths into
  `~/Documents`. Delete that `.build*` folder and rebuild, or rewrite the stale
  paths, then retry.
- Problems or gaps go to the Worktrees Lead: claude-local
  `9304749a-6517-41da-952d-243201c32337`.
