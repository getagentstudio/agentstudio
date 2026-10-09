import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Synchronization

/// Terminal-owned fixed-key contraction point for high-rate local Ghostty signals.
/// It retains no view, runtime, borrowed pointer, or globally replayable event.
final class TerminalLocalActionAccumulator: Sendable {
    static let maximumRetainedEntriesPerSurface = 9

    enum DrainPhase: Equatable {
        case idle
        case scheduled
        case draining
    }

    enum PublicationState<Value: Equatable>: Equatable {
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

    struct SearchLifecycleState {
        var epoch: UInt64 = 0
        var isActive = false
    }

    struct PendingBatch {
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

    struct SurfaceState {
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
            pending.hasWork || titlePending.hasWork
        }

        var hasPublicationState: Bool {
            titlePublicationState != .unknown || activityPublicationState != .unknown
                || cwdPublicationState != .unknown
        }
    }

    // Lock order is accumulator -> scheduler. Scheduler callbacks only register,
    // upgrade, cancel, or record a follow-up claim; they never call back into the
    // accumulator while either lock is held.
    private let scheduleDrain: @Sendable (UUID, TerminalLocalDrainRequest, TerminalLocalActionAccumulator) -> Void
    private let scheduleFollowUpDrain:
        @Sendable (UUID, TerminalLocalDrainRequest, TerminalLocalActionAccumulator) -> Void
    private let cancelScheduledTitleDrain: @Sendable (UUID) -> Void
    private let nowNanoseconds: @Sendable () -> UInt64
    private let isAcceptingWork: @Sendable () -> Bool
    private struct State {
        var statesBySurfaceID: [UUID: SurfaceState] = [:]
        var searchEpochWatermarksBySurfaceID: [UUID: UInt64] = [:]
    }

    private let state = Mutex(State())

    init(
        scheduleDrain: @escaping @Sendable (UUID, TerminalLocalDrainRequest, TerminalLocalActionAccumulator) -> Void,
        scheduleFollowUpDrain: (@Sendable (UUID, TerminalLocalDrainRequest, TerminalLocalActionAccumulator) -> Void)? =
            nil,
        cancelScheduledTitleDrain: @escaping @Sendable (UUID) -> Void = { _ in },
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        isAcceptingWork: @escaping @Sendable () -> Bool = { true }
    ) {
        self.scheduleDrain = scheduleDrain
        self.scheduleFollowUpDrain = scheduleFollowUpDrain ?? scheduleDrain
        self.cancelScheduledTitleDrain = cancelScheduledTitleDrain
        self.nowNanoseconds = nowNanoseconds
        self.isAcceptingWork = isAcceptingWork
    }

    @discardableResult
    func offer(_ action: TerminalLocalAccumulatorAction, for surfaceID: UUID) -> TerminalLocalAccumulatorOfferResult {
        state.withLock { storage -> TerminalLocalAccumulatorOfferResult in
            guard isAcceptingWork() else { return .retired }
            var state =
                storage.statesBySurfaceID[surfaceID]
                ?? SurfaceState(
                    search: SearchLifecycleState(
                        epoch: storage.searchEpochWatermarksBySurfaceID[surfaceID] ?? 0
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
                    storage.statesBySurfaceID[surfaceID] = state
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
                    storage.statesBySurfaceID[surfaceID] = state
                    return .equalSuppressed
                }
            }
            if state.search.epoch > 0 {
                storage.searchEpochWatermarksBySurfaceID[surfaceID] = state.search.epoch
            }
            guard mutationResult != .rejectedInactiveSearch else {
                if state.hasAnyPendingWork || state.phase(for: lane) != .idle || state.search.isActive {
                    storage.statesBySurfaceID[surfaceID] = state
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
                storage.statesBySurfaceID[surfaceID] = state
                scheduleDrain(surfaceID, drainRequest(for: lane, state: state), self)
                return .scheduled
            case .scheduled, .draining:
                break
            }
            storage.statesBySurfaceID[surfaceID] = state
            return mutationResult
        }
    }

    /// Seals the latest title admitted before an exact fact/control. Cancellation
    /// is ordered under the same per-surface lock so a later title cannot lose its
    /// newly registered deadline to the earlier barrier.
    func detachTitleBeforeExactBarrier(for surfaceID: UUID) -> TerminalPrecedingTitleBarrier? {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID], let titleMetadata = state.titlePending.titleMetadata
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
                    storage.statesBySurfaceID.removeValue(forKey: surfaceID)
                } else {
                    storage.statesBySurfaceID[surfaceID] = state
                }
            } else {
                storage.statesBySurfaceID[surfaceID] = state
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
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID] else { return nil }
            guard case .scheduled = state.phase(for: lane) else { return nil }
            guard state.pending(for: lane).hasWork else {
                state.setPhase(.idle, for: lane)
                if lane == .title {
                    cancelScheduledTitleDrain(surfaceID)
                }
                storage.statesBySurfaceID[surfaceID] = state
                return nil
            }
            state.setPhase(.draining, for: lane)
            let detached = state.pending(for: lane)
            state.setPending(PendingBatch(), for: lane)
            if lane == .title { state.titleDeadlineNanoseconds = nil }
            storage.statesBySurfaceID[surfaceID] = state
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
                    ?? DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    func acknowledgeSuccessfulTitlePublication(
        _ appliedProjection: TerminalTitleMetadataBatch,
        for surfaceID: UUID
    ) {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID] else { return }
            state.titlePublicationState.acknowledge(appliedProjection)
            storage.statesBySurfaceID[surfaceID] = state
        }
    }

    func acknowledgeSuccessfulActivityPublication(
        _ appliedProjection: TerminalScrollbarActivityAggregate,
        for surfaceID: UUID
    ) {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID] else { return }
            state.activityPublicationState.acknowledge(appliedProjection)
            storage.statesBySurfaceID[surfaceID] = state
        }
    }

    func admitCWDPublication(
        _ cwdPath: String,
        for surfaceID: UUID
    ) -> TerminalLocalAccumulatorOfferResult {
        state.withLock { storage in
            guard isAcceptingWork() else { return .retired }
            var state = storage.statesBySurfaceID[surfaceID] ?? SurfaceState()
            let normalizedCWDPath = Self.normalizedCWDPath(cwdPath)
            if state.cwdRetryRequired, state.cwdPublicationState.isPending(normalizedCWDPath) {
                state.cwdRetryRequired = false
                storage.statesBySurfaceID[surfaceID] = state
                return .scheduled
            }
            guard !state.cwdPublicationState.isPending(normalizedCWDPath) else {
                storage.statesBySurfaceID[surfaceID] = state
                return .equalSuppressed
            }
            guard state.cwdPublicationState.admit(normalizedCWDPath) else {
                storage.statesBySurfaceID[surfaceID] = state
                return .equalSuppressed
            }
            state.cwdRetryRequired = false
            storage.statesBySurfaceID[surfaceID] = state
            return .scheduled
        }
    }

    func acknowledgeSuccessfulCWDPublication(_ cwdPath: String, for surfaceID: UUID) {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID] else { return }
            state.cwdPublicationState.acknowledge(Self.normalizedCWDPath(cwdPath))
            state.cwdRetryRequired = false
            storage.statesBySurfaceID[surfaceID] = state
        }
    }

    func recordFailedCWDPublication(_ cwdPath: String, for surfaceID: UUID) {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID],
                state.cwdPublicationState.isPending(Self.normalizedCWDPath(cwdPath))
            else { return }
            state.cwdRetryRequired = true
            storage.statesBySurfaceID[surfaceID] = state
        }
    }

    func restoreUnacknowledgedPublications(from batch: TerminalLocalActionBatch) {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[batch.surfaceID] else { return }
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
            storage.statesBySurfaceID[batch.surfaceID] = state
        }
    }

    func detachActivityBeforeControl(
        for surfaceID: UUID,
        contextBeforeControl: TerminalActivityProjectionContext?,
        contextAfterControl: TerminalActivityProjectionContext?
    ) -> TerminalActivityAggregateInput? {
        state.withLock { storage in
            guard var state = storage.statesBySurfaceID[surfaceID] else { return nil }
            defer {
                state.activityContext = contextAfterControl ?? state.activityContext
                storage.statesBySurfaceID[surfaceID] = state
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
        state.withLock { storage in
            storage.searchEpochWatermarksBySurfaceID.removeValue(forKey: surfaceID)
            guard let state = storage.statesBySurfaceID.removeValue(forKey: surfaceID),
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
        state.withLock { storage -> TerminalLocalAccumulatorDrainCompletion in
            guard var state = storage.statesBySurfaceID[surfaceID], state.phase(for: lane) == .draining else {
                return .idle
            }
            if state.pending(for: lane).hasWork {
                if state.publicationRetryAwaitingDemand.contains(lane) {
                    state.setPhase(.idle, for: lane)
                    storage.statesBySurfaceID[surfaceID] = state
                    return .idle
                }
                state.setPhase(.scheduled, for: lane)
                var pending = state.pending(for: lane)
                pending.metrics.followUpDrainCount += 1
                if lane == .title {
                    pending.titleMetrics.followUpDrainCount += 1
                }
                state.setPending(pending, for: lane)
                storage.statesBySurfaceID[surfaceID] = state
                scheduleFollowUpDrain(surfaceID, drainRequest(for: lane, state: state), self)
                return .followUpScheduled
            }
            if lane == .immediate, state.search.isActive {
                state.setPhase(.idle, for: lane)
                storage.statesBySurfaceID[surfaceID] = state
            } else if state.hasAnyPendingWork || state.hasPublicationState
                || state.phase(for: lane == .immediate ? .title : .immediate) != .idle
            {
                state.setPhase(.idle, for: lane)
                storage.statesBySurfaceID[surfaceID] = state
            } else {
                storage.statesBySurfaceID.removeValue(forKey: surfaceID)
            }
            return .idle
        }
    }

    func removeAllSurfaces() {
        state.withLock { storage in
            storage.statesBySurfaceID.removeAll()
            storage.searchEpochWatermarksBySurfaceID.removeAll()
        }
    }

    func removeSurface(_ surfaceID: UUID) {
        state.withLock { storage in
            if storage.statesBySurfaceID[surfaceID]?.phase(for: .title) == .scheduled {
                cancelScheduledTitleDrain(surfaceID)
            }
            storage.statesBySurfaceID.removeValue(forKey: surfaceID)
            _ = storage.searchEpochWatermarksBySurfaceID.removeValue(forKey: surfaceID)
        }
    }

    var pendingSurfaceCount: Int {
        state.withLock { storage in
            storage.statesBySurfaceID.values.count {
                $0.phase(for: .immediate) != .idle || $0.phase(for: .title) != .idle || $0.hasAnyPendingWork
            }
        }
    }

    func hasPendingActions(for surfaceID: UUID) -> Bool {
        state.withLock { storage in
            storage.statesBySurfaceID[surfaceID]?.hasAnyPendingWork == true
        }
    }

    var retainedEntryCount: Int {
        state.withLock { storage in
            storage.statesBySurfaceID.values.reduce(into: 0) { result, state in
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
}
