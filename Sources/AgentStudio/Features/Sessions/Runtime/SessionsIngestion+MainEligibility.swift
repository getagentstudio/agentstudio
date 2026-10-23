import AgentStudioCore
import Foundation

extension SessionsIngestion {
    private struct MainEligibilityPrediction: Equatable {
        let liveMain: SessionsBindingRecord?
        let matchingBinding: SessionsBindingRecord?
        let confirmedLiveMain: Bool
        let unverifiedMain: UnverifiedPaneStatusRuntime.MainIdentity?
        let releasedUnverified: Set<UnverifiedPaneStatusRuntime.MainIdentity>
        let hasUnverifiedPane: Bool
    }

    func mainEligibility(for hook: SessionsHookAdmission, claimOnly: Bool) async -> MainEligibility {
        guard !isStatusClosed, !statusRuntime.retiredPaneIds.contains(hook.paneId) else { return .notEligible }
        let prediction = eligibilityPrediction(for: hook)
        let predictsElection =
            claimOnly
            ? unverifiedStatusRuntime.predictsElection(for: hook)
            : SessionsEvidenceReducer.predictsElection(
                for: hook, liveMain: prediction.liveMain, ownMatching: prediction.matchingBinding,
                confirmedLiveMain: prediction.confirmedLiveMain)
        guard predictsElection else { return .notEligible }
        switch hook.chain {
        case .unknown: return .notEligible
        case .agentShell(_, .multiplexerServer): return .eligible
        case .agentShell(_, .other): break
        }
        guard let sessionID = await terminalLeaderReader.terminalSessionID(for: hook.paneId) else {
            return .notEligible
        }
        let leader = await terminalLeaderReader.terminalLeader(for: sessionID)
        consumePaneViewedBatch()
        guard !isStatusClosed, !statusRuntime.retiredPaneIds.contains(hook.paneId) else { return .notEligible }
        let currentSessionID = await terminalLeaderReader.terminalSessionID(for: hook.paneId)
        consumePaneViewedBatch()
        guard !isStatusClosed, !statusRuntime.retiredPaneIds.contains(hook.paneId),
            currentSessionID == sessionID, eligibilityPrediction(for: hook) == prediction
        else { return .notEligible }
        return hook.chain.isMainEligible(terminalLeader: leader) ? .eligible : .notEligible
    }

    private func eligibilityPrediction(for hook: SessionsHookAdmission) -> MainEligibilityPrediction {
        let current = statusRuntime.currentBindingByPane[hook.paneId].flatMap { statusRuntime.bindings[$0] }
        let liveMain = current?.status == .active ? current : nil
        let matching: SessionsBindingRecord?
        if let current, current.providerIdentifier == hook.providerIdentifier,
            current.providerConversationId == hook.sessionId
        {
            matching = current
        } else {
            matching = statusRuntime.bindings.values.first {
                $0.paneId == hook.paneId && $0.providerIdentifier == hook.providerIdentifier
                    && $0.providerConversationId == hook.sessionId
            }
        }
        let unverified = unverifiedStatusRuntime.panes[hook.paneId]
        return .init(
            liveMain: liveMain, matchingBinding: matching,
            confirmedLiveMain: liveMain.map { statusRuntime.confirmedLiveBindingIds.contains($0.bindingGenerationId) }
                ?? false,
            unverifiedMain: unverified?.main, releasedUnverified: unverified?.released ?? [],
            hasUnverifiedPane: unverified != nil)
    }
}
