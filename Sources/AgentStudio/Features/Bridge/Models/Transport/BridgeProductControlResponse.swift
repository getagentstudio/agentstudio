import Foundation

private typealias BridgeProductControlResponseIdentity = BridgeProductControlCorrelation

enum BridgeProductControlResponseFactoryError: Error, Equatable {
    case mismatchedRequestKind
    case mismatchedCallResult
}

enum BridgeProductControlResponse: Codable, Equatable, Sendable {
    case workerSessionAccepted(BridgeProductWorkerSessionAcceptedResponse)
    case callCompleted(BridgeProductCallCompletedResponse)
    case subscriptionOpenAccepted(BridgeProductSubscriptionOpenAcceptedResponse)
    case subscriptionCancelAccepted(BridgeProductSubscriptionCancelAcceptedResponse)
    case viewAccepted(BridgeProductViewAcceptedResponse)
    case resyncAccepted(BridgeProductResyncAcceptedResponse)
    case requestError(BridgeProductRequestErrorResponse)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var kind: String {
        switch self {
        case .workerSessionAccepted: "workerSession.accepted"
        case .callCompleted: "call.completed"
        case .subscriptionOpenAccepted: "subscription.openAccepted"
        case .subscriptionCancelAccepted: "subscription.cancelAccepted"
        case .viewAccepted(let response): response.kind.rawValue
        case .resyncAccepted: "resync.accepted"
        case .requestError: "request.error"
        }
    }

    var correlation: BridgeProductControlCorrelation {
        switch self {
        case .workerSessionAccepted(let response): response.correlation
        case .callCompleted(let response): response.correlation
        case .subscriptionOpenAccepted(let response): response.correlation
        case .subscriptionCancelAccepted(let response): response.correlation
        case .viewAccepted(let response): response.correlation
        case .resyncAccepted(let response): response.correlation
        case .requestError(let response): response.correlation
        }
    }

    var paneSessionId: String { correlation.paneSessionId }
    var requestId: String { correlation.requestId }
    var requestSequence: Int { correlation.requestSequence }
    var workerInstanceId: String { correlation.workerInstanceId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "workerSession.accepted":
            self = .workerSessionAccepted(try BridgeProductWorkerSessionAcceptedResponse(from: decoder))
        case "call.completed":
            self = .callCompleted(try BridgeProductCallCompletedResponse(from: decoder))
        case "subscription.openAccepted":
            self = .subscriptionOpenAccepted(try BridgeProductSubscriptionOpenAcceptedResponse(from: decoder))
        case "subscription.cancelAccepted":
            self = .subscriptionCancelAccepted(try BridgeProductSubscriptionCancelAcceptedResponse(from: decoder))
        case "subscription.scopeAccepted", "subscription.resnapshotAccepted":
            self = .viewAccepted(try BridgeProductViewAcceptedResponse(from: decoder))
        case "resync.accepted":
            self = .resyncAccepted(try BridgeProductResyncAcceptedResponse(from: decoder))
        case "request.error":
            self = .requestError(try BridgeProductRequestErrorResponse(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown Bridge product control response kind"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .workerSessionAccepted(let response): try response.encode(to: encoder)
        case .callCompleted(let response): try response.encode(to: encoder)
        case .subscriptionOpenAccepted(let response): try response.encode(to: encoder)
        case .subscriptionCancelAccepted(let response): try response.encode(to: encoder)
        case .viewAccepted(let response): try response.encode(to: encoder)
        case .resyncAccepted(let response): try response.encode(to: encoder)
        case .requestError(let response): try response.encode(to: encoder)
        }
    }
}

extension BridgeProductControlResponse {
    static func viewAccepted(correlating request: BridgeProductControlRequest) throws -> Self {
        switch request {
        case .viewScope(let scope):
            .viewAccepted(.init(correlating: scope))
        case .viewResnapshot(let resnapshot):
            .viewAccepted(.init(correlating: resnapshot))
        default:
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
    }

    static func workerSessionAccepted(
        correlating request: BridgeProductControlRequest
    ) throws -> Self {
        guard case .workerSessionOpen = request else {
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
        return .workerSessionAccepted(.init(correlation: request.correlation))
    }

    static func callCompleted(
        correlating request: BridgeProductControlRequest,
        result: BridgeProductCallResult
    ) throws -> Self {
        guard case .productCall(let callRequest) = request else {
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
        guard callRequest.call.method == result.method else {
            throw BridgeProductControlResponseFactoryError.mismatchedCallResult
        }
        return .callCompleted(.init(correlation: request.correlation, call: result))
    }

    static func subscriptionOpenAccepted(
        correlating request: BridgeProductControlRequest,
        worktreeId: String?
    ) throws -> Self {
        guard case .subscriptionOpen(let subscriptionRequest) = request else {
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
        return .subscriptionOpenAccepted(
            try .init(
                correlation: request.correlation,
                subscriptionId: subscriptionRequest.subscriptionId,
                subscriptionKind: subscriptionRequest.subscription.subscriptionKind,
                worktreeId: worktreeId
            )
        )
    }

    static func subscriptionCancelAccepted(
        correlating request: BridgeProductControlRequest
    ) throws -> Self {
        guard case .subscriptionCancel(let subscriptionRequest) = request else {
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
        return .subscriptionCancelAccepted(
            .init(
                correlation: request.correlation,
                subscriptionId: subscriptionRequest.subscriptionId,
                subscriptionKind: subscriptionRequest.subscriptionKind
            )
        )
    }

    static func resyncAccepted(
        correlating request: BridgeProductControlRequest,
        metadataStreamSequenceBarrier: Int,
        nextExpectedRequestSequence: Int,
        reconciliation: [BridgeProductResyncReconciliationOutcome]
    ) throws -> Self {
        guard case .workerSessionResync = request else {
            throw BridgeProductControlResponseFactoryError.mismatchedRequestKind
        }
        return .resyncAccepted(
            try .init(
                correlation: request.correlation,
                metadataStreamSequenceBarrier: metadataStreamSequenceBarrier,
                nextExpectedRequestSequence: nextExpectedRequestSequence,
                reconciliation: reconciliation
            )
        )
    }

    static func requestError(
        correlating request: BridgeProductControlRequest,
        code: BridgeProductRequestErrorCode,
        nextExpectedRequestSequence: Int?,
        retryAfterMilliseconds: Int?,
        retryable: Bool,
        safeMessage: String?
    ) throws -> Self {
        .requestError(
            try .init(
                correlation: request.correlation,
                code: code,
                nextExpectedRequestSequence: nextExpectedRequestSequence,
                retryAfterMilliseconds: retryAfterMilliseconds,
                retryable: retryable,
                safeMessage: safeMessage
            )
        )
    }
}

struct BridgeProductWorkerSessionAcceptedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case result
    }

    private let identity: BridgeProductControlResponseIdentity

    var correlation: BridgeProductControlCorrelation { identity }

    init(correlation: BridgeProductControlCorrelation) {
        self.identity = correlation
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlResponseIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "workerSession.accepted response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "workerSession.accepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid workerSession.accepted response kind",
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.decodeRequiredNull(
            forKey: .result,
            from: container,
            codingPath: decoder.codingPath
        )
        self.identity = try BridgeProductControlResponseIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("workerSession.accepted", forKey: .kind)
        try container.encodeNil(forKey: .result)
    }
}

struct BridgeProductCallCompletedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case call
        case kind
    }

    private let identity: BridgeProductControlResponseIdentity
    let call: BridgeProductCallResult

    var correlation: BridgeProductControlCorrelation { identity }

    init(correlation: BridgeProductControlCorrelation, call: BridgeProductCallResult) {
        self.identity = correlation
        self.call = call
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlResponseIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "call.completed response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.call = try container.decode(BridgeProductCallResult.self, forKey: .call)
        guard try container.decode(String.self, forKey: .kind) == "call.completed" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid call.completed response kind",
                codingPath: decoder.codingPath
            )
        }
        self.identity = try BridgeProductControlResponseIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(call, forKey: .call)
        try container.encode("call.completed", forKey: .kind)
    }
}

struct BridgeProductResyncAcceptedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case metadataStreamSequenceBarrier
        case nextExpectedRequestSequence
        case reconciliation
    }

    private let identity: BridgeProductControlResponseIdentity
    let metadataStreamSequenceBarrier: Int
    let nextExpectedRequestSequence: Int
    let reconciliation: [BridgeProductResyncReconciliationOutcome]

    var correlation: BridgeProductControlCorrelation { identity }

    init(
        correlation: BridgeProductControlCorrelation,
        metadataStreamSequenceBarrier: Int,
        nextExpectedRequestSequence: Int,
        reconciliation: [BridgeProductResyncReconciliationOutcome]
    ) throws {
        try BridgeProductContractDecoding.validatePositive(
            nextExpectedRequestSequence,
            name: "nextExpectedRequestSequence",
            codingPath: []
        )
        try BridgeProductContractDecoding.validateNonnegative(
            metadataStreamSequenceBarrier,
            name: "metadataStreamSequenceBarrier",
            codingPath: []
        )
        try BridgeProductContractDecoding.validateMaximum(
            metadataStreamSequenceBarrier,
            maximum: BridgeProductWireContract.maximumResumableStreamSequence,
            name: "metadataStreamSequenceBarrier",
            codingPath: []
        )
        try BridgeProductContractDecoding.validateCollectionCount(
            reconciliation.count,
            maximum: BridgeProductWireContract.maximumActiveSubscriptionCount,
            name: "resync reconciliation outcomes",
            codingPath: []
        )
        self.identity = correlation
        self.metadataStreamSequenceBarrier = metadataStreamSequenceBarrier
        self.nextExpectedRequestSequence = nextExpectedRequestSequence
        self.reconciliation = reconciliation
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlResponseIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "resync.accepted response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "resync.accepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid resync.accepted response kind",
                codingPath: decoder.codingPath
            )
        }
        self.metadataStreamSequenceBarrier = try container.decode(
            Int.self,
            forKey: .metadataStreamSequenceBarrier
        )
        self.nextExpectedRequestSequence = try container.decode(Int.self, forKey: .nextExpectedRequestSequence)
        self.reconciliation = try container.decode(
            [BridgeProductResyncReconciliationOutcome].self,
            forKey: .reconciliation
        )
        self.identity = try BridgeProductControlResponseIdentity(from: decoder)
        try BridgeProductContractDecoding.validatePositive(
            nextExpectedRequestSequence,
            name: "nextExpectedRequestSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            metadataStreamSequenceBarrier,
            name: "metadataStreamSequenceBarrier",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateMaximum(
            metadataStreamSequenceBarrier,
            maximum: BridgeProductWireContract.maximumResumableStreamSequence,
            name: "metadataStreamSequenceBarrier",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateCollectionCount(
            reconciliation.count,
            maximum: BridgeProductWireContract.maximumActiveSubscriptionCount,
            name: "resync reconciliation outcomes",
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("resync.accepted", forKey: .kind)
        try container.encode(metadataStreamSequenceBarrier, forKey: .metadataStreamSequenceBarrier)
        try container.encode(nextExpectedRequestSequence, forKey: .nextExpectedRequestSequence)
        try container.encode(reconciliation, forKey: .reconciliation)
    }
}

struct BridgeProductRequestErrorResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case kind
        case nextExpectedRequestSequence
        case retryAfterMilliseconds
        case retryable
        case safeMessage
    }

    private let identity: BridgeProductControlResponseIdentity
    let code: BridgeProductRequestErrorCode
    let nextExpectedRequestSequence: Int?
    let retryAfterMilliseconds: Int?
    let retryable: Bool
    let safeMessage: String?

    var correlation: BridgeProductControlCorrelation { identity }

    init(
        correlation: BridgeProductControlCorrelation,
        code: BridgeProductRequestErrorCode,
        nextExpectedRequestSequence: Int?,
        retryAfterMilliseconds: Int?,
        retryable: Bool,
        safeMessage: String?
    ) throws {
        if let nextExpectedRequestSequence {
            try BridgeProductContractDecoding.validatePositive(
                nextExpectedRequestSequence,
                name: "nextExpectedRequestSequence",
                codingPath: []
            )
        }
        if let retryAfterMilliseconds {
            try BridgeProductContractDecoding.validateNonnegative(
                retryAfterMilliseconds,
                name: "retryAfterMilliseconds",
                codingPath: []
            )
        }
        if let safeMessage {
            try BridgeProductContractDecoding.validateSafeMessage(safeMessage, codingPath: [])
        }
        self.identity = correlation
        self.code = code
        self.nextExpectedRequestSequence = nextExpectedRequestSequence
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.retryable = retryable
        self.safeMessage = safeMessage
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductControlResponseIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "request.error response"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(BridgeProductRequestErrorCode.self, forKey: .code)
        guard try container.decode(String.self, forKey: .kind) == "request.error" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid request.error response kind",
                codingPath: decoder.codingPath
            )
        }
        self.nextExpectedRequestSequence = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .nextExpectedRequestSequence,
            from: container,
            codingPath: decoder.codingPath
        )
        self.retryAfterMilliseconds = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .retryAfterMilliseconds,
            from: container,
            codingPath: decoder.codingPath
        )
        self.retryable = try container.decode(Bool.self, forKey: .retryable)
        self.safeMessage = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .safeMessage,
            from: container,
            codingPath: decoder.codingPath
        )
        self.identity = try BridgeProductControlResponseIdentity(from: decoder)
        if let nextExpectedRequestSequence {
            try BridgeProductContractDecoding.validatePositive(
                nextExpectedRequestSequence,
                name: "nextExpectedRequestSequence",
                codingPath: decoder.codingPath
            )
        }
        if let retryAfterMilliseconds {
            try BridgeProductContractDecoding.validateNonnegative(
                retryAfterMilliseconds,
                name: "retryAfterMilliseconds",
                codingPath: decoder.codingPath
            )
        }
        if let safeMessage {
            try BridgeProductContractDecoding.validateSafeMessage(safeMessage, codingPath: decoder.codingPath)
        }
    }

    func encode(to encoder: Encoder) throws {
        try identity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode("request.error", forKey: .kind)
        try container.encode(nextExpectedRequestSequence, forKey: .nextExpectedRequestSequence)
        try container.encode(retryAfterMilliseconds, forKey: .retryAfterMilliseconds)
        try container.encode(retryable, forKey: .retryable)
        try container.encode(safeMessage, forKey: .safeMessage)
    }
}
