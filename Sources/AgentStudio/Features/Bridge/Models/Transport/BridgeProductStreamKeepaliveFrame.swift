import Foundation

/// A transport pulse. Its sequence repeats the last emitted product frame and
/// never consumes a product sequence or a view credit.
struct BridgeProductStreamKeepaliveFrame: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    let frameIdentity: BridgeProductMetadataFrameIdentity

    init(frameIdentity: BridgeProductMetadataFrameIdentity) {
        self.frameIdentity = frameIdentity
    }

    init(from decoder: Decoder) throws {
        try BridgeProductContractDecoding.rejectUnknownKeys(
            from: decoder,
            allowedKeys: BridgeProductMetadataFrameIdentity.codingKeyNames.union(
                CodingKeys.allCases.map(\.rawValue)
            ),
            contract: "stream.keepalive frame"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == "stream.keepalive" else {
            throw BridgeProductContractDecoding.invalidValue(
                "Invalid stream.keepalive frame kind",
                codingPath: decoder.codingPath
            )
        }
        frameIdentity = try BridgeProductMetadataFrameIdentity(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try frameIdentity.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("stream.keepalive", forKey: .kind)
    }
}
