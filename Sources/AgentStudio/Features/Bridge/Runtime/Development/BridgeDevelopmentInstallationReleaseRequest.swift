import Foundation

/// Development HTTP lifecycle identity, separate from the shipped control protocol.
package struct BridgeDevelopmentInstallationReleaseRequest: Decodable, Equatable, Sendable {
    package let paneSessionId: String
    package let workerInstanceId: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case paneSessionId
        case workerInstanceId
    }

    package init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            contract: "Bridge development installation release"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneSessionId = try container.decode(String.self, forKey: .paneSessionId)
        workerInstanceId = try container.decode(String.self, forKey: .workerInstanceId)
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: decoder.codingPath)
        try BridgeProductContractDecoding.validateIdentifier(workerInstanceId, codingPath: decoder.codingPath)
    }
}

package enum BridgeDevelopmentInstallationReleaseError: Error, Equatable, Sendable {
    case unauthorized
    case installationMismatch
    case releaseFailed
}
