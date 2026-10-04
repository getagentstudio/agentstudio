import AgentStudioInfrastructure
import Foundation

package actor WatchedFolderScanScheduler {
    typealias SessionFactory =
        @Sendable (WatchedFolderScanRequest, UInt64) async -> WatchedFolderScannerSessionPort

    package typealias ValidationAdmissionSubmitter =
        @Sendable (RepoDiscoveryValidationRequest) async -> RepoDiscoveryValidationAdmissionResult

    let validationAdmissionSubmitter: ValidationAdmissionSubmitter
    private let maximumConcurrentScans: Int
    let now: @Sendable () -> Duration
    private let sessionFactory: SessionFactory
    let validationExecutor: RepoScannerValidationExecutor
    let factSink: WatchedFolderScanSchedulerFactSink?

    var currentRootBySourceID: [FilesystemSourceID: RegisteredRootDescriptor] = [:]
    private var retiredRootBySourceID: [FilesystemSourceID: RegisteredRootDescriptor] = [:]
    var stateBySourceID = SchedulingStateStore()
    private var quantumTasksBySourceID: [FilesystemSourceID: Task<Void, Never>] = [:]
    var scanRunGenerationBySourceID: [FilesystemSourceID: UInt64]
    private var demandGenerationBySourceID: [FilesystemSourceID: WatchedFolderScanDemandGeneration]
    private var activeDemandCoverageBySourceID: [FilesystemSourceID: WatchedFolderScanDemandCoverage] = [:]
    private var staleDropsBySourceID: [FilesystemSourceID: StaleDropCounts] = [:]
    private var nextFIFOOrdinal: UInt64 = 0
    private var nextCompletionOrdinal: UInt64 = 0
    private var resultCustodyHighWater = 0
    private var boundResultConsumer: WatchedFolderScanResultConsumerToken?
    private var resultWaiter: ResultWaiter?
    var isShuttingDown = false
    private var isShutDown = false
    var validationCompletionDrainTask: Task<Void, Never>?
    var validationPhysicalDrainTask: Task<Void, Never>?
    var parkedValidationByRequestID: [RepoDiscoveryValidationRequestID: AwaitingValidation] = [:]
    var validationAdmissionsByRequestID: [RepoDiscoveryValidationRequestID: InFlightValidationAdmission] = [:]

    init(
        maximumConcurrentScans: Int,
        initialScanRunGenerations: [FilesystemSourceID: UInt64] = [:],
        initialDemandGenerations: [FilesystemSourceID: WatchedFolderScanDemandGeneration] = [:],
        now: @escaping @Sendable () -> Duration,
        validationExecutor: RepoScannerValidationExecutor,
        factSink: WatchedFolderScanSchedulerFactSink? = nil,
        validationAdmissionSubmitter: ValidationAdmissionSubmitter? = nil,
        sessionFactory: @escaping SessionFactory
    ) throws {
        guard maximumConcurrentScans > 0 else {
            throw WatchedFolderScanSchedulerConfigurationError.invalidMaximumConcurrentScans(
                maximumConcurrentScans
            )
        }
        self.maximumConcurrentScans = maximumConcurrentScans
        self.scanRunGenerationBySourceID = initialScanRunGenerations
        self.demandGenerationBySourceID = initialDemandGenerations
        self.now = now
        self.validationExecutor = validationExecutor
        self.factSink = factSink
        self.validationAdmissionSubmitter =
            validationAdmissionSubmitter ?? { request in
                await validationExecutor.submit(request)
            }
        self.sessionFactory = sessionFactory
    }

    func submit(
        _ request: WatchedFolderScanRequest,
        intent: WatchedFolderScanSubmissionIntent = .untracked
    ) async -> WatchedFolderScanSubmissionResult {
        guard !isShuttingDown, !isShutDown else {
            return .rejected(.schedulerShutDown)
        }
        let previousDemandGeneration =
            demandGenerationBySourceID[request.sourceID]
            ?? WatchedFolderScanDemandGeneration(rawValue: 0)
        let (nextDemandGenerationRawValue, demandGenerationOverflow) =
            previousDemandGeneration.rawValue.addingReportingOverflow(1)
        guard !demandGenerationOverflow else {
            return .rejected(.demandGenerationExhausted(request.sourceID))
        }
        switch admitRegistration(request.canonicalRoot) {
        case .accepted:
            break
        case .rejected(let rejection):
            return .rejected(rejection)
        }

        let nextDemandGeneration = WatchedFolderScanDemandGeneration(
            rawValue: nextDemandGenerationRawValue
        )
        let demandCoverage = WatchedFolderScanDemandCoverage(
            registration: request.canonicalRoot.registration,
            throughDemandGeneration: nextDemandGeneration
        )
        let admittedDemand = PendingDemand(request: request, coverage: demandCoverage)
        demandGenerationBySourceID[request.sourceID] = nextDemandGeneration

        let preliminaryDisposition = await admitDemandIntoSchedulingState(admittedDemand)

        let dispatch = dispatchReadyQuanta()
        if let rejection = dispatch.exhaustedBySourceID[request.sourceID] {
            return .rejected(rejection)
        }
        if dispatch.startedSourceIDs.contains(request.sourceID) {
            return acceptedSubmission(
                intent: intent,
                coverage: demandCoverage,
                disposition: .started
            )
        }
        return acceptedSubmission(
            intent: intent,
            coverage: demandCoverage,
            disposition: preliminaryDisposition
        )
    }

    private func admitDemandIntoSchedulingState(
        _ admittedDemand: PendingDemand
    ) async -> WatchedFolderScanSubmissionDisposition {
        let request = admittedDemand.request
        switch stateBySourceID[request.sourceID] {
        case nil:
            stateBySourceID[request.sourceID] = .queuedNew(makeQueuedNewScan(admittedDemand))
            return .queued
        case .queuedNew(let queued):
            stateBySourceID[request.sourceID] = .queuedNew(
                QueuedNewScan(
                    demand: queued.demand.merged(with: admittedDemand),
                    fifoOrdinal: queued.fifoOrdinal,
                    readyAt: queued.readyAt,
                    startedFromDirtyFollowUp: queued.startedFromDirtyFollowUp
                )
            )
            return .replacedQueued
        case .queuedSuspended(let queued):
            stateBySourceID[request.sourceID] = .queuedSuspendedAndDirty(queued, admittedDemand)
            return .markedRunningDirty
        case .queuedSuspendedAndDirty(let queued, let dirty):
            stateBySourceID[request.sourceID] = .queuedSuspendedAndDirty(
                queued,
                dirty.merged(with: admittedDemand)
            )
            return .markedRunningDirty
        case .running(let running):
            stateBySourceID[request.sourceID] = .runningAndDirty(running, admittedDemand)
            return .markedRunningDirty
        case .runningAndDirty(let running, let dirty):
            stateBySourceID[request.sourceID] = .runningAndDirty(
                running,
                dirty.merged(with: admittedDemand)
            )
            return .markedRunningDirty
        case .awaitingValidation(let awaiting):
            stateBySourceID[request.sourceID] = .awaitingValidationAndDirty(
                awaiting,
                admittedDemand
            )
            if awaiting.logicalScan.request.canonicalRoot.registration
                != request.canonicalRoot.registration
            {
                await cancelAwaitingValidation(awaiting)
            }
            return .markedRunningDirty
        case .awaitingValidationAndDirty(let awaiting, let dirty):
            stateBySourceID[request.sourceID] = .awaitingValidationAndDirty(
                awaiting,
                dirty.merged(with: admittedDemand)
            )
            if awaiting.logicalScan.request.canonicalRoot.registration
                != request.canonicalRoot.registration
            {
                await cancelAwaitingValidation(awaiting)
            }
            return .markedRunningDirty
        case .pendingResult(let pending):
            stateBySourceID[request.sourceID] = .pendingResultAndDirty(pending, admittedDemand)
            return .markedResultDirty
        case .pendingResultAndDirty(let pending, let dirty):
            stateBySourceID[request.sourceID] = .pendingResultAndDirty(
                pending,
                dirty.merged(with: admittedDemand)
            )
            return .markedResultDirty
        case .leasedResult(let leased):
            stateBySourceID[request.sourceID] = .leasedResultAndDirty(leased, admittedDemand)
            return .markedResultDirty
        case .leasedResultAndDirty(let leased, let dirty):
            stateBySourceID[request.sourceID] = .leasedResultAndDirty(
                leased,
                dirty.merged(with: admittedDemand)
            )
            return .markedResultDirty
        }
    }

    private func acceptedSubmission(
        intent: WatchedFolderScanSubmissionIntent,
        coverage: WatchedFolderScanDemandCoverage,
        disposition: WatchedFolderScanSubmissionDisposition
    ) -> WatchedFolderScanSubmissionResult {
        switch intent {
        case .tracked:
            return .accepted(
                .tracked(
                    receipt: WatchedFolderScanDemandReceipt(
                        id: .make(),
                        registration: coverage.registration,
                        demandGeneration: coverage.throughDemandGeneration
                    ),
                    disposition: disposition
                )
            )
        case .untracked:
            return .accepted(.untracked(coverage: coverage, disposition: disposition))
        }
    }
}

extension WatchedFolderScanScheduler {
    func bindResultConsumer(
        _ consumer: WatchedFolderScanResultConsumerToken
    ) -> WatchedFolderScanResultConsumerBinding {
        guard !isShutDown else { return .rejected(.schedulerShutDown) }
        guard let boundResultConsumer else {
            self.boundResultConsumer = consumer
            return .bound
        }
        return boundResultConsumer == consumer ? .alreadyBound : .rejected(.anotherConsumerBound)
    }

    func unbindResultConsumer(
        _ consumer: WatchedFolderScanResultConsumerToken
    ) -> WatchedFolderScanResultConsumerUnbindResult {
        guard let boundResultConsumer else { return .alreadyUnbound }
        guard boundResultConsumer == consumer else { return .rejected(.consumerMismatch) }
        if let leased = currentLeasedResult() {
            return .rejected(.leaseOutstanding(leased.leaseID))
        }
        self.boundResultConsumer = nil
        if let waiter = resultWaiter {
            resultWaiter = nil
            waiter.continuation.resume(returning: .consumerUnbound)
        }
        return .unbound
    }

    func nextResultLease(
        for consumer: WatchedFolderScanResultConsumerToken
    ) async -> WatchedFolderScanResultLeaseWaitResult {
        guard boundResultConsumer == consumer else { return .rejected(.consumerMismatch) }
        if let leased = currentLeasedResult() {
            return .rejected(.leaseAlreadyOutstanding(leased.leaseID))
        }
        if let lease = leaseOldestPendingResult() { return .leased(lease) }
        if isShutDown { return .schedulerShutDown }
        guard resultWaiter == nil else { return .rejected(.waiterAlreadyRegistered) }

        let waiterID = UUIDv7.generate()
        let scheduler = self
        let wake: ResultWaiterWake = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    resultWaiter = ResultWaiter(
                        waiterID: waiterID,
                        consumer: consumer,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await scheduler.cancelResultWaiter(waiterID) }
        }
        switch wake {
        case .resultAvailable:
            guard boundResultConsumer == consumer else { return .consumerUnbound }
            if let lease = leaseOldestPendingResult() { return .leased(lease) }
            return isShutDown ? .schedulerShutDown : .cancelled
        case .cancelled:
            return .cancelled
        case .consumerUnbound:
            return .consumerUnbound
        case .schedulerShutDown:
            return .schedulerShutDown
        }
    }

    func resolveResultLease(
        for consumer: WatchedFolderScanResultConsumerToken,
        leaseID: WatchedFolderScanResultLeaseID,
        resolution: WatchedFolderScanResultLeaseResolution
    ) -> WatchedFolderScanResultLeaseResolutionResult {
        guard boundResultConsumer == consumer else { return .rejected(.consumerMismatch) }
        guard let located = locateLeasedResult() else { return .rejected(.noLeaseOutstanding) }
        guard located.leased.leaseID == leaseID else {
            return .rejected(
                .leaseMismatch(submitted: leaseID, current: located.leased.leaseID)
            )
        }

        let currentRegistration = currentRootBySourceID[located.sourceID]?.registration
        let resultRegistration = located.leased.pending.result.request.canonicalRoot.registration
        let resultIsCurrent = currentRegistration == resultRegistration
        switch resolution {
        case .retry where resultIsCurrent:
            restorePendingResult(located)
            signalResultAvailability()
            return .queuedForRetry
        case .retry:
            recordStaleRegistrationDrop(sourceID: located.sourceID)
            finishTransferredResult(located)
            return .staleResultDiscarded
        case .transferred where resultIsCurrent:
            finishTransferredResult(located)
            return .transferred
        case .transferred:
            recordStaleRegistrationDrop(sourceID: located.sourceID)
            finishTransferredResult(located)
            return .staleResultDiscarded
        }
    }

    func retireRegistration(
        _ registeredRoot: RegisteredRootDescriptor
    ) async -> WatchedFolderScanRetirementResult {
        guard !isShuttingDown, !isShutDown else { return .rejected(.schedulerShutDown) }
        let sourceID = registeredRoot.sourceID
        guard let currentRoot = currentRootBySourceID[sourceID] else {
            if retiredRootBySourceID[sourceID] == registeredRoot {
                return .retired(.alreadyRetired)
            }
            return .rejected(.sourceNotRegistered(sourceID))
        }
        guard currentRoot.registration == registeredRoot.registration else {
            return .rejected(
                .registrationMismatch(
                    submitted: registeredRoot.registration,
                    current: currentRoot.registration
                )
            )
        }
        guard currentRoot == registeredRoot else {
            return .rejected(.registrationDescriptorMismatch(registeredRoot.registration))
        }
        currentRootBySourceID.removeValue(forKey: sourceID)
        retiredRootBySourceID[sourceID] = registeredRoot

        switch stateBySourceID[sourceID] {
        case nil:
            return .retired(.idle)
        case .queuedNew:
            stateBySourceID.removeValue(forKey: sourceID)
            return .retired(.queuedRemoved)
        case .queuedSuspended(let queued):
            _ = queued.logicalScan.session.cancel()
            stateBySourceID.removeValue(forKey: sourceID)
            return .retired(.queuedRemoved)
        case .queuedSuspendedAndDirty(let queued, _):
            _ = queued.logicalScan.session.cancel()
            stateBySourceID.removeValue(forKey: sourceID)
            return .retired(.queuedRemoved)
        case .running(let running):
            cancelRunningQuantum(sourceID: sourceID, running: running)
            return .retired(.runningInvalidated)
        case .runningAndDirty(let running, _):
            stateBySourceID[sourceID] = .running(running)
            cancelRunningQuantum(sourceID: sourceID, running: running)
            return .retired(.runningInvalidatedAndDirtyDiscarded)
        case .awaitingValidation(let awaiting):
            await cancelAwaitingValidation(awaiting)
            return .retired(.awaitingValidationInvalidated)
        case .awaitingValidationAndDirty(let awaiting, _):
            stateBySourceID[sourceID] = .awaitingValidation(awaiting)
            await cancelAwaitingValidation(awaiting)
            return .retired(.awaitingValidationInvalidatedAndDirtyDiscarded)
        case .pendingResult:
            stateBySourceID.removeValue(forKey: sourceID)
            _ = dispatchReadyQuanta()
            return .retired(.pendingResultDiscarded)
        case .pendingResultAndDirty:
            stateBySourceID.removeValue(forKey: sourceID)
            _ = dispatchReadyQuanta()
            return .retired(.pendingResultAndDirtyDiscarded)
        case .leasedResult:
            return .retired(.leasedResultInvalidated)
        case .leasedResultAndDirty(let leased, _):
            stateBySourceID[sourceID] = .leasedResult(leased)
            return .retired(.leasedResultInvalidatedAndDirtyDiscarded)
        }
    }

    func stateSnapshot() -> WatchedFolderScanSchedulerStateSnapshot {
        if isShutDown { return .shutDown }
        let counts = stateCounts
        if isShuttingDown {
            return .shuttingDown(
                WatchedFolderScanSchedulerCustodyState(
                    activeQuanta: counts.active,
                    awaitingValidations: counts.awaitingValidation,
                    pendingResults: counts.pending,
                    leasedResults: counts.leased
                )
            )
        }
        return .active(
            WatchedFolderScanSchedulerActiveState(
                ready: counts.ready,
                activeQuanta: counts.active,
                awaitingValidations: counts.awaitingValidation,
                pendingResults: counts.pending,
                leasedResults: counts.leased,
                dirtyFollowUps: counts.dirtyFollowUps,
                resultCustodyHighWater: resultCustodyHighWater
            )
        )
    }

    func readySelectionInspection() -> ReadySelectionInspection {
        ReadySelectionInspection(
            selectionCount: stateBySourceID.readySelectionCount,
            workUnitCount: stateBySourceID.readySelectionWorkUnitCount,
            readyRootCount: stateBySourceID.counts.ready,
            scheduledRootCount: stateBySourceID.scheduledRootCount
        )
    }

    func replaceSchedulingState(
        for sourceID: FilesystemSourceID,
        with replacement: RootSchedulingState
    ) {
        stateBySourceID[sourceID] = replacement
    }

    @discardableResult
    func removeSchedulingState(for sourceID: FilesystemSourceID) -> RootSchedulingState? {
        stateBySourceID.removeValue(forKey: sourceID)
    }

    func shutdown() async {
        guard !isShutDown, !isShuttingDown else { return }
        isShuttingDown = true
        ensureValidationCompletionDrainStarted()
        _ = await validationExecutor.beginShutdown()
        for (sourceID, state) in stateBySourceID {
            switch state {
            case .queuedNew:
                stateBySourceID.removeValue(forKey: sourceID)
            case .queuedSuspended(let queued), .queuedSuspendedAndDirty(let queued, _):
                _ = queued.logicalScan.session.cancel()
                stateBySourceID.removeValue(forKey: sourceID)
            case .running(let running):
                cancelRunningQuantum(sourceID: sourceID, running: running)
            case .runningAndDirty(let running, _):
                stateBySourceID[sourceID] = .running(running)
                cancelRunningQuantum(sourceID: sourceID, running: running)
            case .awaitingValidation(let awaiting),
                .awaitingValidationAndDirty(let awaiting, _):
                await cancelAwaitingValidation(awaiting)
            case .pendingResult:
                break
            case .pendingResultAndDirty(let pending, _):
                stateBySourceID[sourceID] = .pendingResult(pending)
            case .leasedResult:
                break
            case .leasedResultAndDirty(let leased, _):
                stateBySourceID[sourceID] = .leasedResult(leased)
            }
        }
        let tasks = Array(quantumTasksBySourceID.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        let admissions = Array(validationAdmissionsByRequestID.values)
        for admission in admissions {
            // Traversal cancellation/join is complete before admission settlement resumes.
            factSink?(admission.scope, .shutdownAwaitingAdmission)
            await admission.task.value
        }
        if let validationCompletionDrainTask {
            await validationCompletionDrainTask.value
        }
        if let validationPhysicalDrainTask {
            await validationPhysicalDrainTask.value
        }
        finalizeShutdownIfDrained()
    }

    func receiveQuantumCompletion(_ completion: QuantumCompletion) async {
        guard let state = stateBySourceID[completion.sourceID],
            let running = runningQuantum(from: state),
            running.executionID == completion.executionID,
            running.scanRunGeneration == completion.scanRunGeneration
        else {
            _ = completion.session.cancel()
            recordStaleScanRunDrop(sourceID: completion.sourceID)
            return
        }
        quantumTasksBySourceID.removeValue(forKey: completion.sourceID)
        if isShuttingDown {
            _ = completion.session.cancel()
            activeDemandCoverageBySourceID.removeValue(forKey: completion.sourceID)
            stateBySourceID.removeValue(forKey: completion.sourceID)
            finalizeShutdownIfDrained()
            if let factSink, case .validationRequired(let scannerRequest) = completion.outcome {
                factSink(
                    WatchedFolderScanValidationScope(
                        registration: completion.registration,
                        scanRunGeneration: completion.scanRunGeneration,
                        requestID: RepoDiscoveryValidationRequestID(rawValue: scannerRequest.requestID.rawValue)
                    ),
                    .validationDiscardedDuringShutdown
                )
            }
            return
        }
        guard currentRootBySourceID[completion.sourceID]?.registration == completion.registration else {
            _ = completion.session.cancel()
            activeDemandCoverageBySourceID.removeValue(forKey: completion.sourceID)
            recordStaleRegistrationDrop(sourceID: completion.sourceID)
            preserveDirtyAfterStaleCompletion(sourceID: completion.sourceID, state: state)
            _ = dispatchReadyQuanta()
            return
        }

        switch completion.outcome {
        case .suspended:
            requeueSuspendedCompletion(completion, running: running, state: state)
        case .validationRequired(let request):
            await retainValidationRequest(
                request,
                completion: completion,
                running: running,
                state: state
            )
        case .finished(let scannerResult):
            retainFinishedResult(scannerResult, running: running, state: state)
        }
        _ = dispatchReadyQuanta()
    }

    private func requeueSuspendedCompletion(
        _ completion: QuantumCompletion,
        running: RunningQuantum,
        state: RootSchedulingState
    ) {
        let queued = QueuedSuspendedScan(
            logicalScan: LogicalScan(
                request: running.request,
                scanRunGeneration: running.scanRunGeneration,
                session: completion.session,
                accumulatedQueueWaitDuration: running.accumulatedQueueWaitDuration,
                quantumSelectionCount: running.quantumSelectionCount,
                startedFromDirtyFollowUp: running.startedFromDirtyFollowUp
            ),
            fifoOrdinal: takeFIFOOrdinal(),
            readyAt: now()
        )
        switch state {
        case .running:
            stateBySourceID[completion.sourceID] = .queuedSuspended(queued)
        case .runningAndDirty(_, let dirty):
            stateBySourceID[completion.sourceID] = .queuedSuspendedAndDirty(queued, dirty)
        default:
            preconditionFailure("quantum completion requires a running root state")
        }
    }

    private func retainFinishedResult(
        _ scannerResult: RepoScannerResult,
        running: RunningQuantum,
        state: RootSchedulingState
    ) {
        let dirtyDemand: PendingDemand?
        switch state {
        case .running:
            dirtyDemand = nil
        case .runningAndDirty(_, let dirty):
            dirtyDemand = dirty
        default:
            preconditionFailure("finished quantum requires a running root state")
        }
        let staleDrops =
            staleDropsBySourceID.removeValue(forKey: running.request.sourceID)
            ?? StaleDropCounts()
        let followUpEvidence: WatchedFolderScanFollowUpEvidence
        if dirtyDemand != nil {
            followUpEvidence = .dirtyFollowUpQueued
        } else if running.startedFromDirtyFollowUp {
            followUpEvidence = .startedFromDirtyFollowUp
        } else {
            followUpEvidence = .noFollowUp
        }
        let pending = PendingResult(
            result: ScheduledWatchedFolderScanResult(
                resultID: .make(),
                request: running.request,
                demandCoverage: takeActiveDemandCoverage(for: running),
                scanRunGeneration: running.scanRunGeneration,
                scannerResult: scannerResult,
                schedulingMetrics: WatchedFolderScanSchedulingMetrics(
                    queueWaitDuration: running.accumulatedQueueWaitDuration,
                    quantumSelectionCount: running.quantumSelectionCount,
                    staleRegistrationDropCount: staleDrops.registration,
                    staleScanRunDropCount: staleDrops.scanRun,
                    followUpEvidence: followUpEvidence
                )
            ),
            completionOrdinal: takeCompletionOrdinal()
        )
        if let dirtyDemand {
            stateBySourceID[running.request.sourceID] = .pendingResultAndDirty(
                pending,
                dirtyDemand
            )
        } else {
            stateBySourceID[running.request.sourceID] = .pendingResult(pending)
        }
        resultCustodyHighWater = max(resultCustodyHighWater, resultCustodyCount)
        signalResultAvailability()
    }

    func dispatchReadyQuanta() -> DispatchOutcomes {
        var outcomes = DispatchOutcomes()
        while occupiedCreditCount < maximumConcurrentScans,
            let queued = stateBySourceID.oldestReadyScan()
        {
            let sourceID = queued.request.sourceID
            let running: RunningQuantum
            switch queued {
            case .new(let newScan):
                let previous = scanRunGenerationBySourceID[sourceID] ?? 0
                let (generation, overflow) = previous.addingReportingOverflow(1)
                guard !overflow else {
                    stateBySourceID.removeValue(forKey: sourceID)
                    outcomes.exhaustedBySourceID[sourceID] = .scanRunGenerationExhausted(sourceID)
                    continue
                }
                scanRunGenerationBySourceID[sourceID] = generation
                activeDemandCoverageBySourceID[sourceID] = newScan.demand.coverage
                running = RunningQuantum(
                    request: newScan.request,
                    scanRunGeneration: generation,
                    executionID: UUIDv7.generate(),
                    session: .creating,
                    accumulatedQueueWaitDuration: now() - newScan.readyAt,
                    quantumSelectionCount: 1,
                    startedFromDirtyFollowUp: newScan.startedFromDirtyFollowUp
                )
            case .suspended(let suspended):
                let logical = suspended.logicalScan
                running = RunningQuantum(
                    request: logical.request,
                    scanRunGeneration: logical.scanRunGeneration,
                    executionID: UUIDv7.generate(),
                    session: .existing(logical.session),
                    accumulatedQueueWaitDuration: logical.accumulatedQueueWaitDuration
                        + (now() - suspended.readyAt),
                    quantumSelectionCount: saturatingIncrement(logical.quantumSelectionCount),
                    startedFromDirtyFollowUp: logical.startedFromDirtyFollowUp
                )
            }
            let dirty = dirtyDemand(from: stateBySourceID[sourceID])
            if let dirty {
                stateBySourceID[sourceID] = .runningAndDirty(running, dirty)
            } else {
                stateBySourceID[sourceID] = .running(running)
            }
            outcomes.startedSourceIDs.insert(sourceID)
            startQuantum(running)
        }
        return outcomes
    }

    private func startQuantum(_ running: RunningQuantum) {
        let factory = sessionFactory
        let scheduler = self
        // Scanner session construction and traversal must not inherit scheduler actor isolation.
        // swiftlint:disable:next no_task_detached
        let task = Task.detached {
            let session: WatchedFolderScannerSessionPort
            switch running.session {
            case .creating:
                session = await factory(running.request, running.scanRunGeneration)
            case .existing(let existing):
                session = existing
            }
            let outcome = await session.advanceOneQuantum()
            await scheduler.receiveQuantumCompletion(
                QuantumCompletion(
                    sourceID: running.request.sourceID,
                    registration: running.request.canonicalRoot.registration,
                    scanRunGeneration: running.scanRunGeneration,
                    executionID: running.executionID,
                    session: session,
                    outcome: outcome
                )
            )
        }
        quantumTasksBySourceID[running.request.sourceID] = task
    }

    private func takeActiveDemandCoverage(
        for running: RunningQuantum
    ) -> WatchedFolderScanDemandCoverage {
        guard
            let coverage = activeDemandCoverageBySourceID.removeValue(
                forKey: running.request.sourceID
            ),
            coverage.registration == running.request.canonicalRoot.registration
        else {
            preconditionFailure("a finished logical scan must retain exact demand coverage")
        }
        return coverage
    }

    private func admitRegistration(
        _ submittedRoot: RegisteredRootDescriptor
    ) -> RegistrationAdmissionResult {
        guard let currentRoot = currentRootBySourceID[submittedRoot.sourceID] else {
            if let retiredRoot = retiredRootBySourceID[submittedRoot.sourceID] {
                guard registrationIsNewer(submittedRoot.registration, than: retiredRoot.registration)
                else {
                    return .rejected(
                        .staleRegistration(
                            submitted: submittedRoot.registration,
                            current: retiredRoot.registration
                        )
                    )
                }
                retiredRootBySourceID.removeValue(forKey: submittedRoot.sourceID)
            }
            currentRootBySourceID[submittedRoot.sourceID] = submittedRoot
            return .accepted
        }
        if currentRoot.registration == submittedRoot.registration {
            guard currentRoot == submittedRoot else {
                return .rejected(.registrationDescriptorMismatch(submittedRoot.registration))
            }
            return .accepted
        }
        guard registrationIsNewer(submittedRoot.registration, than: currentRoot.registration) else {
            return .rejected(
                .staleRegistration(
                    submitted: submittedRoot.registration,
                    current: currentRoot.registration
                )
            )
        }
        currentRootBySourceID[submittedRoot.sourceID] = submittedRoot
        retiredRootBySourceID.removeValue(forKey: submittedRoot.sourceID)
        return .accepted
    }

    private func registrationIsNewer(
        _ candidate: FSEventRegistrationToken,
        than current: FSEventRegistrationToken
    ) -> Bool {
        if candidate.registrationGeneration != current.registrationGeneration {
            return candidate.registrationGeneration > current.registrationGeneration
        }
        return candidate.rootGeneration > current.rootGeneration
    }

    private func leaseOldestPendingResult() -> WatchedFolderScanResultLease? {
        guard currentLeasedResult() == nil else { return nil }
        while true {
            let candidates = stateBySourceID.compactMap(pendingResultCandidate)
            guard
                let selected = candidates.min(by: {
                    $0.1.completionOrdinal < $1.1.completionOrdinal
                })
            else { return nil }
            let resultRegistration = selected.1.result.request.canonicalRoot.registration
            guard currentRootBySourceID[selected.0]?.registration == resultRegistration else {
                discardStalePendingResult(sourceID: selected.0)
                continue
            }
            let leased = LeasedResult(pending: selected.1, leaseID: .make())
            switch stateBySourceID[selected.0] {
            case .pendingResult:
                stateBySourceID[selected.0] = .leasedResult(leased)
            case .pendingResultAndDirty(_, let dirty):
                stateBySourceID[selected.0] = .leasedResultAndDirty(leased, dirty)
            default:
                preconditionFailure("selected result must remain pending until leased")
            }
            return WatchedFolderScanResultLease(
                leaseID: leased.leaseID,
                result: leased.pending.result
            )
        }
    }

    private func pendingResultCandidate(
        _ entry: (key: FilesystemSourceID, value: RootSchedulingState)
    ) -> (FilesystemSourceID, PendingResult)? {
        switch entry.value {
        case .pendingResult(let pending), .pendingResultAndDirty(let pending, _):
            (entry.key, pending)
        default:
            nil
        }
    }

    private func discardStalePendingResult(sourceID: FilesystemSourceID) {
        let dirty = dirtyDemand(from: stateBySourceID[sourceID])
        stateBySourceID.removeValue(forKey: sourceID)
        recordStaleRegistrationDrop(sourceID: sourceID)
        if let dirty,
            currentRootBySourceID[sourceID]?.registration
                == dirty.request.canonicalRoot.registration
        {
            stateBySourceID[sourceID] = .queuedNew(
                makeQueuedNewScan(dirty, startedFromDirtyFollowUp: true)
            )
        }
        _ = dispatchReadyQuanta()
    }

    private func restorePendingResult(
        _ located: (sourceID: FilesystemSourceID, leased: LeasedResult, dirty: PendingDemand?)
    ) {
        if let dirty = located.dirty {
            stateBySourceID[located.sourceID] = .pendingResultAndDirty(located.leased.pending, dirty)
        } else {
            stateBySourceID[located.sourceID] = .pendingResult(located.leased.pending)
        }
    }

    private func finishTransferredResult(
        _ located: (sourceID: FilesystemSourceID, leased: LeasedResult, dirty: PendingDemand?)
    ) {
        stateBySourceID.removeValue(forKey: located.sourceID)
        if !isShuttingDown, let dirty = located.dirty,
            currentRootBySourceID[located.sourceID]?.registration
                == dirty.request.canonicalRoot.registration
        {
            stateBySourceID[located.sourceID] = .queuedNew(
                makeQueuedNewScan(dirty, startedFromDirtyFollowUp: true)
            )
        }
        _ = dispatchReadyQuanta()
        finalizeShutdownIfDrained()
    }

    private func signalResultAvailability() {
        guard resultCustodyCount > 0, let waiter = resultWaiter else { return }
        resultWaiter = nil
        waiter.continuation.resume(returning: .resultAvailable)
    }

    private func cancelResultWaiter(_ waiterID: UUID) {
        guard let waiter = resultWaiter, waiter.waiterID == waiterID else { return }
        resultWaiter = nil
        waiter.continuation.resume(returning: .cancelled)
    }

    func finalizeShutdownIfDrained() {
        guard isShuttingDown, occupiedCreditCount == 0,
            stateCounts.awaitingValidation == 0,
            validationAdmissionsByRequestID.isEmpty,
            validationCompletionDrainTask == nil
                && validationPhysicalDrainTask == nil
        else { return }
        isShutDown = true
        isShuttingDown = false
        if let waiter = resultWaiter {
            resultWaiter = nil
            waiter.continuation.resume(returning: .schedulerShutDown)
        }
    }

    private func cancelRunningQuantum(sourceID: FilesystemSourceID, running: RunningQuantum) {
        if case .existing(let session) = running.session { _ = session.cancel() }
        quantumTasksBySourceID[sourceID]?.cancel()
    }

    func preserveDirtyAfterStaleCompletion(
        sourceID: FilesystemSourceID,
        state: RootSchedulingState
    ) {
        guard let dirty = dirtyDemand(from: state),
            currentRootBySourceID[sourceID]?.registration
                == dirty.request.canonicalRoot.registration
        else {
            stateBySourceID.removeValue(forKey: sourceID)
            return
        }
        stateBySourceID[sourceID] = .queuedNew(makeQueuedNewScan(dirty))
    }

    private func makeQueuedNewScan(
        _ demand: PendingDemand,
        startedFromDirtyFollowUp: Bool = false
    ) -> QueuedNewScan {
        QueuedNewScan(
            demand: demand,
            fifoOrdinal: takeFIFOOrdinal(),
            readyAt: now(),
            startedFromDirtyFollowUp: startedFromDirtyFollowUp
        )
    }

    func takeFIFOOrdinal() -> UInt64 {
        let ordinal = nextFIFOOrdinal
        nextFIFOOrdinal = saturatingIncrement(nextFIFOOrdinal)
        return ordinal
    }

    private func takeCompletionOrdinal() -> UInt64 {
        let ordinal = nextCompletionOrdinal
        nextCompletionOrdinal = saturatingIncrement(nextCompletionOrdinal)
        return ordinal
    }

    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        let (incremented, overflow) = value.addingReportingOverflow(1)
        return overflow ? UInt64.max : incremented
    }

    private func runningQuantum(from state: RootSchedulingState) -> RunningQuantum? {
        switch state {
        case .running(let running), .runningAndDirty(let running, _): running
        default: nil
        }
    }

    private func dirtyDemand(from state: RootSchedulingState?) -> PendingDemand? {
        switch state {
        case .queuedSuspendedAndDirty(_, let dirty), .runningAndDirty(_, let dirty),
            .awaitingValidationAndDirty(_, let dirty), .pendingResultAndDirty(_, let dirty),
            .leasedResultAndDirty(_, let dirty):
            dirty
        default:
            nil
        }
    }

    private func currentLeasedResult() -> LeasedResult? {
        locateLeasedResult()?.leased
    }

    private func locateLeasedResult() -> (
        sourceID: FilesystemSourceID,
        leased: LeasedResult,
        dirty: PendingDemand?
    )? {
        for (sourceID, state) in stateBySourceID {
            switch state {
            case .leasedResult(let leased):
                return (sourceID, leased, nil)
            case .leasedResultAndDirty(let leased, let dirty):
                return (sourceID, leased, dirty)
            default:
                continue
            }
        }
        return nil
    }

    private var occupiedCreditCount: Int {
        let counts = stateBySourceID.counts
        return counts.active + counts.pending + counts.leased
    }

    private var resultCustodyCount: Int {
        let counts = stateBySourceID.counts
        return counts.pending + counts.leased
    }

    private var stateCounts: StateCounts {
        stateBySourceID.counts
    }

    func recordStaleRegistrationDrop(sourceID: FilesystemSourceID) {
        var counts = staleDropsBySourceID[sourceID] ?? StaleDropCounts()
        counts.registration = saturatingIncrement(counts.registration)
        staleDropsBySourceID[sourceID] = counts
    }

    func recordStaleScanRunDrop(sourceID: FilesystemSourceID) {
        var counts = staleDropsBySourceID[sourceID] ?? StaleDropCounts()
        counts.scanRun = saturatingIncrement(counts.scanRun)
        staleDropsBySourceID[sourceID] = counts
    }
}
