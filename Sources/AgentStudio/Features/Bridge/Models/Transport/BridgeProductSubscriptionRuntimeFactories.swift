import Foundation

extension BridgeProductFileSourceIdentity {
    init(
        repoId: String,
        rootRevisionToken: String?,
        sourceCursor: String,
        sourceId: String,
        subscriptionGeneration: Int,
        worktreeId: String
    ) throws {
        try BridgeProductContractDecoding.validateUUID(repoId, codingPath: [])
        if let rootRevisionToken {
            try BridgeProductContractDecoding.validateOpaqueReference(rootRevisionToken, codingPath: [])
        }
        try BridgeProductContractDecoding.validateOpaqueReference(sourceCursor, codingPath: [])
        try BridgeProductContractDecoding.validateIdentifier(sourceId, codingPath: [])
        try BridgeProductContractDecoding.validateNonnegative(
            subscriptionGeneration,
            name: "subscriptionGeneration",
            codingPath: []
        )
        try BridgeProductContractDecoding.validateUUID(worktreeId, codingPath: [])
        self.repoId = repoId
        self.rootRevisionToken = rootRevisionToken
        self.sourceCursor = sourceCursor
        self.sourceId = sourceId
        self.subscriptionGeneration = subscriptionGeneration
        self.worktreeId = worktreeId
    }
}

extension BridgeProductReviewMetadataEvent {
    init(
        generation: Int,
        packageId: String,
        publicationId: UUID,
        revision: Int,
        sourceIdentity: String
    ) throws {
        self = .sourceAccepted(
            BridgeProductReviewSourceAcceptedEvent(
                identity: try BridgeProductReviewMetadataIdentity(
                    generation: generation,
                    packageId: packageId,
                    publicationId: publicationId,
                    revision: revision,
                    sourceIdentity: sourceIdentity
                )
            )
        )
    }
}

extension BridgePaneProductFileSourceFact {
    init(source: BridgeProductFileSourceIdentity) {
        self = .sourceAccepted(source)
    }
}
