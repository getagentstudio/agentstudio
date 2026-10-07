import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Terminal-owned fixed-key contraction point for high-rate local Ghostty signals.
/// It retains no view, runtime, borrowed pointer, or globally replayable event.
final class TerminalLocalActionAccumulator: @unchecked Sendable {
    static let maximumRetainedEntriesPerSurface = 9

    private enum DrainPhase: Equatable {
        case idle
        case scheduled
        case draining
    }

    private enum PublicationState<Value: Equatable>: Equatable {
        case unknown
        case pending(Value, lastCommitted: Value?)
        case committed(Value)

        mutating func admit(_ candidate: Value) -> Bool {
            switch self {
            case .unknown:
                self = .pending(candidate, lastCommitted: nil)
                return true
            case .pending(let pending, let lastCommitted):
                guard candidate != pending else { return false }
                self = .pending(candidate, lastCommitted: lastCommitted)
                return true
            case .committed(let committed):
                guard candidate != committed else { return false }
                self = .pending(candidate, lastCommitted: committed)
                return true
            }
        }

        mutating func acknowledge(_ applied: Value) {
            switch self {
            case .unknown:
                self = .committed(applied)
            case .pending(let pending, _):
                self =
                    pending == applied
                    ? .committed(applied)
                    : .pending(pending, lastCommitted: applied)
            case .committed:
                self = .committed(applied)
            }
        }

        func isPending(_ projection: Value) -> Bool {
            guard case .pending(let pending, _) = self else { return false }
            return pending == projection
        }
    }

    private struct SearchLifecycleState {
        var epoch: UInt64 = 0
        var isActive = false
    }

    private struct PendingBatch {
        var presentation = TerminalLocalPresentationBatch()
        var activity: TerminalScrollbarActivityAggregate?
        var activityContext: TerminalActivityProjectionContext?
        var searchLifecycle: TerminalSearchLifecycleSummary?
        var titleMetadata: TerminalTitleMetadataBatch?
        var metrics = TerminalLocalAccumulatorMetrics()
        var titleMetrics = TerminalLocalAccumulatorMetrics()
        var firstOfferedAtNanoseconds: UInt64?
        var firstTitleOfferedAtNanoseconds: UInt64?
        var firstNonTitleOfferedAtNanoseconds: UInt64?

        var hasWork: Bool {
            presentation.scrollbarState != nil
                || presentation.mouseShape != nil
                || presentation.mouseVisibility != nil
                || presentation.searchUpdate != nil
                || activity != nil
                || searchLifecycle != nil
                || titleMetadata != nil
        }
    }

    private struct SurfaceState {
        var phases: [TerminalLocalActionLane: DrainPhase] = [:]
        var pending = PendingBatch()
        var titlePending = PendingBatch()
        var titleDeadlineNanoseconds: UInt64?
        var search = SearchLifecycleState()
        var activityContext: TerminalActivityProjectionContext?
        var titlePublicationState: PublicationState<TerminalTitleMetadataBatch> = .unknown
        var activityPublicationState: PublicationState<TerminalScrollbarActivityAggregate> = .unknown
        var cwdPublicationState: PublicationState<String> = .unknown
        var cwdRetryRequired = false
        var publicationRetryAwaitingDemand: Set<TerminalLocalActionLane> = []
        var latestObservedScrollbarTotalRows: Int?
        /// SR6b: immediate-lane only; `beginDrain` pulls it independently.
        var pendingRestorePhaseEnd: TerminalLocalRestorePhaseEnd?

        func phase(for lane: TerminalLocalActionLane) -> DrainPhase {
            phases[lane] ?? .idle
        }

        mutating func setPhase(_ phase: DrainPhase, for lane: TerminalLocalActionLane) {
            phases[lane] = phase
        }

        func pending(for lane: TerminalLocalActionLane) -> PendingBatch {
            switch lane {
            case .immediate: pending
            case .title: titlePending
            }
        }

        mutating func setPending(_ pending: PendingBatch, for lane: TerminalLocalActionLane) {
            switch lane {
            case .immediate: self.pending = pending
            case .title: titlePending = pending
            }
        }

        var hasAnyPendingWork: Bool {
            pending.hasWork || titlePending.hasWork || pendingRestorePhaseEnd != nil
        }

        var hasPublicationState: Bool {
            titlePublicationState != .unknown || activityPublicationState != .unknown
                || cwdPublicationState != .unknown
        }
    }

    // Lock order is accumulator -> scheduler. Scheduler callbacks only register,
    // upgrade, cancel, or record a follow-up claim; they never call back into the
    // accumulator while either lock is held.
    private let lock = NSLock()
    private let scheduleDrain: @Sendable (UUID, TerminalLocalDrainRequest) -> Void
    private let scheduleFollowUpDrain: @Sendable (UUID, TerminalLocalDrainRequest) -> Void
    private let cancelScheduledTitleDrain: @Sendable (UUID) -> Void
    private let nowNanoseconds: @Sendable () -> UInt64
    private var statesBySurfaceID: [UUID: SurfaceState] = [:]
    private var searchEpochWatermarksBySurfaceID: [UUID: UInt64] = [:]

    init(
        scheduleDrain: @escaping @Sendable (UUID, TerminalLocalDrainRequest) -> Void,
        scheduleFollowUpDrain: (@Sendable (UUID, TerminalLocalDrainRequest) -> Void)? = nil,
        cancelScheduledTitleDrain: @escaping @Sendable (UUID) -> Void = { _ in },
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.scheduleDrain = scheduleDrain
        self.scheduleFollowUpDrain = scheduleFollowUpDrain ?? scheduleDrain
        self.cancelScheduledTitleDrain = cancelScheduledTitleDrain
        self.nowNanoseconds = nowNanoseconds
    }

    @discardableResult
    func offer(_ action: TerminalLocalAccumulatorAction, for surfaceID: UUID) -> TerminalLocalAccumulatorOfferResult {
        lock.withLock { () -> TerminalLocalAccumulatorOfferResult in
            var state =
                statesBySurfaceID[surfaceID]
                ?? SurfaceState(
                    search: SearchLifecycleState(
                        epoch: searchEpochWatermarksBySurfaceID[surfaceID] ?? 0
                    )
                )
            let lane: TerminalLocalActionLane = isTitleAction(action) ? .title : .immediate
            state.publicationRetryAwaitingDemand.remove(lane)
            let offeredAtNanoseconds = nowNanoseconds()
            var pending = state.pending(for: lane)
            if pending.firstOfferedAtNanoseconds == nil {
                pending.firstOfferedAtNanoseconds = offeredAtNanoseconds
            }
            if lane == .title, pending.firstTitleOfferedAtNanoseconds == nil {
                pending.firstTitleOfferedAtNanoseconds = offeredAtNanoseconds
                state.titleDeadlineNanoseconds = offeredAtNanoseconds &+ 1_000_000_000
            }
            if lane == .immediate, pending.firstNonTitleOfferedAtNanoseconds == nil {
                pending.firstNonTitleOfferedAtNanoseconds = offeredAtNanoseconds
            }
            pending.metrics.offeredCount += 1
            if lane == .title {
                pending.titleMetrics.offeredCount += 1
            }
            state.setPending(pending, for: lane)
            let mutationResult: TerminalLocalAccumulatorOfferResult
            if lane == .title {
                var titleState = state
                titleState.pending = state.titlePending
                mutationResult = applyTitleMetadata(titleMetadataAction(from: action), to: &titleState)
                state.titlePending = titleState.pending
                guard let candidate = state.titlePending.titleMetadata else {
                    preconditionFailure("Title admission must retain a title projection")
                }
                if !state.titlePublicationState.isPending(candidate),
                    !state.titlePublicationState.admit(candidate)
                {
                    state.titlePending = PendingBatch()
                    statesBySurfaceID[surfaceID] = state
                    return .equalSuppressed
                }
            } else {
                mutationResult = apply(action, to: &state)
                if case .scrollbar = action, let candidate = state.pending.activity,
                    !state.activityPublicationState.isPending(candidate),
                    !state.activityPublicationState.admit(candidate)
                {
                    state.pending.presentation.scrollbarState = nil
                    state.pending.activity = nil
                    state.pending.activityContext = nil
                    if !state.pending.hasWork {
                        state.pending = PendingBatch()
                    }
                    statesBySurfaceID[surfaceID] = state
                    return .equalSuppressed
                }
            }
            if state.search.epoch > 0 {
                searchEpochWatermarksBySurfaceID[surfaceID] = state.search.epoch
            }
            guard mutationResult != .rejectedInactiveSearch else {
                if state.hasAnyPendingWork || state.phase(for: lane) != .idle || state.search.isActive {
                    statesBySurfaceID[surfaceID] = state
                }
                return mutationResult
            }
            switch state.phase(for: lane) {
            case .idle:
                state.setPhase(.scheduled, for: lane)
                var scheduledPending = state.pending(for: lane)
                scheduledPending.metrics.scheduledDrainCount += 1
                if lane == .title {
                    scheduledPending.titleMetrics.scheduledDrainCount += 1
                }
                state.setPending(scheduledPending, for: lane)
                statesBySurfaceID[surfaceID] = state
                scheduleDrain(surfaceID, drainRequest(for: lane, state: state))
                return .scheduled
            case .scheduled, .draining:
                break
            }
            statesBySurfaceID[surfaceID] = state
            return mutationResult
        }
    }

    /// Seals the latest title admitted before an exact fact/control. Cancellation
    /// is ordered under the same per-surface lock so a later title cannot lose its
    /// newly registered deadline to the earlier barrier.
    func detachTitleBeforeExactBarrier(for surfaceID: UUID) -> TerminalPrecedingTitleBarrier? {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID], let titleMetadata = state.titlePending.titleMetadata
            else { return nil }

            state.titlePending.titleMetadata = nil
            let titleMetrics = state.titlePending.titleMetrics
            let firstTitleOfferedAtNanoseconds =
                state.titlePending.firstTitleOfferedAtNanoseconds
                ?? nowNanoseconds()
            guard let remainingMetrics = state.titlePending.metrics.subtracting(titleMetrics) else {
                preconditionFailure("Title metrics must be a subset of pending accumulator metrics")
            }
            state.titlePending.metrics = remainingMetrics
            state.titlePending.titleMetrics = TerminalLocalAccumulatorMetrics()
            state.titlePending.firstTitleOfferedAtNanoseconds = nil
            state.titleDeadlineNanoseconds = nil
            if state.phase(for: .title) == .scheduled {
                cancelScheduledTitleDrain(surfaceID)
                state.setPhase(.idle, for: .title)
            }

            if !state.titlePending.hasWork {
                state.titlePending.firstOfferedAtNanoseconds = nil
                if !state.hasAnyPendingWork, state.phase(for: .immediate) == .idle, !state.search.isActive {
                    statesBySurfaceID.removeValue(forKey: surfaceID)
                } else {
                    statesBySurfaceID[surfaceID] = state
                }
            } else {
                statesBySurfaceID[surfaceID] = state
            }
            return TerminalPrecedingTitleBarrier(
                metadata: titleMetadata,
                metrics: titleMetrics,
                firstOfferedAtNanoseconds: firstTitleOfferedAtNanoseconds
            )
        }
    }

    func beginDrain(
        for surfaceID: UUID,
        lane: TerminalLocalActionLane,
        defaultActivityContext: TerminalActivityProjectionContext? = nil
    ) -> TerminalLocalActionBatch? {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID] else { return nil }
            guard case .scheduled = state.phase(for: lane) else { return nil }
            // SR6b: not part of `pending.hasWork` — pulled independently.
            let restorePhaseEnd = lane == .immediate ? state.pendingRestorePhaseEnd : nil
            guard state.pending(for: lane).hasWork || restorePhaseEnd != nil else {
                state.setPhase(.idle, for: lane)
                if lane == .title {
                    cancelScheduledTitleDrain(surfaceID)
                }
                statesBySurfaceID[surfaceID] = state
                return nil
            }
            state.setPhase(.draining, for: lane)
            let detached = state.pending(for: lane)
            state.setPending(PendingBatch(), for: lane)
            if lane == .title { state.titleDeadlineNanoseconds = nil }
            if lane == .immediate { state.pendingRestorePhaseEnd = nil }
            statesBySurfaceID[surfaceID] = state
            return TerminalLocalActionBatch(
                surfaceID: surfaceID,
                presentation: detached.presentation,
                activity: detached.activity,
                activityContext: detached.activity == nil
                    ? nil
                    : detached.activityContext ?? state.activityContext ?? defaultActivityContext,
                searchLifecycle: detached.searchLifecycle,
                titleMetadata: detached.titleMetadata,
                metrics: detached.metrics,
                firstOfferedAtNanoseconds: detached.firstOfferedAtNanoseconds
                    ?? DispatchTime.now().uptimeNanoseconds,
                restorePhaseEnd: restorePhaseEnd
            )
        }
    }

    /// SR6b: the cold latch calls this synchronously, splitting pending
    /// activity ahead of the control. A later call before the drain is a no-op.
    func markRestorePhaseEnded(
        surfaceID: UUID, generation: RestoreGeneration, contextBeforeControl: TerminalActivityProjectionContext?
    ) {
        lock.withLock {
            let watermark = searchEpochWatermarksBySurfaceID[surfaceID] ?? 0
            var state = statesBySurfaceID[surfaceID] ?? SurfaceState(search: SearchLifecycleState(epoch: watermark))
            guard state.pendingRestorePhaseEnd == nil else { return }
            var precedingAggregate: TerminalActivityAggregateInput?
            if let aggregate = state.pending.activity,
                let latestState = state.pending.presentation.scrollbarState,
                let context = state.pending.activityContext ?? state.activityContext ?? contextBeforeControl
            {
                precedingAggregate = TerminalActivityAggregateInput(
                    aggregate: aggregate, latestState: latestState, context: context)
                state.pending.activity = nil
                state.pending.activityContext = nil
            }
            state.pendingRestorePhaseEnd = TerminalLocalRestorePhaseEnd(
                precedingAggregate: precedingAggregate, generation: generation)
            let wasIdle = state.phase(for: .immediate) == .idle
            if wasIdle { state.setPhase(.scheduled, for: .immediate) }
            statesBySurfaceID[surfaceID] = state
            if wasIdle { scheduleDrain(surfaceID, drainRequest(for: .immediate, state: state)) }
        }
    }

    func acknowledgeSuccessfulTitlePublication(
        _ appliedProjection: TerminalTitleMetadataBatch,
        for surfaceID: UUID
    ) {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID] else { return }
            state.titlePublicationState.acknowledge(appliedProjection)
            statesBySurfaceID[surfaceID] = state
        }
    }

    func acknowledgeSuccessfulActivityPublication(
        _ appliedProjection: TerminalScrollbarActivityAggregate,
        for surfaceID: UUID
    ) {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID] else { return }
            state.activityPublicationState.acknowledge(appliedProjection)
            statesBySurfaceID[surfaceID] = state
        }
    }

    func admitCWDPublication(
        _ cwdPath: String,
        for surfaceID: UUID
    ) -> TerminalLocalAccumulatorOfferResult {
        lock.withLock {
            var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
            let normalizedCWDPath = Self.normalizedCWDPath(cwdPath)
            if state.cwdRetryRequired, state.cwdPublicationState.isPending(normalizedCWDPath) {
                state.cwdRetryRequired = false
                statesBySurfaceID[surfaceID] = state
                return .scheduled
            }
            guard !state.cwdPublicationState.isPending(normalizedCWDPath) else {
                statesBySurfaceID[surfaceID] = state
                return .equalSuppressed
            }
            guard state.cwdPublicationState.admit(normalizedCWDPath) else {
                statesBySurfaceID[surfaceID] = state
                return .equalSuppressed
            }
            state.cwdRetryRequired = false
            statesBySurfaceID[surfaceID] = state
            return .scheduled
        }
    }

    func acknowledgeSuccessfulCWDPublication(_ cwdPath: String, for surfaceID: UUID) {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID] else { return }
            state.cwdPublicationState.acknowledge(Self.normalizedCWDPath(cwdPath))
            state.cwdRetryRequired = false
            statesBySurfaceID[surfaceID] = state
        }
    }

    func recordFailedCWDPublication(_ cwdPath: String, for surfaceID: UUID) {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID],
                state.cwdPublicationState.isPending(Self.normalizedCWDPath(cwdPath))
            else { return }
            state.cwdRetryRequired = true
            statesBySurfaceID[surfaceID] = state
        }
    }

    func restoreUnacknowledgedPublications(from batch: TerminalLocalActionBatch) {
        lock.withLock {
            guard var state = statesBySurfaceID[batch.surfaceID] else { return }
            if let title = batch.titleMetadata,
                state.titlePublicationState.isPending(title),
                state.titlePending.titleMetadata == nil
            {
                state.titlePending.titleMetadata = title
                state.titlePending.firstOfferedAtNanoseconds = batch.firstOfferedAtNanoseconds
                state.titlePending.firstTitleOfferedAtNanoseconds = batch.firstOfferedAtNanoseconds
                state.titleDeadlineNanoseconds = nowNanoseconds() &+ 1_000_000_000
                state.publicationRetryAwaitingDemand.insert(.title)
            }
            if let activity = batch.activity,
                state.activityPublicationState.isPending(activity),
                state.pending.activity == nil
            {
                state.pending.activity = activity
                state.pending.activityContext = batch.activityContext
                state.pending.presentation.scrollbarState = batch.presentation.scrollbarState
                state.pending.firstOfferedAtNanoseconds = batch.firstOfferedAtNanoseconds
                state.pending.firstNonTitleOfferedAtNanoseconds = batch.firstOfferedAtNanoseconds
                state.publicationRetryAwaitingDemand.insert(.immediate)
            }
            statesBySurfaceID[batch.surfaceID] = state
        }
    }

    func detachActivityBeforeControl(
        for surfaceID: UUID,
        contextBeforeControl: TerminalActivityProjectionContext?,
        contextAfterControl: TerminalActivityProjectionContext?
    ) -> TerminalActivityAggregateInput? {
        lock.withLock {
            guard var state = statesBySurfaceID[surfaceID] else { return nil }
            defer {
                state.activityContext = contextAfterControl ?? state.activityContext
                statesBySurfaceID[surfaceID] = state
            }
            guard
                let aggregate = state.pending.activity,
                let latestState = state.pending.presentation.scrollbarState,
                let context = state.pending.activityContext ?? state.activityContext ?? contextBeforeControl
            else { return nil }
            state.pending.activity = nil
            state.pending.activityContext = nil
            return TerminalActivityAggregateInput(
                aggregate: aggregate,
                latestState: latestState,
                context: context
            )
        }
    }

    func detachActivityForSurfaceClose(
        _ surfaceID: UUID,
        defaultActivityContext: TerminalActivityProjectionContext?
    ) -> TerminalActivityAggregateInput? {
        lock.withLock {
            searchEpochWatermarksBySurfaceID.removeValue(forKey: surfaceID)
            guard let state = statesBySurfaceID.removeValue(forKey: surfaceID),
                let aggregate = state.pending.activity,
                let latestState = state.pending.presentation.scrollbarState,
                let context = state.pending.activityContext ?? state.activityContext ?? defaultActivityContext
            else { return nil }
            return TerminalActivityAggregateInput(
                aggregate: aggregate,
                latestState: latestState,
                context: context
            )
        }
    }

    func finishDrain(
        for surfaceID: UUID,
        lane: TerminalLocalActionLane
    ) -> TerminalLocalAccumulatorDrainCompletion {
        lock.withLock { () -> TerminalLocalAccumulatorDrainCompletion in
            guard var state = statesBySurfaceID[surfaceID], state.phase(for: lane) == .draining else { return .idle }
            // F2 (review round 1): a control landing mid-drain was never
            // part of the batch `beginDrain` already detached (`markRestorePhaseEnded`
            // schedules nothing while this lane is draining) -- only a
            // follow-up from here can ever deliver it. Its presence alone
            // demands one, unconditionally, ahead of and independent of the
            // publication-retry-awaiting-demand branch just below: that
            // branch exists for a REJECTED publication waiting on new
            // demand, a different concern from an un-sent control that must
            // never be dropped.
            if lane == .immediate, state.pendingRestorePhaseEnd != nil {
                state.setPhase(.scheduled, for: lane)
                var pending = state.pending(for: lane)
                pending.metrics.followUpDrainCount += 1
                state.setPending(pending, for: lane)
                statesBySurfaceID[surfaceID] = state
                scheduleFollowUpDrain(surfaceID, drainRequest(for: lane, state: state))
                return .followUpScheduled
            }
            if state.pending(for: lane).hasWork {
                if state.publicationRetryAwaitingDemand.contains(lane) {
                    state.setPhase(.idle, for: lane)
                    statesBySurfaceID[surfaceID] = state
                    return .idle
                }
                state.setPhase(.scheduled, for: lane)
                var pending = state.pending(for: lane)
                pending.metrics.followUpDrainCount += 1
                if lane == .title {
                    pending.titleMetrics.followUpDrainCount += 1
                }
                state.setPending(pending, for: lane)
                statesBySurfaceID[surfaceID] = state
                scheduleFollowUpDrain(surfaceID, drainRequest(for: lane, state: state))
                return .followUpScheduled
            }
            if lane == .immediate, state.search.isActive {
                state.setPhase(.idle, for: lane)
                statesBySurfaceID[surfaceID] = state
            } else if state.hasAnyPendingWork || state.hasPublicationState
                || state.phase(for: lane == .immediate ? .title : .immediate) != .idle
            {
                state.setPhase(.idle, for: lane)
                statesBySurfaceID[surfaceID] = state
            } else {
                statesBySurfaceID.removeValue(forKey: surfaceID)
            }
            return .idle
        }
    }

    func removeSurface(_ surfaceID: UUID) {
        lock.withLock {
            if statesBySurfaceID[surfaceID]?.phase(for: .title) == .scheduled {
                cancelScheduledTitleDrain(surfaceID)
            }
            statesBySurfaceID.removeValue(forKey: surfaceID)
            searchEpochWatermarksBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    var pendingSurfaceCount: Int {
        lock.withLock {
            statesBySurfaceID.values.count {
                $0.phase(for: .immediate) != .idle || $0.phase(for: .title) != .idle || $0.hasAnyPendingWork
            }
        }
    }

    func hasPendingActions(for surfaceID: UUID) -> Bool {
        lock.withLock {
            statesBySurfaceID[surfaceID]?.hasAnyPendingWork == true
        }
    }

    var retainedEntryCount: Int {
        lock.withLock {
            statesBySurfaceID.values.reduce(into: 0) { result, state in
                if state.pending.presentation.scrollbarState != nil { result += 1 }
                if state.pending.presentation.mouseShape != nil { result += 1 }
                if state.pending.presentation.mouseVisibility != nil { result += 1 }
                if state.pending.presentation.searchUpdate != nil { result += 1 }
                if state.pending.activity != nil { result += 1 }
                if state.pending.searchLifecycle != nil { result += 1 }
                if state.titlePending.titleMetadata != nil {
                    result += 1
                    if state.titlePending.titleMetadata?.surfaceTitle != nil { result += 1 }
                }
            }
        }
    }

    private func drainRequest(
        for lane: TerminalLocalActionLane,
        state: SurfaceState
    ) -> TerminalLocalDrainRequest {
        TerminalLocalDrainRequest(
            lane: lane,
            absoluteDeadlineNanoseconds: lane == .title ? state.titleDeadlineNanoseconds : nil
        )
    }

    private static func normalizedCWDPath(_ cwdPath: String) -> String {
        URL(fileURLWithPath: cwdPath).standardizedFileURL.path
    }

    private func titleMetadataAction(
        from action: TerminalLocalAccumulatorAction
    ) -> TerminalLatestSemanticMetadataAction {
        switch action {
        case .titleChanged(let title): .titleChanged(title)
        case .tabTitleChanged(let title): .tabTitleChanged(title)
        default: preconditionFailure("Only title actions enter the title lane")
        }
    }

    private func isTitleAction(_ action: TerminalLocalAccumulatorAction) -> Bool {
        switch action {
        case .titleChanged, .tabTitleChanged:
            return true
        case .scrollbar, .mouseShape, .mouseVisibility, .searchStarted, .searchEnded, .searchMatches,
            .searchSelection:
            return false
        }
    }

    private func apply(
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

    private func applyTitleMetadata(
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
        case .scheduled, .rejectedInactiveSearch:
            break
        }
    }
}
