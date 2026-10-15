# Pane agent status by call intent — Program Design

Requirements: [requirements](2026-10-15-pane-agent-status-by-intent-requirements.md) → Specification: [specification](2026-10-15-pane-agent-status-by-intent.md) (E1–E7, R1–R12, V1–V8; revised 2026-10-15 after review) → this Program Design

## Current system

```mermaid
sequenceDiagram
  participant H as Hook (pane shell)
  participant C as CLI client
  participant S as IPC server
  participant X as Sessions
  participant R as Pane row
  H->>C: hook claude Stop (token from shell env)
  C->>S: auth.login(token)
  alt token recognized
    S-->>C: authenticated (spawnedPaneAgent)
    C->>S: session.event(self, Stop)
    S->>X: admit → decideBinding → commit
    X-->>R: status (keyed by binding generation)
  else token not recognized (11 of 19 panes)
    S-->>C: unauthenticated
    Note over C: hook exits 0; log "provider_hook_failed" only
    Note over R: activity from terminal; no status
  end
```

Facts this design rests on, all checked on origin/main:
- The client logs in before every method when it holds a token (`AgentStudioIPCClientCore.swift:201`).
- Status lives in `SessionsStatusRuntime.states`, keyed by binding generation, and a pane with no binding reads `.unbound` (`SessionsIngestion+Status.swift:36`).
- Any admitted hook binds an unbound pane (`SessionsEvidenceReducer+Mutations.swift`, last branch of `decideBinding`).
- Agent Title and Agent Line are stored per pane, but a write needs a claimed writer epoch (`PaneContextStorage+CurrentValues.swift:133`). A session writer claim needs a binding.
- Refusal reasons survive only as one in-memory `lastRefusalByPane` value with three reasons, read by nothing in the UI.

## Choices

| Crux | Chosen | Rejected and why |
| --- | --- | --- |
| How a status call is marked on the wire | A new status-intent method, `session.status`, carrying the hook's status projection. `session.event` stays the identity-intent method. | Letting one `session.event` change its effects with the caller's auth would hide the intent the owner asked to make explicit, and make audits harder. |
| When the hook uses it | Only after login is refused, or when there is no token: one fallback call in the same hook run. | Sending both calls every time doubles hook traffic for the healthy panes. |
| How a claim authenticates | A new principal kind, `paneClaim(paneId, workspaceId)`. It needs the existing same-user peer check plus live membership of the pane in that workspace, and may call only methods whose descriptor declares status intent. | Weakening `spawnedPaneAgent` would leak identity, message and read rights to claims. |
| Agent title and Agent Line | `pane.title.set`, `pane.line.set` and `pane.writer.claimEpoch` declare status intent for the pane writer, meaning no session writer claim. With a session writer claim they stay identity intent. | Moving every epoch claim to the token side would block the Agent Line, which the owner made pane-ID-only. This corrects the Lead's earlier table, which had put writer ordering under identity. |
| Status without a binding | An in-memory `UnverifiedPaneStatusRuntime` inside `SessionsIngestion`, keyed by pane. It reuses `SessionStatusState`'s transition rules and follows an unverified main session. | Persisting it, or creating a binding, would turn a claim into identity (R4). |
| Where the refusal shows | `SessionStatusAtom` publishes one cohesive per-pane value: `PaneAgentStatusPresentation { status: AgentSessionStatus, connectionIssue: AgentConnectionRefusalReason? }`. Sessions derives it outside the atom; the atom keeps assign, equality and index methods only. The row and pane render the status line and, when present, a second "agent not connected · reason" line, both through `LocalActionSpec`. | A `notConnected` status case would make the warning hide `Needs you` (review finding). A new atom, toast or banner is not needed (U5). |
| Diagnostics | Hook diagnostics carry the pane id and a reason from the fixed set, instead of the generic label. | Payload or credential detail (R10). |

## Entity binding

| E | Owner | Home | Shape at boundaries | Kind |
| --- | --- | --- | --- | --- |
| E1 Agent call | IPC client and server | `AgentStudioIPCClientCore/ProviderHooks`, `AgentStudioAppIPC` | JSON-RPC request; `session.status` params `{ paneClaim: { paneId, workspaceId }, tokenOutcome: rejected \| absent, report: hook(event, provider, providerSessionId) \| refusal(reason) }`. The `refusal` variant needs no session id, so a missing-id or unreadable-payload hook can still report. `session.refusal` stays token-only. | transient |
| E2 Call intent | Method descriptor | `AgentStudioProgrammaticControl/BuiltInDescriptors` (existing) | new descriptor field `callIntent: status \| identity \| message \| read \| control`; pane-context methods vary by writer claim | derived |
| E3 Pane claim | Server admission | `AgentStudioAppIPC` (new `AppIPCPaneClaimAdmission`) | `{ paneId: UUID, workspaceId: UUID }`; checked against `PaneContextMembershipDirectory` (existing) | transient |
| E4 Verified binding | Sessions (existing) | `sessions_pane_binding` | unchanged | persisted |
| E5 Unverified pane status | Sessions | new `UnverifiedPaneStatusRuntime` in `Features/Sessions/Runtime` | `[paneId: (mainProviderSessionId, SessionStatusState)]` | cached, in memory |
| E6 Unverified main agent | Sessions | inside E5 | `(provider, providerSessionId)`, plus a per-pane released set for the late-predecessor fence | cached |
| E7 Refusal record | Sessions | extends existing `lastRefusalByPane` | `{ reason: AgentConnectionRefusalReason, intent: CallIntent, at: Date, count: Int }`; reason is a closed enum | cached, in memory |

`SessionStatusAtom`'s per-pane value becomes `PaneAgentStatusPresentation`: the same status plus an optional connection issue. That is related observed state on an existing atom, not a new atom.

## Components and flow after the change

```mermaid
sequenceDiagram
  participant H as Hook (pane shell)
  participant C as CLI client
  participant S as IPC server
  participant X as Sessions
  participant R as Pane row
  H->>C: hook claude Stop
  C->>S: auth.login(token)
  alt token recognized
    S-->>C: authenticated
    C->>S: session.event(self, Stop) — identity + status, as today
    S->>X: decideBinding → commit
    X-->>R: verified status
  else not recognized or no token
    S-->>C: unauthenticated
    C->>S: session.status(paneClaim, Stop, tokenOutcome) — one fallback call
    S->>S: paneClaim admission: same-user peer, live membership, status-intent method
    S->>X: unverified status + refusal record (credentialNotRecognized)
    X-->>R: Working / Idle · done / Needs you, plus "agent not connected · reason" while unbound
  end
  Note over C: hook still exits 0; diagnostic names pane + reason
```

- **Server admission:** `AppIPCTypedMethodRegistration` runs the claim path only for unauthenticated connections calling a status-intent method. It builds a `paneClaim` principal after the membership check. Every other method on such a connection gets `intentRequiresToken`.
- **Sessions:** `session.status` goes to `SessionsIngestion.recordUnverifiedStatus`. If the pane has an active binding it is ignored, because verified status wins. Otherwise it follows the main-session rule and applies the same `SessionStatusState` transition. It submits hook activity to `PaneActivityClock` and publishes to `SessionStatusAtom`.
- **Lifecycle:**
  - E5 and E7 clear when a binding becomes active, when the pane is retired, and at app quit.
  - E6 records the instant it was established.
  - The unverified main is released by a status-path SessionEnd, or by the pane's command-exit fact. A command exit releases it only when its `reportedAt` is after that instant; this is the same source-time fence the verified path applies (`SessionsIngestion+Status.swift:135`). The existing handler (`:125`) returns early when there is no verified binding; it is extended to apply that fence and release E6.
  - Late ordinary facts from a released `(provider, providerSessionId)` are ignored. A `SessionStart` from it may re-establish it as main when no live main blocks it, mirroring `decideBinding`'s SessionStart branch (`SessionsEvidenceReducer+Mutations.swift:29`).
- **Title and Agent Line:**
  - On a refused login, the CLI drops its automatic session attribution (`writerClaim` from `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`, `PaneCLICommandRunner.swift:245`). It writes as the pane writer, with status intent and the pane claim.
  - With the CLI store (`AGENTSTUDIO_CLI_STORE`), it uses its stored epoch and counter as today.
  - Without the store, as in old shells, every write uses one deterministic epoch claim per `(pane, stream)`. Its `claimId` is a name-based UUID of the pane id and the stream, so a repeated claim is idempotent and returns the same epoch. The counter is the host's continuous-clock nanoseconds, captured when the CLI command starts and before any IPC. A delayed older call therefore carries a smaller counter and is rejected as `lastAccepted` by the existing admission (`PaneContextStorage+CurrentValues.swift:184`). Per-write fresh epochs are not used: they would let a delayed older write win (N10).
  - Stale results stay final and are never renumbered.
- **Deadline:** login, the fallback reconnect and the fallback call share one absolute `CallDeadline` (`AgentStudioIPCTransport/CallDeadline.swift`). If the budget is exhausted, the hook exits 0 silently and logs `deadlineExceeded`.
- **Pre-dispatch refusals:** login rejection happens before any method runs. The fallback call carries `tokenOutcome`, and the server records `credentialNotRecognized` on the claimed pane after the membership check.

## Failure, ordering and concurrency

- **Fallback timing:** the fallback shares the hook's existing absolute deadline (2 s ordinary, 250 ms for synchronous lifecycle) with the login attempt. Its speed is not assumed. If no budget is left, the hook records `deadlineExceeded` in its diagnostic and exits 0. Healthy panes send no fallback request.
- **Ordering:** status calls go through the same Sessions FIFO as `session.event`, so ordering per pane is unchanged.
- **Race with a later valid token:** a pane whose binding becomes active stops using E5 at once.
- **App down:** nothing changes from today (silent exit 0).
- **The 7 unexplained panes:** V7 covers them. The new diagnostics and E7 make their reason observable on the first real run.

## How each requirement works and is proven

| U | R | E | Owner | Interface | Shape and home | State | Failure | Proof |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| U1, U2 | R1 | E1–E3 | server admission | `session.status`, status-intent descriptors | `AppIPCPaneClaimAdmission` (new) | none | invalid claim → R11 reason | V1 |
| U2, U3 | R2 | E1, E2 | server admission | non-status methods on claim connections | existing auth | none | `intentRequiresToken` | V1 |
| U2 | R3 | E2 | descriptors | control methods | unchanged | none | — | V1 |
| U2 | R4 | E4 | Sessions | `recordUnverifiedStatus` | no repository write | none | — | V2 |
| U1 | R5 | E4, E5 | Sessions → row | `SessionStatusAtom` | `UnverifiedPaneStatusRuntime` (new) | in memory | binding wins | V3, V6 |
| U4 | R6 | E5, E6 | Sessions | main-session rule | inside E5 | in memory | other sessions ignored | V3 |
| U1 | R7 | E1 | activity clock | `PaneActivityClock.submit(.hook)` | existing | persisted (existing) | — | V3 |
| U3, U5 | R8 | E7 | Sessions → row | `PaneAgentStatusPresentation.connectionIssue` | `lastRefusalByPane` (extended); `session.status` `refusal` report | in memory | — | V4, V6 |
| U1, U2 | R12 | E1, E2 | CLI | pane-writer fallback in `PaneCLICommandRunner` | per-write epoch claim without a store | client-side | stale write stays final | V8, V6 |
| Protected | R9 | E1 | hook client | fallback in `ProviderHookInvocation` | existing budget | none | `deadlineExceeded` | V5 |
| U3 | R10 | E1, E7 | CLI diagnostics | `CLIDiagnostics` routing | reason enum + pane id | none | — | V4 |
| U2 | R11 | E3 | server admission | membership check | `PaneContextMembershipDirectory` | none | reason by case | V1 |

## Review notes

- **Inventory review:** every IPC change gets a full-inventory review (owner rule). This design adds one method (`session.status`) and one descriptor field (`callIntent`), and changes admission for status-intent methods.
- **Command spec:** the row copy for "agent not connected · reason" comes through `LocalActionSpec`, as the command-spec rules require.
