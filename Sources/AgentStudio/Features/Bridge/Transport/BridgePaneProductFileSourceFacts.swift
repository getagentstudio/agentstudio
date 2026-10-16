import Foundation

/// Source notifications invalidate canonical keyed state; they are never wire envelopes.
enum BridgePaneProductFileSourceFact: Equatable, Sendable {
    case sourceAccepted(BridgeProductFileSourceIdentity)
    case inventoryProgress(BridgePaneProductFileInventoryProgress)
    case inventoryChanged(BridgePaneProductFileInventoryChange)
    case statusChanged(BridgeProductFileSourceIdentity)
    case descriptorReady(BridgeProductFileDescriptorReadyPayload)
    case invalidated(BridgePaneProductFileDescriptorInvalidation)

    var sourceIdentity: BridgeProductFileSourceIdentity {
        switch self {
        case .sourceAccepted(let source), .statusChanged(let source): source
        case .inventoryProgress(let progress): progress.source
        case .inventoryChanged(let change): change.source
        case .descriptorReady(let payload): payload.source
        case .invalidated(let invalidation): invalidation.source
        }
    }
}

struct BridgePaneProductFileInventoryProgress: Equatable, Sendable {
    let finalWindow: Bool
    let updatedPaths: Set<String>
    let source: BridgeProductFileSourceIdentity
}

struct BridgePaneProductFileInventoryChange: Equatable, Sendable {
    let updatedPaths: Set<String>
    let removedPaths: Set<String>
    let source: BridgeProductFileSourceIdentity
}

struct BridgePaneProductFileDescriptorInvalidation: Equatable, Sendable {
    let fileId: String?
    let path: String
    let reason: BridgeProductFileInvalidationReason
    let replacementDescriptor: BridgeProductFileDescriptorReadyPayload?
    let source: BridgeProductFileSourceIdentity

    init(
        fileId: String?, path: String, reason: BridgeProductFileInvalidationReason,
        replacementDescriptor: BridgeProductFileDescriptorReadyPayload?, source: BridgeProductFileSourceIdentity
    ) throws {
        if let fileId { try BridgeProductContractDecoding.validateIdentifier(fileId, codingPath: []) }
        try BridgeProductContractDecoding.validateDisplayPath(path, codingPath: [])
        self.fileId = fileId
        self.path = path
        self.reason = reason
        self.replacementDescriptor = replacementDescriptor
        self.source = source
    }
}

enum BridgeProductFileInvalidationReason: String, Equatable, Sendable {
    case filesystemEvent
    case gitStatusChanged
    case contentChanged
    case sourceReset
    case unknown
}
