# J7 — status on the pane displaying the live agent

Oracle: the owner's requirement, **every pane that displays a live agent shows
that agent's status**. A working foreground path does not prove a hosted viewer.
Portable outcomes: `pane-contract.md`. Inherited host credentials select the
hook's pane; provider session IDs do not establish a displaying-pane attachment.
Background Claude hooks may be suppressed before payload decoding. On the
attribution-defect source, remote Codex and Claude daemon/attach are expected to
expose #68. Safely observed missing/misattributed status is FAIL; a setup that
cannot be isolated is UNKNOWN with a specific blocker.

The run grant must cover provider/session creation and name exact versions,
paths and login scope. Return shared setup's debug target/health/ownership first.

## Safety gate — before starting any provider or turn

All four setups get **separate new owned debug panes**, with recorded pane/tab
and terminal/client generations. Use the declared debug CLI/socket/data/zmx
roots, never production IPC, even for a read or to find a misplaced hook.

For **(b) and (c)** the execution host can outlive and be outside the displaying
pane. The owner's existing Claude daemon inherited a **production pane**;
a worker hook can therefore target production even when its viewer is debug.
A new debug pane, setting HOME on the viewer, or attaching an exact session ID
does not prove the execution host is isolated.

Before either host starts, retain the new physical scratch scope, loaded hook
command/CLI and owned debug origin/client environment. The positive recipes
below establish the launch chain without borrowing a shared host. After host
and session creation, extend that receipt with actual process/worker identities
**before the task turn**. These are two checkpoints, not a demand to inspect a
worker that does not exist yet. The completed sanitized receipt shows:

- the Lead-declared owned host/daemon/session and endpoint, executable/version,
  process generation, and displaying debug pane;
- an **isolated daemon/host**, a separately authorized owner-controlled HOME and
  provider scope, or an exact **Lead-declared session**, plus evidence that its
  actual host/worker environment, loaded hook CLI/endpoint and any fallback pane claim can
  reach **only the declared debug app**. A declaration/HOME pathname alone is
  not that evidence. Before the turn, check the execution host and viewer;
  record actual tool/hook children and their recipient after the first turn
  (step 5), not as a prerequisite for children that do not yet exist;
- the permitted bounded hook observer/public debug readback and its limits for
  correlating this turn's hook with a recipient pane, suppression or no call.
  Keep token values, escrow, full environment dumps and provider transcripts out
  of the receipt. Do not open daemon auth snapshots or private control keys.

Unavailable hook-recipient telemetry leaves that field UNKNOWN when debug-only
containment is independently established. Unproved containment blocks the whole
setup; missing telemetry never permits an unsafe probe.

If the first checkpoint fails, **do not start the host/session**. If the second
fails, hold the owned setup and **send no task turn**; report UNKNOWN with the
specific missing evidence/grant. Do not
probe an unsafe host to discover where its hook lands, stop/restart an owner's
shared daemon, transplant a pane token, or change the host environment just to
make its result look like (a). Containment may change deployment roots, not the
defining client/host topology. A denied inspection is not absence or isolation.

Provider installation needs a separate write grant and a reviewed scratch-only
write set (resolve links/parents before writing). **Cursor ignores HOME** for
its default install home: pass an explicit owned scratch provider home for each
install, never rely on HOME alone. The current bundled parser's supported entry
is `"$CLI" package install cursor --provider-home "$CURSOR_SCRATCH_HOME"`.
Read the declared build's parser/help before reuse; verify all hook/skill writes
stay inside the approved scratch homes and that the provider actually loads
that scratch config. No supported isolated config route means UNKNOWN, not an
install into the owner's real home.

## One journey, four actual setups

### Slot (b): try an isolated Router service first

Slot (b) means the **remote app-server topology**, as defined in
`pane-contract.md`: host executes the agent; the displaying pane holds only
`codex --remote`. Router-hosted and owned standalone hosts both fill this slot.
First read the installed management CLI's help, without starting a service:

```bash
agent-collaboration --help
agent-collaboration host --help
agent-collaboration service --help
```

Use the Router route only when that help actually advertises a foreground host/
service launch with an explicit private service directory. Then, under the run
grant, start that supported command from an owned debug origin pane with a new
owner-controlled service directory and scratch Codex scope; retain exact argv,
private endpoint/service identity, PID/start/ancestry and debug environment.
Create only the run-owned session through that isolated service, then connect
the displaying pane's `codex --remote` to its returned endpoint. Apply the same
host/viewer containment and turn observations below. Never assume a read-only
command's `--service-directory` option is also a startup option, reuse the
owner's default service, or invent a host flag.

If these help calls expose no isolated service launch, record the precise
capability gap and use the approved standalone route below; that gap does not
block slot (b). An installed launcher may return **exit 2**, "sessions
interactive picker requires a terminal; use --list or --last", for both host and
service help instead of management usage. This is unsupported command dispatch,
not permission to allocate a terminal or run a picker to find a hidden service
command. This output has not established a supported management launch route.
Record the installed version/help output and fall back. A standalone result's
required label keeps the unexercised Router wrapper explicit in the count.

### Positive containment: owned remote Codex host

Prepare a **new absolute owner-controlled** `CODEX_SCRATCH_HOME`, private short
`CODEX_SERVER_SOCKET` path inside it, and scratch work directory; none may be a
symlink to a real provider home. Execute install/login/host snippets from the
owned debug **origin pane**, retaining its injected CLI/store/socket/pane context.
The pinned `$CLI` must be that debug bundle's helper. The run grant covers writes and
login. With that grant, prepare the directories and install only into scratch:

```bash
umask 077
mkdir -p "$CODEX_SCRATCH_HOME" "$SCRATCH_WORK"
env -u AGENTSTUDIO_PACKAGE_ROOT "$CLI" package install codex --provider-home "$CODEX_SCRATCH_HOME"
```

Inspect the loaded hook command against the declared debug package; retain
the install result and physical write set. The explicit home flag is parsed by
`AgentPackageCommandLine.providerHomePath`; no default provider home is used.
Do not copy a real auth file. With a separate login grant, use
`env CODEX_HOME="$CODEX_SCRATCH_HOME" "$CODEX" login`; authentication failure or
unavailable login is the specific UNKNOWN blocker, not a reason to use real home.

In an **owned debug origin pane**, retain its identity/start and sanitized
debug CLI/socket/pane-claim receipt, remove any outer debug escrow selector,
then run this foreground host (a future live action, never an authoring step):

```bash
env -u AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW \
  CODEX_HOME="$CODEX_SCRATCH_HOME" \
  "$CODEX" app-server --listen "unix://$CODEX_SERVER_SOCKET"
```

In the separate owned **displaying pane**, connect the real TUI:

```bash
env -u AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW \
  CODEX_HOME="$CODEX_SCRATCH_HOME" \
  "$CODEX" --remote "unix://$CODEX_SERVER_SOCKET" -C "$SCRATCH_WORK"
```

Keep the origin pane's host running. The app-server PID/start must be a new
descendant of that origin shell after debug launch; the viewer is a distinct
PID in the displaying pane. Record the explicit endpoint, physical scratch
home, versions, and sanitized inherited debug socket/CLI/claim for **host and
viewer before the turn**. Hook children use the session environment established
by this contained host/viewer setup; record their actual recipient from the
first turn's hook observation (step 5). Confirm server readiness through the supported
handshake/TUI connection and exact selected thread, not socket existence alone.
All potential origins/fallback claims are then debug panes by construction;
observe which one actually receives the hook. Do not force it to the viewer.

This source-backed isolated **remote app-server** route **fills slot (b) and
counts toward N** under the same phase criteria. Use the exact result label
**"(b) remote app-server — Router wrapper not exercised"**. The label records a
residual; it does not turn slot (b) into UNKNOWN merely because Router was not run.

### Positive containment: owned Claude daemon and attached viewer

Prepare a new absolute owner-controlled `CLAUDE_SCRATCH_CONFIG` and work directory.
Run install/login/daemon snippets from its owned debug **origin pane**, with
the install/write grant, using the declared debug CLI's Claude parser:

```bash
umask 077
mkdir -p "$CLAUDE_SCRATCH_CONFIG" "$SCRATCH_WORK"
env -u AGENTSTUDIO_PACKAGE_ROOT "$CLI" package install claude --config-dir "$CLAUDE_SCRATCH_CONFIG"
```

Retain the result and inspect the scratch settings/skill write set, never the
real home. `ClaudeCodePackageCommand.resolvedConfigurationDirectory` gives the
explicit `--config-dir` precedence. With a separate login grant, use
`env CLAUDE_CONFIG_DIR="$CLAUDE_SCRATCH_CONFIG" "$CLAUDE" auth login`.
Do not copy daemon auth snapshots or credentials. If scratch login is not
available, record that exact blocker before launching a session.

In an **owned debug origin pane**, validate its pane environment and run:

```bash
env -u AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW \
  CLAUDE_CONFIG_DIR="$CLAUDE_SCRATCH_CONFIG" "$CLAUDE" daemon run
```

Keep this foreground daemon alive. From a second owned debug shell, using the
**same absolute config root**, create the background session and retain the ID
printed by the successful command:

```bash
env -u AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW \
  CLAUDE_CONFIG_DIR="$CLAUDE_SCRATCH_CONFIG" "$CLAUDE" --bg
```

Attach that exact returned ID in the dedicated displaying pane:

```bash
env -u AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW \
  CLAUDE_CONFIG_DIR="$CLAUDE_SCRATCH_CONFIG" "$CLAUDE" attach "$SESSION_ID"
```

Retain new daemon PID/start/ancestry, scratch-root-derived control-socket identity,
and worker/viewer identities. Claude 2.1.308 derives the Unix daemon scope from a
hash of its config root; its worker builder retains the daemon's config root
and adds background markers. Confirm these for the declared version and the
actual worker before a task turn. Check all inherited/dispatch pane claims are
owned debug panes and no production endpoint is selected. A preexisting daemon
for this supposedly fresh scope is a concrete HOLD/UNKNOWN; do not replace it.
Preserve background markers: suppression leaving the viewer without status is
**FAIL**, even though it prevents a hook to the origin. Keep that evidence.

Source basis for these commands: Codex `rust-v0.163.0` CLI `AppServerCommand`,
app-server `run_main`/Unix acceptor, config `find_codex_home`, hook command runner,
and TUI `--remote`; Claude 2.1.308 installed config-root/daemon-scope/worker-env
implementation plus `daemon run --help`, `--help` (`--bg`), `attach --help` and
`auth login --help`. Re-read declared-version help/source before reuse. These
examples prove a concrete recipe exists in source/help, not that it ran.

Record exact argv and selected conversation identity from the supported launch/
attach route supplied by the Lead. Read its current tool schema/help; do not
invent Router creation flags or daemon isolation switches from this document.

| Setup | Real entry and topology to preserve | Evidence before the turn |
| --- | --- | --- |
| (a) Foreground | Start `claude` or a genuinely pane-local `codex` in its owned debug pane; agent execution and display share that pane. For Codex 0.163, `codex --no-daemon` selects the non-shared path; verify the declared version. Record provider/argv. | Its actual pane-bound environment, loaded hook package and provider/session identity. No `--remote`, shared background host or attach hidden inside this control; classify actual bare-command topology rather than its name. |
| (b) Remote app-server | A Codex **app-server** executes the agent; the debug pane holds only its **`codex --remote` client**. Try a supported isolated Router service first; the owned standalone host above also fills (b) and counts toward N, with its required residual label. | Pre-turn host/viewer environment, remote endpoint and selected thread; first-turn hook recipient afterwards. Client environment alone is insufficient. Distinguish concrete thread ID from shared tree/session ID. |
| (c) Claude background + attach | Session runs under **`claude daemon run`**; display it in its own debug pane using **`claude attach <declared-id>`**. Preserve background markers; if suppression leaves the displaying pane without status, that is **FAIL (#68)**. Retain suppression evidence. | Safety receipt for the actual daemon/worker, exact attached session and viewer pane. Changing only the attacher HOME does not change a warm daemon's inherited production identity. |
| (d) Cursor | Start Cursor's actual foreground agent in its own debug pane, with the declared scratch hook/config scope. | Explicit scratch install homes/config loading, actual conversation ID and pane-bound hook path. Do not substitute IDE/ACP/persistent-host proof or synthesize a hook. |

1. Create/record the four owned panes through the declared debug command catalog
   only after the run grant. Confirm each baseline row/card belongs to that pane;
   preserve any debug origin/comparator pane for detecting wrong-pane updates.
   Blocked setups retain their row in the matrix and denominator.
2. Start/attach each **actual topology** above only after its safety gate passes.
   Keep provider execution identity separate from the client/pane displaying it.
   Matching CWD, process name/ancestry, a shared socket, or the last active session
   is not selected-session proof. A local cached Codex thread switch can change
   the display without a new resume request. Record/fence uncertain selection.
3. Run a real agent turn in each setup, in its owned scratch work area. Ask it
   to set a unique title and Agent Line message using its shipped app skill and
   run a bounded observable command such as `sleep 45` before replying. That
   finite command is workload, not a readiness wait or a speed assertion.
   If it first raises an approval, that is the **Needs you** phase: capture it,
   then the named operator approves under the run grant and Working follows
   when the tool actually starts. Record both outcomes. Without that approval
   grant, hold at Needs you and report the unobserved Working phase UNKNOWN.
   Capture while its actual tool-start/terminal state confirms it is running,
   then retain its completion. Repeat a new real turn for another width if
   needed; never infer Working from elapsed time. Retain actual command
   dispositions, including intentional background refusals. Capture during the
   live turn and after it; a manually invoked hook, setter, fake session event,
   synthetic Working fixture or CLI write alone is not this journey.
4. Observe the **displaying pane's Panes row and its ⌘R card**: status, exact
   message and title, with real turn/session identity. Compare the agent's actual
   turn state with the visible status and any debug-origin/comparator row.
   Use shared setup's app-render route for static fields, including while locked:
   establish the actual phase, wait 3 s after its change and render once. Record
   that pane's owner session/turn facts immediately before capture and match the
   asynchronous rendered fields to them. An in-flight/stale result fails; do not
   retry or extend the settle. A synthetic foreground hold or line CLI fixture
   cannot supply this journey's real turn/provider-host proof. Preserve the
   before/after lock probes and original source-to-evidence paths.
   Record each field's PASS/FAIL/UNKNOWN, all supported widths/taste frames
   (cards: 420/520/640/780/1000pt), and the overall setup result. A missed brief
   Working capture is UNKNOWN for that state, not evidence that status works.
   Use these phase outcomes (source/meaning in `pane-contract.md`):

   | Actual phase | Required row and card status |
   | --- | --- |
   | Submitted real turn, bounded tool still running | **Working** on the displaying pane, not the origin/comparator. |
   | Successful turn stop, before any next turn/acknowledgment | **Idle · done**; after acknowledgment/readiness, **Idle · ready**. Record the actual phase, not whichever label happened to paint. |
   | Outstanding real provider approval/question | **Needs you · approval/question** until answered/cancelled. Arrange a harmless, separately permitted prompt; don't disable approvals or invent a hook to force it. If no such fixture is available, this phase is UNKNOWN. |
5. Record **which pane, if any, received the hook call** using the predeclared
   debug-only observer/readback correlated to this turn. Distinguish an observed
   recipient ID, observed suppression/no call, and UNKNOWN observation. Hook
   exit 0 alone proves none of these: scripts may return 0 without sending, and
   Claude may suppress background hooks before decoding. Missing hook telemetry
   stays UNKNOWN independently of a decisive visible status failure. Do not
   query production to fill this field.

Wrong behavior this catches: a live remote/attached agent with a blank or stale
displaying-pane status; a hook reaching a different debug origin pane; title or
message attached to the wrong pane; or status passing only after silently
replacing (b)/(c) with a foreground process. Preserve each failure. Do not repair
attribution, bypass background guards or manually bind a session during proof.

## Handback and owned cleanup

Return one row for each (a)–(d): actual topology/provider version, displaying
pane/session/thread, containment evidence or block reason, real-turn evidence,
hook recipient/no-call/UNKNOWN, row/card status/message/title results, taste
results through the shared quality return. Expected #68 failures are still FAIL
when safely observed; until run, they are not an observed FAIL or PASS.

End with **"N of 4 setups show status on the displaying pane"**. N counts only
setups with **Working during the running turn and the correct post-turn status**
observed in row **and** card on the correct pane;
never count blocked/UNKNOWN or hook-only evidence. Also give PASS/FAIL/UNKNOWN
counts for the four overall setups and every unrun case. A status count is not
an acceptance verdict for message/title or taste failures.

An observed standalone slot (b) is eligible for N exactly like a Router-hosted
slot. Whenever standalone is used, append **"(b) remote app-server — Router
wrapper not exercised"** to that same coverage line, including on a failed or
incomplete attempt. This preserves the wrapper residual without changing N's
denominator or double-counting the two host variants as separate setups.
Use this line template for standalone:
`N of 4 setups show status on the displaying pane; (b) remote app-server — Router wrapper not exercised`.

Cleanup only the panes/processes/sessions this run owns under its explicit grant,
after preserving evidence and exact identities. Leave shared Router hosts,
owner daemon and production app alone. If an owned fixture must remain held,
name it and the cleanup owner; no process-name kill or inferred retirement.
