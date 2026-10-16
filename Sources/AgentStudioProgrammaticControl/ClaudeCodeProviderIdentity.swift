import Foundation

/// The wire identity Agent Studio recognises for the Claude Code command-line
/// client. The hook projection in the bundled CLI and the Sessions provider
/// profile in the app both read these constants, so a rename can never leave
/// one side reporting an identity the other refuses.
///
/// `supportedExactVersion` is the Claude Code release this round's projection
/// was verified against. A hook installed against a different release reports
/// that release instead, which the Sessions registry treats as unqualified
/// rather than silently admitting unverified capabilities.
package enum ClaudeCodeProviderIdentity {
    package static let identifier = "claude-code"
    package static let supportedExactVersion = "2.1.286"

    /// Claude Code's command-line client. The verified capture shows the
    /// projected hook events firing identically for an attended session and a
    /// `--print` run, so both share one operating mode in round 1.
    package static let operatingMode = "cli"

    /// Lifecycle events this provider's hooks project. Everything else Claude
    /// Code emits stays unprojected rather than mapping onto a nearby name.
    package static let projectedEventNames: Set<IPCSessionEventName> = [
        .sessionStart,
        .sessionEnd,
        .turnStart,
        .turnDone,
        .turnFailed,
        .permission,
        .toolActivity,
        .subagentActivity,
        .question,
        .elicitation,
        .elicitationResult,
        .toolCompleted,
        .toolFailed,
    ]
}
