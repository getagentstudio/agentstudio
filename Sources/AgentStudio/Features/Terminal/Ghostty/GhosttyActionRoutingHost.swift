import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// MainActor routing access selected once for one callback handling lifetime.
@MainActor
package final class GhosttyActionRoutingHost {
    struct Dependencies {
        let runtimeRegistry: RuntimeRegistry
        let routingLookup: any GhosttyActionRoutingLookup
        let mountedHostResolver: TerminalLocalActionMountedHostResolver
        let applyNativeView: GhosttyNativeViewApplyOperation
        let activityContext: @MainActor (UUID) -> TerminalActivityProjectionContext?
        let submitActivityInput: @MainActor (TerminalActivitySourceInput) async -> Void
        let startupTraceRecorder: AgentStudioStartupTraceRecorder?
        let traceRuntime: AgentStudioTraceRuntime?
    }

    let runtimeRegistry: RuntimeRegistry
    let routingLookup: any GhosttyActionRoutingLookup
    let mountedHostResolver: TerminalLocalActionMountedHostResolver
    let applyNativeView: GhosttyNativeViewApplyOperation
    let activityContext: @MainActor (UUID) -> TerminalActivityProjectionContext?
    let submitActivityInput: @MainActor (TerminalActivitySourceInput) async -> Void
    let startupTraceRecorder: AgentStudioStartupTraceRecorder?
    nonisolated let actionTraceQueueStore: GhosttyActionTraceQueueStore

    init(dependencies: Dependencies) {
        runtimeRegistry = dependencies.runtimeRegistry
        routingLookup = dependencies.routingLookup
        mountedHostResolver = dependencies.mountedHostResolver
        applyNativeView = dependencies.applyNativeView
        activityContext = dependencies.activityContext
        submitActivityInput = dependencies.submitActivityInput
        startupTraceRecorder = dependencies.startupTraceRecorder
        actionTraceQueueStore = GhosttyActionTraceQueueStore(traceRuntime: dependencies.traceRuntime)
    }

    func isCurrentSurfaceLifetime(surfaceID: UUID, viewObjectID: ObjectIdentifier) -> Bool {
        routingLookup.surfaceId(forViewObjectId: viewObjectID) == surfaceID
    }

    func applyDirectHost(
        surfaceID: UUID,
        viewObjectID: ObjectIdentifier,
        update: GhosttyDirectHostUpdate
    ) async -> GhosttyDeferredApplyResult {
        await applyNativeView(surfaceID, viewObjectID, update)
    }

    func routeActionToTerminalRuntime(
        actionTag: UInt32,
        payload: GhosttyActionPayload,
        surfaceViewObjectID: ObjectIdentifier
    ) -> GhosttyDeferredApplyResult {
        guard let surfaceID = routingLookup.surfaceId(forViewObjectId: surfaceViewObjectID) else {
            traceGhosttyAction(
                body: "ghostty.action.dropped", actionTag: actionTag, payload: payload,
                signalClass: .unhandled, routeResult: false, reason: "surface_not_registered"
            )
            return .dropped(.staleSurface)
        }
        guard let paneUUID = routingLookup.paneId(for: surfaceID) else {
            traceGhosttyAction(
                body: "ghostty.action.dropped", actionTag: actionTag, payload: payload,
                surfaceId: surfaceID, signalClass: .unhandled, routeResult: false, reason: "pane_not_mapped"
            )
            return .dropped(.paneNotMapped)
        }
        guard let runtime = runtimeRegistry.runtime(for: PaneId(existingUUID: paneUUID)) as? TerminalRuntime else {
            traceGhosttyAction(
                body: "ghostty.action.dropped", actionTag: actionTag, payload: payload,
                paneId: paneUUID, surfaceId: surfaceID, signalClass: .unhandled,
                routeResult: false, reason: "runtime_not_found"
            )
            return .dropped(.runtimeNotFound)
        }

        let event = GhosttyActionTranslation.translate(actionTag: actionTag, payload: payload)
        traceGhosttyAction(
            body: "ghostty.action.translated", actionTag: actionTag, payload: payload, event: event,
            paneId: paneUUID, surfaceId: surfaceID,
            signalClass: Ghostty.ActionRouter.signalClass(for: event, fallbackActionTag: actionTag),
            routeResult: true, reason: nil
        )
        traceTerminalStartupMilestones(
            actionTag: actionTag, event: event, paneID: paneUUID, surfaceID: surfaceID
        )
        GhosttyActionTranslation.route(actionTag: actionTag, payload: payload, to: runtime)
        return .applied
    }

    func routeTitleMetadata(
        _ metadata: TerminalLatestSemanticMetadataAction,
        surfaceViewObjectID: ObjectIdentifier
    ) -> Bool {
        let actionTag: UInt32
        let payload: GhosttyActionPayload
        switch metadata {
        case .titleChanged(let title):
            actionTag = GhosttyActionTag.setTitle.rawValue
            payload = .titleChanged(title)
        case .tabTitleChanged(let title):
            actionTag = GhosttyActionTag.setTabTitle.rawValue
            payload = .tabTitleChanged(title)
        }
        return routeActionToTerminalRuntime(
            actionTag: actionTag, payload: payload, surfaceViewObjectID: surfaceViewObjectID
        ) == .applied
    }

    func applyExactFactOrControl(
        precedingTitle: TerminalPrecedingTitleBarrier?,
        actionTag: UInt32,
        payload: GhosttyActionPayload,
        surfaceID: UUID,
        viewObjectID: ObjectIdentifier,
        accumulator: TerminalLocalActionAccumulator
    ) async -> GhosttyDeferredApplyResult {
        guard isCurrentSurfaceLifetime(surfaceID: surfaceID, viewObjectID: viewObjectID) else {
            accumulator.removeSurface(surfaceID)
            return .dropped(.staleSurface)
        }
        let performanceRecorder = mountedHostResolver.surfaceForID(surfaceID).flatMap { host in
            host.managedSurfaceID == surfaceID && ObjectIdentifier(host) == viewObjectID
                ? host.performanceTraceRecorder : nil
        }
        if case .commandFinished = payload {
            performanceRecorder?.recordSidebarPerformanceOrderedCommand()
        }
        var didApplyPrecedingTitle = false
        defer {
            if let precedingTitle {
                performanceRecorder?.recordTerminalAccumulatorDrain(
                    Ghostty.ActionRouter.terminalAccumulatorDrainPerformanceSnapshot(for: precedingTitle),
                    queueAge: Ghostty.ActionRouter.terminalAccumulatorQueueAge(
                        firstOfferedAtNanoseconds: precedingTitle.firstOfferedAtNanoseconds,
                        currentUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
                    ),
                    applyOutcome: didApplyPrecedingTitle ? .changed : .equal
                )
            }
        }
        if let precedingTitle {
            if let surfaceTitle = precedingTitle.metadata.surfaceTitle,
                let mountedHost = mountedHostResolver.resolve(expectedSurfaceID: surfaceID),
                ObjectIdentifier(mountedHost.host) == viewObjectID,
                mountedHost.host.title != surfaceTitle
            {
                mountedHost.host.titleDidChange(surfaceTitle)
            }
            didApplyPrecedingTitle = routeTitleMetadata(
                precedingTitle.metadata.runtimeTitle, surfaceViewObjectID: viewObjectID
            )
            if didApplyPrecedingTitle {
                accumulator.acknowledgeSuccessfulTitlePublication(precedingTitle.metadata, for: surfaceID)
            }
        }
        if case .commandFinished = payload, let paneID = routingLookup.paneId(for: surfaceID) {
            await applyOrderedActivityControl(
                surfaceID: surfaceID, paneID: paneID, control: .commandFinished, accumulator: accumulator
            )
            guard isCurrentSurfaceLifetime(surfaceID: surfaceID, viewObjectID: viewObjectID) else {
                return .dropped(.staleSurface)
            }
        }
        let result = routeActionToTerminalRuntime(
            actionTag: actionTag, payload: payload, surfaceViewObjectID: viewObjectID
        )
        if case .cwdChanged(let cwdPath) = payload {
            if result == .applied {
                accumulator.acknowledgeSuccessfulCWDPublication(cwdPath, for: surfaceID)
            } else {
                accumulator.recordFailedCWDPublication(cwdPath, for: surfaceID)
            }
        }
        return result
    }

    func applyOrderedActivityControl(
        surfaceID: UUID,
        paneID: UUID,
        control: TerminalActivityOrderedControl,
        contextBeforeControl: TerminalActivityProjectionContext? = nil,
        contextAfterControl: TerminalActivityProjectionContext? = nil,
        accumulator: TerminalLocalActionAccumulator
    ) async {
        let currentContext = activityContext(paneID)
        let aggregate = accumulator.detachActivityBeforeControl(
            for: surfaceID,
            contextBeforeControl: contextBeforeControl ?? currentContext,
            contextAfterControl: contextAfterControl
        )
        await submitActivityInput(
            .orderedControl(surfaceID: surfaceID, paneID: paneID, precedingAggregate: aggregate, control: control)
        )
    }

    private func traceTerminalStartupMilestones(
        actionTag: UInt32,
        event: GhosttyEvent,
        paneID: UUID,
        surfaceID: UUID
    ) {
        let actionName = GhosttyActionTag(rawValue: actionTag).map { String(describing: $0) } ?? "\(actionTag)"
        startupTraceRecorder?.recordFirstGhosttyAction(
            paneID: paneID, surfaceID: surfaceID, actionName: actionName
        )
        switch event {
        case .cwdChanged:
            startupTraceRecorder?.recordCwdReady(paneID: paneID, surfaceID: surfaceID)
        case .titleChanged, .tabTitleChanged:
            startupTraceRecorder?.recordTitleReady(paneID: paneID, surfaceID: surfaceID)
        default:
            break
        }
    }
}
