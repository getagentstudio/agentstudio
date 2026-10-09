# Agent Studio worktree CLI: agent manual

This guide covers the worktree commands in Agent Studio 0.0.109 and later.

## Availability

Agent Studio **0.0.109** ships the full lifecycle: `new`, `list` with state,
`remove`, and `prune`. `new` copies a source checkout, then puts the copy on
the branch you named, as `wt switch` does: `new <branch>` opens a branch that
already exists, locally or on origin (fetched first), and `new -c <branch>`
(`--create`) creates a new one, at the source's HEAD or, with `--from-branch`,
at any local or remote branch. `fork` is gone; use `new -c <branch> --from <worktree>`.
Upgrade with `brew upgrade --cask agent-studio`.

### Older helpers (0.0.107 and 0.0.108)

- `--tracked-only` is the plain checkout; 0.0.109 calls it `--no-fork` and
  treats `--tracked-only` as an unknown option (exit 64).
- `--from-branch` takes only a local branch and makes a tracked-files checkout.
  `--from` with `--from-branch` is a usage error.
- `new` refuses a branch that already exists (`branchAlreadyExists`) and
  never fetches.
- `new <name>` creates the branch when it doesn't exist; there is no `-c`.
  0.0.109 refuses that (`noSuchBranch`) and creates only with `new -c`.
- `new` prints the copy report on extra lines after `created …`.

### Older helpers (0.0.106 and earlier)

These versions also behave differently:

- 0.0.106 refuses default `new` on a dirty or off-branch main checkout
  (`sourceDirty`, `sourceNotOnDefaultBranch`); pass `--from <main checkout>` to
  fork it as it is.
- 0.0.106 requires `--tracked-only` together with `--from-branch`.
- 0.0.106 fails `new` with `libgit2Failure` when the source's copied build
  output holds a nested Git checkout whose `objects/info/alternates` path is
  gone; delete that `.build*` folder and rebuild, then retry.
- 0.0.105's `fork` fails on checkouts whose build caches hold broken nested Git
  checkouts.

## Why use it

- `new` makes an APFS copy-on-write fork of the main checkout as it is,
  uncommitted and untracked files included. `new --from <worktree>` forks that
  worktree as it is.
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
| `"$ASW" worktree new <branch>` | Copies the main worktree, or the worktree named by `--from`, and puts the copy on an existing `<branch>`: local, or origin's (see [How `new` picks its branch](#how-new-picks-its-branch)). A name that exists nowhere is refused `noSuchBranch`. | `--repo <path>`, `--from <worktree>`, `--no-fork`, `--no-fetch`, `--json` |
| `"$ASW" worktree new -c <branch>` | The same copy on a new `<branch>` (`-c` / `--create`), at the source's HEAD or `--from-branch`. A name that exists locally or on origin is refused `branchAlreadyExists`, and one origin can't be asked about is refused `originCheckFailed`. | `--repo <path>`, `--from <worktree>`, `--from-branch <branch>`, `--no-fork`, `--changes-only`, `--no-fetch`, `--json` |
| `"$ASW" worktree list [target...]` | Lists worktrees with branch, path, current/locked state, working changes, integration, `tmp/` evidence, blockers, and removal readiness. Targets limit the rows. | `--repo <path>`, `--no-fetch`, `--json` |
| `"$ASW" worktree remove <target...>` | Removes worktrees or branch-only targets. Processes each target and reports its result. | `--repo <path>`, `--no-fetch`, `-f` / `--force`, `-D`, `--no-delete-branch`, `--archive-to-main`, `--archive-to <path>`, `--discard-tmp`, `--remove-stale-lock`, `--dry-run`, `--json` |
| `"$ASW" worktree prune` | Previews eligible linked worktrees. Skipped rows include the reason and available remove commands. | `--repo <path>`, `--no-fetch`, `--archive-to-main`, `--archive-to <path>`, `--apply`, `--json` |

`fork` is removed: it returns exit 64 with a stderr line naming `new -c <branch> --from`, including with `--json`.

`new -c --from <worktree> --changes-only` carries tracked changes and eligible
untracked files, excludes ignored files, and leaves the destination index at
HEAD. `--from-branch` and `--changes-only` only create, so without `-c` they
are usage errors (exit 64, naming `-c`). `--changes-only` requires `--from`
(refused, exit 1, with options), and excludes `--no-fork` and `--from-branch`
(usage error, exit 64).
`--tracked-only` no longer exists: it is an unknown option (exit 64); use
`--no-fork`.

## How `new` picks its branch

1. If `<branch>` is checked out in any worktree, or being rebased or bisected
   there, `new` refuses `branchCheckedOut` with that worktree's path before
   any fetch, and before checking the destination, so running `new feat` again
   for an existing `<repo>.feat` points you there. Work there instead
   (`cd <path>`).
`new <branch>` (no `-c`) opens an existing branch:

2. `new` asks origin whether it has `<branch>` and fetches that one branch
   (no tags, no pruning). A branch origin doesn't have counts as absent, even
   if an old `origin/<branch>` ref is still on disk. `--no-fetch` skips this and
   reads the refs already on disk. A failed question or fetch never stops
   `new`: it continues with the refs on disk and says so.
3. If local `<branch>` exists, the worktree is on it. When `origin/<branch>`
   is strictly ahead, the local branch is first fast-forwarded to it. When the
   local branch has commits origin lacks, it is kept as it is, and the output
   counts them.
4. If only `origin/<branch>` exists, local `<branch>` is created at it and
   tracks it, so `git push` works.
5. Otherwise `new` refuses `noSuchBranch`, with the option
   `new -c <branch>`.

`new -c <branch>` creates a new branch:

- If `<branch>` exists locally or on origin, `new -c` refuses
  `branchAlreadyExists`, before anything is fetched; run `new <branch>` to
  open it, or pick another name. `new -c` asks origin whether it has
  `<branch>`, which fetches nothing. With `--no-fetch`, the `origin/<branch>`
  ref on disk answers instead. With no origin remote, only local branches
  count.
- If origin can't be asked, `new -c` refuses `originCheckFailed` with the
  reason and creates nothing, so it never makes a branch origin already has.
  Run it again with `--no-fetch` to go by the refs on disk.
- Otherwise the new `<branch>` starts at the source's HEAD commit, with no
  upstream.
- `--from-branch <start>` starts it at another branch instead, fetching
  `<start>` first. `<start>` beginning with a configured remote's name
  (`origin/x`, `upstream/x`) means that remote's branch. Otherwise it is the
  local branch `<start>`, else `origin/<start>`.
- A local `<start>` strictly behind `origin/<start>` starts at origin's commit
  and leaves the local branch where it is. A diverged one starts at the local
  tip, and the output counts the commits origin lacks.
- A start that isn't found refuses `startBranchNotFound`.

`--from <worktree>` works with both forms: without `-c` the named worktree is
copied and set to the existing branch; with `-c --from-branch` the copy is
reset to the start. `--changes-only` needs `-c`, starts at the source's HEAD,
and fetches nothing. A branch that moves between this resolution and the
attach refuses `branchMoved` with nothing changed; run `new` again.

## What `new` prints

One line: `created <branch> at <path> (<how>)`, where `<how>` is
`copy-on-write`, `checkout`, or `changes-only`, followed by notes that apply,
separated by `; `:

- `existing branch`, and `fast-forwarded to origin/<branch>` when it moved up;
- `kept local <name>: <n> commits not on <remote>` for a kept diverged branch
  or start;
- `from <remote>/<name>` for a branch created from a remote branch;
- `fetch failed: <reason>; used local refs`;
- `<n> large files left as pointers`.

For example: `created feat at /code/app.feat (copy-on-write; existing branch; fast-forwarded to origin/feat)`.
Everything else is in `--json`: `branch` (`name`, `status`: `created`,
`existing` or `fastForwarded`, `upstream`), `start` (`commit`, `from`:
`sourceHead`, `localBranch` or `remoteBranch`, `ref`, `localOnlyCommits`),
`fetch` (`remote`, `branch`, `status`: `fetched`, `notOnRemote`, `skipped` or
`failed`), and the copy report under `materialization`.

A refusal or failure that comes after the fetch still reports it: `--json`
carries the same `fetch` object, and the human output adds a `fetch:` line
after the refusal. `noSuchBranch` comes after the fetch and reports it;
`new -c`'s `branchAlreadyExists` and `originCheckFailed` come before any fetch
and report none.

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

- `new` forks the main checkout. When the branch starts at the main checkout's
  HEAD commit, the copy keeps it as it is: uncommitted and untracked files come
  along, whichever branch it has checked out.
- When the branch starts at another commit (an existing branch, origin's
  branch, or `--from-branch`), the copy is reset to that commit: tracked files
  and the index are that commit's, and the source's work in progress is left
  out. Included ignored folders, such as build caches, stay as copied.
  Submodules that commit has at another revision are listed in
  `submodulesNotAtStart` (`git -C <worktree> submodule update --init <path>`).
- `new --from <worktree>` copies that worktree the same way.
- `new -c --from <worktree> --changes-only` starts from HEAD and carries
  tracked changes plus eligible untracked files. It excludes ignored build
  output.
- `new --no-fork` is a plain checkout of tracked files at the same commit the
  fork would use; no ignored files or build outputs. It combines with every
  source and branch form. Submodules stay empty. In agent-studio, run
  `mise run setup` before building or reading vendored headers. Expect a cold
  first build.
- Reuse an existing checkout when you can.

The copy-on-write `new` refuses when the source or destination is not
on APFS, crosses volumes, is not a worktree root, or the destination already
exists.

**Git LFS:** `new --no-fork`, a reset copy, and `new -c --from … --changes-only`
fill LFS pointers from the repository's local object store when those objects
are available. They do not download objects. The line counts files left as
pointers; `--json` lists each with its reason and the
`git -C <worktree> lfs pull` option. An incomplete scan is reported in `--json`
with its reason and the same command.

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
`--no-fork`. `--no-fork` and `--changes-only` never read the config, so a
broken config never blocks them.

Source index problems, the same for default `new` and `new --from`:

- An unreadable source index refuses `sourceIndexUnreadable` (retry or
  `--no-fork`), and a sparse or split index refuses
  `sourceIndexUnsupported` (`--no-fork`).
- A missing index counts as empty.
- A copy reset to another commit reads only the source's HEAD commit, not its
  index, so these two refusals apply only when the branch starts at the
  source's HEAD.
  `new <existing-or-origin-branch>` and `new -c --from-branch` still fork warm.

The copy-on-write report in `--json` carries `ignoredIncludedPatterns`,
`ignoredExcludedCount` (excluded paths), `nestedWorktreesSkipped`,
`sourceState` (`asIs` or `reset`), `submodulesNotAtStart`, and, for a reset
copy, `largeFiles`.

The app UI Fork continues to copy all ignored files. These repository include
rules apply to the CLI `new` copy-on-write path, including `new --from`.

## Rules

- Never put development worktrees in `~/dev/worktrees`,
  `~/dev/agent-studio-worktrees`, or `/private/tmp`.
- Remove a worktree with `"$ASW" worktree remove --repo <repo> <branch-or-path>`
  (add `--archive-to-main` to keep its `tmp/` evidence).
- Problems or gaps go to the Worktrees Lead: claude-local
  `9304749a-6517-41da-952d-243201c32337`.
