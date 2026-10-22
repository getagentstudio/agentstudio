import Foundation

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

struct SchedulerLookupDiagnosticFixture {
    typealias Scheduler = WatchedFolderScanScheduler
    let request: WatchedFolderScanRequest
    let pending: Scheduler.PendingResult

    init(ordinal: UInt64 = 7) throws {
        let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: UUIDv7.generate())
        let directory = FileManager.default.temporaryDirectory
        let root = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                .init(
                    registration: .init(sourceID: sourceID, registrationGeneration: 1, rootGeneration: 1),
                    authorizedBoundary: directory, registeredRoot: directory)))
        request = WatchedFolderScanRequest(canonicalRoot: root, cause: .manual)
        pending = Scheduler.PendingResult(
            result: .init(
                resultID: .make(), request: request,
                demandCoverage: .init(registration: root.registration, throughDemandGeneration: .init(rawValue: 1)),
                scanRunGeneration: 1,
                scannerResult: .completeAuthoritative(
                    .init(
                        verifiedEntries: [],
                        counts: .init(
                            directoryVisitCount: 0, directoryTraversalFailureCount: 0,
                            entryMetadataFailureCount: 0, gitCandidateCount: 0,
                            validationSuccessCount: 0, validationAuthoritativeNegativeCount: 0,
                            validationTimeoutCount: 0, validationCancellationCount: 0,
                            validationFailureCount: 0, scannerServiceInvocationCount: 1),
                        serviceMetrics: .zero)),
                schedulingMetrics: .init(
                    queueWaitDuration: .zero, quantumSelectionCount: 1,
                    staleRegistrationDropCount: 0, staleScanRunDropCount: 0, followUpEvidence: .noFollowUp)),
            completionOrdinal: ordinal)
    }

    var demand: Scheduler.PendingDemand {
        .init(request: request, coverage: pending.result.demandCoverage)
    }

    var queued: Scheduler.QueuedNewScan {
        .init(demand: demand, fifoOrdinal: 1, readyAt: .zero, startedFromDirtyFollowUp: false)
    }

    var leased: Scheduler.LeasedResult { .init(pending: pending, leaseID: .make()) }

    var session: WatchedFolderScannerSessionPort {
        .init(
            id: .init(rawValue: UUIDv7.generate()),
            advanceOneQuantum: { .finished(pending.result.scannerResult) },
            cancel: { .cancelled }, consumeValidationCompletion: { _ in .consumed })
    }

    var allStates: [Scheduler.RootSchedulingState] {
        let logical = Scheduler.LogicalScan(
            request: request, scanRunGeneration: 1, session: session,
            accumulatedQueueWaitDuration: .zero, quantumSelectionCount: 1, startedFromDirtyFollowUp: false)
        let suspended = Scheduler.QueuedSuspendedScan(logicalScan: logical, fifoOrdinal: 1, readyAt: .zero)
        let running = Scheduler.RunningQuantum(
            request: request, scanRunGeneration: 1, executionID: UUIDv7.generate(), session: .creating,
            accumulatedQueueWaitDuration: .zero, quantumSelectionCount: 1, startedFromDirtyFollowUp: false)
        let candidateURL = FileManager.default.temporaryDirectory
        let scannerRequest = RepoScannerValidationRequest(
            requestID: .make(), scannerSessionID: logical.session.id,
            scanRootURL: candidateURL, candidateURL: candidateURL)
        let awaiting = Scheduler.AwaitingValidation(
            logicalScan: logical, scannerRequest: scannerRequest,
            executorRequest: .init(
                requestID: .init(rawValue: scannerRequest.requestID.rawValue),
                scannerSessionID: logical.session.id, scanRunGeneration: 1,
                authorizedRoot: request.canonicalRoot, candidateURL: candidateURL))
        return [
            .queuedNew(queued), .queuedSuspended(suspended), .queuedSuspendedAndDirty(suspended, demand),
            .running(running), .runningAndDirty(running, demand), .awaitingValidation(awaiting),
            .awaitingValidationAndDirty(awaiting, demand), .pendingResult(pending),
            .pendingResultAndDirty(pending, demand), .leasedResult(leased), .leasedResultAndDirty(leased, demand),
        ]
    }
}
