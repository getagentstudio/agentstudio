# iOS ABI-host source check: two ordinary entry paths

**Neither examined path establishes a safety-compliant drop-in host for the embedded Gateway.** This is a bounded source result, not a proof that no such host exists. No dependency, runtime or application-composition change is selected.

The existing [IP6 profile](../initial-profile.md) permits pinned dependencies through safe first-party interfaces but forbids first-party unsafe, including generated scaffolding. The [frozen UniFFI check](../increments/00-qualification/bridge-gateway-transport/native-binding-safety.md) already showed why a green consumer lint alone is insufficient. The [transport design](../increments/00-qualification/bridge-gateway-transport/program-design.md) still needs an embedded iOS startup/control realization under that policy.

## Scope and deciding evidence

The bounded question was whether an ordinary entry path in Tauri or Winit supplies the missing ABI/bootstrap ownership without consumer unsafe scaffolding. Evidence for a candidate would need to identify its actual external host entry, a safe first-party registration/control API, compatible app lifetime and the first-party source generated at that boundary. This source check does not attempt to implement or benchmark one.

| Public source snapshot | Opened boundary | What it establishes | What it does not establish |
| --- | --- | --- | --- |
| Tauri `2e23492ab9bcec06bab041e0e47447aaa0da298c` | `tauri-macros` mobile entry expansion, lines 29–95 | The normal mobile entry macro emits a consumer `start_app` C export with `#[unsafe(no_mangle)]` on the non-Android branch. That is generated consumer code, so this ordinary path does not satisfy literal IP6. | That every way to use Tauri is impossible, or that unsafe code implemented solely inside an allowed dependency violates IP6. No macro consumer was compiled here. |
| Winit `7ed7c2031c405e37aefd8635506933fdaa51b919` | UIKit `EventLoop::new` and `run_app_never_return`, lines 148–156 and 313–329 | The library's normal run path requires main-thread/global event-loop setup, checks that UIKit startup has not already happened and invokes UIKit application startup itself. | A minimal Swift-to-Rust Gateway entry or preserved app composition. Using its application-entry model would require separate composition and runtime qualification; no such integration was attempted. |

Primary pinned sources: [Tauri mobile entry macro](https://github.com/tauri-apps/tauri/blob/2e23492ab9bcec06bab041e0e47447aaa0da298c/crates/tauri-macros/src/mobile.rs#L85), [Tauri iOS callback interfaces](https://github.com/tauri-apps/tauri/blob/2e23492ab9bcec06bab041e0e47447aaa0da298c/crates/tauri/src/ios.rs), [Winit UIKit event loop](https://github.com/rust-windowing/winit/blob/7ed7c2031c405e37aefd8635506933fdaa51b919/winit-uikit/src/event_loop.rs#L313), and [Winit UIKit application setup](https://github.com/rust-windowing/winit/blob/7ed7c2031c405e37aefd8635506933fdaa51b919/winit-uikit/src/lib.rs). These are inspected repository snapshots, not selected release versions or dependency pins for AgentStudio.

Winit's support for a custom application delegate does not itself supply an entry from an already running native app. Conversely, its startup assertion is not a proof that a separately designed Rust-owned entry could never host native UI. Keep both limits visible rather than turning a source mismatch into a universal impossibility claim.

## Consequence

Keep the ordinary UniFFI candidate blocked under the existing profile. This check adds two concrete source constraints and no qualified replacement. The wider external-host search remains open; Mac socket, Linux Host and typed-contract design can proceed independently. A change to first-party safety policy or application ownership would need its own decision and evidence.

No iOS compile/link/device run, Tokio startup, Swift callback/control, suspension/reconnect, ABI safety audit, product test or performance observation occurred. No product source/configuration was edited.

## Research route

The required DeepWiki discovery queries were rejected by automatic approval review because their detailed context included internal architecture/policy. No result from those rejected requests is used. The safer route requested only public repository identities and pinned public source URLs, carrying no internal project context. Public repository tree requests were complete, and the decisive sources were read directly. No attempt was made to bypass the denial or submit the same internal context elsewhere.

Retained public source snapshots and tree responses are in `tmp/practices-research/2026-11-05-ios-abi-hosts/`. The user-only policy and project meaning come from the local documents linked above, not an external model answer.
