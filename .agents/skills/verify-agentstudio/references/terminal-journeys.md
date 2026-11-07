# J11–J13 — terminal rendering, foreground input and warm reattach

Status: **draft**. Apparatus driven once on main `f74d6accb` (zmx 0.8.1,
Ghostty `2fb0c9c`), debug `c86a`, 2026-11-06. Not yet driven on a vendor
candidate: the new-daemon claim stays open until a declared candidate runs.

Oracle: owner request item 3 (verify new-daemon rendering, foreground input,
reattach rendering) as adopted in the Ghostty/zmx update plan, Workstream V;
for J13 also `TerminalRestoreKind.warm` (a live session reattaches, and zmx
ignores the carried cold-restore script) and session-restore spec SR1/SR10
(cold replay prints the restore marker, which therefore must be absent here).
The pass conditions below are this skill's reading of those outcomes. A
disputed condition goes to the Lead; never loosen it to match a frame.

Driver: `scripts/terminal-journeys.sh` (fixtures, session, daemon, focus,
type, press, warm-link), `scripts/pane-chrome.sh` (PID inventory/capture),
`scripts/window-frame.sh resize` (widths), `scripts/terminal_colors.py`
(colour decision). Every command runs from the repository root on a J1-owned
app; read each `--help` first.

## Why native capture

There is no terminal-output IPC verb, and `window.render` does not reliably
include Metal terminal pixels (`pane-proof-setup.md`, fidelity gaps). Terminal
output is judged from `pane-chrome.sh capture` originals (Peekaboo, exact PID
and native window id, `--no-remote`). The screen must already be unlocked,
with Screen Recording and Accessibility granted to the Peekaboo bridge; a
denial or prompt stops the run. Never change TCC or the transport.

## Shared setup (one owned app, one new pane)

1. J1 `launch` in a new `tmp/verify-agentstudio/<run>/` with the declared
   build, full commit, debug code and an empty watch folder.
2. Create one terminal: `command.execute` `newTab` with
   `{kind:"newTab",workspaceWindowId,launchDirectory:<absolute run dir>}` and
   a fresh UUIDv7 correlation. On main `f74d6accb` this returned
   `outcomeUnknown` (known IPC preparation stall) while the pane was created;
   decide from the `pane.list` readback, never by resending.
3. `terminal.wait attachReady` on the new pane, then
   `terminal-journeys.sh session RUN PANE` (read-only stored session),
   `fixtures RUN`, `daemon RUN before-quit`, and
   `pane-chrome.sh inventory PID EXE LSTART RUN/windows-1.json` for the native
   window id. The pane's cwd is the run dir, so fixtures are `fixtures/<name>`.

## J11 — rendering (plain, 256-colour, truecolor, TUI at three widths)

Stimulus goes through `terminal.send` (J11 judges painting, not input):
`clear; sh fixtures/plain.sh <tag>; sh fixtures/palette256.sh <tag>`, then
`clear; sh fixtures/truecolor.sh <tag>`, then `clear; less -R -S fixtures/tui.txt`.
Await `commandFinished` for the printers, then capture each state once.

| Cell | Pass condition (open the original for every cell) |
| --- | --- |
| Plain | `J11_PLAIN` lines with punctuation and box drawing painted legibly, live prompt below. |
| 256-colour | 6×36 cube plus 24-step gray ramp visible; `terminal_colors.py palette256` → `colourCell: PASS` (≥180 solid colours; a 16-colour fallback stays far below even with chrome). |
| Truecolor | Smooth red/green/blue ramps; `terminal_colors.py truecolor` → PASS (each channel keeps ≥40 of 64 steps; 256-quantised ramps keep ≤6). |
| TUI × widths | `window-frame.sh resize` to content widths 1400, 900 and 560 pt (fresh UUIDv7 each; record the applied `contentSize`), wait the documented 3 s settle, capture. At each width less fills the pane, chopped lines end at the right edge with less's reverse-video `>` marker, the `:` prompt is on the last row, coloured segments (`red green blue orange256 truecolor`) keep their colours, and no stale columns from the previous width remain. |

Quit less with `terminal.send` `q` before J12.

## J12 — foreground keyboard input

Real keyboard events through AppKit, not `terminal.send`. `terminal-journeys.sh
focus RUN WINDOW_ID` must report the owned PID frontmost; `type`/`press`
refuse otherwise and recheck afterwards. Inputs are harmless if misdelivered
only up to the point the guard checks; stop and look if a guard trips.

1. `type RUN WIN 'echo J12_TYPED_<tag> | tee j12-return.txt'`, capture: the
   text echoes at the prompt and `j12-return.txt` does **not** exist yet.
2. `press RUN WIN return`: the output line paints and `j12-return.txt`
   contains `J12_TYPED_<tag>`.
3. `type … 'sh fixtures/interrupt.sh j12-interrupt.txt'`, `press … return`,
   capture `J12_WAITING`; `press RUN WIN ctrl+c`: `^C` and `J12_INTERRUPTED`
   paint, the marker file says `INTERRUPTED`, the prompt returns.
4. `type … 'echo J12_AFTER_<tag> | tee j12-after.txt'` + Return: runs.

## J13 — warm reattach across an app relaunch

1. In the J11/J12 pane print a nonce with colour:
   `printf "J13_BEFORE_<tag> \033[38;2;255;120;0mtruecolor-orange\033[0m \033[48;5;27m 256-blue \033[0m\n"`;
   capture; `daemon RUN pre-quit`.
2. J1 `quit RUN` (owned PID retirement confirmed), then `daemon RUN after-quit`:
   exactly one row (the daemon) survives; the login wrapper and attach client
   are gone.
3. J1 `launch` a **new** run with the same build, commit, code and watch folder.
   `pane.list` must return the same pane id; `terminal.wait attachReady`.
4. `warm-link PREVIOUS_RUN NEW_RUN`: same identity/build/commit, same pane, same
   stored session, and the surviving daemon PID and start time are present
   after relaunch. A different or missing daemon is a cold or recreated
   session: J13 FAIL even if the text looks restored.
5. New `pane-chrome.sh inventory` (the window id changes), capture: the prior
   lines including `J13_BEFORE_<tag>` and its colours re-render (reflowed to
   the restored width is fine); **no** `--- restored after restart ---` marker
   and **no** `Restored after restart` notice.
6. `focus` + `type … "echo J13_AFTER_<tag> | tee <absolute new run>/j13-after.txt"`
   + Return: paints and writes the file.

The relaunched client's argv carries the cold-restore script by design; that
alone is not a failure. J1-quit the relaunched app at the end.

## Evidence and cleanup

Keep `native/*.png` originals, `*.colors.json`, `windows-*.json`, `daemon-*.txt`,
`terminal-session.env`, `warm-link.txt`, the marker files, resize receipts under
`window-frames/`, and every CLI log the drivers write. Quit only through J1.
The debug-root zmx session outlives the app; it is not killed or listed here
(no grant). Record it as left in place with its daemon row.

## Open items

- New-daemon claim: unobserved until a declared candidate (zmx v1.0.0,
  Ghostty v1.4.0) runs J11–J13; this run proves the apparatus on zmx 0.8.1.
- Foreground input relies on Peekaboo `--foreground` after a frontmost check;
  a focus change between check and dispatch is detected only afterwards.
- TUI judgement is visual; `terminal_colors.py` decides colour cells only.
