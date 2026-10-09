import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

enum GhosttyTranslatedActionAdmission: Sendable, Equatable {
    case routeExactFactOrControl(precedingTitle: TerminalPrecedingTitleBarrier?)
    case updateDirectHostState
    case handledLocally
    case rejectedRetired
}

@MainActor
protocol TerminalLocalActionDrainHost: AnyObject {
    var managedSurfaceID: UUID { get }
    var hostScrollbarState: ScrollbarState? { get }
    var title: String { get }
    var performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? { get }

    func updateHostScrollbarState(_ state: ScrollbarState)
    func titleDidChange(_ title: String)
}

extension Ghostty.SurfaceView: TerminalLocalActionDrainHost {}

@MainActor
struct TerminalLocalActionMountedHostResolver {
    struct MountedHost {
        let host: any TerminalLocalActionDrainHost
        let paneID: UUID
    }

    let surfaceForID: (UUID) -> (any TerminalLocalActionDrainHost)?
    let paneIDForSurfaceID: (UUID) -> UUID?

    func resolve(expectedSurfaceID: UUID) -> MountedHost? {
        guard
            let host = surfaceForID(expectedSurfaceID),
            host.managedSurfaceID == expectedSurfaceID,
            let paneID = paneIDForSurfaceID(expectedSurfaceID)
        else { return nil }
        return MountedHost(host: host, paneID: paneID)
    }

}

extension Ghostty.ActionRouter {
    @MainActor
    static func isCurrentSurfaceLifetime(
        expectedSurfaceID: UUID,
        surfaceViewObjectID: ObjectIdentifier,
        routingLookup: any GhosttyActionRoutingLookup
    ) -> Bool {
        routingLookup.surfaceId(forViewObjectId: surfaceViewObjectID) == expectedSurfaceID
    }

    static func admitTranslatedActionToTerminalRuntime(
        _ event: GhosttyEvent,
        surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator,
        equalSuppressionObserver: (TerminalPerformancePublicationKind) -> Void = { _ in }
    ) -> GhosttyTranslatedActionAdmission {
        switch GhosttyActionDisposition.classify(event) {
        case .exactFactOrControl:
            if case .cwdChanged(let cwdPath) = event {
                let cwdAdmission = accumulator.admitCWDPublication(cwdPath, for: surfaceID)
                if cwdAdmission == .retired { return .rejectedRetired }
                if cwdAdmission == .equalSuppressed {
                    equalSuppressionObserver(.cwd)
                    return .handledLocally
                }
            }
            return .routeExactFactOrControl(precedingTitle: accumulator.detachTitleBeforeExactBarrier(for: surfaceID))
        case .latestPresentation(let presentation):
            let result = offerLocalPresentation(presentation, for: surfaceID, accumulator: accumulator)
            return result == .retired ? .rejectedRetired : .handledLocally
        case .latestSemanticMetadata(let metadata):
            let result = offerLatestSemanticMetadata(metadata, for: surfaceID, accumulator: accumulator)
            if result == .equalSuppressed { equalSuppressionObserver(.title) }
            return result == .retired ? .rejectedRetired : .handledLocally
        case .activityEvidence(let evidence):
            let result = offerLocalActivityEvidence(evidence, for: surfaceID, accumulator: accumulator)
            if result == .equalSuppressed { equalSuppressionObserver(.activity) }
            return result == .retired ? .rejectedRetired : .handledLocally
        case .exactLocalLifecycle(let lifecycle):
            let result = offerLocalLifecycle(lifecycle, for: surfaceID, accumulator: accumulator)
            return result == .retired ? .rejectedRetired : .handledLocally
        case .diagnostic(.directHostState):
            return .updateDirectHostState
        case .diagnostic(.localOnly), .diagnostic(.deferred), .diagnostic(.unhandled):
            return .handledLocally
        }
    }

    static func shouldSubmitSurfaceClose(
        currentPaneID: UUID?,
        closingPaneID: UUID
    ) -> Bool {
        currentPaneID != closingPaneID
    }

    static func offerLocalPresentation(
        _ presentation: TerminalLocalPresentationAction,
        for surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator
    ) -> TerminalLocalAccumulatorOfferResult {
        switch presentation {
        case .mouseShape(let shape):
            return accumulator.offer(.mouseShape(shape), for: surfaceID)
        case .mouseVisibility(let isVisible):
            return accumulator.offer(.mouseVisibility(isVisible), for: surfaceID)
        case .searchMatches(let totalMatches):
            return accumulator.offer(.searchMatches(totalMatches), for: surfaceID)
        case .searchSelection(let selectedMatchIndex):
            return accumulator.offer(.searchSelection(selectedMatchIndex), for: surfaceID)
        }
    }

    static func offerLocalActivityEvidence(
        _ evidence: TerminalLocalActivityEvidence,
        for surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator
    ) -> TerminalLocalAccumulatorOfferResult {
        switch evidence {
        case .scrollbar(let state):
            return accumulator.offer(
                .scrollbar(
                    state,
                    observedAtMilliseconds: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
                ),
                for: surfaceID
            )
        }
    }

    static func offerLatestSemanticMetadata(
        _ metadata: TerminalLatestSemanticMetadataAction,
        for surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator
    ) -> TerminalLocalAccumulatorOfferResult {
        switch metadata {
        case .titleChanged(let title):
            return accumulator.offer(.titleChanged(title), for: surfaceID)
        case .tabTitleChanged(let title):
            return accumulator.offer(.tabTitleChanged(title), for: surfaceID)
        }
    }

    static func offerLocalLifecycle(
        _ lifecycle: TerminalLocalLifecycleAction,
        for surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator
    ) -> TerminalLocalAccumulatorOfferResult {
        switch lifecycle {
        case .searchStarted(let query):
            return accumulator.offer(.searchStarted(query: query), for: surfaceID)
        case .searchEnded:
            return accumulator.offer(.searchEnded, for: surfaceID)
        }
    }

    static func terminalAccumulatorDrainPerformanceSnapshot(
        for batch: TerminalLocalActionBatch,
        drainClass: TerminalAccumulatorDrainClass
    ) -> TerminalAccumulatorDrainPerformanceSnapshot {
        TerminalAccumulatorDrainPerformanceSnapshot(
            drainClass: drainClass,
            offeredCount: batch.metrics.offeredCount,
            replacedCount: batch.metrics.replacedCount,
            equalSuppressedCount: batch.metrics.equalSuppressedCount,
            scheduledDrainCount: batch.metrics.scheduledDrainCount,
            followUpDrainCount: batch.metrics.followUpDrainCount,
            mainActorTaskCount: 1,
            activityAggregateCount: batch.activity == nil ? 0 : 1,
            outputAdvancementCount: batch.metrics.outputAdvancementCount,
            retainedEntryCount: UInt64(batch.retainedEntryCount),
            retainedSizeBytes: UInt64(batch.retainedEntryCount * 64)
        )
    }

    static func terminalAccumulatorDrainClass(
        for batch: TerminalLocalActionBatch
    ) -> TerminalAccumulatorDrainClass {
        let containsImmediateWork =
            batch.presentation.scrollbarState != nil
            || batch.presentation.mouseShape != nil
            || batch.presentation.mouseVisibility != nil
            || batch.presentation.searchUpdate != nil
            || batch.activity != nil
            || batch.searchLifecycle != nil
        return containsImmediateWork ? .immediate : .titleDeadline
    }

    static func terminalAccumulatorDrainPerformanceSnapshot(
        for barrier: TerminalPrecedingTitleBarrier
    ) -> TerminalAccumulatorDrainPerformanceSnapshot {
        let retainedEntryCount = barrier.metadata.surfaceTitle == nil ? 1 : 2
        return TerminalAccumulatorDrainPerformanceSnapshot(
            drainClass: .exactBarrier,
            offeredCount: barrier.metrics.offeredCount,
            replacedCount: barrier.metrics.replacedCount,
            equalSuppressedCount: barrier.metrics.equalSuppressedCount,
            scheduledDrainCount: barrier.metrics.scheduledDrainCount,
            followUpDrainCount: barrier.metrics.followUpDrainCount,
            mainActorTaskCount: 0,
            activityAggregateCount: 0,
            outputAdvancementCount: 0,
            retainedEntryCount: UInt64(retainedEntryCount),
            retainedSizeBytes: UInt64(retainedEntryCount * 64)
        )
    }

    static func terminalAccumulatorQueueAge(
        firstOfferedAtNanoseconds: UInt64,
        currentUptimeNanoseconds: UInt64
    ) -> Duration {
        let queueAgeNanoseconds =
            currentUptimeNanoseconds >= firstOfferedAtNanoseconds
            ? currentUptimeNanoseconds - firstOfferedAtNanoseconds
            : 0
        return .nanoseconds(Int64(clamping: queueAgeNanoseconds))
    }

}
