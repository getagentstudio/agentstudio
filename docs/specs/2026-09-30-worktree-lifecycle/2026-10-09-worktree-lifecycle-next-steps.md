# Worktree lifecycle: next steps (handoff, 2026-10-09)

This folder is the design home: [Requirements](2026-09-30-worktree-lifecycle-requirements.md) r12, [Specification](2026-09-30-worktree-lifecycle-specification.md) r37, [Program Design](2026-09-30-worktree-lifecycle-program-design.md) r44. Owner decisions D13–D23 are recorded in the Requirements. Use Sol 6.1 high Sidekicks for implementation (owner, 2026-10-09).

```text
worktree lifecycle
├── 1. PR #489: `agentstudio worktree new` (CLI + leaf), finish and merge
│   ├── a. D23 implementation: `new <b>` opens an existing branch, `new -c <b>` creates   ← implemented (385b7d3fd, 7b2f80f9b); tests not yet run
│   │      parser -c/--create · resolver two forms · noSuchBranch · originCheckFailed (fail-closed)
│   │      no origin → local only · printed strings say -c · guide · tests · mutation batch 10 (9 predicted)
│   │      still open: the ipc.md example (docs/architecture) wasn't in the batch; check it
│   ├── b. design review of D23   ← done: Sol ready-for-planning at 508d693f7, Claude READY at d4c89926f
│   ├── c. merge the latest main (carries #463 Bridge stability)
│   ├── d. final gate on the Xcode 27 test machine at that head: fresh build, every `mise run test` step with the
│   │      four Swift lanes separate, mutation reds, debug CLI matrices rewritten for -c,
│   │      receipts INDEX
│   └── e. Sol final verify → PR body → ready → owner squash-merges
├── 2. Release 0.0.109 after #489 (stable + beta tags, smoke, Homebrew SHA)
├── 3. PR 2: worktree lifecycle in the app (Spec LR18–LR24; a separate PR)
│   ├── IPC `worktree.*` methods, same outcomes as the CLI (LR18); define IPC param/result shapes first
│   ├── sidebar rows appear/disappear on CLI and plain-git create/remove (LR20–LR22)
│   ├── Remove Worktree confirmation UI: integrated / remaining / dirty / open panes (LR23)
│   ├── command-bar removal step (LR23/LR24)
│   └── IPC `worktree.create` must reject changes-only + start branch (the runner ignores it today)
└── 4. Follow-ups (each a ticket; found during #489 / SDK #21, not in their scope)
    ├── SDK (agentstudio-git)
    │   ├── staged fetch traps on a canonically-equivalent tracking-ref pair (Dictionary(uniqueKeysWithValues:)) ← priority
    │   ├── GitRemoteOutputParser merges a canonically-equivalent ref pair (String keys)
    │   ├── git-dir path parsing splits on Unicode newlines / trims Unicode whitespace
    │   ├── non-UTF-8 git output blanks the probe and breaks remoteReferences
    │   ├── createWorktree cleanup failures are silent (give create the fork's residue shape)
    │   ├── residue label: createdBranch reported when only metadata was left
    │   ├── carrier mechanism exists twice (fork and create)
    │   ├── LibGit2ErrorCapture names a missing lock parent directory
    │   └── GitProcessRunnerTests time out under load
    └── App (CLI / leaf)
        ├── LR5: list/remove/prune refresh only origin upstreams (non-origin upstream → failed)
        ├── a malformed --from-branch start probes the remote before refusing
        ├── after a canonical name match, reads use the typed bytes (packed NFC ref + NFD input → unreadable)
        ├── invalidComponentBoundary copy doesn't mention @ / HEAD
        ├── `remove HEAD` with a hand-made <repo>.HEAD folder: decide notFound vs alreadyRemoved for invalid names
        ├── a changes-only request's forkUnavailable names only --no-fork (usage error with --changes-only)
        ├── forkUnavailable alternatives ignore the rejection reason (overlappingRoots, invalidDestinationPath)
        └── branch deletion (LR14) checks only HEAD for "checked out"; align with branchUse (rebase/bisect)
```

## Where things are

- PR #489: `fix/worktree-new-from-any-branch`, pinned to SDK main `eace2b5` (SDK #21 merged 2026-10-09).
- Receipts and their INDEX are kept with the Lead's local session logs (not in the repository).
- The canonical plan with its D22/D23 amendment: `tmp/plan-workflows/2026-10-08-worktree-creation-followup.md` on the #489 worktree.
- Every known red at the last full gate (`94b57512d`) is foreign and has a CI Lead disposition (TQ9, TQ15, TQ24–TQ26, TQ28, TQ32, TQ33, the #499 residual); none traces to #489.
