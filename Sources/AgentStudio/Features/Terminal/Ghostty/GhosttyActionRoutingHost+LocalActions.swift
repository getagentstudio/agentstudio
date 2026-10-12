import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension GhosttyActionRoutingHost {
    func drainLocalActions(
        for surfaceID: UUID,
        lane: TerminalLocalActionLane,
        accumulator: TerminalLocalActionAccumulator
    ) async {
        guard
            let mountedHost = mountedHostResolver.resolve(
                expectedSurfaceID: surfaceID
            )
        else {
            accumulator.removeSurface(surfaceID)
            return
        }
        let surfaceView = mountedHost.host
        let paneUUID = mountedHost.paneID

        guard
            let batch = accumulator.beginDrain(
                for: surfaceID,
                lane: lane,
                defaultActivityContext: lane == .title ? nil : activityContext(paneUUID)
            )
        else { return }
        defer {
            accumulator.restoreUnacknowledgedPublications(from: batch)
            _ = accumulator.finishDrain(for: surfaceID, lane: lane)
        }

        let clock = ContinuousClock()
        let compactApplyStartedAt = clock.now
        if let scrollbarState = batch.presentation.scrollbarState,
            surfaceView.hostScrollbarState != scrollbarState
        {
            surfaceView.updateHostScrollbarState(scrollbarState)
        }

        let paneID = PaneId(existingUUID: paneUUID)
        let runtime = runtimeRegistry.runtime(for: paneID) as? TerminalRuntime

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
                didApplyRuntimeTitle = routeTitleMetadata(
                    runtimeTitle,
                    surfaceViewObjectID: ObjectIdentifier(surfaceView)
                )
            } else {
                didApplyRuntimeTitle = false
            }
            if let titleMetadata = batch.titleMetadata, didApplyRuntimeTitle {
                didChangeTitle = true
                accumulator.acknowledgeSuccessfulTitlePublication(
                    titleMetadata,
                    for: surfaceID
                )
            }
        } else {
            equalWriteSuppressedCount = 0
        }
        let compactApplyServiceTime = compactApplyStartedAt.duration(to: clock.now)
        let activityProjectionRoundTrip = await publishActivityProjectionIfNeeded(
            batch,
            paneUUID: paneUUID,
            viewObjectID: ObjectIdentifier(surfaceView),
            accumulator: accumulator
        )
        guard isCurrentSurfaceLifetime(surfaceID: surfaceID, viewObjectID: ObjectIdentifier(surfaceView)),
            let currentHost = mountedHostResolver.resolve(expectedSurfaceID: surfaceID),
            ObjectIdentifier(currentHost.host) == ObjectIdentifier(surfaceView),
            currentHost.paneID == paneUUID
        else { return }
        surfaceView.performanceTraceRecorder?.recordTerminalCompactApply(
            TerminalCompactApplyPerformanceSnapshot(
                equalWriteSuppressedCount: UInt64(equalWriteSuppressedCount),
                activityProjectionRoundTrip: activityProjectionRoundTrip
            ),
            serviceTime: compactApplyServiceTime
        )
        let currentUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        surfaceView.performanceTraceRecorder?.recordTerminalAccumulatorDrain(
            Ghostty.ActionRouter.terminalAccumulatorDrainPerformanceSnapshot(
                for: batch,
                drainClass: Ghostty.ActionRouter.terminalAccumulatorDrainClass(for: batch)
            ),
            queueAge: Ghostty.ActionRouter.terminalAccumulatorQueueAge(
                firstOfferedAtNanoseconds: batch.firstOfferedAtNanoseconds,
                currentUptimeNanoseconds: currentUptimeNanoseconds
            ),
            applyOutcome: batch.titleMetadata == nil ? nil : (didChangeTitle ? .changed : .equal)
        )
    }

    private func publishActivityProjectionIfNeeded(
        _ batch: TerminalLocalActionBatch,
        paneUUID: UUID,
        viewObjectID: ObjectIdentifier,
        accumulator: TerminalLocalActionAccumulator
    ) async -> TerminalActivityProjectionRoundTripPerformance {
        guard
            let aggregate = batch.activity,
            let latestState = batch.presentation.scrollbarState,
            let context = batch.activityContext,
            !Task.isCancelled
        else { return .notSubmitted }

        let clock = ContinuousClock()
        let projectionStartedAt = clock.now
        await submitActivityInput(
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
        if !Task.isCancelled,
            isCurrentSurfaceLifetime(surfaceID: batch.surfaceID, viewObjectID: viewObjectID),
            routingLookup.paneId(for: batch.surfaceID) == paneUUID
        {
            accumulator.acknowledgeSuccessfulActivityPublication(
                aggregate,
                for: batch.surfaceID
            )
        }
        return .completed(projectionStartedAt.duration(to: clock.now))
    }

}
