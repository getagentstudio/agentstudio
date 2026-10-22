# J3 — lose one owned terminal session, then observe cold replay

Require a Lead-declared prepared restore build and explicit permission for this
one-session fault. The driver takes the full build commit as an input, requires
the matching J1 launch receipt, and checks `VERIFY_RESTORE_RUN_AUTHORIZED=1`.
The selector does not grant permission; do not substitute or build a target.

Oracle: `docs/specs/2026-09-28-session-restore/2026-09-28-session-restore-specification.md`,
**revision 11**, SR3, SR5, SR6a and SR7–SR10, together with **Program Design
revision 28**, item 2 (the cold command). SR10 requires replay → marker → shell;
Program Design 28 places the restore notice **before** that sequence. The
declared build's `ZmxBackend.coldRestoreScript`/`folderFallbackLines` must therefore
select the folder and print the notice, replay the saved bytes, print
`--- restored after restart ---`, then hand off to the login shell. Recheck these
symbols in that build; unqualified line ranges from an older build are not anchors.

Find that build's stored session-id codec (the current owner is
`Core/State/MainActor/Persistence/WorkspaceCoreRepository+PaneGraphCodecs.swift`)
and snapshot writer/reader. Confirm the `pane_content_terminal.zmx_session_id`
mapping and `<data root>/scrollback/<lowercase pane id>.vt` path before using the
driver. A missing SR7–SR10 implementation is a specific build prerequisite gap,
not permission to borrow another pin. This saved-scrollback journey uses a fresh
pane with no agent binding: R3's SR11–SR14 auto-resume cases require their own
declared fixtures; they do not replace the J3 nonce/replay proof.

## Prepare saved output and identify one owned session

1. Receive the build path/commit/configuration, then launch through J1 in a new
   run directory. Check isolated identity, background launch and CLI health.
2. Create a disposable new terminal after J1's baseline pane readback. Keep its
   pane id; do not reuse earlier persisted debug terminal processes.
3. Through `terminal.send`, print two distinct short nonce lines, e.g.
   `VERIFY_RESTORE_<run-tag>_A` then `VERIFY_RESTORE_<run-tag>_B`, followed by a
   correlated OSC title acknowledgment. Use a fresh UUIDv7 and the typed
   `titleChanged` wait/readback from J2. Capture the actual two lines and title
   by the owned PID. Fit them and the expected marker/notice/prompt in the viewport.
   An accepted send receipt is not saved output. Use no private content.
4. Normal quit is the adopted snapshot trigger. Do not sleep five minutes or
   add a debug-only capture hook. Before quit, record the **stored**, opaque zmx
   session id for the new pane, never a derivation from its pane id:

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh select "$DECLARED_BUILD_COMMIT" "$RUN" "$PANE_ID"
```

The read-only SQL is
`SELECT zmx_session_id FROM pane_content_terminal WHERE upper(pane_id)=upper('<validated UUID>');`
against the launch state's debug `local.sqlite`. The driver rejects a pane in
J1's baseline, an ambiguous result or a non-UUID new session. This records the
selection; it lists/kills nothing.

## Quit, then pin the zmx namespace

Quit and confirm retirement through J1. If retirement is unobservable, leave the
session intact. The kill driver requires a nonempty snapshot at
`~/.agentstudio-db/<code>/scrollback/<lowercase-pane-id>.vt`. That metadata check
does not prove its contents; only replay of the exact nonce after restart does.
Do not read/copy arbitrary snapshot contents without a grant.

**Every zmx call must set `ZMX_DIR` from this owned launch's state file.** A debug
executable run without it uses the default root containing the owner's production
sessions (Lead-confirmed hazard, 2026-10-17). The path of the executable is not
isolation. The underlying route is:

```bash
ZMX_DIR="$AGENTSTUDIO_OBSERVABILITY_ZMX_DIR" "$DEBUG_DATA_ROOT/bin/zmx" list
ZMX_DIR="$AGENTSTUDIO_OBSERVABILITY_ZMX_DIR" "$DEBUG_DATA_ROOT/bin/zmx" kill "$EXACT_LISTED_SESSION"
```

Use the guarded steps, not an unowned/stale handoff:

```bash
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh list "$DECLARED_BUILD_COMMIT" "$RUN"
/bin/bash .agents/skills/verify-agentstudio/scripts/cold-restore.sh kill "$DECLARED_BUILD_COMMIT" "$RUN"
```

The driver checks the ownership receipt against current
`tmp/debug-observability/latest-observability.env`, proves that app retired,
requires the state-derived namespace to equal `~/.agentstudio-db/<code>/z`, rejects
symlink escapes and invokes only that data root's `bin/zmx`. A fresh successful
listing must contain the exact selected session; parsing accepts `name=`,
`session_name=` or short names, like `ZmxBackend.extractSessionName`. No glob,
prefix, default-root call, kill-all, signal or deletion. Listing can prune stale
sockets, so it belongs after app retirement, never a periodic probe or during
session startup. Failed/incomplete listing is unknown, not session absence.

`kill` records its one attempt and never retries it. Preserve its command/status
and the subsequent successful **same-root** list showing the exact session absent.
A kill receipt alone is not the absence observation. If reconciliation is needed,
leave the evidence and return to the Lead; do not repeat the fault automatically.

## Relaunch the same build and judge the visible result

Use a new J1 run directory, the same restore build and the same watch folder.
Do not create a replacement pane. Check `pane.list` returns the original pane id;
retain its stored session id. Capture the newly owned app PID and AX tree, then
inspect that terminal's order:

1. `Restored after restart` notice and justified folder-fallback reason, if any;
2. exact saved nonce lines, in their original order;
3. visible `--- restored after restart ---` marker;
4. fresh login shell in the saved folder.

Send a new distinct input through the same pane, await/read its correlated title
and capture new visible output. That establishes usable fresh-shell behavior.
SR5 requires a visible reason if the shell cannot start; no silent empty pane or
retry loop. `no saved output` is legitimate in the separate unusable-snapshot
case, but does not pass this saved-scrollback case. A warm reattach, row count or
successful IPC acknowledgment proves none of the restart order.

Report saved output, app retirement, exact-session absence, same pane identity,
replay/marker/notice order and fresh input separately. If text is offscreen,
request a scoped scroll/output-read route; `zmx history` is not granted.
J1 retires only the relaunched app. Do not
retire the pane or delete its snapshot to clean up persistence evidence.
