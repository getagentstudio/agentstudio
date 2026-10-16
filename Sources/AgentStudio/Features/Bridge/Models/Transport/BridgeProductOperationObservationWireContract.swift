import Foundation

/// Observing is an unsequenced result read. Its deadline is an observation
/// deadline, not a reason to replace the session.
struct BridgeProductOperationObservationRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case after
        case kind
        case operationId
        case paneSessionId
        case wireVersion
        case workerInstanceId
    }

    let after: Int
    let operationId: String
    let paneSessionId: String
    let wireVersion: Int
    let workerInstanceId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "operation.observe request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "operation.observe" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid operation.observe kind", codingPath: decoder.codingPath)
        }
        after = try container.decode(Int.self, forKey: .after)
        operationId = try container.decode(String.self, forKey: .operationId)
        paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validatePositive(after, name: "after", codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(operationId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(after, forKey: .after)
        try container.encode("operation.observe", forKey: .kind)
        try container.encode(operationId, forKey: .operationId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

struct BridgeProductLateOutcomeEvidence: Equatable, Sendable {
    let operationId: String
    let revision: Int
    let outcome: BridgeProductOperationSettlement
    let failureCode: BridgeProductRequestErrorCode?
    let result: BridgeProductJSONValue?
}

enum BridgeProductOperationObservationResponse: Codable, Equatable, Sendable {
    case stillUnknown(operationId: String, revision: Int)
    case lateOutcome(BridgeProductLateOutcomeEvidence)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case failureCode
        case kind
        case operationId
        case outcome
        case result
        case revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let operationId = try container.decode(String.self, forKey: .operationId)
        let revision = try container.decode(Int.self, forKey: .revision)
        try BridgeProductContractDecoding.validateIdentifier(operationId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validatePositive(revision, name: "revision", codingPath: decoder.codingPath)
        switch kind {
        case "operation.stillUnknown":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: ["kind", "operationId", "revision"],
                contract: "operation.stillUnknown response"
            )
            self = .stillUnknown(operationId: operationId, revision: revision)
        case "operation.lateOutcome":
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                contract: "operation.lateOutcome response"
            )
            let outcome = try container.decode(BridgeProductOperationSettlement.self, forKey: .outcome)
            let failureCode = try BridgeProductContractDecoding.decodeRequiredNullable(
                BridgeProductRequestErrorCode.self,
                forKey: .failureCode,
                from: container,
                codingPath: decoder.codingPath
            )
            let result = try BridgeProductContractDecoding.decodeRequiredNullable(
                BridgeProductJSONValue.self,
                forKey: .result,
                from: container,
                codingPath: decoder.codingPath
            )
            guard outcome != .outcomeUnknown,
                outcome == .succeeded || result == nil,
                outcome == .refused || outcome == .failed || failureCode == nil
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Invalid late mutation outcome",
                    codingPath: decoder.codingPath
                )
            }
            self = .lateOutcome(
                .init(
                    operationId: operationId,
                    revision: revision,
                    outcome: outcome,
                    failureCode: failureCode,
                    result: result
                ))
        default:
            throw BridgeProductContractDecoding.invalidValue(
                "Unknown operation observation response",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stillUnknown(let operationId, let revision):
            try container.encode("operation.stillUnknown", forKey: .kind)
            try container.encode(operationId, forKey: .operationId)
            try container.encode(revision, forKey: .revision)
        case .lateOutcome(let evidence):
            try container.encode(evidence.failureCode, forKey: .failureCode)
            try container.encode("operation.lateOutcome", forKey: .kind)
            try container.encode(evidence.operationId, forKey: .operationId)
            try container.encode(evidence.outcome, forKey: .outcome)
            try container.encode(evidence.result, forKey: .result)
            try container.encode(evidence.revision, forKey: .revision)
        }
    }
}

/// Revision 1's acknowledgement cannot acknowledge or delete revision 2.
struct BridgeProductOperationLateOutcomeAcknowledgement: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case operationId
        case revision
    }

    let correlation: BridgeProductControlCorrelation
    let operationId: String
    let revision: Int

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlCorrelation.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "operation.lateOutcomeAcknowledgement request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "operation.lateOutcomeAcknowledgement" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid late-outcome acknowledgement kind",
                codingPath: decoder.codingPath
            )
        }
        correlation = try BridgeProductControlCorrelation(from: decoder)
        operationId = try container.decode(String.self, forKey: .operationId)
        revision = try container.decode(Int.self, forKey: .revision)
        try BridgeProductContractDecoding.validateIdentifier(operationId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validatePositive(revision, name: "revision", codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try correlation.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("operation.lateOutcomeAcknowledgement", forKey: .kind)
        try container.encode(operationId, forKey: .operationId)
        try container.encode(revision, forKey: .revision)
    }
}
