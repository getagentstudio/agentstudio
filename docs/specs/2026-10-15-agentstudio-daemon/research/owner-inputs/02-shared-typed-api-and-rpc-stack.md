More research My recommendation: one typed Rust API, multiple thin frontends

Make the Rust gateway the reusable engine, not another protocol server with duplicated implementations.

Your macOS app, iOS app, CLI, and MCP server should all invoke the same typed Rust operations. Only the connection adapters should differ.

Logical architecture. macOS/CLI/MCP can share one running gateway process; iOS embeds the same gateway library.

The design principle is one implementation of SessionApi, not one implementation per transport.

For example, session.list should exist once as a Rust operation. The CLI formats its response as a table, Swift displays it in a sidebar, and MCP exposes it as a tool. None reimplement session discovery.

MCP remains an external integration surface, not your internal host↔gateway protocol.

1. The actual Rust stack I’d choose

I’d revise my earlier MessagePack-RPC recommendation. Use tarpc for RPC semantics, with MessagePack as its binary serialization codec.

Typed RPC	tarpc 0.38 — generated Rust client/server interfaces, correlation, deadlines, cancellation and tracing
RPC encoding	MessagePack through tokio-serde
Remote transport	Quinn QUIC, with a dedicated RPC stream and independent terminal streams
Local transport	tarpc over Unix domain sockets
Swift bindings	UniFFI generates strongly typed Swift async interfaces
MCP adapter	rmcp — uses the shared Rust client and schemars

Why tarpc? It already supports typed service generation, Unix sockets and arbitrary Serde transports. Quinn’s bidirectional streams expose Tokio’s AsyncRead/AsyncWrite traits, so a QUIC stream can be adapted into tarpc’s transport. That QUIC adapter requires a little glue; it is not built in.

2. What the types look like

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct OpenTerminal {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema)]
pub struct TerminalTicket {
    pub id: u64,
}
#[tarpc::service]
pub trait GatewayControl {
    async fn list_sessions()
        -> Result<Vec<SessionInfo>, GatewayError>;
    async fn open_terminal(req: OpenTerminal)
        -> Result<TerminalTicket, GatewayError>;
    async fn claim_control(ticket: TerminalTicket)
        -> Result<(), GatewayError>;
}

tarpc generates Rust client calls with strongly typed arguments and responses. GatewayError, SessionInfo and other domain types live in a shared crate.

The GatewayControl trait defines your request/response contract. The concrete GatewayCore implements the actual behavior.

There are three interfaces to expose, but not three implementations of the behavior.

* RPC commands: list_sessions, open_terminal, claim_control, etc.
* Subscriptions: typed SessionEvent / ConnectionEvent streams, implemented separately from unary tarpc calls.
* Binary streams: TerminalHandle, sending and receiving VT bytes without wrapping every chunk as an RPC call.

The key limitation of tarpc is that it focuses on request/response, not first-class bidirectional streaming. That’s fine here because QUIC already gives you independent streams for terminal output and events.

3. Reuse the gateway without creating extra connections

I’d structure the workspace like this:

crates/
  protocol/
    types.rs          # Shared DTOs, enums, errors
    rpc.rs            # Typed RPC service definitions
    events.rs         # Typed event definitions
  gateway-core/
    sessions.rs       # Session operations
    terminals.rs      # Terminal management
    connection.rs     # Remote QUIC connection
    subscriptions.rs  # Event fanout
  gateway-client/
    client.rs         # One ergonomic client API
    local.rs          # UDS client
    embedded.rs       # Direct gateway-core invocation
  gateway-server/
    daemon.rs         # Local UDS RPC server
  host-daemon/
    rpc.rs            # Host-side RPC implementation
    zmx.rs            # ZMX IPC adapter
  gateway-ffi/
    lib.rs            # UniFFI-generated Swift API
  gateway-cli/
    main.rs           # CLI and MCP entry points
    mcp.rs            # rmcp tool adapter

The most useful abstraction is GatewayClient. Swift and CLI users shouldn’t know whether they’re accessing an embedded service, a local daemon, or a remote host.

Here is how each runs:

Caller	Gateway execution
macOS Agent Studio	Rust client shim → local UDS → shared gateway daemon
iOS Agent Studio	UniFFI → embedded GatewayCore
CLI	Rust client → existing local gateway, or standalone direct mode
MCP server	rmcp → Rust client → local gateway

On macOS, CLI, MCP and the GUI can reuse one QUIC connection through the same gateway daemon.

On iOS, the embedded Rust gateway establishes its own remote connection. You can still put a socketpair between Swift and Rust, but I’d use UniFFI there because it eliminates a serialization and socket hop while keeping a strongly typed Swift API.

4. What actually travels over QUIC?

One Quinn connection

Gateway ↔ host daemon

Control — tarpc + MessagePack

Typed RPC, replies, request IDs, cancellation

Events — typed binary messages

Session changes and connection status

Terminal streams — raw binary

One per attachment, with independent flow control

This separation matters more to latency than choosing between MessagePack and another reasonably fast serializer.

tarpc already multiplexes requests and responses on its RPC transport. Independent QUIC terminal streams avoid mixing a big screen update with control messages.

5. What about quic-rpc, Protobuf or gRPC?

Option	Strength	Why I’d choose or avoid it
tarpc + MessagePack	Rust-native typed calls; UDS support	My first choice for this setup
quic-rpc	Native typed streaming over QUIC	Excellent remote fit, but no built-in UDS adapter; last published version I found is 0.20.0 from May 2025
Protobuf + tonic	Generated schemas, cross-language contracts, streaming	Strong option if Swift must speak the network RPC protocol directly; more tooling and HTTP/2 infrastructure

quic-rpc explicitly targets Rust-to-Rust communication, supports four interaction patterns including bidirectional streaming, and leaves versioning to the application. If you decide most of your control interface should itself be streaming RPC, it’s a credible alternative to tarpc.

6. Two safeguards I’d build into the protocol

First, define protocol-version negotiation and compatibility tests. MessagePack is compact, but a binary codec alone doesn’t guarantee schema evolution. You’ll want to test mixed gateway/host versions, especially when adding fields or enum variants.

Second, keep RPC transport success distinct from command execution success. For a session kill, command send, or terminal input, losing the connection doesn’t prove the operation failed. Define application-level acknowledgements, idempotency keys where appropriate, and meaningful typed errors.

Also, the MCP adapter should expose an intentional subset of operations instead of blindly publishing every privileged gateway method as a tool. The official Rust MCP SDK supports typed tool parameter schemas and both stdio and Streamable HTTP.

Bottom line: I’d build GatewayCore and GatewayClient first, share the Rust DTOs and operation implementations, use tarpc + MessagePack for control RPC, and keep terminal data as raw streams. That gives you a performant, typed system where the CLI and MCP server are genuinely thin adapters—not parallel implementations that eventually drift apart.