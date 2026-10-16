import AgentStudioCore
import Foundation

enum BridgeProductMetadataStreamResumeDisposition: String, Codable, Equatable, Sendable {
    case resumed
    case snapshotRequired = "snapshot_required"
}

enum BridgeProductContentCancellationDisposition: String, Codable, Equatable, Sendable {
    case stopped
    case alreadyTerminal = "already_terminal"
}

struct BridgeProductMetadataStreamRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case metadataStreamId
        case paneSessionId
        case resumeFromStreamSequence
        case wireVersion
        case workerInstanceId
    }

    let metadataStreamId: String
    let paneSessionId: String
    let resumeFromStreamSequence: Int?
    let wireVersion: Int
    let workerInstanceId: String

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "metadataStream.open request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "metadataStream.open" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid metadataStream.open request kind",
                codingPath: decoder.codingPath
            )
        }
        self.metadataStreamId = try container.decode(String.self, forKey: .metadataStreamId)
        self.paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        self.resumeFromStreamSequence = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .resumeFromStreamSequence,
            from: container,
            codingPath: decoder.codingPath
        )
        self.wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        self.workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(metadataStreamId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        if let resumeFromStreamSequence {
            try BridgeProductContractDecoding.validateNonnegative(
                resumeFromStreamSequence,
                name: "resumeFromStreamSequence",
                codingPath: decoder.codingPath
            )
            try BridgeProductContractDecoding.validateMaximum(
                resumeFromStreamSequence,
                maximum: BridgeProductWireContract.maximumResumableStreamSequence,
                name: "resumeFromStreamSequence",
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("metadataStream.open", forKey: .kind)
        try container.encode(metadataStreamId, forKey: .metadataStreamId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(resumeFromStreamSequence, forKey: .resumeFromStreamSequence)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

enum BridgeProductMetadataFrameIdentityCodingKeys: String, CodingKey, CaseIterable {
    case metadataStreamId
    case paneSessionId
    case streamSequence
    case wireVersion
    case workerInstanceId
}

struct BridgeProductMetadataFrameIdentity: Codable, Equatable, Sendable {
    static let codingKeyNames = Set(BridgeProductMetadataFrameIdentityCodingKeys.allCases.map(\.rawValue))

    let metadataStreamId: String
    let paneSessionId: String
    let streamSequence: Int
    let wireVersion: Int
    let workerInstanceId: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BridgeProductMetadataFrameIdentityCodingKeys.self)
        self.metadataStreamId = try container.decode(String.self, forKey: .metadataStreamId)
        self.paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        self.streamSequence = try container.decode(Int.self, forKey: .streamSequence)
        self.wireVersion = try container.decode(Int.self, forKey: .wireVersion)
        self.workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(metadataStreamId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            streamSequence,
            name: "streamSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateWireVersion(wireVersion, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }

    func validateProgressSequence(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validatePositive(
            streamSequence,
            name: "streamSequence",
            codingPath: codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BridgeProductMetadataFrameIdentityCodingKeys.self)
        try container.encode(metadataStreamId, forKey: .metadataStreamId)
        try container.encode(paneSessionId, forKey: .paneSessionId)
        try container.encode(streamSequence, forKey: .streamSequence)
        try container.encode(wireVersion, forKey: .wireVersion)
        try container.encode(workerInstanceId, forKey: .workerInstanceId)
    }
}

enum BridgeProductSubscriptionFrameIdentityCodingKeys: String, CodingKey, CaseIterable {
    case subscriptionId
    case subscriptionKind
    case subscriptionSequence
    case workerDerivationEpoch
}

struct BridgeProductSubscriptionFrameIdentity: Codable, Equatable, Sendable {
    static let codingKeyNames = Set(BridgeProductSubscriptionFrameIdentityCodingKeys.allCases.map(\.rawValue))

    let subscriptionId: String
    let subscriptionKind: BridgeProductSubscriptionKind
    let subscriptionSequence: Int
    let workerDerivationEpoch: Int
    let registeredSurface: BridgeProductSurface

    var surface: BridgeProductSurface { registeredSurface }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BridgeProductSubscriptionFrameIdentityCodingKeys.self)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.subscriptionKind = try container.decode(BridgeProductSubscriptionKind.self, forKey: .subscriptionKind)
        registeredSurface = try BridgeProductMetadataApplicationRegistry.product.registration(
            for: subscriptionKind
        ).surface
        self.subscriptionSequence = try container.decode(Int.self, forKey: .subscriptionSequence)
        self.workerDerivationEpoch = try container.decode(
            Int.self,
            forKey: .workerDerivationEpoch
        )
        try BridgeProductContractDecoding.validateIdentifier(subscriptionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            subscriptionSequence,
            name: "subscriptionSequence",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            workerDerivationEpoch,
            name: "workerDerivationEpoch",
            codingPath: decoder.codingPath
        )
    }

    func validateAcceptedSequence(codingPath: [any CodingKey]) throws {
        guard subscriptionSequence == 0 else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge subscription.accepted sequence must be zero",
                codingPath: codingPath
            )
        }
    }

    func validateProgressSequence(codingPath: [any CodingKey]) throws {
        try BridgeProductContractDecoding.validatePositive(
            subscriptionSequence,
            name: "subscriptionSequence",
            codingPath: codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: BridgeProductSubscriptionFrameIdentityCodingKeys.self)
        try container.encode(subscriptionId, forKey: .subscriptionId)
        try container.encode(subscriptionKind, forKey: .subscriptionKind)
        try container.encode(subscriptionSequence, forKey: .subscriptionSequence)
        try container.encode(workerDerivationEpoch, forKey: .workerDerivationEpoch)
    }
}

enum BridgeProductMetadataFrame: Codable, Equatable, Sendable {
    case metadataStreamAccepted(BridgeProductMetadataStreamAcceptedFrame)
    case streamKeepalive(BridgeProductStreamKeepaliveFrame)
    case panePresentation(BridgeProductPanePresentationFrame)
    case paneSurfaceSelectionRequested(BridgeProductPaneSurfaceSelectionRequestedFrame)
    case subscriptionAccepted(BridgeProductSubscriptionAcceptedFrame)
    case batch(BridgeProductBatchFrame)
    case subscriptionReset(BridgeProductSubscriptionResetFrame)
    case subscriptionEnd(BridgeProductSubscriptionEndFrame)
    case subscriptionCancelled(BridgeProductSubscriptionCancelledFrame)
    case contentCancelled(BridgeProductContentCancelledFrame)
    case metadataStreamError(BridgeProductMetadataStreamErrorFrame)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var kind: String {
        switch self {
        case .metadataStreamAccepted: "metadataStream.accepted"
        case .streamKeepalive: "stream.keepalive"
        case .panePresentation: "pane.presentation"
        case .paneSurfaceSelectionRequested: "pane.surfaceSelectionRequested"
        case .subscriptionAccepted: "subscription.accepted"
        case .batch(let frame):
            switch frame {
            case .begin: "subscription.batchBegin"
            case .part: "subscription.batchPart"
            case .complete: "subscription.batchComplete"
            }
        case .subscriptionReset: "subscription.reset"
        case .subscriptionEnd: "subscription.end"
        case .subscriptionCancelled: "subscription.cancelled"
        case .contentCancelled: "content.cancelled"
        case .metadataStreamError: "metadataStream.error"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "metadataStream.accepted":
            self = .metadataStreamAccepted(try BridgeProductMetadataStreamAcceptedFrame(from: decoder))
        case "stream.keepalive":
            self = .streamKeepalive(try BridgeProductStreamKeepaliveFrame(from: decoder))
        case "pane.presentation":
            self = .panePresentation(try BridgeProductPanePresentationFrame(from: decoder))
        case "pane.surfaceSelectionRequested":
            self = .paneSurfaceSelectionRequested(
                try BridgeProductPaneSurfaceSelectionRequestedFrame(from: decoder)
            )
        case "subscription.accepted":
            self = .subscriptionAccepted(try BridgeProductSubscriptionAcceptedFrame(from: decoder))
        case "subscription.batchBegin", "subscription.batchPart", "subscription.batchComplete":
            self = .batch(try BridgeProductBatchFrame(from: decoder))
        case "subscription.reset":
            self = .subscriptionReset(try BridgeProductSubscriptionResetFrame(from: decoder))
        case "subscription.end":
            self = .subscriptionEnd(try BridgeProductSubscriptionEndFrame(from: decoder))
        case "subscription.cancelled":
            self = .subscriptionCancelled(try BridgeProductSubscriptionCancelledFrame(from: decoder))
        case "content.cancelled":
            self = .contentCancelled(try BridgeProductContentCancelledFrame(from: decoder))
        case "metadataStream.error":
            self = .metadataStreamError(try BridgeProductMetadataStreamErrorFrame(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown Bridge product metadata frame kind"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .metadataStreamAccepted(let frame): try frame.encode(to: encoder)
        case .streamKeepalive(let frame): try frame.encode(to: encoder)
        case .panePresentation(let frame): try frame.encode(to: encoder)
        case .paneSurfaceSelectionRequested(let frame): try frame.encode(to: encoder)
        case .subscriptionAccepted(let frame): try frame.encode(to: encoder)
        case .batch(let frame): try frame.encode(to: encoder)
        case .subscriptionReset(let frame): try frame.encode(to: encoder)
        case .subscriptionEnd(let frame): try frame.encode(to: encoder)
        case .subscriptionCancelled(let frame): try frame.encode(to: encoder)
        case .contentCancelled(let frame): try frame.encode(to: encoder)
        case .metadataStreamError(let frame): try frame.encode(to: encoder)
        }
    }
}

struct BridgeProductPaneSurfaceSelectionRequestedFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case navigationCommand
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let navigationCommand: BridgeProductNavigationCommand

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "pane.surfaceSelectionRequested frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "pane.surfaceSelectionRequested" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid pane.surfaceSelectionRequested frame kind",
                codingPath: decoder.codingPath
            )
        }
        navigationCommand = try container.decode(
            BridgeProductNavigationCommand.self,
            forKey: .navigationCommand
        )
        frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("pane.surfaceSelectionRequested", forKey: .kind)
        try container.encode(navigationCommand, forKey: .navigationCommand)
    }
}

struct BridgePaneReviewDisplayedSnapshotIdentity: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case packageId
        case reviewGeneration
        case revision
    }

    let packageId: String
    let reviewGeneration: Int
    let revision: Int

    init(packageId: String, reviewGeneration: Int, revision: Int) {
        self.packageId = packageId
        self.reviewGeneration = reviewGeneration
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Review displayed snapshot identity"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageId = try container.decode(String.self, forKey: .packageId)
        reviewGeneration = try container.decode(Int.self, forKey: .reviewGeneration)
        revision = try container.decode(Int.self, forKey: .revision)
        try BridgeProductContractDecoding.validateIdentifier(packageId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateNonnegative(
            reviewGeneration,
            name: "reviewGeneration",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateNonnegative(
            revision,
            name: "revision",
            codingPath: decoder.codingPath
        )
    }
}

enum BridgePaneReviewDisplayedSnapshot: Codable, Equatable, Sendable {
    case absent
    case current(BridgePaneReviewDisplayedSnapshotIdentity)
    case stale(BridgePaneReviewDisplayedSnapshotIdentity)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case packageId
        case reviewGeneration
        case revision
        case status
    }

    private enum Status: String, Codable {
        case absent = "none"
        case current
        case stale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .absent:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.status.rawValue],
                contract: "empty Review displayed snapshot"
            )
            self = .absent
        case .current, .stale:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
                contract: "Review displayed snapshot"
            )
            let packageId = try container.decode(String.self, forKey: .packageId)
            let reviewGeneration = try container.decode(Int.self, forKey: .reviewGeneration)
            let revision = try container.decode(Int.self, forKey: .revision)
            try BridgeProductContractDecoding.validateIdentifier(
                packageId,
                codingPath: decoder.codingPath
            )
            try BridgeProductContractDecoding.validateNonnegative(
                reviewGeneration,
                name: "reviewGeneration",
                codingPath: decoder.codingPath
            )
            try BridgeProductContractDecoding.validateNonnegative(
                revision,
                name: "revision",
                codingPath: decoder.codingPath
            )
            let identity = BridgePaneReviewDisplayedSnapshotIdentity(
                packageId: packageId,
                reviewGeneration: reviewGeneration,
                revision: revision
            )
            self =
                try container.decode(Status.self, forKey: .status) == .current
                ? .current(identity)
                : .stale(identity)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Status.absent, forKey: .status)
        case .current(let identity):
            try identity.encode(to: encoder)
            try container.encode(Status.current, forKey: .status)
        case .stale(let identity):
            try identity.encode(to: encoder)
            try container.encode(Status.stale, forKey: .status)
        }
    }

    var identity: BridgePaneReviewDisplayedSnapshotIdentity? {
        switch self {
        case .absent: nil
        case .current(let identity), .stale(let identity): identity
        }
    }

    var stalePredecessor: Self {
        switch self {
        case .absent: .absent
        case .current(let identity), .stale(let identity): .stale(identity)
        }
    }
}

enum BridgePaneReviewComparisonAttempt: Codable, Equatable, Sendable {
    case noSource
    case selectionRequired
    case pending(reviewGeneration: Int)
    case settled(reviewGeneration: Int)
    case unavailable(failureKind: String, retryable: Bool)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case failureKind
        case retryable
        case reviewGeneration
        case status
    }

    private enum Status: String, Codable {
        case noSource
        case selectionRequired
        case pending
        case settled
        case unavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .noSource:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.status.rawValue],
                contract: "no-source Review comparison attempt"
            )
            self = .noSource
        case .selectionRequired:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.status.rawValue],
                contract: "selection-required Review comparison attempt"
            )
            self = .selectionRequired
        case .pending, .settled:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [CodingKeys.reviewGeneration.rawValue, CodingKeys.status.rawValue],
                contract: "Review comparison attempt"
            )
            let reviewGeneration = try container.decode(Int.self, forKey: .reviewGeneration)
            try BridgeProductContractDecoding.validateNonnegative(
                reviewGeneration,
                name: "reviewGeneration",
                codingPath: decoder.codingPath
            )
            self =
                try container.decode(Status.self, forKey: .status) == .pending
                ? .pending(reviewGeneration: reviewGeneration)
                : .settled(reviewGeneration: reviewGeneration)
        case .unavailable:
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [
                    CodingKeys.failureKind.rawValue,
                    CodingKeys.retryable.rawValue,
                    CodingKeys.status.rawValue,
                ],
                contract: "unavailable Review comparison attempt"
            )
            let failureKind = try container.decode(String.self, forKey: .failureKind)
            try BridgeProductContractDecoding.validateIdentifier(
                failureKind,
                codingPath: decoder.codingPath
            )
            self = .unavailable(
                failureKind: failureKind,
                retryable: try container.decode(Bool.self, forKey: .retryable)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noSource:
            try container.encode(Status.noSource, forKey: .status)
        case .selectionRequired:
            try container.encode(Status.selectionRequired, forKey: .status)
        case .pending(let reviewGeneration):
            try container.encode(reviewGeneration, forKey: .reviewGeneration)
            try container.encode(Status.pending, forKey: .status)
        case .settled(let reviewGeneration):
            try container.encode(reviewGeneration, forKey: .reviewGeneration)
            try container.encode(Status.settled, forKey: .status)
        case .unavailable(let failureKind, let retryable):
            try container.encode(failureKind, forKey: .failureKind)
            try container.encode(retryable, forKey: .retryable)
            try container.encode(Status.unavailable, forKey: .status)
        }
    }
}

package struct BridgeReviewComparisonDefaultTargetIdentity: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case branchName
        case remoteName
    }

    let remoteName: String
    let branchName: String

    package init(remoteName: String, branchName: String) {
        self.remoteName = remoteName
        self.branchName = branchName
    }

    package init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Review comparison default target identity"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.branchName = try container.decode(String.self, forKey: .branchName)
        self.remoteName = try container.decode(String.self, forKey: .remoteName)
        guard !branchName.isEmpty, !remoteName.isEmpty else {
            throw BridgeProductContractDecoding.invalidValue(
                "Review comparison default target identity must be non-empty",
                codingPath: decoder.codingPath
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branchName, forKey: .branchName)
        try container.encode(remoteName, forKey: .remoteName)
    }
}

struct BridgePaneReviewComparisonPresentation: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case activeTarget
        case attempt
        case displayedSnapshot
        case repositoryDefaultTarget
    }

    let activeTarget: WorkspaceReviewContributionTarget?
    let attempt: BridgePaneReviewComparisonAttempt
    let displayedSnapshot: BridgePaneReviewDisplayedSnapshot
    let repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?

    init(
        activeTarget: WorkspaceReviewContributionTarget?,
        attempt: BridgePaneReviewComparisonAttempt,
        displayedSnapshot: BridgePaneReviewDisplayedSnapshot,
        repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity? = nil
    ) {
        self.activeTarget = activeTarget
        self.attempt = attempt
        self.displayedSnapshot = displayedSnapshot
        self.repositoryDefaultTarget = repositoryDefaultTarget
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Review comparison presentation"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transportTarget = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeProductReviewComparisonTransportTarget.self,
            forKey: .activeTarget,
            from: container,
            codingPath: decoder.codingPath
        )
        activeTarget = transportTarget?.workspaceTarget
        attempt = try container.decode(BridgePaneReviewComparisonAttempt.self, forKey: .attempt)
        displayedSnapshot = try container.decode(
            BridgePaneReviewDisplayedSnapshot.self,
            forKey: .displayedSnapshot
        )
        repositoryDefaultTarget = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgeReviewComparisonDefaultTargetIdentity.self,
            forKey: .repositoryDefaultTarget,
            from: container,
            codingPath: decoder.codingPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeTarget, forKey: .activeTarget)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(displayedSnapshot, forKey: .displayedSnapshot)
        try container.encode(repositoryDefaultTarget, forKey: .repositoryDefaultTarget)
    }
}

struct BridgeProductPanePresentationFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case fileRefreshFailure
        case kind
        case nativeActivity
        case operationCorrelationId
        case presentationRevision
        case refreshingLanes
        case reviewComparison
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let fileRefreshFailure: BridgePaneProductFileRefreshFailure?
    let nativeActivity: BridgePaneActivity
    let operationCorrelationID: String?
    let presentationRevision: Int
    let refreshingLanes: [BridgePaneRefreshLane]
    let reviewComparison: BridgePaneReviewComparisonPresentation?

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "pane.presentation frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "pane.presentation" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid pane.presentation frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.nativeActivity = try container.decode(BridgePaneActivity.self, forKey: .nativeActivity)
        self.operationCorrelationID = try BridgeProductContractDecoding.decodeRequiredNullable(
            String.self,
            forKey: .operationCorrelationId,
            from: container,
            codingPath: decoder.codingPath
        )
        self.fileRefreshFailure = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgePaneProductFileRefreshFailure.self,
            forKey: .fileRefreshFailure,
            from: container,
            codingPath: decoder.codingPath
        )
        self.presentationRevision = try container.decode(Int.self, forKey: .presentationRevision)
        self.refreshingLanes = try container.decode(
            [BridgePaneRefreshLane].self,
            forKey: .refreshingLanes
        )
        self.reviewComparison = try BridgeProductContractDecoding.decodeRequiredNullable(
            BridgePaneReviewComparisonPresentation.self,
            forKey: .reviewComparison,
            from: container,
            codingPath: decoder.codingPath
        )
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
        if let operationCorrelationID {
            try BridgeProductContractDecoding.validateSHA256(
                operationCorrelationID,
                codingPath: decoder.codingPath
            )
        }
        try BridgeProductContractDecoding.validatePositive(
            presentationRevision,
            name: "presentationRevision",
            codingPath: decoder.codingPath
        )
        try BridgeProductContractDecoding.validateMaximum(
            presentationRevision,
            maximum: BridgeProductWireContract.maximumSafeInteger,
            name: "presentationRevision",
            codingPath: decoder.codingPath
        )
        let canonicalLanes = Array(Set(refreshingLanes)).sorted { $0.rawValue < $1.rawValue }
        guard refreshingLanes == canonicalLanes else {
            throw BridgeProductContractDecoding.invalidValue(
                "Bridge pane refreshing lanes must be unique and canonical",
                codingPath: decoder.codingPath
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("pane.presentation", forKey: .kind)
        try container.encode(fileRefreshFailure, forKey: .fileRefreshFailure)
        try container.encode(nativeActivity, forKey: .nativeActivity)
        try container.encode(operationCorrelationID, forKey: .operationCorrelationId)
        try container.encode(presentationRevision, forKey: .presentationRevision)
        try container.encode(refreshingLanes, forKey: .refreshingLanes)
        try container.encode(reviewComparison, forKey: .reviewComparison)
    }
}

struct BridgeProductMetadataStreamAcceptedFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case resumeDisposition
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let resumeDisposition: BridgeProductMetadataStreamResumeDisposition

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "metadataStream.accepted frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "metadataStream.accepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid metadataStream.accepted frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.resumeDisposition = try container.decode(
            BridgeProductMetadataStreamResumeDisposition.self,
            forKey: .resumeDisposition
        )
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("metadataStream.accepted", forKey: .kind)
        try container.encode(resumeDisposition, forKey: .resumeDisposition)
    }
}

struct BridgeProductSubscriptionAcceptedFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity
    let subscriptionIdentity: BridgeProductSubscriptionFrameIdentity

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames
                .union(BridgeProductSubscriptionFrameIdentity.codingKeyNames)
                .union(CodingKeys.allCases.map(\.rawValue)),
            contract: "subscription.accepted frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "subscription.accepted" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid subscription.accepted frame kind",
                codingPath: decoder.codingPath
            )
        }
        self.frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
        self.subscriptionIdentity = try BridgeProductSubscriptionFrameIdentity(from: decoder)
        try frameIdentity.validateProgressSequence(codingPath: decoder.codingPath)
        try subscriptionIdentity.validateAcceptedSequence(codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        try subscriptionIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("subscription.accepted", forKey: .kind)
    }
}
