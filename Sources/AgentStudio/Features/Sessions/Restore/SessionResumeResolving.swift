import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

package protocol SessionResumeResolving: Sendable {
    func resumeEvidence(for input: ResumeEvidenceInput) async -> ResumeEvidence
}

/// Decides only from the cold end and the evidence captured before activation.
package struct SessionsResumeResolver: SessionResumeResolving {
    private let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    package init(performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil) {
        self.performanceTraceRecorder = performanceTraceRecorder
    }

    @concurrent nonisolated package func resumeEvidence(for input: ResumeEvidenceInput) async -> ResumeEvidence {
        AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
            .restoreResumeDecide, recorder: performanceTraceRecorder
        ) {
            switch input.evidence?.value {
            case .reportedEnd: return .knownExited
            case .reportedOtherSessionEnd, .reportedOtherStart: return .unknown(.changedWhileClosed)
            case .reportsUnreadable(.historyLost): return .unknown(.historyLost)
            case .reportsUnreadable(.rowRefused): return .unknown(.reportRefused)
            case .look, nil: break
            }
            guard let main = input.coldEndedMain else { return .knownExited }
            guard let provider = ResumeProvider(providerIdentifier: main.providerIdentifier) else {
                return .unknown(.unknownProvider)
            }
            if input.isSameBoot {
                guard case .complete(let entries) = input.inventory else { return .unknown(.observationMismatch) }
                switch entries[input.zmxSessionId] {
                case .refused, nil: break
                case .alive, .unresponsive: return .unknown(.observationMismatch)
                }
            }
            guard let sessionId = try? ProviderSessionId(rawValue: main.providerConversationId) else {
                return .unknown(.invalidSessionId)
            }
            return .interruptedCandidate(.init(provider: provider, sessionId: sessionId))
        }
    }
}
