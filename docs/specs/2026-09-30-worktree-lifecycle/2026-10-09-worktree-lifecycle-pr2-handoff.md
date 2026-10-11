# Worktree lifecycle PR 2: handoff (2026-10-09)

PR 1, `agentstudio worktree new` (D13–D23), merged as #489 (`9c99d10d4`). This handoff covers PR 2, the worktree lifecycle inside the app. Design home: [Requirements](2026-09-30-worktree-lifecycle-requirements.md) r12, [Specification](2026-09-30-worktree-lifecycle-specification.md) r37, [Program Design](2026-09-30-worktree-lifecycle-program-design.md) r44. Use Sol 6.1 high Sidekicks for implementation (owner, 2026-10-09).

## Scope

| Obligation | Spec | What PR 2 adds |
|---|---|---|
| IPC `worktree.*` | LR18 | `worktree.create`, `worktree.remove`, `worktree.prune` and `worktree.list` over IPC, with the same outcomes as the CLI. Contracts are compiled into the CLI and called without a per-call catalog fetch. A mutation completes only after the sidebar refresh. Mutations use `appCommandExecute`; list uses `workspaceRead` (Program Design, PR 2 block). |
| Sidebar follows creation and removal | LR20–LR22 | Rows appear and disappear when worktrees are created or removed by the CLI or by plain git, without a restart. Panes stay open and lose their worktree link when their worktree disappears. |
| Remove Worktree confirmation | LR23, LR11, LR14, LR16 | A row-menu item "Remove Worktree…" (not shown for main) plus a command-bar target. Both open one removal step showing integration grade and proof, uncommitted changes, what happens to the branch, the `tmp/` choice, and open panes ("Close Panes and Remove" / "Remove Anyway" / "Cancel"). Stops disable Remove and offer their options. |
| Changes-only fork in the command bar | LR24 | A second row in the fork's branch-name level, using the Specification's help text. |

Out of scope: a switch or jump command, auto-cd, merge, hooks (D19).

## Decisions waiting on the owner (before any UI code)

1. **The removal step's shape.** Ideas 1–3 in [the PR 2 design space](2026-10-07-worktree-lifecycle-pr2-design-space.md). The Lead recommends Idea 1: facts as rows, plus a drill-in step only when a real choice exists.
2. **Where "Remove Worktree…" sits in the row menu.** C1 is its own group at the bottom; C2 is beside Open in Editor. The Lead recommends C1.
3. **Mocks:** edited onto real debug-app captures, never invented. A real capture of a drilled-in command-bar level is still needed, and needs the owner's go. Earlier mock images from 2026-10-05 are in the Lead's local archive, not in the repository; they predate the design space.

## Define first: the IPC boundary shapes

From the other-family design review (F3), before any IPC code:
- Define `IPCWorktree<Verb>Params` / `Result` in the existing IPC convention: field types, discriminants, optional and default semantics, schema home, and the mapping from the leaf's documents.
- Keep ProgrammaticControl Foundation-only.
- Every IPC change gets a full-inventory review by a different-lineage reviewer.

## Known gaps PR 2 must close

- **Changes-only plus a start branch.** The leaf runner ignores a start branch on a changes-only request. The CLI rejects the combination with exit 64, but an IPC caller would silently get changes-only at the source's HEAD. Either `worktree.create`'s argument validation rejects it, or the runner refuses it so every host gets the same answer.
- **Spec text, fixed in PR 2's first spec revision:**
  - LR23 places "Remove Worktree…" "beside Fork This Worktree", but the row menu has no Fork item; the position becomes the owner's C1/C2 answer.
  - LR8's list of unknown integration reasons omits `branchNotFound`, which the Program Design and the code produce; the UI must word it.
- **D23 wording in the UI.** Every user-facing create action names `new -c`. The removal step's "Keep the work" option runs `new -c <branch> --from <this> --changes-only`.

## Evidence

[The PR 2 evidence report](2026-10-07-worktree-lifecycle-pr2-evidence.md) maps today's code: the New Worktree catalog and command-bar levels, the row menus, IPC pane snapshots, pane↔worktree links, popover primitives, the leaf runners, and sidebar refresh. Its line anchors are as of `e3bc09fda`; re-verify them before use.

## Proof expected

- IPC: contract and wire tests for each verb, plus an integration test through the real IPC transport. Each mutation is observed only after the sidebar refresh.
- Sidebar: integration tests for create and remove through the CLI and through plain git.
- UI: headless tests for the step model (every fact row, every stop, each choice), then visual proof on a debug app with PID-targeted captures.
- `mise run test` at the final head. Hosted CI runs the same tasks.

## Carried over from PR 1 (not PR 2 scope)

- The D23 debug-CLI matrices weren't run on a built binary before #489 merged; the real-dispatch integration tests and hosted CI covered the behavior. Run them against the 0.0.110 release build as its smoke.
- The follow-up tickets are listed in [Next steps](2026-10-09-worktree-lifecycle-next-steps.md).
