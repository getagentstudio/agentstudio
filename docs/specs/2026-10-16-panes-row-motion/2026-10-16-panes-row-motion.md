# Panes row: motion and the detached branch line (design note, 2026-10-16)

## Owner decisions (2026-10-16, this session)

- **Working status:** option A, a breathing dot. Apply it the same way to the Agent Line's `working`. `Working · monitoring` gets a slow rotate. Needs you, Idle and Done stay still. Motion is off under Reduce Motion.
- **"Now" activity chip:** pulses **very gently** while terminal output is streaming. This covers terminals without agents too.
- **Branch line:** a pane in a worktree whose branch is detached or unknown still shows it, as `repo · detached` or `repo · unknown branch`.
- **Ahead/behind chip:** stays hidden when fully in sync, as the code does today. The Stage 1 spec's "upstream exists" wording gets corrected.
- **Rule:** the choice of what moves lives with the status display spec, beside its icon and tone, not in the view.

## Observable contract

| Row state | What the person sees |
|---|---|
| Session status `Working`, or Agent Line `working` | green dot breathes, roughly a 1.5 s cycle |
| `Working · monitoring` (status or Agent Line) | dotted circle rotates slowly |
| any other status or Agent Line state | glyph still |
| activity within the streaming window | the clock chip pulses very gently (small opacity change, slow) |
| streaming window lapses with no new activity | the pulse stops at the next presentation change; nothing else changes |
| Reduce Motion on | no glyph or chip motion; everything else is identical |
| worktree pane, detached or unknown branch | `repo · detached` / `repo · unknown branch` line present |

## Structure

1. **Motion is display data.** `RepoExplorerPaneContextLine` gains `glyphMotion: PaneLineGlyphMotion` (`still | breathe | rotate`). The same projection that derives `icon` and `tone` from status and Agent Line work sets it. The view only renders it.
2. **Rendering:** `RepoExplorerPaneContextLineView` applies the SF Symbol effects (`.symbolEffect(.breathe)` / `.rotate`, `isActive:` only when the motion is not `still`). These are Core Animation effects on the render server, with no SwiftUI re-render loop and no CPU timer. They are disabled under `accessibilityReduceMotion`.
3. **Streaming is a derived activity fact.**
   - `RepoExplorerPaneActivityProjection` gains `isStreaming`: activity age below `AppPolicies.RepoExplorer.streamingActivityDuration`. That is a behavior constant, so it lives in AppPolicies; its value is the 10 s activity-publication coalescing plus a margin.
   - The flag's lapse instant joins `nextPresentationChangeDate`, so the existing refresh path turns the pulse off. No new timer, observer or atom.
   - New output while a row already reads "Now" changes nothing visible, so the projection is equal-paint, but the lapse moves later. The adapter re-arms the deadline whenever a pane's or a repository's next transition moved, not only a repository's. Without that, the earlier deadline fires, re-projects to the same transitions and stops, and the pulse never ends. Re-arming only on a moved transition keeps a fired deadline from looping.
4. **The chip pulse** is a very gentle repeating opacity animation on the clock chip while `isStreaming`. It is off under Reduce Motion.
5. **The branch line:** today the projection drops the line when branch normalization fails. It will instead name git's answer (`detached`, `unknown branch`) for a worktree pane. A missing branch fact means facts have not arrived yet, so the line stays out until they do, rather than flashing `unknown branch` at launch.

## Proof

- Unit tests (projection):
  - the motion mapping for every status and Agent Line state;
  - `isStreaming` with its lapse folded into `nextPresentationChangeDate`, driven by a controlled clock;
  - the detached and unknown branch copy.
- View: motion is a function of the line model. A focused test proves that `none` yields no effect and that Reduce Motion disables effects, where the harness allows it.
- Real app: a working agent in a debug pane, then a sequence of captures showing the dot changing and the chip pulsing. Then Reduce Motion on, showing everything still.
- Gates: lint, full `mise run test`, independent review, CI, pinned squash.
