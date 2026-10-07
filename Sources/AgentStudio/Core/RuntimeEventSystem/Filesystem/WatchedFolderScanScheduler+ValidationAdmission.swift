import AgentStudioInfrastructure
import Foundation

extension WatchedFolderScanScheduler {
    func submitValidationRequest(_ awaiting: AwaitingValidation) async {
        let requestID = awaiting.executorRequest.requestID
        let sourceID = awaiting.logicalScan.request.sourceID
        guard let state = stateBySourceID[sourceID],
            awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
        else { return }
        parkedValidationByRequestID.removeValue(forKey: requestID)
        guard !isShuttingDown else {
            consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
            return
        }
        precondition(validationAdmissionsByRequestID[requestID] == nil, "validation admission must have one owner")
        let task = Task { await settleValidationAdmission(awaiting) }
        validationAdmissionsByRequestID[requestID] = InFlightValidationAdmission(
            scope: awaiting.validationScope, task: task, disposition: .submitting
        )
        await task.value
    }

    private func settleValidationAdmission(_ awaiting: AwaitingValidation) async {
        let requestID = awaiting.executorRequest.requestID
        defer {
            validationAdmissionsByRequestID.removeValue(forKey: requestID)
            finalizeShutdownIfDrained()
        }
        let admission = await validationAdmissionSubmitter(awaiting.executorRequest)
        let sourceID = awaiting.logicalScan.request.sourceID
        guard let state = stateBySourceID[sourceID],
            awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
        else {
            if case .accepted = admission {
                _ = await validationExecutor.cancel(requestID: requestID)
            }
            return
        }
        let cancellationRequested =
            validationAdmissionsByRequestID[requestID]?.disposition == .cancellationRequested
        guard !cancellationRequested, !isShuttingDown,
            currentRootBySourceID[sourceID] == awaiting.executorRequest.authorizedRoot
        else {
            switch admission {
            case .accepted:
                // Retain source custody until the executor delivers the correlated
                // completion, which retires its outstanding source before dispatch.
                _ = awaiting.logicalScan.session.cancel()
                _ = await validationExecutor.cancel(requestID: requestID)
            case .rejected:
                // Rejected admission owns no executor request, so synthetic cancellation is safe.
                consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
            }
            return
        }

        switch admission {
        case .accepted:
            return
        case .rejected(.logicalCapacityReached):
            consumeSyntheticValidationOutcome(
                .failure(.serviceFailed(detail: "validation logical capacity reached")),
                awaiting: awaiting
            )
        case .rejected(.allPhysicalJobsDraining):
            parkValidationRequest(awaiting)
        case .rejected(.shutdown):
            consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
        case .rejected(.duplicateRequest),
            .rejected(.scannerSessionAlreadyOutstanding),
            .rejected(.sourceAlreadyOutstanding):
            rejectCorrelatedValidationCustody(awaiting)
        }
    }
}
