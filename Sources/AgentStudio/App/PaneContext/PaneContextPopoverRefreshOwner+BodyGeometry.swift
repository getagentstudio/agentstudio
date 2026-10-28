import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

extension PaneContextPopoverRefreshOwner {
    /// A layout input never schedules a service read or a refresh deadline.
    func receiveBodyGeometry(
        _ capture: PaneContextPopoverBodyGeometryCapture, row: MessageRowModel.Key,
        for key: PaneContextPopoverConsumerKey, opening: UInt64, operation: UUID
    ) async {
        defer { observe(.input(operation), .inputFinished) }
        guard !stopping, !Task.isCancelled, var consumer = consumers[key], consumer.opening == opening else {
            observe(.input(operation), .cancelled)
            return
        }
        let geometry = capture.geometry
        guard geometry.effectiveWidth.isFinite, geometry.effectiveWidth > 0 else {
            observe(.input(operation), .coalesced)
            return
        }
        guard capture.sequence > consumer.bodyGeometrySequences[row, default: 0] else {
            observe(.input(operation), .superseded)
            return
        }
        // Even an equal newest value fences an older differing capture still in flight.
        consumer.bodyGeometrySequences[row] = capture.sequence
        guard consumer.bodyGeometry[row] != geometry else {
            consumers[key] = consumer
            observe(.input(operation), .coalesced)
            return
        }
        consumer.bodyGeometry[row] = geometry
        consumer.layoutGeneration &+= 1
        consumer.projection.invalidate()
        consumers[key] = consumer
        observe(.input(operation), .observed)
        // An in-flight canonical projection retries with this latest complete geometry.
        guard consumer.execution == nil, consumer.inputOperation == nil,
            consumer.acceptedRequestGeneration == consumer.requestGeneration,
            let state = consumer.acceptedState, let capture = consumer.capture
        else { return }
        consumer.layoutOperation = operation
        consumers[key] = consumer
        let identity = PaneContextPopoverRequestIdentity(
            key: key, openingEpoch: opening, serviceEpoch: serviceEpoch,
            requestGeneration: consumer.requestGeneration, inputGeneration: consumer.inputGeneration,
            ageGeneration: consumer.ageGeneration, pageGeneration: consumer.pageGeneration,
            producer: .input(operation))
        let snapshot = PaneContextPopoverSnapshot(
            identity: identity, demand: consumer.demand, capture: capture, state: state,
            wallNow: wallNow(), frozenWidth: consumer.frozenWidth,
            shellExecutablePath: consumer.shellExecutablePath, liveSession: consumer.liveSession,
            actionFeedback: consumer.actionFeedback)
        let outcome = await projectWithCurrentGeometry(snapshot, layoutOperation: operation)
        if consumers[key]?.layoutOperation == operation { consumers[key]?.layoutOperation = nil }
        switch outcome {
        case .published: observe(.input(operation), .published)
        case .equal: observe(.input(operation), .equal)
        case .superseded: observe(.input(operation), .superseded)
        case .cancelled: observe(.input(operation), .cancelled)
        }
    }

    /// Each retry joins a completed projection and requires a distinct geometry revision.
    func projectWithCurrentGeometry(
        _ base: PaneContextPopoverSnapshot, layoutOperation: UUID? = nil
    ) async -> PaneContextPopoverProjectionOutcome {
        let identity = base.identity
        var joined = Set<UInt64>()
        while isCurrent(
            identity.key, opening: identity.openingEpoch, epoch: identity.serviceEpoch,
            generation: identity.requestGeneration), let consumer = consumers[identity.key]
        {
            guard layoutOperation == nil || consumer.layoutOperation == layoutOperation else { return .superseded }
            guard joined.insert(consumer.layoutGeneration).inserted else { return .superseded }
            let nextIdentity = PaneContextPopoverRequestIdentity(
                key: identity.key, openingEpoch: identity.openingEpoch, serviceEpoch: identity.serviceEpoch,
                requestGeneration: identity.requestGeneration, inputGeneration: identity.inputGeneration,
                ageGeneration: identity.ageGeneration, pageGeneration: identity.pageGeneration,
                producer: identity.producer, validationPhase: identity.validationPhase,
                layoutGeneration: consumer.layoutGeneration)
            let snapshot = PaneContextPopoverSnapshot(
                identity: nextIdentity, demand: base.demand, capture: base.capture, state: base.state,
                wallNow: base.wallNow, frozenWidth: base.frozenWidth, shellExecutablePath: base.shellExecutablePath,
                liveSession: base.liveSession, actionFeedback: base.actionFeedback, bodyGeometry: consumer.bodyGeometry)
            let outcome = await consumer.projection.admit(snapshot)
            guard
                isCurrent(
                    identity.key, opening: identity.openingEpoch, epoch: identity.serviceEpoch,
                    generation: identity.requestGeneration)
            else { return .superseded }
            if consumers[identity.key]?.layoutGeneration != nextIdentity.layoutGeneration { continue }
            return outcome
        }
        return .cancelled
    }
}
