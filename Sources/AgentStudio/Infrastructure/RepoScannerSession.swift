import Foundation
import Synchronization

final class RepoScannerTraversalSession: Sendable {
    typealias ResolvedGitEntry = RepoScanner.ResolvedGitEntry

    let id = RepoScannerSessionID(rawValue: UUIDv7.generate())

    let quantumBudget: RepoScannerQuantumBudget
    let retainedTargetIndex: RetainedTargetIndex
    private let capacity: RepoScannerSessionCapacity
    private let serviceClock: any Clock<Duration>
    private let lifecycle: Mutex<Lifecycle>

    init(
        rootURL: URL,
        maxDepth: Int,
        retainedCheckoutPaths: [URL],
        retainedTargetPreparationFailure: ScanFailureReason?,
        quantumBudget: RepoScannerQuantumBudget,
        capacity: RepoScannerSessionCapacity,
        serviceClock: any Clock<Duration>
    ) {
        self.quantumBudget = quantumBudget
        retainedTargetIndex = RetainedTargetIndex(
            rootURL: rootURL,
            retainedCheckoutPaths: retainedCheckoutPaths
        )
        self.capacity = capacity
        self.serviceClock = serviceClock
        lifecycle = Mutex(
            .ready(
                ReadyCustody(
                    traversalLease: TraversalLease(
                        state: TraversalState(
                            rootURL: rootURL,
                            maxDepth: maxDepth,
                            retainedCheckoutPaths: retainedCheckoutPaths,
                            retainedTargetPreparationFailure: retainedTargetPreparationFailure,
                            position: .inspectRoot
                        )
                    ),
                    completionHistory: .empty
                )
            )
        )
    }

    func advanceOneQuantum() async -> RepoScannerQuantumOutcome {
        let advanceCustody: AdvanceCustody = lifecycle.withLock { lifecycle in
            switch lifecycle {
            case .ready(let ready):
                lifecycle = .leased(
                    cancellationRequested: false,
                    completionHistory: ready.completionHistory
                )
                return .traversal(ready.traversalLease)
            case .leased:
                preconditionFailure("RepoScannerSessionPort permits only one active quantum lease")
            case .awaitingValidation(let pending):
                return .validation(pending.request)
            case .finished(let result, _):
                return .finished(result)
            }
        }
        let traversalLease: TraversalLease
        switch advanceCustody {
        case .traversal(let acquiredLease):
            traversalLease = acquiredLease
        case .validation(let request):
            return .validationRequired(request)
        case .finished(let result):
            return .finished(result)
        }

        traversalLease.state.scannerServiceInvocationCount += 1
        return advanceTraversalQuantum(traversalLease: traversalLease, serviceClock: serviceClock)
    }

    private func advanceTraversalQuantum<ServiceClock: Clock<Duration>>(
        traversalLease: TraversalLease,
        serviceClock: ServiceClock
    ) -> RepoScannerQuantumOutcome {
        let serviceStartedAt = serviceClock.now
        var usage = MutableQuantumUsage()
        let disposition = advanceTraversal(
            traversalLease: traversalLease,
            usage: &usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        )
        let traversalServiceDuration = serviceStartedAt.duration(to: serviceClock.now)
        traversalLease.state.traversalServiceDuration += traversalServiceDuration
        usage.traversalServiceDuration = traversalServiceDuration

        return lifecycle.withLock { lifecycle in
            let cancellationRequested: Bool
            let completionHistory: ValidationCompletionHistory
            switch lifecycle {
            case .leased(let requested, let history):
                cancellationRequested = requested
                completionHistory = history
            case .ready:
                preconditionFailure("scanner session lost its active quantum lease")
            case .awaitingValidation:
                preconditionFailure("scanner session entered validation custody before lease return")
            case .finished(let result, _):
                return .finished(result)
            }

            let outcome: RepoScannerQuantumOutcome
            if cancellationRequested || Task.isCancelled || disposition.isCancelled {
                let result = traversalLease.state.cancelledResult()
                lifecycle = .finished(result, completionHistory: completionHistory)
                outcome = .finished(result)
            } else {
                switch disposition {
                case .suspended:
                    lifecycle = .ready(
                        ReadyCustody(
                            traversalLease: traversalLease,
                            completionHistory: completionHistory
                        )
                    )
                    outcome = .suspended(usage: usage.snapshot)
                case .validationRequired(let request, let continuation):
                    let pending = PendingValidationCustody(
                        request: request,
                        continuation: continuation,
                        traversalLease: traversalLease,
                        completionHistory: completionHistory
                    )
                    lifecycle = .awaitingValidation(pending)
                    outcome = .validationRequired(request)
                case .exhausted:
                    let result = traversalLease.state.exhaustedResult()
                    lifecycle = .finished(result, completionHistory: completionHistory)
                    outcome = .finished(result)
                case .unavailable(let reason):
                    let result = traversalLease.state.unavailableResult(reason: reason)
                    lifecycle = .finished(result, completionHistory: completionHistory)
                    outcome = .finished(result)
                case .failed(let reason):
                    let result = traversalLease.state.failedResult(reason: reason)
                    lifecycle = .finished(result, completionHistory: completionHistory)
                    outcome = .finished(result)
                case .cancelled:
                    let result = traversalLease.state.cancelledResult()
                    lifecycle = .finished(result, completionHistory: completionHistory)
                    outcome = .finished(result)
                }
            }
            return outcome
        }
    }

    func cancel() -> RepoScannerSessionCancellationResult {
        lifecycle.withLock { lifecycle in
            switch lifecycle {
            case .ready(let ready):
                lifecycle = .finished(
                    ready.traversalLease.state.cancelledResult(),
                    completionHistory: ready.completionHistory
                )
                return .cancelled
            case .leased(_, let history):
                lifecycle = .leased(cancellationRequested: true, completionHistory: history)
                return .cancellationRequested
            case .awaitingValidation(let pending):
                pending.traversalLease.state.validationCancellationCount += 1
                lifecycle = .finished(
                    pending.traversalLease.state.cancelledResult(),
                    completionHistory: pending.completionHistory
                )
                return .cancelledAwaitingValidation(pending.request)
            case .finished:
                return .alreadyFinished
            }
        }
    }

    func consumeValidationCompletion(
        _ completion: RepoScannerValidationCompletion
    ) -> RepoScannerValidationCompletionConsumptionResult {
        guard completion.request.scannerSessionID == id else {
            return .rejected(.foreignSession(completion.request.scannerSessionID))
        }
        return lifecycle.withLock { lifecycle in
            switch lifecycle {
            case .awaitingValidation(let pending):
                guard completion.request.requestID == pending.request.requestID else {
                    if pending.completionHistory.contains(completion.request.requestID) {
                        return .rejected(.staleRequest(completion.request.requestID))
                    }
                    return .rejected(.foreignRequest(completion.request.requestID))
                }
                guard completion.request.scanRootURL == pending.request.scanRootURL else {
                    return .rejected(.foreignRoot(completion.request.scanRootURL))
                }
                guard completion.request.candidateURL == pending.request.candidateURL else {
                    return .rejected(.foreignCandidate(completion.request.candidateURL))
                }

                let completionHistory = pending.completionHistory.recording(
                    completion.request.requestID
                )
                pending.traversalLease.state.validationServiceDuration +=
                    completion.validationServiceDuration
                switch applyValidationOutcome(
                    completion.outcome,
                    candidateURL: pending.request.candidateURL,
                    traversalLease: pending.traversalLease
                ) {
                case .cancelled:
                    lifecycle = .finished(
                        pending.traversalLease.state.cancelledResult(),
                        completionHistory: completionHistory
                    )
                case .exhausted:
                    lifecycle = .finished(
                        pending.traversalLease.state.exhaustedResult(),
                        completionHistory: completionHistory
                    )
                case .resumeTraversal:
                    pending.traversalLease.state.position = pending.continuation.position
                    lifecycle = .ready(
                        ReadyCustody(
                            traversalLease: pending.traversalLease,
                            completionHistory: completionHistory
                        )
                    )
                }
                return .consumed
            case .ready(let ready):
                return ready.completionHistory.contains(completion.request.requestID)
                    ? .rejected(.duplicateCompletion(completion.request.requestID))
                    : .rejected(.foreignRequest(completion.request.requestID))
            case .leased(_, let completionHistory):
                return completionHistory.contains(completion.request.requestID)
                    ? .rejected(.duplicateCompletion(completion.request.requestID))
                    : .rejected(.foreignRequest(completion.request.requestID))
            case .finished(_, let completionHistory):
                return completionHistory.contains(completion.request.requestID)
                    ? .rejected(.duplicateCompletion(completion.request.requestID))
                    : .rejected(.sessionFinished)
            }
        }
    }
}

extension RepoScannerTraversalSession {
    private func advanceTraversal<ServiceClock: Clock<Duration>>(
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition {
        if traversalLease.state.maxDepth < 0 {
            return .failed(.invalidMaximumDepth(traversalLease.state.maxDepth))
        }

        while true {
            if Task.isCancelled || cancellationRequested() {
                return .cancelled
            }
            if usage.hasMadeProgress,
                quantumLimitReached(
                    usage: usage,
                    elapsed: serviceStartedAt.duration(to: serviceClock.now)
                )
            {
                return .suspended
            }

            let disposition: QuantumDisposition?
            switch traversalLease.state.position {
            case .inspectRoot:
                disposition = inspectRoot(
                    traversalLease: traversalLease,
                    usage: &usage,
                    serviceClock: serviceClock,
                    serviceStartedAt: serviceStartedAt
                )
            case .pendingValidation(let candidateURL, let continuation):
                disposition = requestValidation(
                    candidateURL,
                    continuation: continuation,
                    traversalLease: traversalLease,
                    usage: &usage
                )
            case .pendingEntry(let pendingEntry, let cursor):
                disposition = resumePendingEntry(
                    pendingEntry,
                    cursor: cursor,
                    traversalLease: traversalLease,
                    usage: &usage,
                    serviceClock: serviceClock,
                    serviceStartedAt: serviceStartedAt
                )
            case .enumerating(let cursor):
                disposition = enumerateNextEntry(
                    cursor: cursor,
                    traversalLease: traversalLease,
                    usage: &usage,
                    serviceClock: serviceClock,
                    serviceStartedAt: serviceStartedAt
                )
            case .retainedTargets(let nextIndex):
                disposition = inspectNextRetainedTarget(
                    at: nextIndex,
                    traversalLease: traversalLease,
                    usage: &usage,
                    serviceClock: serviceClock,
                    serviceStartedAt: serviceStartedAt
                )
            case .exhausted:
                disposition = .exhausted
            }
            if let disposition {
                return disposition
            }
        }
    }

    private func inspectRoot<ServiceClock: Clock<Duration>>(
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        guard
            consumeEnumeratedItem(
                traversalLease.state.rootURL,
                state: &traversalLease.state,
                usage: &usage
            )
        else {
            return .exhausted
        }

        let rootValues: URLResourceValues
        do {
            rootValues = try traversalLease.state.rootURL.resourceValues(
                forKeys: [.isDirectoryKey]
            )
        } catch let error as CocoaError where Self.isMissingFileError(error) {
            return .unavailable(.rootDoesNotExist)
        } catch {
            return .unavailable(.rootMetadataUnavailable(detail: String(describing: error)))
        }
        guard rootValues.isDirectory == true else {
            return .unavailable(.rootIsNotDirectory)
        }

        traversalLease.state.directoryVisitCount += 1
        if !traversalLease.state.remainingRetainedPathKeys.isEmpty {
            traversalLease.state.remainingRetainedPathKeys.remove(
                retainedTargetIndex.rootPathKey
            )
        }
        switch inspectGitMarker(at: traversalLease.state.rootURL) {
        case .candidate:
            return inspectRootCandidate(
                traversalLease: traversalLease,
                usage: &usage,
                serviceClock: serviceClock,
                serviceStartedAt: serviceStartedAt
            )
        case .notCandidate:
            return beginRootEnumeration(traversalLease: traversalLease)
        case .failed(let detail):
            traversalLease.state.entryMetadataFailureCount += 1
            _ = recordFailure(
                .gitMarkerInspectionFailed(
                    candidatePath: traversalLease.state.rootURL,
                    detail: detail
                ),
                state: &traversalLease.state,
                usage: &usage
            )
            traversalLease.state.position = .exhausted
            return .exhausted
        }
    }

    private func inspectRootCandidate<ServiceClock: Clock<Duration>>(
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        traversalLease.state.gitCandidateCount += 1
        if shouldSuspendBeforeValidation(
            usage: usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        ) {
            traversalLease.state.position = .pendingValidation(
                traversalLease.state.rootURL,
                continuation: .retainedTargets(nextIndex: 0)
            )
            return .suspended
        }
        return requestValidation(
            traversalLease.state.rootURL,
            continuation: .retainedTargets(nextIndex: 0),
            traversalLease: traversalLease,
            usage: &usage
        )
    }

    private func beginRootEnumeration(
        traversalLease: TraversalLease
    ) -> QuantumDisposition? {
        guard traversalLease.state.maxDepth > 0 else {
            traversalLease.state.position = .retainedTargets(nextIndex: 0)
            return nil
        }
        switch makeEnumerationCursor(
            rootURL: traversalLease.state.rootURL,
            maximumBufferedErrors: min(
                quantumBudget.maximumFailures,
                capacity.maximumRetainedFailures
            )
        ) {
        case .available(let cursor):
            traversalLease.state.position = .enumerating(cursor)
            return nil
        case .unavailable(let detail):
            return .unavailable(.rootTraversalUnavailable(detail: detail))
        }
    }

    private func resumePendingEntry<ServiceClock: Clock<Duration>>(
        _ pendingEntry: PendingEnumerationEntry,
        cursor: EnumerationCursor,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        traversalLease.state.position = .enumerating(cursor)
        return processEnumeratedEntry(
            pendingEntry,
            cursor: cursor,
            traversalLease: traversalLease,
            usage: &usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        )
    }

    private func enumerateNextEntry<ServiceClock: Clock<Duration>>(
        cursor: EnumerationCursor,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        cursor.errorBuffer.prepare(
            maximumAdditionalErrors: max(
                1,
                quantumBudget.maximumFailures - usage.failureCount
            )
        )
        guard let nextURL = cursor.enumerator.nextObject() as? URL else {
            let recordedErrors = cursor.errorBuffer.drain()
            if recordEnumerationErrors(
                recordedErrors,
                state: &traversalLease.state,
                usage: &usage
            ) {
                traversalLease.state.position = .exhausted
                return .exhausted
            }
            traversalLease.state.position = .retainedTargets(nextIndex: 0)
            return nil
        }

        let depth = cursor.enumerator.level
        let recordedErrors = cursor.errorBuffer.drain()
        if recordEnumerationErrors(
            recordedErrors,
            state: &traversalLease.state,
            usage: &usage
        ) {
            return .exhausted
        }
        let pendingEntry = PendingEnumerationEntry(url: nextURL, depth: depth)
        if shouldSuspendBeforeConsumingPath(nextURL, usage: usage) {
            traversalLease.state.position = .pendingEntry(pendingEntry, cursor: cursor)
            return .suspended
        }
        return processEnumeratedEntry(
            pendingEntry,
            cursor: cursor,
            traversalLease: traversalLease,
            usage: &usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        )
    }

    private func processEnumeratedEntry<ServiceClock: Clock<Duration>>(
        _ entry: PendingEnumerationEntry,
        cursor: EnumerationCursor,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        guard
            consumeEnumeratedItem(
                entry.url,
                state: &traversalLease.state,
                usage: &usage
            )
        else {
            return .exhausted
        }

        let values: URLResourceValues
        do {
            values = try entry.url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            removeRetainedTargetExaminedByTraversal(
                entry,
                isSymbolicLink: false,
                state: &traversalLease.state
            )
            traversalLease.state.entryMetadataFailureCount += 1
            cursor.enumerator.skipDescendants()
            if recordFailure(
                .entryMetadataReadFailed(
                    entryPath: entry.url,
                    detail: String(describing: error)
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
            traversalLease.state.position = .enumerating(cursor)
            return nil
        }
        guard entry.depth <= traversalLease.state.maxDepth else {
            cursor.enumerator.skipDescendants()
            traversalLease.state.position = .enumerating(cursor)
            return nil
        }
        removeRetainedTargetExaminedByTraversal(
            entry,
            isSymbolicLink: values.isSymbolicLink == true,
            state: &traversalLease.state
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            if values.isSymbolicLink == true {
                cursor.enumerator.skipDescendants()
            }
            traversalLease.state.position = .enumerating(cursor)
            return nil
        }

        traversalLease.state.directoryVisitCount += 1
        return inspectEnumeratedDirectoryGitMarker(
            entry,
            cursor: cursor,
            traversalLease: traversalLease,
            usage: &usage,
            serviceClock: serviceClock,
            serviceStartedAt: serviceStartedAt
        )
    }

    private func inspectEnumeratedDirectoryGitMarker<ServiceClock: Clock<Duration>>(
        _ entry: PendingEnumerationEntry,
        cursor: EnumerationCursor,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> QuantumDisposition? {
        switch inspectGitMarker(at: entry.url) {
        case .candidate:
            cursor.enumerator.skipDescendants()
            traversalLease.state.gitCandidateCount += 1
            let continuation = PostValidationContinuation.enumerating(cursor)
            if shouldSuspendBeforeValidation(
                usage: usage,
                serviceClock: serviceClock,
                serviceStartedAt: serviceStartedAt
            ) {
                traversalLease.state.position = .pendingValidation(
                    entry.url,
                    continuation: continuation
                )
                return .suspended
            }
            return requestValidation(
                entry.url,
                continuation: continuation,
                traversalLease: traversalLease,
                usage: &usage
            )
        case .notCandidate:
            if entry.depth >= traversalLease.state.maxDepth {
                cursor.enumerator.skipDescendants()
            }
            traversalLease.state.position = .enumerating(cursor)
            return nil
        case .failed(let detail):
            cursor.enumerator.skipDescendants()
            traversalLease.state.entryMetadataFailureCount += 1
            if recordFailure(
                .gitMarkerInspectionFailed(
                    candidatePath: entry.url,
                    detail: detail
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
            traversalLease.state.position = .enumerating(cursor)
            return nil
        }
    }

    func requestValidation(
        _ candidateURL: URL,
        continuation: PostValidationContinuation,
        traversalLease: TraversalLease,
        usage: inout MutableQuantumUsage
    ) -> QuantumDisposition? {
        usage.candidateValidationCount += 1
        let request = RepoScannerValidationRequest(
            requestID: .make(),
            scannerSessionID: id,
            scanRootURL: traversalLease.state.rootURL,
            candidateURL: candidateURL
        )
        return .validationRequired(request, continuation: continuation)
    }

    private func applyValidationOutcome(
        _ outcome: GitRepositoryDiscoveryOutcome,
        candidateURL: URL,
        traversalLease: TraversalLease
    ) -> ValidationApplicationDisposition {
        var usage = MutableQuantumUsage()
        switch outcome {
        case .validated(let entry):
            traversalLease.state.validationSuccessCount += 1
            guard
                retainVerifiedEntry(
                    entry,
                    state: &traversalLease.state,
                    usage: &usage
                )
            else {
                return .exhausted
            }
        case .authoritativeNegative:
            traversalLease.state.validationAuthoritativeNegativeCount += 1
        case .timeout:
            traversalLease.state.validationTimeoutCount += 1
            if recordFailure(
                .gitValidationTimedOut(candidatePath: candidateURL),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
        case .cancelled:
            traversalLease.state.validationCancellationCount += 1
            return .cancelled
        case .failure(let reason):
            traversalLease.state.validationFailureCount += 1
            if recordFailure(
                .gitRepositoryDiscoveryFailed(
                    candidatePath: candidateURL,
                    reason: reason
                ),
                state: &traversalLease.state,
                usage: &usage
            ) {
                return .exhausted
            }
        }
        return .resumeTraversal
    }

    func consumeEnumeratedItem(
        _ url: URL,
        state: inout TraversalState,
        usage: inout MutableQuantumUsage
    ) -> Bool {
        let pathByteCount = url.path.utf8.count
        guard pathByteCount <= quantumBudget.maximumPathBytes else {
            _ = recordFailure(
                .quantumPathByteLimitTooSmall(
                    pathByteCount: pathByteCount,
                    maximumPathBytes: quantumBudget.maximumPathBytes
                ),
                state: &state,
                usage: &usage
            )
            return false
        }
        guard state.enumeratedItemCount < capacity.maximumEnumeratedItems else {
            recordCapacityFailure(
                .enumeratedItemCount(maximum: capacity.maximumEnumeratedItems),
                state: &state,
                usage: &usage
            )
            return false
        }
        guard pathByteCount <= capacity.maximumPathBytes - state.enumeratedPathByteCount else {
            recordCapacityFailure(
                .enumeratedPathBytes(maximum: capacity.maximumPathBytes),
                state: &state,
                usage: &usage
            )
            return false
        }
        state.enumeratedItemCount += 1
        state.enumeratedPathByteCount += pathByteCount
        usage.enumeratedItemCount += 1
        usage.enumeratedPathByteCount += pathByteCount
        return true
    }

    private func retainVerifiedEntry(
        _ entry: ResolvedGitEntry,
        state: inout TraversalState,
        usage: inout MutableQuantumUsage
    ) -> Bool {
        let entryByteCount = Self.retainedByteCount(for: entry)
        guard state.verifiedEntries.count < capacity.maximumRetainedVerifiedEntries else {
            recordCapacityFailure(
                .retainedVerifiedEntryCount(
                    maximum: capacity.maximumRetainedVerifiedEntries
                ),
                state: &state,
                usage: &usage
            )
            return false
        }
        guard
            entryByteCount
                <= capacity.maximumRetainedVerifiedEntryBytes
                - state.retainedVerifiedEntryByteCount
        else {
            recordCapacityFailure(
                .retainedVerifiedEntryBytes(
                    maximum: capacity.maximumRetainedVerifiedEntryBytes
                ),
                state: &state,
                usage: &usage
            )
            return false
        }
        state.verifiedEntries.append(entry)
        state.retainedVerifiedEntryByteCount += entryByteCount
        return true
    }

    private func recordEnumerationErrors(
        _ errorDrain: DirectoryEnumerationErrorDrain,
        state: inout TraversalState,
        usage: inout MutableQuantumUsage
    ) -> Bool {
        for record in errorDrain.records {
            state.directoryTraversalFailureCount += 1
            if recordFailure(
                .directoryTraversalFailed(
                    directoryPath: record.url,
                    detail: record.detail
                ),
                state: &state,
                usage: &usage
            ) {
                return true
            }
        }
        if errorDrain.stoppedForLimit {
            recordCapacityFailure(
                .retainedFailureCount(maximum: capacity.maximumRetainedFailures),
                state: &state,
                usage: &usage
            )
            return true
        }
        return false
    }

    func recordFailure(
        _ failure: ScanFailureReason,
        state: inout TraversalState,
        usage: inout MutableQuantumUsage
    ) -> Bool {
        usage.failureCount += 1
        guard state.failures.count < capacity.maximumRetainedFailures else {
            let capacityFailure = ScanFailureReason.sessionCapacityExceeded(
                .retainedFailureCount(maximum: capacity.maximumRetainedFailures)
            )
            if state.failures.isEmpty {
                state.failures.append(capacityFailure)
            } else {
                state.failures[state.failures.index(before: state.failures.endIndex)] =
                    capacityFailure
            }
            return true
        }
        state.failures.append(failure)
        return false
    }

    private func recordCapacityFailure(
        _ dimension: RepoScannerSessionCapacityDimension,
        state: inout TraversalState,
        usage: inout MutableQuantumUsage
    ) {
        _ = recordFailure(
            .sessionCapacityExceeded(dimension),
            state: &state,
            usage: &usage
        )
    }

    func shouldSuspendBeforeValidation<ServiceClock: Clock<Duration>>(
        usage: MutableQuantumUsage,
        serviceClock: ServiceClock,
        serviceStartedAt: ServiceClock.Instant
    ) -> Bool {
        usage.candidateValidationCount >= quantumBudget.maximumCandidateValidations
            || serviceStartedAt.duration(to: serviceClock.now)
                >= quantumBudget.maximumActiveServiceDuration
    }

    private func quantumLimitReached(
        usage: MutableQuantumUsage,
        elapsed: Duration
    ) -> Bool {
        usage.enumeratedItemCount >= quantumBudget.maximumEnumeratedItems
            || usage.enumeratedPathByteCount >= quantumBudget.maximumPathBytes
            || usage.candidateValidationCount >= quantumBudget.maximumCandidateValidations
            || usage.failureCount >= quantumBudget.maximumFailures
            || elapsed >= quantumBudget.maximumActiveServiceDuration
    }

    private func cancellationRequested() -> Bool {
        lifecycle.withLock { lifecycle in
            if case .leased(let cancellationRequested, _) = lifecycle {
                return cancellationRequested
            }
            return true
        }
    }

    static func isMissingFileError(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    private func makeEnumerationCursor(
        rootURL: URL,
        maximumBufferedErrors: Int
    ) -> EnumerationCursorAvailability {
        let errorBuffer = DirectoryEnumerationErrorBuffer(
            maximumBufferedErrors: maximumBufferedErrors
        )
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    errorBuffer.record(url: url, error: error)
                }
            )
        else {
            return .unavailable("FileManager could not create a directory enumerator")
        }
        return .available(
            EnumerationCursor(enumerator: enumerator, errorBuffer: errorBuffer)
        )
    }

    func inspectGitMarker(at directoryURL: URL) -> GitMarkerInspection {
        let gitMarkerURL = directoryURL.appending(path: ".git")
        do {
            _ = try gitMarkerURL.resourceValues(forKeys: [.isDirectoryKey])
            return .candidate
        } catch let error as CocoaError where Self.isMissingFileError(error) {
            return .notCandidate
        } catch {
            return .failed(String(describing: error))
        }
    }

    private static func retainedByteCount(for entry: ResolvedGitEntry) -> Int {
        var byteCount = entry.path.path.utf8.count + entry.repositoryKey.utf8.count
        if case .linkedWorktree(let parentClonePath) = entry.kind {
            byteCount += parentClonePath.path.utf8.count
        }
        return byteCount
    }
}
