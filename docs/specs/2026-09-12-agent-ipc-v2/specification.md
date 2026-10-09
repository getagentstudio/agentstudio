# Agent IPC v2 and Agent Package — Specification

Date: 2026-09-16. **Amended 2026-10-07** (owner, stopgap until a daemon owns pane tokens): a pane verifier is written durably when it's issued, so an abrupt app end no longer loses it (credential continuity below).
Requirements: [user-requirements.md](user-requirements.md).
Authority and rationale: [decision-record.md](decision-record.md).
Structural realization: [program-design.md](program-design.md).

## Product contract

Agents in ordinary Agent Studio panes receive their app identity through the
environment. They report status and send messages through a small model-facing
CLI surface. Hooks and tools use the full typed JSON-RPC catalog through the
same Swift CLI. Sessions supplies ingest, durable state and queries; its pane
UI is later. Debug-channel automation additionally controls existing app
features through an explicitly classified testing surface.

| Problem | Outcome |
| --- | --- |
| P1 — A pane agent lacks a usable app identity and invocation contract, while making that identity durable can delay unrelated terminal use. | O1 — It identifies its own scope, reports and sends messages without hand-typed identifiers; normal startup and terminal use remain independent of IPC readiness. |
| P2 — Provider activity does not uniformly establish agent state. | O2 — Each fact has qualified origin, matching context and honest freshness. |
| P3 — Messages and attention must outlive app availability. | O3 — Durable messages survive restart; offline notifications are collected; no message drops. |
| P4 — Native integration and testing vary by provider and surface. | O4 — One package installs the native integrations; one typed CLI serves tools and debug tests without a second catalog. |

Current evidence: ordinary terminal startup supplies zmx isolation but no pane
IPC identity in [terminal startup](../../../Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator+ViewLifecycle.swift).
The existing [registry](../../../Sources/AgentStudioAppIPC/AgentStudioIPCRegistryAuthorization.swift),
[authentication](../../../Sources/AgentStudioAppIPC/AgentStudioIPCAuthentication.swift)
and [client core](../../../Sources/AgentStudioIPCClientCore/AgentStudioIPCClientCore.swift)
provide the foundation; current method schemas and client mappings do not yet
satisfy the contracts below.

### Journeys

```text
C2 — Pane agent (U1, U3, U8, U12, U20, U22)
Start -> read env -> skill guard -> discover context -> report/message -> continue
Pain: no ordinary-pane IPC identity; argument and target ceremony.
Difference: scalar model calls, self context and short replies; tooling alone
uses the full catalog. Evidence: startup source above and Requirements E-IPC.

C1 — Developer (U7–U10, U12–U15, U21)
Start agents -> leave -> question/message -> return -> inspect -> respond in pane
Pain: missing or uncertain state and lost delivery while the app is absent.
Difference: query attributed messages and attention after restart; current state
never silently follows stale evidence. Sessions pane UI is a later surface.
Evidence: Requirements E-SPEC, E-OWNER and its C1 sequence.

C3 — Installer/operator (U5)
Install once -> inspect per-provider outcome -> run native integration -> uninstall
Pain: provider-specific configuration and uncertain activation.
Difference: exact package ownership, preserved unrelated config, explicit limits.
Evidence: Requirements E-HOOKS, E-GHOSTEX and its C3 sequence.
```

C4 maintainers consume exhaustive catalog and boundary checks. S1 is a future
adapter stakeholder, not a round-1 ACP user.

```text
Native providers / pane agents -- hooks + skill --> Swift agentstudio CLI
                                                       |
                                    env + JSON-RPC / local Unix socket
                                                       v
                                                [Agent Studio]
Developer <---- Sessions query: message / state / attention ---+
Debug test agent <---- debugTesting actions and results -------+
Installer/operator <---- native install/uninstall outcomes -----+
Maintainer / future adapter <---- typed catalog ----------------+

Excluded: Studio-to-agent steering, Inbox delivery, remote hosts, screen scraping.
Reserved only: file.open boundary; no discovery entry or implementation here.
```

## Normative obligations

R identifiers own active obligations. C identifiers below own their detailed
observable contracts, and V identifiers name proof modalities. The U basis
resolves to the distinct Requirements source.

### Identity and wire

| ID | Obligation and observable failure boundary | Basis; contract; proof |
| --- | --- | --- |
| R-01 | Every ordinary genuinely new pane shell MUST receive pane/workspace IDs, socket location and a pane-scoped credential through its environment without a special agent launch. Restoration or attachment to an existing zmx shell MUST preserve that shell's original environment and credential rather than issue a replacement. At a ready IPC endpoint, a genuinely new shell MUST authenticate while durable verifier registration is deliberately delayed. If bounded identity creation or authority registration fails, the terminal MUST still start and the integration MUST report unavailable. The package guard MUST decline missing or invalid context without guessing a target. | U1, U24; A, AA, AC; C1; V1/V10 |
| R-02 | One pane-bound principal MUST serve reporting and control. Self-pane baseline actions need no additional grant; no pane grants are issuable in round 1. Cross-pane/workspace requests MUST return missing-grant with the required scope. Channel-bound diagnostic authority is separate and MUST NOT upgrade a pane principal. | U1, U16; A, M, S; C1/C4; V1/V4 |
| R-03 | Undo-eligible pane close MUST immediately deny all requests and close leases for the retained shell because the closed pane is not canonically eligible. Undo of that same retained shell MUST restore eligibility for the same credential only after canonical pane/workspace membership is restored. Discard or undo expiry MUST revoke every credential for that logical pane permanently; neither a request nor delayed work may restore a revoked or nonmember pane. Continuing agents in restored panes retain reporting continuity when their existing verifier was durable. Reattachment MUST NOT inspect IPC, replace the credential or rewrite the running shell. A genuinely new shell may receive the current app runtime's pane token and need not recover an old raw token. Previously durable verifier credentials for the same canonical live pane remain valid; issuing another credential MUST NOT automatically supersede them. Undo-closed, revoked, forged or unknown credentials fail all requests. If any process ends before a credential becomes durable — including an otherwise normal exit after optional schema or storage failure — the next app MUST reject that continuing shell's unknown credential, report IPC explicitly unavailable, and keep IDE/terminal recovery usable; the shell remains without IPC until a new shell is created. Authentication rejection MUST NOT trigger spooling. | U1, U14, U16, U21, U24; A, K, U, AA, AB, AC; C1/C6/C8; V1/V7/V10 |
| R-04 | IPC v2 MUST use JSON-RPC 2.0 over the existing local socket and make a hard cutover from phase-1 argument shapes. Exposed methods MUST have agent-friendly explicit inputs, not implicit picker or focused-UI arguments. | U3, U4, U19; B, J; C2; V2 |
| R-05 | App commands MUST retain one AppCommand identity and exhaustive ipcSpec classification. Curated user-visible methods MUST declare reuse of that identity or an explicit no-interactive-identity relationship. Current session/report methods have no interactive identity. Typed command.execute MUST reject non-headless execution in stable/beta and expose every AppCommand with typed debug variants in debug; presentation success MUST NOT mean command completion. | U3, U4, U19; B, S, Z; C2/C4; V2/V4 |
| R-06 | One discovery call MUST return the complete available method catalog with JSON Schema params/results, descriptions, examples, required privileges, target kinds and compatibility identity. Missing schema, hidden defaults or non-executable examples fail the contract. | U3, U4, U19; J, R, T; C2; V2 |
| R-07 | Errors MUST have stable reasons and machine-readable correction data for invalid input, missing grants, wrong targets, unknown methods/commands and version skew. Unknown identifiers MUST yield protocol errors, never opaque client enum/decode failures. | U3, U4, U19, U20; C2/C8; V2 |
| R-08 | Methods MUST share the spellings self, UUID and pane:N while separately declaring target kinds. Pane, workspace, conversation/session, message occurrence and needs-you request are distinct kinds; existing catalog kinds remain explicit. Wrong kinds MUST fail without falling back to focus. | U1, U3, U4, U16, U19; C1/C2; V1/V2 |
| R-09 | Every mutation/report MUST require a correlation ID on the wire; the CLI MUST generate one when omitted by its caller, and responses MUST echo it. For reports and messages, equivalent retries MUST NOT duplicate occurrences and conflicting correlation reuse MUST fail before evidence or derived state changes; for reports carrying a provider occurrence ID, equivalent occurrence reuse under a new correlation MUST return the retained outcome. Controls carry no replay guarantee in round 1: a repeated correlation is a new request, and a caller that loses the response treats the outcome as uncertain (decision AD). | U14, U19–U22; Q, AD; C2/C3/C5/C6; V2/V3/V6/V7 |

### Agent DX and model token economy

Schema DX concerns tooling. Model token economy is a separate pass/fail rubric:
a catalog can be excellent while a model-facing invocation still wastes tokens.

| ID | Obligation and observable failure boundary | Basis; contract; proof |
| --- | --- | --- |
| R-10 | The Swift agentstudio CLI MUST ship in this repo's app bundle under its signing/notarization boundary. Hook/tool verbs, argument parsing, help and schemas MUST derive from the same compiled descriptor definitions the server registers, without a hand-maintained mapping or JSON-export generation step. It MUST provide one invocation per method, AGENTSTUDIO_CLI as the owning bundle executable path with its directory prepended to pane PATH, pane-env defaults, --json/stdin input, structured results/errors and no bearer token argv. | U19, U20; R, T; C2; V2 |
| R-11 | Model commands MUST take plain scalar arguments and require no model-authored JSON, pane ID, correlation ID, request ID or sequence. The deliberate model vocabulary MUST be needs-you, needs-you --clear and done; message is the sole free-text message operation. Targeting and identifiers MUST be supplied by the CLI/app context. | U8, U13, U22; Q; C3; V3 |
| R-12 | Each model call MUST return one short line unless detail is explicitly requested. Catalog dumps, query pages, raw IDs and protocol envelopes MUST NOT appear in its default reply. | U22; Q; C3; V3 |
| R-13 | Debug MUST expose every AppCommand through typed command.execute, including interactive and presentation-only variants, plus curated layout/terminal/bridge/ui/snapshot and acknowledgment testing methods. Discovery MUST label debugTesting; stable/beta MUST refuse debug-only variants while retaining headless-only exposure. Debug MUST write an owner-only reusable runtime-bound credential when its off-critical-path IPC service becomes ready, verify its SHA-256 verifier on every CLI call, and revoke/delete it at shutdown or runtime replacement. Authenticated debug calls MUST use the existing automation-client principal kind with the current authenticated same-user access mode; they MUST NOT acquire unsafe-no-auth provenance. Stable/beta MUST never write the credential. The CLI MUST discover a single running debug app without flags, tokens or paths to assemble, use plain arguments and short replies, and require explicit selection if multiple debug apps exist. | U3, U4, U20, U23, U24; S, Y, Z, AA; C4; V4/V10 |

### Package, facts and delivery

| ID | Obligation and observable failure boundary | Basis; contract; proof |
| --- | --- | --- |
| R-14 | One package MUST install the appropriate native hook/skill/plugin for Claude Code, Codex CLI and Cursor CLI. Install/upgrade MUST preserve unrelated settings and avoid duplicates; uninstall MUST remove exactly package-owned additions and disclose conflicting edits. Outcomes and activation limits MUST be per provider. | U5; D1/D2; C5; V5 |
| R-15 | Lifecycle reports MUST represent session start/end, turn start/done/abort, permission/question/elicitation needs-you, tool and subagent activity. Each provider/version/event capability MUST be qualified separately; unsupported capabilities MUST remain unknown. | U7, U12, U13; D3, E; C5; V6 |
| R-16 | State MUST use UNKNOWN, RUNNING, NEEDS YOU and DONE with the evidence precedence and matching rules in C5. Origin is server-assigned REPORTED, AGENT REPORTED or ESTIMATED; weaker, replayed, old-turn, old-generation or cross-context facts MUST NOT rewrite stronger current evidence or duplicate results. Typed terminal facts MUST use their qualified provider meaning; screen content is excluded. | U7, U12, U14; E; C5; V6 |
| R-17 | Needs-you MUST remain observe-only, with durable/queryable request identity and matching resolution. The app MUST derive a model report's request ID and coalesce one current deliberate assertion per conversation/generation; clearing that assertion MUST need no model-typed ID. Report handling MUST NOT answer, approve, deny or wait on Studio for a provider response. | U7, U13, U22; D3, H, Q; C3/C5; V3/V6 |
| R-18 | Bound agents MUST be able to send arbitrary text. Accepted messages MUST preserve that text exactly and remain durably attributable and queryable through Sessions. They MUST NOT be reduced to content-free status or a single replacement status. | U8, U15, U21; D4, G; C6; V7 |
| R-19 | Sessions MUST own ingest/store/query and durable seen/attention state. New messages start unseen; only explicit acknowledgment of the exact occurrence marks them seen; round 1 ships no acknowledgment entry (in-process App entry and debug-channel session.message.ack deferred by decision AH until a consumer exists), so every message stays unseen until that entry lands. Pane principals MUST NOT acknowledge messages. Reads, delivery receipts, focus and input MUST NOT do so. Replays/restart preserve disposition and MUST NOT change unrelated messages or resolve needs-you. Derived-state rebuilding MUST preserve durable data; Inbox remains dormant. | U8, U14, U15; G, accepted seen-state contract; C6; V7/V8 |
| R-20 | When the app is unreachable (missing socket path, refused connection or dead/stale endpoint), the CLI MUST durably spool eligible notifications (message, needs-you, done) without bearer tokens; later IPC-side recovery admission MUST use the same semantics and mark them late without gating normal launch or terminal activation. Authentication and protocol rejection — including AB's unknown credential after a non-durable process end — MUST NOT trigger queuing. A notification that cannot be appended or durably accepted MUST return explicit failure; notifications MUST NOT be dropped after acceptance. Controls, queries, auth and needs-you --clear MUST never queue. Hook lifecycle state facts emitted while the app is unreachable are not collected in round 1. Live overload MUST return throttled/rejected outcomes and disclose state drops. Late notifications MUST NOT supersede newer live state; admitted lines MUST be removed after durable admission. | U14, U21, U24; K, U, X, AA, AB; C6/C8; V7/V10 |
| R-21 | Message/attention explanation text MUST NOT enter OTLP or JSONL telemetry/logs, including failures. Existing OTLP exclusions for raw paths, UUIDs, prompts, payloads, errors and tool output remain binding. The report surface MUST NOT ingest transcripts or terminal content. | U8, U9, U12, U15; D4; C3/C6/C8; V8 |
| R-22 | Integration loss, rejection and unavailable capability MUST fail open for the provider/terminal and disclose source health. A report cannot become a hidden provider control or answer-through dependency. | U5, U7, U12, U13; H; C5/C8; V5/V6 |
| R-23 | The typed catalog MUST project to MCP tools metadata without another semantic catalog. This MUST NOT require an MCP server, SDK or Rust CLI in round 1. | U19, U20; J, T; C2; V2 |
| R-24 | Round 1 MUST preserve the explicit negative space below. Deferred features MUST NOT acquire active endpoints, hidden workers or advertised capabilities merely because their contracts are documented. | U2, U6, U10, U11, U15, U18, U20; P, V, N; C7; V9 |
| R-25 | Normal IDE startup, first interactive frame, genuine new terminal construction and existing-zmx restoration/attachment MUST have no IPC-specific readiness wait, database operation, schema migration, socket/catalog publication or spool drain on their critical paths. Restoration MUST NOT replace or recover the running shell's token. Optional migration/catalog/socket work starts only after the existing first-frame and terminal-activation release edges; if those edges are unavailable or the optional work fails, IPC remains explicitly unavailable without new retry machinery. | U24; AA, AC; C1/C6/C8; V10 |

## Observable contracts

### C1 — Environment and authority

Ordinary genuinely new pane shells receive AGENTSTUDIO_PANE_ID, AGENTSTUDIO_WORKSPACE_ID,
AGENTSTUDIO_IPC_SOCKET, AGENTSTUDIO_PANE_TOKEN, AGENTSTUDIO_IPC_SPOOL_DIR and
AGENTSTUDIO_CLI. AGENTSTUDIO_CLI is the absolute path to the owning app bundle's
agentstudio executable, supplied by the runtime issuing the pane credential.
The environment also prepends that executable's directory to PATH, so the
skill's bare agentstudio calls select the owning stable/beta/debug bundle.
Hooks and the skill invoke through this declared location: AGENTSTUDIO_CLI is
the contract; PATH is its convenience projection, not an alternate authority.
At a ready IPC endpoint, this environment authenticates successfully while its
durable registration is deliberately delayed. Durable registration is not a
terminal-readiness condition. If bounded identity creation or immediate authority
registration fails, the terminal still starts and the package guard reports
integration unavailable. The same scope follows descendant agent/hook processes.
Cwd and window focus do not change identity. The credential is pane-scoped,
denied while Undo-closed and permanently revoked on discard/expiry; it is never
passed as argv, written to spool, or printed/logged by the integration.

Self means the authenticated pane; pane:N is workspace-local convenience,
not durable authority. UUIDs are interpreted against the declared target kind.
A known ID grants no access to another agent's data. Non-debug pane principals
receive the self baseline only; broader requests identify the missing scope.
No round-1 approval UI or policy issues pane grants. Message acknowledgment
accepts only the in-process App entry reserved for the future Sessions UI action
or the debug-channel testing principal. Pane principals cannot mark messages
seen, including their own; knowing an occurrence ID supplies no authority.

Credential continuity survives restart for continuing shells whose verifier was
durably registered before the prior process ended. Each pane verifier is written
durably when it's issued (owner, 2026-10-07; stopgap until a daemon owns pane
tokens), so a crash, force quit or SIGTERM no longer loses it. Before this, a
token never used for IPC was saved only at a normal quit, and its pane's shell
lost IPC after an abrupt end (finding #6, 2026-10-06). The write never blocks the
terminal. A credential still not durable when the process ends (an end in the
moment between issue and write, or a schema/storage failure) is an accepted
limitation: after relaunch it is unknown, every request fails
with explicit IPC-unavailable/authentication status, and the terminal remains
usable until a new shell supplies a new credential. That rejection never enters
the offline spool. Within one app runtime, IPC supplies one reused environment
token per logical pane; repeated mount/attachment preparation does not mint,
promote, order or supersede credentials. Existing-zmx restoration/attachment keeps the shell's original
environment and token; it does not preload, validate, rotate, replace, persist or
otherwise wait on IPC state. IPC verifies a presented token through its stored
hash on the request path. A genuinely new shell may receive a newly issued token
and does not need the old raw token recovered from storage. Previously durable
verifiers for that same canonical live pane remain valid until final revocation.
A forged scope, Undo-closed, revoked or unknown credential is not an authenticated
context. Undo-eligible close removes canonical request eligibility
and closes leases. Undo restores eligibility for that same retained-shell
credential only after canonical membership is restored; discard or expiry revokes
it permanently. No new persisted suspended state is required for renderer retention.
Offline files use the accepted same-UID filesystem trust boundary. Neither that
boundary nor a possessed current credential distinguishes malicious same-user
processes; the product claims no stronger process identity.

### C2 — Tooling CLI and protocol

The catalog exposes each method's types, defaults/bounds, descriptions,
examples, target/data scope, exposure class and result meaning. Commands share
AppCommand identity and an exhaustive ipcSpec projection. Their arguments are
a typed alternative per command, not an untyped catch-all bag. Method/command
identifiers stay open strings at version-skew boundaries.

Hooks/tools invoke catalog methods through agentstudio with --json or stdin.
The CLI reads pane env or the selected existing diagnostic auth context, supplies
missing correlation, checks response IDs and returns structured output. It uses
compiled descriptors, not a generated JSON file or another verb table. The
JSON representation returned by system.capabilities remains the future adapter
contract; it is not the Swift CLI's build input.

Wire request ID identifies a response; correlation identifies the logical
mutation/report. For reports and messages, reusing a correlation with
equivalent input returns the known outcome without repeating occurrences, and
different content conflicts. Controls have no replay store (decision AD): a
repeated correlation executes again. Missing wire correlation is invalid input
with no effect. Timeout/disconnect after submission may leave an uncertain
outcome; it does not establish cancellation or authorize an automatic retry.

A result establishes only its declared boundary: accepted, durable, applied,
partial or uncertain. Presenting UI does not execute a selected command, and
terminal input acceptance does not prove command completion. Diagnostics never
pollute machine output. There is no general cross-method transaction or implicit
rollback contract.

### C3 — Model-facing surface

The default skill resolves the owning CLI through AGENTSTUDIO_CLI; the prepared
PATH permits the following bare spelling without hardcoding a bundle location.
It teaches only these scalar calls:

| Invocation | Observable meaning | Default response shape |
| --- | --- | --- |
| agentstudio message "text" | Send arbitrary message text in the bound conversation. | “Message saved.” or “Message queued.” |
| agentstudio needs-you "why" | Open/update the one deliberate help assertion; retain explanation privately with it. | “Needs you recorded.” or “Report queued.” |
| agentstudio needs-you --clear | Clear the current deliberate assertion in the same bound generation, without supplying its ID. | “Needs you cleared.” or “Can't clear while Agent Studio is offline.” (failure; never queued). |
| agentstudio done | Assert completion of the bound current turn/reporting episode as AGENT REPORTED. | “Done recorded.” or “Report queued.” |

Message text, including Unicode and line breaks, is preserved exactly;
reply brevity never truncates stored content. Needs-you explanation text obeys
the same private-content restrictions. No command asks the model to construct
an ID, sequence, envelope or JSON object. The app derives conversation, current
generation and matching turn/episode from admitted context. If that context is
unavailable, a short binding/error reply replaces guesses; it does not request
that the model invent an identifier.

Descendant processes share the pane's one deliberate assertion/episode because
this path intentionally carries no separate model-authored identity. The shipped
skill instructs subagents not to call done or needs-you. Evidence precedence
is the guard: a child's done is AGENT REPORTED and cannot outrank a provider
REPORTED running turn, so the developer still sees RUNNING. A child's needs-you
displaces nothing stronger than AGENT REPORTED. Without provider facts, a child's
done may show DONE, explicitly labeled AGENT REPORTED; the system cannot infer
which descendant authored an identifier-free call.

Done is not provider-reported completion. Clearing help does not establish done
or clear another source's attention. Repeated help/done calls coalesce by current
assertion/episode in addition to correlation replay. Model reply defaults exclude
IDs, catalogs and query pages; an explicit detail option exposes the tooling
result. A disconnect after submission returns the one-line model outcome “Delivery
uncertain.”; it does not claim delivery, cancellation or safe repetition with a
new correlation. C2's same-logical-request reconciliation rule still applies.
This is the model-token-economy rubric and V3's pass/fail boundary.

### C4 — Debug test control

The debugTesting class exposes every AppCommand through typed command.execute,
including interactive commands, plus curated layout split/close/focus/drawer,
terminal send/wait/status/snapshot, bridge.*, ui.*, app/window/workspace/pane
read snapshots and session.message.ack. Former focus/picker/UI inputs become
explicit typed arguments (for example repository/worktree IDs). Commands whose
meaning is presentation report presented, never action completion. Existing
feature availability still applies; catalog completeness does not revive dormant
features or implement the reserved file.open contract.

When the off-critical-path debug IPC service becomes ready, it writes a 0600
owner-only runtime-bound credential. The
CLI reads it on every call; the app verifies its SHA-256 verifier. Disconnect
does not consume or revoke it. Shutdown/runtime replacement revoke its generation
and delete the owned file. Stable/beta never write this credential. Authenticated
diagnostic calls use `.automationClient` with `.automationSameUser`; they do not
use `.unsafeDebug` or `.unsafeDebugClient`. The explicit unsafe-no-auth option
remains opt-in only, never automatic failure recovery.

The installed skill gives a Haiku/Luna-class test agent enough information to
start/discover and drive a debug app. For a single running debug app, the CLI
discovers runtime metadata and authentication without hand-assembled flags,
tokens or socket paths. Discovery uses a fixed owner-only channel-scoped debug registry independent of
per-run data roots, populated by the apps themselves, so relocated repo launches
are reachable from an unrelated shell. Multiple debug apps require explicit
selection, never a guess. Plain-argument debug verbs return short outcome lines; detail is
explicit. Snapshot output is concise requested readback, not an unsolicited
catalog dump. No running app produces a concise unavailable/start instruction.

Discovery labels debug-only command variants and methods, with privileges and
targets. Stable/beta exclude and refuse those variants; their command exposure
remains headless-only. An AppCommand with an admitted headless variant can still
execute that variant in stable/beta under normal authority; Z does not remove it.
A CLI flag cannot change server channel. Normal pane credentials cannot become
diagnostic authority; diagnostic credentials are fixed to that runtime/channel,
not issuable production pane grants.

session.message.ack is debug-only. The only other acknowledgment entry is the
in-process App entry reserved for the future Sessions UI action. Production
pane methods remain bound report/message/query and admitted headless capabilities
under C1. Full debug dispatch uses existing execution owners and preserves
observable unavailable outcomes for dormant features.

### C5 — Provider facts and Agent state

Round 1 installs native integrations for Claude Code, Codex CLI and Cursor CLI.
Install success is distinct from hook trust/activation and event qualification.
Reinstall is idempotent; uninstall removes only still-owned entries and reports
user-modified conflicts. Unsupported profiles stay useful through explicit
agent reports without inheriting provider authority.

session.bind establishes an absent binding, repeats the same current conversation
idempotently, and replaces it only with live qualified new provider session-start
evidence or an explicit model bind labeled AGENT REPORTED. Replacement ends the
old generation. A late/historical provider bind is historical only even when it
carries a previously unseen source generation. A delayed bind/report for an ended
or older generation is likewise historical only, never current; competing identities without such a transition
return bindingConflict. Same-correlation bind replay returns its original outcome.
On app restart, restored bindings have ended generations; the first qualified
bind establishes a fresh generation. These rules prevent A→B→delayed A from
silently retargeting identifier-free model calls.

Every qualified event has provider/version, conversation, source generation,
turn/tool/subagent/request identity as applicable, occurrence, origin and
freshness. Provider fields do not choose a pane or evidence label. The app assigns
REPORTED from qualified provider facts, AGENT REPORTED from deliberate reports,
and ESTIMATED from qualified revocable inference. For the same capability/turn,
REPORTED supersedes AGENT REPORTED, which supersedes ESTIMATED. Apply that
precedence before choosing state: provider REPORTED running blocks a descendant's
AGENT REPORTED done from producing DONE. Deliberate descendants share the pane's
assertion/episode; their needs-you cannot displace stronger evidence. Without
provider facts, DONE from a descendant remains visibly AGENT REPORTED, as C3
states. Provider-identified child facts retain their separate matching rules.

The Agent Sessions Specification, 2026-08-03, branch sessions-in-sidebar,
Agent State Contract section, supplies these retained semantics:

| State or transition | Meaning |
| --- | --- |
| UNKNOWN | No usable current evidence; no invented label. |
| RUNNING | Current activity in the latest turn; quietness cannot complete it. |
| NEEDS YOU | A current actionable condition; focus/reading/input is not resolution. |
| DONE | Matching latest-turn completion, not provider process exit. |
| State precedence | Actionable condition, otherwise completion, otherwise activity, otherwise unknown. |
| Matching clear/abort | Clear only the associated condition/turn; abort creates no completion result. |
| Source loss | Provider-reported unresolved attention remains stale; generation-scoped agent help loses current authority. Reveal remaining facts or unknown; loss alone never proves done. |
| Replay/upgrade | One completion result per turn; stronger matching evidence can upgrade it without resetting seen state. |

Current actionable conditions retain independent source ownership. App-derived
request IDs are queryable by tooling even though the model never types them.
An identifierless provider prompt requires a qualified matching/revalidation
contract; minting an app ID does not prove which prompt resolved. Typed OSC 9,
title and progress signals enter through Contract 7 and establish only their
qualified semantics. No screen manifests, scraping or generic silence inference.

Qualification is per event, not per provider as a whole:

| Capability | Required qualification |
| --- | --- |
| Session start/end | Exact native session boundaries and pane binding. |
| Turn start/done/abort | Matching turn identity; interrupted/failed work is not completion. |
| Permission/question/elicitation | Actionable entry and matching resolution or bounded revocation. |
| Tool/subagent activity | Exact child/tool identity without confusing child completion with root completion. |
| Deliberate reports | Bound context and AGENT REPORTED attribution. |

The 2026-09-12 Cursor CLI live-hook receipt, summarized in
[decision-record.md](decision-record.md#evidence-gaps-not-owner-decisions),
observed sessionStart/sessionEnd in three headless 2026.09.02-c22c1a3 runs,
with matching session_id/conversation_id. beforeSubmitPrompt,
afterAgentResponse and stop did not fire; tool/subagent hooks were not exercised.
Interactive TUI remains unverified. Positive checks qualify only observed
capabilities; negative checks disclose unavailable capability; inconclusive
checks disclose unverified capability. Neither unknown state nor a nearby
version creates provider authority. Complete Claude/Codex event/version
qualification likewise remains a required evidence input.

### C6 — Durability and offline notifications

Accepted messages preserve exact text, attribution and occurrence identity.
They start unseen. Only an explicit authorized user acknowledgment of that
message marks it seen; repeated acknowledgment is idempotent. Unknown/unauthorized
acknowledgment fails without mutation. Sender receipts, queries, pane focus and
terminal input do not mark seen, resolve needs-you, or change another message.
Rebuilding derived state and restarting preserve durable messages, results,
seen state and attention; generation loss still follows C5.

The spool holds notifications, never commands (decision X): agent messages and
deliberate agent reports (needs-you, done). This is a semantic category,
not JSON-RPC's response-free notification envelope: the existing request,
correlation and durable-receipt contract remains. Controls, queries and auth
never queue; needs-you --clear is likewise an offline-ineligible state-change
command. Hook lifecycle state facts emitted while the app is down are
dropped at the source, not collected in round 1; provider history remains their
record. Later collection of such facts is permitted under the notification-only
rule, but adds no current obligation or machinery.

When the app is unreachable, the CLI appends the exact eligible notification
request as one encoded line in an owner-only per-pane spool. No bearer token
is persisted. Unreachable means a missing socket path, refused connection or
dead/stale endpoint; authentication/protocol rejection is not offline and never
queues. Queued success requires durable append and differs from admission
into Sessions. Any notification that cannot be appended or durably accepted
returns explicit failure; none is silently dropped or evicted. There is no
offline state-fact cap or loss-disclosure mechanism.

Live ingress separately discloses “some facts lost” when it drops state and
returns a per-request throttled/rejected outcome. Notification content never
enters telemetry to carry those diagnostics.

An unattributable drained notification remains durably queryable as an
unattributed message with its pane UUID retained and conversation unknown;
nothing is lost merely because its pane/binding no longer resolves.

An IPC-side recovery pass drains through the same admission rules, forcing late disposition.
Late offline facts can preserve historical
occurrences/messages but cannot overwrite newer live state, clear current
attention, or create fresh live completion. Equivalent replay never duplicates
an occurrence or resets seen state. Lines are removed after successful durable
admission, not retained as a telemetry log. Physical storage destruction and
operator data deletion are not app-restart guarantees.

### C7 — Reserved contracts

file.open is a documented boundary only (U2; P/V). It is not registered,
not advertised in discovery, not a CLI verb in this slice, and has no current
realization or functional proof obligation. Its future adapter must declare a
command relationship when registered; the reserved relationship is a dedicated
AppCommand identity named openFile, not reuse of an unrelated existing action.
This reserves the relationship, not an enum case or execution owner now.

| Field | Reserved wire contract |
| --- | --- |
| Method | file.open, JSON-RPC 2.0 request. |
| Params | path: string; line: positive integer, default 1; target: {kind: pane, handle: self/UUID/pane:N}, default self; placement: drawer/split/tab/new, default drawer; focus: boolean, default false; correlationId: required string; optional basePath for relative paths. |
| Success | applied with actual target/viewer handle, placement, line, focusChanged and correlationId. |
| Other results | accepted with operation identity; partial with known effect identities; uncertain with reason and correlationId. These never masquerade as applied. |
| Errors | invalidParams (field/expected value), missingGrant (scope), wrongTargetKind, targetNotFound, pathUnavailable, unsupportedContent, unavailablePresentation, unsupportedVersion, correlationConflict. |
| Registration constraint | A later contribution declares its AppCommand relationship, schemas, target and privilege/data scope through the same registry; no raw renderer endpoint. |

Path resolution, viewer implementation, placement algorithms and native
composition belong to later work. No such internals are selected here.

### C8 — Failure contract

| Situation | Required outcome |
| --- | --- |
| Missing/forged identity | No guessed target; structured auth/binding failure and concise model reply. |
| Undo-closed retained shell | Canonically ineligible, all requests denied and leases closed; Undo restores the same credential's eligibility after canonical membership returns; discard/expiry revokes permanently. |
| Cross-scope pane request | Missing-grant names required privilege/scope; no effect or grant prompt. |
| Wrong target kind / unknown identifier / version skew | Stable correction data, no focus fallback or client decode crash. |
| Missing correlation / conflicting replay | Invalid input or conflict before a new side effect. |
| Disconnect after submission | Uncertain where effect may have occurred; reconcile the same logical request. |
| App unreachable (missing/refused/dead endpoint) | Eligible notification durably queues or fails explicitly; authentication/protocol rejection never queues; controls/queries/auth and needs-you --clear never queue. Hook lifecycle state facts are dropped at the source. |
| Malformed or stale report | Reject current-state mutation; never guess content or clear unrelated attention. |
| Durable write failure | No false accepted/queued receipt; previously accepted notifications remain protected. |
| Live state admission overload | Per-request throttled/rejected outcome and queryable loss disclosure. |
| Diagnostic call to stable/beta | Testing capability unavailable; no effect regardless of CLI flags. |
| Provider integration failure | Provider/terminal continue; source health remains explicit. |
| IPC/Sessions schema, credential persistence, server publication or spool recovery delayed/unavailable | IDE startup and terminal construction/attachment continue without waiting; IPC remains unavailable until its own readiness succeeds. Restoration leaves the existing shell/token unchanged. |
| Any process end before a pane verifier becomes durable, including normal exit after storage failure | The next app explicitly rejects the continuing shell's unknown credential; authentication rejection does not spool, startup/reattachment remains usable, and IPC requires a new shell. |

## Cross-cutting boundaries and negative space

The [IPC boundary rules](../../architecture/commands/ipc.md#boundary-rules),
[command rules](../../architecture/commands/command_specs.md),
[atom boundaries](../../architecture/state/atom_persistence_boundaries.md),
[observability contract](../../architecture/observability/observability_and_traceability.md)
and [Inbox retirement](../2026-08-21-inbox-retirement/specification.md) remain
binding. No zmx.* public methods, renderer transports, direct IPC atom access,
commands on a facts bus, or Inbox startup/data writes. Decision A explicitly
replaces the old ban on env-borne bearer credentials while retaining pane scope,
close denial/final revocation and no token argv/log/spool. Typed source admission stays
outside MainActor; MainActor applies compact validated UI changes only.

Round 1 excludes Studio-to-agent steering, file-open internals, Sessions pane
UI, ACP client/chat pane, agent-to-agent messaging, macOS banners, screen
manifests/scraping, transcript storage/search, answer-through replies, Inbox
revival, a daemon/Rust core, SDK/Rust CLI, remote/multi-machine, grant issuance
UI/policy, and pi/OpenCode integrations. Hook lifecycle facts emitted while the
app is down are not collected in round 1 (X). U17's ACP-shaped vocabulary is advisory,
not a compatibility MUST. No additional message expiry policy, latency budget,
regulatory regime or new UI accessibility surface is introduced; existing
performance, privacy and native accessibility gates remain intact.

## Proof obligations

| ID | Requirements | Evidence distinguishing pass from fail |
| --- | --- | --- |
| V1 | R-01–R-03, R-08 | Real pane-shell/descendant env and authenticated socket calls: one reused per-pane/app-runtime environment token, genuinely new shell identity, restored existing-zmx shell retaining its original token, multiple durable verifier credentials remaining valid for the same canonical live pane, stored-hash verification, self context, denied broader scope, close-time canonical ineligibility/all-request denial, same-shell Undo eligibility restoration, expiry/discard revocation of every pane credential, restored-shell continuity, forged-scope and other-UID negatives. |
| V2 | R-04–R-10, R-23 | In-process ClientCore and shell CLI transcripts through the actual catalog/decoder: every schema/example/result alternative, command relationships, target kinds, unknown/version-skew errors, omitted correlation, equivalent/conflicting/ordinal-reassignment replay and MCP metadata projection, including targetless diagnostic duplicate/conflict cases across reconnect and runtime replacement. Inspect the bundled Swift executable's signing/notarization context; no JSON-generated CLI resource or hand map supplies its verbs. |
| V3 | R-09, R-11, R-12, R-17 | Installed skill plus CLI reports/messages in a real bound agent context using only inherited AGENTSTUDIO_CLI/PATH, with another app channel installed: scalar calls, no typed identifiers/JSON, one-line replies, no catalog/query dump. Verify server-derived request identity, repeated help/done coalescing, ID-free clear, binding A→B with delayed A bind/report, repeated B bind, source end/restart, descendant calls with and without stronger provider evidence, exact message text and concise invalid-context/queued outcomes. |
| V4 | R-02, R-05, R-13 | A Haiku/Luna-class agent given only the installed skill starts via the repo launcher, discovers from an unrelated shell and drives the debug app end-to-end: split, send terminal input, run a command and read a snapshot using plain arguments/short replies. Every AppCommand dispatches its typed debug variant; presentation-only outcomes report presentation. Stable/beta refuse debug-only variants and omit them from discovery, preserving admitted headless variants. Two sequential authenticated calls with disconnect both succeed; inspect reusable credential disposition, shutdown/replacement revocation/deletion and stable/beta absence. Test duplicate/conflicting targetless mutations across reconnect/runtime replacement and explicit selection among multiple debug apps; pane credentials never gain diagnostic authority. |
| V5 | R-14, R-22 | Native install/upgrade/reinstall/uninstall with pre-existing and modified settings, partial failures, missing/untrusted integrations and exact ownership diffs; actual provider entry points remain usable on reporting failure. |
| V6 | R-09, R-15–R-17, R-22 | Exact-version provider fixtures for origin, turn/request/child matching, abort, generation loss, binding A→B then delayed A bind/report, late/historical new-generation bind, repeated B bind, source end/restart, equivalent/conflicting occurrence-ID reuse across correlations, stale/replayed inputs, precedence and state fallback; Contract 7 typed terminal facts with silence/screen/unqualified-event negatives. Cursor headless evidence does not substitute for its pane mode. |
| V7 | R-03, R-09, R-18–R-20 | Real app-down CLI emission with removed-socket and stale-socket-file variants, post-readiness recovery drain and SQLite queries: exact durable messages and deliberate reports once, seen/attention survival, late-versus-live ordering, app-derived assertion IDs, live-overload loss disclosure, notification append/commit failures and crashes before/after commit/line removal. Controls/queries/auth, needs-you --clear and hook lifecycle facts never enter the offline spool; deleted/unresolvable bindings yield queryable unattributed notifications. Reads/focus cannot mark seen. Acknowledgment proof (session.message.ack isolation, idempotence, pane denial, stable/beta absence) is deferred with the entry itself (AH); round 1 proves only that no acknowledgment path exists and messages stay unseen. |
| V8 | R-19, R-21 | Real storage and telemetry sinks with distinctive private payloads in success/rejection/recovery: no message/explanation/token in OTLP/JSONL logs, no bearer in spool/argv, no transcript ingestion; architecture/runtime evidence preserves IPC/atom/renderer/zmx and dormant Inbox boundaries. |
| V9 | R-24 | Scope and capability inspection preserves excluded systems and the reserved-only boundary; no deferred feature is presented as active. |
| V10 | R-01, R-03, R-13, R-25 | Controlled barriers delay optional schema migration, verifier persistence, socket/catalog publication and spool recovery while real startup reaches its first interactive frame and genuine new and restored terminal paths become usable. Prove normal and automatic-restore-suppressed trigger paths and same-writer migration barrier scheduling. Against a ready endpoint, a genuine new shell authenticates while persistence is delayed; restoration retains the existing zmx token without replacement; close/Undo/discard during delayed persistence cannot regress. Separate abrupt-exit and normal-storage-failure process-end evidence proves explicit unknown-credential failure without auth-rejection spooling. First-schema and steady-schema runs measure startup, genuine construction and reattachment without an invented threshold. |

## Requirement coverage

| U | Problem/outcome | Active obligations or reserved boundary | Contracts/proof; disposition |
| --- | --- | --- | --- |
| U1 | P1/O1 | R-01–R-03, R-08–R-10, R-25 | C1/C2; V1/V2/V10; covered |
| U2 | Contract only | C7 reserved file.open | No realization or functional proof in this slice; P/V |
| U3 | P1/O1, P4/O4 | R-04–R-08, R-13 | C2/C4; V2/V4; full typed debug command catalog under Z |
| U4 | P1/O1 | R-04–R-10, R-13 | C2/C4; V2/V4; covered |
| U5 | P4/O4 | R-14, R-22 | C5; V5; provider activation qualified separately |
| U6 | Later provider round | R-24 exclusion | Negative space; V9; authorized deferral |
| U7 | P2/O2 | R-15–R-17, R-22 | C5; V6; per-capability qualification required |
| U8 | P3/O3 | R-11, R-18, R-19, R-21 | C3/C6; V3/V7/V8; covered |
| U9 | P3/O3 | R-21 | C6/C8; V8; covered |
| U10 | Later banners | R-24 exclusion | Negative space; V9; authorized deferral |
| U11 | PR2 steering | No delivery obligation | N; deferred |
| U12 | P2/O2 | R-15, R-16, R-21, R-22 | C5; V6/V8; qualified evidence only |
| U13 | P2/O2 | R-15, R-17, R-22 | C3/C5; V3/V6; observe-only |
| U14 | P3/O3 | R-03, R-09, R-16, R-19, R-20 | C1/C6; V1/V7/V10; notifications-only offline collection under X; AB's authentication rejection never queues |
| U15 | P3/O3 | R-18, R-19, R-21, R-24 | C6; V7/V8/V9; capability now, UI later |
| U16 | P1/O1 | R-02, R-03, R-08 | C1/C4; V1/V4; no issuable pane grants |
| U17 | Advisory S1 | None | No normative ACP compatibility claim |
| U18 | Excluded agent-to-agent | R-24 exclusion | Negative space; V9 |
| U19 | P1/O1, P4/O4 | R-04–R-10, R-23 | C2; V2; common typed catalog |
| U20 | P1/O1, P4/O4 | R-10, R-13, R-23 | C2/C4; V2/V4; Swift CLI now, SDK/Rust later |
| U21 | P3/O3 | R-03, R-09, R-18–R-20 | C1/C6/C8; V1/V7/V10; accepted/spooled notification durability, commands/auth rejection never queue, AB non-durable failure explicit |
| U22 | P1/O1 | R-09, R-11, R-12, R-17 | C3; V3; model token economy |
| U23 | P4/O4 | R-13 | C4; V4; reusable debug auth and zero-ceremony test-agent DX (Y) |
| U24 | P1/O1 | R-01, R-03, R-13, R-25 | C1/C6/C8; V1/V4/V7/V10; startup and terminal independence, restored-token continuity and the accepted non-durable process-end limitation |
