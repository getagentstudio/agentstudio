import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Supporting value types for `TerminalLocalActionAccumulator`, split out
/// (F2, review round 1) to keep the accumulator's own file under the repo's
/// line-length ceiling with headroom for R2/R3 -- a mechanical relocation,
/// no behavior change. Matches this directory's existing precedent of
/// splitting a type's own supporting values into a sibling `*Types.swift`
/// file (see `SurfaceTypes.swift` for `SurfaceManager`).
enum TerminalLocalAccumulatorAction: Sendable, Equatable {
    case scrollbar(ScrollbarState, observedAtMilliseconds: Int64)
    case mouseShape(TerminalMouseShape)
    case mouseVisibility(Bool)
    case searchStarted(query: String?)
    case searchEnded
    case searchMatches(Int?)
    case searchSelection(Int?)
    case titleChanged(String)
    case tabTitleChanged(String)
}

enum TerminalSearchLifecycleState: Sendable, Equatable {
    case active(query: String?, epoch: UInt64)
    case inactive(lastEndedEpoch: UInt64)

    var epoch: UInt64 {
        switch self {
        case .active(_, let epoch):
            epoch
        case .inactive(let lastEndedEpoch):
            lastEndedEpoch
        }
    }

    var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }
}

struct TerminalSearchLifecycleSummary: Sendable, Equatable {
    let firstEpoch: UInt64
    private(set) var latestEpoch: UInt64
    private(set) var transitionCount: UInt64
    private(set) var state: TerminalSearchLifecycleState

    init(query: String?, epoch: UInt64) {
        firstEpoch = epoch
        latestEpoch = epoch
        transitionCount = 1
        state = .active(query: query, epoch: epoch)
    }

    init(endedEpoch: UInt64) {
        firstEpoch = endedEpoch
        latestEpoch = endedEpoch
        transitionCount = 1
        state = .inactive(lastEndedEpoch: endedEpoch)
    }

    mutating func recordStarted(query: String?, epoch: UInt64) {
        latestEpoch = epoch
        transitionCount += 1
        state = .active(query: query, epoch: epoch)
    }

    mutating func recordEnded(epoch: UInt64) {
        latestEpoch = epoch
        transitionCount += 1
        state = .inactive(lastEndedEpoch: epoch)
    }
}

struct TerminalSearchPresentationUpdate: Sendable, Equatable {
    let epoch: UInt64
    var hasTotalMatchesUpdate: Bool
    var totalMatches: Int?
    var hasSelectionUpdate: Bool
    var selectedMatchIndex: Int?
}

struct TerminalLocalPresentationBatch: Sendable, Equatable {
    var scrollbarState: ScrollbarState?
    var mouseShape: TerminalMouseShape?
    var mouseVisibility: Bool?
    var searchUpdate: TerminalSearchPresentationUpdate?
}

struct TerminalTitleMetadataBatch: Sendable, Equatable {
    var runtimeTitle: TerminalLatestSemanticMetadataAction
    var surfaceTitle: String?
}

struct TerminalPrecedingTitleBarrier: Sendable, Equatable {
    let metadata: TerminalTitleMetadataBatch
    let metrics: TerminalLocalAccumulatorMetrics
    let firstOfferedAtNanoseconds: UInt64
}

struct TerminalScrollbarActivityAggregate: Sendable, Equatable {
    let firstObservedAtMilliseconds: Int64
    private(set) var latestObservedAtMilliseconds: Int64
    let firstTotalRows: Int
    private(set) var latestTotalRows: Int
    private(set) var cumulativePositiveRowGrowth: Int
    private(set) var sampleCount: Int
    let firstIsPinnedToBottom: Bool
    private(set) var latestIsPinnedToBottom: Bool
    private(set) var didEnterPinnedToBottom: Bool
    private(set) var didExitPinnedToBottom: Bool

    init(state: ScrollbarState, observedAtMilliseconds: Int64) {
        firstObservedAtMilliseconds = observedAtMilliseconds
        latestObservedAtMilliseconds = observedAtMilliseconds
        firstTotalRows = state.total
        latestTotalRows = state.total
        cumulativePositiveRowGrowth = 0
        sampleCount = 1
        firstIsPinnedToBottom = state.isPinnedToBottom
        latestIsPinnedToBottom = state.isPinnedToBottom
        didEnterPinnedToBottom = false
        didExitPinnedToBottom = false
    }

    mutating func merge(state: ScrollbarState, observedAtMilliseconds: Int64) {
        cumulativePositiveRowGrowth += max(0, state.total - latestTotalRows)
        if state.isPinnedToBottom != latestIsPinnedToBottom {
            if state.isPinnedToBottom {
                didEnterPinnedToBottom = true
            } else {
                didExitPinnedToBottom = true
            }
        }
        latestObservedAtMilliseconds = observedAtMilliseconds
        latestTotalRows = state.total
        latestIsPinnedToBottom = state.isPinnedToBottom
        sampleCount += 1
    }
}

struct TerminalLocalAccumulatorMetrics: Sendable, Equatable {
    var offeredCount: UInt64 = 0
    var replacedCount: UInt64 = 0
    var equalSuppressedCount: UInt64 = 0
    var scheduledDrainCount: UInt64 = 0
    var followUpDrainCount: UInt64 = 0
    var outputAdvancementCount: UInt64 = 0

    func subtracting(_ subset: Self) -> Self? {
        guard
            offeredCount >= subset.offeredCount,
            replacedCount >= subset.replacedCount,
            equalSuppressedCount >= subset.equalSuppressedCount,
            scheduledDrainCount >= subset.scheduledDrainCount,
            followUpDrainCount >= subset.followUpDrainCount,
            outputAdvancementCount >= subset.outputAdvancementCount
        else { return nil }

        return Self(
            offeredCount: offeredCount - subset.offeredCount,
            replacedCount: replacedCount - subset.replacedCount,
            equalSuppressedCount: equalSuppressedCount - subset.equalSuppressedCount,
            scheduledDrainCount: scheduledDrainCount - subset.scheduledDrainCount,
            followUpDrainCount: followUpDrainCount - subset.followUpDrainCount,
            outputAdvancementCount: outputAdvancementCount - subset.outputAdvancementCount
        )
    }
}

/// SR6b: the restore-phase-ended control plus its preceding aggregate.
struct TerminalLocalRestorePhaseEnd: Sendable, Equatable {
    let precedingAggregate: TerminalActivityAggregateInput?
    let generation: RestoreGeneration
}

struct TerminalLocalActionBatch: Sendable, Equatable {
    let surfaceID: UUID
    let presentation: TerminalLocalPresentationBatch
    let activity: TerminalScrollbarActivityAggregate?
    let activityContext: TerminalActivityProjectionContext?
    let searchLifecycle: TerminalSearchLifecycleSummary?
    let titleMetadata: TerminalTitleMetadataBatch?
    let metrics: TerminalLocalAccumulatorMetrics
    let firstOfferedAtNanoseconds: UInt64
    var restorePhaseEnd: TerminalLocalRestorePhaseEnd?

    var retainedEntryCount: Int {
        var count = searchLifecycle == nil ? 0 : 1
        if presentation.scrollbarState != nil { count += 1 }
        if presentation.mouseShape != nil { count += 1 }
        if presentation.mouseVisibility != nil { count += 1 }
        if presentation.searchUpdate != nil { count += 1 }
        if activity != nil { count += 1 }
        if titleMetadata != nil {
            count += 1
            if titleMetadata?.surfaceTitle != nil { count += 1 }
        }
        return count
    }
}

enum TerminalLocalAccumulatorOfferResult: Sendable, Equatable {
    case scheduled
    case coalesced
    case equalSuppressed
    case rejectedInactiveSearch
}

enum TerminalLocalAccumulatorDrainCompletion: Sendable, Equatable {
    case idle
    case followUpScheduled
}

enum TerminalLocalActionLane: Hashable, Sendable {
    case immediate
    case title
}

struct TerminalLocalDrainRequest: Equatable, Sendable {
    let lane: TerminalLocalActionLane
    let absoluteDeadlineNanoseconds: UInt64?
}
