# Bridge and remote transport direction

This is the first-hand owner relay supplied by the Advisor on 22 October, rather than a direct message to this Lead. Source: [owner quotations and advice](../../../../../tmp/practices-research/2026-10-22-advisor-bridge-quic/owner-direction-and-advice.md), posted on the daemon thread as message `01a1635d-f215-70b2-9353-49b959427504`.

The adoption request quoted in that packet is: “this is another change I want you to guide the lead through and get him and research agents to work on and also write down as part of the design changes.”

## Preserved owner quotations from the relay

These excerpts are attributed to the owner by the Advisor's packet; the Lead did not independently open the original Advisor conversation. Advice later in that packet is not included as owner wording.

> “Yes, you can use QUIC. For Agent Studio, I'd separate the WebView connection from the remote-machine connection.”

> “The WebView communicates using normal browser networking. Rust handles the remote QUIC connection and multiplexes requests, content streams and session updates.”

> “I wouldn't make WebTransport mandatory yet.”

> “For Rust gateway ↔ remote host, Quinn is a better-established option that you control at both ends.”

> “Encryption alone isn't pairing.”

> “Swift never forwards individual content chunks.”

> “I would keep privileged commands on the native UDS/FFI interface and give the WebView only the operations it needs.”

> “I would also favor bearer capabilities over ordinary localhost cookies initially.”

The relay attributes this threat/defense table to the owner:

| Threat | Required defense as recorded |
| --- | --- |
| Network | Loopback-only bind |
| Malicious website | Auth plus strict Origin/Host, no permissive CORS |
| Other local process | Unpredictable scoped credentials; separate privileged IPC |
| Compromised WebView | Per-pane/worktree authorization, CSP |
| Gateway impersonation | Authenticated TLS or a trusted native bootstrap |
| Floods | Rate limits, bounded queues, byte budgets, cancellation |

## Direction carried into S32

- The WebView uses normal browser fetch and WebSocket to its device's Rust Gateway over loopback, loading the Bridge app from that same origin. Swift bootstraps the actual port and a fresh scoped capability; it does not forward individual content chunks.
- The Gateway is a separate macOS service and an embedded iOS library/runtime. Privileged native control uses UDS on macOS and FFI on iOS.
- Gateway-to-remote-Host communication uses upstream Quinn QUIC with authenticated TLS 1.3 and paired/pinned identities. Encryption alone does not establish pairing or device authority.
- WebTransport is optional, not an initial requirement.
- The browser gets narrowly scoped pane/worktree access. The quoted threat table requires a loopback-only listener, strict Origin/Host handling, independent unpredictable credentials, separate privileged IPC, restrictive content policy, bounded resources and cancellation.

S32 supersedes the physical socket-only wording for the selected embedded iOS native bootstrap/control boundary. It preserves the Gateway role, the prohibition on a UX client directly calling Host services, macOS Unix-socket compatibility proof, Host-local machine CLI, central database-writer lease authority and all existing feature semantics.

## Advice and facts that are not additional owner decisions

The concrete browser authentication exchange, crate decomposition, certificate versus raw-key encoding, pairing ceremony, expiry duration, key persistence, exact budgets, platform entitlements and mobile stop/reconnect policy require structural design and qualification. Proposed experiments and platform claims do not supply runtime results or a speed winner. Suspension does not imply every socket automatically closes; an HTTP/browser abort does not prove Host work stopped.

No automatic TCP fallback, new Host VT engine, always-running iOS daemon, Ghostty fork, database-writer transfer or blanket product-implementation authority is selected here.
