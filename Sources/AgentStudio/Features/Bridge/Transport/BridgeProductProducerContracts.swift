import Foundation

struct BridgeProductProducerLease: Hashable, Sendable {
    let id: UUID
}

enum BridgeProductProducerRegistrationRejection: Equatable, Sendable {
    case contentProducerCapacityReached(maximumLifecycleResidueCount: Int)
    case closing
    case duplicate
    case inactiveSession
    case metadataResumeConflict(nextMetadataStreamSequence: Int)
    case revoked
    case sequenceExhausted
    case staleSurfaceEpoch(currentFloor: Int)
    case staleWorker
}

enum BridgeProductProducerRegistration: Equatable, Sendable {
    case accepted(BridgeProductProducerLease)
    case rejected(BridgeProductProducerRegistrationRejection)
}

enum BridgeProductProducerOpeningFrameState: Equatable, Sendable {
    case delivered
    case queued
    case required
}

enum BridgeProductProducerFrame: Equatable, Sendable {
    case metadata(BridgeProductMetadataFrame)
    case content(BridgeProductContentFrame)

    var sequence: Int {
        switch self {
        case .metadata(let frame): frame.producerFrameIdentity.streamSequence
        case .content(let frame): frame.header.contentSequence
        }
    }

    var isRequiredOpening: Bool {
        switch self {
        case .metadata(.metadataStreamAccepted): true
        case .content(let frame):
            if case .accepted = frame.header { true } else { false }
        default:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .metadata(.metadataStreamError): true
        case .content(let frame):
            switch frame.header {
            case .end, .error, .reset: true
            case .accepted, .data: false
            }
        default:
            false
        }
    }

    func encode() throws -> Data {
        switch self {
        case .metadata(let frame): try BridgeProductMetadataFrameCodec.encode(frame)
        case .content(let frame): try BridgeProductContentFrameCodec.encode(frame)
        }
    }
}

struct BridgeProductQueuedProducerFrame: Equatable, Sendable {
    let data: Data
    let sequence: Int
    let terminal: Bool
    let requiredOpening: Bool
    let batchComplete: Bool
}

struct BridgeProductProducerFrameReceipt: Hashable, Sendable {
    let producerLease: BridgeProductProducerLease
    let sequence: Int
    let nonce: UUID
}

struct BridgeProductProducerFrameDelivery: Equatable, Sendable {
    let frame: BridgeProductQueuedProducerFrame
    let receipt: BridgeProductProducerFrameReceipt
}

enum BridgeProductProducerFramePullRejection: Equatable, Sendable {
    case producerEndedWithoutTerminal
    case receiptInFlight
    case retirementFailed
    case unknownLease
    case waiterAlreadyRegistered
}

enum BridgeProductProducerFramePullResult: Equatable, Sendable {
    case cancelled
    case finished
    case frame(BridgeProductProducerFrameDelivery)
    case rejected(BridgeProductProducerFramePullRejection)
}

enum BridgeProductProducerEnqueueRejection: Equatable, Sendable {
    case closeRequired
    case frameIdentityMismatch
    case frameKindMismatch
    case frameLifecycleMismatch
    case frameTooLarge(maximumEncodedByteCount: Int)
    case lifecycleClosed
    case openingFrameAlreadyAdmitted
    case openingFrameRequired
    case sequenceExhausted
    case terminalAlreadyAdmitted
    case unknownLease
}

enum BridgeProductProducerEnqueueResult: Equatable, Sendable {
    case enqueued(BridgeProductQueuedProducerFrame)
    case queueReset(
        frame: BridgeProductQueuedProducerFrame,
        discardedFrameCount: Int,
        discardedByteCount: Int
    )
    case rejected(BridgeProductProducerEnqueueRejection)
}

struct BridgeProductProducerLifecycleAcknowledgement: Hashable, Sendable {
    let producerLease: BridgeProductProducerLease
    let nonce: UUID
}

struct BridgeProductProducerRegistrySnapshot: Equatable, Sendable {
    let activeProducerCount: Int
    let activeProducerTaskCount: Int
    let activeContentLeaseCount: Int
    let contentProducerLifecycleResidueCount: Int
    let queuedFrameCount: Int
    let queuedByteCount: Int
    let pendingFrameWaiterCount: Int
    let inFlightFrameReceiptCount: Int
    let pendingLifecycleAcknowledgementCount: Int
    let nextMetadataStreamSequence: Int
    let isRevoked: Bool
    let sessionContentAdmissionCount: Int
    let sessionProductAdmissionCount: Int

    var hasZeroResidue: Bool {
        activeProducerCount == 0
            && activeProducerTaskCount == 0
            && activeContentLeaseCount == 0
            && queuedFrameCount == 0
            && queuedByteCount == 0
            && pendingFrameWaiterCount == 0
            && inFlightFrameReceiptCount == 0
            && pendingLifecycleAcknowledgementCount == 0
            && sessionContentAdmissionCount == 0
            && sessionProductAdmissionCount == 0
    }

    func includingSessionAdmissionResidue(
        contentAdmissionCount: Int,
        productAdmissionCount: Int
    ) -> Self {
        Self(
            activeProducerCount: activeProducerCount,
            activeProducerTaskCount: activeProducerTaskCount,
            activeContentLeaseCount: activeContentLeaseCount,
            contentProducerLifecycleResidueCount: contentProducerLifecycleResidueCount,
            queuedFrameCount: queuedFrameCount,
            queuedByteCount: queuedByteCount,
            pendingFrameWaiterCount: pendingFrameWaiterCount,
            inFlightFrameReceiptCount: inFlightFrameReceiptCount,
            pendingLifecycleAcknowledgementCount: pendingLifecycleAcknowledgementCount,
            nextMetadataStreamSequence: nextMetadataStreamSequence,
            isRevoked: isRevoked,
            sessionContentAdmissionCount: contentAdmissionCount,
            sessionProductAdmissionCount: productAdmissionCount
        )
    }
}

extension BridgeProductMetadataFrame {
    var producerFrameIdentity: BridgeProductMetadataFrameIdentity {
        switch self {
        case .metadataStreamAccepted(let frame): frame.frameIdentity
        case .streamKeepalive(let frame): frame.frameIdentity
        case .panePresentation(let frame): frame.frameIdentity
        case .paneSurfaceSelectionRequested(let frame): frame.frameIdentity
        case .subscriptionAccepted(let frame): frame.frameIdentity
        case .batch(let frame): frame.identity.frame
        case .subscriptionReset(let frame): frame.identity.frameIdentity
        case .subscriptionEnd(let frame): frame.identity.frameIdentity
        case .subscriptionCancelled(let frame): frame.identity.frameIdentity
        case .contentCancelled(let frame): frame.frameIdentity
        case .metadataStreamError(let frame): frame.frameIdentity
        }
    }
}
