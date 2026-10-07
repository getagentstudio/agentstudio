import AgentStudioCore
import Foundation

extension TerminalActivityProjector {
    /// A newer restore generation replaces the previous arm for this pane.
    func armRestorePhase(paneID: UUID, generation: RestoreGeneration) {
        recordRestorePhaseGeneration(generation, for: paneID)
        discardOpenActivityWindowsForRestorePhaseArm(for: paneID)
    }

    /// Only a matching generation ends suppression and establishes a fresh
    /// activity baseline. A stale or duplicate end has no effect.
    @discardableResult
    func endRestorePhase(paneID: UUID, generation: RestoreGeneration) -> Bool {
        guard endRestorePhaseGenerationIfMatching(paneID: paneID, generation: generation) else {
            return false
        }
        resetPaneActivityBaselineAfterRestorePhaseEnd(for: paneID)
        return true
    }

    /// Clears restore suppression only for permanent pane retirement.
    func retirePanePermanently(paneID: UUID) {
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
