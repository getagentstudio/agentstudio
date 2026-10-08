# Observability And Traceability

AgentStudio is an observability producer. The shared collector, Victoria
services, retention, and smoke checks live outside this repo in
`~/dev/ai-tools/observability`. AgentStudio owns only source-side
instrumentation, launch markers, safe projection, and app-specific proof
scripts.

## Control Plane

Tracing has three separate control surfaces:

| Surface | Env or file | Owns |
| --- | --- | --- |
| Global preferences | `<AppDataPaths.rootDirectory()>/preferences.global.json` | App-root scoped default observability posture |
| Instrumentation selection | `AGENTSTUDIO_TRACE_TAGS` | Which app emitters are enabled |
| Sink selection | `AGENTSTUDIO_TRACE_BACKEND`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL` | JSONL, OTLP, or both |
| Proof handoff | `AGENTSTUDIO_OBSERVABILITY_*` state files | Marker, PID, app path, query window, launch status |

`AGENTSTUDIO_DATA_DIR` is only a root locator. It chooses the app data root
that contains `preferences.global.json`; it is not itself an observability
setting. Stable, beta, debug, generated debug, and custom app identities keep
separate roots, so each app identity gets its own global preferences file.

The preference file is loaded by App/Boot before `AgentStudioTraceRuntime` is
constructed. Diagnostics then resolves effective trace behavior in this order:
channel defaults, then global preferences, then environment overrides. This
keeps local prod/beta/debug defaults durable while preserving the existing
one-launch override contract. `AGENTSTUDIO_TRACE_TAGS=off` still disables
tracing for that launch, and `AGENTSTUDIO_TRACE_BACKEND`,
`OTEL_EXPORTER_OTLP_ENDPOINT`, and `OTEL_EXPORTER_OTLP_PROTOCOL` still win over
the preference file.

The v1 preference schema owns only durable choices:

```json
{
  "schemaVersion": 1,
  "observability": {
    "enabled": true,
    "traceTags": "*",
    "traceBackend": "otlp",
    "traceFlush": "buffered",
    "otlpEndpoint": "http://127.0.0.1:4318"
  }
}
```

`observability.enabled` is required. `traceTags`, `traceBackend`, `traceFlush`,
and `otlpEndpoint` are optional. `otlpEndpoint` must be loopback HTTP when
present. `otlpProtocol` is intentionally not a persisted preference; protocol
compatibility remains an environment-only escape hatch.

Do not add one-off environment variables for individual emitters. A new
instrumentation lane must be represented as an `AgentStudioTraceTag`, or as an
event namespace under an existing tag when that tag already owns the lane.

Examples:

```text
Good:
  AGENTSTUDIO_TRACE_TAGS=atoms
  AGENTSTUDIO_TRACE_TAGS=performance,atoms
  AGENTSTUDIO_TRACE_TAGS=*

Bad:
  AGENTSTUDIO_TRACE_ATOM_METRICS=1
  AGENTSTUDIO_TRACE_SIDEBAR_EVENTS=1
  AGENTSTUDIO_TRACE_ENABLE_REPO_CACHE=1
```

The strict debug and beta observability launchers may pass the standard
trace/backend variables plus app identity and state-file variables. Preference
proof launchers use sibling scripts and write `preferences.global.json` under an
isolated proof data root instead of injecting trace-selection variables. Neither
launcher family may grow feature-specific trace switches.

## Tag Semantics

`AGENTSTUDIO_TRACE_TAGS` selects emitters. Debug and beta app startup has a safe
default baseline when the variable is unset. The strict
`run-debug-observability` and `run-beta-observability` proof helpers set
`AGENTSTUDIO_TRACE_TAGS=*` unless the caller explicitly overrides it, so full
local proof can include high-volume lanes with a fresh marker.

The standard git-refresh performance workload is different: it uses the narrow
`performance,app.startup,terminal.startup` tag set by default so the measured
hot path is not perturbed by high-volume atom tracing. Dedicated atom telemetry
proof can opt into `AGENTSTUDIO_TRACE_TAGS=atoms` or `*`.

High-volume or domain-sensitive lanes remain explicit opt-in for ordinary app
startup. This includes `atoms`, `eventbus`, `terminal.activity`,
`terminal.signal`, `terminal.tcc`, `inbox`, `paneInbox`, and
`persistence.snapshot`.

Terminal signal instrumentation is controlled by the `terminal.signal` tag. It
captures low-volume Ghostty action/control facts such as desktop notification,
command-finished, progress, and routing outcomes. Terminal output growth and
debounced unseen-activity windows remain under `terminal.activity`. Keep raw
terminal payloads, pane ids, surface ids, and notification ids JSONL-only; OTLP
may export only controlled signal class, action name, route result, reason, and
safe aggregate counters.

TCC upgrade diagnostics are controlled by the `terminal.tcc` tag and the
explicit startup diagnostic action `tcc-upgrade-probe`. The probe records bundle
identity classification and shell-child access classification for protected
folders so beta/debug proof can distinguish grant loss from ordinary startup
failure. Raw bundle paths, probe paths, responsible executable paths, and TCC
database client strings must stay JSONL-only; OTLP may export only controlled
classification enums, booleans, and counts.
Repeating `tcc-upgrade-probe` runs also emit an app identity snapshot for each
probe sequence. The snapshot compares the current on-disk app executable
identity to the startup baseline and exports only controlled classifications
such as same/different/missing disk identity plus reachability. Raw executable
paths remain JSONL-only.
Use [`scripts/report-tcc-upgrade-probe-observability.sh`](../../../scripts/report-tcc-upgrade-probe-observability.sh) after a marker-scoped
debug or beta launch to summarize the identity/access rows. The report helper
is read-only and can require identity discontinuity or access denial, which is
the proof gate for a Homebrew-style replacement reproduction.
For the generated-debug reproduction only, use
[`scripts/replace-running-debug-app-for-tcc-probe.sh`](../../../scripts/replace-running-debug-app-for-tcc-probe.sh) to dry-run and, with
explicit acknowledgement, replace the executable inside the generated
per-worktree debug app while the monitor is active. The helper refuses beta,
stable, `/Applications`, and non-generated debug paths; it is not a release or
Homebrew updater.

Atom instrumentation is controlled by the `atoms` tag. It emits reduced,
aggregate-safe events such as `performance.atom.read`,
`performance.atom.mutation`, and `performance.atom.derived`. The event names
describe the metric family, but the trace tag remains `atoms`; the tag is the
selection boundary.

## OTLP Projection

OTLP is a source-side trust boundary. The app projects trace records into a
reduced safe shape before export. New OTLP fields must be explicit allowlist
entries with tests proving they do not expose raw paths, UUIDs, prompts,
payloads, errors, terminal output, tokens, or tool output.

Allowed OTLP atom fields are aggregate or controlled vocabulary only:

```text
agentstudio.performance.atom.kind
agentstudio.performance.atom.label
agentstudio.performance.atom.operation
agentstudio.performance.atom.slot.count
agentstudio.performance.atom.cached_key.count
agentstudio.performance.atom.input_revision.count
agentstudio.performance.atom.accepted_change.count
agentstudio.performance.atom.cache_hit
```

Raw atom keys, repo paths, pane ids, workspace ids, object identifiers, and
dictionary payloads must not be exported over OTLP. If an investigation needs a
local forensic field, keep it JSONL-only unless a design update explicitly
extends the OTLP allowlist.

The atom `label` is a controlled lane identity such as
`pane_graph_canonical`; it is not an atom key or entity identifier. Atom
metrics retain the controlled `kind`, `operation`, and `label` dimensions plus
aggregate slot/cache/input-revision/accepted-change counts and cache-hit state.

`performance.runtime_delivery.snapshot` exports aggregate delivery health.
Runtime-channel outbound pending/dropped/retired-undelivered counts remain
separate from EventBus live drops, replay drops, retired-undelivered counts,
active-subscriber count, and active delivery debt. Delivery debt means items
already admitted but still owed to active subscribers; it is not a drop count.
OTLP metrics use the equivalent scrubbed
`agentstudio_performance_runtime_delivery_*` series and never export subscriber
names or payloads.

## Proof Model

The standard debug proof loop is:

```text
mise run observability:up
mise run run-debug-observability -- --detach
mise run verify-debug-observability
```

The launcher writes `tmp/debug-observability/latest-observability.env`. That
file is not proof by itself; it is the handoff containing the marker and process
identity. Verification must query Victoria using the current marker and expected
resource labels.

### Manual and stress verification

- Treat every debug launch as a distinct proof window. When an interaction feels
  slow, query that launch marker's lanes first: feel, query, attribute, then
  diagnose. Never diagnose latency from feel alone.
- Correlate the user's timestamps with the marker's per-second VictoriaLogs
  timeline. Event bursts can attribute the responsible lane immediately; for
  example, 42 coordinator writes in the second after Add Folder.
- Verify the target instance before every manual verdict. Production and multiple
  per-worktree debug identities can run together: match the window's
  four-character identity code to the code and PID in
  `tmp/debug-observability/latest-observability.env`. A verdict against another
  instance is void.
- Detached debug launches are background by default (`open -g`). Set
  `AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE=1` only for human manual testing; automated
  proof must not steal the user's foreground.
- Synthetic fixtures can under-detect MainActor pressure. Interaction-latency and
  MainActor claims require real-sized state—many repositories, heavy watched
  folders, and an active PTY fleet—through either a live marker-scoped manual
  session or a stress fixture derived from one. A **stress baseline** is a
  recorded marker window under heavy real load; load-sensitive fixes must
  demonstrably improve it. A fixture measuring 0.2 ms does not substitute for a
  real-load lane measuring 290 ms p95 and 841 ms maximum coordinator writes.

Preference-honoring proof writes
`AGENTSTUDIO_OBSERVABILITY_PREFERENCES_MODE=honor_preferences` in the state
file. When that flag is present, verifiers must also require the
`app.preferences.global.loaded` startup event under the current marker. Strict
env-driven launchers must not write the flag.

State files may include existing proof handoff fields such as marker, PID, app
path, app identity, launch status, query window, data root, zmx root, and log
path. They must not include preference file paths, symlink targets, raw JSON,
parse messages, prompts, payloads, or tool output.

For atom or performance work, proof should include:

```text
logs     current marker contains expected event names
metrics  current marker contains expected metric series
safety   OTLP projection contains only allowlisted fields
tests    trace config, projection, metric mapping, and emitter tests pass
```

Do not accept stale Victoria rows, old JSONL files, screenshots, or unmarked
records as proof.

Use proof layers deliberately:

```text
unit/focused tests    -> deterministic logic and source projection
integration tests     -> real boundaries such as sinks, stores, processes
debug observability   -> debug app launch with marker-scoped Victoria proof
performance proof     -> VictoriaMetrics under the current workload marker
native UI proof       -> Peekaboo against a debug/beta app by PID
```

Peekaboo is visual/native interaction evidence. It can prove that a debug or
beta app launched, rendered, and accepted a UI interaction, but it does not
replace marker-scoped VictoriaLogs/VictoriaMetrics proof for telemetry or
focused tests for source-side projection and safety rules. The debug-binary
launch recipe is
[Peekaboo PID Targeting](../../guides/agent_resources.md#peekaboo-pid-targeting).

## Local proof launch

App repos target the shared Compose services `ai-tools-otel-collector`,
`ai-tools-victoria-metrics`, `ai-tools-victoria-logs`, and
`ai-tools-victoria-traces` through loopback. Do not create or query per-app
stacks. The stack source of truth is
`~/dev/ai-tools/observability/observability-stack`.

```bash
mise run observability:up
mise run observability:status
mise run observability:smoke
mise run observability:down
```

The standard debug proof loop is in [Proof Model](#proof-model). Ordinary
manual debug development and UI proof use that detached launch with no IPC
automation selector.

### Debug app identity

The debug launcher wraps the debug binary in a signed per-worktree app bundle
named `Agent Studio Debug <code>`, where `<code>` is a deterministic
four-character base36 hash of the canonical worktree path. The short code is
intentional: zmx session names and Unix-domain socket paths are
length-sensitive. That launch uses an isolated data root at
`~/.agentstudio-db/<code>` and zmx directory at `~/.agentstudio-db/<code>/z`,
so a debug run from one worktree cannot share zmx state with stable, beta, or
another debug worktree. Debug observability bundles also remove URL-handler
registration so they cannot claim production `agentstudio://` callbacks or
deep links. Do not copy production or beta state into this root unless a test
plan explicitly calls for it. The generated debug bundle, logs, traces, and
zmx root live under `~/.agentstudio-db/<code>` rather than a repo `tmp/` tree so
autonomous debug runs do not need to read their runnable app from
`~/Documents`.

To inspect the deterministic identity without launching:

```bash
scripts/run-debug-observability.sh --print-identity
```

The state file `tmp/debug-observability/latest-observability.env` is
marker/verifier handoff, not proof. See [Proof Model](#proof-model).
Verification must still query VictoriaLogs and validate the live process
identity. Manual identity/PID matching, feel-as-query, stress baselines, and
`AGENTSTUDIO_DEBUG_LAUNCH_ACTIVATE=1` are in
[Manual and stress verification](#manual-and-stress-verification).

The launcher refuses to start a second `Agent Studio Debug <code>` instance
while one is already running; quit the reported PID before collecting a new
debug observability proof for the same worktree. On refusal it overwrites
`tmp/debug-observability/latest-observability.env` with
`AGENTSTUDIO_OBSERVABILITY_STATUS=already_running` so stale markers cannot
pass verification.

Use this path instead of raw `swift build` plus hand-written environment
variables. The runner allocates a shared Swift build slot, creates the debug
app identity, launches with the Victoria/OTLP environment, and records the
marker that the verifier queries in VictoriaLogs. Performance workload proof
builds on this same runner; it must not create a separate app identity, data
root, zmx root, build directory, trace marker, or process-discovery scheme.

### IPC escrow and startup diagnostics

Agent-driven write-capable debug automation must opt in explicitly:

```bash
mkdir -p tmp/debug-observability
AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$PWD/tmp/debug-observability/ipc-escrow.json" \
mise run run-debug-observability -- --detach
```

`AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW` is the absolute path of the escrow file,
not a flag. The app writes it as an owner-only file, and its directory must
already exist (see [IPC — debug credential escrow](../commands/ipc.md)). A value
like `1` is read as a relative path, which a LaunchServices-launched app
resolves against `/`, so no escrow is written and the CLI can't authenticate.

The worktree-isolated debug app then mints one owner-only automation credential,
reusable for that app runtime's lifetime, and writes it to that file. That principal can use the DEBUG semantic
control allowlist plus the App command execution, read-back, and
workspace-bounded sidebar scopes used by proof harnesses. The selector is not
required to launch, develop, or test the app manually. Stable, beta, and
release apps must never enable it. Do not add
`AGENTSTUDIO_IPC_UNSAFE_NO_AUTH=1` merely to obtain write access; use unsafe
no-auth only when an established diagnostic explicitly requires it.

To exercise a startup diagnostic during debug proof, pass
`AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=<action>` to the launcher. The launcher
records the selected action into the state file as
`AGENTSTUDIO_OBSERVABILITY_STARTUP_DIAGNOSTIC_ACTION`; that state key is
verifier handoff, not the app input environment variable. Example:

```bash
AGENTSTUDIO_IPC_DEBUG_TOKEN_ESCROW="$PWD/tmp/debug-observability/ipc-escrow.json" \
AGENTSTUDIO_STARTUP_DIAGNOSTIC_ACTION=ipc-terminal-smoke \
mise run run-debug-observability -- --detach
mise run verify-debug-observability
```

### Performance workload

```bash
mise run observability:up
mise run verify-git-refresh-performance-workload
```

This script creates disposable fixture repos/worktrees, calls
`scripts/run-debug-observability.sh --print-identity`, preflights the standard
debug app is idle, launches through `scripts/run-debug-observability.sh
--detach`, and then verifies marker-scoped performance telemetry through
VictoriaMetrics. Standard performance proof must use VictoriaMetrics when the
shared collection exists. JSONL is only a local artifact/debug aid and must
not be an automatic fallback; set `AGENTSTUDIO_PERF_ALLOW_JSONL_PROOF=1` only
when a test plan explicitly asks for JSONL proof.

Tag selection for that workload (narrow
`performance,app.startup,terminal.startup`, atoms opt-in) is in
[Tag Semantics](#tag-semantics).

The strict sidebar CPU workload is descriptor-driven and fail-closed. It uses
the complete `open-source` and `project-dev` watched roots through production
owners, positive repository/worktree discovery, exactly five tabs and twenty
pane models, and zero debug-owned PTYs for idle and action populations. One
disposable control repository first proves cold FSEvent local correctness and
no automatic successor, then runs the targeted repository-update command and
becomes the warm self-heal/continuity control for the timed population.

CPU samples come from one absolute-phase, continuous libproc sampler bound to
the state-file debug PID. Action issue records must begin inside the projected
phase envelope and carry generation-matched semantic, accepted, and native
visible-projection fingerprints through settlement. Any debug-owned descendant
observed inside a sample invalidates the population; unrelated host processes
and process names are never gates. Marker-scoped Victoria evidence must show
positive warm and inactive membership, zero cold automatic local/remote/Forge
starts or deadlines, at least one warm periodic completion and continuity
renewal, complete source-specific explicit-update settlement, zero required
loss, and graceful exact-candidate retirement. Future ineligible deadlines are
classified state, not active debt. JSONL cannot substitute for these checks.

### Local beta diagnostic path

```bash
mise run observability:up
mise run create-beta-app-bundle
mise run run-beta-observability -- --latest-local
```

This local beta helper is diagnostic only. The release workflow is the source
of truth for beta promotion: it builds, signs, notarizes, staples, and
publishes the real `AgentStudio Beta.app` artifact from a beta tag. Use the
local debug runner for PR-branch proof, then use the GitHub-produced beta
artifact for promotion proof.

`run-beta-observability` stays attached to LaunchServices with `open -W` so
task runners do not clean it up early. Leave it running, then verify from
another shell:

```bash
AGENTSTUDIO_EXPECTED_BETA_APP="$DOWNLOADED_WORKFLOW_BETA_APP" mise run verify-beta-observability
```

`run-beta-observability` does not install over `/Applications/AgentStudio
Beta.app`. With `--latest-local`, it prefers the newest local bundle under
`~/.agentstudio-db/beta-observability/`, falling back to legacy repo-local
bundles under `tmp/beta-observability/` only if present. Release-promotion
proof must pass `--app "$DOWNLOADED_WORKFLOW_BETA_APP"` and bind
`verify-beta-observability` with `AGENTSTUDIO_EXPECTED_BETA_APP`, so a stale
installed beta or local diagnostic bundle cannot satisfy the gate. Generated
beta apps, logs, and traces live outside `~/Documents` so local proof runs do
not trigger Documents-folder TCC prompts merely because this worktree is under
Documents.

### Launcher environment

Debug and beta observability launchers require the shared collector health
endpoint to be reachable; run `mise run observability:up` first. They run
from a minimal clean environment and pass only the candidate app's
trace/data variables (`open --env` for LaunchServices, equivalent direct
environment for debug fallback), so inherited production app identity,
Ghostty resource variables, `ZMX_DIR`, `ZMX_SESSION`, and
`ZMX_SESSION_PREFIX` cannot leak into the candidate process. The launchers
write per-run markers to `tmp/debug-observability/latest-observability.env`
or `tmp/beta-observability/latest-observability.env`; verification queries
those markers so stale logs cannot satisfy the gate.

The beta launcher likewise refuses to launch while any beta-channel
AgentStudio process is already running, even from another bundle path. Beta
promotion proof should start from one known beta process. Its refusal path
also writes `AGENTSTUDIO_OBSERVABILITY_STATUS=already_running` to the beta
state file. Repo-local observability helpers run under `/bin/bash` rather
than Homebrew bash because the Homebrew bash process has previously wedged
release/verification scripts on this machine. Detached debug and beta
launchers try LaunchServices `open` first. Debug may fall back to direct
`Contents/MacOS/AgentStudio` execution when a local generated bundle is
rejected by LaunchServices/Gatekeeper; the state file then records
`AGENTSTUDIO_OBSERVABILITY_LAUNCH_METHOD=direct_executable`. This is valid
for Victoria/OTLP debug proof and keeps the same isolated data/zmx root, but
it is not full GUI proof. Beta does not use this fallback: if LaunchServices
returns a launch error, beta writes
`AGENTSTUDIO_OBSERVABILITY_STATUS=launch_failed` and exits non-zero. Local
ad-hoc beta bundles may be rejected by AMFI/LaunchServices; Developer ID
signing alone can still be rejected as unnotarized. Beta promotion proof
requires the accepted/notarized artifact produced by the GitHub release
workflow, or another explicitly notarized local artifact. Developer ID
signing is opt-in for local diagnostic bundles: set `SIGNING_IDENTITY` when
running `mise run create-beta-app-bundle`.

Debug and beta builds use a safe baseline when `AGENTSTUDIO_TRACE_TAGS` is
unset: JSONL plus OTLP logs/metrics to `http://127.0.0.1:4318`. Stable builds
stay disabled unless trace tags are explicit, and explicit stable tracing
defaults to JSONL. `AGENTSTUDIO_TRACE_TAGS=off` disables the debug/beta
baseline. Instrumentation selection remains `AGENTSTUDIO_TRACE_TAGS`; see
[Control Plane](#control-plane) and [Tag Semantics](#tag-semantics).

`AGENTSTUDIO_TRACE_BACKEND=jsonl|otlp|both` selects the sink.
`OTEL_EXPORTER_OTLP_ENDPOINT` is accepted only for loopback HTTP endpoints
and is treated as a collector base URL; AgentStudio sends logs to `/v1/logs`
and metrics to `/v1/metrics`. Collector absence or exporter failure must be
fail-open for normal app startup and must not prevent JSONL writes.
AgentStudio currently exports OTLP logs and performance metrics. The shared
stack also runs VictoriaTraces for other local producers, and its smoke gate
exercises all three ingestion lanes. Allowed OTLP resource identity is limited
to safe runtime labels plus deterministic repo/worktree hashes and branch, for
example `dev.repo.hash`, `dev.worktree.hash`, `dev.branch.name`,
`dev.runtime.flavor`, and `dev.release.channel`. Field-level atom allowlists
and forensic JSONL-only rules are in [OTLP Projection](#otlp-projection).

## Progressive Disclosure For Debugging

When explaining or debugging AgentStudio observability, start by separating the
control surfaces before naming specific events:

```text
instrumentation selection  -> AGENTSTUDIO_TRACE_TAGS
sink selection             -> AGENTSTUDIO_TRACE_BACKEND + OTLP endpoint/protocol
global preferences         -> <AppDataPaths.rootDirectory()>/preferences.global.json
data root locator          -> AGENTSTUDIO_DATA_DIR
proof identity             -> AGENTSTUDIO_OBSERVABILITY_* state file
                             + marker + launch proof token
Victoria proof             -> marker/token-scoped logs and metrics queries
```

Then select one slice:

```text
atom emitter
  -> AgentStudioTraceTag.atoms
  -> AgentStudioTraceRuntime
  -> JSONL / OTLP sinks
  -> source-side OTLP projection
  -> VictoriaLogs + VictoriaMetrics under the current marker/token
```

Only after that should the explanation name concrete event bodies, attributes,
series names, or query strings. This prevents backend variables, proof-state
variables, and instrumentation flags from being blurred into one bucket.
