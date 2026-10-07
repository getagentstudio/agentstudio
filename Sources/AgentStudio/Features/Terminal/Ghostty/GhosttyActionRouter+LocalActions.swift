import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

enum GhosttyTranslatedActionAdmission: Sendable, Equatable {
    case routeExactFactOrControl(precedingTitle: TerminalPrecedingTitleBarrier?)
    case updateDirectHostState
    case handledLocally
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

    static let surfaceManager = Self(
        surfaceForID: { SurfaceManager.shared.surface(for: $0) },
        paneIDForSurfaceID: { SurfaceManager.shared.paneId(for: $0) }
    )
}

@MainActor
struct TerminalLocalActionDrainDependencies {
    let mountedHostResolver: TerminalLocalActionMountedHostResolver
    let runtimeRegistry: RuntimeRegistry
    let fallbackRuntimeRegistry: RuntimeRegistry?
    let routingLookup: any GhosttyActionRoutingLookup
    let activityContext: @MainActor (UUID) -> TerminalActivityProjectionContext?
    let submitActivityInput: @MainActor (TerminalActivitySourceInput) async -> Void

    init(
        mountedHostResolver: TerminalLocalActionMountedHostResolver,
        runtimeRegistry: RuntimeRegistry,
        fallbackRuntimeRegistry: RuntimeRegistry?,
        routingLookup: any GhosttyActionRoutingLookup = SurfaceManager.shared,
        activityContext: @escaping @MainActor (UUID) -> TerminalActivityProjectionContext?,
        submitActivityInput: @escaping @MainActor (TerminalActivitySourceInput) async -> Void
    ) {
        self.mountedHostResolver = mountedHostResolver
        self.runtimeRegistry = runtimeRegistry
        self.fallbackRuntimeRegistry = fallbackRuntimeRegistry
        self.routingLookup = routingLookup
        self.activityContext = activityContext
        self.submitActivityInput = submitActivityInput
    }

    static var live: Self {
        let runtimeRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        return Self(
            mountedHostResolver: .surfaceManager,
            runtimeRegistry: runtimeRegistry,
            fallbackRuntimeRegistry: ObjectIdentifier(runtimeRegistry) != ObjectIdentifier(RuntimeRegistry.shared)
                ? RuntimeRegistry.shared
                : nil,
            routingLookup: SurfaceManager.shared,
            activityContext: { Ghostty.ActionRouter.terminalActivityProjectionContext(paneID: $0) },
            submitActivityInput: { await Ghostty.ActionRouter.submitTerminalActivityInput($0) }
        )
    }
}

extension Ghostty.ActionRouter {
    static func admitTranslatedActionToTerminalRuntime(
        _ event: GhosttyEvent,
        surfaceID: UUID,
        accumulator: TerminalLocalActionAccumulator,
        equalSuppressionObserver: (TerminalPerformancePublicationKind) -> Void = { _ in }
    ) -> GhosttyTranslatedActionAdmission {
        switch GhosttyActionDisposition.classify(event) {
        case .exactFactOrControl:
            if case .cwdChanged(let cwdPath) = event,
                accumulator.admitCWDPublication(cwdPath, for: surfaceID) == .equalSuppressed
            {
                equalSuppressionObserver(.cwd)
                return .handledLocally
            }
            return .routeExactFactOrControl(
                precedingTitle: accumulator.detachTitleBeforeExactBarrier(for: surfaceID)
            )
        case .latestPresentation(let presentation):
            offerLocalPresentation(presentation, for: surfaceID, accumulator: accumulator)
            return .handledLocally
        case .latestSemanticMetadata(let metadata):
            if offerLatestSemanticMetadata(metadata, for: surfaceID, accumulator: accumulator)
                == .equalSuppressed
            {
                equalSuppressionObserver(.title)
            }
            return .handledLocally
        case .activityEvidence(let evidence):
            if offerLocalActivityEvidence(evidence, for: surfaceID, accumulator: accumulator)
                == .equalSuppressed
            {
                equalSuppressionObserver(.activity)
            }
            return .handledLocally
        case .exactLocalLifecycle(let lifecycle):
            offerLocalLifecycle(lifecycle, for: surfaceID, accumulator: accumulator)
            return .handledLocally
        case .diagnostic(.directHostState):
            return .updateDirectHostState
        case .diagnostic(.localOnly), .diagnostic(.deferred), .diagnostic(.unhandled):
            return .handledLocally
        }
    }

    static func retireLocalActions(for surfaceID: UUID) {
        localActionDrainScheduler.cancel(for: surfaceID)
        localActionAccumulator.removeSurface(surfaceID)
    }

    @MainActor
    static func applyOrderedActivityControl(
        surfaceID: UUID,
        paneID: UUID,
        control: TerminalActivityOrderedControl,
        contextBeforeControl: TerminalActivityProjectionContext? = nil,
        contextAfterControl: TerminalActivityProjectionContext? = nil,
        accumulator: TerminalLocalActionAccumulator = localActionAccumulator
    ) async {
        let currentContext = terminalActivityProjectionContext(paneID: paneID)
        let precedingAggregate = accumulator.detachActivityBeforeControl(
            for: surfaceID,
            contextBeforeControl: contextBeforeControl ?? currentContext,
            contextAfterControl: contextAfterControl
        )
        await submitTerminalActivityInput(
            .orderedControl(
                surfaceID: surfaceID,
                paneID: paneID,
                precedingAggregate: precedingAggregate,
                control: control
            )
        )
    }

    @MainActor
    static func closeLocalActions(surfaceID: UUID, paneID: UUID) {
        localActionDrainScheduler.cancel(for: surfaceID)
        let precedingAggregate = localActionAccumulator.detachActivityForSurfaceClose(
            surfaceID,
            defaultActivityContext: terminalActivityProjectionContext(paneID: paneID)
        )
        Task { @MainActor in
            guard
                shouldSubmitSurfaceClose(
                    currentPaneID: SurfaceManager.shared.paneId(for: surfaceID),
                    closingPaneID: paneID
                )
            else { return }
            await submitTerminalActivityInput(
                .orderedControl(
                    surfaceID: surfaceID,
                    paneID: paneID,
                    precedingAggregate: precedingAggregate,
                    control: .surfaceClosed
                )
            )
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
    ) {
        switch presentation {
        case .mouseShape(let shape):
            accumulator.offer(.mouseShape(shape), for: surfaceID)
        case .mouseVisibility(let isVisible):
            accumulator.offer(.mouseVisibility(isVisible), for: surfaceID)
        case .searchMatches(let totalMatches):
            accumulator.offer(.searchMatches(totalMatches), for: surfaceID)
        case .searchSelection(let selectedMatchIndex):
            accumulator.offer(.searchSelection(selectedMatchIndex), for: surfaceID)
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
    ) {
        switch lifecycle {
        case .searchStarted(let query):
            accumulator.offer(.searchStarted(query: query), for: surfaceID)
        case .searchEnded:
            accumulator.offer(.searchEnded, for: surfaceID)
        }
    }

    @MainActor
    static func drainLocalActions(for surfaceID: UUID) async {
        await drainLocalActions(
            for: surfaceID,
            lane: .immediate,
            dependencies: .live
        )
    }

    @MainActor
    static func drainLocalActions(
        for surfaceID: UUID,
        lane: TerminalLocalActionLane
    ) async {
        await drainLocalActions(for: surfaceID, lane: lane, dependencies: .live)
    }

    @MainActor
    static func drainLocalActions(
        for surfaceID: UUID,
        lane: TerminalLocalActionLane,
        dependencies: TerminalLocalActionDrainDependencies
    ) async {
        guard
            let mountedHost = dependencies.mountedHostResolver.resolve(
                expectedSurfaceID: surfaceID
            )
        else {
            retireLocalActions(for: surfaceID)
            return
        }
        let surfaceView = mountedHost.host
        let paneUUID = mountedHost.paneID

        guard
            let batch = localActionAccumulator.beginDrain(
                for: surfaceID,
                lane: lane,
                defaultActivityContext: lane == .title ? nil : dependencies.activityContext(paneUUID)
            )
        else { return }
        defer {
            localActionAccumulator.restoreUnacknowledgedPublications(from: batch)
            _ = localActionAccumulator.finishDrain(for: surfaceID, lane: lane)
        }

        let clock = ContinuousClock()
        let compactApplyStartedAt = clock.now
        if let scrollbarState = batch.presentation.scrollbarState,
            surfaceView.hostScrollbarState != scrollbarState
        {
            surfaceView.updateHostScrollbarState(scrollbarState)
        }

        let paneID = PaneId(existingUUID: paneUUID)
        let routedRuntime = dependencies.runtimeRegistry.runtime(for: paneID) as? TerminalRuntime
        let runtime =
            routedRuntime
            ?? dependencies.fallbackRuntimeRegistry?.runtime(for: paneID) as? TerminalRuntime

        var didChangeTitle = false
        let equalWriteSuppressedCount: Int
        if let runtime {
            if let surfaceTitle = batch.titleMetadata?.surfaceTitle,
                surfaceView.title != surfaceTitle
            {
                surfaceView.titleDidChange(surfaceTitle)
                didChangeTitle = true
            }
            equalWriteSuppressedCount = runtime.applyLocalActionBatch(batch)
            let didApplyRuntimeTitle: Bool
            if let runtimeTitle = batch.titleMetadata?.runtimeTitle {
                didApplyRuntimeTitle = routeContractedTitleMetadata(
                    runtimeTitle,
                    surfaceViewObjectID: ObjectIdentifier(surfaceView),
                    routingLookup: dependencies.routingLookup
                )
            } else {
                didApplyRuntimeTitle = false
            }
            if let titleMetadata = batch.titleMetadata, didApplyRuntimeTitle {
                didChangeTitle = true
                localActionAccumulator.acknowledgeSuccessfulTitlePublication(
                    titleMetadata,
                    for: surfaceID
                )
            }
        } else {
            equalWriteSuppressedCount = 0
        }
        let compactApplyServiceTime = compactApplyStartedAt.duration(to: clock.now)
        // SR6b: the restore-phase-ended control (with the aggregate that
        // preceded the person's first input) goes out ahead of whatever
        // activity accumulated after the latch fired — "the pre-input
        // aggregate, the control, then later activity, in that order"
        // (Program Design item 13).
        await submitRestorePhaseEndIfNeeded(batch, surfaceID: surfaceID, paneUUID: paneUUID, dependencies: dependencies)
        let activityProjectionRoundTrip = await publishActivityProjectionIfNeeded(
            batch,
            paneUUID: paneUUID,
            dependencies: dependencies
        )
        surfaceView.performanceTraceRecorder?.recordTerminalCompactApply(
            TerminalCompactApplyPerformanceSnapshot(
                equalWriteSuppressedCount: UInt64(equalWriteSuppressedCount),
                activityProjectionRoundTrip: activityProjectionRoundTrip
            ),
            serviceTime: compactApplyServiceTime
        )
        let currentUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        surfaceView.performanceTraceRecorder?.recordTerminalAccumulatorDrain(
            terminalAccumulatorDrainPerformanceSnapshot(
                for: batch,
                drainClass: terminalAccumulatorDrainClass(for: batch)
            ),
            queueAge: terminalAccumulatorQueueAge(
                firstOfferedAtNanoseconds: batch.firstOfferedAtNanoseconds,
                currentUptimeNanoseconds: currentUptimeNanoseconds
            ),
            applyOutcome: batch.titleMetadata == nil ? nil : (didChangeTitle ? .changed : .equal)
        )
    }

    /// SR6b (Program Design item 13): submits the ordered control the latch
    /// (`TerminalLocalActionAccumulator.markRestorePhaseEnded`) already
    /// detached the preceding aggregate for. Submits `.orderedControl`
    /// directly rather than through `applyOrderedActivityControl`, which
    /// would re-detach and find nothing — the split already happened at the
    /// latch instant, under the same lock, ahead of any later activity this
    /// same batch may also carry.
    @MainActor
    private static func submitRestorePhaseEndIfNeeded(
        _ batch: TerminalLocalActionBatch,
        surfaceID: UUID,
        paneUUID: UUID,
        dependencies: TerminalLocalActionDrainDependencies
    ) async {
        guard let restorePhaseEnd = batch.restorePhaseEnd, !Task.isCancelled else { return }
        await dependencies.submitActivityInput(
            .orderedControl(
                surfaceID: surfaceID,
                paneID: paneUUID,
                precedingAggregate: restorePhaseEnd.precedingAggregate,
                control: .restorePhaseEnded(restorePhaseEnd.generation)
            )
        )
    }

    @MainActor
    private static func publishActivityProjectionIfNeeded(
        _ batch: TerminalLocalActionBatch,
        paneUUID: UUID,
        dependencies: TerminalLocalActionDrainDependencies
    ) async -> TerminalActivityProjectionRoundTripPerformance {
        guard
            let aggregate = batch.activity,
            let latestState = batch.presentation.scrollbarState,
            let context = batch.activityContext,
            !Task.isCancelled
        else { return .notSubmitted }

        let clock = ContinuousClock()
        let projectionStartedAt = clock.now
        await dependencies.submitActivityInput(
            .aggregate(
                surfaceID: batch.surfaceID,
                paneID: paneUUID,
                input: TerminalActivityAggregateInput(
                    aggregate: aggregate,
                    latestState: latestState,
                    context: context
                )
            )
        )
        if !Task.isCancelled {
            localActionAccumulator.acknowledgeSuccessfulActivityPublication(
                aggregate,
                for: batch.surfaceID
            )
        }
        return .completed(projectionStartedAt.duration(to: clock.now))
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

    @MainActor
    @discardableResult
    static func routeContractedTitleMetadata(
        _ metadata: TerminalLatestSemanticMetadataAction,
        surfaceViewObjectID: ObjectIdentifier,
        routingLookup: any GhosttyActionRoutingLookup
    ) -> Bool {
        let actionTag: UInt32
        let payload: GhosttyAdapter.ActionPayload
        switch metadata {
        case .titleChanged(let title):
            actionTag = UInt32(GHOSTTY_ACTION_SET_TITLE.rawValue)
            payload = .titleChanged(title)
        case .tabTitleChanged(let title):
            actionTag = UInt32(GHOSTTY_ACTION_SET_TAB_TITLE.rawValue)
            payload = .tabTitleChanged(title)
        }
        return routeActionToTerminalRuntimeOnMainActor(
            actionTag: actionTag,
            payload: payload,
            surfaceViewObjectId: surfaceViewObjectID,
            routingLookup: routingLookup
        )
    }

    @MainActor
    static func isCurrentSurfaceLifetime(
        expectedSurfaceID: UUID,
        surfaceViewObjectID: ObjectIdentifier,
        routingLookup: any GhosttyActionRoutingLookup
    ) -> Bool {
        routingLookup.surfaceId(forViewObjectId: surfaceViewObjectID) == expectedSurfaceID
    }

    @MainActor
    static func routeExactFactOrControlOnMainActor(
        precedingTitle: TerminalPrecedingTitleBarrier?,
        actionTag: UInt32,
        payload: GhosttyAdapter.ActionPayload,
        surfaceViewObjectID: ObjectIdentifier,
        expectedSurfaceID: UUID,
        routingLookup: any GhosttyActionRoutingLookup,
        accumulator: TerminalLocalActionAccumulator = localActionAccumulator,
        precedingTitleApplyObserver: @MainActor (Bool) -> Void = { _ in }
    ) async -> Bool {
        guard
            isCurrentSurfaceLifetime(
                expectedSurfaceID: expectedSurfaceID,
                surfaceViewObjectID: surfaceViewObjectID,
                routingLookup: routingLookup
            )
        else {
            accumulator.removeSurface(expectedSurfaceID)
            return false
        }
        if let precedingTitle {
            let didApplyPrecedingTitle = routeContractedTitleMetadata(
                precedingTitle.metadata.runtimeTitle,
                surfaceViewObjectID: surfaceViewObjectID,
                routingLookup: routingLookup
            )
            precedingTitleApplyObserver(didApplyPrecedingTitle)
            if didApplyPrecedingTitle {
                accumulator.acknowledgeSuccessfulTitlePublication(
                    precedingTitle.metadata,
                    for: expectedSurfaceID
                )
            }
        }
        if case .commandFinished = payload,
            let paneID = routingLookup.paneId(for: expectedSurfaceID)
        {
            await applyOrderedActivityControl(
                surfaceID: expectedSurfaceID,
                paneID: paneID,
                control: .commandFinished,
                accumulator: accumulator
            )
        }
        let didPublish = routeActionToTerminalRuntimeOnMainActor(
            actionTag: actionTag,
            payload: payload,
            surfaceViewObjectId: surfaceViewObjectID,
            routingLookup: routingLookup
        )
        if case .cwdChanged(let cwdPath) = payload {
            if didPublish {
                accumulator.acknowledgeSuccessfulCWDPublication(cwdPath, for: expectedSurfaceID)
            } else {
                accumulator.recordFailedCWDPublication(cwdPath, for: expectedSurfaceID)
            }
        }
        return didPublish
    }
}
