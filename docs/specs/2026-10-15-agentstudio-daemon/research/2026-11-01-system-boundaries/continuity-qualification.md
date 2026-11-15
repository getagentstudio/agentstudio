# Qualifying execution custody across a planned Host upgrade

Experiment-design input, 2026-11-01, with subsequent bounded runtime results. This is not a completed Verification Design or an approved product implementation plan. [Observed native prototype results](native-continuity-results.md) are separate from the full product proof. The owner-selected outcome is binding: **the active provider turn keeps running during a planned Host upgrade**. Restoring history and launching a replacement attempt do not satisfy it.

## What the experiment must distinguish

| Promise | What would demonstrate it | What would be insufficient |
| --- | --- | --- |
| Durable work identity | The same task/attempt association remains inspectable | A task row alone says nothing about a live turn |
| Native conversation restoration | The provider loads the intended retained conversation | Starting another turn after interruption |
| Active-turn continuity | The original provider process and original active turn continue while the Host interface is replaced | Replayed output, a fresh turn under the old display label, a surviving shell or a success receipt |

The third promise is the selected outcome. Abrupt crash/power loss and replacing the execution owner itself remain separate contracts. A control connection disappearing must not be mistaken for authority to terminate its resource.

The owner also selected standalone and board-linked delegation with durable execution tracking in either case. That work association does not alter this experiment's literal active-turn observation, and it does not imply that a whole execution attempt always consists of exactly one provider turn.

## Candidate boundary to qualify

```text
Replaceable Studio Host interface
  → deliberately admitted control/event interface
  → continuing Router/provider execution owner
  → original provider process and active turn
```

The execution owner, its provider connection, pending interaction custody and actual turn identity stay outside the replaced lifecycle. The replacement Host reconnects to them. This preserves one integrated logical Host capability without assuming all its owners share one OS process. It is a candidate, not selected product placement.

Current Router whole-Host replacement deliberately shuts down owned providers and retained children. Reusing that teardown unchanged would fail the chosen outcome. A different qualified handover is possible; its descriptor/connection/state custody must be demonstrated rather than inferred from a process being separate.

## Split the proof into honest stages

### Stage A — existing control and reattachment seam

Use a real native provider behind a retained execution owner. Replace only an isolated control-client/adapter process while the real provider turn remains active. This stage asks whether the candidate interface has the right lifetime behavior. **It does not prove a product Studio Host upgrade**, because the Rust Host upgrade path is not implemented at this checkout.

Entry and observations:

1. Establish one isolated, explicitly identified provider conversation through the real control adapter. Record the actual provider-qualified session and turn association and the retained child identity available to its owner.
2. Keep that turn active through a controlled, harmless blocking operation whose release belongs to the fixture. Observe the actual tool-start/blocking state through the owner; do not use a delay or model response length as the oracle.
3. End the control adapter process and its transport. Do not terminate the provider owner, provider process, shared production Router or the owner's interactive sessions.
4. Start a replacement adapter and reattach to the existing execution. Observe the current turn and pending interaction state without submitting another prompt.
5. Release the fixture operation. Observe the same turn receive its exact fixture result and reach its actual settlement. Record explicit resync/gap outcomes; do not claim uninterrupted event delivery merely because execution continued.

The fixture's blocking operation must be bounded by the runner's hang guard, with event-driven release and complete cleanup. It performs no repository writes, network side effects or privileged actions. The provider/adapter must support that fixture through its actual tool contract. The mechanism and allowed launch commands must be checked before a run; no imagined flags or automatic approval are part of this design.

### Stage B — the actual Studio Host replacement

Drive the same observation through the implemented Studio client/Gateway/Host route and its real planned-upgrade operation. Upgrade the Host interface while the continuing execution owner stays alive. The same process/turn and exact settlement must be observed afterward.

This stage also observes the caller's lost/replaced connection, selected target binding, operation receipts and resource cleanup. It must catch a Host shutdown callback that still retires the provider, an installer that restarts the wrong service, or replacement startup that launches a second execution owner.

### Stage C — target and concurrency coverage

Repeat the real path on the required Mac and Linux Host profiles and each supported provider adapter. Add another Host and an independent active session as controls. Preserve address/identity when paths match across machines. iOS/Gateway suspension and native UI rendering are separate observations; a desktop protocol fixture does not establish either.

## Cases and wrong builds

| Case | Observation that decides it | Wrong build this catches |
| --- | --- | --- |
| Known admitted turn, adapter replaced | Same original provider process/turn continues and settles after fixture release | Adapter disconnect cancels the turn or closes the provider owner |
| Reply lost after native admission | Replacement reconciles actual operation/turn evidence before further action | Retrying turn/start creates another input/turn |
| Pending approval/question | Same pending request and legitimate recipient/options remain; no implicit approval | Reconnect duplicates, loses or answers the interaction without authority |
| Event delivery gap | Explicit source/epoch/resync behavior; native execution continuity observed separately | Cached output is presented as complete live continuity |
| Delayed cancellation | Targets only the exact authorized attempt/turn, with actual stop settlement | A stale cancel stops unrelated later work in a reused conversation |
| Two independent resources | Other session/Host remains correctly attributed and unaffected | Broad cleanup kills other provider work or falls back to a different Host |
| Upgrade installation | Only the intended replaceable lifecycle changes; original execution ownership remains | Bundled service replacement also restarts the supposedly continuing owner |

These cases do not select retry, cascade, task acceptance, retention or credential policy. They exercise the contracts those domains eventually establish. A response acknowledging a stop is not evidence of cessation.

## Source support and where it stops

- [Shared commands/events in Router composition](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/startup_composition.rs:596>) show a reuse seam.
- [Connection-local app-server facade tasks](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server.rs:178>) and their [cleanup](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server.rs:338>) show scope; they do not establish every failure branch's behavior.
- [Retained provider operation](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor.rs:608>) runs independently of its answer receiver. [Prompt control](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/provider_session_command_port.rs:164>) returns the actual correlated turn handle.
- [Facade turn/start](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_methods.rs:329>) generates a new input ID. A retry is not automatically reconciliation.
- [Existing reattach test source](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_reattach_tests.rs:296>) keeps a scripted backend, not a real provider. It is not reusable native-upgrade proof.
- [Provider retirement](</Users/shravansunder/code/projects/codex-router/crates/acp-client-runtime/src/agent_session_client/provider_connection_task.rs:671>) and [Host replacement](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/host_replacement_activation.rs:29>) identify lifecycle behavior the new boundary must not inherit unchanged.

## Current readiness

**Latest observed result:** the corrected armed native probe supported its registered primitive: the same command and turn completed after confirmed requester SIGKILL, post-exit marker matched after trimming, exit 0, with retained observer/prototype custody. [All attempts, environment, evidence and limits](native-continuity-results.md). This is not a completed product Host-upgrade qualification. No replacement adapter was started, so the complete Stage A reattachment procedure above is also still unqualified.

### Bounded runtime attempts and the registered repaired probe

The first native caller probe was executed against one new `write-restricted` Codex fixture conversation, using the existing native/ACP CLI path rather than the reverse app-server facade. Local socket permission was granted through the actual escalation tool after its initial preparation denial; no alternative transport bypassed that denial. The caller CLI returned `running` and exited cleanly at its 120-second deadline. The manual hard-drop action happened after that exit, and the unchanged 240-second runner guard aborted the gate. **Its planned abrupt-loss verdict is inconclusive.** Native read-only API metadata later showed the same turn's prescribed command completed, exit 0, after reading the abort value, with a 211,059 ms command duration. That is narrower evidence of graceful caller detachment, not a passed abrupt-loss or Host-upgrade test.

Before a second run, the cause of the missed observation was narrowed: native observations do not support provider-style paging, and attaching after dispatch misses earlier events. Source `agent-collaboration/src/event_commands.rs:165–213` supplies a real `listenerReady` record after observation attachment. The repaired driver waits for that record before it starts the requesting CLI, eliminating manual tool-call timing from the controlled drop. No hang bound is raised.

Registered second-run reference, before execution:

1. One retained native event listener is a **prototype execution-custody stand-in**, explicitly outside the requesting CLI's lifetime. Its presence may keep the native thread loaded; it is not an invisible/noninterfering verifier or proof of last-subscriber disappearance.
2. Capture the fixture's new native turn-start ID, then the matching exact command-start ID/path within that turn.
3. SIGKILL only the driver-owned requesting CLI. Require its actual process-exit signal to confirm SIGKILL before releasing the private one-use gate value. Never signal Router/provider processes or other conversations.
4. Require the same command ID/turn ID to complete with exit 0 and the gate marker after trimming output, then the same native turn to complete successfully. Submit no replacement prompt or replay.
5. Keep the same 240-second runner-owned hang guard. Missing preconditions, event gaps, early natural client exit, native interruption, unavailable output or guard expiry cannot pass.

The bounded passing claim is active native command/turn continuity after requesting-client SIGKILL **with retained observer/prototype custody**. It does not establish original OS provider-process incarnation independently, no-subscriber survival, pending-approval recovery, durable standalone-work storage, actual Rust Host replacement, remote transport, Linux/iOS or every provider. Source-code gaps in the reverse facade's stale-turn cancellation remain independent and unmodified.

### Source-confirmed constraint on task-scoped interruption

The current [facade turn/interrupt handler](</Users/shravansunder/code/projects/codex-router/crates/collaboration-runtime/src/router_session_app_server_methods.rs:395>) checks that a turn ID was supplied, then discards that ID when calling session cancellation. [The delivery route](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/provider_acp_delivery_route/provider_active_turn_cancel.rs:24>) resolves the operation active at receipt time. Source countercase: A ends, B starts in the same session, then a delayed request naming A resolves B's current operation. This fails the intended exact-old-turn cancellation oracle at the source-contract level; no executed reproduction or product repair is claimed.

The narrower [operation-bound provider cancel](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor/provider_conversation_backend.rs:359>) remains a distinct reuse candidate. Its correctness for an exact operation does not repair the facade's discarded turn identity. The basic continuity probe must not be advertised as validating this interruption path. An owning repair/review path or another actually qualified control path is required before claiming task-scoped stale-cancel safety.

### Source-confirmed launch and result limits

The [provider-only debug example](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/examples/provider-only-debug-host.rs:87>) supplies no owner-human configuration. [Startup](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/collaboration_runtime/startup_composition.rs:634>) consequently skips creation of that app-server facade. The real [Host CLI settings](</Users/shravansunder/code/projects/codex-router/crates/codex-router-cli/src/host_command/mod.rs:136>) expose configuration that a legitimate isolated launch must qualify. Do not launch the example and assume this interface exists, or manufacture an actor/approver to make it work. The chosen client's own graceful shutdown behavior must also be inspected; normal server disconnect cleanup does not prove that client sends no cancellation first.

The [provider wait/reconcile path](</Users/shravansunder/code/projects/codex-router/crates/codex-router-host/src/external_provider_supervisor/provider_conversation_backend.rs:532>) can return output unavailable when live settlement data is gone, and can classify unresolved non-live operations as not reconcilable. Retained metadata is not complete standalone-work/result recovery. Required result/evidence retention and its owning source remain a separate contract; copying the metadata store must not be treated as restoring it.

| Needed input | Checked state | Consequence |
| --- | --- | --- |
| Owner continuity outcome | Selected directly; recorded in research ledger/work thread | The proof must observe original active-turn continuity |
| Current source and control seams | Router `1cf0ce5a6`, Studio documentation `a3c945738` inspected | Source-supported candidate, not native runtime evidence |
| Real Rust Studio Host and replacement entry | Root source/manifest survey returned no product Rust Cargo manifest outside vendor/tmp/build exclusions; retained design describes the Host as new | Stage B has no implemented target in this checkout. This is not a claim about every installed binary elsewhere |
| Isolated execution-owner launch/configuration | A dedicated conversation used the existing configured runtime; no separate owner instance was launched | Do not stop/reconfigure production Router or invent launch flags; standalone-owner isolation remains unqualified |
| Provider-specific harmless blocking fixture | One native Codex pipe read was exercised through the actual route | Supports the bounded caller-loss case; other providers and interaction cases remain unqualified |
| Auth/admission and actual caller scope | Existing typed actor values are not by themselves authenticated origin | No credentials, approvals or privileges may be fabricated to make a probe pass |
| Required targets and provider matrix | Product qualification not run here | No Mac/Linux/native-provider coverage claimed |
| Existing tests | Read scripted reattach source; no tests run | Lower-layer prior art only |

The initial source-only pass ran no native experiment. The later bounded Codex experiment above kept the selected product promise intact: it is not a fake-backend substitute for the actual Host-upgrade observation. No VM, production service restart or Rust/Swift product build/test suite was run. A full Verification Design must follow the current Requirements, observable Specification and Program Design, with their exact seams and supported profiles; this research note is input to that work.
