More research Yes. Connection and session must be independent concepts. I’d make this a fundamental invariant of the Agent Studio architecture, not just a reconnect feature.

A session is a durable logical resource. A connection is a temporary communication channel. An attachment links a client to a session.

The separation

Many connections can access many sessions. Disconnecting a device doesn’t terminate a session.

Concept	Lifetime	Owns
Connection	Network connection	QUIC, authentication, health
Session	Until explicitly terminated	Stable ID, ZMX process, terminal state
Attachment	Until detach/disconnect	Viewer, viewport, control permissions
Stream	Until closed or interrupted	Terminal bytes or event delivery
RPC request	One operation	Request ID, deadline, result

One QUIC connection can carry 10 terminal attachments. Two QUIC connections can attach to the same session.

What happens during a disconnect?

1. iOS attaches to Session A
   Connection: C1
   Attachment: A1
   Session: S1
2. iOS loses network
   C1 → closed
   A1 → disconnected
   S1 → STILL RUNNING
3. iOS reconnects
   Connection: C2 (new)
   terminal.attach(S1)
4. Host creates Attachment A2
   → restore current terminal state
   → continue live terminal output
   S1 is the SAME session

The host daemon should own the session registry. The gateway owns transport connectivity and client subscriptions. ZMX owns the persistent terminal process.

For a correct reconnect, you need an ordered handoff from the terminal snapshot to live output—otherwise bytes produced during resynchronization can be duplicated or lost.

Typed API boundaries

I’d explicitly model these identities as Rust newtypes rather than passing strings around:

struct HostId(Uuid);
struct SessionId(Uuid);
struct ConnectionId(Uuid);
struct AttachmentId(Uuid);
struct AttachRequest {
    session: SessionId,
    viewport: Viewport,
    mode: AttachMode,
}
struct AttachResponse {
    attachment: AttachmentId,
    stream_id: u64,
}

Operations then become clear:

* session.create() / session.list() / session.kill() manage durable resources.
* terminal.attach(session_id) / terminal.detach(attachment_id) manage client views.
* terminal.claim_control(attachment_id) manages input and resize ownership.
* events.subscribe(cursor) manages resumable event delivery.

And importantly, a Codex agent session and a ZMX terminal session aren’t necessarily the same resource. Keep their IDs distinct; Agent Studio can associate them without coupling their lifetimes.

One extra distinction I’d add

Separate connection state from subscription state.

A gateway reconnecting to the host shouldn’t force the UI to recreate every logical subscription. The gateway should remember its desired subscriptions and reattach automatically, while the host provides event sequence numbers or cursors for catching up.

That’s the model I’d use across GUI, CLI, MCP, and mobile: persistent sessions, replaceable connections, replaceable attachments, and recoverable subscriptions.