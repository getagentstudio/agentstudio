# AgentStudio Global Observability Preferences Spec

Status: Draft for review
Date: 2026-06-26

## Problem

AgentStudio already has a good local observability producer path, but ordinary
stable and beta app startup is controlled only by environment variables and
channel defaults. The local operator need is a durable global preference that can
make stable and beta start with full local OTLP observability by default, while
preserving environment-variable override authority for proof launchers and one-off
debug runs.

This is not a keybindings problem and not a workspace-settings problem. The
setting is global to the app identity that is starting.

## Global Preferences Reader Map

Global preferences are app-root scoped. They are not workspace scoped.

```text
File:
  <AppDataPaths.rootDirectory()>/preferences.global.json

Root owner:
  AppDataPaths

Startup composition owner:
  App/Boot global-preferences bootstrap code

Common file loader:
  App/Boot/GlobalPreferencesBootstrap.swift

Trace interpretation owner:
  Infrastructure/Diagnostics/AgentStudioTraceConfiguration.swift
```

Examples:

```text
stable app       ~/.agentstudio/preferences.global.json
beta app         ~/.agent-studio-b/preferences.global.json
raw debug build  ~/.agentstudio-db/preferences.global.json
debug app        ~/.agentstudio-db/<debug-code>/preferences.global.json
custom root      $AGENTSTUDIO_DATA_DIR/preferences.global.json
```

The file contains durable app-wide defaults, starting with:

```text
schemaVersion
observability
```

The file does not contain:

```text
AGENTSTUDIO_DATA_DIR
keybindings
workspace settings
proof markers
trace output directories
collector health helper paths
```

## Success Criteria

1. AgentStudio can load observability preferences from a schema-defined
   `preferences.global.json` file before `AgentStudioTraceRuntime` is created.
2. Environment variables remain the highest-precedence layer and can override or
   disable any file-backed observability preference for a single launch.
3. Stable and beta can be configured locally to start with full OTLP logging to
   the shared local stack without hand-written shell wrappers.
4. The enabled preference path is fast: preference loading is a bounded local file
   read and schema decode only. It does not preflight the collector, touch
   workspace state, scan directories, or initialize UI/state systems.
5. Startup proof includes profiling evidence that the preferences layer does not
   materially slow app launch.
6. OTLP remains aligned with the shared stack contract: loopback HTTP endpoint,
   HTTP/protobuf transport, app-owned source-side scrubbing, ordinary startup
   fail-open.

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

## Current Evidence

- `main.swift` creates `AgentStudioTraceRuntime.fromEnvironment()` before
  Ghostty startup and before `NSApplication` creation, so preferences that affect
  tracing must load before that point.
- `AgentStudioTraceConfiguration` currently resolves trace tags, backend, flush
  mode, OTLP endpoint, and OTLP protocol from environment variables only.
- `AgentStudioTraceRuntime` builds its sinks once during initialization; tag,
  backend, endpoint, and flush changes are restart-required for the first slice.
- `AppDataPaths.rootDirectory()` is the owner for app-global state. It resolves
  `AGENTSTUDIO_DATA_DIR` first, then channel/debug defaults.
- The debug observability launcher computes a per-worktree debug code and passes
  `AGENTSTUDIO_DATA_DIR=$HOME/.agentstudio-db/<debug-code>`. Debug preferences
  therefore live under that effective app root, not directly under
  `~/.agentstudio-db`.
- The architecture target already reserves root-level `preferences.global.json`
  for true global app preferences and keeps keybindings separate.
- The shared local observability stack expects loopback collector URLs and
  HTTP/protobuf OTLP. AgentStudio appends `/v1/logs`, `/v1/metrics`, and
  `/v1/traces` from the collector base URL.

Source anchors:

- `Sources/AgentStudio/main.swift:24-32`
- `Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceConfiguration.swift:127-176`
- `Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceConfiguration.swift:219-334`
- `Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTraceRuntime.swift:48-56`
- `Sources/AgentStudio/Infrastructure/AppDataPaths.swift:44-60`
- `scripts/run-debug-observability.sh:464-476`
- `scripts/run-debug-observability.sh:631-688`
- `docs/architecture/structure/component_architecture.md:576-598`
- `docs/architecture/observability/observability_and_traceability.md:11-21`
- `docs/architecture/observability/observability_and_traceability.md:43-56`
- `Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioOTLPBootstrapper.swift:92-183`

## Design Contract

### Configuration Source Taxonomy

The design separates three things that are easy to blur:

```text
App root selection
  decides where app-owned files live
  source: AGENTSTUDIO_DATA_DIR plus channel/debug defaults
  owner: AppDataPaths
  not a preference

Global preferences
  durable user/operator defaults loaded from the selected app root
  source: <AppDataPaths.rootDirectory()>/preferences.global.json
  owner: App/Boot global-preferences bootstrap code

Launch overrides
  one-run environment overrides for tracing/proof
  source: ProcessInfo.processInfo.environment
  owner: AgentStudioTraceConfiguration resolution layer
```

`AGENTSTUDIO_DATA_DIR` is not represented in `preferences.global.json`. It is
the location selector that must be resolved first so the app knows which
`preferences.global.json` file to read.

### Preference File Location

The file is always:

```text
<AppDataPaths.rootDirectory()>/preferences.global.json
```

That means:

```text
stable default    ~/.agentstudio/preferences.global.json
beta default      ~/.agent-studio-b/preferences.global.json
raw debug build   ~/.agentstudio-db/preferences.global.json
debug app launch  ~/.agentstudio-db/<debug-code>/preferences.global.json
custom launch     $AGENTSTUDIO_DATA_DIR/preferences.global.json
```

The path rule is intentionally expressed through `AppDataPaths.rootDirectory()`,
not hard-coded per channel. The existing app identity/data-root system remains
the source of truth.

`raw debug build` means running the DEBUG binary without a data-root override.
`debug app launch` means the existing generated debug app path used by the
debug observability launcher. That launcher computes the per-worktree
`<debug-code>` and passes `AGENTSTUDIO_DATA_DIR`, so the generated debug app gets
its own app root and therefore its own `preferences.global.json`.

### Source Matrix

```text
Concern                         Durable preference?  Env override?  Code owner
------------------------------  -------------------  -------------  -----------------------------
app data root location           no                   yes            AppDataPaths
observability enabled            yes                  no             App/Boot bootstrap + TraceConfiguration
trace tag selection              yes                  yes            AgentStudioTraceConfiguration
trace backend selection          yes                  yes            AgentStudioTraceConfiguration
trace flush mode                 yes                  yes            AgentStudioTraceConfiguration
OTLP endpoint base URL           yes                  yes            AgentStudioTraceConfiguration
OTLP protocol                    no                   compatibility  AgentStudioTraceConfiguration
trace name / proof marker        no                   yes            proof launchers + TraceConfiguration
trace output directory           no                   yes            proof/debug launch inputs
observability proof state file   no                   yes            proof launchers/verifiers
collector health URL/helper      no                   yes            proof launchers/verifiers
```

`compatibility` for `OTEL_EXPORTER_OTLP_PROTOCOL` means the current environment
surface may continue to accept the one supported value, `http/protobuf`, and
reject anything else. It does not mean protocol becomes a durable preference.

### Code Organization

The implementation should make source ownership visible in the filesystem:

```text
Sources/AgentStudio/Infrastructure/AppDataPaths.swift
  existing app root resolver
  owns AGENTSTUDIO_DATA_DIR and channel/debug root selection

Sources/AgentStudio/App/Boot/
  GlobalPreferencesBootstrap.swift
    app-level composition point for startup preferences
    resolves the app root through AppDataPaths
    loads preferences.global.json from that app root
    decodes GlobalPreferencesPayload / GlobalObservabilityPreferences
    maps observability fields into the Diagnostics-owned trace preference layer
    passes that layer into trace configuration
    does not own trace tag parsing, endpoint policy, or sink behavior

  GlobalPreferencesPayload.swift
    schemaVersion and top-level global preference schema

  GlobalObservabilityPreferences.swift
    Codable schema for the observability object
    holds raw durable preference values only
    does not parse tags, select sinks, or reference trace runtime types

Sources/AgentStudio/Infrastructure/Diagnostics/
  AgentStudioTracePreferenceLayer.swift
    owns the trace-facing preference layer shape
    no dependency on App/Boot payload types

  AgentStudioTraceConfiguration.swift
    resolves channel defaults + observability preference layer + env override layer

  AgentStudioTraceRuntime.swift
    unchanged sink/runtime owner; consumes effective configuration only

Sources/AgentStudio/main.swift
  calls the app-level bootstrap helper before trace runtime construction
```

Test homes should mirror this split:

```text
Tests/AgentStudioTests/App/Boot/
  GlobalPreferencesBootstrapTests.swift

Tests/AgentStudioTests/Infrastructure/Diagnostics/
  AgentStudioTraceConfigurationTests.swift
  AgentStudioTraceConfigurationPreferencesTests.swift
```

This deliberately keeps global preferences out of
`Core/State/MainActor/Persistence/WorkspaceSettingsStore.swift`. That store owns
workspace-scoped settings files under `workspaces/`; it is not on the earliest
process-start path and should not become the trace bootstrap dependency.

The intended file dependency DAG is:

```text
main.swift
  -> GlobalPreferencesBootstrap

GlobalPreferencesBootstrap
  -> AppDataPaths
  -> GlobalPreferencesPayload / GlobalObservabilityPreferences
  -> Foundation JSON/file APIs
  -> AgentStudioTracePreferenceLayer
  -> AgentStudioTraceConfiguration

GlobalPreferencesPayload / GlobalObservabilityPreferences
  -> Foundation only

AgentStudioTracePreferenceLayer
  -> Foundation only

AgentStudioTraceConfiguration
  -> AgentStudioTracePreferenceLayer
  -> AgentStudioTraceTag / backend / endpoint parsing

AgentStudioTraceRuntime
  -> AgentStudioTraceConfiguration
  -> sinks
```

Forbidden dependency edges:

```text
GlobalPreferencesBootstrap -> Core/State
GlobalPreferencesBootstrap -> Features
GlobalPreferencesBootstrap -> OTel sinks/runtime
GlobalPreferencesPayload   -> Infrastructure/Diagnostics
GlobalPreferencesPayload   -> App/Core/Features
AgentStudioTraceConfiguration -> App/Boot
WorkspaceSettingsStore     -> trace bootstrap
```

This keeps the startup load local to app boot and cheap. The bootstrap file
resolves the app root, reads one file, and decodes schema. It does not interpret
observability semantics. Diagnostics owns interpretation because trace tags,
backends, endpoint policy, and sink behavior already live there.

`GlobalPreferencesBootstrap` is the composition seam that makes the app startup
load easy to find. The tiny file loader is colocated in the same `App/Boot`
file because this is launch-specific composition, not a general infrastructure
service. It remains workspace-independent and trace-runtime-independent.
The boundary handshake is a Diagnostics-owned value type, not an App/Boot
payload type, so the import direction remains App -> Infrastructure.

### Schema

Version 1 adds a single global observability object:

```json
{
  "schemaVersion": 1,
  "observability": {
    "enabled": true,
    "traceTags": "*",
    "traceBackend": "otlp",
    "traceFlush": "buffered",
    "otlpEndpoint": null
  }
}
```

Field contract:

```text
schemaVersion   required integer, currently 1

observability.enabled
                required boolean
                false means no trace tags from preferences

observability.traceTags
                optional string
                same selector grammar as AGENTSTUDIO_TRACE_TAGS
                default when enabled=true: "*"

observability.traceBackend
                optional enum: "otlp", "jsonl", "both"
                default when enabled=true: "otlp"

observability.traceFlush
                optional enum: "buffered", "immediate"
                default when enabled=true: "buffered"

observability.otlpEndpoint
                optional string or null
                null/missing means AgentStudioTraceConfiguration.defaultOTLPEndpoint
                non-null values must pass the existing loopback HTTP endpoint policy
```

There is no `otlpProtocol` field in preferences. The app and the shared stack use
HTTP/protobuf. The existing `OTEL_EXPORTER_OTLP_PROTOCOL` environment handling
may remain as a validation/override compatibility surface, but unsupported values
must not become a persisted preference option.

### Defaults

There are two different defaults, and the spec keeps them separate:

```text
Absent preferences file:
  preserve current channel defaults
  stable -> tracing disabled unless env selects tags
  beta/debug -> existing safe baseline unless env selects tags

Present observability object with enabled=true:
  traceTags    "*"
  traceBackend "otlp"
  traceFlush   "buffered"
  otlpEndpoint default loopback collector base URL
```

The local operator file can therefore make stable and beta fully observable
without changing the app's factory behavior for every install.

### Resolution Order

Effective trace settings are resolved in this order:

```text
channel defaults
  -> preferences.global.json observability layer
  -> environment override layer
  -> AgentStudioTraceConfiguration
  -> AgentStudioTraceRuntime
```

Environment variables remain authoritative:

```text
AGENTSTUDIO_DATA_DIR
  selects the app data root before preferences are loaded
  not an observability preference and not part of preferences.global.json

AGENTSTUDIO_TRACE_TAGS
  overrides observability.traceTags
  value "off" disables all tags for this launch

AGENTSTUDIO_TRACE_BACKEND
  overrides observability.traceBackend

AGENTSTUDIO_TRACE_FLUSH
  overrides observability.traceFlush

OTEL_EXPORTER_OTLP_ENDPOINT
  overrides observability.otlpEndpoint

OTEL_EXPORTER_OTLP_PROTOCOL
  accepted only for the already-supported HTTP/protobuf transport
```

There is intentionally no `AGENTSTUDIO_OBSERVABILITY_ENABLED` environment
variable. A launch override should use the existing trace selection surface:
`AGENTSTUDIO_TRACE_TAGS=off` disables tracing for one launch, and
`AGENTSTUDIO_TRACE_TAGS=<selector>` enables/replaces the durable tag selector for
one launch.

Resolution cases:

```text
File state                    Env trace tags       Effective tag source
----------------------------  -------------------  --------------------------------------------
file missing                  unset                channel default
enabled=false                 unset                disabled by preferences
enabled=false                 "*" or selector      enabled by env for this launch
enabled=true, traceTags null  unset                preferences default "*"
enabled=true, traceTags set   unset                preferences traceTags
any                           "off"                disabled by env for this launch
any                           "*" or selector      env traceTags for this launch
```

Environment backend, flush, endpoint, and protocol variables override only their
matching effective fields. They do not change where preferences are loaded, and
they do not become durable settings. Invalid OTLP endpoints follow the existing
fail-open trace configuration policy: remote/non-loopback endpoints are rejected,
the app continues, and OTLP output is not attempted for that invalid endpoint.

Proof-specific variables such as `AGENTSTUDIO_TRACE_NAME`,
`AGENTSTUDIO_TRACE_DIR`, `AGENTSTUDIO_TRACE_PROOF_TOKEN`, and
`AGENTSTUDIO_OBSERVABILITY_*` state-file variables are not global preferences.
They remain launch/proof handoff inputs.

### Startup Flow

```text
main.swift
  -> GlobalPreferencesBootstrap.loadStartupPreferences(environment)
       -> AppDataPaths.rootDirectory(environment, channel, debug)
       -> read root/preferences.global.json
       -> GlobalPreferencesPayload / GlobalObservabilityPreferences
       -> AgentStudioTracePreferenceLayer
  -> AgentStudioTraceConfiguration.resolve(defaults, tracePreferenceLayer, env)
  -> AgentStudioTraceRuntime(configuration)
  -> AgentStudioStartupTraceRecorder
  -> GhosttyStartupEnvironment.apply()
  -> ghostty_init(...)
```

The loader is intentionally earlier and smaller than the eventual UI-facing
preferences store. It reads the global file because tracing must be decided
before most app systems exist.

### Loader Requirements

The global preference loader must be systematic and startup-safe:

1. Read exactly one file path under the effective app root.
2. Treat a missing file as absent preferences, not as an error.
3. Enforce a small file-size cap before decoding, such as 64 KiB.
4. Decode with Foundation JSON APIs into typed `Codable` schema structs.
5. Validate enum values, endpoint shape, and schema version before resolving.
6. Treat malformed, oversized, unsupported-schema, or invalid-field files as
   absent for startup purposes. Valid environment overrides still apply after
   this fail-open fallback.
7. Never contact the collector from the ordinary app loader.
8. Never load workspace state, atoms, keybindings, or UI stores from this path.
9. Never write or migrate the file during ordinary trace configuration load.

The loader must return a typed result so tests and startup diagnostics can
distinguish failure classes without scraping logs:

```text
missing
loaded(schemaVersion, observabilityEnabled, elapsed)
invalidMalformedJSON(elapsed)
invalidUnsupportedSchema(elapsed)
invalidOversized(elapsed)
invalidEndpoint(elapsed)
readFailed(elapsed)
```

If tracing is enabled after final resolution, startup telemetry may include the
loader result as low-cardinality fields. If tracing is disabled, deterministic
unit/config tests remain the proof surface for these result cases. Diagnostics
must not export the raw preferences path, symlink target, JSON content, or parse
error text over OTLP.

File mutation by agents or a future settings UI is fine, but the first slice is
load-on-app-start only. Applying changed preferences requires restart.

### Ownership Boundaries

```text
GlobalPreferencesBootstrap
  owns: app-root preference file read and schema decode during startup
  does not own: trace sinks, OTLP transport, workspace settings, keybindings

AgentStudioTraceConfiguration
  owns: default + preferences + env resolution into effective trace config
  does not own: filesystem I/O

AgentStudioTraceRuntime
  owns: sink construction and trace dispatch from an already-resolved config
  does not own: reading preferences or watching files

run-debug-observability / run-beta-observability
  own: strict proof launch env and stack health preflight
  do not own: ordinary app preferences schema

shared ai-tools observability stack
  owns: collector, Victoria services, retention, smoke checks
  does not live in this repo
```

## Performance Contract

Preferences loading is on the cold-start path, so the implementation must prove
it is cheap.

Startup constraints:

```text
No network I/O
No directory traversal
No workspace database/file reads
No MainActor dependency
No async task startup
No collector health check
No schema migration writes
One bounded JSON file read at most
```

Profiling proof expectations:

1. Unit-level loader tests cover missing, valid enabled, valid disabled,
   malformed JSON, unsupported schema, oversized file, invalid endpoint, and env
   precedence.
2. A focused performance/profiling proof measures preference load resolution for
   missing, valid, and invalid files and reports p50/p95/max elapsed time. The
   initial pass/fail budget is p95 <= 2 ms and max <= 10 ms over at least 1,000
   iterations for files at or below the 64 KiB cap on the local development Mac.
3. A startup proof compares app startup with no preferences file and with an
   enabled full-OTLP preferences file. Use at least five launches for each case
   under the same harness. The initial pass/fail budget is enabled median delta
   <= 25 ms and enabled max delta <= 75 ms relative to the no-preferences run
   set. If the harness itself is noisier than that, the plan must capture raw
   samples, attribute the variance, and stop for design review instead of
   silently weakening the startup contract.
4. The profiling path should reuse the current marker-scoped VictoriaMetrics
   style when possible. Current performance proof already queries p95/max elapsed
   metrics by marker; preferences startup proof should follow that pattern rather
   than relying on stale JSONL.
5. If a new startup performance event is added, it should be low-cardinality and
   safe for OTLP, for example:

```text
event: app.preferences.global.loaded
tag: app.startup
fields:
  agentstudio.preferences.global.status = missing | loaded | invalid | oversized
  agentstudio.preferences.global.schema_version = 1
  agentstudio.preferences.global.observability.enabled = true | false
  agentstudio.preferences.global.load.elapsed_ms = <number>
```

The event must not export raw file paths or raw JSON content.

## Required Proof Gates For Planning

The implementation plan must define concrete commands and expected evidence for
each gate below:

```text
Unit/config gate
  schema decoding, root/path resolution, result classification, env precedence,
  endpoint validation, and disabled/enabled semantics

Integration/file gate
  real filesystem reads for missing, valid, invalid, oversized, unreadable, and
  custom AGENTSTUDIO_DATA_DIR roots

Preference-honoring debug gate
  generated debug app launches from its effective debug data root with
  preferences.global.json selecting full OTLP; the launch must not pass trace
  selection env such as AGENTSTUDIO_TRACE_TAGS, AGENTSTUDIO_TRACE_BACKEND,
  AGENTSTUDIO_TRACE_FLUSH, OTEL_EXPORTER_OTLP_ENDPOINT, or
  OTEL_EXPORTER_OTLP_PROTOCOL

Strict debug proof gate
  existing run-debug-observability path continues to prove env override and
  fail-fast shared-stack behavior

Preference-honoring beta gate
  beta app identity launches from its effective beta data root with
  preferences.global.json selecting full OTLP and no trace-selection env
  overrides

Stable/prod local gate
  stable-channel app identity launches with an isolated AGENTSTUDIO_DATA_DIR
  containing preferences.global.json and no trace-selection env overrides. If a
  stable artifact cannot be produced in the branch context, the plan must define
  the closest accepted local stable substitute or record an explicit blocker.

Startup profiling gate
  loader micro-benchmark plus app startup comparison using the budgets in this
  spec

E2E observability gate
  app starts, records the global-preferences load status, exports expected
  OTLP logs/metrics through the shared Victoria stack, and shows no visible
  startup failure

PR/release-readiness gate
  PR checks, implementation review, review-thread state, mergeability, and beta
  deploy/release artifact proof only when merge or release promotion is
  explicitly authorized
```

The strict debug/beta launchers may continue injecting trace env for their
current purpose. They are not sufficient by themselves to prove that the
preferences file controls app startup.

## Security And Privacy

The preferences file can only point OTLP at loopback HTTP endpoints. Remote
endpoints, HTTPS collectors, arbitrary hosts, and custom protocols are rejected
by the same policy as environment endpoints.

The preference file must not expand the OTLP projection allowlist. Raw paths, raw
UUIDs, prompts, payloads, errors, terminal output, tool output, and tokens remain
out of OTLP. Full local observability means full tag selection through the
existing scrubbed projection, not unsanitized export.

> #26 supersedes the export-filter contract in the historical passage above.
> [The current OTLP contract](../../architecture/observability/observability_and_traceability.md#otlp-projection)
> exports every recorded attribute under its recorded name and value. Upstream
> message-text and credential restrictions, and Bridge ingress validation, still apply.

Threat model:

```text
Asset
  local prompts, terminal output, tool output, file paths, tokens, and app
  startup reliability

Entry point
  same-user local file at <AppDataPaths.rootDirectory()>/preferences.global.json

Trust boundary
  the file is operator/agent-controlled local configuration, not trusted remote
  input and not privileged policy

Accepted local behavior
  same-user agents may edit or symlink the preferences file as local
  configuration. The loader still enforces the size cap, schema validation,
  read-error handling, and endpoint policy, and it must not export the resolved
  path or symlink target.

Controls
  bounded read, typed JSON schema, unsupported schema rejection, loopback-only
  endpoint policy, no persisted protocol option, no collector preflight, no
  workspace or atom dependency, and fail-open startup
```

Ordinary app startup is fail-open:

```text
collector absent       -> app continues
exporter/bootstrap err -> app continues
invalid preferences    -> app uses channel defaults plus valid env overrides
                          and continues
```

Strict proof launchers remain fail-fast for collector health and identity
handoff, because proof requires a reachable shared stack and a fresh marker.

## Non-Goals

- No keybinding schema changes.
- No workspace-scoped observability settings.
- No live reload or file watcher in the first slice.
- No UI settings panel requirement in the first slice.
- No new per-emitter environment variables.
- No remote OTLP endpoint support.
- No persisted OTLP protocol option.
- No collector, Victoria, Docker Compose, or shared-stack ownership in this repo.
- No expansion of exported OTLP fields just because trace tags are `*`.

## Open Decisions

None blocking for the first implementation plan.

The plan may still choose exact helper names and exact command wiring, but it
must preserve the schema, precedence, path, startup, performance, security, and
proof contracts above.

## Review Route

`spec-review-swarm` completed on 2026-06-26. Accepted findings were folded into
this spec, and the review report is recorded at
`tmp/spec-review-swarms/2026-06-26-agentstudio-global-observability-preferences/review-report.md`.

Next step: use `plan-creation-swarm` to map this contract to implementation
tasks and proof gates.
