# Networking: how Gateway and Host find and reach each other

**Source research, not a stack selection.** This compares Tailscale, Iroh, Nebula and alternatives using official documentation and pinned implementation paths. No networking, mobile or performance experiment ran. The most useful distinction is between an application connection library and a fuller IP-overlay network: both can avoid a separately installed VPN app, but they bring different protocols, runtimes and integration work.

The question is how AgentStudio can reach an explicitly selected Host from another network without requiring the user to install a separate VPN app. That is different from promising every connection is physically direct, eliminating all relays, or removing the need to authenticate and authorize each peer. This note informs O3/O8/O10 in the preliminary design; it does not answer those owner decisions.

## First separate seven jobs

| Job | Plain meaning | What it does not establish |
| --- | --- | --- |
| Enrollment and membership | Decide which machine identity belongs to the owner's fleet. | Where that machine is reachable now, or which files/operations a caller may use. |
| Address discovery | Exchange possible local/public addresses and any relay address. | That a particular pair can actually exchange packets. |
| NAT traversal | Try to open a usable path through the two networks' address translation and filtering. | A guarantee of success on every network. |
| Path selection | Probe candidates, use a working path and adapt when it stops working. | That the application session or agent execution has ended when the path changes. |
| Relay | Forward traffic when a usable direct path is unavailable. | End-to-end confidentiality unless the peers retain their own encryption through the relay. |
| Secure transport | Authenticate the intended cryptographic peer and encrypt the connection. | Current fleet membership, repository permission or authority to terminate an agent. |
| Application session | Keep requests, subscriptions, terminal attachments and execution identities coherent over replaceable connections. | Safe replay of uncertain terminal input or survival of a replaced execution owner. |

These are responsibilities to understand, not seven proposed services or crates. A library can implement several. An application protocol can remain the same while its connection uses a direct or relayed route, provided that library actually supplies the required semantics.

## What happens behind a home router

Your phone may know a laptop's identity but not an address it can dial. A laptop's private Wi-Fi address is usually meaningful only inside that network. Its router maps outgoing traffic to a public address and port; a second network sees that mapping rather than the private address.

**STUN** lets an endpoint ask a reachable server what address/port it appears to come from. It can also support connectivity checks and keepalives. It does not open every firewall or supply the complete connection procedure. [STUN, RFC 8489](https://www.rfc-editor.org/rfc/rfc8489.html#section-2).

**Hole punching** coordinates traffic from both endpoints toward candidate addresses so their NAT/filter state may admit the returning packets. It works only when the network's mapping and filtering behavior permit it. A mapping observed toward a STUN server may not be the mapping used toward the actual peer; trying a different socket can also create a different mapping.

**ICE** formalizes candidate gathering, exchanging candidates through signaling, testing candidate pairs and selecting one that works. Candidates can be local addresses, public mappings learned through STUN or relay addresses allocated through TURN. Tests use the actual candidate addresses/ports rather than proving an unrelated probe socket works. [ICE overview, RFC 8445](https://www.rfc-editor.org/rfc/rfc8445.html#section-2).

**A relay is the fallback path.** It may be reachable over UDP, TCP, TLS or WebSocket depending on the specific product. TURN's base specification explicitly permits TCP/TLS on the client-to-relay leg for networks that block UDP; its base relay-to-peer leg remains UDP. A product's end-to-end blocked-UDP story must therefore be checked, not inferred from the word TURN. [TURN transports, RFC 8656](https://www.rfc-editor.org/rfc/rfc8656.html#section-2.1).

Changing Wi-Fi, moving to cellular or expiring a NAT mapping can make an old path invalid. Endpoint updates, probing and recovery remain necessary after the first introduction. “Central gets out of the data path” can mean it never carries terminal bytes while still providing later membership/address updates. Exactly what Central continues to own in this system remains O9; this networking explanation does not resolve lease or replication responsibilities.

## What upstream Quinn supplies

Quinn implements QUIC: authenticated/encrypted transport, streams, connection handling and UDP integration. Its public endpoint connects to a supplied remote socket address and certificate name. It is not itself a fleet registry, address-discovery server, NAT-traversal coordinator or deployed relay network.

At inspected public main revision `c7b46a969cd315398b504792e9e9af6a15a7dcc6`:

| Source boundary | What was checked |
| --- | --- |
| [Endpoint creation](https://github.com/quinn-rs/quinn/blob/c7b46a969cd315398b504792e9e9af6a15a7dcc6/quinn/src/endpoint.rs#L51) | One endpoint corresponds to a UDP socket and can carry many connections. Client/server helpers bind a local address. |
| [Connect](https://github.com/quinn-rs/quinn/blob/c7b46a969cd315398b504792e9e9af6a15a7dcc6/quinn/src/endpoint.rs#L205) | The caller supplies the remote address and certificate server name. No reachable peer is discovered by this call. |
| [Custom socket construction](https://github.com/quinn-rs/quinn/blob/c7b46a969cd315398b504792e9e9af6a15a7dcc6/quinn/src/endpoint.rs#L159) and [socket trait](https://github.com/quinn-rs/quinn/blob/c7b46a969cd315398b504792e9e9af6a15a7dcc6/quinn/src/runtime/mod.rs#L44) | A custom asynchronous socket can be integrated. The integration seam is not a ready-made traversal/relay implementation. |
| [Rebinding](https://github.com/quinn-rs/quinn/blob/c7b46a969cd315398b504792e9e9af6a15a7dcc6/quinn/src/endpoint.rs#L269) | An endpoint can change its local socket; the docs warn unreachable connections can be lost. |

QUIC connection migration helps an established connection handle an address change; it is not initial peer discovery. [QUIC migration, RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html#section-9). The source above is a research pin, not a selected released dependency; the separately observed released documentation has different socket ownership types, so no exact API compatibility with that release is inferred.

**Consequence for the options:** retaining upstream Quinn is feasible for a reachable Host profile. Promising consumer-network traversal and a blocked-UDP fallback additionally means adopting or owning the discovery, probing, relay and authorization integration. The cost is broader than adding a STUN request to `connect`.

## Three checks that enrollment must not collapse

1. **Which peer is this?** The handshake proves possession of the key or certificate identity selected by the transport. An address change need not change that identity; a copied label is not the same proof.
2. **Is that peer still a member I may connect to?** The application's membership record, its freshness and any expiry/revocation decide this. Knowing a cryptographic identity does not enroll it automatically.
3. **What may it do here?** The addressed Host still admits the actual operation and resource: viewing a terminal, controlling input, accessing a repository or terminating work need not have identical authority.

Central enrollment could supply the trusted peer information without an additional manual SSH-style pairing ceremony. That is a possible integration of the existing trust requirement, not removal of peer verification. The concrete ceremony and whether a new device requires another trusted device's approval remain proposed/open in the preliminary design.

### The unavoidable stale-list example

Gateway G cached a list allowing Host H. Later, Central removes H while G cannot receive updates. G has no information distinguishing that removal from “H is still allowed.” Signing the old list proves its origin; it does not make the old membership current.

O10 therefore needs the owner to choose the allowed offline interval and behavior when authority cannot be refreshed, separately for new admission and an already established connection. Candidate mechanisms include bounded credentials, update-driven removal and checking a current authority, but each carries an availability/revocation tradeoff. This note selects none and invents no expiry number. Even an expiry policy depends on the declared clock and freshness assumptions.

This is separate from the application's database-writer lease. A network membership change, terminal-controller change and write-lease expiry may require different outcomes; networking evidence cannot silently unify them.

## Tailscale: a mature overlay, with discovery and relays inside the client

Tailscale gives participating applications or machines an encrypted IP network. The coordination service distributes peer identities, candidate addresses, expiry and policy. Clients discover and choose working paths; WireGuard protects traffic before it enters a direct or relayed carrier.

### How a path becomes direct

The client combines public mappings learned through STUN with local addresses, available router port mappings and configured addresses. Magicsock carries discovery and peer traffic through shared UDP handling rather than creating a separate external connection for every terminal. Discovery Ping/Pong messages test candidates. A `CallMeMaybe` message carried over DERP asks the other peer to probe back, creating the reciprocal traffic NAT traversal needs. An authenticated, outstanding probe response can promote a usable path; selection also considers latency and path preference. This is not “dial the first IP in Central's list.”

Primary code: [candidate gathering](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/wgengine/magicsock/magicsock.go#L1293), [reciprocal discovery](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/wgengine/magicsock/endpoint.go#L2174), [send/path behavior](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/wgengine/magicsock/endpoint.go#L1112).

### Two different relay paths

- **DERP:** the normal native client opens TCP, negotiates TLS for an HTTPS endpoint, and uses HTTP Upgrade into DERP's framed protocol. An actual WebSocket variant also exists; it is not the framing used by every native connection. The relay forwards already encrypted WireGuard packets. Outer TLS ends at the relay; inner WireGuard encryption ends at the peer. This can work with outer UDP blocked if the actual TCP/TLS/upgrade route and name resolution are allowed. Ordinary HTTPS reachability alone is insufficient proof. [DERP connection implementation](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/derp/derphttp/derphttp_client.go#L342).
- **Tailscale Peer Relay:** another eligible tailnet device relays through a UDP/Geneve path. This helps when both peers can reach it over UDP, but does not rescue an endpoint that cannot send any outer UDP. The [peer-relay requirements](https://tailscale.com/docs/features/peer-relay) explicitly require access to the relay's UDP port. The broader connection overview's blocked-UDP wording must be read with this more precise requirement.

Discovery continues when addresses, activity or path confidence change. Exact heartbeat constants in one source revision are implementation policies, not a guaranteed NAT lifetime, reconnection bound or battery result.

### Coordination outage, expiry and removal

An ordinary control error retains the current network map; a received explicit node-removal result is handled differently. Known peer expiries are enforced locally by changing the expired peer state/key and rejecting sends. A newly issued remote revocation still needs delivery to the enforcing node. Therefore a useful direct session can outlast a coordination outage, while an already-known credential deadline can still end access. These are different cases. [Control result handling](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/ipn/ipnlocal/local.go#L1937), [local expiry](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/ipn/ipnlocal/expiry.go#L92).

Offline restart is conditional: the inspected cache path depends on build support, capability/configuration and retained state. It is not evidence that every embedded node can boot offline from its private key alone. Tailnet Lock additionally demonstrates locally verified node-key signatures; it does not by itself supply every device's fresh revocation state. [Node-key signature verification](https://github.com/tailscale/tailscale/blob/9d5313662a594ad9b595483153301941ae75e808/tka/tka.go#L688).

### Embedding and Headscale

`tsnet` is a Go API that embeds the userspace WireGuard engine, magicsock and an IP stack inside the application. `libtailscale` wraps it in C/Swift-facing APIs; it does not replace the Go runtime with native Rust networking. Its connection wrapper creates a local socket pair and copy goroutines. Its stream-shaped C connection interface must not be assumed to provide the datagram semantics Quinn needs without a separate check. [Native wrapper](https://github.com/tailscale/libtailscale/blob/dacde75057ff350e146505829beff446e6823966/tailscale.go#L406).

There are concrete iOS device/simulator build targets and Swift framework instructions. That establishes packaging source, not successful AgentStudio embedding, background survival or a no-unsafe first-party bootstrap. [Build definitions](https://github.com/tailscale/libtailscale/blob/dacde75057ff350e146505829beff446e6823966/Makefile#L33), [Swift framework guidance](https://github.com/tailscale/libtailscale/blob/dacde75057ff350e146505829beff446e6823966/swift/README.md).

**Headscale replaces coordination, not the client datapath.** It still needs Tailscale-protocol clients and reachable relays. Its inspected example leaves embedded DERP off and uses Tailscale's relay map by default, so self-hosted coordination is not automatically self-hosted relaying. [Headscale relay configuration](https://github.com/juanfont/headscale/blob/520eb6f9c7f90bad7a5358ea818267edf4d0b4de/docs/ref/config-example.yaml#L122).

Version compatibility matters: inspected libtailscale imports Tailscale `1.104.1`; current Headscale's deleted-node path documents removal handling for clients `1.106+`. That pair needs qualification. It would be incorrect to combine current-main behavior and the embedded release as if they were one target. [libtailscale manifest](https://github.com/tailscale/libtailscale/blob/dacde75057ff350e146505829beff446e6823966/go.mod#L1), [Headscale map handler](https://github.com/juanfont/headscale/blob/520eb6f9c7f90bad7a5358ea818267edf4d0b4de/hscontrol/noise.go#L802).

**Fit with Central:** it could integrate with or drive a Tailscale-compatible coordination service. Implementing that protocol in Central is substantially more than publishing a list of keys. Copying magicsock's design into a new Rust transport would also mean owning the probing, path state, relay protocol and compatibility work; no such implementation is supplied by Quinn alone. No cost or performance measurement of these routes was made.

## Iroh: application connections addressed by endpoint key

Iroh supplies a Rust/Tokio application endpoint rather than a whole-machine virtual IP network. An endpoint's key identifies it; discovery supplies possible routes to that key; the peer QUIC/TLS handshake authenticates it. The application still admits fleet members and individual operations.

### Routes and the actual relay transport

The caller can supply an endpoint key with direct/relay addresses, or install address lookup services. An injectable `AddressLookup` interface and an in-memory lookup are present, so a fleet directory could supply route information without becoming the transport implementation. Default presets also install public discovery/relay services; privacy and infrastructure ownership therefore require an explicit configuration choice. [Lookup interface](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh/src/address_lookup.rs#L335).

At the inspected main pin, address observation uses QUIC Address Discovery (QAD), and noq's NAT-traversal extensions exchange candidates and initiate attempts. Supplied direct addresses can also start a connection; “every Iroh connection must start through a relay” is not the inspected contract. Path selection prefers a usable direct IP path while retaining a relay backup. Selection and migration are source behavior, not measured recovery times.

The native relay client/server use **WebSocket over TCP**, normally TLS-protected for secure relay URLs. This corrects older overview wording describing a different custom upgraded stream. QAD's optional QUIC/UDP service is separate from relay data delivery. Thus the relay data leg can operate with UDP blocked, subject to DNS, TCP/TLS, WebSocket, proxy and relay-admission reachability. [Actual relay client](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh-relay/src/client.rs#L255), [TCP/TLS wrapper](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh-relay/src/client/tls.rs#L66).

The relay terminates outer WebSocket/TLS but forwards the inner peer QUIC packets. End-to-end encryption belongs to that inner connection. TCP's ordered delivery beneath those packets can affect relayed performance; direct-UDP QUIC claims do not transfer unchanged. Neither path was benchmarked here. Test source for UDP blocking exists, but permits DNS and was not run by this research.

### Peer identity is not fleet admission

The inspected TLS verifier uses TLS 1.3 raw Ed25519 public keys, checks the intended outgoing endpoint key and verifies handshake signatures. It is not a fleet member database. Rust endpoint hooks can reject outgoing attempts or authenticated handshakes; already-open session revocation and per-operation authority remain application work. [TLS verifier](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh/src/tls/verifier.rs#L17), [admission hooks](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh/src/endpoint/hooks.rs#L47).

A Central-issued membership record could bind an endpoint key to an enrolled device; sharing an Ed25519 algorithm does not itself prove that every machine-signing and transport key should be the same key. Removing a peer only from relay admission cannot revoke its existing direct application connection. Zero-RTT, if selected, needs separate effect/admission treatment.

### The Quinn descendant is now noq

Current Iroh main resolves the `n0-computer/noq` project. This is a material Quinn descendant, not a patch name that can safely be substituted for upstream Quinn without qualification:

| Observed extension | Consequence |
| --- | --- |
| Multipath and path state APIs | Several paths can be managed inside a peer connection; this does not mean application data is striped over every path. |
| Observed-address and NAT-traversal extensions | Iroh's reachability machinery relies on functionality beyond the inspected upstream endpoint API. |
| Server migration during the handshake | The fork's documentation explicitly calls the enabled option noncompliant with RFC 9000; this is a deliberate protocol customization to qualify. |
| Newer stream affinity | The exact main pin has additional stream/path APIs not established for the published FFI dependency. |

Primary: [noq transport extensions](https://github.com/n0-computer/noq/blob/2f3ba68ab18329697a5c4b8330ff1e93fa1b78ce/noq-proto/src/config/transport.rs#L386), [Iroh's enabled defaults](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh/src/endpoint/quic.rs#L152), [dependency patch](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/Cargo.toml#L62).

No complete ancestry, patch-size, security or reliability comparison with a chosen upstream commit was performed. The old S32 upstream-Quinn selection must therefore be explicitly revisited if this route is selected. The no-Ghostty-fork requirement does not itself decide the separate networking-dependency choice.

### Mobile and maturity limits

Official Swift packaging and simulator/device build/test definitions exist; the inspected published wrapper uses UniFFI and resolves Iroh `1.4.1`/noq `1.4.0`, while current main resolves a different noq commit. Not every Rust hook/lookup API was found in the Swift wrapper. A Rust Gateway using Iroh's Rust API has a different boundary from a Swift app consuming that wrapper. Neither closes AgentStudio's own embedded-runtime startup/IP6 question. [FFI manifest/package](https://github.com/n0-computer/iroh-ffi/blob/66a8d619a4d791d458d582f312df6e0ab42bc541/Package.swift#L26).

The inspected main also enables an optional Apple batching feature whose manifest calls the APIs private. Selected features, platform support and distribution acceptance need qualification; this is not proof that every configuration is rejected. [Feature definition](https://github.com/n0-computer/iroh/blob/2c12bb58f47fcd7910c1f9c61c026abef9325f47/iroh/Cargo.toml#L149).

[Delta Chat's own deployment account](https://delta.chat/en/2024-11-20-webxdc-realtime#technical-background-on-our-irohp2p-integration) is useful historical adopter evidence. It does not audit current dependencies or prove this product's mobile behavior. Vendor direct-connection percentages vary by date/use case and are not this deployment's success rate; the earlier approximate “10% relay” premise should not be a product planning constant.

## Nebula: learn from the lighthouse/CA split, keep the UDP limit visible

Nebula separates a certificate authority, discovery lighthouses and optional data relays. The CA signs host/network/group identity. Lighthouses receive endpoint reports, answer discovery queries and notify the other peer to send packets back. Hosts authenticate certificates locally in their Noise handshake. A lighthouse need not be the CA or a relay.

This is useful prior art for facilitation without carrying every application packet. It still requires reachable discovery infrastructure, credential distribution and a process for delivering trust changes. A local packet firewall is not AgentStudio's repository/terminal-operation authority.

**Its relay does not solve blocked UDP.** Core writers and relay legs use UDP; relay establishment requires usable UDP tunnels to the relay/target. The [official NAT guide](https://nebula.defined.net/docs/guides/nat-traversal/) expressly excludes a TCP fallback. A UDP port numbered 443 is still not HTTPS. [UDP listener](https://github.com/slackhq/nebula/blob/2bb1ca99266b323f63d10e9497a00996bf681f3a/udp/udp_darwin.go#L29), [relay establishment](https://github.com/slackhq/nebula/blob/2bb1ca99266b323f63d10e9497a00996bf681f3a/relay_manager.go#L58).

Certificate expiry/blocklists are locally enforced. Existing tunnels are rechecked; invalid certificates close by default, while a configuration can retain certain invalid tunnels. A loaded blocklist forces closure regardless of that setting. Crucially, lighthouses do not distribute blocklists: a host with stale trust data does not learn a new revocation through local verification alone. [Existing-session validation](https://github.com/slackhq/nebula/blob/2bb1ca99266b323f63d10e9497a00996bf681f3a/connection_manager.go#L493), [blocklist distribution contract](https://nebula.defined.net/docs/config/pki/#pkiblocklist). No revocation latency SLA is established here.

The Go core also has a userspace/gVisor network API, so it is too broad to say every possible embedding requires a system VPN. The inspected Mobile Nebula iOS app, however, uses a packet-tunnel extension and Go framework. That is not proof of a new app-only iOS integration. Its wrapper reuse license was not established; core MIT terms do not automatically cover another repository. [Userspace service](https://github.com/slackhq/nebula/blob/2bb1ca99266b323f63d10e9497a00996bf681f3a/service/service.go#L57), [mobile entitlement](https://github.com/DefinedNet/mobile_nebula/blob/0bb72f8b622193229489cb320c6add53d5c88dff/ios/NebulaNetworkExtension/NebulaNetworkExtension.entitlements#L5).

## Brief alternatives: compare the implemented path, not the category name

These are narrower source checks than the three main studies. Each row has concrete primary anchors; none is a complete platform/security audit.

| Candidate | What is supplied | Relay/blocked-UDP distinction |
| --- | --- | --- |
| rust-libp2p | Key-derived peer identity, composed transports, circuit relay and DCUtR direct-upgrade machinery. Application membership/discovery inputs are separate. | The [relay example](https://github.com/libp2p/rust-libp2p/blob/6782cb8a08f5c99c158ef8b24508af741bf62837/examples/relay-server/src/main.rs#L50) composes TCP/Noise/Yamux and QUIC. End-peer security is layered through the circuit. A reachable TCP relay is possible; a particular deployed WSS route was not qualified. |
| str0m | A Rust Sans-I/O WebRTC state machine. The caller owns sockets, time, signaling and candidate gathering. | [STUN/TURN gathering is explicitly outside its scope](https://github.com/algesten/str0m/blob/13741a4a9450b0fda6d1f42dd9d6ff17138e4ffb/docs/ice.md#L4). Supplying a relay candidate is not a built-in TURN/TLS transport. A blocked-UDP composition remains unproven. |
| WebRTC.rs | An async wrapper over a separate Sans-I/O core; data channels use DTLS/SCTP, not the selected Quinn interface. | The inspected [TURN gatherer](https://github.com/webrtc-rs/webrtc/blob/3c4584ae984a004def73168782fa86d59f12263a/src/peer_connection/transport/turn_relayer.rs#L209) actively allocates UDP TURN but skips secure/non-UDP TURN. Separate ICE-TCP support is not a general TURN/TLS fallback. |
| ZeroTierOne | A C++ overlay with cryptographic node identity, discovery roots and separate network controllers. | Optional TCP proxy fallback exists. Its framing is pseudo-TLS, not an ordinary HTTPS/TLS connection; firewall acceptance and mobile behavior remain unproved. [Proxy component](https://github.com/ZeroTier/ZeroTierOne/blob/899352e38405968516bb12a770f0ac02f6058fa8/tcp-proxy/README.md), [fallback implementation](https://github.com/ZeroTier/ZeroTierOne/blob/899352e38405968516bb12a770f0ac02f6058fa8/service/OneService.cpp#L4387). |
| NetBird | A Go/WireGuard overlay with management, signaling and a custom relay; these roles exceed a small endpoint library. | Relay clients can choose [QUIC or WS/WSS](https://github.com/netbirdio/netbird/blob/1bb2fd37361b6ac6cb4d7df37f959d7a9583bdad/shared/relay/client/dialers_generic.go#L27). WS/WSS can handle blocked UDP when reachable; forced QUIC cannot. Inner WireGuard encryption is distinct from the relay leg. |

WebRTC's generic standards support must not be substituted for a particular crate's implemented TURN transports. Similarly, inner TCP carried inside an overlay says nothing about whether the overlay's outside path uses UDP or TCP.

### Compare identity, coordination and the direct path

This combines the three detailed studies with the brief alternatives. A transport identity is not an application user/role or permission to execute an operation.

| System | Identity and coordination | Direct-path technique |
| --- | --- | --- |
| Tailscale | Node/WireGuard public keys and network configuration distributed by a compatible control service. | STUN/endpoint gathering, authenticated disco probing and reciprocal UDP punching. |
| Iroh | Ed25519 endpoint key authenticated by peer TLS; lookup and application membership are separate. | Direct address input, QAD observations and noq candidate/traversal extensions. |
| Nebula | CA-signed host/network/group certificate; lighthouse discovery is a different role. | Lighthouse endpoint reports/notifications and UDP handshake/punching. |
| rust-libp2p | Public-key-derived PeerId; application supplies directory/admission and peer/relay addresses. | Identify plus DCUtR upgrade over composed transports; no guaranteed direct success. |
| str0m | Expected DTLS fingerprint from setup; caller supplies trusted signaling and candidate gathering. | ICE checks on supplied candidates; caller drives actual socket traffic. |
| WebRTC.rs | Wrapper uses DTLS/SCTP and SDP signaling; core identity-binding audit remains a gap. | ICE candidate processing, active/passive TCP path and UDP TURN gathering at this pin. |
| ZeroTierOne | Cryptographic node identity; roots aid discovery while a network controller signs membership/configuration. | UDP discovery/rendezvous and path management in the overlay. |
| NetBird | WireGuard peers enrolled/configured by management; signaling is a separate connection-setup service. | ICE-driven direct discovery/punching. |

### Compare relay carriers and encryption

| System | Relay's outside transport | What protects peer application data |
| --- | --- | --- |
| Tailscale | DERP native TCP/TLS upgrade; actual WS variant also exists. Peer Relay is UDP/Geneve. | Inner WireGuard, independent of outer DERP TLS. |
| Iroh | WS/WSS over TCP; optional QUIC QAD is a separate discovery service. | Inner peer QUIC/TLS, independent of relay WSS. |
| Nebula | UDP only; no TCP escape path. | Peer Noise/session encryption through the relay envelope. |
| rust-libp2p | Circuit runs over the chosen transport; inspected example supports TCP and QUIC. | A separately authenticated/multiplexed end-peer circuit; exact security is part of the composition. |
| str0m | External TURN allocation/carrier adapter required; no complete built-in fallback demonstrated. | DTLS/SCTP data-channel stack; signaling identity still needs binding. |
| WebRTC.rs | Inspected TURN allocation accepts UDP and skips secure/non-UDP TURN. | DTLS/SCTP wrapper path; this walk did not audit the entire cryptographic core. |
| ZeroTierOne | Optional TCP proxy with pseudo-TLS framing, not HTTPS/TLS. | Inner encrypted overlay packet; no outer TLS guarantee from the fake record header. |
| NetBird | QUIC or WS/WSS; configured mode matters. | Inner WireGuard; the relay's TLS/QUIC is a separate layer. |

An IP overlay supplies private network addresses and carries normal IP traffic for its participating applications or devices. An application connection library supplies connections/streams to its own caller. Running application QUIC inside a WireGuard overlay can retain both layers; their CPU, memory and latency cost must be measured rather than inferred from either component's reputation.

## Runtime, license and self-hosting comparison

License entries describe inspected repository declarations, not a full dependency/compliance assessment or advice about a distribution.

| Candidate | Runtime/layer | License declaration | Mobile/self-hosting evidence and limit |
| --- | --- | --- | --- |
| Tailscale / libtailscale / Headscale | Go; WireGuard + userspace IP network; C/Swift wrapper adds a native boundary. | Root repositories: BSD-3-Clause. | iOS build targets exist. Coordination and relays can be separate self-hosted services; Headscale alone does not replace the client or its default relay dependencies. |
| Iroh / noq | Rust/Tokio; application QUIC connections. | MIT OR Apache-2.0. | Swift packaging and platform test definitions exist; this app's physical-device/lifecycle proof does not. Own relay and lookup can replace default infrastructure, with actual integration still required. |
| Nebula core | Go; IP overlay, optional userspace stack. | MIT; mobile wrapper grant not established. | Core roles are self-hostable. Existing iOS wrapper is a VPN extension; app-only embedding remains unqualified. |
| rust-libp2p | Rust; configurable P2P transport/behavior stack. | Inspected root: MIT. | Self-hosted relay example exists; no iOS product guarantee established. |
| str0m | Rust; caller-driven WebRTC. | MIT OR Apache-2.0. | README lists iOS as compiled, not tested; caller supplies discovery/TURN/signaling integration. |
| WebRTC.rs | Rust; async WebRTC/DTLS/SCTP wrapper. | MIT/Apache-2.0. | No iOS guarantee established in this walk. Self-hosted signaling/TURN are additional services and must match the client's actual transports. |
| ZeroTierOne | C++; managed overlay components. | Core/agent MPL-2.0; `nonfree/` and external components have separate terms. | Official iOS app exists, not proof of app-only embedding. Root, controller and TCP proxy hosting are distinct choices. |
| NetBird | Go; WireGuard overlay and control/relay services. | Client/default BSD-3-Clause; named management/signal/relay directories AGPLv3. | Self-hosted product exists; inspected iOS SDK uses a packet tunnel. Enrollment-key expiry is distinct from removing an enrolled peer. |

Primary license/runtime detail and selected-source pins are retained in the topic source reports linked below. No adoption is justified solely by a permissive-looking top-level license or a platform appearing in a build matrix.

## Where Cloudflare fits

An ordinary Worker can host HTTPS coordination/signaling and WebSocket connections. Its documented HTTP/3 support means handling HTTP requests over QUIC, not exposing arbitrary incoming QUIC datagrams or the Quinn endpoint API. The inspected protocol support list contains no raw UDP socket API. Its direct TCP API has distinct inbound service-binding/outbound rules. [Workers protocol table](https://github.com/cloudflare/cloudflare-docs/blob/34d908abc615fdf22eeb386b171b9657b9abcf38/src/content/docs/workers/reference/protocols.mdx#L11).

Workers/DOs can forward framed binary WebSocket payloads, including ciphertext when peers retain the keys. That could implement a **particular application relay**, but it is not automatically compatible with DERP, Iroh's relay protocol or TURN. Outer WSS terminates at Cloudflare; the required end-to-end encryption must remain inside. Message buffering, limits, disconnects, version compatibility and backpressure need their own proof. No such relay was built here.

**Realtime TURN** is a separate service. Client-to-service TCP/TLS options do not mean arbitrary TCP relaying to the other peer; its FAQ explicitly excludes RFC 6062. It also must match the client's actual TURN support. **Spectrum** is a separate TCP/UDP proxy product, not a Worker script or a discovery/member registry. [TURN limitation](https://github.com/cloudflare/cloudflare-docs/blob/34d908abc615fdf22eeb386b171b9657b9abcf38/src/content/docs/realtime/turn/faq.mdx#L178). No pricing, deployment or operational acceptance was established.

## How these choices change the cost of “Central facilitates”

| Possible route | What it reuses | What this project would still own |
| --- | --- | --- |
| Upstream Quinn with reachable Hosts | The selected QUIC transport and its existing TLS/socket APIs. | Reachability assumptions, peer directory/admission, and any later punching/relay implementation. A public or otherwise reachable Host profile is a smaller promise than arbitrary consumer networks. |
| Iroh as a connection library | Key-addressed QUIC, path discovery/switching and relaying. | Central membership/lookup integration, app authorization/revocation, relay operations, platform proof and an explicit revisit of S32's upstream-Quinn choice. |
| Embedded Tailscale/Headscale | Existing overlay discovery, WireGuard and DERP machinery, with compatible coordination options. | Go/native integration and lifecycle, control-protocol compatibility, state/enrollment and relay operation. App-only embedding is still an overlay; it does not leave the runtime pure Rust. |
| Nebula-style facilitation | A useful CA/discovery/relay separation and existing overlay implementation. | Certificate/config/revocation distribution and mobile/runtime integration; no supplied blocked-UDP/TCP fallback. Learning from the model does not require adopting the overlay. |

This is a tradeoff map, not a selected architecture. No source proves the smallest code change, lowest memory use, fastest terminal echo or best operational fit. A separately installed VPN app is a packaging constraint; requiring no overlay at all is a stronger architectural constraint. The owner's intended boundary should remain explicit when narrowing the candidates.

## Experiments that would discriminate, not just demonstrate an echo

All are proposed and unrun. The real implementation/version and expected outcome must be selected first; this note authorizes no listener, firewall, device or service operation.

1. **Same workload, three routes:** two real endpoints exchange control and terminal-sized streams directly, through a forced relay and with all outer UDP denied. Supply/declare name resolution separately. Record the selected outer path, reconnect behavior, memory/backpressure and input-to-visible-echo measurement. A forced relay on a UDP-capable network cannot pass the blocked-UDP claim. No acceptance latency threshold is invented.
2. **Roaming without identity confusion:** change a device's network during an active terminal/agent attachment. Observe whether the connection survives, is replaced or fails, then apply the application's declared reattachment behavior. The same conversation label or screen image cannot prove the same running turn survived.
3. **Authority partition:** establish a connection, withhold Central updates, revoke the peer elsewhere and advance the selected expiry policy. Separately test new admission and existing-session restrictions. Expected outcomes come from O10; this cannot be judged before that policy is selected.
4. **Exact embedded iOS boundary:** use the chosen dependency/version/features in the actual app, then foreground, suspend/resume and change Wi-Fi/cellular. Audit first-party generated/bootstrap code separately. Simulator echo/build definitions do not establish device or background behavior.
5. **Central and relay failures separately:** stop only the coordination fixture, then only the relay fixture, preserving an existing direct route where applicable. Confirm which work depends on each and what recovery can actually observe. No test should substitute killing a caller for replacing its execution custodian.

## Source map and coverage

Four disjoint native source-support tasks supplied the Tailscale, Iroh, Nebula and alternatives/hosting reports. The Lead read those reports, reopened the deciding transport/admission/expiry/embedding functions, checked official Tailscale requirements and the upstream Quinn/IETF boundaries, and retained exact gaps. This was source research, not formal independent validation.

| Source | Inspected revision / role |
| --- | --- |
| Tailscale main | `9d5313662a594ad9b595483153301941ae75e808` |
| libtailscale | `dacde75057ff350e146505829beff446e6823966`, importing Tailscale `1.104.1` at `9a522a9786c97eb7910c01ccb7bd66557b04c910` |
| Headscale | `520eb6f9c7f90bad7a5358ea818267edf4d0b4de` |
| Iroh main / release cross-check | `2c12bb58f47fcd7910c1f9c61c026abef9325f47` / release `1.4.1` source `d6c6963b9602d1b8dd2ba53b6519e7eb19cc7940` |
| noq / Iroh FFI | `2f3ba68ab18329697a5c4b8330ff1e93fa1b78ce` / `66a8d619a4d791d458d582f312df6e0ab42bc541`; the FFI resolves registry noq `1.4.0` |
| Nebula core / mobile wrapper | `2bb1ca99266b323f63d10e9497a00996bf681f3a` / `0bb72f8b622193229489cb320c6add53d5c88dff`; wrapper uses core `1.12.0` |
| rust-libp2p / str0m | `6782cb8a08f5c99c158ef8b24508af741bf62837` / `13741a4a9450b0fda6d1f42dd9d6ff17138e4ffb` |
| WebRTC.rs / ZeroTierOne | `3c4584ae984a004def73168782fa86d59f12263a` / `899352e38405968516bb12a770f0ac02f6058fa8` |
| NetBird / Cloudflare docs | `1bb2fd37361b6ac6cb4d7df37f959d7a9583bdad` / `34d908abc615fdf22eeb386b171b9657b9abcf38` |
| Upstream Quinn | `c7b46a969cd315398b504792e9e9af6a15a7dcc6`, a main-source research pin, not a selected release |

Detailed primary anchor tables, discovery queries, failed/stale lookups and task-specific gaps: [Tailscale](../../../../tmp/practices-research/2026-11-14-networking/tailscale/findings.md), [Iroh](../../../../tmp/practices-research/2026-11-14-networking/iroh/findings.md), [Nebula](../../../../tmp/practices-research/2026-11-14-networking/nebula/findings.md), [alternatives/Cloudflare](../../../../tmp/practices-research/2026-11-14-networking/alternatives/findings.md), and the [parent source ledger](../../../../tmp/practices-research/2026-11-14-networking/research-ledger.md). Primary public permalinks in this note remain usable without the local caches.

The existing [integration constraints](integration-constraints.md) still apply. No control-plane responsibility, network stack, key-freshness tolerance, relay provider, public contract or implementation scope is selected here. Runtime, device, actual blocked-network compatibility, resource and performance acceptance remain unverified.
