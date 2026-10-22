# Mobile socket/lifecycle and network-path evidence

Read-only primary-source check, received from the existing Sol xhigh performance/transport lane and independently checked by the Lead on2026-10-16. No iPhone build, device operation, process launch, Tailscale command, traffic capture or latency measurement. These facts constrain either pending Gateway placement without selecting it.

| Question | Primary evidence | Supported conclusion and limit |
| --- | --- | --- |
| App Group IPC | [Apple App Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) | Apple documents UNIX-domain IPC among group members with a socket path in the group container and address-length restrictions. Membership/entitlement and process lifetime still apply; this is not unrestricted arbitrary-app IPC |
| Ordinary iOS background lifetime | [Apple background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time) | Ordinary apps become suspended after backgrounding; additional execution is bounded, and extensions use a different API. A socket or App Group grants no perpetual execution. This does not establish universal immediate socket closure |
| Tokio target support | [Tokio1.53.3 platforms](https://github.com/tokio-rs/tokio/blob/a85c3f5baa298a6b554fd3700daf0342289881af/tokio/src/lib.rs#L399-L418) | iOS is explicitly in Tokio's supported-platform list. This research pin is not a selected dependency or successful app build |
| Unix networking types | [Tokio exports](https://github.com/tokio-rs/tokio/blob/a85c3f5baa298a6b554fd3700daf0342289881af/tokio/src/net/mod.rs#L54-L60) | UnixListener/UnixStream/UnixDatagram/UnixSocket are exported on the Unix networking path |
| Socket pair | [Tokio UnixStream::pair](https://github.com/tokio-rs/tokio/blob/a85c3f5baa298a6b554fd3700daf0342289881af/tokio/src/net/unix/stream.rs#L908-L923) | A connected unnamed pair is created and registered with Tokio; that API alone does not connect separately launched processes or prove Swift integration |
| Network route beneath application transport | [Tailscale connection types](https://tailscale.com/docs/reference/connection-types) | Tailscale distinguishes direct, DERP and peer-relay paths, describes their general cost, and documents status/ping observations. Initial relay discovery can later become direct; no actual path or fixed latency premium is established for this user's machines |

Lead read the official Apple DocC data behind those pages, the exact Tokio source ranges and the current Tailscale document. Worker used DeepWiki first for Tokio pointers. Applicable Apple conditions were read; no guessed API or a search-summary signature is the authority.

For proposed experiments: verify real socket exchange and resume/suspension through the selected app profile; separate application suspension, transport migration, a new connection and process restart. Observe the actual underlying network route during a workload rather than assuming QUIC/Tailscale implies directness. App Group/extension experiments are conditional on an actual extension requirement, not mandatory scope because the research mentioned them.

Gateway placement is still owner meaning. The mandatory frontend route remains socket→Gateway→Host; FFI/direct-operation shortcuts from research cannot replace that boundary without a new owner decision. Current sources establish capability/constraints, not a measured winner, a running mobile Gateway or background delivery guarantee.
