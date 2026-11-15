# Rex and ZMX: the common terminal boundary

**The evidence supports investigating a shared terminal contract. It does not support treating the two backends as interchangeable implementations of the current Swift protocol.** Establishing an execution, attaching a view and restoring a display are separate operations.

Versions and evidence classes are in the [source index](README.md). The native renderer constraint is owned by the [renderer note](ghostty-renderer-boundary.md).

## Creation must name the resource it actually creates

| Inspected entry | What the source or published contract establishes | What it does not establish |
| --- | --- | --- |
| Swift `SessionBackend.createPaneSession` | Creates the isolated directory and returns a handle containing `ZmxSessionID`; `attachCommand` produces a command string. | A live shell or independent Host execution. The protocol remains ZMX-shaped despite its general name. |
| ZMX Zig `create` | Ensures a background daemon without a terminal attachment and returns a created/already-present boolean. | The safe Rust call path, a verified process incarnation, shell readiness, or an installed CLI command named `create`. Some existing-endpoint connection failures return `false`, so the boolean is not an identity witness. |
| Rex `session.create` | Creates a logical session, optionally with initial windows. With no windows, it creates no terminal block. The calling client is not automatically attached. | That a successful empty session represents a running terminal program. |

Primary local anchors: [Swift protocol](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift#L43), [Swift preparation and command construction](../../../../Sources/AgentStudio/Core/RuntimeEventSystem/Runtime/ZmxBackend.swift#L205), [ZMX library creation](../../../../vendor/zmx/src/client.zig#L57), [public Zig exports](../../../../vendor/zmx/src/lib.zig#L23). Published Rex contract: [session creation](https://www.superlogical.com/rex/docs/reference/api#sessioncreate).

**Consequence:** define the caller-visible creation result around the selected resource and actual establishment evidence. Mapping similarly named methods is insufficient. No public operation schema or readiness promise is selected by this note.

## Attachment and control are not execution ownership

ZMX's [detach handler](../../../../vendor/zmx/src/loop.zig#L1073) closes that client without requesting shutdown-on-last. Its [input handler](../../../../vendor/zmx/src/loop.zig#L922) can make a nonleader the leader after recognizing user input. [Resize](../../../../vendor/zmx/src/loop.zig#L1052) follows the leader; the separate `Send` path queues input without changing leadership.

Rex documents two ownership modes: immediate takeover and a queued request. Disowning or losing a connection can pass the block to another claimant; reconnection restores ownership only when it has not changed again. Ownership selects conflicting preferences such as terminal size and grants no additional access rights. [Official ownership and detach contracts](https://www.superlogical.com/rex/docs/reference/api#sessionown_block).

**Inference:** a backend's size owner is not an exclusive input-authorization lock. AgentStudio's one-controller/viewers promise requires its own admitted control semantics, correctly related to the backend's observed state. If Rex.app connects independently to the same backend, the design must account for that client's actions rather than maintain a second, contradictory controller record.

Still open: whether direct external Rex.app access participates in the initial supported control profile; what handoff means for already queued input; and which owner can declare control held, lost or unavailable. No hidden attachment may silently take over resizing.

## Sending input needs an honest receipt

The bundled ZMX [PTY input queue](../../../../vendor/zmx/src/loop.zig#L896) drops newly submitted bytes when its 256 KiB cap would be exceeded, and logs the loss. `handleInput` does not return a per-payload child-consumption acknowledgement. This is an inspected implementation behavior, not a measured loss rate.

**Consequence:** a successful socket write cannot be promoted to proof that the shell consumed the input. The common API must preserve the actual supported delivery boundary and uncertainty. Retrying uncertain input automatically is unsafe. Typed agent steering and approvals should use their agent-control interface, with their own outcome contract.

Slow-reader output buffering and recovery also need qualification. Reading the broadcast queue alone does not establish a complete memory bound or a correct resynchronization protocol.

## Four replacement boundaries

| Replaced component | Necessary survival condition | What remains unproven |
| --- | --- | --- |
| Gateway | Continuing execution has independent custody; losing a subscriber does not trigger termination. | The actual product's disconnect, cancellation and reattachment paths. |
| AgentStudio Host | PTY and provider-control custody outlive the replaced process, or a qualified handover preserves them. | Active-turn identity, pending approvals, callbacks and control after replacement. |
| Terminal backend | Its process custody survives the specific upgrade mechanism. | A ZMX daemon restart is not the same operation as replacing its observer. |
| ACP/provider-control process | The provider's actual execution and callback ownership support the selected replacement. | Saved-conversation resume is not evidence that the same in-flight turn continued. |

Rex's [upgrade table](https://www.superlogical.com/rex/docs/linux/upgrading) distinguishes restarting the shared server, which ends sessions, from restarting the login broker while account servers keep running on their prior version. Personal servers also remain running until stopped. This is a published deployment distinction, not a guarantee about every Rex installation or macOS update path.

## Herdrex is evidence of interoperability, with limits

[Herdrex](https://github.com/elonnzhang/Herdrex/tree/8bab18ef035a326ead3a93fc5afec159f1b2d88f) maps Herdr workspaces, tabs and panes into Rex sessions, windows and blocks. Its Go packages separate protocol/client/server/stream machinery from the backend mapping. Its [alignment document](https://github.com/elonnzhang/Herdrex/blob/8bab18ef035a326ead3a93fc5afec159f1b2d88f/docs/PROTOCOL.md) records incomplete reconnect, history, exit-status and other mappings.

The README's blanket absence of floating layers conflicts with the inspected [floating-layer implementation](https://github.com/elonnzhang/Herdrex/blob/8bab18ef035a326ead3a93fc5afec159f1b2d88f/internal/bridge/layers.go) and later alignment sections. Reuse exact source behavior, not an unqualified feature-gap summary. These Go packages are prior art, not Rust crates already integrated into AgentStudio.

## Deciding experiments, not executed results

1. **Headless establishment:** create the selected execution without Swift or a terminal view; independently identify the actual backend process/resource; attach later. A directory, logical container or request receipt alone fails the intended proof.
2. **Two clients:** a desktop controls while a phone views; exercise takeover, disconnect and stale queued resize/input. A viewer changing the PTY size or a stale controller causing input violates the selected policy.
3. **Replacement:** keep a correlated agent turn active while replacing the exact intended Host component. Observe the same turn and regain its pending control/approval channel. A surviving shell with a dead ACP child is the critical counterexample.

All three require a later executable profile and grant. This note does not authorize running them or claim they passed.
