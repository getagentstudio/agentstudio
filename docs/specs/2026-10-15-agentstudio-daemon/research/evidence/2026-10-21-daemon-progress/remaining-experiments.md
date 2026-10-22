# What the next experiments must cover

**Terminal experiments do not establish whole-AgentStudio parity.** The completed Capture matrix answers one backend question; the remaining work includes the real Git SDK, Bridge/review products, provider ingress, storage, mobile lifetime and the final network route.

This tree is a research sequence, not an implementation plan or a list of delivered features. Near-term discriminators are specific; later integration waits for its actual owners and contracts. It incorporates the Advisor's component-coverage check while correcting one omission: the real Swift-to-Rust Unix-socket custody prototype already ran nine scenarios; complete product/schema compatibility has not run.

## Start with the thinly supported boundaries

- **Git and worktree realization — not run through a Rust engine**
  - Reference: the actual `agentstudio-git` SDK and its fixture repositories, together with AgentStudio's worktree policy. The app decodes `.agentstudio.config.json` → `worktree.include` and compiles those entries through the pinned SDK's `GitPathPattern`; an SDK-only literal search does not cover that contract.
  - First bounded comparison: pathspec-scoped status folding; worktree add/remove/prune with include patterns; staged-ref partial promotion; config search paths.
  - Use one declared Rust candidate and the same repository states; compare observed values, errors and side effects against the Swift SDK on Mac, then Linux.
  - This does not settle all surveyed Git operations. Record each mismatch against the operation tree before expanding coverage.
  - Separate Linux fork qualification: the tested Fly overlay rejected reflink. Ordinary copying remains a diagnostic, not an authorized fallback or full worktree-fork parity. First qualify an eligible filesystem/mechanism, then refs/admin/index/contents/metadata and failure cleanup.
- **Bridge files, review and annotations — remote route not run**
  - New owner direction, relayed in the Advisor's source packet: same-origin WebView HTTP/WebSocket directly to the Rust Gateway; Swift bootstraps the port and scoped capability, rather than forwarding content chunks. Privileged native control stays separate.
  - Current code still registers `agentstudio://`; the [bounded transport design](../../../increments/00-qualification/bridge-gateway-transport/index.md) now describes the target and its planned T1–T3 observations. It is not an implemented route.
  - First bounded loopback probe: actual WKWebView, finite streamed content, a held reader, cancellation reaching Rust, authenticated WebSocket subscription and wrong Host/Origin/missing-capability refusals.
  - Then cover every finite-content kind, source revision changes while reading, and annotation commit/output/finalization contracts. A successful HTTP fetch cannot prove those workflows.
- **Provider hooks and agent facts — actual remote install not run**
  - First install one real provider's hooks into an isolated Host environment; run a real turn with no viewer.
  - Observe authenticated ingress, provider/session identity, ordering, partial files, duplicate/stale facts and the Host's resulting state.
  - Existing renderer-free title/CWD/zero-viewer probes are component evidence, not automatic hook installation or the full collector pipeline. Real provider credentials may be needed for that later run.

## Continue the qualified components toward real clients

- **Terminal and session lifetime**
  - Completed: unchanged larger corpus on the newer ZMX; 110 Capture and 55 Init comparisons, with explicit losses. [Results](capture-stress-results.md).
  - The independent saved-byte rescore agrees. A ZMX-only blank-row/absolute-cursor repair is the next bounded backend discriminator; alternate-screen history and parser continuation remain separate losses. No Ghostty fork or lossless promise follows.
  - Next native slice: representative interactive TUI, alternate-screen switches, resize ownership and Unicode/paste through the existing unforked Ghostty relay.
  - Then actual UX → Gateway → Host → ZMX, two attachments, controller handoff and disconnect/reconnect.
  - Keep live reattachment distinct from restarting a dead agent. Exact display tolerances remain a product contract to settle; measurements alone select neither a Host VT engine nor a ring buffer.
- **Filesystem sources and repository discovery**
  - Completed on Sprite: actual queue overflow, replacement inode and finite closed-producer rescan recovery.
  - Next: concurrent mutations during enumeration, recursive scope, stale watch generations, arbitrary byte names and bounded publication through the selected Rust adapter.
  - Then watched-folder scan to actual repository membership. Event delivery and repository discovery are different outcomes.
- **Network, command effects and compatibility**
  - Existing proof: nine custody scenarios through real Swift AF_UNIX and Rust/Tokio; central and Git/provider effects were stand-ins.
  - Relayed owner transport direction: Quinn between Gateway and Host, with paired/pinned identities; optional WebTransport is not required. The bounded design is written; native identity/binding qualification, independent review and runtime observations remain open.
  - First remote comparison: actual Mac↔Linux route, wrong-identity refusal, held bulk reader alongside small interactive traffic, disconnect/reply loss and bounded memory.
  - Separately enumerate production Swift/Rust schemas, versions, integer bounds, frame/error cases, machine targets and cancellation. The prototype's private JSON schema does not close that inventory.
- **iOS Gateway lifetime — no physical-device proof**
  - Use the embedded Rust Gateway and the selected native/loopback adapters on a signed physical device.
  - Observe background, actual suspension, termination and resume independently; record listener, subscription and connection recovery.
  - Simulator success is not device suspension proof. Device/signing access is a later environment dependency, not a reason to block the source and Mac experiments now.

## Integrate authority and projections after their owners exist

- **Host state and Gateway materialized views**
  - Exercise actual admitted tables, reducer transactions and one-way replicated copies, including stale epochs, lag and disconnected readers.
  - Compare authoritative Host rows, replicated state and client-facing projections independently; distinguish ordered facts from replaceable latest-state invalidations.
  - Existing SQLite receipt and coordination fixtures do not prove Turso/Fleet replication or the storage split.
- **Shared workspace and output effects**
  - Multi-client layout writes, stale revisions and conflicts need actual writes, not a single insertion arm.
  - Clipboard/file/native effects need the declared real destination, followed by Host finalization and uncertain-recovery observation.
- **Diagnostics and performance**
  - Qualify the actual Rust telemetry producer and source scrubbing.
  - Measure the real admitted path and first fresh result under representative load; no serialization or transport speed winner has been established.

## Sources and current limits

The [Advisor scope note](../../../../../../tmp/practices-research/2026-10-22-advisor-scope-coverage/scope-coverage.md) supplies the independent coverage challenge; its leaf counts are survey categories, not delivery counts. The Lead checked the current scheme registration and socket-custody report before accepting those corresponding claims. The [Bridge/Quinn input packet](../../../../../../tmp/practices-research/2026-10-22-advisor-bridge-quic/owner-direction-and-advice.md) retains the relayed owner words and the still-open platform/security questions. Those research records do not replace the governing design.

No new Git engine, fallback copy mechanism, public protocol or authentication boundary is selected by this tree. Capturing the experiments is useful now; product implementation follows the reconciled design and its required independent review.
