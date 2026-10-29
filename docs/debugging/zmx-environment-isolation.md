# zmx Environment Isolation — Debugging Notes

> **PARTIALLY SUPERSEDED.** Environment/root-isolation observations remain
> debugging evidence. Any startup identity reconciliation, stored-anchor
> hydration/adoption, fallback, or boot persistence described below is obsolete;
> see [Session Lifecycle Architecture](../architecture/runtime/session_lifecycle.md).

Active investigation into how `ZMX_DIR` / `ZMX_SESSION` env vars leak between Agent Studio instances and out into user process trees, and whether scrubbing them at the AS-boot boundary is safe. This doc captures what we know, what we tried, and what remains unexplained.

## TL;DR

- zmx isolates **daemons from each other** through `setsid` and per-session sockets, but its trust boundary is **the socket directory** — anyone who can write there can `zmx kill` any daemon in it.
- Agent Studio (AS) sets `ZMX_DIR` and `ZMX_SESSION=""` per Ghostty surface, but **does not scrub these from its own process env**. They leak from outer AS → ghostty surface env → zmx daemon's `execChild` → user shell → claude/bash → nested AS.
- Observed bug: launching nested debug AS from inside outer release AS (via `claude → bash → .build/debug/AgentStudio`) kills every outer zmx daemon **except** the one hosting the launch chain. Signature consistent with serial external killing where the killer dies on self-kill.
- Tried fix (Option C): `unsetenv("ZMX_DIR")` and `unsetenv("ZMX_SESSION")` at top of `Sources/AgentStudio/main.swift`. **Crashes new-pane creation in debug AS reproducibly**, even when launched from plain Ghostty.app where the unsetenv calls should be no-ops. Cause unresolved as of last session.

## Background — zmx system architecture

```
  AgentStudio process
    └── Ghostty surface (forkpty)
         └── shell command: `<zmx> attach <id> <user-shell> -i -l`
              └── zmx attach CLI (the client)
                   ├── fork → daemon (setsid, reparented to init)
                   │    └── forkpty → user-shell (claude, bash, etc.)
                   └── stays as the first client (drives the PTY from outside)
```

Per session: one daemon process, one Unix-domain socket under `ZMX_DIR`, one PTY pair, independent log file. **No cross-daemon coupling** in zmx code itself — different sessions never talk to each other.

### Env vars zmx reads

| Var | Read at | Used by |
|---|---|---|
| `ZMX_DIR` | `Cfg.socketDir` (vendor/zmx/src/main.zig:285) | every subcommand via `cfg.socket_dir` |
| `ZMX_SESSION` | `socket.getSeshNameFromEnv` (vendor/zmx/src/socket.zig:9) | attach guard, history fallback |
| `ZMX_SESSION` | `getEnvVarOwned` (main.zig:961, 998) | list current marker, detachAll |
| `ZMX_SESSION_PREFIX` | `socket.getSeshPrefix` (vendor/zmx/src/socket.zig:5) | every subcommand that takes a session-name arg, plus selector for `kill`/`wait` with no args |

### `Cfg.socketDir` resolution priority

vendor/zmx/src/main.zig:281-294

```zig
1. ZMX_DIR             →  $ZMX_DIR
2. else XDG_RUNTIME_DIR →  $XDG_RUNTIME_DIR/zmx
3. else                →  $TMPDIR/zmx-$UID         (default /tmp/zmx-$UID)
```

The captured value lives in `cfg.socket_dir` for the lifetime of the process. The daemon never re-reads `ZMX_DIR` after init.

### Attach nested-guard

vendor/zmx/src/main.zig:1136-1140

```zig
fn attach(daemon: *Daemon) !void {
    const sesh = socket.getSeshNameFromEnv();
    if (sesh.len > 0) return error.CannotAttachToSessionInSession;
    ...
}
```

`getSeshNameFromEnv` returns `""` for both unset and explicitly-empty `ZMX_SESSION` — so `ZMX_SESSION=""` is equivalent to "not in a session" and passes the guard.

### Daemon's execChild — the leak point

vendor/zmx/src/main.zig:378-420

The daemon's `execChild` injects `ZMX_SESSION=<name>` via `putenv` and then `execvpeZ`s the user's shell with `std.c.environ` wholesale. **`ZMX_DIR` is not touched** — whatever was inherited at fork time is passed straight through to the user shell, claude, bash, and any nested process they spawn.

## Agent Studio's zmx integration

```
  Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift
    ▸ executeWithRetry (line 366-409)
        every `zmx list` / `zmx kill` call passes
        environment: ["ZMX_DIR": zmxDir]   ← explicit override
    ▸ buildAttachCommand (line 247-256)
        builds `<zmx> attach <id> <shell> -i -l` as a string
        relies on Ghostty surface env_vars for ZMX_DIR

  Sources/AgentStudio/App/Coordination/PaneCoordinator+ViewLifecycle.swift
    ▸ createView (line 178-187)         | sets surface env_vars:
    ▸ createFloatingTerminalView (307-311) |   ZMX_DIR     = sessionConfig.zmxDir
                                            |   ZMX_SESSION = ""

  Sources/AgentStudio/Infrastructure/AppDataPaths.swift:46
    zmxDirectory(env, isDebugBuild) = rootDirectory/z
      where rootDirectory =
        $AGENTSTUDIO_DATA_DIR              (override)
        else if #if DEBUG → ~/.agentstudio-db
        else              → ~/.agentstudio
```

**AS code never reads `ZMX_DIR` from `ProcessInfo.processInfo.environment`** in production paths. The dir is computed from build flavor + optional `AGENTSTUDIO_DATA_DIR` override.

### Ghostty env_override semantics (claimed override-wins, see open question)

```
  vendor/ghostty/src/Surface.zig:623-638
    var env = rt_surface.defaultTermioEnv()       // getEnvMap of AS process
    ...
    .env = env,
    .env_override = config.env,                    // surface env_vars from C API

  vendor/ghostty/src/termio/Exec.zig:807-814
    var it = cfg.env_override.iterator();
    while (it.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
```

Reads as override-wins. **But Option C's empirical crash contradicts this** — see Open Questions.

## Current launcher rule — bundle first, marked debug fallback

`mise run run-debug-observability` builds a signed per-worktree bundle named
`Agent Studio Debug <code>.app`, where `<code>` is a deterministic
four-character base36 hash of the canonical worktree path. The generated bundle,
logs, traces, and zmx root live under `~/.agentstudio-db/<code>` instead of the
repo checkout. That matters for autonomy: if the checkout is under
`~/Documents`, putting the runnable `.app` under repo `tmp/` can make macOS TCC
ask the generated debug app for Documents access before the test has even
created its own fixture workspace.

The launcher first invokes LaunchServices `open` from a minimal allowlisted
environment:

```text
HOME
USER
LOGNAME
SHELL
TMPDIR
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

The candidate app receives only the explicit trace variables and, for debug,
`AGENTSTUDIO_DATA_DIR`. In the LaunchServices path these are passed with
`open --env`; in the direct debug fallback they are passed through an equivalent
allowlisted process environment. Inherited AgentStudio/zmx/Ghostty identity
variables are not forwarded.

Effective debug identity:

```text
bundle id   com.agentstudio.app.debug
app name    Agent Studio Debug <code>
data root   ~/.agentstudio-db/<code>
zmx dir     ~/.agentstudio-db/<code>/z
URL scheme  none
```

The debug observability bundle removes URL-handler registration entirely so it
cannot claim stable production `agentstudio://` callbacks or deep links. Debug
isolation comes from bundle id, bundle name, data root, and zmx root.

The short code is intentionally four characters because zmx session names and
Unix socket paths are length-sensitive. The code is not a pane/session id; it is
only a debug worktree discriminator. Pane zmx identities still need enough
entropy for durable uniqueness. A future compact zmx naming pass should preserve
the current entropy budget while using a denser alphabet.

`mise run run-beta-observability` keeps the normal beta identity
(`Agent Studio Beta`, `com.agentstudio.app.beta`, `~/.agent-studio-b`) but uses
the same clean launch environment. Local beta bundles, launcher logs, and trace
files default to `~/.agentstudio-db/beta-observability/`; the repo keeps only
the small state file used by `verify-beta-observability`. Both helpers require
a healthy local collector and should be the only supported way to collect
Victoria-stack proof from debug or beta builds. For PR-branch proof, prefer the
isolated debug runner. For beta promotion proof, use the accepted/notarized beta
artifact produced by the GitHub release workflow.

The helpers are executed with `/bin/bash`, not Homebrew bash. Launches try
LaunchServices `open` first so macOS sees a real app bundle and WindowServer
creates an inspectable GUI process. If LaunchServices rejects the generated
debug bundle, the debug launcher may fall back to direct
`Contents/MacOS/AgentStudio` execution and records
`AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable` in
`tmp/debug-observability/latest-observability.env`. That fallback is valid for
Victoria/OTLP debug proof because it keeps the same isolated data root,
`ZMX_DIR`, and trace configuration. It is not full GUI proof.

Beta is stricter. If LaunchServices returns an error such as `-10810` for beta,
the helper writes `AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed` and exits
non-zero; beta promotion proof must use an accepted/notarized beta bundle. A
Developer ID signed local bundle that has not been notarized can still be
rejected by Gatekeeper and is not the promotion proof path.

The helpers invoke `open` from a minimal clean environment and pass only the
candidate app's trace/data variables through `open --env`; inherited
AgentStudio, Ghostty, and zmx identity variables are not forwarded. Local
ad-hoc beta bundles may be AMFI/LaunchServices-rejected; Developer ID signed
local bundles can still be rejected until notarized. Developer ID signing is
opt-in for local diagnostic bundles via
`SIGNING_IDENTITY=... mise run create-beta-app-bundle`. Use the isolated debug
runner for branch proof and the GitHub workflow's notarized beta artifact for
promotion proof.

Both helpers refuse duplicate same-identity launches. Debug refuses if any
process with this worktree's debug code and executable path is
already alive, even if `AGENTSTUDIO_DEBUG_ARTIFACT_DIR` points outside the
default artifact root. Beta refuses if any beta-channel AgentStudio process is
already running, even from a different bundle path. This keeps proof runs from
sharing SQLite and zmx roots through accidental duplicate app instances.

## The original bug — nested AS blast radius

Setup:
- Outer AS = `/Applications/AgentStudio.app` (release, `~/.agentstudio/z`)
- Inner AS = raw `.build/debug/AgentStudio` from a worktree
- Inside an outer AS pane, claude is running. User asks claude to launch the debug binary.

Result:
- Inner AS boots successfully.
- **Every outer zmx daemon dies, except the one hosting the claude→bash→inner-AS chain.**
- Outer AS AppKit process stays alive, but its panes show "Process Exited".

Signature analysis:
- "All but one die" + "the survivor is the one whose destruction would destroy the killer" → **serial external killing**. Whatever process is iterating outer's daemons sits inside the surviving daemon's PTY tree. When the loop reaches that daemon, killing it SIGHUPs the killer mid-iteration.
- Daemons cannot do this to each other — they're independent processes in different sessions.

What we ruled out by code audit:
- Current AS startup reconciliation (`AppDelegate.reconcileZmxSessionAnchorsAtStartup`) is non-destructive and uses a typed, discovery-only zmx inventory boundary. It can hydrate/adopt missing stored anchors and report unmatched live sessions, but it does not call `zmx kill`.
- No `pkill`, `killall`, or PG-wide signal in AS source.
- No code path in AS reads `ZMX_DIR` from `ProcessInfo.processInfo.environment`.
- Bundle id collision (both Info.plist = `com.agentstudio.app`) — AS lifecycle hooks don't kill daemons on terminate.

What remains as the likely mechanism:
- Some process in inner's tree that runs `zmx kill` (with no args) + `ZMX_SESSION_PREFIX` set, OR
- A process that runs `zmx list | xargs zmx kill`-style logic, OR
- libghostty internals doing something we haven't audited.

The leak that enables this: **outer's `ZMX_DIR` is inherited all the way down the process tree** because zmx's `execChild` doesn't scrub it. So any zmx subcommand inner's tree happens to invoke without an explicit `ZMX_DIR` override defaults to outer's directory.

## Behavior matrix — outer × inner × env

```
  Variables that determine the inner pane's child-shell ZMX state:

  O = outer launch context (env that inner AS inherits)
  C = Option C state (applied / reverted)
  S = surface env_override AS sends to Ghostty (always: ZMX_DIR=debug-z, ZMX_SESSION="")

                                            child-shell after merge
                                            (per override-wins model)
  ─────────────────────────────────────────────────────────────────
  1. Terminal.app, no ZMX_*           any C  ZMX_DIR=debug-z, SESSION=""  ✓ valid
  2. Ghostty.app, plain shell         any C  ZMX_DIR=debug-z, SESSION=""  ✓ valid
  3. Ghostty.app inside zmx session   any C  ZMX_DIR=debug-z, SESSION=""  ✓ valid
                                              (override-wins clears outer)
  4. Inside outer AS pane             any C  ZMX_DIR=debug-z, SESSION=""  ✓ valid

  Per the model, all eight cells should produce identical child-shell env.
  Empirically, case 2 with Option C applied crashes new-pane creation.
  This contradiction is unresolved.
```

## ZMX_SESSION — empty vs unset distinction

Two reader patterns in zmx source treat empty and unset differently:

| Reader | Unset | Empty `""` | Set value |
|---|---|---|---|
| `socket.getSeshNameFromEnv` (`getenv orelse ""`) | `""` | `""` | the value |
| `getEnvVarOwned` | `error.EnvironmentVariableNotFound` | `""` | the value |

Implications:

| Caller | Unset | Empty | Set |
|---|---|---|---|
| `attach` guard (main.zig:1137) | passes | passes | errors |
| `history` fallback (main.zig:90) | "no fallback" | "no fallback" | uses value |
| `list` current-marker (main.zig:961) | no marker | empty marker, no match | arrow |
| `detachAll` (main.zig:998) | error "not in session" | proceeds with `""` → fails | detaches |

So `ZMX_SESSION=""` is **safe for attach** (guard-equivalent to unset) but **distinguishable from unset** by `detachAll` and `list`.

## Cross-daemon impact mechanisms

zmx daemons are independent. Anything that takes them down comes from outside zmx's own code.

```
  Vector              Per-daemon vs cohort?      Fits "all-but-killer" pattern?
  ────────────────────────────────────────────────────────────────────────────
  1. SIGNAL (kill PID)   per-daemon              only if iterated; killer self-kills last
  2. IPC Kill via socket per-socket              same — iterated, killer self-kills last
  3. PTY shell death     per-daemon              no, siblings unaffected
  4. unlink socket       per-socket              cosmetic (existing fd OK), no kill
  5. disk pressure       cohort                  simultaneous, no "killer survives last"
  6. OS resource limit   cohort                  simultaneous, ditto

  Vectors 1 and 2 are the only ones consistent with the observed signature.
```

`zmx kill` with no args + `ZMX_SESSION_PREFIX` set is a single CLI invocation that walks the cohort serially via IPC — exact match for the signature.

## Proposed defenses

### Option A — vendor zmx patch (`execChild` scrubs `ZMX_DIR`)

vendor/zmx/src/main.zig in `execChild`, after the existing `putenv("ZMX_SESSION=...")`:

```zig
_ = cross.c.unsetenv("ZMX_DIR");
```

**Closes**: daemon → user shell link. The user shell and everything below (claude, bash, nested AS) no longer inherits `ZMX_DIR`. Any subsequent `zmx <anything>` invocation from inside a session falls back to default dir resolution.

**Breaks**: `zmx list` / `zmx detach` / `zmx kill` from **inside** a session. zmx upstream's intended UX assumes you can run zmx commands inside a session against the same dir. AS doesn't use that, so this is acceptable for an AS fork but probably not upstream-mergeable as-is.

User stated: cannot patch upstream zmx in this project's submodule (constraint, not technical).

### Option B — wrap the attach command to scrub after daemon spawn

`ZmxBackend.buildAttachCommand` change:

```
  before:  zmx attach <id> /bin/zsh -i -l
  after:   zmx attach <id> /bin/sh -c 'unset ZMX_DIR ZMX_SESSION; exec /bin/zsh -i -l'
```

The `exec` keyword keeps fork count identical (one extra `execve`, no extra `fork`).

**Closes**: same link as Option A, but from AS side without vendor changes.
**Cost**: one extra `execve` call per pane spawn (~5 ms). Login-shell behavior preserved via `-l` flag.

### Option C — `unsetenv` at AS main entry

`Sources/AgentStudio/main.swift` lines 4-18 (after existing imports, before `ghostty_init`):

```swift
unsetenv("ZMX_DIR")
unsetenv("ZMX_SESSION")
```

**Closes**: AS-boot → AS-subprocess link. Inner AS's own subprocesses (reaper, libghostty internals, anything not explicitly overriding env) cannot pick up an inherited `ZMX_DIR` pointing at outer's dir.

**Does NOT close**: outer's daemon → user shell link (zmx's own leak). claude/bash inside an AS pane still have the inherited `ZMX_DIR` from the daemon's `execChild`.

**Verified safe by audit (Codex, code review)**:
- No AS code reads `ZMX_DIR` / `ZMX_SESSION` from `ProcessInfo.processInfo.environment` in production.
- libghostty does not reference either var (grep of vendor/ghostty/src).
- No tests assert ambient inherited values; all tests use explicit env overrides.
- Placement before `ghostty_init` is required (so any Ghostty static init that captures env doesn't see them).

**Empirically broken**: see Option C Mystery below.

### Option D — launcher-level debug isolation (CURRENT)

Do not rely on app startup to detect a nested Agent Studio terminal. The
supported debug/beta observability launchers scrub the inherited process
environment before `exec`, and the debug launcher also assigns a per-worktree
bundle id and data root. This closes the common nested-launch case without
mutating global process environment inside `main.swift`.

## Option C Mystery — UNRESOLVED

Per the matrix above, Option C should be a no-op when AS is launched from a context that has no `ZMX_*` vars in env. The unsetenv calls remove nothing.

Yet empirically:

```
  Setup:        plain Ghostty.app terminal (no ZMX_*, just GHOSTTY_*)
  Launch:       .build/debug/AgentStudio (Option C applied, built clean)
  Action:       open new terminal pane in debug AS
  Result:       new pane shows "Process Exited" (zmx attach exited immediately)
  Reproducible: yes
```

With Option C reverted, baseline works in the same setup.

This contradicts both the override-wins reading of Ghostty's env model and the no-op-on-unset claim of `unsetenv(3)`. One of those must be wrong, or there's a third factor.

### Hypotheses still open

- **H1**: Ghostty's `env_override` does not actually override at runtime. The reading at `vendor/ghostty/src/termio/Exec.zig:807-814` says it does, but the runtime behavior may diverge.
- **H2**: Something between AS boot and surface spawn sets `ZMX_SESSION` non-empty. No production code path identified that does this; would need runtime tracing.
- **H3**: Inherited PROCESS env interacts with `env_override` differently than expected (e.g., empty value treated as "remove" by some intermediate layer). RepeatableStringMap parse path treats empty value as "remove key" (vendor/ghostty/src/config/RepeatableStringMap.zig:46-51), but that's the parseCLI path, not the C-API env_vars path used by AS.
- **H4** (RULED OUT): different zmx binary. Both `/Applications/AgentStudio.app/Contents/MacOS/zmx` and worktree `vendor/zmx/zig-out/bin/zmx` report identical version 0.4.2 and ghostty_vt commit. Same binary effectively.

### What would resolve this

A diagnostic that captures the child shell's actual env at the moment of zmx attach. One-line code change:

```swift
// ZmxBackend.swift buildAttachCommand
return "(env > /tmp/zmx-attach-env-\(handle.id).log; exec \(escapedPath)) attach \(escapedId) \(escapedShell) -i -l"
```

After repro, `cat /tmp/zmx-attach-env-*.log | grep ZMX_` shows exactly what the child saw. That collapses H1/H2/H3 into a single answer.

Has not yet been run (user wanted no code changes during last verification pass).

## Diagnostic procedure for future sessions

### Pre-launch state (in plain Ghostty.app terminal)

```bash
WORKTREE="$HOME/Documents/dev/project-dev/agent-studio.fix-zmx-env-isolation"
DEBUG_STATE="$WORKTREE/tmp/debug-observability/latest-observability.env"

# Prepare the stable vendor paths. In a shared worktree this reuses the
# compatible primary output without hydrating the local zmx submodule.
mise run setup

# Which zmx will debug AS pick?
which zmx
ls -la /Applications/AgentStudio.app/Contents/MacOS/zmx
ls -la "$WORKTREE/vendor/zmx/zig-out/bin/zmx"
/Applications/AgentStudio.app/Contents/MacOS/zmx --version
"$WORKTREE/vendor/zmx/zig-out/bin/zmx" --version

# What env does this terminal have?
env | grep -E "^ZMX_|^GHOSTTY_|^TERM_" | sort

# Launch through the supported helper, then source its state file.
mise run run-debug-observability -- --detach
mise run verify-debug-observability
. "$DEBUG_STATE"
DEBUG_DIR="$AGENTSTUDIO_OBSERVABILITY_ZMX_DIR"

# Pre-action state of the isolated debug socket dir
ls -la "$DEBUG_DIR/"
ps -eo pid,ppid,stat,command | grep -E "[z]mx attach"

# Is Option C currently in source?
grep -n unsetenv "$WORKTREE/Sources/AgentStudio/main.swift" || echo "(reverted)"
```

### Console log stream (run in a second tab BEFORE launching AS)

```bash
log stream \
  --predicate 'subsystem == "com.agentstudio" OR senderImagePath CONTAINS "zmx" OR senderImagePath CONTAINS "AgentStudio"' \
  --info --debug --style compact 2>&1 | tee /tmp/as-debug-stream.log
```

### Reproduce, then capture post-crash state

```bash
# In tab 1: debug AS is already running from the helper above.

# In debug AS UI: open new terminal pane → see "Process Exited" → cmd-Q
# In tab 2: stop log stream (ctrl-C)

# In tab 1, post-crash:
ls -la "$DEBUG_DIR/"
ps -eo pid,ppid,stat,command | grep -E "[z]mx attach"
ls -lat "$DEBUG_DIR/logs/"
for L in $(ls -t "$DEBUG_DIR/logs/"*.log 2>/dev/null | head -3); do
  echo "--- $L ---"; tail -50 "$L"
done
[ -f "$DEBUG_DIR/logs/zmx.log" ] && tail -80 "$DEBUG_DIR/logs/zmx.log"
grep -Ei "zmx|attach|surface|Process|exit|fail|error|orphan|kill" /tmp/as-debug-stream.log | head -120
```

### Key signals to look for

- daemon log shutdown messages: `"shutting down daemon session_name=…"` → graceful kill via IPC
- abrupt log truncation → SIGKILL
- AS log lines mentioning boot-time `zmx kill` or "Killed orphan zmx session"
- zmx CLI log entries showing CannotAttachToSessionInSession
- absence of any new socket created in `$DEBUG_DIR/` for the new pane → daemon never started

## Architectural insight — what the trust boundary actually is

The zmx mental model places the trust boundary at the **directory**, not the daemon:

```
  - daemons in the same ZMX_DIR are mutually reachable through their sockets
  - any process with read+write to that dir can `zmx kill` any daemon
  - per-daemon authentication does not exist
  - the directory is the cohort
```

Stable and beta keep channel-level data roots (`~/.agentstudio/z` and
`~/.agent-studio-b/z`). Debug observability launches use a per-worktree root
(`~/.agentstudio-db/<code>/z`) so parallel debug branches do not share the same
socket cohort by default. Because the current boot reconciliation path is
non-destructive, shared-directory membership is safe at startup. Any future
destructive background janitor must still treat cross-instance visibility as a
latent data-loss risk: each instance can see another instance's sessions when
they intentionally share a root, and `as-*` prefix membership alone is not
ownership proof.

Possible architectural fixes (each addresses a different leak point):

| Fix | Closes | Cost |
|---|---|---|
| Per-worktree debug root: `~/.agentstudio-db/<code>/z` | isolates debug branches while preserving cross-launch debug persistence for the same worktree | requires explicit fixtures instead of accidentally sharing the global debug root |
| Per-instance subdirectory: `~/.agentstudio-db/z/<launch-nonce>/` | cross-instance destructive cleanup; isolates per process | breaks cross-launch persistence unless nonce is workspace-stable |
| Owner-stamped session names: `as-<instanceId>-<repo>-<wt>-<pane>` | janitor filter targets only own sessions | renames the on-disk format; migration cost |
| Janitor attribution via `zmx list` metadata (cwd/pid) | only delete when attribution is unambiguous | still fragile if two instances know about same worktree |
| Refuse boot when `ZMX_SESSION` inherited (Option D) | nested-launch case specifically | doesn't help two side-by-side AS windows |

## File reference index

```
  AS — zmx integration
    Sources/AgentStudio/main.swift                                           — Option C location
    Sources/AgentStudio/Infrastructure/AppDataPaths.swift:46-53              — zmxDirectory derivation
    Sources/AgentStudio/Core/Models/SessionConfiguration.swift:30-59         — detect()
    Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift
       :104   sessionPrefix = "as-"
       :165   sessionId(repoStableKey, worktreeStableKey, paneId)
       :184   drawerSessionId(parentPaneId, drawerPaneId)
       :247   buildAttachCommand                                              — surface command
       :273   destroyPaneSession (zmx kill)
       :290   healthCheck (zmx list)
       :322   discoverOrphanSessions
       :346   destroySessionById
       :366   executeWithRetry — env override happens here
    Sources/AgentStudio/App/Coordination/PaneCoordinator+ViewLifecycle.swift
       :178   surface env_vars: ZMX_DIR + ZMX_SESSION="" for attached pane
       :307   same for floating pane
    Sources/AgentStudio/App/Coordination/ZmxOrphanCleanupPlanner.swift       — protects own panes
    Sources/AgentStudio/App/Boot/AppDelegate.swift
       reconcileZmxSessionAnchorsAtStartup() — boot-time, non-destructive
       runZmxStartupSessionReconciliation(...) — discovery/hydration only
    Sources/AgentStudio/Infrastructure/ProcessExecutor.swift:93-96           — env merge override-wins

  zmx — vendor
    vendor/zmx/src/main.zig
       :281-294   Cfg.socketDir (ZMX_DIR resolution)
       :378-420   execChild (the daemon→shell leak point)
       :961       list — current marker via getEnvVarOwned
       :998       detachAll — requires ZMX_SESSION present
       :1136-1140 attach guard (CannotAttachToSessionInSession)
       :185-191   kill no-args path (uses ZMX_SESSION_PREFIX)
    vendor/zmx/src/socket.zig
       :5         getSeshPrefix (ZMX_SESSION_PREFIX)
       :9         getSeshNameFromEnv (ZMX_SESSION)
       :12-29     getSeshName (validates + prepends prefix)

  Ghostty — vendor (env handling)
    vendor/ghostty/src/apprt/embedded.zig
       :452-453   env_vars / env_var_count fields on surface options
       :538-548   C API env_vars → config.env.map.put
       :951-953   defaultTermioEnv → getEnvMap of AS process
    vendor/ghostty/src/Surface.zig:623-638                                   — env + env_override wired
    vendor/ghostty/src/termio/Exec.zig:807-814                               — env_override iteration (override-wins)
    vendor/ghostty/src/config/RepeatableStringMap.zig:46-51                  — parseCLI: empty value removes key
       (NOT the path AS goes through, but worth knowing)
```

## Open questions

1. **Why does Option C crash new-pane creation when launched from plain Ghostty.app?** All four hypotheses (H1-H4) explored, H4 ruled out. Need the env-dump diagnostic to make further progress.
2. **What is the actual mechanism that kills outer AS daemons during nested launch?** Suspected `zmx kill`-style external loop with `ZMX_DIR` inherited from outer. Not yet localized to a specific process or call site; the current AS boot path is no longer a candidate because it has no destroy-capable startup backend.
3. **Are there other AS code paths that spawn zmx subprocesses?** Last audit found only `ZmxBackend.executeWithRetry`. Worth re-grepping after any refactor.
4. **Is libghostty's surface command pipeline doing anything zmx-aware that we haven't seen?** The xcframework is binary-only in this checkout; would need to rebuild Ghostty with logging or trace at runtime.

## Status snapshot

- Worktree `fix/zmx-env-isolation` exists at `~/Documents/dev/project-dev/agent-studio.fix-zmx-env-isolation/`
- Last state: Option C **reverted** in source, last build at `.build-agent-78406/debug/AgentStudio`
- Codex validation completed: Option C labeled SAFE_WITH_CAVEAT (caveat = placement before `ghostty_init`, which is what we did)
- Empirical contradiction with Codex's verdict remains unexplained
- No fix shipped yet
