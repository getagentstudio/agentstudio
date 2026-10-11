import Foundation

/// Correlation identities for projector-local transition facts. Each scope
/// names one operation, so a closing fact cannot close later work accidentally.
package enum GitProjectorScope: Hashable, Sendable {
    case intake(worktreeId: UUID, registration: UInt64, batchSeq: UInt64)
    case refresh(worktreeId: UUID, requestSequence: UInt64)
    case deadline(worktreeId: UUID, kind: GitProjectorDeadlineKind, generation: UInt64)
    case capacity(worktreeId: UUID, episode: UInt64)
    case backoff(worktreeId: UUID, episode: UInt64)
    case quarantine(worktreeId: UUID, episode: UInt64)
    case lifetime(UInt64)
}

package enum GitProjectorDeadlineKind: Hashable, Sendable {
    case automatic
    case failure
    case capacityFallback
    case governorPacing
    case visibilityCoalescing
    case coalescingWindow
}

package enum GitProjectorChangesetDropReason: Equatable, Sendable {
    case stale
    case superseded
    case equal
}

package enum GitProjectorRefreshOutcome: Equatable, Sendable {
    case completed(snapshotChanged: Bool, branchChanged: Bool)
    case equal
    case timeout
    case unavailable
    case capacityExceeded
    case superseded
    case cancelled
    case shutdown
}

package enum GitProjectorDeadlineDisposition: Equatable, Sendable {
    case admitted
    case deferred
    case obsolete
    case cancelled
}

package enum GitProjectorCapacityRetryOutcome: Equatable, Sendable {
    case rearmed
    case expired
    case cancelled
}

package enum GitProjectorEnvelopeDisposition: Equatable, Sendable {
    case ignored
    case routed
}

/// These facts are synchronous observations of the projector actor's own
/// transitions. They do not add events to the app runtime bus.
package enum GitProjectorFact: Equatable, Sendable {
    case changesetAccepted
    case changesetCoalesced(into: UInt64)
    case changesetDropped(GitProjectorChangesetDropReason)
    case refreshAdmitted
    case refreshStarted
    case refreshClosed(GitProjectorRefreshOutcome)
    case deadlineRegistered(GitProjectorDeadlineKind)
    case deadlineDisposition(GitProjectorDeadlineDisposition)
    case capacityRetryScheduled
    case capacityRetryClosed(GitProjectorCapacityRetryOutcome)
    case backoffOpened(level: Int)
    case backoffAdvanced(level: Int)
    case backoffHalfOpen
    case backoffClosed
    case quarantineOpened
    case quarantineClosed
    case envelopesDropped(count: UInt64)
    case envelopeHandled(seq: UInt64, disposition: GitProjectorEnvelopeDisposition)
    case shutdownCompleted
}

package typealias GitProjectorFactSink = @Sendable (GitProjectorScope, GitProjectorFact) -> Void

struct GitProjectorDeadlineFactSlot: Hashable {
    let worktreeId: UUID
    let sourceKind: Int
}

extension GitWorkingDirectoryProjector {
    func registerVisibilityAdmissionFacts(generation: UInt64) {
        guard let factSink else { return }
        activeVisibilityAdmissionFactGeneration = generation
        for worktreeId in pendingVisibilityDeltaWorktreeIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            let scope = GitProjectorScope.deadline(
                worktreeId: worktreeId,
                kind: .visibilityCoalescing,
                generation: generation
            )
            visibilityAdmissionFactScopesByWorktreeId[worktreeId] = scope
            factSink(scope, .deadlineRegistered(.visibilityCoalescing))
        }
    }

    func closeVisibilityAdmissionFacts(as disposition: GitProjectorDeadlineDisposition) {
        guard let factSink else { return }
        let scopes = Array(visibilityAdmissionFactScopesByWorktreeId.values)
        visibilityAdmissionFactScopesByWorktreeId.removeAll(keepingCapacity: false)
        activeVisibilityAdmissionFactGeneration = nil
        for scope in scopes {
            factSink(scope, .deadlineDisposition(disposition))
        }
    }

    func closeVisibilityAdmissionFacts(admittedWorktreeIds: Set<UUID>) {
        guard let factSink else { return }
        let scopes = visibilityAdmissionFactScopesByWorktreeId
        visibilityAdmissionFactScopesByWorktreeId.removeAll(keepingCapacity: false)
        activeVisibilityAdmissionFactGeneration = nil
        for (worktreeId, scope) in scopes {
            let disposition: GitProjectorDeadlineDisposition =
                admittedWorktreeIds.contains(worktreeId) ? .admitted : .obsolete
            factSink(scope, .deadlineDisposition(disposition))
        }
    }

    func visibilityAdmissionDelayDidFail(generation: UInt64) {
        guard factSink != nil, activeVisibilityAdmissionFactGeneration == generation else { return }
        visibilityAdmissionTask = nil
        closeVisibilityAdmissionFacts(as: .cancelled)
    }

    func admitRefreshFact(worktreeId: UUID, requestSequence: UInt64) {
        guard let factSink else { return }
        let scope = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: requestSequence)
        if let previous = openRefreshFactScopeByWorktreeId[worktreeId], previous != scope {
            factSink(previous, .refreshClosed(.superseded))
        }
        openRefreshFactScopeByWorktreeId[worktreeId] = scope
        factSink(scope, .refreshAdmitted)
    }

    func closeRefreshFact(worktreeId: UUID, outcome: GitProjectorRefreshOutcome) {
        guard let factSink else { return }
        guard let scope = openRefreshFactScopeByWorktreeId.removeValue(forKey: worktreeId) else { return }
        factSink(scope, .refreshClosed(outcome))
    }

    func closeRefreshFact(
        worktreeId: UUID, ifCurrent scope: GitProjectorScope?, outcome: GitProjectorRefreshOutcome
    ) {
        guard factSink != nil, let scope, openRefreshFactScopeByWorktreeId[worktreeId] == scope else { return }
        closeRefreshFact(worktreeId: worktreeId, outcome: outcome)
    }

    func beginIntakeFactRegistration(worktreeId: UUID) {
        guard factSink != nil else { return }
        retireIntakeFactRegistration(worktreeId: worktreeId)
        let registration = nextIntakeFactRegistrationByWorktreeId[worktreeId, default: 0] + 1
        nextIntakeFactRegistrationByWorktreeId[worktreeId] = registration
        intakeFactRegistrationByWorktreeId[worktreeId] = registration
    }

    func retireIntakeFactRegistration(worktreeId: UUID) {
        guard let factSink else { return }
        intakeFactRegistrationByWorktreeId.removeValue(forKey: worktreeId)
        let openScopes = observedIntakeFactScopes.filter { scope in
            if case .intake(let scopedWorktreeId, _, _) = scope { return scopedWorktreeId == worktreeId }
            return false
        }
        for scope in openScopes {
            factSink(scope, .changesetDropped(.superseded))
        }
        observedIntakeFactScopes = observedIntakeFactScopes.filter { scope in
            if case .intake(let scopedWorktreeId, _, _) = scope { return scopedWorktreeId != worktreeId }
            return true
        }
        closedIntakeFactScopes = closedIntakeFactScopes.filter { scope in
            if case .intake(let scopedWorktreeId, _, _) = scope { return scopedWorktreeId != worktreeId }
            return true
        }
    }

    private func intakeFactScope(worktreeId: UUID, batchSeq: UInt64) -> GitProjectorScope {
        .intake(
            worktreeId: worktreeId,
            registration: intakeFactRegistrationByWorktreeId[worktreeId] ?? 0,
            batchSeq: batchSeq
        )
    }

    func observeIntakeFact(worktreeId: UUID, batchSeq: UInt64) {
        guard factSink != nil else { return }
        let scope = intakeFactScope(worktreeId: worktreeId, batchSeq: batchSeq)
        guard !closedIntakeFactScopes.contains(scope) else { return }
        observedIntakeFactScopes.insert(scope)
    }

    func closeIntakeFactOnce(worktreeId: UUID, batchSeq: UInt64, fact: GitProjectorFact) {
        guard let factSink else { return }
        let scope = intakeFactScope(worktreeId: worktreeId, batchSeq: batchSeq)
        guard observedIntakeFactScopes.remove(scope) != nil else { return }
        guard closedIntakeFactScopes.insert(scope).inserted else { return }
        factSink(scope, fact)
    }

    func closeAllOpenIntakeFacts(as fact: GitProjectorFact) {
        guard let factSink else { return }
        let openScopes = Array(observedIntakeFactScopes)
        observedIntakeFactScopes.removeAll(keepingCapacity: false)
        for scope in openScopes where closedIntakeFactScopes.insert(scope).inserted {
            factSink(scope, fact)
        }
    }

    func mergeTrackedChangesets(_ existing: FileChangeset?, with incoming: FileChangeset) -> FileChangeset {
        let merged = Self.mergeChangesets(existing, with: incoming)
        if let existing, existing.batchSeq != merged.batchSeq {
            closeIntakeFactOnce(
                worktreeId: existing.worktreeId,
                batchSeq: existing.batchSeq,
                fact: .changesetCoalesced(into: merged.batchSeq)
            )
        }
        if incoming.batchSeq != merged.batchSeq {
            closeIntakeFactOnce(
                worktreeId: incoming.worktreeId,
                batchSeq: incoming.batchSeq,
                fact: .changesetCoalesced(into: merged.batchSeq)
            )
        }
        return merged
    }

    func registerDeadlineFact(
        worktreeId: UUID,
        sourceKind: GitRefreshDeadlineKind,
        factKind: GitProjectorDeadlineKind
    ) {
        guard let factSink else { return }
        let slot = GitProjectorDeadlineFactSlot(worktreeId: worktreeId, sourceKind: sourceKind.rawValue)
        if let replacedScope = deadlineFactScopeBySlot[slot] {
            factSink(replacedScope, .deadlineDisposition(.obsolete))
        }
        nextDeadlineFactGeneration &+= 1
        let scope = GitProjectorScope.deadline(
            worktreeId: worktreeId,
            kind: factKind,
            generation: nextDeadlineFactGeneration
        )
        deadlineFactScopeBySlot[slot] = scope
        factSink(scope, .deadlineRegistered(factKind))
    }

    func takeDeadlineFact(worktreeId: UUID, sourceKind: GitRefreshDeadlineKind) -> GitProjectorScope? {
        guard factSink != nil else { return nil }
        let slot = GitProjectorDeadlineFactSlot(worktreeId: worktreeId, sourceKind: sourceKind.rawValue)
        return deadlineFactScopeBySlot.removeValue(forKey: slot)
    }

    func cancelDeadlineFact(worktreeId: UUID, sourceKind: GitRefreshDeadlineKind) {
        guard factSink != nil else { return }
        closeDeadlineFact(worktreeId: worktreeId, sourceKind: sourceKind, disposition: .cancelled)
    }

    func closeDeadlineFact(
        worktreeId: UUID,
        sourceKind: GitRefreshDeadlineKind,
        disposition: GitProjectorDeadlineDisposition
    ) {
        guard let scope = takeDeadlineFact(worktreeId: worktreeId, sourceKind: sourceKind) else { return }
        factSink?(scope, .deadlineDisposition(disposition))
    }

    func cancelAllDeadlineFacts() {
        guard let factSink else { return }
        let openScopes = Array(deadlineFactScopeBySlot.values)
        deadlineFactScopeBySlot.removeAll(keepingCapacity: false)
        for scope in openScopes {
            factSink(scope, .deadlineDisposition(.cancelled))
        }
    }

    func openCapacityFactIfNeeded(worktreeId: UUID) {
        guard let factSink, capacityFactOpenEpisodeByWorktreeId[worktreeId] == nil else { return }
        let episode = capacityFactEpisodeByWorktreeId[worktreeId, default: 0] + 1
        capacityFactEpisodeByWorktreeId[worktreeId] = episode
        capacityFactOpenEpisodeByWorktreeId[worktreeId] = episode
        factSink(.capacity(worktreeId: worktreeId, episode: episode), .capacityRetryScheduled)
    }

    func closeCapacityFact(worktreeId: UUID, outcome: GitProjectorCapacityRetryOutcome) {
        guard let factSink else { return }
        guard let episode = capacityFactOpenEpisodeByWorktreeId.removeValue(forKey: worktreeId) else { return }
        factSink(.capacity(worktreeId: worktreeId, episode: episode), .capacityRetryClosed(outcome))
    }

    func recordBackoffFact(worktreeId: UUID, level: Int) {
        guard let factSink else { return }
        if let episode = backoffFactOpenEpisodeByWorktreeId[worktreeId] {
            factSink(.backoff(worktreeId: worktreeId, episode: episode), .backoffAdvanced(level: level))
            return
        }
        let episode = backoffFactEpisodeByWorktreeId[worktreeId, default: 0] + 1
        backoffFactEpisodeByWorktreeId[worktreeId] = episode
        backoffFactOpenEpisodeByWorktreeId[worktreeId] = episode
        factSink(.backoff(worktreeId: worktreeId, episode: episode), .backoffOpened(level: level))
    }

    func recordBackoffHalfOpenFact(worktreeId: UUID) {
        guard let factSink else { return }
        guard let episode = backoffFactOpenEpisodeByWorktreeId[worktreeId] else { return }
        factSink(.backoff(worktreeId: worktreeId, episode: episode), .backoffHalfOpen)
    }

    func closeBackoffFact(worktreeId: UUID) {
        guard let factSink else { return }
        guard let episode = backoffFactOpenEpisodeByWorktreeId.removeValue(forKey: worktreeId) else { return }
        factSink(.backoff(worktreeId: worktreeId, episode: episode), .backoffClosed)
    }
}
