import Foundation

/// The agent-resume argv a cold-restore script runs inside the fresh login
/// shell before handing off interactively (Program Design choice 2's script
/// step 5: `-c '<argv>; exec <shell> -i -l'`).
///
/// This is a minimal placeholder for the R3 resume vocabulary. R3's exact
/// shape (`ResumeProvider`, `ProviderSessionId`, the fixed per-provider
/// argument templates) is explicitly pending the owner's auto-resume policy
/// decision (Program Design "Open" #1) and is not this slice's to invent. R1
/// never produces a non-nil `ResumeInvocation`: `TerminalColdRestorePlan.resume`
/// is always `nil` here, and the cold script always takes its
/// not-resuming branch (`exec <loginShell> -i -l`). This type exists only so
/// `TerminalColdRestorePlan`'s shape matches Program Design item 2 now,
/// ahead of R3 filling in how it's produced.
package struct ResumeInvocation: Equatable, Sendable {
    /// The command line the shell runs before the interactive handoff.
    package let argv: [String]

    package init(argv: [String]) {
        self.argv = argv
    }
}
