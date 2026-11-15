import Foundation

/// The actual binding ended by cold restore, before resume eligibility is validated.
package struct ColdEndedMain: Equatable, Sendable {
    package let bindingGenerationId: UUID
    package let providerIdentifier: String
    package let providerConversationId: String

    package init(bindingGenerationId: UUID, providerIdentifier: String, providerConversationId: String) {
        self.bindingGenerationId = bindingGenerationId
        self.providerIdentifier = providerIdentifier
        self.providerConversationId = providerConversationId
    }
}
