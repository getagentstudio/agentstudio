# Native execution custody: observed results

Local date: 2026-11-01; recorded event times below are UTC on 2026-11-02.

## What was observed

**A real native Codex command and its turn completed after the requesting CLI was confirmed killed with SIGKILL.** A separate event observer stayed connected as prototype execution custody. No replacement prompt was submitted. The exact command ID and turn ID continued, the command returned output matching the private one-use marker after trimming, with exit code 0, and that same turn completed successfully.

This supports one native lifetime primitive with a retained connection. It does not prove an actual AgentStudio Rust Host upgrade, last-subscriber disappearance, independently attested provider-process incarnation, pending-approval handover, durable task-result recovery, remote QUIC, Linux/iOS or every provider. The observer is an active part of the prototype's custody, not a noninterfering measurement.

## The successful causal sequence

| UTC event time | Observed fact |
| --- | --- |
| 01:39:27.977 | Native event listener reported ready before dispatch |
| 01:39:28.057 | New native turn started |
| 01:39:32.203 | Its exact gate command started; output was correctly null at this stage |
| 01:39:32.206 | Requesting CLI process exited with signal SIGKILL |
| 01:39:32.207 | Only then did the driver release the one-use gate value |
| 01:39:32.209 | The same command completed, exit 0, marker matched after trimming |
| 01:39:33.822 | The same native turn completed; driver returned supported-primitive / exit 0 |
| 01:39:33.824 | The driver's observer process exited |

These timestamps establish the recorded sequence; they are not an RPC or keystroke latency benchmark. [Structured result and exact identities](native-continuity-result.json).

## What ran

- One newly created, explicitly named fixture conversation, with SDK-reported `write-restricted` access and configured `gpt-6-luna` / medium effort. Thread metadata did not expose the full OS sandbox settings; no confinement claim is derived from the label.
- The existing Router native/ACP control route and native event listener on macOS 26.5.2. Installed CLI/service reported 0.1.119; the listener setup and a retained post-run SDK inspection reported the same service epoch/generation. This is not per-event generation attestation. Checked source head and running binary identity remain different evidence claims.
- A temporary pipe and one read-only `cat` operation. The harness released the value only after observing the requesting child process's actual SIGKILL exit.
- An event-driven TypeScript driver. It signalled only child CLI processes it created. It did not signal/restart Router, the provider, the user's current sessions, launchd or any unrelated process.

The runtime was already configured and shared; the conversation, filesystem fixture and caller/observer processes were dedicated to this experiment. This was not a separately launched isolated app-server instance.

## Keep all three attempts visible

| Attempt | Outcome | What it actually established |
| --- | --- | --- |
| Manual caller/gate driver | Planned hard-drop case inconclusive; runner aborted | Caller returned running and exited at 120 seconds. Native API metadata later showed its gate read completed after the abort value, exit 0, with a 211,059 ms command duration. This is narrower graceful-detachment evidence |
| Armed observer with original parser | Not established; caller exited before controlled drop | Observation was armed first, but the fixture rejected a valid nullable start-event field. This was a fixture/schema problem, not evidence of a backend continuity failure |
| Armed observer after schema correction | Supported primitive, exit 0 | Captured native turn and command start, actual requester SIGKILL, exact post-exit gate output and successful settlement of the same command and turn |

The runner hang guard stayed 240 seconds. The caller deadline stayed 120 seconds. Neither was increased to obtain the successful result. No elapsed-time threshold determined success. The comparison used `aggregatedOutput?.trim() === marker`; byte-for-byte stdout equality is not claimed.

## Why the parser correction matters

The runtime-published schema's bytes hashed exactly to its advertised digest:

`54ff3ea1cc888ccd9969a8e9aec5c0012f971714592dd34d14dfeab9412dc626`

It declares command `aggregatedOutput` nullable. The original fixture allowed absent/string but rejected null, preventing recognition of valid command-start events. The corrected run directly observed null at start. Completion still required exact output, exit 0 and matching native identities; no success condition was weakened. [Digest-bound schema excerpt](runtime-command-schema-excerpt.json).

This is a practical example of why actual producer/consumer schema checks matter. A codec roundtrip and a TypeScript compile would not catch this incorrect assumption about the producer's state-specific payload.

## Access and tooling limits

The first shell-based fixture creation could not reach Router's local socket. The exact access escalation was requested, the operation was inspected before retry, and the same operation ID was reused after a reported no-effect preparation failure. No transport/identity workaround bypassed an access denial. No human identity was fabricated as requester or approver.

A non-runtime Codex schema-export invocation was blocked by the host's PreToolUse nested-CLI hook. No override variable or host setting was changed. Instead, the already-published runtime schema was read and its digest verified; the blocked generator was not launched through another route.

Probe drivers passed TypeScript compilation, ordinary Oxlint and formatting checks using the repository's existing tools. Oxlint's type-check companion was unavailable, so the existing TypeScript compiler provided the type check. No dependency was installed into the product. No Rust/Swift product build or test suite ran.

Native diagnostics used the supported API for this fixture and exported only identities/status, command metadata and the fixture's own gate output. No provider session/transcript files or reasoning text were printed or saved. [Input hashes and result](native-continuity-result.json) bind the retained evidence to its script/schema-excerpt snapshots. The excerpt records the Lead's full-bundle digest comparison; the original full schema bundle is not included for an offline independent rehash.

## Cleanup and remaining proof

The requesting CLI and observer both exited. The same command's exit 0 and turn completion were observed, and subsequent SDK inspection reported the fixture not loaded. The [filtered post-run SDK observation](inputs/post-run-sdk-observation.json) records that status and its generation. Temporary fixture inputs are retained while this qualification work remains active; they are not running jobs. The clearly named fixture conversation/history is retained as evidence.

This run did not start a replacement adapter, so the full Stage A reattachment procedure also remains incomplete. Native command-item start and a post-exit gate value do not independently attest OS-process incarnation or that a read syscall was already blocked. The fixture replaces the pipe with a regular file at release so a late reader can finish.

The next product design must assign the continuing native connection, session residency and callback custody to a real execution owner outside the replaced Host lifecycle, or an equivalent qualified handover. A real Host installer/replacement path must then demonstrate the owner's selected outcome. Merely calling a new facade process “the Host upgrade” does not establish the complete product claim.

The separately identified reverse-facade stale-turn interruption gap remains unmodified. Its operation-bound cancellation below the facade does not repair a discarded requested turn identity. The task model's optional board linkage, result authority and retention also remain distinct from this native lifetime experiment.
