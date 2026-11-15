import Foundation

/// The startup observer's total result for one cold start's startup window
/// (SR5; Program Design item 3). Every launch, exit and registration outcome
/// maps to exactly one case — there is no partial or default state. S3
/// implements the observer (`ColdStartObserver`) that produces these; this
/// slice only defines the closed vocabulary its consumers (the activation
/// path's start slots, the placeholder/overlay owner) are written against.
package enum ColdStartOutcome: Equatable, Sendable {
    /// `NOTE_EXEC` (or the post-registration check) found the leader still
    /// alive, still the process from the discovered identity (same pid
    /// **and** start time, so a reused pid can't pass), and its arguments no
    /// longer carrying this attempt's startup token (Program Design revision
    /// 11, item 3, "the token"). The login shell is running.
    case handedOff
    /// The attach process ended before handoff was confirmed. Covers a zmx
    /// child dying before exec, a script error, a zmx diagnostic followed by
    /// an exit, and a failed final `exec` — independent of whether anything
    /// was typed. Never retried.
    case failed(ColdStartFailure)
    /// The observer could not establish the witness at all: the shell may be
    /// running fine. Never reported as `.failed`, and never left pending.
    case unobservable(ColdStartUnobservableReason)
}

/// Every way a cold start's attach process can end before handoff is
/// confirmed (Program Design item 3). The pane shows this reason instead of
/// the generic "Process Exited" — the exit status travels through when the
/// OS reports one, `nil` when it doesn't (for example, a session that never
/// creates its socket).
///
/// This is a conservative placeholder for S3's actual observer design: the
/// Program Design narrates several triggers (`NOTE_EXIT` before handoff, the
/// endpoint found gone or refused after discovery, the surface's command
/// exiting before handoff) without giving them verbatim case names the way
/// it does for `ColdStartUnobservableReason`. They collapse to one
/// underlying fact — the attach process ended before the marker was seen —
/// so this slice defines exactly that, leaving S3 free to split it further
/// if its observer implementation needs to distinguish them.
package enum ColdStartFailure: Equatable, Sendable {
    case exitedBeforeHandoff(exitStatus: Int32?)
}

/// Program Design revision 11, item 3, given verbatim:
/// `.watchRegistrationFailed(errno:) | .identityUnverifiable | .processArgsUnreadable(errno:)`.
/// A `kqueue` registration error, an unverifiable identity (the leader's
/// current pid and start time no longer match the identity discovered in
/// stage 1 -- a reused pid, guarded against), or a process-args read that
/// failed or returned no argument vector (`EINVAL`, `EIO`, or a zombie
/// leader). The slot settles with no false failure and no false handoff; the
/// reason goes to telemetry only.
package enum ColdStartUnobservableReason: Equatable, Sendable {
    case watchRegistrationFailed(errno: Int32)
    case identityUnverifiable
    case processArgsUnreadable(errno: Int32)
}
