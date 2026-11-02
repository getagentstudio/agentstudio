# Lead handoff (updated 2026-11-02)

Resume from this file. Decisions live in the ledger at `agentstudio.feat-pane-context-display/tmp/design-workflows/2026-10-25-decisions-ledger.md` (D1–D110, local to the Sunbook). The Lead's task log is `agentstudio.pane-fixes/tmp/handback/lead-task-log-2026-10-30.md`, and the owner gallery is `agentstudio.pane-fixes/tmp/presentation/2026-10-30-ui-gallery/`. Linear tracking: LUNA-509–517, plus LUNA-480 (#659) and LUNA-485 (pane/session identity).

## Start here

1. **Track A: testing without the owner's screen** (owner decisions D86, D88, D89). Do this first; locked-screen holds blocked gates repeatedly on 10-31 and 11-01.
   - **Input:** the console-dependence inventory in the `agentstudio.diag-scheduler-crash-tsan` worktree, `tmp/debug-workflows/2026-11-01-console-dependence/inventory.md`. 415 of 615 lock-guarded suites are static candidates for running without a console. That count comes from reading the code, not from runs; the Advisor's caution applies.
   - **Prove before moving:** run the suites unchanged in the target session or lane before moving any of them out.
   - **Known hang:** `CLIPaneContextApprovalTests.terminalOutputRetainsAskParity(.expired)` hung under a lock.
     - Make it wait on the correlated pending expiry before advancing the clock, and give the wait exits for producer end, refusal and final failure.
     - Details: `cli-expiry-followup.md` and `2026-11-01-cli-expiry-hang/`.
   - **Already evidenced:** offscreen bitmap tests (NSHostingView, cacheDisplay) ran fine while locked on 11-02.
   - **Sunclaw capture conflict:** Screen Sharing interferes, and Peekaboo's CLI (4.5.0) and GUI (4.9.0) versions don't match.
   - **Deliverable:** a design brief for the owner as a gallery page; build only after they pick.
2. **Arrangements follow-ups (owner):**
   - chips left-aligned right after the status, with a gap, and chips alone when there's no status;
   - hover highlight on the row buttons;
   - shortcuts inside Arrangements (rename, switch arrangement);
   - a chip menu.
3. **Owner decision brief: crash reports to OTel.**
   - Production OTLP points at `127.0.0.1:4318`, and nothing listens there.
   - There's no MetricKit or unclean-exit capture.
   - The Ghostty crash handler writes minidumps to `~/.local/state/ghostty/crash/` and exits with code 6, so macOS writes no `.ips`.
4. **Owner decision brief: D105a, an app-owned popover host.** Messages takes about 0.5 s to open, almost all of it SwiftUI/AppKit layout; our own code is about 30 ms.
5. **Earlier queue:**
   - Track B: launch sessions from Agent Studio (D87, LUNA-485).
   - #659: Ghostty/zmx (LUNA-480).
   - CPU findings.
   - Disk writes: 8.6 GB in about 15 h.
6. **Production crash root cause.** Wait for the next real crash's v0.0.124 fault log.
   - **Logged at the trap:** the ready-root trap now logs the 32-entry transition ring, the selected source, queue links, a run-local scheduler ID, and both the guard's observed state and the reread state.
   - **Reading a mismatch:** if observed and reread differ, report it as an observed mismatch with the cause unresolved; it isn't proof of a concurrent writer.
   - **Status:** 15 of the 16 October crashes are in `WatchedFolderScanScheduler`. TSan and the replay driver were both negative.

## Shipped

| When | What |
|---|---|
| 11-01 | #663 (UI fixes), #664 (BridgeWeb flake), #666 (handoff); release v0.0.123 and v0.0.123-beta.107 |
| 11-02 | #667 and #669 (crash fault-log diagnostics) |
| 11-02 | #670 (worktree CLI failures now report the real reason; the intermittent cause is still unknown) |
| 11-02 | #668 (sidebar restore) |
| 11-02 | Release v0.0.124 and v0.0.124-beta.108 on `25ca7f9c2`; smoke-verified (plist, Developer ID, notarization, cask SHA) |

About #668:

- **What it restored:** the pane-row active, PR, changes, sync and drawer chips, plus the branch and note lines. #651 had deleted them silently.
- **How it was proven:** 12 native pairs against v0.0.122.
  - 10 are pixel-identical.
  - 2 differ only in approved additions: the status color, the bracketed Agent Line age and the typed message chip.
- **Regression guard:** native and projection tests now pin every element.
- **D110:** v0.0.122 wins on the 18 pt chip gutter and the note line. The owner may prefer #651 S12's flush-left chips; that's a one-line change.

## Rules learned (also in memory)

- **UI specs:** every UI spec lists the existing on-screen elements as keep, change or remove.
- **UI reviews:** every UI review diffs against the previous release's screenshots. This came out of #651's silent deletion.
- **Preview builds:** push reviewed UI commits to a `preview/` branch right away, and rebuild the owner's sunclaw app in parallel. Reuse one sunclaw worktree. Tell the owner exactly what a build contains.
- **When the console locks:** headless or offscreen suites may run. When a full gate can't finish because of a lock, hosted CI is the gate, and the PR says so.
- **Questions to the owner:** never re-ask answered questions. Small UI calls are the Lead's; design choices go to the owner as renders.

## Helpers (Router, codex-local, gpt-6.1-sol high)

| Role | Session | Where |
|---|---|---|
| Implementer | `01a1888f` | `feat-messages-polish` |
| Reviewer | `01a17b21` | cwd `a1-frames` |
| Verifier | `01a174bb` | sunclaw; one owner-preview worktree, debug app z01u |
| Crash Sidekick | `01a19240` | `diag-scheduler-crash-tsan` |
| Advisor | `01a15e37` | |

Router restarts unload sessions. Reload with `agent-collaboration conversation load --target <ref> --cwd <original cwd> --access workspace-write`.

## Cleanup

- **Merged or done worktrees:**
  - `agentstudio.feat-messages-polish`
  - `agentstudio.fix-bridge-file-tree-overlapping-act`
  - `agentstudio.a1-frames`
  - `agentstudio.diag-scheduler-crash-tsan` (its local diag branches hold the TSan driver and probes)
- **Branches on origin:** `preview/uifix-*`, `fix/pane-chips-and-arrangement-status`, `fix/ready-root-observed-state`, `fix/worktree-cli-operation-key`, `docs/lead-handoff-*`.
- **How:** check each `tmp/` for evidence before removing anything, then use the worktree helper.
