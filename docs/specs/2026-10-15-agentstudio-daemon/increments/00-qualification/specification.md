# I0 — Qualify the remote-terminal foundations

This is an engineering qualification profile, not a usable product release. Its purpose is to falsify assumptions before I1 is frozen. Shared Requirements U1/U3/U6–U10/U19 and DS01/03/04/11 govern it; E1/E2/E4/E5 here mean the experiment-family labels from the experiment map, not domain-entity definitions.

## Questions and deciding evidence

| Question | Real boundary to exercise | Result this profile can establish |
| --- | --- | --- |
| Can a fresh native terminal restore and continue? | Pinned ZMX restoration/live connection plus actual Ghostty/PTY producer-output leg | Correct/incomplete/inconclusive declared terminal-state elements and continuation, not all TUIs or production compatibility |
| Can Swift and Rust exchange the chosen local schemas? | Two real processes over Unix sockets | Bidirectional variant/rejection/framing/limit/pairing behavior, not remote Host semantics |
| Does the CLI behave as a real client of the same operation contract? | Actual CLI parsing/submission, selected service entry and caller-visible output/exit result | Preserve target and distinguish refusal, submission, effect and uncertainty; a second independent backend implementation does not satisfy this boundary |
| Can Host execution be established without native surface launch? | Real Host/backend process and readiness observation | Distinguish directory/handle from actual execution, attach readiness and natural exit |
| Does input saturation remain observable at the backend boundary? | Actual Host adapter, ZMX input queue and controlled PTY reader | Distinguish Host receipt, backend queue admission and child observation; do not infer lossless delivery from transport success |
| Can the selected safe platform primitives support the Host path? | Actual isolated Mac/Linux process/PTY/peer/filesystem realization | Qualified/refused environment and gaps; no universal Linux/fork proof |
| Can performance be observed at the intended boundary? | Calibrated client-clock parser/native observation and controlled stimulus | Eligibility for a later metric; byte echo is not pixels/presentation |

Current `createPaneSession` only prepares a handle; current native startup launches `zmx attach`. The native paste API is not an output-feed API. Those are the two most direct native/Host integration risks for the first remote slice.

The [E1 native-leg qualification](../../designs/04-terminal-runtime/experiments/terminal-restoration.md#qualify-the-real-native-leg-before-scoring-r11) compares the current command-backed path and the proposed relay at their actual output, keyboard/paste, query-return, resize, metadata/mode and close boundaries. It supplies deciding observations, not a selected adapter implementation or passing result.

The [Swift/socket qualification](../../designs/01-service-contracts/experiments/swift-socket-compatibility.md) makes E2/A13's local producer/consumer, schema, framing, semantic-admission, interruption and selected-version-pair cases concrete. Local interoperability and actual Gateway↔Host/native effects remain separate proof layers.

The pinned backend can drop input when its PTY queue is full. Its interactive input path can also promote a different attachment and request that attachment's dimensions. The [source reduction](../../../../../tmp/practices-research/2026-10-16-daemon-delivery-book/terminal-control-evidence.md) separates those mechanisms from the selected IP2 single-controller profile and its still-open handoff details. Qualification must not use backend enqueue as a child-consumption oracle or silently turn source leadership behavior into the target controller contract.

## App integration and exclusions

Use the actual terminal hosting and startup seam, not a standalone renderer-free byte echo advertised as app integration. Fixtures must identify the exact binary/backend pins and isolate data/process/socket roots. Tests or throwaway probes do not authorize replacing running sessions or switching the current app.

The existing [E1](../../designs/04-terminal-runtime/experiments/terminal-restoration.md), [E2](../../designs/07-agents-context/experiments/host-autonomy.md), [E4](../../designs/06-worktree-fork/experiments/linux-feasibility.md) and [E5](../../designs/11-operations-integration/experiments/route-performance.md) procedures define the broader qualification. The [bounded backend and component results](../../designs/04-terminal-runtime/research/backend-observations-2026-10-20.md) now constrain E1: creation is feasible, the tested Capture/Init reconstruction fails, and the standalone complete-snapshot component passes its declared tests. Native import, complete-route behavior, Linux and mobile remain unqualified. This document itself authorizes no execution; actual experiment grants, fixture plans and environment checks remain separate inputs.

Return truthful qualification evidence to DS01/DS04/DS11. A failed assumption changes the bounded design before I1; a passing lower-layer probe does not accept I1.
