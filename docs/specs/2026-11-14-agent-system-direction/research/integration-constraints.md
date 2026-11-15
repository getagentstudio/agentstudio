# Integration constraints and decisions still open

**The server direction, terminal integration and client product scope are separate choices.** The new design can use current evidence without treating every idea in the strategy discussion as an adopted requirement.

## What the current picture preserves

The existing owner-directed daemon work separates frontend access through Gateway from machine-local Host operations. It also distinguishes durable execution, replaceable connection, terminal attachment, agent conversation and client view. See the existing [Requirements](../../2026-10-15-agentstudio-daemon/user-requirements.md), [initial profile](../../2026-10-15-agentstudio-daemon/initial-profile.md) and [terminal API ownership](../../2026-10-15-agentstudio-daemon/designs/04-terminal-runtime/terminal-api-ownership.md).

Those inputs include Host support on macOS/Linux, Gateway support on macOS/iOS, a central writer-lease authority separate from Gateway, shared logical tabs/layout and selected read marks, one terminal controller with viewers, lossy ZMX restoration and an unforked Ghostty. The precise public contracts and several lifecycle/storage details remain incomplete. A new preliminary direction does not silently resolve or supersede them.

The current [PaneContent union](../../../../Sources/AgentStudio/Core/Models/PaneContent.swift#L13) already distinguishes terminal, browser, Bridge and code-viewer content. That is evidence that terminal resources and richer workspace surfaces are separate concerns; it is not a complete portable composition schema. The current [Layout](../../../../Sources/AgentStudio/Core/Models/Layout.swift#L4) is a flat pane strip, so the illustrative recursive split tree from the strategy is a potential design change rather than a description of current code.

## Today's relay: preserve its authority labels

The parallel Claude author supplied exact quotations in DM `01a1dcfb-f876-7101-9318-fa3c6b25a32e` and recorded them in [pathfinding](../pathfinding.html). This Lead read that relay, not the original other conversation. These distinctions must survive into the four documents:

| Topic | Meaning actually available | Treatment |
| --- | --- | --- |
| Common Rex/ZMX terminal interface | The owner proposed making the implementations details behind a common interface/protocol. This also appears directly in the Lead conversation. | Explore the consumer contract; no backend adoption or frozen protocol is confirmed. |
| iOS sockets | The owner asked whether the iPhone app can simply use sockets; the other author confirms this remains owner-proposed. | A possible revision to S32, not an already selected replacement for embedded iOS FFI. |
| Gateway/app startup | The relay contains an owner idea that macOS Gateway starts Swift while iOS app starts Gateway. | LaunchServices and a Rust-owned UIKit entry are the author's recommendations, not the owner's selected mechanisms. |
| Central facilitation | Owner wording in the relay narrows Central to facilitating connections and sending Host termination messages. | Conflicts with existing lease/storage responsibilities. The other author is raising that conflict with the owner; preserve it as open. |
| Deferring a Rex-compatible server | Confirmed by the relay as an agent recommendation. | Do not turn priority advice into owner authority. |
| Running-agent custody | Router Host, Studio Host or shared execution owner remains unanswered. | Keep the independent-custody outcome distinct from the still-open process allocation. |

Rex already uses versioned control/data subprotocol names and revision negotiation, as shown by [Herdrex's protocol types](https://github.com/elonnzhang/Herdrex/tree/8bab18ef035a326ead3a93fc5afec159f1b2d88f/pkg/rex) and its alignment documentation. A deferral can be justified by product priority or a missing adopted compatibility guarantee; it should not claim there are no version labels.

## Mobile sockets do not settle runtime startup

An in-process socket may separate protocol code while preserving embedded hosting. It does not itself initialize the Rust runtime, enter from Swift, preserve UI ownership or audit generated/exported first-party code.

The existing [ABI-host source check](../../2026-10-15-agentstudio-daemon/research/2026-11-05-ios-abi-host-source-check.md) identified limitations in ordinary Tauri/Winit paths; it did not prove every safe host is impossible. A proposed safe `UIApplication::main` call still needs the complete program-entry, Swift/UI integration, callbacks, shutdown and generated-code inventory checked against IP6. This research has not inspected or qualified that objc2 route. iOS suspension, reconnect and any push-notification sender remain separate contracts.

## Transport is not the product boundary

S32 currently selects direct browser-to-Gateway loopback HTTP/WebSocket, privileged macOS UDS, embedded iOS FFI and authenticated upstream Quinn toward remote Hosts. See the [recorded transport direction](../../2026-10-15-agentstudio-daemon/research/owner-inputs/bridge-transport-direction-2026-10-22.md). The iOS socket proposal may change one boundary after selection; it does not automatically change the browser or remote protocol.

[WebKit's Safari 26.4 announcement](https://webkit.org/blog/17862/webkit-features-for-safari-26-4/) documents WebTransport support. It does not prove AgentStudio's WKWebView secure-context, TLS, origin, packaging or lifecycle path, nor a performance advantage over its selected loopback transport. WebTransport remains optional under the saved direction. Iroh, NAT traversal, key enrollment and relay behavior were not researched or adopted in this bounded walk.

Rex [client actions](https://www.superlogical.com/rex/docs/reference/api#clientperform) can invoke declared actions on another connected client. The documented receiver still receives session/block identifiers without server-side validation of those identifiers. A review-opening integration must validate caller, exact resource and permitted effect; client action dispatch does not confer arbitrary Host or native authority.

## Existing continuity evidence is narrower than Host upgrade

The retained [native continuity result](../../2026-10-15-agentstudio-daemon/research/2026-11-01-system-boundaries/native-continuity-results.md) reports the same native command and turn completing after the requesting CLI was killed, with a separate observer connection retained. Its own result explicitly excludes actual Host replacement, replacement-client reattachment, pending-approval handover, every provider and remote/mobile platforms. This research reread the result and its limits; it did not rerun the experiment or independently re-evaluate its complete raw event corpus.

The result supports an investigation path for independent custody. It cannot close the owner requirement that active turns continue through the real planned Host upgrade. A terminal backend surviving while a Host-owned provider child dies is the deciding counterexample.

## Claims not established here

- Which of Router Host, Studio Host or another existing owner should retain provider process/control custody.
- Rex source publication, redistribution terms, release-channel compatibility guarantees or a selected deployment package. The public testing announcement is not a source license.
- A source-backed T3 Code/Orca feature comparison, market demand, or differentiation accepted by the owner.
- A portable workspace schema, multi-device merge rules, or changed Central lease/replication responsibility.
- Any runtime, performance, native rendering, platform lifecycle or deployment result for the proposed integration.

Old-document retirement must name a replacement, live dependents and preserved open constraints. No existing document is deleted or declared superseded by these research notes.
