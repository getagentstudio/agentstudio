import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTerminal
import Foundation

struct ColdRestoreResumeVerdict: Sendable {
    let evidence: ResumeEvidence
    let endedMain: ColdEndedMain?
    let reportEvidence: PaneForegroundEvidence?

    func applying(to plan: TerminalColdRestorePlan) -> TerminalColdRestorePlan {
        if case .reportedOtherStart(let other) = reportEvidence?.value {
            return TerminalColdRestorePlanBuilder.applyingResumeEvidence(
                evidence, providerIdentifier: other.provider == .codex ? "codex" : "claude-code",
                providerSessionId: other.conversationId, to: plan)
        }
        if let endedMain {
            return TerminalColdRestorePlanBuilder.applyingResumeEvidence(
                evidence, providerIdentifier: endedMain.providerIdentifier,
                providerSessionId: endedMain.providerConversationId, to: plan)
        }
        if case .unknown = evidence {
            return TerminalColdRestorePlanBuilder.applyingUncheckedAgentStateNotice(to: plan)
        }
        return plan
    }
}

/// Sequences the named readiness/cold-end/B1 boundaries; E10 remains a pure Sessions decision.
struct ColdRestoreResumeDecision: Sendable {
    let ingestion: SessionsIngestion
    let reportRepository: any PaneForegroundEvidenceRepository
    let drain: PaneCLIOutboxDrain?
    let storeURL: URL?
    var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?

    @concurrent nonisolated func resolve(
        paneId: UUID, sessionId: ZmxSessionID,
        readiness: RestoreResumeReadinessResult, launchBoot: TerminalRestoreLaunchBoot?,
        inventory: ZmxSessionInventory
    ) async -> ColdRestoreResumeVerdict {
        let ended: ColdEndedMain?
        do { ended = try await ingestion.endLiveMainForColdRestore(paneId: paneId) } catch {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: nil, reportEvidence: nil)
        }
        var reportEvidence: PaneForegroundEvidence?
        do { reportEvidence = try await reportRepository.loadEvidence(paneId: paneId) } catch {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, reportEvidence: nil)
        }
        guard readiness == .ready, let launchBoot else {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, reportEvidence: reportEvidence)
        }
        let resolver = SessionsResumeResolver(performanceTraceRecorder: performanceTraceRecorder)
        func input(_ evidence: PaneForegroundEvidence?) -> ResumeEvidenceInput {
            .init(
                zmxSessionId: sessionId, coldEndedMain: ended, evidence: evidence,
                isSameBoot: launchBoot.isSameBoot, inventory: inventory)
        }
        var verdict = await resolver.resumeEvidence(for: input(reportEvidence))
        if launchBoot.isSameBoot {
            guard let drain, let storeURL else {
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, reportEvidence: reportEvidence)
            }
            let reread = await drain.drain(storeURL: storeURL)
            do { reportEvidence = try await reportRepository.loadEvidence(paneId: paneId) } catch {
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, reportEvidence: nil)
            }
            switch reread.readOutcome {
            case .complete, .verifiedEmpty: break
            case .historyLost:
                return .init(evidence: .unknown(.historyLost), endedMain: ended, reportEvidence: reportEvidence)
            case .unreadable, .incomplete:
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, reportEvidence: reportEvidence)
            }
            let current = await resolver.resumeEvidence(for: input(reportEvidence))
            if case .interruptedCandidate(let candidate) = current {
                guard verdict == .interruptedCandidate(candidate), let ended,
                    (try? await ingestion.commitColdResume(
                        paneId: paneId, bindingGenerationId: ended.bindingGenerationId)) == true
                else {
                    return .init(
                        evidence: .unknown(.changedWhileClosed), endedMain: ended, reportEvidence: reportEvidence)
                }
            }
            verdict = current
        }
        return .init(evidence: verdict, endedMain: ended, reportEvidence: reportEvidence)
    }
}
