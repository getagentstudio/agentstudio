import Foundation

struct BridgeProductProducerRegistry {
    typealias ProducerOperation = @Sendable (BridgeProductProducerLease) async -> Void
    typealias ProducerCompletion = @Sendable (BridgeProductProducerLease) async -> Void
    typealias FrameBuilder = @Sendable (Int) throws -> BridgeProductProducerFrame

    struct StopRequest: Sendable {
        let lease: BridgeProductProducerLease
        let task: Task<Void, Never>?
    }

    private struct PendingLifecycleAcknowledgement {
        let acknowledgement: BridgeProductProducerLifecycleAcknowledgement
        let producerKey: BridgeProductProducerKey
    }

    private let limits: BridgeProductProducerQueueLimits
    let deadlineClock: any Clock<Duration> & Sendable
    var producersByLeaseId: [UUID: BridgeProductProducerState] = [:]
    private var pendingAcknowledgementsByLeaseId: [UUID: PendingLifecycleAcknowledgement] = [:]
    private var nextMetadataStreamSequence = 0
    private var isClosing = false
    private var isRevoked = false

    init(
        limits: BridgeProductProducerQueueLimits = .productContract,
        deadlineClock: any Clock<Duration> & Sendable = ContinuousClock()
    ) {
        self.limits = limits
        self.deadlineClock = deadlineClock
    }

    var metadataProducerLeases: [BridgeProductProducerLease] {
        let activeIds = producersByLeaseId.compactMap { id, state in
            state.key.isContent ? nil : id
        }
        let pendingIds = pendingAcknowledgementsByLeaseId.compactMap { id, pending in
            pending.producerKey.isContent ? nil : id
        }
        return Set(activeIds + pendingIds).map(BridgeProductProducerLease.init(id:))
    }

    func pendingMetadataFrameTarget(
        for lease: BridgeProductProducerLease
    ) -> (stream: BridgeProductMetadataStreamCorrelation, nextSequence: Int)? {
        guard let state = producersByLeaseId[lease.id],
            case .metadata(let metadataKey) = state.key,
            state.lifecycle == .running,
            state.openingFrameState != .required,
            !state.terminalFrameAdmitted
        else { return nil }
        return (metadataKey.request.correlation, nextSequence(for: state))
    }

    mutating func registerMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        operation: @escaping ProducerOperation,
        completion: @escaping ProducerCompletion
    ) -> BridgeProductProducerRegistration {
        let openingSequence = request.resumeFromStreamSequence.map { $0 + 1 } ?? 0
        guard openingSequence < BridgeProductWireContract.maximumSafeInteger else {
            return .rejected(.sequenceExhausted)
        }
        guard openingSequence <= nextMetadataStreamSequence else {
            return .rejected(
                .metadataResumeConflict(
                    nextMetadataStreamSequence: nextMetadataStreamSequence
                )
            )
        }
        let expectedResumeDisposition: BridgeProductMetadataStreamResumeDisposition =
            if request.resumeFromStreamSequence != nil,
                openingSequence == nextMetadataStreamSequence
            {
                .resumed
            } else {
                .snapshotRequired
            }
        return register(
            key: .metadata(
                .init(
                    expectedResumeDisposition: expectedResumeDisposition,
                    request: request
                )
            ),
            metadataStreamSequenceRewindFloor: nextMetadataStreamSequence,
            initialMetadataStreamSequence: openingSequence,
            operation: operation,
            completion: completion
        )
    }

    mutating func registerContentProducer(
        request: BridgeProductContentRequest,
        operation: @escaping ProducerOperation,
        completion: @escaping ProducerCompletion
    ) -> BridgeProductProducerRegistration {
        register(
            key: .content(request),
            metadataStreamSequenceRewindFloor: nil,
            initialMetadataStreamSequence: nil,
            operation: operation,
            completion: completion
        )
    }

    mutating func enqueueRequiredOpeningFrame(
        for lease: BridgeProductProducerLease,
        build: FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        guard var state = producersByLeaseId[lease.id] else {
            return .rejected(.unknownLease)
        }
        guard state.lifecycle == .running else {
            return .rejected(.lifecycleClosed)
        }
        guard state.openingFrameState == .required else {
            return .rejected(.openingFrameAlreadyAdmitted)
        }
        guard !state.terminalFrameAdmitted else {
            return .rejected(.terminalAlreadyAdmitted)
        }

        let sequence = nextSequence(for: state)
        guard sequence < state.key.maximumAdmittedSequence else {
            return .rejected(.sequenceExhausted)
        }
        let encodedFrame: BridgeProductValidatedProducerFrame
        do {
            encodedFrame = try BridgeProductProducerFrameValidator.encode(
                for: state.key,
                sequence: sequence,
                intent: .requiredOpening,
                build: build
            )
        } catch let validationError as BridgeProductProducerFrameValidationError {
            return .rejected(validationError.rejection)
        }
        if let rejection = frameSizeRejection(for: encodedFrame.data) {
            return .rejected(rejection)
        }
        let frame = BridgeProductQueuedProducerFrame(
            data: encodedFrame.data,
            sequence: sequence,
            terminal: false,
            requiredOpening: true,
            batchComplete: false
        )
        state.queuedFrames.append(frame)
        state.queuedByteCount = encodedFrame.data.count
        state.openingFrameState = .queued
        commitNextSequence(after: sequence, state: &state)
        producersByLeaseId[lease.id] = state
        return .enqueued(frame)
    }

    mutating func enqueueNonterminalFrame(
        for lease: BridgeProductProducerLease,
        build: FrameBuilder,
        overflowReset: FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        guard var state = producersByLeaseId[lease.id] else {
            return .rejected(.unknownLease)
        }
        guard state.lifecycle == .running else {
            return .rejected(.lifecycleClosed)
        }
        guard state.openingFrameState != .required else {
            return .rejected(.openingFrameRequired)
        }
        guard !state.terminalFrameAdmitted else {
            return .rejected(.terminalAlreadyAdmitted)
        }

        let candidateSequence = nextSequence(for: state)
        guard candidateSequence < state.key.maximumAdmittedSequence else {
            return .rejected(.sequenceExhausted)
        }
        let candidateFrame: BridgeProductValidatedProducerFrame
        do {
            candidateFrame = try BridgeProductProducerFrameValidator.encode(
                for: state.key,
                sequence: candidateSequence,
                intent: .nonterminal,
                build: build
            )
        } catch let validationError as BridgeProductProducerFrameValidationError {
            return .rejected(validationError.rejection)
        }
        if let rejection = frameSizeRejection(for: candidateFrame.data) {
            return .rejected(rejection)
        }
        let nonterminalFrameLimit = limits.maximumQueuedFrameCount - limits.terminalFrameReserve
        if state.queuedFrames.count < nonterminalFrameLimit,
            state.queuedByteCount + candidateFrame.data.count <= limits.maximumQueuedByteCount
        {
            return appendFrame(
                validatedFrame: candidateFrame,
                sequence: candidateSequence,
                terminal: false,
                lease: lease,
                state: &state
            )
        }
        guard state.openingFrameState == .delivered else {
            return .rejected(.closeRequired)
        }
        guard state.inFlightFrameReceipt == nil else {
            return .rejected(.closeRequired)
        }

        let replacementSequence = state.queuedFrames.first?.sequence ?? candidateSequence
        let resetFrame: BridgeProductValidatedProducerFrame
        do {
            resetFrame = try BridgeProductProducerFrameValidator.encode(
                for: state.key,
                sequence: replacementSequence,
                intent: .terminal,
                build: overflowReset
            )
        } catch let validationError as BridgeProductProducerFrameValidationError {
            return .rejected(validationError.rejection)
        }
        if let rejection = frameSizeRejection(for: resetFrame.data) {
            return .rejected(rejection)
        }
        return replaceQueueWithTerminal(
            validatedFrame: resetFrame,
            sequence: replacementSequence,
            lease: lease,
            state: &state
        )
    }

    mutating func enqueueTerminalFrame(
        for lease: BridgeProductProducerLease,
        build: FrameBuilder
    ) throws -> BridgeProductProducerEnqueueResult {
        guard var state = producersByLeaseId[lease.id] else {
            return .rejected(.unknownLease)
        }
        guard state.openingFrameState != .required else {
            return .rejected(.openingFrameRequired)
        }
        guard !state.terminalFrameAdmitted else {
            return .rejected(.terminalAlreadyAdmitted)
        }

        let candidateSequence = nextSequence(for: state)
        guard candidateSequence <= state.key.maximumAdmittedSequence else {
            return .rejected(.sequenceExhausted)
        }
        let candidateFrame: BridgeProductValidatedProducerFrame
        do {
            candidateFrame = try BridgeProductProducerFrameValidator.encode(
                for: state.key,
                sequence: candidateSequence,
                intent: .terminal,
                build: build
            )
        } catch let validationError as BridgeProductProducerFrameValidationError {
            return .rejected(validationError.rejection)
        }
        if let rejection = frameSizeRejection(for: candidateFrame.data) {
            return .rejected(rejection)
        }
        if state.queuedFrames.count < limits.maximumQueuedFrameCount,
            state.queuedByteCount + candidateFrame.data.count <= limits.maximumQueuedByteCount
        {
            return appendFrame(
                validatedFrame: candidateFrame,
                sequence: candidateSequence,
                terminal: true,
                lease: lease,
                state: &state
            )
        }
        guard state.openingFrameState == .delivered else {
            return .rejected(.closeRequired)
        }
        guard state.inFlightFrameReceipt == nil else {
            return .rejected(.closeRequired)
        }

        let replacementSequence = state.queuedFrames.first?.sequence ?? candidateSequence
        let replacementFrame: BridgeProductValidatedProducerFrame
        if replacementSequence == candidateSequence {
            replacementFrame = candidateFrame
        } else {
            do {
                replacementFrame = try BridgeProductProducerFrameValidator.encode(
                    for: state.key,
                    sequence: replacementSequence,
                    intent: .terminal,
                    build: build
                )
            } catch let validationError as BridgeProductProducerFrameValidationError {
                return .rejected(validationError.rejection)
            }
        }
        if let rejection = frameSizeRejection(for: replacementFrame.data) {
            return .rejected(rejection)
        }
        return replaceQueueWithTerminal(
            validatedFrame: replacementFrame,
            sequence: replacementSequence,
            lease: lease,
            state: &state
        )
    }

    func openingFrameState(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductProducerOpeningFrameState? {
        producersByLeaseId[lease.id]?.openingFrameState
    }

    mutating func requestStop(
        _ leases: [BridgeProductProducerLease]
    ) -> [StopRequest] {
        var seenLeaseIds: Set<UUID> = []
        var requests: [StopRequest] = []
        for lease in leases where seenLeaseIds.insert(lease.id).inserted {
            guard var state = producersByLeaseId[lease.id] else { continue }
            if state.lifecycle == .running {
                state.lifecycle = .stopping
                state.task?.cancel()
                producersByLeaseId[lease.id] = state
            }
            requests.append(.init(lease: lease, task: state.task))
        }
        return requests
    }

    mutating func requestStopEveryProducer(revoking: Bool) -> [StopRequest] {
        if revoking {
            isRevoked = true
        }
        isClosing = true
        let leases = producersByLeaseId.keys.map(BridgeProductProducerLease.init(id:))
        return requestStop(leases)
    }

    mutating func finishClosing() {
        if !isRevoked {
            isClosing = false
        }
    }

    mutating func producerOperationFinished(_ lease: BridgeProductProducerLease) {
        guard var state = producersByLeaseId[lease.id] else { return }
        state.lifecycle = .stopped
        state.task = nil
        producersByLeaseId[lease.id] = state
    }

    func producerIsStopped(_ lease: BridgeProductProducerLease) -> Bool {
        producersByLeaseId[lease.id]?.lifecycle == .stopped
    }

    func pendingLifecycleAcknowledgement(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductProducerLifecycleAcknowledgement? {
        pendingAcknowledgementsByLeaseId[lease.id]?.acknowledgement
    }

    func lifecycleResidueLeases() -> [BridgeProductProducerLease] {
        Set(producersByLeaseId.keys)
            .union(pendingAcknowledgementsByLeaseId.keys)
            .sorted { $0.uuidString < $1.uuidString }
            .map(BridgeProductProducerLease.init(id:))
    }

    func hasLifecycleResidue(for lease: BridgeProductProducerLease) -> Bool {
        producersByLeaseId[lease.id] != nil
            || pendingAcknowledgementsByLeaseId[lease.id] != nil
    }

    mutating func unregister(
        _ lease: BridgeProductProducerLease
    ) -> BridgeProductProducerLifecycleAcknowledgement? {
        guard let state = producersByLeaseId[lease.id], state.lifecycle == .stopped else {
            return nil
        }
        producersByLeaseId.removeValue(forKey: lease.id)
        let acknowledgement = BridgeProductProducerLifecycleAcknowledgement(
            producerLease: lease,
            nonce: UUID()
        )
        pendingAcknowledgementsByLeaseId[lease.id] = .init(
            acknowledgement: acknowledgement,
            producerKey: state.key
        )
        return acknowledgement
    }

    mutating func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) -> Bool {
        guard
            pendingAcknowledgementsByLeaseId[acknowledgement.producerLease.id]?.acknowledgement
                == acknowledgement
        else {
            return false
        }
        pendingAcknowledgementsByLeaseId.removeValue(forKey: acknowledgement.producerLease.id)
        return true
    }

    func snapshot() -> BridgeProductProducerRegistrySnapshot {
        let states = Array(producersByLeaseId.values)
        return BridgeProductProducerRegistrySnapshot(
            activeProducerCount: states.count,
            activeProducerTaskCount: states.count { $0.lifecycle != .stopped },
            activeContentLeaseCount: states.count { $0.key.isContent },
            contentProducerLifecycleResidueCount: contentProducerLifecycleResidueCount,
            queuedFrameCount: states.reduce(0) { $0 + $1.queuedFrames.count },
            queuedByteCount: states.reduce(0) { $0 + $1.queuedByteCount },
            pendingFrameWaiterCount: states.reduce(into: 0) { count, state in
                if state.frameWaiterToken != nil { count += 1 }
            },
            inFlightFrameReceiptCount: states.count { $0.inFlightFrameReceipt != nil },
            pendingLifecycleAcknowledgementCount: pendingAcknowledgementsByLeaseId.count,
            nextMetadataStreamSequence: nextMetadataStreamSequence,
            isRevoked: isRevoked,
            sessionContentAdmissionCount: 0,
            sessionProductAdmissionCount: 0
        )
    }

    private mutating func register(
        key: BridgeProductProducerKey,
        metadataStreamSequenceRewindFloor: Int?,
        initialMetadataStreamSequence: Int?,
        operation: @escaping ProducerOperation,
        completion: @escaping ProducerCompletion
    ) -> BridgeProductProducerRegistration {
        if isRevoked { return .rejected(.revoked) }
        if isClosing { return .rejected(.closing) }
        if hasDuplicateProducer(for: key) { return .rejected(.duplicate) }
        if key.isContent,
            contentProducerLifecycleResidueCount
                >= limits.maximumContentProducerLifecycleResidueCount
        {
            return .rejected(
                .contentProducerCapacityReached(
                    maximumLifecycleResidueCount:
                        limits.maximumContentProducerLifecycleResidueCount
                )
            )
        }

        let lease = BridgeProductProducerLease(id: UUID())
        producersByLeaseId[lease.id] = BridgeProductProducerState(
            key: key,
            metadataStreamSequenceRewindFloor: metadataStreamSequenceRewindFloor,
            nextMetadataStreamSequence: initialMetadataStreamSequence
        )
        let task = Task {
            await operation(lease)
            await completion(lease)
        }
        producersByLeaseId[lease.id]?.task = task
        return .accepted(lease)
    }

    private func hasDuplicateProducer(for candidateKey: BridgeProductProducerKey) -> Bool {
        producersByLeaseId.values.contains { state in
            Self.producerKeysMatch(state.key, candidateKey)
        }
            || pendingAcknowledgementsByLeaseId.values.contains { pending in
                Self.producerKeysMatch(pending.producerKey, candidateKey)
            }
    }

    private var contentProducerLifecycleResidueCount: Int {
        producersByLeaseId.values.count { $0.key.isContent }
            + pendingAcknowledgementsByLeaseId.values.count { $0.producerKey.isContent }
    }

    private static func producerKeysMatch(
        _ existingKey: BridgeProductProducerKey,
        _ candidateKey: BridgeProductProducerKey
    ) -> Bool {
        switch (existingKey, candidateKey) {
        case (.metadata, .metadata): true
        case (.content(let existing), .content(let candidate)): existing == candidate
        default: false
        }
    }

    private func nextSequence(for state: BridgeProductProducerState) -> Int {
        switch state.key {
        case .metadata:
            guard let nextMetadataStreamSequence = state.nextMetadataStreamSequence else {
                preconditionFailure("Metadata producers require a local sequence cursor")
            }
            return nextMetadataStreamSequence
        case .content: return state.nextContentSequence
        }
    }

    private mutating func commitNextSequence(
        after sequence: Int,
        state: inout BridgeProductProducerState
    ) {
        guard sequence < state.key.maximumAdmittedSequence else { return }
        switch state.key {
        case .metadata:
            let producerNextSequence = sequence + 1
            nextMetadataStreamSequence = max(
                nextMetadataStreamSequence,
                producerNextSequence
            )
            state.nextMetadataStreamSequence = producerNextSequence
        case .content:
            state.nextContentSequence = sequence + 1
        }
    }

    private func frameSizeRejection(for data: Data) -> BridgeProductProducerEnqueueRejection? {
        guard data.count <= limits.maximumEncodedFrameByteCount else {
            return .frameTooLarge(maximumEncodedByteCount: limits.maximumEncodedFrameByteCount)
        }
        return nil
    }

    private mutating func appendFrame(
        validatedFrame: BridgeProductValidatedProducerFrame,
        sequence: Int,
        terminal: Bool,
        lease: BridgeProductProducerLease,
        state: inout BridgeProductProducerState
    ) -> BridgeProductProducerEnqueueResult {
        let frame = BridgeProductQueuedProducerFrame(
            data: validatedFrame.data,
            sequence: sequence,
            terminal: terminal,
            requiredOpening: false,
            batchComplete: validatedFrame.batchComplete
        )
        state.queuedFrames.append(frame)
        state.queuedByteCount += validatedFrame.data.count
        state.terminalFrameAdmitted = terminal
        commitNextSequence(after: sequence, state: &state)
        producersByLeaseId[lease.id] = state
        return .enqueued(frame)
    }

    private mutating func replaceQueueWithTerminal(
        validatedFrame: BridgeProductValidatedProducerFrame,
        sequence: Int,
        lease: BridgeProductProducerLease,
        state: inout BridgeProductProducerState
    ) -> BridgeProductProducerEnqueueResult {
        let discardedFrameCount = state.queuedFrames.count
        let discardedByteCount = state.queuedByteCount
        let frame = BridgeProductQueuedProducerFrame(
            data: validatedFrame.data,
            sequence: sequence,
            terminal: true,
            requiredOpening: false,
            batchComplete: false
        )
        state.queuedFrames = [frame]
        state.queuedByteCount = validatedFrame.data.count
        state.terminalFrameAdmitted = true
        commitReplacementSequence(after: sequence, state: &state)
        producersByLeaseId[lease.id] = state
        return .queueReset(
            frame: frame,
            discardedFrameCount: discardedFrameCount,
            discardedByteCount: discardedByteCount
        )
    }

    private mutating func commitReplacementSequence(
        after sequence: Int,
        state: inout BridgeProductProducerState
    ) {
        guard sequence < state.key.maximumAdmittedSequence else { return }
        switch state.key {
        case .metadata:
            let replacementNextSequence = sequence + 1
            guard let rewindFloor = state.metadataStreamSequenceRewindFloor else {
                preconditionFailure("Metadata producers require a sequence rewind floor")
            }
            nextMetadataStreamSequence = max(rewindFloor, replacementNextSequence)
            state.nextMetadataStreamSequence = replacementNextSequence
        case .content:
            state.nextContentSequence = sequence + 1
        }
    }
}
