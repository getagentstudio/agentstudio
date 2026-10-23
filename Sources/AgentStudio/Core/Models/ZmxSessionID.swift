import AgentStudioInfrastructure
import Foundation

/// Durable opaque identity used to create or reattach a terminal session.
///
/// New identities are UUIDv7 strings. Restoration deliberately accepts any
/// nonblank persisted text verbatim so an existing session is never renamed.
package struct ZmxSessionID: Codable, Hashable, Sendable {
    package let rawValue: String

    package static func generateUUIDv7() -> Self {
        Self(rawValue: UUIDv7.generate().uuidString)
    }

    package init?(restoring storedText: String) {
        guard !storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        rawValue = storedText
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let storedText = try container.decode(String.self)
        guard let restoredIdentity = Self(restoring: storedText) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "zmx session identity must be nonblank"
            )
        }
        self = restoredIdentity
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}
