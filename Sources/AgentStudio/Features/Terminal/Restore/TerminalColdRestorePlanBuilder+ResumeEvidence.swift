import AgentStudioCore
import Foundation

extension TerminalColdRestorePlanBuilder {
    package static func applyingResumeEvidence(
        _ evidence: ResumeEvidence, providerIdentifier: String, providerSessionId: String,
        to plan: TerminalColdRestorePlan
    ) -> TerminalColdRestorePlan {
        let invocation: ResumeInvocation?
        let outcome: String
        switch evidence {
        case .knownExited:
            invocation = nil
            outcome = ""
        case .interruptedCandidate(let candidate):
            invocation = candidate
            outcome =
                "Resumed \(candidate.provider.displayName) session \(candidate.sessionId.rawValue.prefix(8)) after restart"
        case .unknown:
            invocation = nil
            let provider =
                ResumeProvider(providerIdentifier: providerIdentifier)?.displayName
                ?? (providerIdentifier == "cursor" ? "Cursor" : providerIdentifier)
            let printable = providerSessionId.unicodeScalars.filter { (32...126).contains($0.value) }.map { String($0) }
                .joined()
            let shortId = String(printable.prefix(8))
            let identity = shortId.isEmpty ? provider : "\(provider) session \(shortId)"
            outcome = "Could not determine whether \(identity) exited; resume it manually."
        }
        return composingOutcome(outcome, invocation: invocation, onto: plan)
    }

    package static func applyingUncheckedAgentStateNotice(to plan: TerminalColdRestorePlan) -> TerminalColdRestorePlan {
        composingOutcome(
            "Agent state couldn't be checked before restore; if an agent was running here, resume it manually.",
            invocation: nil, onto: plan)
    }

    private static func composingOutcome(
        _ outcome: String, invocation: ResumeInvocation?, onto plan: TerminalColdRestorePlan
    ) -> TerminalColdRestorePlan {
        TerminalColdRestorePlan(
            zmxExecutable: plan.zmxExecutable, zmxDirectory: plan.zmxDirectory, sessionID: plan.sessionID,
            loginShell: plan.loginShell, folderCandidates: plan.folderCandidates,
            notice: .init(
                linesByCandidateIndex: plan.notice.linesByCandidateIndex.map {
                    outcome.isEmpty ? $0 : "\($0)\n\(outcome)"
                }),
            replayFile: plan.replayFile, resume: invocation, attemptID: plan.attemptID)
    }
}
