# Worktree lifecycle: next steps (handoff, 2026-10-09)

This folder is the design home: [Requirements](2026-09-30-worktree-lifecycle-requirements.md) r12, [Specification](2026-09-30-worktree-lifecycle-specification.md) r37, [Program Design](2026-09-30-worktree-lifecycle-program-design.md) r44. Owner decisions D13–D23 are recorded in the Requirements. Use Sol 6.1 high Sidekicks for implementation (owner, 2026-10-09).

```text
worktree lifecycle
├── 1. PR #489: `agentstudio worktree new` (CLI + leaf)   ← done: merged 2026-10-09 as 9c99d10d4 (head 924a9dd6b)
│      proof at 924a9dd6b: hosted CI all green; focused tests green; 9 mutation batches red (batch 10 exactly its 9);
│      Sol implementation review: no findings. Not run: the D23 debug-CLI matrices on a built binary (→ 2)
├── 2. Release 0.0.110 (v0.0.109 and v0.0.110-beta.83 were cut from baefff8e5, before #489)
│   ├── tag main as v0.0.110 and the next beta, v0.0.110-beta.84 (tags are the owner's)
│   ├── after the tag workflows: smoke the downloaded .app (plist, signature, notarization), confirm the Homebrew cask SHAs
│   ├── run the D23 matrices against the 0.0.110 helper: docs/wip/2026-10-09-worktree-d23-cli-matrices/
│   └── then devfiles #15 (agent prompt for `new` / `new -c`), with the owner's yes on its exact diff
├── 3. PR 2: worktree lifecycle in the app → [PR 2 handoff](2026-10-09-worktree-lifecycle-pr2-handoff.md)
│   ├── owner decisions first: removal step shape (Ideas 1–3) and row-menu position (C1/C2)
│   │      → [design space](2026-10-07-worktree-lifecycle-pr2-design-space.md), [evidence](2026-10-07-worktree-lifecycle-pr2-evidence.md)
│   ├── IPC `worktree.*` (LR18): define the param/result shapes first
│   ├── sidebar rows follow CLI and plain-git create/remove (LR20–LR22)
│   ├── Remove Worktree confirmation: row menu + command-bar step (LR23, LR11, LR14, LR16)
│   ├── changes-only fork row in the command bar (LR24)
│   ├── `worktree.create` must reject changes-only + start branch (the runner ignores it today)
│   └── spec text: LR23's stale "beside Fork This Worktree" anchor; LR8 omits `branchNotFound`
└── 4. Follow-ups (each a ticket; not in PR 1 or PR 2 scope)
    ├── SDK (agentstudio-git)
    │   ├── staged fetch traps on a canonically-equivalent tracking-ref pair (Dictionary(uniqueKeysWithValues:)) ← priority
    │   ├── GitRemoteOutputParser merges a canonically-equivalent ref pair (String keys)
    │   ├── git-dir path parsing splits on Unicode newlines / trims Unicode whitespace
    │   ├── non-UTF-8 git output blanks the probe and breaks remoteReferences
    │   ├── createWorktree cleanup failures are silent (give create the fork's residue shape)
    │   ├── residue label: createdBranch reported when only metadata was left
    │   ├── carrier mechanism exists twice (fork and create)
    │   ├── LibGit2ErrorCapture names a missing lock parent directory
    │   ├── GitProcessRunnerTests time out under load
    │   ├── `.copyAll` (app command-bar Fork) skips the source-index check; decide whether it should refuse at all
    │   └── simplification: about 30 fork mechanisms the basic product doesn't need (owner review of the cut list)
    └── App (CLI / leaf)
        ├── LR5: list/remove/prune refresh only origin upstreams (non-origin upstream → failed)
        ├── a malformed --from-branch start probes the remote before refusing
        ├── after a canonical name match, reads use the typed bytes (packed NFC ref + NFD input → unreadable)
        ├── invalidComponentBoundary copy doesn't mention @ / HEAD
        ├── `remove HEAD` with a hand-made <repo>.HEAD folder: decide notFound vs alreadyRemoved for invalid names
        ├── a changes-only request's forkUnavailable names only --no-fork (usage error with --changes-only)
        ├── forkUnavailable alternatives ignore the rejection reason (overlappingRoots, invalidDestinationPath)
        ├── branch deletion (LR14) checks only HEAD for "checked out"; align with branchUse (rebase/bisect)
        ├── `list`/`remove` failing `readFailed` carry no detail; report the step and path, without raw git text
        ├── tmp/ archive: a file swapped for a FIFO mid-copy can block (open O_NONBLOCK, fstat S_ISREG first)
        ├── tmp/ archive: directory metadata (mode, mtime, xattrs) isn't preserved; a 0700 folder archives as 0755
        ├── a warm-copied worktree can't follow a vendor pin bump without `--use-local-vendors` (owner decision on the vendor model)
        └── creation tests' observed state omits .git/worktrees registrations and branch config sections
```

## Where things are

- **PR 1:** #489 is merged (`9c99d10d4`). It pins SDK main `eace2b5` (agentstudio-git #21, merged 2026-10-09).
- **D23 debug-CLI matrices:** the scripts, with each row's source anchor, are in `docs/wip/2026-10-09-worktree-d23-cli-matrices/`.
- **Receipts:** proof receipts and their INDEX are kept with the Lead's local session logs, not in the repository.
