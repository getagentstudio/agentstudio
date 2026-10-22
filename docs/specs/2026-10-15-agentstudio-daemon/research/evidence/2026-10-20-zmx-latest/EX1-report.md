# EX1 — viewerless interactive-shell establishment at zmx main 0a18bee

## Answer

**source:** Yes. A non-TTY process can establish a continuing interactive login shell, leave zero clients, generate output/state through `zmx send`, and later attach a real PTY client that receives the detached marker, current title and cwd, takes leadership, and resizes the existing shell. The cleanest observed CLI path was **`zmx attach s4 /bin/zsh -i -l` with stdin immediately at EOF and stdout/stderr captured**: it created zsh directly, then exited before flushing `Init`, leaving no terminal client or leader. Holding the input pipe open and explicitly detaching also worked, but temporarily registered the Host as a terminal client. `run s1 -d /bin/zsh -i -l` worked with a continuing **nested zsh inside task-mode bash**, with task tracking and temporary leadership side effects. These are observed mechanisms, not a recommendation to make EOF timing a public Host contract. Evidence: [commands.log](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/commands.log), [commands-extra.log](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/commands-extra.log), [observations.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/observations.txt).

## Scope and provenance

- **source:** Source HEAD is `0a18bee7d3555b7822d1cb79cca2304d6ef2711b`; every decisive source file was byte-compared to that commit's blob. [provenance.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/provenance.txt).
- **source:** Executed only the supplied `install/bin/zmx`, SHA-256 `9e4bb4b3d29c790c24b56eddaab8b6087e759999ae2d0cfe5f584a0d8886f5da`. It prints version **0.8.1**, which is also the version still in main's `build.zig.zon:3`; that string cannot distinguish main from the vendored release. Build provenance is supplied by EX0; this experiment did not rebuild it. Matching main behavior was observed, including first-attach snapshots without any preceding `Init`.
- **source:** Every invocation had `ZMX_DIR=/Users/shravansunder/code/projects/agentstudio.feat-daemon/tmp/ex/z`; initial/final lists were empty. No network or production session was used. HOME/ZDOTDIR were isolated under `ex1/home`; zsh startup set only a simple prompt. This checks `/bin/zsh -i -l` without the owner's personal rc files.
- **source:** The initial sandboxed attempt created and killed s1, then failed executing `ps`: `PermissionError: [Errno 1] Operation not permitted: 'ps'`. Host escalation succeeded; both complete drivers exited **0**. PTY creation and Unix sockets worked. [first-attempt.log](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/first-attempt.log), [exception.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/exception.txt) retain that earlier failure, not the final result.

## Procedure and commands

The pre-run deciding observations are in [protocol.md](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/protocol.md). Driver source and exact argv, shell commands, exit codes and trimmed outputs are retained in [viewerless_probe.py](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/viewerless_probe.py), [eof_attach_probe.py](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/eof_attach_probe.py), and the two command logs. The scripts are single-run experiment artifacts; their completion-file names must be made fresh before rerunning.

```sh
# Applied to EVERY command below, including cleanup:
export ZMX_DIR=/Users/shravansunder/code/projects/agentstudio.feat-daemon/tmp/ex/z
ZMX=/Users/shravansunder/code/projects/agentstudio.feat-daemon/tmp/experiments/2026-10-20-zmx-latest/install/bin/zmx

# A: session name precedes -d (the packet's run -d <S> ordering is not the CLI syntax).
"$ZMX" run s1 -d /bin/zsh -i -l

# B: Python Popen, stdin=PIPE, stdout/stderr=files; pipe kept open.
"$ZMX" attach s2 /bin/zsh -i -l
# Send a bootstrap command, await its completion file, then write byte 0x1c to detach.

# C: third ensureSession CLI path. The driver pipes this exact content:
# b'EX1_WRITE_CONTROL\n'
"$ZMX" write s3 /Users/shravansunder/code/projects/agentstudio.feat-daemon/tmp/experiments/2026-10-20-zmx-latest/ex1/s3-written.txt
"$ZMX" send s3 $'exec /bin/zsh -i -l\r'

# D: same attach entry, immediately closed stdin pipe; output captured to files.
"$ZMX" attach s4 /bin/zsh -i -l < /dev/null
```

**source:** D was actually invoked with Python `subprocess.run(..., input=b'')`, an already-EOF pipe rather than `/dev/null`. The distinction is retained because the source branches on observed EOF. Its output was exactly:

```text
session "s4" created\n
\x1b[2J\x1b[H\x1bc\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\
```

For each session the driver then used `send` to export `EX1_STATE`, change to `ex1/cwd`, print OSC 0 then OSC 2 titles, announce cwd with OSC 7, enter/exit alternate screen, and print a unique marker. Shell PID, PPID, `$-`, tty, `stty size`, cwd and state were recorded to a file and echoed to the PTY. A completion file correlated the detached operation. `list` reported `clients=0` after creation and detached generation. This count excludes the querying Info connection; it is corroborated by daemon disconnect logs.

The Python driver used `pty.openpty`, `TIOCSWINSZ` and subprocess stdio bound to the slave. First attach: **120 columns × 40 rows**; second attach: **100 × 30**. It captured initial bytes **before sending any shell input**, queried leadership via tracked `EX1_VIEW`, then sent shell evidence commands and detached with `0x1c`. Between attaches, a second detached generation changed title/state and marker. Fixed capture windows only bounded acquisition; positive bytes and shell completion/state are the result, not elapsed-time assertions.

## Results by mechanism

**source:** All four mechanisms passed the same two-attach observation. `$-` was `569XZilms` in every shell phase, including `i` and `l`. The same zsh PID survived both detached periods and attaches. Sizes in `stty`'s **rows columns** order were `24 120` initially, `40 120` after attach 1, still `40 120` detached, and `30 100` after attach 2. [observations.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/observations.txt) contains every phase's raw shell evidence.

| Mechanism | Daemon PID | Interactive zsh PID / PGID | Establishment-specific observation |
|---|---:|---:|---|
| A — `run s1 -d /bin/zsh -i -l` | 89145 | 89148 / 89148 | Outer `-bash` PID/PGID 89146; `list` reports **that bash PID**, not nested zsh. `run` client briefly became leader via Resize, then disconnected. |
| B — piped `attach`, explicit detach | 89199 | 89200 / 89200 | Direct zsh. Host registered via Init and became leader at 120×24; `print-env` returned `EX1_VIEW=NON_TTY_HOST`. Detach cleared leadership. |
| C — `write`, then `send exec zsh` | 89247 | 89248 / 89248 | Task-mode bash replaced by zsh using exec. Created `s3-written.txt` and echoed the base64 file-write command. No leader before real attach. |
| D — `attach`, immediate EOF | 89625 | 89626 / 89626 | Direct zsh, no Init/leader before real attach; no task wrapper or injected task command. Ephemeral socket connection still existed during establishment. |

**source:** For every session/attach, the initial captured stream contained a standalone detached marker line, **actual OSC 2 title bytes**, and **actual OSC 7 cwd bytes**. Eight of eight snapshots contained all three. The current title was the final OSC 2 value; earlier OSC 0 was superseded. The live environment/cwd were also read back from the same shell after each attach. Both earlier and later detached output remained in the terminal history/snapshot.

| Session | Initial bytes, attach 1 | Initial bytes, attach 2 | Marker / title / cwd, both attaches |
|---|---:|---:|---|
| s1 | 1586 | 3746 | present / present / present |
| s2 | 2293 | 4453 | present / present / present |
| s3 | 1981 | 4141 | present / present / present |
| s4 | 1483 | 3641 | present / present / present |

Example byte fragment from `s4-attach1-initial.bin` (escaped, trimmed):

```text
\r\nEX1_MARKER_s4_detached1\r\n
EX1_PHASE=detached1 PID=89626 PPID=89625 FLAGS=569XZilms STATE=STATE_s4_detached1 ...
...\x1b]7;file://localhost/.../ex1/cwd\x1b\\
\x1b]2;EX1_TITLE_s4_detached1\x07
```

**source:** Alternate-screen enter/exit did not leak an actual `ESC[?1049h` into any attach snapshot. The transient alternate display was gone; the primary marker remained. The echoed *command text* includes the literal `EX1_ALT...` and textual escape spelling, so mere substring searches for `ALT` would produce a false claim of replay. This experiment proves return to primary state, not preservation of an exited alternate screen.

**source:** Before shell input, `print-env` returned `EX1_VIEW=PTY_sN_1` or `PTY_sN_2` in all eight real attaches. Corresponding daemon logs show `setting new leader`, `init resize rows=40 cols=120` or `rows=30 cols=100`, then `unsetting leader` at detach. This corroborates leadership and size beyond just shell input triggering a later takeover. Full logs: `ex1/sN-daemon.log`; raw bytes: `ex1/sN-attachN-initial.bin` and `*-command.bin`. Reattach correctly repeated this sequence.

## Source explanation at 0a18bee

All following source anchors refer to the read-only clone at the pinned commit; numbered excerpts are retained in [source-anchors.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/source-anchors.txt).

1. **source — session creation and shell selection.** `src/main.zig:157–200` constructs an ordinary attach daemon with explicit command argv; `:201–235` sets `is_task_mode=true` for run. `:452–487` does the same for write. The only three `ensureSession` callers are attach (`:1614`), write (`:1712`) and run (`:1867`); no separate create-only CLI was found. `src/loop.zig:715–773` creates/reuses the socket/session, then `src/daemonize.zig:16–40` chooses explicit command argv first; otherwise task mode forces **bash**, while normal attach uses the configured shell with login argv[0]. A thus executes the requested zsh **as a command inside bash**, rather than selecting it as the daemon's initial shell.
2. **source — detached run is task submission, not a shell constructor.** `src/main.zig:1935–1946` sends Resize then Run; `src/loop.zig:1053–1063` lets Resize claim an empty leadership slot even without Init. `src/loop.zig:1187–1220` resets task tracking and appends `; echo ZMX_TASK_COMPLETED:<id>:$?`. `src/main.zig:765–772` makes `-d` return on Ack. With a nested continuing interactive shell that marker waits for its exit; the outer bash and task semantics remain. `send` instead queues raw input without claiming leadership (`src/loop.zig:931–934`).
3. **source — non-TTY attach still normally acts as a terminal client.** `src/main.zig:1637–1675` guards termios operations by `tcgetattr` success, but still writes clear/reset escape sequences to stdout. `src/loop.zig:43–50` queues EnvSet and Init regardless of TTY status. `:116–140` checks stdin first and returns immediately on EOF; buffered socket writes happen later at `:193–206`. This explains D: immediate EOF returns before Init is flushed. B's open pipe allowed Init and a real terminal-client lifecycle. The creation step precedes either behavior (`src/main.zig:1614`). D is a composition of these existing branches, not a named detached-create interface.
4. **source — state is in the daemon VT, not the client's write buffer.** `src/loop.zig:360–377` feeds every shell output chunk into the VT and updates cwd even without terminal clients. Without an Init client it also answers device-attribute queries. `:979–983` clears **only the newly initializing client's queued output**, then marks it terminal. `:1000–1021` always serializes when `has_pty_output`; it does not require an earlier viewer. Therefore c0d157e does **not** discard the accumulated VT state.
5. **source — what the real client gets.** `src/loop.zig:985–998` assigns the first available leader and resizes the emulator before serialization; `:1024–1040` resizes the PTY and sends WINCH to its foreground process group when output exists. `src/util.zig:795–905` serializes current screen/history, appends cwd OSC 7 (`:890` / helper `:767`) and title OSC 2 (`:892–900`). This reconstructs current terminal state; it is not a raw output-event replay. `src/loop.zig:684–700` clears leadership on disconnect, leaving the daemon alive for ordinary detach.
6. **source — other attach side effects.** A persistent attach client supplies tracked environment state; `src/loop.zig:1333–1336` reads it from the leader. Source also emits focus-in/out when the last terminal client appears/disappears if focus reporting is enabled (`:260–268`). Focus-report behavior was read, not exercised. Non-TTY size discovery falls through the available descriptors and `/dev/tty`, then defaults to **120×24** (`src/ipc.zig:79–101`); these runs observed that default.
7. **source — write is not a neutral establishment mechanism.** `src/loop.zig:1284–1325` injects `printf | base64 -d > path` through shell input. It changes a file and pollutes terminal history; C needed another `send exec` to obtain the user shell. Its task-mode creation follows the same bash default as run.

## What changed since the 0.8.1 reading?

**source:** The two central earlier claims remain true: run forces task-mode bash for a new default session (`vendor/zmx/src/main.zig:223`, `vendor/zmx/src/daemonize.zig:30`), and an attach client that sends Init claims available leadership and resizes (`vendor/zmx/src/loop.zig:950–1029`). Non-TTY termios guarding was also already present (`vendor/zmx/src/main.zig:1603–1618`). Main does not turn run into a user-shell establishment API.

**history:** The important change is `c0d157e525b36872b46889adb05375925b6eb30a`: its diff removes `has_had_client`, clears pre-Init queued output, and changes the restore condition from `has_pty_output && has_had_client` to **`has_pty_output`**. Its stated rationale is avoiding duplicate startup output/already-answered terminal queries while allowing a snapshot on every Init. The current implementation and first-viewer experiment independently support that effect. At vendored 0.8.1 (`src/loop.zig:976–981`), a first viewer after viewerless run would not take that snapshot path; that old binary was **not executed** in EX1. Title and cwd serialization already existed there (`vendor/zmx/src/util.zig:867–879`); their mere presence was insufficient when first-attach serialization was gated off.

## What this means for the Host establishment port

**inference:** Independent execution and delayed viewing are technically feasible on the supplied main build. The port should distinguish establishing the daemon's PTY child from registering a viewing client. Ordinary piped attach can establish the correct user shell directly, but temporarily takes terminal leadership, size and tracked-environment responsibility; run creates a task shell and can report a PID different from the interactive user's shell. Immediate-EOF attach demonstrated direct user-shell establishment without Init, and main now restores output created before the first viewer. That is evidence against “a Ghostty viewer is intrinsically required,” not yet a durable API promise. A Host implementation consuming this path must explicitly own its launch environment, initial size/readiness check and client shutdown semantics; a dedicated upstream establishment operation or adoption of the EOF behavior is a design decision for the commissioner, not made here.

## Residual uncertainty and cleanup

- **gaps:** Build-to-source provenance was supplied by EX0; the binary was hashed and its behavior checked, not independently rebuilt. A reproduced build at the pinned commit would close that provenance layer.
- **gaps:** Tested one local macOS binary, controlled zsh startup, one client at a time, two attaches per mechanism. Personal startup hooks, other user shells, SSH/Linux, simultaneous viewers, failures during establishment, durable recovery and full-screen applications left active are untested; corresponding real-target probes would settle them.
- **gaps:** D was observed once and explained by the immediate-EOF branch before the Init flush. This does not guarantee arbitrary pipe-close timing or future-version compatibility. A documented upstream contract or broader entry-path probe would settle whether a Host may rely on it.
- **gaps:** `cd` changes shell state; daemon/client cwd discovery additionally requires OSC 7 or shell integration. EX1 emitted OSC 7 explicitly, so it does not prove automatic cwd discovery for shells that emit none.
- **source:** Both successful driver runs exited 0; all eight PTY clients detached with exit 0. All named sessions were killed using the isolated `ZMX_DIR`. Final list returned no sessions. Final `ps` checks found **no recorded PID survivors and no process whose command starts with the exact experiment binary**; this also covers the aborted initial creation. [final.ps](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/final.ps), [extra-final.ps](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/extra-final.ps), [cleanup-verification.txt](../../../../../../tmp/experiments/2026-10-20-zmx-latest/ex1/cleanup-verification.txt).
- **source:** No product code was changed. Only assigned experiment paths were written. No board posts. `no-home`: no supplied work thread and Router discovery outside the command grant. Trace gap: no authorized session-logs destination supplied; this report/protocol hand back scoped evidence for the commissioner's trace.

Checkpoint: EX1's bounded runtime/source question is answered; no experiment daemon remains. Commissioner action: use the distinction between task submission, ordinary Init attach, and immediate-EOF establishment in the daemon review; no product design decision was taken by this researcher.
