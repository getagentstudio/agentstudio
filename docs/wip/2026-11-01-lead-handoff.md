# Lead handoff — 2026-11-01

How to resume: read this file, then the newest entries of `tmp/handback/lead-task-log-2026-10-30.md` in this worktree. Decisions live in `/Users/shravansunder/code/projects/agentstudio.feat-pane-context-display/tmp/design-workflows/2026-10-25-decisions-ledger.md` (D1–D109b). The owner gallery is `tmp/presentation/2026-10-30-ui-gallery/`.

## Done (verified)

- #663, the UI-fix round, was merged as `d0d59364b`. It contains:
  - D90–D108b: Messages include chips, a 60% / 280 pt latched height, app colors, and the ⌘R card without asks;
  - D109/D109a: the Arrangements redo, accepted live by the owner;
  - the post-latch height-write fix.
- #664, the BridgeWeb act() overlap flake fix, was merged as `f6fabb611`.
- Release `v0.0.123` and `v0.0.123-beta.107` were cut on `f6fabb611`. Smoke checks passed for both: plist, Developer ID signature, notarization, and cask SHA.

## In flight

- **Crash-log diagnostics.** Branch `diag/ready-root-fault-history` in worktree `/Users/shravansunder/code/projects/agentstudio.diag-scheduler-crash-tsan`, owned by Sidekick `codex-local/01a19240-0c8f-70e0-871c-c00b476ffe00`.
  - The ready-root trap gains a fault-log dump: the 32-entry transition ring, the selected source, the queue links, and a run-local scheduler ID.
  - The Sidekick merges main, runs the credited full gate, pushes, and opens a PR.
  - Next: merge it once CI is green and review is READY. The owner granted merge and release authority.
- **Local-only diag branches in the same worktree, not for merge:**
  - `diag/scheduler-crash-tsan`: read-only seams plus a crash-replay driver;
  - `diag/cli-expiry-hang`: the probe.

## Crash status (no proven cause)

- 16 October production crashes. 15 are in `WatchedFolderScanScheduler`:
  - 4 hit the ready-root trap;
  - 5 hit the pending-lease trap;
  - 5 are ARC faults;
  - 1 hit the FilesystemActor drain trap.
  The remaining one is a `Dictionary.merge` crash (10-04).
- Two dumps show two threads inside scheduler code at the same time.
- The TSan run over the existing suites (70/70) and the replay driver (3/3 scenarios) are both negative.
- The plan is to ship the fault-log PR, then read the next real crash's log.
- Report: `<diag worktree>/tmp/debug-workflows/2026-10-31-production-crashes/` (`debug-investigation.md`, `tsan-step2.md`, `ready-root-step3.md`).
- Crash files live in `~/.local/state/ghostty/crash/`. The Ghostty handler exits with code 6, so macOS writes no `.ips`.

## Next work (owner-approved order unless they redirect)

1. **Track A, testing without the owner's screen (D86/D88/D89; mis-sequenced).**
   - Input: `<diag worktree>/tmp/debug-workflows/2026-11-01-console-dependence/inventory.md`. Of 615 lock-guarded suites, 415 have no visual dependency. The repo runner has no lock guard; ours is a wrapper rule.
   - Known hang to fix: `CLIPaneContextApprovalTests.terminalOutputRetainsAskParity(.expired)`. It needs a wait on the correlated pending expiry, plus producer-end exits (`cli-expiry-followup.md`; probe in `2026-11-01-cli-expiry-hang/`).
   - Sunclaw capture conflict: Screen Sharing plus a Peekaboo CLI 4.5.0 vs GUI 4.9.0 mismatch.
   - Deliverable: a design brief for the owner as a gallery page, then build.
2. **Owner follow-ups for Arrangements:**
   - chips left-aligned after the status, chips alone when there's no status;
   - hover highlight on the row buttons;
   - shortcuts inside Arrangements (rename, switch);
   - a chip menu.
3. **Owner decision brief:** crash reports to OTel. Production has OTLP enabled to `127.0.0.1:4318`, but nothing listens there, and there's no MetricKit or unclean-exit capture.
4. **Owner decision brief:** D105a, an app-owned popover host. Live open costs about 0.5 s, nearly all of it SwiftUI/AppKit layout; our own code is about 30 ms.

5. **Earlier queue, sequenced after the UI work** (D86/D87):
   - Track B: launch sessions from Agent Studio, so pane↔session identity is known (D87).
   - #659: Ghostty/zmx.
   - CPU findings, from the cpu_resource diagnostic of 10-30.
   - Disk writes: production wrote 8.6 GB in about 15 h (macOS disk-write reports of 10-29 and 10-30).

## Helpers (Router, codex-local, gpt-6.1-sol high)

- Implementer `01a1888f` in `feat-messages-polish`: idle; that branch is merged.
- Reviewer `01a17b21` (cwd `a1-frames`).
- Verifier `01a174bb`: sunclaw. It keeps one owner-preview worktree (38d); debug app z01u is running at `6e7f933fd`.
- Crash Sidekick `01a19240`.
- Sessions get unloaded by Router restarts. Reload with `agent-collaboration conversation load --target <ref> --cwd <original cwd> --access workspace-write`.

## Cleanup when resuming

These worktrees are merged or done; remove them through the helper after checking for evidence in their `tmp/`:
- `agentstudio.feat-messages-polish`
- `agentstudio.fix-bridge-file-tree-overlapping-act`
- `agentstudio.a1-frames` (the Reviewer's cwd)

Also delete the preview branches `preview/uifix-*` on origin.

## Rules learned this session (also in memory)

- Push reviewed UI commits to a `preview/` branch right away, and rebuild the owner's sunclaw app in parallel with tests. Reuse one sunclaw worktree.
- Tell the owner exactly what a build contains.
- Never re-ask answered questions. Small UI calls are the Lead's; design choices go to the owner as renders or a gallery page.
- Lock: only console-dependent suites need an unlocked screen. Don't block whole runs; that's being redesigned in track A.

## Added at commit time

- **Open production bug** (owner, 2026-11-01, v0.0.123): the sidebar and Arrangements show no message-count chips, and Arrangements said "Claude · Idle" while the sidebar said "Working". The Implementer `01a1888f` is root-causing it on branch `fix/pane-chips-and-arrangement-status`. Suspect: D109 moved chip projection into Core.
- File paths above that begin `tmp/` are local to the `agentstudio.pane-fixes` worktree on the Sunbook.
