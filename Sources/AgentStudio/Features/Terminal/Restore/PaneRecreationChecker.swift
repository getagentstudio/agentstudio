import AgentStudioCore
import Foundation

/// SR2a; Program Design item 5: "For warm and unverified panes, one
/// off-main observe after the attach settles is compared by identity with
/// the warm baseline from item 1: a different identity means zmx recreated
/// the session ... a missing baseline or a failed observation means
/// 'couldn't check.' A PID or a clock is never a substitute for identity."
///
/// R2-3 (Lead decision 2026-10-02): "after the attach settles" is this
/// design item's own original framing; the actual trigger wired up is the
/// pane's first render, and attach completion itself is not observable
/// through any existing contract. See `PaneRecreationCheckOutcome
/// .matchedAtFirstRender`'s own doc comment for the honest replacement.
///
/// A pure comparison over two already-opaque identity blobs
/// (`TerminalRestoreKind.warm(identity:fallback:)`'s `identity` payload,
/// `ZmxSessionIdentity.encoded()`'s deterministic `.sortedKeys` JSON) — no
/// decoding needed, since two encodings of the same logical identity are
/// byte-identical and two different identities are not. This is
/// deliberately only the detection half: how a `.recreated`/`.couldNotCheck`
/// result reaches the person is an open presentation question (Program
/// Design's own S4 stop — "presenting a notice over a live warm surface
/// needs a new UI mechanism" — and `InboxNotificationRouter`'s "intentionally
/// retired... do not reconnect without a new product decision" both apply;
/// see the implementation trace).
package enum PaneRecreationCheckResult: Equatable, Sendable {
    /// The post-attach observation matches the warm baseline exactly.
    case unchanged
    /// A different session now answers where the baseline was observed —
    /// zmx recreated the session under the same name (SR2a).
    case recreated
    /// No baseline existed to compare against (an unverified pane never had
    /// one), or the post-attach observation itself failed. Never presented
    /// as `.recreated` on a mere absence of proof.
    case couldNotCheck
}

/// A6 (advisor review 2026-10-01; PD rev 21 item 5): why a post-attach
/// recreation check reached no verdict -- the orchestration layer's own
/// typed reason for taking `PaneRecreationCheckResult.couldNotCheck`'s
/// branch, now that waiting for the pane's first output before checking can
/// itself fail in a way the pure comparison never could. `PaneRecreationChecker
/// .checkForRecreation` is unchanged: it stays an honest two-blob
/// comparison, oblivious to why either blob might be missing.
package enum PaneRecreationUncheckableReason: Equatable, Sendable {
    /// `restoreKind == .unverified`: no warm baseline ever existed to
    /// compare against.
    case missingBaseline
    /// The pane exited, was retired, unmounted, or this check's own task
    /// was cancelled before the awaited first render after native mount
    /// ever arrived -- the check never got to observe at all.
    case paneUnavailableBeforeFirstRender
    /// `ZmxSessionRestoreProbing.observeSessionIdentity` threw a recognized
    /// `ZmxSessionControlFailure` -- including the pre-setsid window
    /// immediately after a freshly recreated session
    /// (`.unexpectedProcessGroup`/`.unexpectedProcessParent`).
    case observationFailed(ZmxSessionControlFailure)
    /// `observeSessionIdentity` threw an error this reason type doesn't
    /// recognize (a non-`ZmxSessionControlFailure` conformer).
    case observationFailedUnrecognized
}

/// A6: the post-attach recreation check's own outer verdict -- wraps
/// `PaneRecreationCheckResult`, the pure identity comparison, with a typed
/// reason when no comparison could be made. `recreated` collapses directly
/// from the pure result's own `.recreated`: a different identity is
/// definitive whenever it's observed. `uncheckable` replaces its bare
/// `.couldNotCheck` with a specific `PaneRecreationUncheckableReason`.
package enum PaneRecreationCheckOutcome: Equatable, Sendable {
    /// R2-3 (Lead decision 2026-10-02): was `.unchanged`. This means the
    /// baseline identity still answered when the pane's first render
    /// arrived -- not that the session survived the attach. Attach
    /// completion itself is not observable through any existing contract:
    /// zmx exposes no attached-client query, Ghostty exposes no PTY event,
    /// and the handoff-token check can't distinguish an attach that
    /// created the session from a check that simply ran against a session
    /// already alive (its leader never carried our token either way). A
    /// session recreated strictly between this observation and real
    /// attach completion is invisible to this comparison by construction.
    case matchedAtFirstRender
    case recreated
    case uncheckable(PaneRecreationUncheckableReason)
}

package enum PaneRecreationChecker {
    /// `baselineIdentity` is `TerminalRestoreKind.warm(identity:fallback:)`'s
    /// stored `identity` for a warm pane, or `nil` for an unverified one (which never
    /// had a baseline to begin with). `observedIdentity` is the result of
    /// one more `ZmxSessionRestoreProbing.observeSessionIdentity(_:)` call
    /// made at the pane's first render — `nil` on any observation failure,
    /// matching that API's existing `nil`-on-failure convention. "A PID or
    /// a clock is never a substitute for identity": this compares only the
    /// identity blobs themselves.
    package static func checkForRecreation(
        baselineIdentity: Data?,
        observedIdentity: Data?
    ) -> PaneRecreationCheckResult {
        guard let baselineIdentity, let observedIdentity else {
            return .couldNotCheck
        }
        return baselineIdentity == observedIdentity ? .unchanged : .recreated
    }
}
