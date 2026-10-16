import AgentStudioCore
import Foundation

package struct BridgeDevelopmentProductSource: Equatable, Sendable {
    package let paneID: UUID
    package let paneState: BridgePaneState
    package let repoID: UUID
    package let reviewedSubjectLabel: String?
    package let worktreeID: UUID
    package let worktreeRoot: URL

    package init(
        paneID: UUID,
        paneState: BridgePaneState,
        repoID: UUID,
        reviewedSubjectLabel: String?,
        worktreeID: UUID,
        worktreeRoot: URL
    ) {
        self.paneID = paneID
        self.paneState = paneState
        self.repoID = repoID
        self.reviewedSubjectLabel = reviewedSubjectLabel
        self.worktreeID = worktreeID
        self.worktreeRoot = worktreeRoot.standardizedFileURL.resolvingSymlinksInPath()
    }
}

package enum BridgeDevelopmentProductHostError: Error, Equatable, Sendable {
    case invalidBootstrapRequest
    case invalidContributionTarget
    case invalidPaneSource
    case invalidWorktree
    case replacementNavigationChanged
    case replacementPaneNotFound
    case reviewPublicationFailed
    case sessionAlreadyOpen
    case sessionActivationFailed
    case shutdown
}

package struct BridgeDevelopmentProductBootstrapRequest: Decodable, Equatable, Sendable {
    package enum Reason: String, Decodable, Sendable {
        case initial
        case workerReplacement
    }

    enum NavigationIntent: Equatable, Sendable {
        case activateContext(commandId: String, surface: BridgeProductSurface)
        case activateFileTarget(
            commandId: String,
            target: BridgeProductNavigationFileTarget
        )
        case activateReviewTarget(
            commandId: String,
            target: BridgeProductNavigationReviewTarget
        )
    }

    let navigationIntent: NavigationIntent
    package let paneSessionId: String?
    package let reason: Reason
    package let tabId: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case navigationIntent
        case paneSessionId
        case reason
        case tabId
    }

    package init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Bridge development bootstrap request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        navigationIntent = try container.decode(
            BridgeDevelopmentProductNavigationIntent.self,
            forKey: .navigationIntent
        ).value
        reason = try container.decode(Reason.self, forKey: .reason)
        tabId = try container.decode(String.self, forKey: .tabId)
        try BridgeProductContractDecoding.validateIdentifier(tabId, codingPath: decoder.codingPath)
        paneSessionId = try container.decodeIfPresent(String.self, forKey: .paneSessionId)
        switch reason {
        case .initial:
            guard paneSessionId == nil else {
                throw BridgeDevelopmentProductHostError.invalidBootstrapRequest
            }
        case .workerReplacement:
            guard let paneSessionId else {
                throw BridgeDevelopmentProductHostError.invalidBootstrapRequest
            }
            try BridgeProductContractDecoding.validateIdentifier(
                paneSessionId,
                codingPath: decoder.codingPath
            )
        }
    }
}

private struct BridgeDevelopmentProductNavigationIntent: Decodable {
    let value: BridgeDevelopmentProductBootstrapRequest.NavigationIntent

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case commandId
        case commandKind
        case surface
        case target
    }

    private enum CommandKind: String, Decodable {
        case activateContext
        case activateTarget
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Bridge development navigation intent"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let commandId = try container.decode(String.self, forKey: .commandId)
        try BridgeProductContractDecoding.validateIdentifier(
            commandId,
            codingPath: decoder.codingPath
        )
        let commandKind = try container.decode(CommandKind.self, forKey: .commandKind)
        let surface = try container.decode(BridgeProductSurface.self, forKey: .surface)
        switch (commandKind, surface) {
        case (.activateContext, let surface):
            try BridgeProductContractDecoding.rejectUnknownKeys(
                from: decoder,
                allowedKeys: [
                    CodingKeys.commandId.rawValue,
                    CodingKeys.commandKind.rawValue,
                    CodingKeys.surface.rawValue,
                ],
                contract: "Bridge development context navigation intent"
            )
            value = .activateContext(
                commandId: commandId,
                surface: surface
            )
        case (.activateTarget, .file):
            value = .activateFileTarget(
                commandId: commandId,
                target: try container.decode(
                    BridgeProductNavigationFileTarget.self,
                    forKey: .target
                )
            )
        case (.activateTarget, .review):
            value = .activateReviewTarget(
                commandId: commandId,
                target: try container.decode(
                    BridgeProductNavigationReviewTarget.self,
                    forKey: .target
                )
            )
        }
    }
}

enum BridgeDevelopmentProductBootstrapEnvelope {
    private static let version: UInt8 = 1
    private static let metadataLengthByteCount = 4

    static func encode(_ installation: BridgeProductSessionInstallation) throws -> Data {
        let metadata = try JSONEncoder().encode(installation.bootstrap)
        guard metadata.count <= UInt32.max else {
            throw BridgeDevelopmentProductHostError.invalidBootstrapRequest
        }
        var encoded = Data(capacity: 1 + metadataLengthByteCount + metadata.count + installation.capabilityBytes.count)
        encoded.append(version)
        var metadataLength = UInt32(metadata.count).bigEndian
        withUnsafeBytes(of: &metadataLength) { bytes in
            encoded.append(contentsOf: bytes)
        }
        encoded.append(metadata)
        encoded.append(contentsOf: installation.capabilityBytes)
        return encoded
    }
}
