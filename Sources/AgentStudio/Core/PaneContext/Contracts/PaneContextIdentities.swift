import AgentStudioInfrastructure
import Foundation

package struct AgentMessageId: Hashable, Sendable {
    package let uuid: UUID

    package init(existingUUID: UUID) {
        uuid = existingUUID
    }

    package static func generateUUIDv7() -> Self {
        Self(existingUUID: UUIDv7.generate())
    }
}

package struct PaneContextRevision: Hashable, Sendable {
    package let value: UInt64

    package init(_ value: UInt64) {
        self.value = value
    }
}

package struct AskChoiceId: Hashable, Sendable {
    package let value: String

    package init(_ value: String) throws {
        guard !value.isEmpty else { throw PaneContextIdentityError.emptyChoiceId }
        self.value = value
    }
}

package enum PaneContextIdentityError: Error, Equatable, Sendable {
    case emptyChoiceId
}
