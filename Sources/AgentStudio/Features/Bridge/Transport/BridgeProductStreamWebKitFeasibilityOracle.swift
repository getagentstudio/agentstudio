import Foundation

package actor BridgeProductStreamWebKitFeasibilityOracle {
    private let configuration: BridgeProductStreamWebKitFeasibilityConfiguration
    private enum ProducerLifecycle {
        case acceptingFrames
        case terminalFrameAdmitted(sequence: Int)
        case workFinished(cancelled: Bool)

        var isWorkFinished: Bool {
            if case .workFinished = self { return true }
            return false
        }

        var finishedByCancellation: Bool {
            if case .workFinished(cancelled: true) = self { return true }
            return false
        }
    }

    private struct ProducerState {
        let task: Task<Void, Never>
        var queuedSequences: [Int] = []
        var lifecycle = ProducerLifecycle.acceptingFrames
    }

    private struct ProofGateResults {
        let authenticationBeforeBodySucceeded: Bool
        let bodyCapBeforeDecodeSucceeded: Bool
        let strictRouteDecodeSucceeded: Bool
        let missingContentLengthAccepted: Bool
        let exactRequestBodyBytesSucceeded: Bool
        let nearCapRequestBodySucceeded: Bool
    }

    private var rejections: [BridgeProductStreamWebKitFeasibilityRejection] = []
    private var bodyReadCount = 0
    private var bodyReadByteCount = 0
    private var decodeCallCount = 0
    private var providerCallCount = 0
    private var unauthorizedBodyReadCount = 0
    private var acceptedProductRequestCount = 0
    private var validBodyByteCount = 0
    private var firstFrameByteCount = 0
    private var validStreamEnded = false
    private var workerStartPostObserved = false
    private var workerObservedExactFrames = false
    private var workerObservedIncrementalFrames = false
    private var workerObservedCancellation = false
    private var frameReceipts: [BridgeWebKitFeasibilityFrameReceipt] = []
    private var emittedFrames: Set<BridgeWebKitFeasibilityFrameReceipt> = []
    private var cancellationOrder: [BridgeWebKitFeasibilityCancellationEvent] = []
    private var requestAPIObservations: [BridgeWebKitRequestAPIObservation] = []
    private var workerNearCapTiming = BridgeWebKitNearCapTimingResult.empty
    private var producers: [BridgeWebKitFeasibilityProducerKind: ProducerState] = [:]
    private var terminalProducers: Set<BridgeWebKitFeasibilityProducerKind> = []
    private var maximumQueuedFrameCount = 0
    private var producerOverflowCount = 0
    private var postTerminalFrameCount = 0
    private var nextWaiterID: UInt64 = 0
    private var frameWaiters: [BridgeWebKitFeasibilityFrameReceipt: [UInt64: CheckedContinuation<Bool, Never>]] = [:]
    private var zeroResidueWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

    package init(configuration: BridgeProductStreamWebKitFeasibilityConfiguration = .productContract) {
        self.configuration = configuration
    }

    func recordRequestAPIObservation(_ observation: BridgeWebKitRequestAPIObservation) {
        requestAPIObservations.append(observation)
        if case .rejected(let rejection) = observation.admissionOutcome {
            rejections.append(rejection)
        } else {
            acceptedProductRequestCount += 1
            validBodyByteCount = max(validBodyByteCount, observation.bodyByteCount)
        }
        if observation.bodySource == .httpBody || observation.bodySource == .httpBodyStream {
            bodyReadCount += 1
            bodyReadByteCount += observation.bodyByteCount
            if observation.capabilityHeaderState != .matches {
                unauthorizedBodyReadCount += 1
            }
        }
        decodeCallCount += observation.decodeCallCount
        providerCallCount += observation.providerCallCount
    }

    func recordWorkerStartPost() {
        workerStartPostObserved = true
    }

    func registerProducer(
        _ producer: BridgeWebKitFeasibilityProducerKind,
        task: Task<Void, Never>
    ) -> Bool {
        guard producers[producer] == nil, !terminalProducers.contains(producer) else { return false }
        producers[producer] = ProducerState(task: task)
        return true
    }

    func enqueueFrame(
        producer: BridgeWebKitFeasibilityProducerKind,
        sequence: Int,
        terminal: Bool
    ) -> Bool {
        guard var state = producers[producer], case .acceptingFrames = state.lifecycle else {
            postTerminalFrameCount += 1
            return false
        }
        let nonTerminalLimit =
            BridgeProductStreamWebKitFeasibilityPolicy.producerQueueCapacity
            - BridgeProductStreamWebKitFeasibilityPolicy.producerTerminalReserve
        let limit = terminal ? BridgeProductStreamWebKitFeasibilityPolicy.producerQueueCapacity : nonTerminalLimit
        guard state.queuedSequences.count < limit else {
            producerOverflowCount += 1
            return false
        }
        state.queuedSequences.append(sequence)
        if terminal {
            state.lifecycle = .terminalFrameAdmitted(sequence: sequence)
        }
        producers[producer] = state
        maximumQueuedFrameCount = max(maximumQueuedFrameCount, totalQueuedFrameCount)
        return true
    }

    func recordFrameYielded(producer: BridgeWebKitFeasibilityProducerKind, sequence: Int) -> Bool {
        guard var state = producers[producer], state.queuedSequences.first == sequence else { return false }
        state.queuedSequences.removeFirst()
        producers[producer] = state
        emittedFrames.insert(.init(producer: producer, sequence: sequence))
        return true
    }

    func recordFrameObserved(_ receipt: BridgeWebKitFeasibilityFrameReceipt) -> Bool {
        guard emittedFrames.contains(receipt), !frameReceipts.contains(receipt) else { return false }
        let expectedSequence = frameReceipts.filter { $0.producer == receipt.producer }.count
        guard receipt.sequence == expectedSequence else { return false }
        frameReceipts.append(receipt)
        let waiters = frameWaiters.removeValue(forKey: receipt)?.values ?? [:].values
        for waiter in waiters {
            waiter.resume(returning: true)
        }
        return true
    }

    func waitUntilFrameObserved(_ receipt: BridgeWebKitFeasibilityFrameReceipt) async -> Bool {
        if frameReceipts.contains(receipt) { return true }
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if frameReceipts.contains(receipt) {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    frameWaiters[receipt, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelFrameWaiter(receipt: receipt, waiterID: waiterID) }
        }
    }

    func finishProducerWork(
        _ producer: BridgeWebKitFeasibilityProducerKind,
        cancelled: Bool
    ) {
        guard var state = producers[producer], !state.lifecycle.isWorkFinished else { return }
        state.queuedSequences.removeAll(keepingCapacity: false)
        state.lifecycle = .workFinished(cancelled: cancelled)
        producers[producer] = state
        if cancelled {
            cancellationOrder.append(.producerStopped)
        }
    }

    func unregisterFinishedProducer(_ producer: BridgeWebKitFeasibilityProducerKind) {
        guard let state = producers[producer], state.lifecycle.isWorkFinished else { return }
        producers.removeValue(forKey: producer)
        terminalProducers.insert(producer)
        if state.lifecycle.finishedByCancellation {
            cancellationOrder.append(.producerUnregistered)
        }
        resumeZeroResidueWaitersIfNeeded()
    }

    func finalizeProducerRegistration(
        _ producer: BridgeWebKitFeasibilityProducerKind,
        cancelled: Bool
    ) {
        finishProducerWork(producer, cancelled: cancelled)
        unregisterFinishedProducer(producer)
    }

    func waitUntilZeroProducerResidue() async -> Bool {
        if hasZeroProducerResidue { return true }
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasZeroProducerResidue {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    zeroResidueWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelZeroResidueWaiter(waiterID) }
        }
    }

    func recordCompletedStream(firstFrameByteCount: Int) {
        self.firstFrameByteCount = firstFrameByteCount
        validStreamEnded = true
    }

    func recordWorkerResult(
        exactFrames: Bool,
        incrementalFrames: Bool,
        cancellationObserved: Bool,
        nearCapTiming: BridgeWebKitNearCapTimingResult
    ) {
        workerObservedExactFrames = exactFrames
        workerObservedIncrementalFrames = incrementalFrames
        workerObservedCancellation = cancellationObserved
        workerNearCapTiming = nearCapTiming
    }

    package func recordWorkerResultAcknowledged() -> Bool {
        if cancellationOrder.last == .resultAcknowledged { return true }
        guard workerResultSucceeded,
            cancellationOrder == [.producerStopped, .producerUnregistered],
            hasZeroProducerResidue
        else {
            return false
        }
        cancellationOrder.append(.resultAcknowledged)
        return true
    }

    package func isComplete() -> Bool {
        workerResultSucceeded
            && cancellationOrder
                == [.producerStopped, .producerUnregistered, .resultAcknowledged]
            && hasZeroProducerResidue
    }

    private var workerResultSucceeded: Bool {
        workerObservedExactFrames
            && workerObservedIncrementalFrames
            && workerObservedCancellation
    }

    func snapshot() -> BridgeProductStreamWebKitFeasibilitySnapshot {
        BridgeProductStreamWebKitFeasibilitySnapshot(
            rejections: rejections,
            bodyReadCount: bodyReadCount,
            bodyReadByteCount: bodyReadByteCount,
            decodeCallCount: decodeCallCount,
            providerCallCount: providerCallCount,
            unauthorizedBodyReadCount: unauthorizedBodyReadCount,
            acceptedProductRequestCount: acceptedProductRequestCount,
            validBodyByteCount: validBodyByteCount,
            firstFrameByteCount: firstFrameByteCount,
            validStreamEnded: validStreamEnded,
            workerStartPostObserved: workerStartPostObserved,
            workerObservedExactFrames: workerObservedExactFrames,
            workerObservedIncrementalFrames: workerObservedIncrementalFrames,
            workerObservedCancellation: workerObservedCancellation,
            frameReceipts: frameReceipts,
            cancellationOrder: cancellationOrder,
            requestAPIObservations: requestAPIObservations,
            workerNearCapTiming: workerNearCapTiming,
            producers: producerSnapshot
        )
    }

    package func proof(timedOut: Bool) -> BridgeProductStreamWebKitFeasibilityProof {
        let snapshot = snapshot()
        let gates = ProofGateResults(
            authenticationBeforeBodySucceeded: Self.authenticationBeforeBodySucceeded(snapshot),
            bodyCapBeforeDecodeSucceeded: Self.bodyCapBeforeDecodeSucceeded(
                snapshot,
                maximumRequestBodyBytes: configuration.maximumRequestBodyBytes
            ),
            strictRouteDecodeSucceeded: Self.strictRouteDecodeSucceeded(snapshot),
            missingContentLengthAccepted: Self.missingContentLengthAccepted(
                snapshot,
                configuration: configuration
            ),
            exactRequestBodyBytesSucceeded: snapshot.requestAPIObservations
                .filter { $0.admissionOutcome == .accepted }
                .allSatisfy(\.bodyBytesExact),
            nearCapRequestBodySucceeded: Self.nearCapRequestBodySucceeded(
                snapshot,
                configuration: configuration
            )
        )
        let measuredNearCapObservations = snapshot.requestAPIObservations.filter {
            $0.route == "/near-cap" && $0.nearCapMeasurementPhase == .measured
                && $0.admissionOutcome == .accepted
        }
        let workerEncodeTiming = BridgeWebKitTimingSummary(
            samples: snapshot.workerNearCapTiming.workerEncodeDurationsMicroseconds)
        let workerFetchCompletionTiming = BridgeWebKitTimingSummary(
            samples: snapshot.workerNearCapTiming.workerFetchCompletionDurationsMicroseconds)
        let swiftAdmissionTiming = BridgeWebKitTimingSummary(
            samples: measuredNearCapObservations.map(\.admissionDurationMicroseconds))
        let swiftDecodeTiming = BridgeWebKitTimingSummary(
            samples: measuredNearCapObservations.map(\.decodeDurationMicroseconds))
        let failureReason = Self.failureReason(timedOut: timedOut, snapshot: snapshot, gates: gates)

        return BridgeProductStreamWebKitFeasibilityProof(
            authenticationBeforeBodySucceeded: gates.authenticationBeforeBodySucceeded,
            bodyCapBeforeDecodeSucceeded: gates.bodyCapBeforeDecodeSucceeded,
            strictRouteDecodeSucceeded: gates.strictRouteDecodeSucceeded,
            missingContentLengthAccepted: gates.missingContentLengthAccepted,
            exactRequestBodyBytesSucceeded: gates.exactRequestBodyBytesSucceeded,
            nearCapRequestBodySucceeded: gates.nearCapRequestBodySucceeded,
            nearCapBodyByteCount: snapshot.workerNearCapTiming.bodyByteCount,
            nearCapWarmupRequestCount: snapshot.workerNearCapTiming.warmupRequestCount,
            nearCapMeasuredRequestCount: snapshot.workerNearCapTiming.measuredRequestCount,
            workerEncodeTiming: workerEncodeTiming,
            workerFetchCompletionTiming: workerFetchCompletionTiming,
            swiftAdmissionTiming: swiftAdmissionTiming,
            swiftDecodeTiming: swiftDecodeTiming,
            bodyReadCount: snapshot.bodyReadCount,
            bodyReadByteCount: snapshot.bodyReadByteCount,
            decodeCallCount: snapshot.decodeCallCount,
            providerCallCount: snapshot.providerCallCount,
            unauthorizedBodyReadCount: snapshot.unauthorizedBodyReadCount,
            validBodyByteCount: snapshot.validBodyByteCount,
            firstFrameByteCount: snapshot.firstFrameByteCount,
            validStreamEnded: snapshot.validStreamEnded,
            workerStartPostObserved: snapshot.workerStartPostObserved,
            workerObservedExactFrames: snapshot.workerObservedExactFrames,
            workerObservedIncrementalFrames: snapshot.workerObservedIncrementalFrames,
            workerObservedCancellation: snapshot.workerObservedCancellation,
            frameReceiptCount: snapshot.frameReceipts.count,
            cancellationOrder: snapshot.cancellationOrder,
            activeProducerCount: snapshot.producers.activeProducerCount,
            activeProducerTaskCount: snapshot.producers.activeProducerTaskCount,
            queuedFrameCount: snapshot.producers.queuedFrameCount,
            maximumQueuedFrameCount: snapshot.producers.maximumQueuedFrameCount,
            producerOverflowCount: snapshot.producers.producerOverflowCount,
            postTerminalFrameCount: snapshot.producers.postTerminalFrameCount,
            requestAPIObservations: snapshot.requestAPIObservations,
            failureReason: failureReason,
            diagnosticSnapshot: snapshot
        )
    }

    private static func failureReason(
        timedOut: Bool,
        snapshot: BridgeProductStreamWebKitFeasibilitySnapshot,
        gates: ProofGateResults
    ) -> String {
        if timedOut, !snapshot.workerStartPostObserved {
            "worker_not_started"
        } else if timedOut {
            "product_stream_probe_timeout"
        } else if !gates.authenticationBeforeBodySucceeded {
            "authentication_before_body_failed"
        } else if !gates.bodyCapBeforeDecodeSucceeded {
            "body_cap_before_decode_failed"
        } else if !gates.strictRouteDecodeSucceeded {
            "strict_route_decode_failed"
        } else if !gates.missingContentLengthAccepted {
            "missing_content_length_rejected"
        } else if !gates.exactRequestBodyBytesSucceeded {
            "request_body_bytes_changed"
        } else if !gates.nearCapRequestBodySucceeded {
            "near_cap_request_body_failed"
        } else if !snapshot.validStreamEnded || !snapshot.workerObservedExactFrames
            || !snapshot.workerObservedIncrementalFrames
        {
            "incremental_framed_stream_failed"
        } else if snapshot.cancellationOrder
            != [.producerStopped, .producerUnregistered, .resultAcknowledged]
            || !snapshot.workerObservedCancellation
        {
            "abort_causal_teardown_failed"
        } else if snapshot.producers.activeProducerCount != 0
            || snapshot.producers.activeProducerTaskCount != 0
            || snapshot.producers.queuedFrameCount != 0
            || snapshot.producers.producerOverflowCount != 0
            || snapshot.producers.postTerminalFrameCount != 0
        {
            "producer_residue_failed"
        } else {
            "none"
        }
    }

    private var totalQueuedFrameCount: Int {
        producers.values.reduce(into: 0) { $0 += $1.queuedSequences.count }
    }

    private var hasZeroProducerResidue: Bool {
        producers.isEmpty && totalQueuedFrameCount == 0
    }

    private var producerSnapshot: BridgeWebKitFeasibilityProducerSnapshot {
        let activeTasks = producers.values.compactMap { state in
            state.lifecycle.isWorkFinished ? nil : state.task
        }
        return BridgeWebKitFeasibilityProducerSnapshot(
            activeProducerCount: producers.count,
            activeProducerTaskCount: activeTasks.count,
            queuedFrameCount: totalQueuedFrameCount,
            maximumQueuedFrameCount: maximumQueuedFrameCount,
            producerOverflowCount: producerOverflowCount,
            postTerminalFrameCount: postTerminalFrameCount
        )
    }

    private func cancelFrameWaiter(receipt: BridgeWebKitFeasibilityFrameReceipt, waiterID: UInt64) {
        guard let waiter = frameWaiters[receipt]?.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: false)
    }

    private func cancelZeroResidueWaiter(_ waiterID: UInt64) {
        guard let waiter = zeroResidueWaiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: false)
    }

    private func resumeZeroResidueWaitersIfNeeded() {
        guard hasZeroProducerResidue else { return }
        let waiters = zeroResidueWaiters.values
        zeroResidueWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    private static func authenticationBeforeBodySucceeded(
        _ snapshot: BridgeProductStreamWebKitFeasibilitySnapshot
    ) -> Bool {
        let missing = snapshot.requestAPIObservations.contains {
            $0.route == "/missing-capability" && $0.capabilityHeaderState == .missing
                && $0.bodySource == .unread && $0.admissionOutcome == .rejected(.missingCapability)
        }
        let wrong = snapshot.requestAPIObservations.contains {
            $0.route == "/wrong-capability" && $0.capabilityHeaderState == .mismatch
                && $0.bodySource == .unread && $0.admissionOutcome == .rejected(.wrongCapability)
        }
        return missing && wrong && snapshot.unauthorizedBodyReadCount == 0
    }

    private static func bodyCapBeforeDecodeSucceeded(
        _ snapshot: BridgeProductStreamWebKitFeasibilitySnapshot,
        maximumRequestBodyBytes: Int
    ) -> Bool {
        snapshot.requestAPIObservations.contains {
            $0.route == "/oversized-body" && $0.capabilityHeaderState == .matches
                && $0.bodyByteCount == maximumRequestBodyBytes + 1
                && $0.decodeCallCount == 0 && $0.providerCallCount == 0
                && $0.admissionOutcome == .rejected(.oversizedBody)
        }
    }

    private static func strictRouteDecodeSucceeded(
        _ snapshot: BridgeProductStreamWebKitFeasibilitySnapshot
    ) -> Bool {
        let routeMismatch = snapshot.requestAPIObservations.contains {
            $0.route == "/route-mismatch" && $0.decodeCallCount == 1 && $0.providerCallCount == 0
                && $0.admissionOutcome == .rejected(.routeBodyMismatch)
        }
        let unknownKey = snapshot.requestAPIObservations.contains {
            $0.route == "/strict-extra" && $0.decodeCallCount == 1 && $0.providerCallCount == 0
                && $0.admissionOutcome == .rejected(.invalidBody)
        }
        return routeMismatch && unknownKey
    }

    private static func missingContentLengthAccepted(
        _ snapshot: BridgeProductStreamWebKitFeasibilitySnapshot,
        configuration: BridgeProductStreamWebKitFeasibilityConfiguration
    ) -> Bool {
        var requiredRoutes = Set(["/worker-started", "/stream", "/cancel-stream", "/observed", "/result"])
        if configuration.requiresNearCapTimingProbe {
            requiredRoutes.insert("/near-cap")
        }
        let acceptedRoutes = Set(
            snapshot.requestAPIObservations.compactMap { observation -> String? in
                guard requiredRoutes.contains(observation.route),
                    observation.declaredLengthHeaderState == .missing,
                    observation.admissionOutcome == .accepted
                else { return nil }
                return observation.route
            })
        return acceptedRoutes == requiredRoutes
    }

    private static func nearCapRequestBodySucceeded(
        _ snapshot: BridgeProductStreamWebKitFeasibilitySnapshot,
        configuration: BridgeProductStreamWebKitFeasibilityConfiguration
    ) -> Bool {
        let nearCapObservations = snapshot.requestAPIObservations.filter { $0.route == "/near-cap" }
        guard configuration.requiresNearCapTimingProbe else {
            return nearCapObservations.isEmpty && snapshot.workerNearCapTiming == .empty
        }

        let expectedRequestCount =
            configuration.nearCapWarmupRequestCount + configuration.nearCapMeasuredRequestCount
        guard nearCapObservations.count == expectedRequestCount,
            snapshot.workerNearCapTiming.bodyByteCount == configuration.maximumRequestBodyBytes,
            snapshot.workerNearCapTiming.warmupRequestCount == configuration.nearCapWarmupRequestCount,
            snapshot.workerNearCapTiming.measuredRequestCount == configuration.nearCapMeasuredRequestCount,
            snapshot.workerNearCapTiming.workerEncodeDurationsMicroseconds.count
                == configuration.nearCapMeasuredRequestCount,
            snapshot.workerNearCapTiming.workerFetchCompletionDurationsMicroseconds.count
                == configuration.nearCapMeasuredRequestCount
        else { return false }

        let warmupIndexes = nearCapObservations.compactMap { observation -> Int? in
            observation.nearCapMeasurementPhase == .warmup
                ? observation.nearCapMeasurementIndex : nil
        }
        let measuredIndexes = nearCapObservations.compactMap { observation -> Int? in
            observation.nearCapMeasurementPhase == .measured
                ? observation.nearCapMeasurementIndex : nil
        }
        guard warmupIndexes == Array(0..<configuration.nearCapWarmupRequestCount),
            measuredIndexes == Array(0..<configuration.nearCapMeasuredRequestCount)
        else { return false }

        return nearCapObservations.allSatisfy {
            $0.capabilityHeaderState == .matches
                && $0.declaredLengthHeaderState == .missing
                && ($0.bodySource == .httpBody || $0.bodySource == .httpBodyStream)
                && $0.bodyByteCount == configuration.maximumRequestBodyBytes
                && $0.decodeCallCount == 1
                && $0.providerCallCount == 1
                && $0.bodyBytesExact
                && $0.admissionOutcome == .accepted
        }
    }
}
