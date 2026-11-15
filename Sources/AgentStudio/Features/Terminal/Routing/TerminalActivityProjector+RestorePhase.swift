import AgentStudioCore
import Foundation
import Synchronization

extension TerminalActivityProjector {
    /// A newer restore generation replaces the previous arm for this pane.
    func armRestorePhase(paneID: UUID, generation: RestoreGeneration, resumeInvocation: ResumeInvocation? = nil) async {
        recordRestorePhaseGeneration(generation, for: paneID, resumeInvocation: resumeInvocation)
        discardOpenActivityWindowsForRestorePhaseArm(for: paneID)
    }

    /// Claim once while keeping suppression active until the ordered end arrives.
    func claimMatchingResumeRestoreGeneration(
        paneID: UUID, providerIdentifier: String, providerSessionID: String
    ) -> RestorePhaseGenerationClaim? {
        guard let invocation = pendingResumeInvocation(for: paneID),
            invocation.provider == ResumeProvider(providerIdentifier: providerIdentifier),
            invocation.sessionId.rawValue == providerSessionID,
            let claim = restorePhaseGenerationClaim(for: paneID)
        else { return nil }
        consumePendingResumeInvocation(for: paneID)
        return claim
    }

    /// Only a matching generation ends suppression and establishes a fresh
    /// activity baseline. A stale or duplicate end has no effect.
    @discardableResult
    func endRestorePhase(paneID: UUID, generation: RestoreGeneration) async -> Bool {
        guard endRestorePhaseGenerationIfMatching(paneID: paneID, generation: generation) else {
            return false
        }
        resetPaneActivityBaselineAfterRestorePhaseEnd(for: paneID)
        return true
    }

    /// Clears restore suppression only for permanent pane retirement.
    func retirePanePermanently(paneID: UUID) async {
        clearRestorePhaseGeneration(for: paneID)
        retirePaneStatePermanently(for: paneID)
    }

    func isRestorePhaseActive(paneID: UUID) -> Bool {
        restorePhaseGeneration(for: paneID) != nil
    }

    /// Returns the latest row total represented by the compact burst state.
    func currentLatestTotal(_ state: TerminalOutputBurstState) -> Int? {
        switch state {
        case .unknown: return nil
        case .quiet(let lastTotal): return lastTotal
        case .accumulating(let burst): return burst.latestTotal
        }
    }

    /// Discards replay growth and makes the latest known total the new baseline.
    func outputBurstBaselineAfterRestorePhaseEnd(
        from state: TerminalOutputBurstState
    ) -> TerminalOutputBurstState {
        .quiet(lastTotal: currentLatestTotal(state) ?? 0)
    }

    /// Keeps the compact output burst and pin projection current while the
    /// restore phase suppresses activity windows.
    func nextOutputBurst(
        current: TerminalOutputBurstState,
        aggregate: TerminalScrollbarActivityAggregate,
        threshold: Int
    ) -> TerminalOutputBurstState {
        let baseline: Int
        let priorRowsAdded: Int
        switch current {
        case .unknown:
            baseline = aggregate.firstTotalRows
            priorRowsAdded = 0
        case .quiet(let lastTotal):
            baseline = lastTotal
            priorRowsAdded = 0
        case .accumulating(let burst):
            baseline = burst.baselineTotal
            priorRowsAdded = burst.addedRows
        }
        let rowsAdded =
            priorRowsAdded
            + max(0, aggregate.firstTotalRows - (currentLatestTotal(current) ?? aggregate.firstTotalRows))
            + aggregate.cumulativePositiveRowGrowth
        guard rowsAdded > 0 else { return .quiet(lastTotal: aggregate.latestTotalRows) }
        return .accumulating(
            TerminalOutputBurst(
                baselineTotal: baseline,
                latestTotal: aggregate.latestTotalRows,
                addedRows: rowsAdded,
                threshold: threshold
            )
        )
    }

    func pinnedObservationTransitions(
        previousIsPinnedToBottom: Bool?,
        aggregate: TerminalScrollbarActivityAggregate,
        latestIsPinnedToBottom: Bool
    ) -> [Bool] {
        var projectedIsPinnedToBottom = previousIsPinnedToBottom
        var transitions: [Bool] = []
        func appendChangedState(_ isPinnedToBottom: Bool) {
            guard isPinnedToBottom != projectedIsPinnedToBottom else { return }
            transitions.append(isPinnedToBottom)
            projectedIsPinnedToBottom = isPinnedToBottom
        }

        appendChangedState(aggregate.firstIsPinnedToBottom)
        if aggregate.firstIsPinnedToBottom {
            if aggregate.didExitPinnedToBottom { appendChangedState(false) }
            if aggregate.didEnterPinnedToBottom { appendChangedState(true) }
        } else {
            if aggregate.didEnterPinnedToBottom { appendChangedState(true) }
            if aggregate.didExitPinnedToBottom { appendChangedState(false) }
        }
        appendChangedState(latestIsPinnedToBottom)
        return transitions
    }
}

/// Producer-owned currentness travels with the matched generation. A raw
/// generation can become stale while its single MainActor delivery is queued.
struct RestorePhaseGenerationClaim: Sendable {
    private let generation: RestoreGeneration
    private let validity: RestorePhaseArmValidity

    init(generation: RestoreGeneration, validity: RestorePhaseArmValidity) {
        self.generation = generation
        self.validity = validity
    }

    /// Validate inside the synchronous native-application turn. Surface
    /// replacement cannot interleave with this turn; rearming invalidates the
    /// claim before any newer surface can be published on MainActor.
    @MainActor func withCurrentGeneration<Output: Sendable>(_ apply: (RestoreGeneration) -> Output) -> Output? {
        guard validity.isCurrent else { return nil }
        return apply(generation)
    }
}

/// Only the projector writes this one-way arm validity; native application
/// reads it without a second actor round trip. No lock crosses an await.
final class RestorePhaseArmValidity: Sendable {
    private let state = Mutex(true)
    var isCurrent: Bool { state.withLock { $0 } }
    func invalidate() { state.withLock { $0 = false } }
}
