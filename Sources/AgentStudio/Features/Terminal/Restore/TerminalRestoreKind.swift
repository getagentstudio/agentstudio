import AgentStudioCore
import Foundation

/// The restore decision for one pane at this launch (E4; SR1). Decided
/// before attach and never let `zmx attach` silently recreate a dead session
/// as if nothing happened.
package enum TerminalRestoreKind: Equatable, Sendable {
    /// The session is believed alive. `identity` is the warm baseline
    /// (Program Design item 1's `ZmxSessionControl.observe` result), carried
    /// as the same opaque encoded form `ZmxBackend.observeSessionIdentity`
    /// already returns across this module boundary — `ZmxSessionIdentity`
    /// itself stays Core-private. Kept for S4's post-attach recreation check
    /// (SR2a): a different identity observed after attach means zmx
    /// recreated the session under the same name.
    ///
    /// `fallback` (owner decision, 2026-09-30, "option A"; Spec SR2a; S4b)
    /// is a cold-restore plan carried, not used, unless the warm check was
    /// wrong: `TerminalRestoreRuntime.startupCommand(for:kind:)` sends the
    /// cold-restore script for every reconnect, warm included. zmx itself
    /// ignores a startup command when the session it finds is actually
    /// alive (`loop.zig` `ensureSession`, "session already exists, ignoring
    /// command" — confirmed directly against the vendored source), so a
    /// correct warm check changes nothing observable. A session that died
    /// between the check and the reconnect gets recreated by the script
    /// instead of silently attaching to a blank shell.
    case warm(identity: Data, fallback: TerminalColdRestorePlan)
    case cold(TerminalColdRestorePlan)
    /// `fallback`: the same "every reconnect carries the script" reasoning
    /// as `.warm`'s — this pane could not be proven alive, so if it turns
    /// out to be dead, the reconnect recreates it with the script instead of
    /// silently attaching to nothing.
    case unverified(TerminalRestoreUnverifiedReason, fallback: TerminalColdRestorePlan)
}

/// Why a pane could not be proven either alive or dead (Program Design
/// choice 1). Distinguishes the three ways `.unverified` is reached; none of
/// them is ever treated as proof of death (SR2).
package enum TerminalRestoreUnverifiedReason: Equatable, Sendable {
    /// This one session's inventory entry was `.unresponsive` (a timeout or
    /// unexpected error) inside an otherwise `.complete` inventory.
    case sessionUnresponsive
    /// The whole-inventory probe itself failed, so every pane in this
    /// launch is unverified.
    case inventoryUnavailable(ZmxInventoryFailure)
    /// The session was `.alive` in the inventory, but its identity
    /// (`ZmxSessionControl.observe`) could not be observed. Never `.warm`
    /// on the PID alone.
    case warmIdentityUnobservable
}
