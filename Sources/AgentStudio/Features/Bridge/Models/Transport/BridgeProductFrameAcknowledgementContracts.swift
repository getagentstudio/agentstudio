import Foundation

private enum ContentAcknowledgementCodingKeys: String, CodingKey, CaseIterable {
    case contentRequestId
    case kind
    case leaseId
    case paneSessionId
    case receivedThroughContentSequence
    case wireVersion
    case workerInstanceId
}

struct BridgeProductContentFrameAcknowledgement: Codable, Equatable, Sendable {
    let contentRequestId: String
    let receivedThroughContentSequence: Int
    let leaseId: String
    let paneSessionId: String
    let wireVersion: Int
    let workerInstanceId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(
                ContentAcknowledgementCodingKeys.allCases.map(\.rawValue)
            ),
            contract: "content.acknowledge request"
        )
        let container = try decoder.container(
            keyedBy: ContentAcknowledgementCodingKeys.self
        )
        guard try container.decode(String.self, forKey: .kind) == "content.acknowledge" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid content.acknowledge discriminator",
                codingPath: decoder.codingPath
            )
        }
        self.contentRequestId = try container.decode(String.self, forKey: .contentRequestId)
        self.receivedThroughContentSequence = try container.decode(Int.self, forKey: .receivedThroughContentSequence)
        self.leaseId = try container.decode(String.self, forKey: .leaseId)
        self.paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        self.wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        self.workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(
            contentRequestId,
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            receivedThroughContentSequence,
            name: "receivedThroughContentSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(
            leaseId,
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(
            paneSessionId,
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateWireVersion(
            wireVersion,
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateIdentifier(
            workerInstanceId,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: ContentAcknowledgementCodingKeys.self
        )
        try container.encode(contentRequestId, forKey: .contentRequestId)
        try container.encode("content.acknowledge", forKey: .kind)
        try container.encode(leaseId, forKey: .leaseId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(receivedThroughContentSequence, forKey: .receivedThroughContentSequence)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

enum BridgeProductContentAcknowledgementRefusalReason: String, Codable, Equatable, Sendable {
    case unknownRead
    case invalidReadIdentity
    case invalidSequence
}

struct BridgeProductContentAcknowledgementRefusedResponse: Codable, Sendable {
    let contentRequestId: String
    let leaseId: String
    let paneSessionId: String
    let receivedThroughContentSequence: Int
    let reason: BridgeProductContentAcknowledgementRefusalReason
    let wireVersion: Int
    let workerInstanceId: String

    init(
        acknowledgement: BridgeProductContentFrameAcknowledgement,
        reason: BridgeProductContentAcknowledgementRefusalReason
    ) {
        contentRequestId = acknowledgement.contentRequestId
        leaseId = acknowledgement.leaseId
        paneSessionId = acknowledgement.paneSessionId
        receivedThroughContentSequence = acknowledgement.receivedThroughContentSequence
        self.reason = reason
        wireVersion = acknowledgement.wireVersion
        workerInstanceId = acknowledgement.workerInstanceId
    }

    private enum CodingKeys: String, CodingKey {
        case contentRequestId
        case kind
        case leaseId
        case paneSessionId
        case receivedThroughContentSequence
        case reason
        case wireVersion
        case workerInstanceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "content.acknowledgementRefused" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid content acknowledgement refusal kind",
                codingPath: decoder.codingPath
            )
        }
        contentRequestId = try container.decode(String.self, forKey: .contentRequestId)
        leaseId = try container.decode(String.self, forKey: .leaseId)
        paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        receivedThroughContentSequence = try container.decode(Int.self, forKey: .receivedThroughContentSequence)
        reason = try container.decode(BridgeProductContentAcknowledgementRefusalReason.self, forKey: .reason)
        wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentRequestId, forKey: .contentRequestId)
        try container.encode("content.acknowledgementRefused", forKey: .kind)
        try container.encode(leaseId, forKey: .leaseId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(receivedThroughContentSequence, forKey: .receivedThroughContentSequence)
        try container.encode(reason, forKey: .reason)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

enum BridgeProductCommandPackage: Decodable, Sendable {
    case contentFrameAcknowledgement(BridgeProductContentFrameAcknowledgement)
    case control(BridgeProductControlRequest)
    case operationResult(BridgeProductOperationResultRequest)
    case operationResultAcknowledgement(BridgeProductOperationResultAcknowledgement)
    case operationObservation(BridgeProductOperationObservationRequest)
    case lateOutcomeAcknowledgement(BridgeProductOperationLateOutcomeAcknowledgement)
    case viewAcknowledgement(BridgeProductViewAcknowledgementRequest)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "operation.result":
            self = .operationResult(try BridgeProductOperationResultRequest(from: decoder))
        case "operation.resultAcknowledgement":
            self = .operationResultAcknowledgement(
                try BridgeProductOperationResultAcknowledgement(from: decoder)
            )
        case "operation.observe":
            self = .operationObservation(try BridgeProductOperationObservationRequest(from: decoder))
        case "operation.lateOutcomeAcknowledgement":
            self = .lateOutcomeAcknowledgement(
                try BridgeProductOperationLateOutcomeAcknowledgement(from: decoder)
            )
        case "subscription.acknowledge":
            self = .viewAcknowledgement(
                try BridgeProductViewAcknowledgementRequest(from: decoder)
            )
        case "content.acknowledge":
            self = .contentFrameAcknowledgement(
                try BridgeProductContentFrameAcknowledgement(from: decoder)
            )
        default:
            self = .control(try BridgeProductControlRequest(from: decoder))
        }
    }
}
