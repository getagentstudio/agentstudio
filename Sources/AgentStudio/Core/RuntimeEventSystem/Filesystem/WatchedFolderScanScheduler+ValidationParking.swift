import AgentStudioInfrastructure
import Foundation

extension WatchedFolderScanScheduler {
    func parkValidationRequest(_ awaiting: AwaitingValidation) {
        let sourceID = awaiting.logicalScan.request.sourceID
        guard let state = stateBySourceID[sourceID],
            awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
        else { return }
        guard !isShuttingDown,
            currentRootBySourceID[sourceID] == awaiting.executorRequest.authorizedRoot
        else {
            consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
            return
        }

        parkedValidationByRequestID[awaiting.executorRequest.requestID] = awaiting
        factSink?(awaiting.validationScope, .validationParked)
        ensureValidationPhysicalDrainStarted()
    }

    private func ensureValidationPhysicalDrainStarted() {
        guard validationPhysicalDrainTask == nil, !parkedValidationByRequestID.isEmpty else { return }
        validationPhysicalDrainTask = Task {
            await validationExecutor.waitUntilPhysicalJobSlotAvailable()
            await resubmitParkedValidations()
        }
    }

    private func resubmitParkedValidations() async {
        let parkedValidations = Array(parkedValidationByRequestID.values)
        for awaiting in parkedValidations {
            let requestID = awaiting.executorRequest.requestID
            guard parkedValidationByRequestID[requestID] != nil else { continue }
            let sourceID = awaiting.logicalScan.request.sourceID
            guard let state = stateBySourceID[sourceID],
                awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
            else {
                parkedValidationByRequestID.removeValue(forKey: requestID)
                continue
            }
            guard !isShuttingDown,
                currentRootBySourceID[sourceID] == awaiting.executorRequest.authorizedRoot
            else {
                parkedValidationByRequestID.removeValue(forKey: requestID)
                consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
                continue
            }

            // Submission claims parked-only custody before crossing into executor admission.
            factSink?(awaiting.validationScope, .validationResubmitted)
            await submitValidationRequest(awaiting)
        }
        validationPhysicalDrainTask = nil
        ensureValidationPhysicalDrainStarted()
        finalizeShutdownIfDrained()
    }
}

extension WatchedFolderScanScheduler.AwaitingValidation {
    var validationScope: WatchedFolderScanValidationScope {
        WatchedFolderScanValidationScope(
            registration: executorRequest.authorizedRoot.registration,
            scanRunGeneration: executorRequest.scanRunGeneration,
            requestID: executorRequest.requestID
        )
    }
}
