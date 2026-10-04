import AgentStudioInfrastructure
import Foundation

extension WatchedFolderScanScheduler {
    func retainValidationRequest(
        _ scannerRequest: RepoScannerValidationRequest,
        completion: QuantumCompletion,
        running: RunningQuantum,
        state: RootSchedulingState
    ) async {
        let authorizedScanRootPath = running.request.canonicalRoot.aliases.onceResolvedCanonical.path
        let scannerRootPath = scannerRequest.scanRootURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard scannerRequest.scannerSessionID == completion.session.id,
            scannerRootPath == authorizedScanRootPath
        else {
            _ = completion.session.cancel()
            recordStaleScanRunDrop(sourceID: completion.sourceID)
            preserveDirtyAfterStaleCompletion(sourceID: completion.sourceID, state: state)
            _ = dispatchReadyQuanta()
            return
        }

        let executorRequest = RepoDiscoveryValidationRequest(
            requestID: RepoDiscoveryValidationRequestID(
                rawValue: scannerRequest.requestID.rawValue
            ),
            scannerSessionID: scannerRequest.scannerSessionID,
            scanRunGeneration: running.scanRunGeneration,
            authorizedRoot: running.request.canonicalRoot,
            candidateURL: scannerRequest.candidateURL
        )
        let awaiting = AwaitingValidation(
            logicalScan: LogicalScan(
                request: running.request,
                scanRunGeneration: running.scanRunGeneration,
                session: completion.session,
                accumulatedQueueWaitDuration: running.accumulatedQueueWaitDuration,
                quantumSelectionCount: running.quantumSelectionCount,
                startedFromDirtyFollowUp: running.startedFromDirtyFollowUp
            ),
            scannerRequest: scannerRequest,
            executorRequest: executorRequest
        )
        switch state {
        case .running:
            stateBySourceID[completion.sourceID] = .awaitingValidation(awaiting)
        case .runningAndDirty(_, let dirty):
            stateBySourceID[completion.sourceID] = .awaitingValidationAndDirty(awaiting, dirty)
        default:
            preconditionFailure("validation request requires a running root state")
        }

        // Validation custody is independent. Release traversal credit and serve another root
        // before crossing into the bounded executor actor.
        _ = dispatchReadyQuanta()
        ensureValidationCompletionDrainStarted()
        await submitValidationRequest(awaiting)
    }

    func ensureValidationCompletionDrainStarted() {
        guard validationCompletionDrainTask == nil else { return }
        validationCompletionDrainTask = Task { await drainValidationCompletions() }
    }

    func cancelAwaitingValidation(_ awaiting: AwaitingValidation) async {
        let requestID = awaiting.executorRequest.requestID
        if validationAdmissionsByRequestID[requestID] != nil {
            validationAdmissionsByRequestID[requestID]?.disposition = .cancellationRequested
            _ = awaiting.logicalScan.session.cancel()
            return
        }
        if parkedValidationByRequestID.removeValue(forKey: awaiting.executorRequest.requestID) != nil {
            consumeSyntheticValidationOutcome(.cancelled, awaiting: awaiting)
            _ = awaiting.logicalScan.session.cancel()
            return
        }
        _ = awaiting.logicalScan.session.cancel()
        _ = await validationExecutor.cancel(requestID: awaiting.executorRequest.requestID)
    }

    private func drainValidationCompletions() async {
        while true {
            switch await validationExecutor.nextCompletion() {
            case .completed(let completion):
                receiveValidationCompletion(completion)
            case .shutdown(.drainingPhysicalJobs):
                await validationExecutor.waitUntilPhysicalJobCount(0)
            case .shutdown(.complete):
                validationCompletionDrainTask = nil
                finalizeShutdownIfDrained()
                return
            case .cancelled:
                if isShuttingDown { continue }
                validationCompletionDrainTask = nil
                return
            case .rejected(.anotherWaiterRegistered):
                preconditionFailure("scheduler must own the sole validation completion waiter")
            }
        }
    }

    func receiveValidationCompletion(
        _ executorCompletion: RepoDiscoveryValidationCompletion
    ) {
        let executorRequest = executorCompletion.schedulerRequest
        let sourceID = executorRequest.authorizedRoot.sourceID
        guard let state = stateBySourceID[sourceID] else {
            recordStaleRegistrationDrop(sourceID: sourceID)
            return
        }
        guard let awaiting = awaitingValidation(from: state) else {
            recordStaleScanRunDrop(sourceID: sourceID)
            return
        }
        guard awaiting.executorRequest.requestID == executorRequest.requestID else {
            recordStaleScanRunDrop(sourceID: sourceID)
            return
        }
        if awaiting.executorRequest == executorRequest {
            let settlement: WatchedFolderScanValidationSettlement
            switch executorCompletion {
            case .finished: settlement = .finished
            case .timedOut: settlement = .timedOut
            case .cancelled: settlement = .cancelled
            }
            factSink?(awaiting.validationScope, .validationSettled(settlement))
        }
        guard awaiting.executorRequest == executorRequest,
            awaiting.scannerRequest.requestID.rawValue == executorRequest.requestID.rawValue,
            awaiting.scannerRequest.scannerSessionID == executorRequest.scannerSessionID,
            awaiting.scannerRequest.candidateURL == executorRequest.candidateURL,
            awaiting.logicalScan.scanRunGeneration == executorRequest.scanRunGeneration,
            scanRunGenerationBySourceID[sourceID] == awaiting.logicalScan.scanRunGeneration
        else {
            rejectCorrelatedValidationCustody(awaiting)
            return
        }
        guard !isShuttingDown else {
            _ = awaiting.logicalScan.session.cancel()
            stateBySourceID.removeValue(forKey: sourceID)
            finalizeShutdownIfDrained()
            return
        }
        guard currentRootBySourceID[sourceID] == executorRequest.authorizedRoot else {
            _ = awaiting.logicalScan.session.cancel()
            preserveDirtyAfterStaleCompletion(sourceID: sourceID, state: state)
            _ = dispatchReadyQuanta()
            finalizeShutdownIfDrained()
            return
        }

        let scannerOutcome: GitRepositoryDiscoveryOutcome
        switch executorCompletion {
        case .finished(let finished):
            scannerOutcome = finished.outcome
        case .timedOut:
            scannerOutcome = .timeout
        case .cancelled:
            scannerOutcome = .cancelled
        }
        consumeExactValidationCompletion(
            RepoScannerValidationCompletion(
                request: awaiting.scannerRequest,
                outcome: scannerOutcome,
                validationServiceDuration: executorCompletion.validationServiceDuration
            ),
            awaiting: awaiting,
            state: state
        )
    }

    func consumeSyntheticValidationOutcome(
        _ outcome: GitRepositoryDiscoveryOutcome,
        awaiting: AwaitingValidation
    ) {
        guard let state = stateBySourceID[awaiting.logicalScan.request.sourceID],
            awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
        else { return }
        consumeExactValidationCompletion(
            RepoScannerValidationCompletion(
                request: awaiting.scannerRequest,
                outcome: outcome,
                validationServiceDuration: .zero
            ),
            awaiting: awaiting,
            state: state
        )
    }

    private func consumeExactValidationCompletion(
        _ completion: RepoScannerValidationCompletion,
        awaiting: AwaitingValidation,
        state: RootSchedulingState
    ) {
        let sourceID = awaiting.logicalScan.request.sourceID
        switch awaiting.logicalScan.session.consumeValidationCompletion(completion) {
        case .consumed:
            guard !isShuttingDown else {
                stateBySourceID.removeValue(forKey: sourceID)
                finalizeShutdownIfDrained()
                return
            }
            let queued = QueuedSuspendedScan(
                logicalScan: awaiting.logicalScan,
                fifoOrdinal: takeFIFOOrdinal(),
                readyAt: now()
            )
            switch state {
            case .awaitingValidation:
                stateBySourceID[sourceID] = .queuedSuspended(queued)
            case .awaitingValidationAndDirty(_, let dirty):
                stateBySourceID[sourceID] = .queuedSuspendedAndDirty(queued, dirty)
            default:
                preconditionFailure("validation completion requires awaiting custody")
            }
            _ = dispatchReadyQuanta()
        case .rejected:
            rejectCorrelatedValidationCustody(awaiting)
        }
    }

    func rejectCorrelatedValidationCustody(_ awaiting: AwaitingValidation) {
        let sourceID = awaiting.logicalScan.request.sourceID
        _ = awaiting.logicalScan.session.cancel()
        guard let state = stateBySourceID[sourceID],
            awaitingValidation(from: state)?.executorRequest == awaiting.executorRequest
        else { return }
        preserveDirtyAfterStaleCompletion(sourceID: sourceID, state: state)
        _ = dispatchReadyQuanta()
        finalizeShutdownIfDrained()
    }

    func awaitingValidation(from state: RootSchedulingState) -> AwaitingValidation? {
        switch state {
        case .awaitingValidation(let awaiting),
            .awaitingValidationAndDirty(let awaiting, _):
            awaiting
        default:
            nil
        }
    }
}

extension RepoDiscoveryValidationCompletion {
    fileprivate var schedulerRequest: RepoDiscoveryValidationRequest {
        switch self {
        case .finished(let finished): finished.request
        case .timedOut(let timedOut): timedOut.request
        case .cancelled(let cancelled): cancelled.request
        }
    }

    fileprivate var validationServiceDuration: Duration {
        switch self {
        case .finished(let finished): finished.validationServiceDuration
        case .timedOut(let timedOut): timedOut.validationServiceDuration
        case .cancelled(let cancelled): cancelled.validationServiceDuration
        }
    }
}
