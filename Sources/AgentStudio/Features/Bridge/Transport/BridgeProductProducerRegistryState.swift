import Foundation

struct BridgeProductMetadataProducerKey: Equatable {
    let expectedResumeDisposition: BridgeProductMetadataStreamResumeDisposition
    let request: BridgeProductMetadataStreamRequest
}

enum BridgeProductProducerKey: Equatable {
    case metadata(BridgeProductMetadataProducerKey)
    case content(BridgeProductContentRequest)

    var isContent: Bool {
        guard case .content = self else { return false }
        return true
    }

    var maximumAdmittedSequence: Int {
        switch self {
        case .metadata:
            BridgeProductWireContract.maximumSafeInteger
        case .content:
            Int(UInt32.max)
        }
    }
}

enum BridgeProductProducerWorkLifecycle: Equatable {
    case running
    case stopped
    case stopping
}

enum BridgeProductProducerEnqueueIntent {
    case nonterminal
    case requiredOpening
    case terminal
}

struct BridgeProductProducerState {
    let key: BridgeProductProducerKey
    let metadataStreamSequenceRewindFloor: Int?
    var nextMetadataStreamSequence: Int?
    var task: Task<Void, Never>?
    var lifecycle = BridgeProductProducerWorkLifecycle.running
    var openingFrameState = BridgeProductProducerOpeningFrameState.required
    var queuedFrames: [BridgeProductQueuedProducerFrame] = []
    var queuedByteCount = 0
    var nextContentSequence = 0
    var terminalFrameAdmitted = false
    var terminalFrameConsumed = false
    var frameWaiterToken: UUID?
    var inFlightFrameReceipt: BridgeProductProducerFrameReceipt?
}

enum BridgeProductProducerFramePullPreparation {
    case finished
    case frame(BridgeProductProducerFrameDelivery)
    case rejected(BridgeProductProducerFramePullRejection)
    case wait(waiterToken: UUID)
}

struct BridgeProductProducerFrameWaiterResolution {
    let result: BridgeProductProducerFramePullResult
    let waiterToken: UUID
}

extension BridgeProductProducerRegistry {
    mutating func prepareFramePull(
        for lease: BridgeProductProducerLease,
        waiterToken: UUID
    ) -> BridgeProductProducerFramePullPreparation {
        guard var state = producersByLeaseId[lease.id] else {
            return .rejected(.unknownLease)
        }
        guard state.frameWaiterToken == nil else {
            return .rejected(.waiterAlreadyRegistered)
        }
        guard state.inFlightFrameReceipt == nil else {
            return .rejected(.receiptInFlight)
        }
        if let frame = state.queuedFrames.first {
            let delivery = claimFrame(frame, lease: lease, state: &state)
            producersByLeaseId[lease.id] = state
            return .frame(delivery)
        }
        guard state.lifecycle != .stopped else {
            return state.terminalFrameConsumed
                ? .finished
                : .rejected(.producerEndedWithoutTerminal)
        }
        state.frameWaiterToken = waiterToken
        producersByLeaseId[lease.id] = state
        return .wait(waiterToken: waiterToken)
    }

    mutating func resolveFrameWaiterIfPossible(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductProducerFrameWaiterResolution? {
        guard var state = producersByLeaseId[lease.id],
            let waiterToken = state.frameWaiterToken,
            state.inFlightFrameReceipt == nil
        else {
            return nil
        }
        let result: BridgeProductProducerFramePullResult
        if let frame = state.queuedFrames.first {
            state.frameWaiterToken = nil
            result = .frame(claimFrame(frame, lease: lease, state: &state))
        } else if state.lifecycle == .stopped, state.terminalFrameConsumed {
            state.frameWaiterToken = nil
            result = .finished
        } else if state.lifecycle == .stopped {
            state.frameWaiterToken = nil
            result = .rejected(.producerEndedWithoutTerminal)
        } else {
            return nil
        }
        producersByLeaseId[lease.id] = state
        return .init(result: result, waiterToken: waiterToken)
    }

    mutating func cancelFrameWaiter(
        for lease: BridgeProductProducerLease,
        waiterToken: UUID
    ) -> Bool {
        guard var state = producersByLeaseId[lease.id],
            state.frameWaiterToken == waiterToken
        else {
            return false
        }
        state.frameWaiterToken = nil
        producersByLeaseId[lease.id] = state
        return true
    }

    mutating func acknowledgeFrameConsumed(
        _ receipt: BridgeProductProducerFrameReceipt
    ) -> Bool {
        let lease = receipt.producerLease
        guard var state = producersByLeaseId[lease.id],
            state.inFlightFrameReceipt == receipt,
            state.queuedFrames.first?.sequence == receipt.sequence
        else {
            return false
        }
        let frame = state.queuedFrames.removeFirst()
        state.queuedByteCount -= frame.data.count
        state.inFlightFrameReceipt = nil
        state.terminalFrameConsumed = state.terminalFrameConsumed || frame.terminal
        if frame.requiredOpening {
            state.openingFrameState = .delivered
        }
        producersByLeaseId[lease.id] = state
        return true
    }

    mutating func abandonFrameDelivery(
        for lease: BridgeProductProducerLease
    ) -> UUID? {
        guard var state = producersByLeaseId[lease.id] else { return nil }
        let waiterToken = state.frameWaiterToken
        state.frameWaiterToken = nil
        state.inFlightFrameReceipt = nil
        producersByLeaseId[lease.id] = state
        return waiterToken
    }

    private func claimFrame(
        _ frame: BridgeProductQueuedProducerFrame,
        lease: BridgeProductProducerLease,
        state: inout BridgeProductProducerState
    ) -> BridgeProductProducerFrameDelivery {
        let receipt = BridgeProductProducerFrameReceipt(
            producerLease: lease,
            sequence: frame.sequence,
            nonce: UUID()
        )
        state.inFlightFrameReceipt = receipt
        return .init(frame: frame, receipt: receipt)
    }
}
