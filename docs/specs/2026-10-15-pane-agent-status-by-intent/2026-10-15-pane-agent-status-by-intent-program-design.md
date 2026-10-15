# Pane agent status by call intent — Program Design

Requirements: [requirements](2026-10-15-pane-agent-status-by-intent-requirements.md) → Specification: [specification](2026-10-15-pane-agent-status-by-intent.md) (E1–E7, R1–R11, V1–V7) → this Program Design

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
| Where the refusal shows | Extend the session status value the row already reads (`SessionStatusAtom`) with `notConnected(reason)`, shown through the existing status line and its `LocalActionSpec`. | A new atom, toast or banner (U5); the owner must approve new atoms. |
| Diagnostics | Hook diagnostics carry the pane id and a reason from the fixed set, instead of the generic label. | Payload or credential detail (R10). |

## Entity binding

| E | Owner | Home | Shape at boundaries | Kind |
| --- | --- | --- | --- | --- |
| E1 Agent call | IPC client and server | `AgentStudioIPCClientCore/ProviderHooks`, `AgentStudioAppIPC` | JSON-RPC request; `session.status` params `{ paneClaim: { paneId, workspaceId }, providerSessionId, event, tokenOutcome: rejected \| absent }` | transient |
| E2 Call intent | Method descriptor | `AgentStudioProgrammaticControl/BuiltInDescriptors` (existing) | new descriptor field `callIntent: status \| identity \| message \| read \| control`; pane-context methods vary by writer claim | derived |
| E3 Pane claim | Server admission | `AgentStudioAppIPC` (new `AppIPCPaneClaimAdmission`) | `{ paneId: UUID, workspaceId: UUID }`; checked against `PaneContextMembershipDirectory` (existing) | transient |
| E4 Verified binding | Sessions (existing) | `sessions_pane_binding` | unchanged | persisted |
| E5 Unverified pane status | Sessions | new `UnverifiedPaneStatusRuntime` in `Features/Sessions/Runtime` | `[paneId: (mainProviderSessionId, SessionStatusState)]` | cached, in memory |
| E6 Unverified main agent | Sessions | inside E5 | provider session id string | cached |
| E7 Refusal record | Sessions | extends existing `lastRefusalByPane` | `{ reason: AgentConnectionRefusalReason, intent: CallIntent, at: Date, count: Int }`; reason is a closed enum | cached, in memory |

`SessionStatusAtom` gains one value case, `notConnected(AgentConnectionRefusalReason)`. It is related state on an existing atom, not a new atom.

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
- **Lifecycle:** E5 and E7 clear when a binding becomes active, when the pane is retired, and at app quit.
- **Title and Agent Line:** on a refused login, the CLI repeats the pane-writer claim and write as status intent with the pane claim. A session writer claim keeps today's path and is refused as `intentRequiresToken`.

## Failure, ordering and concurrency

- **Fallback timing:** a stale token fails at login quickly, so the fallback runs within the hook's existing limits (2 s ordinary, 250 ms for synchronous lifecycle). If no budget is left, the hook records `deadlineExceeded` in its diagnostic and exits 0.
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
| U3, U5 | R8 | E7 | Sessions → row | `notConnected(reason)` | `lastRefusalByPane` (extended) | in memory | — | V4, V6 |
| Protected | R9 | E1 | hook client | fallback in `ProviderHookInvocation` | existing budget | none | `deadlineExceeded` | V5 |
| U3 | R10 | E1, E7 | CLI diagnostics | `CLIDiagnostics` routing | reason enum + pane id | none | — | V4 |
| U2 | R11 | E3 | server admission | membership check | `PaneContextMembershipDirectory` | none | reason by case | V1 |

## Review notes

- **Inventory review:** every IPC change gets a full-inventory review (owner rule). This design adds one method (`session.status`) and one descriptor field (`callIntent`), and changes admission for status-intent methods.
- **Command spec:** the row copy for "agent not connected · reason" comes through `LocalActionSpec`, as the command-spec rules require.
