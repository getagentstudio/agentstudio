import AgentStudioCore
import AgentStudioSessions
import AgentStudioTerminal
import Foundation

struct ColdRestoreResumeVerdict: Sendable {
    let evidence: ResumeEvidence
    let endedMain: ColdEndedMain?
    let foreground: PaneForegroundEvidence?

    func applying(to plan: TerminalColdRestorePlan) -> TerminalColdRestorePlan {
        if case .reportedOtherStart(let other) = foreground?.value {
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
    let foregroundRepository: any PaneForegroundEvidenceRepository
    let drain: PaneCLIOutboxDrain?
    let storeURL: URL?

    @concurrent nonisolated func resolve(
        paneId: UUID, sessionId: ZmxSessionID, preRestoreLook: PaneForegroundLook?,
        readiness: RestoreResumeReadinessResult, launchBoot: TerminalRestoreLaunchBoot?,
        inventory: ZmxSessionInventory
    ) async -> ColdRestoreResumeVerdict {
        let ended: ColdEndedMain?
        do { ended = try await ingestion.endLiveMainForColdRestore(paneId: paneId) } catch {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: nil, foreground: nil)
        }
        var foreground: PaneForegroundEvidence?
        do { foreground = try await foregroundRepository.loadEvidence(paneId: paneId) } catch {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, foreground: nil)
        }
        guard readiness == .ready, let launchBoot else {
            return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, foreground: foreground)
        }
        let resolver = SessionsResumeResolver()
        func input(_ evidence: PaneForegroundEvidence?) -> ResumeEvidenceInput {
            .init(
                paneId: paneId, zmxSessionId: sessionId, coldEndedMain: ended, evidence: evidence,
                preRestoreLook: preRestoreLook, launchBootId: launchBoot.currentBootId, inventory: inventory)
        }
        var verdict = await resolver.resumeEvidence(for: input(foreground))
        if launchBoot.isSameBoot {
            guard let drain, let storeURL else {
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, foreground: foreground)
            }
            let reread = await drain.drain(storeURL: storeURL)
            do { foreground = try await foregroundRepository.loadEvidence(paneId: paneId) } catch {
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, foreground: nil)
            }
            switch reread.readOutcome {
            case .complete, .verifiedEmpty: break
            case .historyLost:
                return .init(evidence: .unknown(.historyLost), endedMain: ended, foreground: foreground)
            case .unreadable, .incomplete:
                return .init(evidence: .unknown(.reportsNotRead), endedMain: ended, foreground: foreground)
            }
            let current = await resolver.resumeEvidence(for: input(foreground))
            if case .interruptedCandidate(let candidate) = current {
                guard verdict == .interruptedCandidate(candidate), let ended,
                    (try? await ingestion.commitColdResume(
                        paneId: paneId, bindingGenerationId: ended.bindingGenerationId)) == true
                else { return .init(evidence: .unknown(.changedWhileClosed), endedMain: ended, foreground: foreground) }
            }
            verdict = current
        }
        return .init(evidence: verdict, endedMain: ended, foreground: foreground)
    }
}
