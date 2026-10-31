import AgentStudioCore
import Foundation

extension PaneContextPopoverRefreshOwner {
    /// Publishes validation state without installing read authority or completing the read's obligations.
    func publishPendingCard(
        _ identity: PaneContextPopoverRequestIdentity, capture: PopoverSourceCapture,
        shellExecutablePath: String?, clearingService: Bool
    ) async -> Bool {
        let key = identity.key
        let producer = identity.producer
        guard let consumer = consumers[key], identity.validationPhase == .pending else { return false }
        guard case .card = consumer.demand.content else { return true }
        let snapshot = PaneContextPopoverSnapshot(
            identity: identity, demand: consumer.demand, capture: capture,
            state: .ready(.compact),
            wallNow: wallNow(),
            frozenWidth: consumer.frozenWidth
                ?? preferredWidth(
                    for: consumer.demand,
                    state: .unavailable(.databaseUnavailable, retained: nil)),
            shellExecutablePath: shellExecutablePath, liveSession: clearingService ? nil : consumer.liveSession,
            actionFeedback: consumer.actionFeedback)
        let outcome = await consumer.projection.admit(snapshot)
        guard
            isCurrent(
                key, opening: identity.openingEpoch, epoch: identity.serviceEpoch,
                generation: identity.requestGeneration), var latest = consumers[key]
        else { return false }
        observe(producer.scope(for: key), .projected)
        switch outcome {
        case .published:
            latest.acceptedState = snapshot.state
            consumers[key] = latest
            observe(producer.scope(for: key), .published)
            return true
        case .equal:
            latest.acceptedState = snapshot.state
            consumers[key] = latest
            observe(producer.scope(for: key), .equal)
            return true
        case .superseded:
            observe(producer.scope(for: key), .superseded)
            return false
        case .cancelled:
            observe(producer.scope(for: key), .cancelled)
            return false
        }
    }

}
