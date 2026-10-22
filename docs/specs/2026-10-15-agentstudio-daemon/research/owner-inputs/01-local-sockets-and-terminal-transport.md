Yes. iOS supports Unix domain sockets (AF_UNIX), and Rust can use them directly, including with Tokio.

You can use UnixStream, UnixListener, and socketpair() on iOS. Apple also explicitly supports Unix sockets for communication between apps and extensions sharing an App Group.

What works on iOS?

Scenario	Supported?
Rust ↔ Rust in the same app	Yes
Swift ↔ Rust in the same app	Yes
Tokio UnixStream / UnixListener	Yes
App ↔ extension over Unix socket	Yes, with sandbox/App Group considerations
Separate always-running Rust daemon	Not like macOS
Unix socket between iPhone and Mac	No — Unix sockets are local only

For Agent Studio, the important distinction is that iOS supports local socket IPC, but it doesn’t give you macOS-style daemon execution.

Rust + Tokio example on iOS

use tokio::net::{UnixListener, UnixStream};
async fn start_ipc() -> std::io::Result<()> {
    let path = std::env::temp_dir().join("studio.sock");
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    // Another task can connect:
    let client = UnixStream::connect(&path).await?;
    let (server, _) = listener.accept().await?;
    // Both streams support asynchronous read/write.
    Ok(())
}

Tokio supports both named Unix sockets and anonymous socket pairs (UnixStream::pair()).

How I’d structure Agent Studio on iOS

iOS app process

SwiftUI + embedded Rust gateway

FFI / Tokio channels / Unix socket

Rust + Tokio runtime

Terminal data, sessions, control protocol

QUIC / TCP / WebSocket

Remote host daemon

macOS / Linux • ZMX + PTY

My recommendation:

* Swift ↔ Rust in one process: use FFI and Tokio channels. No socket overhead or framing required.
* Separate app/extension processes: use Unix sockets with an App Group.
* iOS ↔ remote daemon: use your network protocol, not Unix sockets.

One important constraint: iOS normally suspends apps shortly after backgrounding, so an embedded 

Rust socket listener isn’t an always-on service.

The useful architectural point is that your Rust gateway can run on iOS with Tokio and the same protocol logic as macOS, but it will generally be an embedded library rather than an independently running daemon.


Agent Studio: Fast terminal and RPC transport architecture

My recommendation is to use Tokio + Quinn (QUIC) for remote communication, Unix domain sockets for local IPC, and separate reliable QUIC streams for terminal traffic and RPC. Don’t introduce Mosh yet.

The most important finding from inspecting ZMX’s actual source is that ZMX already has a binary IPC protocol. Your Rust host daemon can communicate directly with each ZMX session, without spawning a second terminal emulator or creating an unnecessary PTY.

ZMX currently exposes messages including Init, Input, Output, Resize, Capture, History, and Info over per-session Unix sockets. It also uses libghostty-vt to restore terminal state when clients reconnect.

That substantially simplifies the architecture we discussed previously.

1. Recommended topology

Logical architecture. Each device has its own QUIC connection; each open terminal has an independent stream within that connection.

The important separation is between session lifetime, connection lifetime, and terminal attachment lifetime. ZMX owns the persistent shell; the host daemon owns the application protocol; the gateway owns the live network connection. The UI can disappear without terminating the session.

2. Which transport for each kind of traffic?

Traffic	Transport	Delivery
Commands and responses	QUIC RPC stream	Reliable, request IDs
Session/agent state changes	QUIC event stream	Reliable, ordered
Terminal output	QUIC stream per terminal	Reliable binary bytes
Terminal keyboard input	Same terminal’s bidirectional stream	Reliable, ordered
Terminal resize	Same terminal stream	Reliable; coalesce updates
Cursor presence, transient telemetry	Optional QUIC datagrams	Latest value wins

One physical QUIC connection, multiple logical streams. You don’t need separate UDP sockets for RPC and terminals.

QUIC has per-stream ordering, so a lost terminal-output packet does not necessarily block delivery on another stream. This is the advantage over sending everything through one TCP WebSocket. Quinn provides both reliable streams and unreliable datagrams.

For terminal output, don’t use unreliable UDP packets directly. ANSI/VT sequences form a stateful byte stream. Losing the wrong byte can corrupt the rendered screen.

The distinction between QUIC and Mosh

QUIC terminal stream

Preserves the complete sequence of terminal bytes, even during packet loss.

Mosh state synchronization

Synchronizes rendered terminal state instead of retransmitting every intermediate screen.

Mosh’s actual advantage isn’t simply UDP. It synchronizes terminal state, tolerates network changes, and predicts local typing. It provides a different application protocol, not just a faster socket.

This means ZMX + QUIC gives you durable sessions and reliable remote rendering, whereas Mosh adds more sophisticated behavior under poor network conditions. That’s a potential later optimization, not something you need to get the first design working.

3. Local IPC: macOS and iOS should be different

There are two distinct boundaries:

Boundary	Recommendation	Why
ZMX ↔ host daemon	Tokio UnixStream	ZMX’s existing IPC
macOS Rust gateway ↔ Agent Studio	Unix socket if separate processes	Fast, clean process isolation
iOS Rust gateway ↔ Agent Studio	Rust library through UniFFI	Both should live in the same iOS process
Rust gateway ↔ remote host daemon	Quinn / QUIC	Multiplexed network transport

Tokio has native Unix socket support. UniFFI can expose Rust async functions to Swift, so the mobile app doesn’t need a socket simply to talk to its own embedded Rust networking library.

On macOS, I’d use a separate Rust gateway helper if you want its connection and supervision logic isolated from the Swift app. If it’s already embedded, FFI is equally reasonable. A Unix socket is fast, but same-process calls avoid the IPC hop altogether.

On iOS, assume the gateway can be suspended when the app backgrounds. Apple does not permit an ordinary app to maintain an arbitrary networking daemon indefinitely. The persistent session must remain on the remote host.

4. The actual protocol I would build

Keep JSON-RPC for application commands, and make terminal data binary.

QUIC connection: device-42 → host-7
│
├─ Control stream (bidirectional)
│   JSON-RPC 2.0, length-prefixed
│   session.list / session.create / terminal.attach
│   terminal.detach / terminal.claimControl
│
├─ Events stream (host → gateway)
│   session.started / session.ended
│   session.updated / connection.status
│
├─ Terminal stream: session-A (bidirectional)
│   OUTPUT   → raw ANSI/VT bytes
│   INPUT    ← raw keyboard bytes
│   RESIZE   ← rows, cols
│   SNAPSHOT → restoration bytes
│
└─ Terminal stream: session-B (bidirectional)
    ...independent from session-A

For example, control commands remain readable:

{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "terminal.attach",
  "params": {
    "sessionId": "codex-router-main",
    "cols": 160,
    "rows": 44
  }
}

The response authorizes/binds a QUIC terminal stream to that session. From that point onward, send actual terminal bytes, not JSON strings or base64.

A simple terminal frame can be:

[u32 frame_length][u8 message_type][payload]
message_type:
  1 = OUTPUT      raw bytes
  2 = INPUT       raw bytes
  3 = RESIZE      u16 rows + u16 cols
  4 = SNAPSHOT    raw VT restoration bytes
  5 = STATUS      attach/control status

This is a proposed Agent Studio wire format, not ZMX’s private wire format. ZMX has its own 8-byte IPC header and frozen tag values. Keep that protocol behind the host-side ZMX adapter. ZMX IPC implementation⁠￼

For Rust libraries:

Job	Choice
Async runtime	tokio
QUIC	quinn
Buffering	bytes
RPC serialization	serde + serde_json
Framing	tokio-util::codec
Swift bindings	uniffi
Instrumentation	tracing, histograms

LengthDelimitedCodec already handles bounded, length-prefixed frames.

I would not bring in jsonrpsee solely for this. It’s good for HTTP/WebSocket JSON-RPC, but QUIC isn’t its standard built-in server transport. If you prefer typed Rust-to-Rust RPC instead of standard JSON-RPC, quic-rpc⁠￼ is worth examining; it provides streaming RPC over QUIC-compatible transports.

5. Three things in ZMX’s implementation matter a lot

These are based on inspecting ZMX’s current daemon implementation⁠￼.

Multiple viewers and terminal leadership

ZMX allows multiple attachments, but has one leader controlling the terminal size. Input from another client can make it leader. A phone connecting with 40 columns could unexpectedly resize the desktop’s 160-column terminal.

I’d put a single control/resize owner per session in your host daemon, while allowing multiple read-only viewers. You can use one shared ZMX attachment per session and fan out its output to devices.

Backpressure is a real correctness issue

ZMX queues output per connected local client; its output buffer can accumulate when a client stops draining. Your Rust host must keep reading ZMX independently of slow remote viewers.

Give each remote subscriber a bounded queue. If it falls too far behind, stop streaming to that viewer and resynchronize its screen from ZMX, rather than accumulating unbounded memory or silently dropping arbitrary ANSI bytes.

Restoration and command delivery are separate

ZMX’s reattach logic can serialize terminal state; Capture can also return screen content with bounded scrollback. But this does not make keyboard input safe to replay after a disconnect.

Never automatically resend an input sequence when its delivery is uncertain. Distinguish RPC accepted, request applied, and terminal output observed.

For the shared-ZMX-attachment design, I would validate Capture/VT restoration first. If it doesn’t correctly rebuild a fresh Ghostty surface, use a temporary ZMX attachment to obtain the snapshot while preserving the canonical live reader.

Also, the host should retain any canonical terminal transcript separately from what it delivers to viewers. UI resynchronization should not discard audit/log bytes.

6. How fast will this actually be?

The meaningful metric is keyboard-to-visible-echo latency, not raw socket throughput.

Scenario	Useful expectation
Same-process Rust → Swift	No network hop; FFI/copying overhead
Local Unix socket	Usually sub-millisecond for small exchanges
QUIC on a local LAN	Dominated by LAN latency and scheduling
QUIC over the internet	Dominated by network RTT, route and packet loss
Relay instead of direct connection	Additional network latency, sometimes substantial

These are expectations, not benchmarks of your implementation. A remote character that must be echoed by the shell normally requires a round trip regardless of whether its command wrapper is JSON or binary.

As an example, if the path RTT is 40 ms, saving 0.1 ms of serialization won’t be noticeable. Improving the route or adding genuinely safe local echo could be.

The practical performance choices are:

* Don’t send each output byte separately. Coalesce naturally occurring PTY chunks and cap intentional batching delay to a few milliseconds.
* Give control/input streams higher priority than bulk transfers. Quinn exposes SendStream::set_priority.
* Don’t marshal every terminal byte separately across Swift FFI. Deliver byte buffers.
* Don’t continuously stream every hidden terminal at full output rate when a snapshot on activation would suffice.

For your existing Tailscale-based machines, verify direct versus relayed connectivity before optimizing serialization. Tailscale documents direct connections as generally lower-latency than DERP/peer relays.

If you eventually want devices to connect without installing Tailscale, Iroh is worth evaluating for hole punching and relay discovery. It solves a connectivity problem that Quinn by itself doesn’t solve.

7. What I would implement and benchmark first

Build a single vertical slice:

Ghostty → gateway → QUIC → host daemon → ZMX, with keyboard input working in reverse. Make a second device attach to the same session and test controller handoff.

Measure p50/p95/p99 for local IPC RTT, remote RPC RTT, keystroke-to-echo, output throughput, reconnect-to-render, and maximum buffered bytes per slow client. Then test Wi-Fi → cellular, packet loss, and two clients with different viewport sizes.

My architecture choice is therefore: Tokio UDS locally, Quinn QUIC remotely, JSON-RPC for commands, raw VT byte streams for terminals, and ZMX as the durable session owner. Mosh-style screen synchronization is worth adding only if the measurements show the reliable byte stream behaves poorly on mobile networks. A QUIC stream already handles most of what you need, without implementing a second terminal protocol.

And here is the information that we've researched. Can you please check with the advisor and do a full survey on what we want to do and what needs to change, the features we need to cover for the Git, and a lot of other features, and how we set up the bus. Right now the bus is still Swift itself, different actors, but I think it might be better technology to do that in Rust and have the Swift system just be a client. I don't know what kind of speed and performance we need with the sockets, so that's important too.