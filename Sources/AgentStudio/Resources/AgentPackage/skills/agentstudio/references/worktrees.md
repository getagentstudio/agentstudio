# Worktree commands and effects

This reference owns branch, content and folder choices for local worktree operations. Start with the repository, source worktree, intended branch and whether the task permits creation/removal. Return the chosen mode, start commit, content limits, destination, fetch effect and per-entry result. Stop before a mutation whose data loss or target ownership is unsettled.

## Open a branch or create one

```sh
"$AS_CLI" worktree new release-fix --repo "$REPO"
"$AS_CLI" worktree new -c fix-checkout-alt --repo "$REPO" --from "$SOURCE"
"$AS_CLI" worktree list --repo "$REPO" --no-fetch --json
```

`new BRANCH` opens an existing local or `origin/BRANCH` branch. A remote-only branch creates a local tracking branch. An existing local branch keeps its upstream; it may fast-forward when strictly behind origin, but ahead/diverged branches are kept. It refuses if the branch is already checked out elsewhere: use the returned existing worktree. It does not create an arbitrary new branch when the name is absent.

`new -c BRANCH` creates a new branch and refuses an existing local or origin name. Its default start is the selected source worktree's HEAD, with no upstream. Without `--from`, the source is the main worktree: this is a physical source checkout, not an independent instruction to resolve a branch named `main`.

There is no `worktree fork` verb. Copy a chosen same-repository worktree with `new -c BRANCH --from SOURCE`. The original branch/worktree remains in place.

The destination is a sibling of the main worktree: `<main-parent>/<main-folder>.<branch-slug>`, even when the source is another worktree. Branch names are at most 200 characters; folder slugs at most 80. Different names can collide after slugging. Existing destinations are refused, never reused or overwritten. Read the returned path rather than reconstructing a path for subsequent deletion.

## Select the start and files separately

| Choice | Start and content |
| --- | --- |
| Default copy-on-write fork | Copies supported source files. Ignored content requires the repository's `worktree.include` declaration in `.agentstudio.config.json`; a build cache is not guaranteed merely because it exists. |
| `--from SOURCE` | Chooses the same-repository worktree whose files supply the copy. With `-c`, default start is its HEAD. The destination still belongs beside the main worktree. |
| `-c BRANCH --from-branch START` | Selects the new branch's start commit from a real local/origin branch; does not move START. Source files and start commit are different choices. At a different start, copied tracked files are reset and ordinary untracked content omitted; selected ignored includes may remain. |
| `-c BRANCH --from SOURCE --changes-only` | Clean checkout plus supported net tracked disk changes and eligible untracked files. Excludes ignored content. Requires both `-c` and `--from`; incompatible with `--from-branch` or `--no-fork`. |
| `--no-fork` | Plain tracked checkout at the selected start, with no source working overlay, ignored files or build outputs. |

Every copy rebuilds the destination index from HEAD. It does **not** preserve staging: an index-only change can be lost, and a copied tracked disk change is not staged as it was in the source. If staging matters, inspect source disk and index state and preserve it through separately authorized Git work before choosing a mode. There is no preserve-staging flag.

Good: choose `--changes-only` because the requested artifact is the supported disk delta and eligible untracked files. Bad: add it automatically after a failed full fork when the user wanted ignored build outputs. A printed `--no-fork` alternative changes what will be copied; explain the loss and obtain any needed decision first.

## Fetch-aware inspection

```sh
"$AS_CLI" worktree new --help
"$AS_CLI" worktree list --repo "$REPO" --no-fetch --json
"$AS_CLI" worktree remove "$TARGET" --repo "$REPO" --dry-run --no-fetch --json
"$AS_CLI" worktree prune --repo "$REPO" --no-fetch --json
```

`list`, removal preview and prune preview can fetch unless `--no-fetch` is supplied. Use it for a fully read-only preview, and state that decisions use refs already on disk. Creation may refresh start refs or probe whether origin already has the target name; `--changes-only` skips the start refresh but still probes target-name availability unless `--no-fetch` is used. A failed fetch or stale on-disk ref is a result to report, not a reason to invent the remote state.

`list --json` supplies the main-worktree identity and integration assessment. Inspect its fetch outcome and each entry's state; a successful listing is not proof that a branch has no remaining contribution.

## Remove or prune only the intended targets

`remove TARGET...` resolves paths before names and can delete a branch even when no worktree folder remains. Multiple targets have separate outcomes, not an atomic batch. Run from outside the target and verify the actual directory/branch from the preview.

Default removal protects uncommitted work, evidence in `tmp/`, main/current worktrees, locks and unsafe branch deletion. It deletes an integrated local branch when policy permits; the folder may be removed while the branch remains. `--no-delete-branch` keeps it deliberately. `-f` discards working changes, `-D` permits branch deletion with remaining contribution, and `--discard-tmp` discards evidence: these are three different losses, each needing task authorization. They do not bypass every protection.

To preserve evidence, select `--archive-to-main` or `--archive-to FOLDER` explicitly. The archive appends the removed worktree's folder name beneath that destination. A conflicting destination or partial archive stops removal; inspect what was actually copied before another call.

`--remove-stale-lock` is only for a specifically identified regular Git lock rechecked as stale: at least 120 seconds old and a successful probe finding no Git process. An unavailable probe does not establish staleness. Do not delete locks by hand or unlock another owner's work to make a preview pass.

`prune` previews by default; `--apply` removes eligible worktrees. It has no force, `-D`, discard or stale-lock options. Read every `wouldRemove`, `skipped` and failure entry, then apply only within the authorized scope. A skipped item remains unresolved.

The local CLI's activity result can be `notChecked`; that is not an assurance that Agent Studio has no open consumer. `closePanes` and `removeWithOpenPanes` are not local CLI flags. Resolve affected consumers with their owner before destruction.

## Read the result

Prefer `--json` when handling multiple entries or partial effects. Retain destination/branch/start and fetch fields for creation; for removal retain directory, administration, branch, evidence, assessment, activity and lock-residue effects. A branch retention reason or leftover is part of the outcome even after a folder disappears.

A zero exit can include previews, skips, fetch failure or a retained branch. Completion requires checking the requested effects, not just the exit code. Keep exact refusals/leftovers for recovery; do not retry a partially changed operation until the actual resulting state is inspected.
