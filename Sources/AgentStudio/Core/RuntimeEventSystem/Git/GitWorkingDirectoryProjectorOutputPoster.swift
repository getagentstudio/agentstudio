/// The projector's output handoff; input subscription stays on its runtime bus.
package protocol RuntimeEnvelopePosting: Sendable {
    func post(_ envelope: RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult
}

extension EventBus: RuntimeEnvelopePosting where Envelope == RuntimeEnvelope {}
