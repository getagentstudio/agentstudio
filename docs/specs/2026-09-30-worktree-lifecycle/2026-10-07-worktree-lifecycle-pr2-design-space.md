# PR 2 design space: Remove Worktree and the changes-only fork

Lead draft, 2026-10-07, for owner review before any mocks are generated.

> **2026-10-09 (D23):** creating now needs `-c`, so the dirty-refusal row "Keep the work in a new worktree" runs `new -c <branch> --from <this> --changes-only`. The owner hasn't yet chosen among Ideas 1–3 or menu positions C1/C2; the [PR 2 handoff](2026-10-09-worktree-lifecycle-pr2-handoff.md) tracks that decision. These are not mocks. They are text sketches built from the real command bar's parts, so we can choose which ideas get mocked onto real captures.

- **Sources:**
  - real debug-app captures: the sidebar, and the worktree row menu on `demo-app.feature-x`;
  - current code at `e3bc09fda`;
  - spec rows LR11, LR14, LR16, LR23 and LR24.
- **Labels:** labels that exist in the app today are quoted from code. "Remove Worktree…", "Close Panes and Remove", "Remove Anyway" and "Cancel" are fixed by LR23. The LR24 help text is fixed by the spec. Every other label below is a proposal.
- **Missing:** a real capture of the command bar at a drilled-in level. The mocks will be edited onto that capture, which needs the owner's "go".

## What exists today

- **Worktree row menu (real capture):**
  - Create New in Tab ›
  - Create New in Pane ›
  - Open in Editor ›
  - Reveal in Finder
  - Copy Path

  There is no Fork row: `LocalActionSpec.forkThisWorktree` is used only by the command bar. LR23's "beside Fork This Worktree" is a stale position anchor, so the position is choice C below.
- **The parts a command-bar step is built from:**
  - a breadcrumb trail (`CommandBarBreadcrumbRow`);
  - capitalised group headers ("FORK A WORKTREE", "FROM A BRANCH");
  - rows with a title, subtitle, secondary line and icon;
  - a disabled row that states its reason in the subtitle ("Checking fork availability…").

  Every enabled row either runs or drills in (›). The command bar has no toggles or checkboxes, and no free-form summary area: `CommandBarStatusStrip` is a 28-pt context line.
- **Program design:** the row menu's Remove Worktree… and the command-bar target both open one removal step in the command bar, which uses `NSOpenPanel` for "archive to a folder".

## What the step must show (LR23 with LR11, LR14, LR16)

| Fact | Spec | Example on `demo-app.fix-login` |
|---|---|---|
| Integration grade and proof | E5 | "Integrated into origin/main: squash", then the proof lines (next section) |
| Uncommitted changes | E6 | "No changes" or "1 file changed" |
| What happens to the branch | LR14 | "Branch fix-login is deleted", or kept, with a reason |
| `tmp/` choice | E7, LR12 | archive to main, archive to a folder, or discard |
| Open panes | LR16 | Close Panes and Remove / Remove Anyway / Cancel |
| Stops | LR11 | dirty, locked, current, git lock: Remove disabled, with options |

## What the integration proof shows (E5, checked against the shipped contract)

LR23 asks for the grade **and** its proof. The shipped assessment, `WorktreeIntegrationAssessmentDocument`, is exactly one of:

```jsonl
{"grade": "integrated", "proof": {"proof": "squash", "commit": "2c9fe2f"}}
{"grade": "integrated", "proof": {"proof": "sameCommit"}}
{"grade": "hasRemainingContribution"}
{"grade": "unknown", "reason": "historyLimitReached"}
```

The proof kinds are `sameCommit`, `ancestor`, `sameContent`, `emptyDelta` and `squash` (with its commit). The assessment is always measured against E4 (`WorktreeIntegrationTarget`: a ref, e.g. `origin/main`, and a commit), and the removal outcome names the branch tip it assessed (LR15 `branch.commit`). So the fact row shows three things: **the grade and proof kind**, **what the proof means for this branch**, and **what was compared** (branch tip against target commit).

One concrete example, `demo-app.fix-login` squash-merged into `origin/main`:

```text
  ✓ Integrated into origin/main: squash
      fix-login's whole change equals commit 2c9fe2f
      checked fix-login 4e5f6a7 against origin/main 9d8e7f6
```

The CLI prints the same assessment as `integrated (squash 2c9fe2f)` (`WorktreeCommandLineFormatter+Listed.swift:58`). The UI line uses words, but the proof kind and the commit stay visible.

Every grade, mapped to its row (the third line, "checked … against …", is always shown):

| Contract | Row title | Meaning line |
|---|---|---|
| `integrated` / `sameCommit` | Integrated into origin/main: same commit | fix-login is origin/main's commit |
| `integrated` / `ancestor` | Integrated into origin/main: in its history | fix-login's tip is in origin/main's history |
| `integrated` / `sameContent` | Integrated into origin/main: same files | fix-login's files are identical to origin/main's |
| `integrated` / `emptyDelta` | Integrated into origin/main: no net change | fix-login changes nothing since it branched off |
| `integrated` / `squash(commit)` | Integrated into origin/main: squash | fix-login's whole change equals commit 2c9fe2f |
| `hasRemainingContribution` | Not integrated into origin/main | fix-login has changes that origin/main does not |
| `unknown(reason)` | Can't tell if fix-login is integrated | the reason in words, e.g. `historyLimitReached`: "searched the last 500 commits of origin/main" |

Unknown reasons the UI must word: `noTarget`, `noMergeBase`, `multipleMergeBases`, `historyLimitReached`, `incompleteHistory`, `missingObjects`, `readFailed` and `branchNotFound`. The last one is in the program design and the code (`WorktreeRemovalEffectDocuments.swift:185`) but missing from LR8's list. That's a spec text gap, logged.

## The three choices that shape the design

- **A. Where the facts sit:**
  - **A1:** fact rows (not actionable) in a group at the top of the step, built from existing row parts;
  - **A2:** a new summary block above the list, which is a new view part;
  - **A3:** facts folded into the subtitles of the action rows.
- **B. How choices are made, with no toggles:**
  - **B1:** one level, one row per complete plan, so the `tmp/` choice multiplied by the pane choice multiplies rows;
  - **B2:** a drill-in step per choice, shown only when that choice exists. A clean worktree is one step.
  - **B3:** one row for the safest plan, plus an "Other ways to remove" drill-in for the rest.
- **C. Where Remove Worktree… sits in the row menu (LR23):**
  - **C1:** its own group at the bottom, after Copy Path, where macOS puts destructive items;
  - **C2:** beside Open in Editor.

## Idea 1: facts as rows, a step only when a choice exists (A1 + B2), recommended

Clean worktree: integrated, no changes, empty `tmp/`, no panes. One step.

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.fix-login › Remove Worktree                    │
├────────────────────────────────────────────────────────────────────┤
│ WHAT HAPPENS                                                       │
│   ✓ Integrated into origin/main: squash                            │
│       fix-login's whole change equals commit 2c9fe2f               │
│       checked fix-login 4e5f6a7 against origin/main 9d8e7f6        │
│   ✓ No changes                      nothing uncommitted            │
│   ✓ Branch fix-login is deleted     because it is integrated       │
│   ✓ tmp/ is empty                   nothing to keep                │
│                                                                    │
│ REMOVE                                                             │
│ > Remove demo-app.fix-login                                        │
│     deletes the folder and the branch                              │
└────────────────────────────────────────────────────────────────────┘
```

`tmp/` has files and 2 panes are open. Step 1 chooses what happens to `tmp/`:

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.fix-login › Remove Worktree                    │
├────────────────────────────────────────────────────────────────────┤
│ WHAT HAPPENS                                                       │
│   ✓ Integrated into origin/main: squash                            │
│       fix-login's whole change equals commit 2c9fe2f               │
│       checked fix-login 4e5f6a7 against origin/main 9d8e7f6        │
│   ✓ No changes                      nothing uncommitted            │
│   ✓ Branch fix-login is deleted     because it is integrated       │
│   ! tmp/ has 14 files               3.2 MB, choose below           │
│   ! 2 panes are open                you choose on the next step    │
│                                                                    │
│ KEEP TMP/                                                          │
│ > Archive to demo-app/tmp/                                  ›      │
│     copies 14 files to the main worktree, then removes             │
│   Archive to a folder…                                      ›      │
│     pick a folder, then removes                                    │
│   Discard tmp/                                              ›      │
│     the 14 files are deleted with the worktree                     │
└────────────────────────────────────────────────────────────────────┘
```

Step 2 appears only because panes are open (LR16):

```text
┌────────────────────────────────────────────────────────────────────┐
│ … › demo-app.fix-login › Remove Worktree › Archive to demo-app/tmp/│
├────────────────────────────────────────────────────────────────────┤
│ 2 PANES ARE OPEN IN THIS WORKTREE                                  │
│   zsh                               Tab 1 · Pane 1 · Active        │
│   claude                            Tab 1 · Pane 2                 │
│                                                                    │
│ REMOVE                                                             │
│ > Close Panes and Remove                                           │
│     closes the 2 panes, archives tmp/, removes                     │
│   Remove Anyway                                                    │
│     the panes stay open without their worktree                     │
│   Cancel                                                           │
└────────────────────────────────────────────────────────────────────┘
```

Uncommitted changes: LR11 `dirty`. Remove is disabled and the stop's options become rows. "Keep the work" runs `new --from <this> --changes-only`, and "Discard" is `-f`.

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.feature-x › Remove Worktree                    │
├────────────────────────────────────────────────────────────────────┤
│ WHAT HAPPENS                                                       │
│   ! Not integrated into origin/main                                │
│       feature-x has changes that origin/main does not              │
│       checked feature-x 1a2b3c4 against origin/main 9d8e7f6        │
│   ! 1 file changed                  +1 -0, not committed           │
│   ! Branch feature-x is kept        because it is not integrated   │
│   ✓ tmp/ is empty                   nothing to keep                │
│                                                                    │
│ REMOVE                                                             │
│   Remove demo-app.feature-x                        (disabled)      │
│     uncommitted changes would be lost                              │
│                                                                    │
│ OTHER WAYS                                                         │
│ > Keep the work in a new worktree                           ›      │
│     copies the changes, then you can remove this one               │
│   Discard changes and remove                                       │
│     the 1 changed file is lost                                     │
└────────────────────────────────────────────────────────────────────┘
```

## Idea 2: every plan is a row (A3 + B1)

One level and no steps, but the rows multiply: 3 `tmp/` choices × 2 pane choices = 6 long rows.

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.fix-login › Remove Worktree                    │
├────────────────────────────────────────────────────────────────────┤
│ REMOVE  (tmp/ has 14 files · 2 panes open)                         │
│ > Close panes, archive tmp/ to demo-app/tmp/, remove               │
│     integrated (squash 2c9fe2f) · branch fix-login is deleted      │
│   Close panes, archive tmp/ to a folder…, remove                   │
│   Close panes, discard tmp/, remove                                │
│   Keep panes open, archive tmp/ to demo-app/tmp/, remove           │
│   Keep panes open, archive tmp/ to a folder…, remove               │
│   Keep panes open, discard tmp/, remove                            │
└────────────────────────────────────────────────────────────────────┘
```

## Idea 3: summary block and one safest plan (A2 + B3)

A new summary block above the list. One row runs the safest plan; everything else is behind a drill-in.

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.fix-login › Remove Worktree                    │
├────────────────────────────────────────────────────────────────────┤
│   fix-login 4e5f6a7 integrated into origin/main 9d8e7f6            │
│   proof: squash, whole change equals commit 2c9fe2f                │
│   No changes · tmp/ 14 files (3.2 MB) · 2 panes open               │
├────────────────────────────────────────────────────────────────────┤
│ REMOVE                                                             │
│ > Remove                                                           │
│     closes 2 panes, archives tmp/ to demo-app/tmp/,                │
│     deletes branch fix-login                                       │
│   Other ways to remove                                      ›      │
│     keep panes open, archive elsewhere, or discard tmp/            │
└────────────────────────────────────────────────────────────────────┘
```

## The changes-only fork (LR24)

The fork's branch-name level today has one row: "Create <name>", subtitle "from <source>". LR24 adds a second row in the same level, carrying the spec's help text:

```text
┌────────────────────────────────────────────────────────────────────┐
│ demo-app › demo-app.fix-login › Fork This Worktree                 │
│   fix-login-2                                                      │
├────────────────────────────────────────────────────────────────────┤
│ CREATE                                                             │
│ > Create fix-login-2                     from demo-app.fix-login   │
│     → demo-app.fix-login-2                                         │
│   Create fix-login-2, changes only       from demo-app.fix-login   │
│     Tracked changes and untracked files; no ignored files or       │
│     build outputs                                                  │
└────────────────────────────────────────────────────────────────────┘
```

## Where Remove Worktree… sits in the row menu

```text
┌─ C1: own group at the bottom ──────────────────────────────────────┐
│ Create New in Tab                         ›                        │
│ Create New in Pane                        ›                        │
├────────────────────────────────────────────────────────────────────┤
│ Open in Editor                            ›                        │
├────────────────────────────────────────────────────────────────────┤
│ Reveal in Finder                                                   │
│ Copy Path                                                          │
├────────────────────────────────────────────────────────────────────┤
│ Remove Worktree…                                                   │
└────────────────────────────────────────────────────────────────────┘
```

```text
┌─ C2: beside Open in Editor ────────────────────────────────────────┐
│ Create New in Tab                         ›                        │
│ Create New in Pane                        ›                        │
├────────────────────────────────────────────────────────────────────┤
│ Open in Editor                            ›                        │
│ Remove Worktree…                                                   │
├────────────────────────────────────────────────────────────────────┤
│ Reveal in Finder                                                   │
│ Copy Path                                                          │
└────────────────────────────────────────────────────────────────────┘
```

## Comparing the ideas

| | Idea 1 | Idea 2 | Idea 3 |
|---|---|---|---|
| New view parts | none | none | summary block |
| Clean worktree | 1 step | 1 level | 1 level |
| `tmp/` + open panes | 3 steps | 1 level, 6 rows | 1 level + drill-in |
| Facts visible before choosing | all, as rows | only in subtitles | all, in the block |
| Main cost | more steps on a messy worktree | row explosion, long labels | the default plan decides for the user |

Recommendation: **Idea 1 with C1**. It uses only parts the command bar already has, a clean worktree takes one step, every fact is visible before anything is chosen, and each extra step exists only because a real choice exists.

## What the mocks will be

- **Base images:** real captures, edited, never invented: the sidebar (have), the row menu (have) and a command-bar level (missing; owner "go" needed).
- **Ideas to mock:** the ones the owner picks, each in these states:
  1. clean;
  2. `tmp/` plus open panes;
  3. dirty refusal.
- **Also mocked:** the row menu at C1 and C2, and the LR24 fork level.
- **Who makes them:** a 🐒 Sidekick on Sol 6.1 high, from a brief that embeds the real captures and the exact labels above. The Lead checks every image against the real capture before anything reaches the owner.
