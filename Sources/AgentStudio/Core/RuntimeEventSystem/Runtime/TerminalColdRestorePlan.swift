import AgentStudioInfrastructure
import Foundation

/// Identifies one cold-restore attempt (Program Design revision 11, item 3,
/// "the token"). `startupToken` is passed as the cold-restore script's `$0`
/// (`ZmxBackend.buildColdRestoreCommand`), so it lives in the terminal
/// leader's **argument vector** in every process image before the handoff —
/// zmx's forked child, `/bin/sh`, and any `/bin/sh`-into-`bash` re-exec — and
/// the final `exec <loginShell>` replaces the arguments, making it disappear.
/// The startup observer (S3) proves handoff by finding it gone from a live
/// leader's current arguments (never the environment: macOS returns no
/// environment to a third-party reader for any process, confirmed for this
/// design in round 7). Ephemeral and per-attempt: never persisted, never
/// restored, and never equal to a stored `ZmxSessionID`.
package struct ColdRestoreAttemptID: Equatable, Hashable, Sendable {
    package let rawValue: String

    package static func generate() -> Self {
        Self(rawValue: UUIDv7.generate().uuidString)
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The exact argument the cold-restore script's `$0` carries. Shared by
    /// the builder (which passes it) and the observer (which watches for its
    /// absence), so the two never drift.
    package var startupToken: String {
        "agentstudio-restore-\(rawValue)"
    }
}

/// The one-line notice a cold restore prints before its fresh shell starts
/// (SR3: "Restored after restart", plus the reason for any fallback folder).
///
/// Which folder actually exists is a fact the generated script discovers at
/// run time by trying each of `TerminalColdRestorePlan.folderCandidates` in
/// order (Program Design choice 2, script step 2), not something Swift can
/// safely decide ahead of the attach. So this carries one display line per
/// candidate, index-aligned with `folderCandidates`: the script prints
/// exactly the line for the candidate it actually lands in.
package struct ColdRestoreNotice: Equatable, Sendable {
    /// `linesByCandidateIndex[i]` is the text to print when the script lands
    /// in `folderCandidates[i]`. Must have the same count as
    /// `folderCandidates`; index 0 (the saved folder) never needs a fallback
    /// explanation, but still carries its own headline text so the script
    /// has exactly one line to print for every candidate, uniformly.
    package let linesByCandidateIndex: [String]

    package init(linesByCandidateIndex: [String]) {
        self.linesByCandidateIndex = linesByCandidateIndex
    }
}

/// Everything `ZmxBackend.buildColdRestoreCommand(_:)` needs to build the
/// cold-restore script (SR3, SR6a, SR10, SR11; Program Design item 2). Every
/// value the command needs travels on this plan, so the builder reads
/// nothing ambient.
package struct TerminalColdRestorePlan: Equatable, Sendable {
    /// The zmx binary path `TerminalRestoreRuntime` already resolves for
    /// today's warm attach.
    package let zmxExecutable: URL
    /// The isolated `ZMX_DIR` root `TerminalRestoreRuntime` already resolves.
    package let zmxDirectory: URL
    /// The pane's stored zmx session id. Never derived: SR6a keeps the same
    /// id across a cold restore, only the process and pane token are new.
    package let sessionID: ZmxSessionID
    /// The configured login shell the fresh session finally `exec`s into.
    package let loginShell: URL
    /// Ordered fallback chain: saved folder, then the repository's main
    /// folder, then the home folder (SR3). Never empty.
    package let folderCandidates: [URL]
    package let notice: ColdRestoreNotice
    /// Prior scrollback to replay before the fresh prompt (SR10, R2). Always
    /// `nil` in R1 — no scrollback capture exists yet.
    package let replayFile: URL?
    /// The provider resume to run once the shell is ready (SR11, R3). Always
    /// `nil` in R1 — auto-resume is not built until R3.
    package let resume: ResumeInvocation?
    package let attemptID: ColdRestoreAttemptID

    package init(
        zmxExecutable: URL,
        zmxDirectory: URL,
        sessionID: ZmxSessionID,
        loginShell: URL,
        folderCandidates: [URL],
        notice: ColdRestoreNotice,
        replayFile: URL?,
        resume: ResumeInvocation?,
        attemptID: ColdRestoreAttemptID
    ) {
        self.zmxExecutable = zmxExecutable
        self.zmxDirectory = zmxDirectory
        self.sessionID = sessionID
        self.loginShell = loginShell
        self.folderCandidates = folderCandidates
        self.notice = notice
        self.replayFile = replayFile
        self.resume = resume
        self.attemptID = attemptID
    }
}
