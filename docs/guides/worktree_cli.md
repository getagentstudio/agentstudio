# Agent Studio worktree CLI: agent manual

Use this instead of `wt` to **create** worktrees. Keep using `wt remove` to **remove** them until app PR 1 ships `remove` and `prune`.

## Why use it

- `fork` makes an APFS copy-on-write clone of a worktree: the same files, uncommitted and ignored ones included (`.build`, `node_modules`, `tmp/`). It costs almost no disk. Not measured yet: whether an incremental build in the fork reuses that build output. SwiftPM `.build` and cargo `target/` can embed absolute paths, so the first build after a fork may be partly or fully cold.
- It goes straight to Git through agentstudio-git. No shelling out to `git`, and no app or IPC needed.
- `--json` gives a machine-readable result, and exit codes tell you what happened.
- It puts worktrees at `<repo>.<branch>` next to the repository, the same default path as `wt`, so the sidebar and `wt` both see them as ordinary git worktrees.

## Run it

**Never run bare `agentstudio`.** In Agent Studio panes, `PATH` can include `AgentStudio.app/Contents/MacOS`. APFS ignores case, so `agentstudio` resolves to the GUI app binary and starts a stray second app instead of the CLI. Always use the full, quoted Helpers path:

```bash
ASW="/Applications/AgentStudio Beta.app/Contents/Helpers/agentstudio"   # beta: has the worktree verbs
```

The stable helper (`/Applications/AgentStudio.app/Contents/Helpers/agentstudio`, 0.0.104) doesn't have the `worktree` verbs yet.

| Command | Does | Options |
|---|---|---|
| `"$ASW" worktree new <branch>` | new branch + worktree from the default start point (`origin/HEAD`, else `main`, else `master`) | `--repo <path>` (default: current directory), `--json` |
| `"$ASW" worktree fork <branch>` | copy-on-write clone of a worktree, current state included, on a new branch | `--from <worktree path>` (default: current directory), `--json` |
| `"$ASW" worktree list` | the repository's worktrees with branch and path | `--repo <path>`, `--json` |

Exit codes: `0` created or listed · `1` refused, nothing changed (bad branch name, branch or destination exists, not in a repository, fork not possible) · `2` failed (Git error, or the fork's source changed while it was copying; the output says what was left behind).

## Which one

- **`fork`**: you want your exact current state, including uncommitted work and build output, in a second worktree. It's the cheapest option for big repositories.
- **`new`**: you want a clean branch from the default start point. Prefer it when you don't need the source's build state: `fork` also clones `.build`, `node_modules` and the like, so one fork can add hundreds of thousands of files at once inside `~/Documents/dev/project-dev`, which the running app watches through FSEvents.
- Reuse an existing checkout when you can.

## Works / doesn't (beta 0.0.105-beta.71, checked 2026-10-01)

| Works | Not yet, coming in app PR 1 |
|---|---|
| `new`, `fork`, `list`, `--json`, running without the app open | `remove`, `prune`: use `wt remove <branch>` (archive `tmp/` and push first) |
| worktrees that `wt list` and `wt remove` handle normally | merged / dirty / locked state in `list` (use `wt list`'s `⊂` for "merged" meanwhile) |
| | `fork --changes-only` (only your changes, on top of HEAD) |
| | `new --from-branch <branch>` |
| | `--help` on subcommands (it prints "unknown worktree option") |

**Git LFS:** `new` leaves LFS files as pointer files (libgit2 doesn't run Git's `lfs` filter). In an LFS repository, which includes agent-studio's website captures, run `git -C <new worktree> lfs pull` right after `new`. `fork` copies the source's real files, so it isn't affected.

`fork` refuses (exit 1, nothing changed) when the source or destination isn't on APFS, crosses volumes, isn't a worktree root, or the destination already exists.

## Rules

- Never put worktrees in `~/dev/worktrees`, `~/dev/agent-studio-worktrees` or `/private/tmp`.
- Remove a worktree as soon as its work is merged or abandoned: archive `tmp/`, push, then `wt remove <branch>`.
- Problems or gaps go to the Worktrees Lead: claude-local `9304749a-6517-41da-952d-243201c32337`.
