# J2 — observe the row as a person sees it

Oracle: `docs/specs/2026-10-16-panes-row-motion/2026-10-16-panes-row-motion.md`,
The section **Revision 2026-10-17: the chip pulse is withdrawn** supersedes the
older streaming-pulse rows. The Lead names the oracle commit separately from
the declared build commit. Option C removes the pulse,
`isStreaming` and `streamingActivityDuration`; glyph motion is retained.
Rendering at that pin is in
`Features/RepoExplorer/RepoExplorerPaneContextLineView.swift` and
`Models/RepoExplorerPaneActivityProjection.swift`. Use the source at the declared
build when these types move; do not treat an old path as a current target.

## Drive a declared scenario

Use J1's launch/health mechanics and the Lead's two full commits. The driver
compares its declared build with the launch receipt; that receipt is declared
provenance and still needs the binary/build evidence required by J1.
Create new disposable terminals
through the live command catalog, record their handles and retain J1's baseline.
Leave the app in the background. No activation, foreground clicks, app-name
targeting, token overrides or internal setters.

```bash
DRIVER=.agents/skills/verify-agentstudio/scripts/panes-row.sh
RUN=tmp/verify-agentstudio/j1
/bin/bash "$DRIVER" show "$DECLARED_BUILD_COMMIT" "$ORACLE_COMMIT" "$RUN" "$WINDOW_ID" "$FRESH_UUIDV7"
/bin/bash "$DRIVER" drive "$DECLARED_BUILD_COMMIT" "$ORACLE_COMMIT" "$RUN" "$NEW_PANE_ID" working "$ANOTHER_FRESH_UUIDV7"
```

`show` uses `command.execute` → `showPanesSidebar` with
`arguments:{kind:"workspaceWindow",workspaceWindowId:<returned-id>}`, as in the
prior-art driver. Before `drive`, retain `terminal.snapshot.lastSequence`.
`drive` sends a real pane CLI command and a subsequent correlated OSC title only
if it succeeds. Use a separate fresh UUIDv7 for each stage:

| Stage | Actual command in this run's new terminal | Required row observation |
| --- | --- | --- |
| working | `"$AGENTSTUDIO_CLI" line "verify working" --working` | Agent Line working glyph breathes; chip=still under the label rule below |
| monitoring | `line "verify monitoring" --monitoring verification` through that same CLI | dotted glyph rotates; chip=still |
| done | `line "verify done" --done` | glyph still; chip=still |
| blocked | `line "verify blocked" --blocked-on-you verification` | glyph still; chip=still; correct text |
| clear | `line --clear` | this run's Agent Line disappears; plain-row glyph and chip stay still |
| stream | 45-line loop, `echo tick` separated by shell `sleep 1` | chip=still while output actually streams and again after quiet; recency label updates across stages, with no streaming pulse |

The stream's sleep is its output stimulus, never a readiness wait. Its title
acknowledgment comes after the loop. Capture a burst during actual terminal output,
then a separate quiet burst after the completion fact, retaining their AX labels.
Record the recency label's permitted update across stages; do not demand that
terminal activity publishes while output flows, because option C removes that
claim. No arbitrary delay is a readiness signal. Agent Line cases do not prove provider Session Working,
Monitoring, Idle or Needs you; those require separately granted real-provider
fixtures. For a message-only CLI that has removed work-state flags, do not send
the legacy `drive` states above: use a separately granted real provider phase
from J7, then this driver's `show`/`capture`. A successful message write cannot
stand for provider Working. Name a missing compatible stimulus as UNKNOWN.
For provider phases use the spec's **Observable contract** glyph rows: Working
breathes, Working · monitoring rotates, every other status stays still; Reduce
Motion stills all glyphs. With no actual monitoring stimulus, that row is UNKNOWN.

For shell completion, call the debug CLI's `terminal.wait` with
`{"handle":"<pane-id>","condition":"titleChanged","timeoutSeconds":30,"afterSequence":<saved-sequence>}`.
The bound is the protocol's non-arrival guard, not a speed assertion. Inspect the
result and actual correlated title `verify-<stage>-<correlation>` in current state.
An unrelated event, retirement, refusal or timeout is not completion. Also read
the row/AX state; accepted input or a title event alone does not prove paint.

## Capture and localise

### Chip/text measurement rule — Lead decision, 2026-10-17

For every ten-frame burst, read the **same pane's clock-chip accessibility label**
from both saved AX snapshots. Keep the originals and identify the selected chip;
copy its full label verbatim into `CHIP_LABEL_BEFORE` and `CHIP_LABEL_AFTER`.
Do not substitute the window title, invent a label, or normalize the strings.
A missing or ambiguous chip label leaves this observation UNKNOWN.

1. Equal labels mean no recency repaint occurred inside the burst under the
   adopted rule: the label changes at most once per bucket and never changes back.
   Keep the **whole-chip region**. `chip=still` requires zero changed pixels in
   every consecutive frame pair. A zero union count is equivalent to all pairs
   being zero. `text=still` uses the same label gate. These checks use threshold 0.
2. Different labels make chip and text **repaint-spanned**, neither pass nor fail.
   Record `chip=repaint-spanned`; discard only their pixel verdicts, not the raw
   evidence or glyph verdict. Capture a fresh, uniquely named burst and carry the
   reported `consecutive_repaint_spanned` count into `PRIOR_REPAINT_SPANNED`.
3. After three changed-label bursts in a row, stop: the chip result is **UNKNOWN**
   for that reason. Do not reset the count merely because the phase filename
   changed. A stable-label burst resets it to zero. Keep separate streaks for
   different panes. No automatic app operation or unbounded retry is added.
4. Judge the glyph on **every** burst, including repaint-spanned ones. A glyph
   failure remains a failure even if chip/text are inconclusive. Across stages,
   compare the actual recency labels independently to establish the required
   text update; label stability within a burst never proves cross-stage updating.

Use `--expect chip=still` in every stage because option C withdraws the pulse.
The label gate permits data repaint without weakening the
whole-chip pixel check or masking text pixels. The inputs below are labels read
from the two AX snapshots, not a new command that extracts or alters app state.
Set `PRIOR_REPAINT_SPANNED=0` only for the first burst or after a stable burst.

```bash
/bin/bash "$DRIVER" capture "$DECLARED_BUILD_COMMIT" "$ORACLE_COMMIT" "$RUN" working
uv run --with pillow --with numpy python -I \
  .agents/skills/verify-agentstudio/scripts/frame_diff.py \
  --oracle-commit "$ORACLE_COMMIT" \
  --scope "$ROW_X,$ROW_Y,$ROW_WIDTH,$ROW_HEIGHT" \
  --region "glyph:$GLYPH_X,$GLYPH_Y,$GLYPH_WIDTH,$GLYPH_HEIGHT" \
  --region "chip:$CHIP_X,$CHIP_Y,$CHIP_WIDTH,$CHIP_HEIGHT" \
  --region "text:$TEXT_X,$TEXT_Y,$TEXT_WIDTH,$TEXT_HEIGHT" \
  --expect glyph=moving --expect chip=still --expect text=still \
  --chip-label-before "$CHIP_LABEL_BEFORE" --chip-label-after "$CHIP_LABEL_AFTER" \
  --prior-repaint-spanned "$PRIOR_REPAINT_SPANNED" \
  "$ABSOLUTE_RUN_DIR"/working-frame-*.png
```

`capture` takes AX before/after and ten consecutive original PNGs with the owned
PID. Its `<phase>-target.env` records the supplied oracle, declared build and
receipt's declared build; the pixel report uses the same supplied oracle.
It verifies the process before every frame. Read each capture's success
field; an existing file is not enough. Establish the row bounds and disjoint
regions from the first original **before** evaluating differences. Coordinates
are original PNG pixels, not AX points; exclude the terminal cursor/unrelated
rows. Save coordinates, scenario, sampling span and captures with the observation.

For subsequent scenarios, select the matching burst's own frame paths and labels.
Use `glyph=still` for done, blocked and plain rows, or under Reduce Motion; the
chip remains `still` in every scenario. Repeat stream captures during output and
after quiet with this same rule.

The pixel driver rejects changed dimensions, duplicate paths, fewer than two
frames, overlapping/out-of-scope regions and missing expectations. It reports
pairwise changed pixel counts/bounds, region counts and unassigned change within
the row. Each chip/text record is `checked`, `repaint-spanned` or `UNKNOWN`;
deferred records have `pixel_expectation_met: null`, never true or false. Exit 2
means inconclusive/UNKNOWN if no independent check failed; exit 1 still reports
glyph or unassigned-region failures even while chip/text are deferred. Inspect
the per-region results rather than calling any nonzero status a chip failure.
Unassigned movement leaves localisation unresolved. Chip/text stillness cannot
raise the exact threshold to hide a change.

Inspect original frames in order: breathing changes size/opacity in place;
rotation changes dotted-circle angular phase. A stable-label chip burst must
show no pulse, while recency repaint is handled by the label rule. Text/layout
stillness uses that same gate. Pixel counts cannot establish glyph shape or
cadence. Finite/undersampled frames cannot prove a slow animation
stopped; record inadequate sampling as inconclusive. Verify Agent Line/status,
branch and activity text in AX `label`, `title`, `value`, `description` and the
original screenshot. A detached/unknown worktree branch needs a supplied fixture;
this commission grants no git mutation to create it. A worktree on detached HEAD
must show `repo · detached`, unknown branch data `repo · unknown branch`, and no
fact yet no branch line.

Repeat with monitoring, still statuses, streaming and actual quiet. The chip never
pulses in any of them. Reduce Motion
needs an independently known/read configuration and the same scenarios with
`glyph=still`, `chip=still`, `text=still`, retaining the AX label gate. Reduce Motion
stills the glyph; it is not the cause of chip stillness. This commission grants no global
preference change; request that fixture/read/toggle grant rather than writing
defaults. Still pixels alone do not show that Reduce Motion is enabled.

## Current gaps and cleanup

Return motion/label-gated pixel observations and missing fixtures separately;
apply the skill's shared visual-quality pass. Name denied access only after an
actual attempt. Preserve commands/results and retire only J1's owned app.
