import Foundation

extension BridgeProductSession {
    func rejectionForUnpreparedRequest(
        _ request: BridgeProductControlRequest
    ) -> BridgeProductSessionControlAdmission {
        if case .workerSessionResync(let resyncRequest) = request,
            lifecycle == .active,
            resyncRequest.lastAcceptedRequestSequence + 1 != request.requestSequence
        {
            return .rejected(
                .init(
                    reason: .sequenceConflict(
                        nextExpectedRequestSequence: controlReplay.snapshot.nextExpectedRequestSequence
                    ),
                    request: request
                )
            )
        }
        guard let surface = request.surface,
            let workerDerivationEpoch = request.workerDerivationEpoch
        else {
            return .rejected(.init(reason: .inactiveSession, request: request))
        }
        let currentEpoch = workerDerivationEpochBySurface[surface, default: 0]
        guard workerDerivationEpoch < currentEpoch else {
            return .rejected(.init(reason: .inactiveSession, request: request))
        }
        return .rejected(
            .init(
                reason: .staleDerivationEpoch(
                    currentWorkerDerivationEpoch: currentEpoch,
                    surface: surface
                ),
                request: request
            )
        )
    }
}
