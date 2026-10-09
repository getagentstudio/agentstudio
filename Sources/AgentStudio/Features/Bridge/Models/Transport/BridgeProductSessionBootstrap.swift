import AgentStudioInfrastructure
import Foundation

struct BridgeProductBootstrapPolicy: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case admissionRetryCount
        case contentProgressDeadlineMilliseconds
        case contentAcknowledgementDeadlineMilliseconds
        case maximumContentBytes
        case maximumRequestBodyBytes
        case maximumMetadataFrameBytes
        case maximumQueuedStreamBytes
        case maximumQueuedStreamFrames
        case terminalFrameReserve
        case streamKeepaliveIntervalMilliseconds
        case telemetryPreReadyBufferMaxBytes
        case telemetryPreReadyBufferMaxSamples
        case viewAcknowledgementDeadlineMilliseconds
        case viewBatchProgressDeadlineMilliseconds
        case viewCreditBytes
        case viewCreditParts
        case viewMaximumConsecutiveResnapshots
        case viewMaximumDirtyKeys
        case workerSettlementDeadlineMilliseconds
    }

    let admissionRetryCount: Int
    let contentProgressDeadlineMilliseconds: Int
    let contentAcknowledgementDeadlineMilliseconds: Int
    let maximumContentBytes: Int
    let maximumRequestBodyBytes: Int
    let maximumMetadataFrameBytes: Int
    let maximumQueuedStreamBytes: Int
    let maximumQueuedStreamFrames: Int
    let terminalFrameReserve: Int
    let streamKeepaliveIntervalMilliseconds: Int
    let telemetryPreReadyBufferMaxBytes: Int
    let telemetryPreReadyBufferMaxSamples: Int
    let viewAcknowledgementDeadlineMilliseconds: Int
    let viewBatchProgressDeadlineMilliseconds: Int
    let viewCreditBytes: Int
    let viewCreditParts: Int
    let viewMaximumConsecutiveResnapshots: Int
    let viewMaximumDirtyKeys: Int
    let workerSettlementDeadlineMilliseconds: Int

    static let productContract = Self(
        admissionRetryCount: AppPolicies.Bridge.productAdmissionRetryCount,
        contentProgressDeadlineMilliseconds: Int(
            AppPolicies.Bridge.contentProgressDeadline.components.seconds * 1000
        ),
        contentAcknowledgementDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productContentAcknowledgementDeadline.components.seconds * 1000),
        maximumContentBytes: BridgeProductWireContract.maximumContentStreamBytes,
        maximumRequestBodyBytes: BridgeProductWireContract.maximumRequestBodyBytes,
        maximumMetadataFrameBytes: BridgeProductWireContract.maximumMetadataFrameBytes,
        maximumQueuedStreamBytes: BridgeProductWireContract.maximumQueuedStreamBytes,
        maximumQueuedStreamFrames: BridgeProductWireContract.maximumQueuedStreamFrames,
        terminalFrameReserve: BridgeProductWireContract.terminalFrameReserve,
        streamKeepaliveIntervalMilliseconds: Int(
            AppPolicies.Bridge.streamKeepaliveInterval.components.seconds * 1000
                + AppPolicies.Bridge.streamKeepaliveInterval.components.attoseconds / 1_000_000_000_000_000
        ),
        telemetryPreReadyBufferMaxBytes: BridgeTelemetryWorkerPolicy.live.producerPreReadyBufferMaxBytes,
        telemetryPreReadyBufferMaxSamples: BridgeTelemetryWorkerPolicy.live.producerPreReadyBufferMaxSamples,
        viewAcknowledgementDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productViewAcknowledgementDeadline.components.seconds * 1000
        ),
        viewBatchProgressDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productViewBatchProgressDeadline.components.seconds * 1000
        ),
        viewCreditBytes: AppPolicies.Bridge.productViewCreditBytes,
        viewCreditParts: AppPolicies.Bridge.productViewCreditParts,
        viewMaximumConsecutiveResnapshots: AppPolicies.Bridge.productViewMaximumConsecutiveResnapshots,
        viewMaximumDirtyKeys: AppPolicies.Bridge.productViewMaximumDirtyKeys,
        workerSettlementDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productWorkerSettlementDeadline.components.seconds * 1000
        )
    )

    init(
        admissionRetryCount: Int,
        contentProgressDeadlineMilliseconds: Int,
        contentAcknowledgementDeadlineMilliseconds: Int,
        maximumContentBytes: Int,
        maximumRequestBodyBytes: Int,
        maximumMetadataFrameBytes: Int,
        maximumQueuedStreamBytes: Int,
        maximumQueuedStreamFrames: Int,
        terminalFrameReserve: Int,
        streamKeepaliveIntervalMilliseconds: Int,
        telemetryPreReadyBufferMaxBytes: Int,
        telemetryPreReadyBufferMaxSamples: Int,
        viewAcknowledgementDeadlineMilliseconds: Int,
        viewBatchProgressDeadlineMilliseconds: Int,
        viewCreditBytes: Int,
        viewCreditParts: Int,
        viewMaximumConsecutiveResnapshots: Int,
        viewMaximumDirtyKeys: Int,
        workerSettlementDeadlineMilliseconds: Int
    ) {
        self.admissionRetryCount = admissionRetryCount
        self.contentProgressDeadlineMilliseconds = contentProgressDeadlineMilliseconds
        self.contentAcknowledgementDeadlineMilliseconds = contentAcknowledgementDeadlineMilliseconds
        self.maximumContentBytes = maximumContentBytes
        self.maximumRequestBodyBytes = maximumRequestBodyBytes
        self.maximumMetadataFrameBytes = maximumMetadataFrameBytes
        self.maximumQueuedStreamBytes = maximumQueuedStreamBytes
        self.maximumQueuedStreamFrames = maximumQueuedStreamFrames
        self.terminalFrameReserve = terminalFrameReserve
        self.streamKeepaliveIntervalMilliseconds = streamKeepaliveIntervalMilliseconds
        self.telemetryPreReadyBufferMaxBytes = telemetryPreReadyBufferMaxBytes
        self.telemetryPreReadyBufferMaxSamples = telemetryPreReadyBufferMaxSamples
        self.viewAcknowledgementDeadlineMilliseconds = viewAcknowledgementDeadlineMilliseconds
        self.viewBatchProgressDeadlineMilliseconds = viewBatchProgressDeadlineMilliseconds
        self.viewCreditBytes = viewCreditBytes
        self.viewCreditParts = viewCreditParts
        self.viewMaximumConsecutiveResnapshots = viewMaximumConsecutiveResnapshots
        self.viewMaximumDirtyKeys = viewMaximumDirtyKeys
        self.workerSettlementDeadlineMilliseconds = workerSettlementDeadlineMilliseconds
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Bridge product bootstrap policy"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.admissionRetryCount = try container.decode(Int.self, forKey: .admissionRetryCount)
        self.contentProgressDeadlineMilliseconds = try container.decode(
            Int.self, forKey: .contentProgressDeadlineMilliseconds
        )
        self.contentAcknowledgementDeadlineMilliseconds = try container.decode(
            Int.self, forKey: .contentAcknowledgementDeadlineMilliseconds)
        self.maximumContentBytes = try container.decode(Int.self, forKey: .maximumContentBytes)
        self.maximumRequestBodyBytes = try container.decode(Int.self, forKey: .maximumRequestBodyBytes)
        self.maximumMetadataFrameBytes = try container.decode(Int.self, forKey: .maximumMetadataFrameBytes)
        self.maximumQueuedStreamBytes = try container.decode(Int.self, forKey: .maximumQueuedStreamBytes)
        self.maximumQueuedStreamFrames = try container.decode(Int.self, forKey: .maximumQueuedStreamFrames)
        self.terminalFrameReserve = try container.decode(Int.self, forKey: .terminalFrameReserve)
        self.streamKeepaliveIntervalMilliseconds = try container.decode(
            Int.self, forKey: .streamKeepaliveIntervalMilliseconds
        )
        self.telemetryPreReadyBufferMaxBytes = try container.decode(
            Int.self,
            forKey: .telemetryPreReadyBufferMaxBytes
        )
        self.telemetryPreReadyBufferMaxSamples = try container.decode(
            Int.self,
            forKey: .telemetryPreReadyBufferMaxSamples
        )
        self.viewAcknowledgementDeadlineMilliseconds = try container.decode(
            Int.self, forKey: .viewAcknowledgementDeadlineMilliseconds
        )
        self.viewBatchProgressDeadlineMilliseconds = try container.decode(
            Int.self, forKey: .viewBatchProgressDeadlineMilliseconds
        )
        self.viewCreditBytes = try container.decode(Int.self, forKey: .viewCreditBytes)
        self.viewCreditParts = try container.decode(Int.self, forKey: .viewCreditParts)
        self.viewMaximumConsecutiveResnapshots = try container.decode(
            Int.self, forKey: .viewMaximumConsecutiveResnapshots
        )
        self.viewMaximumDirtyKeys = try container.decode(Int.self, forKey: .viewMaximumDirtyKeys)
        self.workerSettlementDeadlineMilliseconds = try container.decode(
            Int.self,
            forKey: .workerSettlementDeadlineMilliseconds
        )

        try validateDecodedPolicy(codingPath: decoder.codingPath)
    }

    private func validateDecodedPolicy(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validateNonnegative(
            admissionRetryCount,
            name: "admissionRetryCount",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validatePositive(
            contentProgressDeadlineMilliseconds,
            name: "contentProgressDeadlineMilliseconds",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validatePositive(
            workerSettlementDeadlineMilliseconds,
            name: "workerSettlementDeadlineMilliseconds",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validatePositive(
            telemetryPreReadyBufferMaxBytes,
            name: "telemetryPreReadyBufferMaxBytes",
            codingPath: codingPath
        )
        try BridgeProductContractDecoding.validatePositive(
            telemetryPreReadyBufferMaxSamples,
            name: "telemetryPreReadyBufferMaxSamples",
            codingPath: codingPath
        )
        for (name, value) in [
            ("contentAcknowledgementDeadlineMilliseconds", contentAcknowledgementDeadlineMilliseconds),
            ("streamKeepaliveIntervalMilliseconds", streamKeepaliveIntervalMilliseconds),
            ("viewAcknowledgementDeadlineMilliseconds", viewAcknowledgementDeadlineMilliseconds),
            ("viewBatchProgressDeadlineMilliseconds", viewBatchProgressDeadlineMilliseconds),
            ("viewCreditBytes", viewCreditBytes),
            ("viewCreditParts", viewCreditParts),
            ("viewMaximumConsecutiveResnapshots", viewMaximumConsecutiveResnapshots),
            ("viewMaximumDirtyKeys", viewMaximumDirtyKeys),
        ] {
            try BridgeProductContractDecoding.validatePositive(value, name: name, codingPath: codingPath)
        }

        try validate(
            maximumContentBytes,
            maximum: BridgeProductWireContract.maximumContentStreamBytes,
            name: "maximumContentBytes",
            codingPath: codingPath
        )
        try validate(
            maximumRequestBodyBytes,
            maximum: BridgeProductWireContract.maximumRequestBodyBytes,
            name: "maximumRequestBodyBytes",
            codingPath: codingPath
        )
        try validate(
            maximumMetadataFrameBytes,
            maximum: BridgeProductWireContract.maximumMetadataFrameBytes,
            name: "maximumMetadataFrameBytes",
            codingPath: codingPath
        )
        try validate(
            maximumQueuedStreamBytes,
            maximum: BridgeProductWireContract.maximumQueuedStreamBytes,
            name: "maximumQueuedStreamBytes",
            codingPath: codingPath
        )
        try validate(
            maximumQueuedStreamFrames,
            maximum: BridgeProductWireContract.maximumQueuedStreamFrames,
            name: "maximumQueuedStreamFrames",
            codingPath: codingPath
        )
        guard terminalFrameReserve == BridgeProductWireContract.terminalFrameReserve else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge product policy must reserve exactly one terminal frame",
                codingPath: codingPath
            )
        }
    }

    private func validate(
        _ value: Int,
        maximum: Int,
        name: String,
        codingPath: [any CodingKey]
    ) throws {
        try BridgeProductContractDecoding.validatePositive(value, name: name, codingPath: codingPath)
        try BridgeProductContractDecoding.validateMaximum(
            value,
            maximum: maximum,
            name: name,
            codingPath: codingPath
        )
    }
}

package struct BridgeProductSessionBootstrap: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case paneSessionId
        case policy
        case wireVersion
        case workerInstanceId
    }

    let paneSessionId: String
    let policy: BridgeProductBootstrapPolicy
    let wireVersion: Int
    package let workerInstanceId: String

    init(
        paneSessionId: String,
        policy: BridgeProductBootstrapPolicy = .productContract,
        workerInstanceId: String
    ) {
        self.paneSessionId = paneSessionId
        self.policy = policy
        self.wireVersion = BridgeProductWireContract.version
        self.workerInstanceId = workerInstanceId
    }

    package init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Bridge product session bootstrap"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "productSession.bootstrap" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid Bridge product bootstrap kind",
                codingPath: decoder.codingPath
            )
        }
        self.paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        self.policy = try container.decode(BridgeProductBootstrapPolicy.self, forKey: .policy)
        self.wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        self.workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("productSession.bootstrap", forKey: .kind)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(policy, forKey: .policy)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

package enum BridgeProductCapabilityHeaderEncoding {
    package static func encode(_ capabilityBytes: [UInt8]) throws -> String {
        guard capabilityBytes.count == BridgeProductWireContract.capabilityByteLength else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge product capability must contain exactly 32 bytes",
                codingPath: []
            )
        }
        return Data(capabilityBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
