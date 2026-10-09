import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension TerminalLocalActionAccumulator {
    func titleMetadataAction(
        from action: TerminalLocalAccumulatorAction
    ) -> TerminalLatestSemanticMetadataAction {
        switch action {
        case .titleChanged(let title): .titleChanged(title)
        case .tabTitleChanged(let title): .tabTitleChanged(title)
        default: preconditionFailure("Only title actions enter the title lane")
        }
    }

    func isTitleAction(_ action: TerminalLocalAccumulatorAction) -> Bool {
        switch action {
        case .titleChanged, .tabTitleChanged:
            return true
        case .scrollbar, .mouseShape, .mouseVisibility, .searchStarted, .searchEnded, .searchMatches,
            .searchSelection:
            return false
        }
    }

    func apply(
        _ action: TerminalLocalAccumulatorAction,
        to state: inout SurfaceState
    ) -> TerminalLocalAccumulatorOfferResult {
        switch action {
        case .scrollbar(let scrollbarState, let observedAtMilliseconds):
            return applyScrollbar(
                scrollbarState,
                observedAtMilliseconds: observedAtMilliseconds,
                to: &state
            )
        case .mouseShape(let mouseShape):
            let hadCurrentValue = state.pending.presentation.mouseShape != nil
            let result = replacementResult(current: state.pending.presentation.mouseShape, next: mouseShape)
            state.pending.presentation.mouseShape = mouseShape
            record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
            return result
        case .mouseVisibility(let isVisible):
            let hadCurrentValue = state.pending.presentation.mouseVisibility != nil
            let result = replacementResult(current: state.pending.presentation.mouseVisibility, next: isVisible)
            state.pending.presentation.mouseVisibility = isVisible
            record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
            return result
        case .searchStarted(let query):
            state.search.epoch &+= 1
            state.search.isActive = true
            state.pending.presentation.searchUpdate = nil
            if var summary = state.pending.searchLifecycle {
                summary.recordStarted(query: query, epoch: state.search.epoch)
                state.pending.searchLifecycle = summary
            } else {
                state.pending.searchLifecycle = TerminalSearchLifecycleSummary(
                    query: query,
                    epoch: state.search.epoch
                )
            }
            return .coalesced
        case .searchEnded:
            guard state.search.isActive else { return .equalSuppressed }
            state.search.isActive = false
            state.pending.presentation.searchUpdate = nil
            if var summary = state.pending.searchLifecycle {
                summary.recordEnded(epoch: state.search.epoch)
                state.pending.searchLifecycle = summary
            } else {
                state.pending.searchLifecycle = TerminalSearchLifecycleSummary(endedEpoch: state.search.epoch)
            }
            return .coalesced
        case .searchMatches(let totalMatches):
            guard state.search.isActive else { return .rejectedInactiveSearch }
            var update =
                state.pending.presentation.searchUpdate
                ?? TerminalSearchPresentationUpdate(
                    epoch: state.search.epoch,
                    hasTotalMatchesUpdate: false,
                    totalMatches: nil,
                    hasSelectionUpdate: false,
                    selectedMatchIndex: nil
                )
            let hadCurrentValue = update.hasTotalMatchesUpdate
            let result: TerminalLocalAccumulatorOfferResult =
                hadCurrentValue && update.totalMatches == totalMatches ? .equalSuppressed : .coalesced
            update.hasTotalMatchesUpdate = true
            update.totalMatches = totalMatches
            state.pending.presentation.searchUpdate = update
            record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
            return result
        case .searchSelection(let selectedMatchIndex):
            guard state.search.isActive else { return .rejectedInactiveSearch }
            var update =
                state.pending.presentation.searchUpdate
                ?? TerminalSearchPresentationUpdate(
                    epoch: state.search.epoch,
                    hasTotalMatchesUpdate: false,
                    totalMatches: nil,
                    hasSelectionUpdate: false,
                    selectedMatchIndex: nil
                )
            let hadCurrentValue = update.hasSelectionUpdate
            let result: TerminalLocalAccumulatorOfferResult =
                hadCurrentValue && update.selectedMatchIndex == selectedMatchIndex ? .equalSuppressed : .coalesced
            update.hasSelectionUpdate = true
            update.selectedMatchIndex = selectedMatchIndex
            state.pending.presentation.searchUpdate = update
            record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
            return result
        case .titleChanged(let title):
            return applyTitleMetadata(.titleChanged(title), to: &state)
        case .tabTitleChanged(let title):
            return applyTitleMetadata(.tabTitleChanged(title), to: &state)
        }
    }

    private func applyScrollbar(
        _ scrollbarState: ScrollbarState,
        observedAtMilliseconds: Int64,
        to state: inout SurfaceState
    ) -> TerminalLocalAccumulatorOfferResult {
        if let latestTotalRows = state.latestObservedScrollbarTotalRows,
            scrollbarState.total > latestTotalRows
        {
            state.pending.metrics.outputAdvancementCount &+= 1
        }
        state.latestObservedScrollbarTotalRows = scrollbarState.total
        let hadCurrentValue = state.pending.presentation.scrollbarState != nil
        let result = replacementResult(current: state.pending.presentation.scrollbarState, next: scrollbarState)
        if result == .equalSuppressed {
            record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
            return result
        }
        state.pending.presentation.scrollbarState = scrollbarState
        if var activity = state.pending.activity {
            activity.merge(state: scrollbarState, observedAtMilliseconds: observedAtMilliseconds)
            state.pending.activity = activity
        } else {
            state.pending.activity = TerminalScrollbarActivityAggregate(
                state: scrollbarState,
                observedAtMilliseconds: observedAtMilliseconds
            )
            state.pending.activityContext = state.activityContext
        }
        record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
        return result
    }

    func applyTitleMetadata(
        _ metadata: TerminalLatestSemanticMetadataAction,
        to state: inout SurfaceState
    ) -> TerminalLocalAccumulatorOfferResult {
        let hadCurrentValue = state.pending.titleMetadata != nil
        let result = replacementResult(current: state.pending.titleMetadata?.runtimeTitle, next: metadata)
        let surfaceTitle: String?
        switch metadata {
        case .titleChanged(let title):
            surfaceTitle = title
        case .tabTitleChanged:
            surfaceTitle = state.pending.titleMetadata?.surfaceTitle
        }
        state.pending.titleMetadata = TerminalTitleMetadataBatch(
            runtimeTitle: metadata,
            surfaceTitle: surfaceTitle
        )
        record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.metrics)
        record(result, replacedExistingValue: hadCurrentValue, in: &state.pending.titleMetrics)
        return result
    }

    private func replacementResult<Value: Equatable>(
        current: Value?,
        next: Value
    ) -> TerminalLocalAccumulatorOfferResult {
        guard let current else { return .coalesced }
        return current == next ? .equalSuppressed : .coalesced
    }

    private func record(
        _ result: TerminalLocalAccumulatorOfferResult,
        replacedExistingValue: Bool,
        in metrics: inout TerminalLocalAccumulatorMetrics
    ) {
        switch result {
        case .coalesced:
            if replacedExistingValue {
                metrics.replacedCount += 1
            }
        case .equalSuppressed:
            metrics.equalSuppressedCount += 1
        case .scheduled, .rejectedInactiveSearch, .retired:
            break
        }
    }
}
