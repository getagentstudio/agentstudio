import Foundation

package protocol RepoDiscoveryReadClient: Sendable {
    func validateDiscoveryCandidate(at candidateURL: URL) async -> GitRepositoryDiscoveryOutcome
}

package struct RepoDiscoveryValidationRequestID: Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    package static func make() -> Self { Self(rawValue: UUIDv7.generate()) }
    package var isUUIDv7: Bool { UUIDv7.isV7(rawValue) }
}

package struct RepoDiscoveryValidationRequest: Equatable, Sendable {
    package let requestID: RepoDiscoveryValidationRequestID
    package let scannerSessionID: RepoScannerSessionID
    package let scanRunGeneration: UInt64
    package let authorizedRoot: RegisteredRootDescriptor
    package let candidateURL: URL

    package init(
        requestID: RepoDiscoveryValidationRequestID,
        scannerSessionID: RepoScannerSessionID,
        scanRunGeneration: UInt64,
        authorizedRoot: RegisteredRootDescriptor,
        candidateURL: URL
    ) {
        self.requestID = requestID
        self.scannerSessionID = scannerSessionID
        self.scanRunGeneration = scanRunGeneration
        self.authorizedRoot = authorizedRoot
        self.candidateURL = candidateURL
    }
}

package enum RepoDiscoveryValidationBudgetError: Error, Equatable, Sendable {
    case nonPositiveLogicalDeadline(Duration)
    case nonPositiveMaximumPhysicalJobs(Int)
    case logicalCapacitySmallerThanPhysicalCapacity(logical: Int, physical: Int)
    case unsupportedMaximumQueuedRequestsPerRoot(Int)
}

package struct RepoDiscoveryValidationBudget: Equatable, Sendable {
    package let logicalDeadline: Duration
    package let maximumPhysicalJobs: Int
    /// Maximum running, queued, or completed-but-undelivered logical requests.
    package let maximumQueuedRequests: Int
    package let maximumQueuedRequestsPerRoot: Int

    package static let productionDefault = Self(
        validatedLogicalDeadline: AppPolicies.GitRefresh.defaultDiscoveryReadTimeout,
        maximumPhysicalJobs: 2,
        maximumQueuedRequests: 256,
        maximumQueuedRequestsPerRoot: 1
    )

    package init(
        logicalDeadline: Duration,
        maximumPhysicalJobs: Int,
        maximumQueuedRequests: Int,
        maximumQueuedRequestsPerRoot: Int
    ) throws {
        guard logicalDeadline > .zero else {
            throw RepoDiscoveryValidationBudgetError.nonPositiveLogicalDeadline(logicalDeadline)
        }
        guard maximumPhysicalJobs > 0 else {
            throw RepoDiscoveryValidationBudgetError.nonPositiveMaximumPhysicalJobs(
                maximumPhysicalJobs
            )
        }
        guard maximumQueuedRequests >= maximumPhysicalJobs else {
            throw RepoDiscoveryValidationBudgetError.logicalCapacitySmallerThanPhysicalCapacity(
                logical: maximumQueuedRequests,
                physical: maximumPhysicalJobs
            )
        }
        guard maximumQueuedRequestsPerRoot == 1 else {
            throw RepoDiscoveryValidationBudgetError.unsupportedMaximumQueuedRequestsPerRoot(
                maximumQueuedRequestsPerRoot
            )
        }
        self.init(
            validatedLogicalDeadline: logicalDeadline,
            maximumPhysicalJobs: maximumPhysicalJobs,
            maximumQueuedRequests: maximumQueuedRequests,
            maximumQueuedRequestsPerRoot: maximumQueuedRequestsPerRoot
        )
    }

    private init(
        validatedLogicalDeadline: Duration,
        maximumPhysicalJobs: Int,
        maximumQueuedRequests: Int,
        maximumQueuedRequestsPerRoot: Int
    ) {
        logicalDeadline = validatedLogicalDeadline
        self.maximumPhysicalJobs = maximumPhysicalJobs
        self.maximumQueuedRequests = maximumQueuedRequests
        self.maximumQueuedRequestsPerRoot = maximumQueuedRequestsPerRoot
    }
}

package enum RepoDiscoveryValidationAdmissionAcceptance: Equatable, Sendable {
    case started
    case queued
}

package enum RepoDiscoveryValidationAdmissionRejection: Equatable, Sendable {
    case duplicateRequest(RepoDiscoveryValidationRequestID)
    case scannerSessionAlreadyOutstanding(RepoScannerSessionID)
    case sourceAlreadyOutstanding(FilesystemSourceID)
    case logicalCapacityReached(maximum: Int)
    case allPhysicalJobsDraining(count: Int)
    case shutdown
}

package enum RepoDiscoveryValidationAdmissionResult: Equatable, Sendable {
    case accepted(RepoDiscoveryValidationAdmissionAcceptance)
    case rejected(RepoDiscoveryValidationAdmissionRejection)
}

package struct FinishedRepoDiscoveryValidation: Equatable, Sendable {
    package let request: RepoDiscoveryValidationRequest
    package let outcome: GitRepositoryDiscoveryOutcome
    package let validationServiceDuration: Duration
}

package struct TimedOutRepoDiscoveryValidation: Equatable, Sendable {
    package let request: RepoDiscoveryValidationRequest
    package let validationServiceDuration: Duration
}

package enum RepoDiscoveryValidationCancellationCause: Equatable, Sendable {
    case explicitRequest
    case shutdown
}

package struct CancelledRepoDiscoveryValidation: Equatable, Sendable {
    package let request: RepoDiscoveryValidationRequest
    package let cause: RepoDiscoveryValidationCancellationCause
    package let validationServiceDuration: Duration
}

package enum RepoDiscoveryValidationCompletion: Equatable, Sendable {
    case finished(FinishedRepoDiscoveryValidation)
    case timedOut(TimedOutRepoDiscoveryValidation)
    case cancelled(CancelledRepoDiscoveryValidation)
}

package enum RepoDiscoveryValidationCancellationDisposition: Equatable, Sendable {
    case queued
    case running
}

package enum RepoDiscoveryValidationCancellationResult: Equatable, Sendable {
    case cancelled(RepoDiscoveryValidationCancellationDisposition)
    case alreadyCompleted
    case unknownRequest
}

package enum RepoDiscoveryValidationShutdownResult: Equatable, Sendable {
    case started(cancelledLogicalRequestCount: Int, physicalDrainCount: Int)
    case alreadyStarted
}

package enum RepoDiscoveryValidationShutdownState: Equatable, Sendable {
    case drainingPhysicalJobs(count: Int)
    case complete
}

package enum RepoDiscoveryValidationCompletionWaitRejection: Equatable, Sendable {
    case anotherWaiterRegistered
}

package enum RepoDiscoveryValidationCompletionWaitResult: Equatable, Sendable {
    case completed(RepoDiscoveryValidationCompletion)
    case cancelled
    case shutdown(RepoDiscoveryValidationShutdownState)
    case rejected(RepoDiscoveryValidationCompletionWaitRejection)
}

package struct RepoDiscoveryValidationExecutorSnapshot: Equatable, Sendable {
    package let physicalJobCount: Int
    package let drainingPhysicalJobCount: Int
    package let queuedRequestCount: Int
    package let logicalRequestCount: Int
    package let semanticCompletionCount: UInt64
    package let lateNativeReturnCount: UInt64
    package let staleNativeReturnCount: UInt64
}

package protocol RepoDiscoveryDeadlineScheduler: Sendable {
    func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline
}

package struct RepoDiscoveryScheduledDeadline: Sendable {
    private let cancelHandler: @Sendable () -> Void

    package init(cancel: @escaping @Sendable () -> Void) { cancelHandler = cancel }
    func cancel() { cancelHandler() }
}

package struct DispatchRepoDiscoveryDeadlineScheduler: RepoDiscoveryDeadlineScheduler {
    package init() {}

    private static let queue = DispatchQueue(
        label: "com.agentstudio.repo-discovery-deadline",
        qos: .utility
    )

    package func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline {
        let workItem = SendableRepoDiscoveryDeadlineWorkItem(handler: handler)
        Self.queue.asyncAfter(
            deadline: .now() + duration.timeIntervalForDispatch,
            execute: workItem.dispatchWorkItem
        )
        return RepoDiscoveryScheduledDeadline { workItem.cancel() }
    }
}

private final class SendableRepoDiscoveryDeadlineWorkItem: @unchecked Sendable {
    package let dispatchWorkItem: DispatchWorkItem

    package init(handler: @escaping @Sendable () -> Void) {
        dispatchWorkItem = DispatchWorkItem(block: handler)
    }

    func cancel() { dispatchWorkItem.cancel() }
}

package actor RepoScannerValidationExecutor {
    private struct PhysicalJobID: Hashable, Sendable {
        let rawValue: UUID
        static func make() -> Self { Self(rawValue: UUIDv7.generate()) }
    }

    private enum PhysicalJobPhase: Sendable {
        case running(RepoDiscoveryScheduledDeadline)
        case drainingAfterTimeout
        case drainingAfterCancellation
    }

    private struct PhysicalJob: Sendable {
        let jobID: PhysicalJobID
        let request: RepoDiscoveryValidationRequest
        let serviceStartedAt: Duration
        var phase: PhysicalJobPhase

        var isDraining: Bool {
            switch phase {
            case .running:
                false
            case .drainingAfterTimeout, .drainingAfterCancellation:
                true
            }
        }
    }

    private enum LogicalRequestPhase: Sendable {
        case queued
        case running(PhysicalJobID)
        case semanticCompletionPendingDelivery
    }

    private struct LogicalRequest: Sendable {
        let request: RepoDiscoveryValidationRequest
        var phase: LogicalRequestPhase
    }

    private struct CompletionWaiter: Sendable {
        let identity: RepoDiscoveryValidationRequestID
        let continuation: CheckedContinuation<RepoDiscoveryValidationCompletionWaitResult, Never>
    }

    private let validationClient: any RepoDiscoveryReadClient
    private let deadlineScheduler: any RepoDiscoveryDeadlineScheduler
    private let budget: RepoDiscoveryValidationBudget
    private let now: @Sendable () -> Duration
    private var acceptingAdmissions = true
    private var readySourceRing: [FilesystemSourceID] = []
    private var queuedRequestBySource: [FilesystemSourceID: RepoDiscoveryValidationRequest] = [:]
    private var logicalRequests: [RepoDiscoveryValidationRequestID: LogicalRequest] = [:]
    private var physicalJobs: [PhysicalJobID: PhysicalJob] = [:]
    private var requestToPhysicalJob: [RepoDiscoveryValidationRequestID: PhysicalJobID] = [:]
    private var outstandingSessions: Set<RepoScannerSessionID> = []
    private var outstandingSources: Set<FilesystemSourceID> = []
    private var recentRequestIDs: Set<RepoDiscoveryValidationRequestID> = []
    private var recentRequestIDOrder: [RepoDiscoveryValidationRequestID] = []
    private var completions: [RepoDiscoveryValidationCompletion] = []
    private var completionWaiter: CompletionWaiter?
    private var physicalDrainWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var semanticCompletionCount: UInt64 = 0
    private var lateNativeReturnCount: UInt64 = 0
    private var staleNativeReturnCount: UInt64 = 0

    package init(
        validationClient: any RepoDiscoveryReadClient,
        deadlineScheduler: any RepoDiscoveryDeadlineScheduler = DispatchRepoDiscoveryDeadlineScheduler(),
        budget: RepoDiscoveryValidationBudget = .productionDefault,
        now: @escaping @Sendable () -> Duration = RepoDiscoveryValidationClock.productionNow()
    ) throws {
        self.validationClient = validationClient
        self.deadlineScheduler = deadlineScheduler
        self.budget = budget
        self.now = now
    }

    package func submit(_ request: RepoDiscoveryValidationRequest) -> RepoDiscoveryValidationAdmissionResult {
        guard acceptingAdmissions else { return .rejected(.shutdown) }
        if logicalRequests[request.requestID] != nil || recentRequestIDs.contains(request.requestID) {
            return .rejected(.duplicateRequest(request.requestID))
        }
        if outstandingSessions.contains(request.scannerSessionID) {
            return .rejected(.scannerSessionAlreadyOutstanding(request.scannerSessionID))
        }
        let sourceID = request.authorizedRoot.sourceID
        if outstandingSources.contains(sourceID) {
            return .rejected(.sourceAlreadyOutstanding(sourceID))
        }
        guard logicalRequests.count < budget.maximumQueuedRequests else {
            return .rejected(.logicalCapacityReached(maximum: budget.maximumQueuedRequests))
        }
        if physicalJobs.count == budget.maximumPhysicalJobs,
            physicalJobs.values.allSatisfy(\.isDraining)
        {
            return .rejected(.allPhysicalJobsDraining(count: physicalJobs.count))
        }

        outstandingSessions.insert(request.scannerSessionID)
        outstandingSources.insert(sourceID)
        if physicalJobs.count < budget.maximumPhysicalJobs {
            logicalRequests[request.requestID] = LogicalRequest(request: request, phase: .queued)
            startPhysicalJob(for: request)
            return .accepted(.started)
        }
        logicalRequests[request.requestID] = LogicalRequest(request: request, phase: .queued)
        readySourceRing.append(sourceID)
        queuedRequestBySource[sourceID] = request
        return .accepted(.queued)
    }

    package func cancel(
        requestID: RepoDiscoveryValidationRequestID
    ) -> RepoDiscoveryValidationCancellationResult {
        cancelLogicalRequest(requestID: requestID, cause: .explicitRequest)
    }

    package func beginShutdown() -> RepoDiscoveryValidationShutdownResult {
        guard acceptingAdmissions else { return .alreadyStarted }
        acceptingAdmissions = false
        let cancellableIDs = logicalRequests.compactMap { requestID, logical -> RepoDiscoveryValidationRequestID? in
            switch logical.phase {
            case .queued, .running:
                requestID
            case .semanticCompletionPendingDelivery:
                nil
            }
        }
        for requestID in cancellableIDs {
            _ = cancelLogicalRequest(requestID: requestID, cause: .shutdown)
        }
        resumeCompletionWaiterForShutdownIfPossible()
        return .started(
            cancelledLogicalRequestCount: cancellableIDs.count,
            physicalDrainCount: physicalJobs.count
        )
    }

    package func nextCompletion() async -> RepoDiscoveryValidationCompletionWaitResult {
        let waiterIdentity = RepoDiscoveryValidationRequestID.make()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerCompletionWaiter(identity: waiterIdentity, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelCompletionWaiter(identity: waiterIdentity) }
        }
    }

    package func waitUntilPhysicalJobCount(_ maximumCount: Int) async {
        guard physicalJobs.count > maximumCount else { return }
        await withCheckedContinuation { continuation in
            physicalDrainWaiters.append((maximumCount, continuation))
        }
    }

    package func waitUntilPhysicalJobSlotAvailable() async {
        await waitUntilPhysicalJobCount(max(0, budget.maximumPhysicalJobs - 1))
    }

    func snapshot() -> RepoDiscoveryValidationExecutorSnapshot {
        RepoDiscoveryValidationExecutorSnapshot(
            physicalJobCount: physicalJobs.count,
            drainingPhysicalJobCount: physicalJobs.values.count { job in
                switch job.phase {
                case .running: false
                case .drainingAfterTimeout, .drainingAfterCancellation: true
                }
            },
            queuedRequestCount: readySourceRing.count,
            logicalRequestCount: logicalRequests.count,
            semanticCompletionCount: semanticCompletionCount,
            lateNativeReturnCount: lateNativeReturnCount,
            staleNativeReturnCount: staleNativeReturnCount
        )
    }
}

extension RepoScannerValidationExecutor {
    private func startPhysicalJob(for request: RepoDiscoveryValidationRequest) {
        let jobID = PhysicalJobID.make()
        let deadline = deadlineScheduler.scheduleDeadline(after: budget.logicalDeadline) {
            Task { await self.logicalDeadlineReached(jobID: jobID) }
        }
        physicalJobs[jobID] = PhysicalJob(
            jobID: jobID,
            request: request,
            serviceStartedAt: now(),
            phase: .running(deadline)
        )
        requestToPhysicalJob[request.requestID] = jobID
        logicalRequests[request.requestID]?.phase = .running(jobID)
        let validationClient = validationClient
        // Detached by design: a synchronous native read must not inherit executor actor isolation.
        // swiftlint:disable:next no_task_detached
        Task.detached(priority: .utility) {
            let outcome: GitRepositoryDiscoveryOutcome
            switch FilesystemPathCanonicalizer().classifyDiscoveryCandidate(
                request.candidateURL,
                within: request.authorizedRoot
            ) {
            case .contained(let candidate):
                let nativeOutcome = await validationClient.validateDiscoveryCandidate(
                    at: candidate.canonicalURL
                )
                switch nativeOutcome {
                case .validated(let entry):
                    switch FilesystemPathCanonicalizer().classifyDiscoveryCandidate(
                        entry.path,
                        within: request.authorizedRoot
                    ) {
                    case .contained(let validatedCandidate):
                        outcome = .validated(
                            RepoScanner.ResolvedGitEntry(
                                path: validatedCandidate.canonicalURL,
                                kind: entry.kind,
                                repositoryKey: entry.repositoryKey
                            )
                        )
                    case .rejected(let rejection):
                        outcome = .failure(.candidateAdmissionRejected(rejection))
                    }
                case .authoritativeNegative, .timeout, .cancelled, .failure:
                    outcome = nativeOutcome
                }
            case .rejected(let rejection):
                outcome = .failure(.candidateAdmissionRejected(rejection))
            }
            await self.nativeValidationReturned(jobID: jobID, outcome: outcome)
        }
    }

    private func logicalDeadlineReached(jobID: PhysicalJobID) {
        guard var job = physicalJobs[jobID], case .running = job.phase else { return }
        guard logicalRequestCanComplete(job.request.requestID) else { return }
        job.phase = .drainingAfterTimeout
        physicalJobs[jobID] = job
        markLogicalCompletion(
            .timedOut(
                TimedOutRepoDiscoveryValidation(
                    request: job.request,
                    validationServiceDuration: now() - job.serviceStartedAt
                )
            )
        )
    }

    private func nativeValidationReturned(
        jobID: PhysicalJobID,
        outcome: GitRepositoryDiscoveryOutcome
    ) {
        guard let job = physicalJobs.removeValue(forKey: jobID) else {
            staleNativeReturnCount &+= 1
            return
        }
        requestToPhysicalJob.removeValue(forKey: job.request.requestID)
        switch job.phase {
        case .running(let deadline):
            deadline.cancel()
            if logicalRequestCanComplete(job.request.requestID) {
                markLogicalCompletion(
                    .finished(
                        FinishedRepoDiscoveryValidation(
                            request: job.request,
                            outcome: outcome,
                            validationServiceDuration: now() - job.serviceStartedAt
                        )
                    )
                )
            }
        case .drainingAfterTimeout, .drainingAfterCancellation:
            lateNativeReturnCount &+= 1
        }
        resumePhysicalDrainWaiters()
        startReadyJobsWithinCapacity()
        resumeCompletionWaiterForShutdownIfPossible()
    }

    private func cancelLogicalRequest(
        requestID: RepoDiscoveryValidationRequestID,
        cause: RepoDiscoveryValidationCancellationCause
    ) -> RepoDiscoveryValidationCancellationResult {
        guard let logical = logicalRequests[requestID] else {
            return recentRequestIDs.contains(requestID) ? .alreadyCompleted : .unknownRequest
        }
        switch logical.phase {
        case .semanticCompletionPendingDelivery:
            return .alreadyCompleted
        case .queued:
            let sourceID = logical.request.authorizedRoot.sourceID
            queuedRequestBySource.removeValue(forKey: sourceID)
            readySourceRing.removeAll { $0 == sourceID }
            markLogicalCompletion(
                .cancelled(
                    CancelledRepoDiscoveryValidation(
                        request: logical.request,
                        cause: cause,
                        validationServiceDuration: .zero
                    )
                )
            )
            return .cancelled(.queued)
        case .running(let jobID):
            guard var job = physicalJobs[jobID], case .running(let deadline) = job.phase else {
                return .alreadyCompleted
            }
            deadline.cancel()
            job.phase = .drainingAfterCancellation
            physicalJobs[jobID] = job
            markLogicalCompletion(
                .cancelled(
                    CancelledRepoDiscoveryValidation(
                        request: logical.request,
                        cause: cause,
                        validationServiceDuration: now() - job.serviceStartedAt
                    )
                )
            )
            return .cancelled(.running)
        }
    }

    private func logicalRequestCanComplete(_ requestID: RepoDiscoveryValidationRequestID) -> Bool {
        guard let logical = logicalRequests[requestID] else { return false }
        if case .semanticCompletionPendingDelivery = logical.phase { return false }
        return true
    }

    private func markLogicalCompletion(_ completion: RepoDiscoveryValidationCompletion) {
        let requestID = completion.request.requestID
        logicalRequests[requestID]?.phase = .semanticCompletionPendingDelivery
        semanticCompletionCount &+= 1
        if let waiter = completionWaiter {
            completionWaiter = nil
            retireLogicalRequest(requestID)
            waiter.continuation.resume(returning: .completed(completion))
        } else {
            completions.append(completion)
        }
    }

    private func retireLogicalRequest(_ requestID: RepoDiscoveryValidationRequestID) {
        guard let logical = logicalRequests.removeValue(forKey: requestID) else { return }
        outstandingSessions.remove(logical.request.scannerSessionID)
        outstandingSources.remove(logical.request.authorizedRoot.sourceID)
        recentRequestIDs.insert(requestID)
        recentRequestIDOrder.append(requestID)
        if recentRequestIDOrder.count > budget.maximumQueuedRequests {
            recentRequestIDs.remove(recentRequestIDOrder.removeFirst())
        }
    }

    private func startReadyJobsWithinCapacity() {
        guard acceptingAdmissions else { return }
        while physicalJobs.count < budget.maximumPhysicalJobs, !readySourceRing.isEmpty {
            let sourceID = readySourceRing.removeFirst()
            guard let request = queuedRequestBySource.removeValue(forKey: sourceID) else { continue }
            startPhysicalJob(for: request)
        }
    }
}

extension RepoScannerValidationExecutor {
    private func registerCompletionWaiter(
        identity: RepoDiscoveryValidationRequestID,
        continuation: CheckedContinuation<RepoDiscoveryValidationCompletionWaitResult, Never>
    ) {
        if Task.isCancelled {
            continuation.resume(returning: .cancelled)
        } else if !completions.isEmpty {
            let completion = completions.removeFirst()
            retireLogicalRequest(completion.request.requestID)
            continuation.resume(returning: .completed(completion))
        } else if !acceptingAdmissions {
            continuation.resume(returning: .shutdown(currentShutdownState))
        } else if completionWaiter != nil {
            continuation.resume(returning: .rejected(.anotherWaiterRegistered))
        } else {
            completionWaiter = CompletionWaiter(identity: identity, continuation: continuation)
        }
    }

    private func cancelCompletionWaiter(identity: RepoDiscoveryValidationRequestID) {
        guard completionWaiter?.identity == identity else { return }
        let waiter = completionWaiter
        completionWaiter = nil
        waiter?.continuation.resume(returning: .cancelled)
    }

    private var currentShutdownState: RepoDiscoveryValidationShutdownState {
        physicalJobs.isEmpty ? .complete : .drainingPhysicalJobs(count: physicalJobs.count)
    }

    private func resumeCompletionWaiterForShutdownIfPossible() {
        guard !acceptingAdmissions, completions.isEmpty, let waiter = completionWaiter else { return }
        completionWaiter = nil
        waiter.continuation.resume(returning: .shutdown(currentShutdownState))
    }

    private func resumePhysicalDrainWaiters() {
        let ready = physicalDrainWaiters.filter { $0.0 >= physicalJobs.count }
        physicalDrainWaiters.removeAll { $0.0 >= physicalJobs.count }
        for waiter in ready { waiter.1.resume() }
    }
}

extension RepoDiscoveryValidationCompletion {
    fileprivate var request: RepoDiscoveryValidationRequest {
        switch self {
        case .finished(let value): value.request
        case .timedOut(let value): value.request
        case .cancelled(let value): value.request
        }
    }
}

package enum RepoDiscoveryValidationClock {
    package static func productionNow() -> @Sendable () -> Duration {
        let clock = ContinuousClock()
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }
}

extension Duration {
    fileprivate var timeIntervalForDispatch: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
