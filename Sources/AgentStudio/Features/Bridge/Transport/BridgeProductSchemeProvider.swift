protocol BridgeProductSchemeProvider: Sendable {
    var reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource? { get }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async

    nonisolated func makeContentProducerOperation(
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) -> BridgeProductProducerRegistry.ProducerOperation

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool

    func invalidatePendingComparisonTargetReservation() async

    func activateWorkerIdentity(_ workerInstanceId: String) async

    func revokeWorkerIdentity(_ workerInstanceId: String) async

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async

    /// Stops the producers of subscriptions the session ended because their surface
    /// floor advanced. The session already removed their records and deliveries and
    /// queued their `epoch_retired` terminals.
    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission: BridgeProductAdmissionContext
    ) async
}

extension BridgeProductSchemeProvider {
    var reviewIntentAdmissionSource: BridgePaneRefreshWorkAdmissionSource? { nil }

    func invalidatePendingComparisonTargetReservation() async {}

    func activateWorkerIdentity(_ workerInstanceId: String) async {}

    func revokeWorkerIdentity(_ workerInstanceId: String) async {}

    nonisolated func makeContentProducerOperation(
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) -> BridgeProductProducerRegistry.ProducerOperation {
        { lease in
            await self.runContentProducer(
                request: request,
                lease: lease,
                productAdmission: productAdmission,
                session: session
            )
        }
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        _ = (effect, request, productAdmission)
    }

    func retireFloorRetiredSubscriptions(
        _ subscriptions: [BridgeProductSubscriptionSnapshot],
        productAdmission: BridgeProductAdmissionContext
    ) async {
        _ = (subscriptions, productAdmission)
    }
}
