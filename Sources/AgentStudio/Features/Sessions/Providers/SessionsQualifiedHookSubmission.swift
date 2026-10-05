import AgentStudioInfrastructure
import Foundation

/// Qualified wire intent awaiting generation resolution in the Sessions FIFO.
/// Builders only map an already-decided generation to existing mutations.
package struct SessionsQualifiedHookSubmission: Sendable {
    package let paneId: UUID
    package let providerIdentifier: String
    package let providerConversationId: String
    package let occurrence: SessionsProviderOccurrenceIdentity
    package let providerIntentFingerprint: String
    package let occurredAt: Date
    package let sourceOccurredAt: Date?
    package let evidenceKind: SessionsEvidenceKind?
    package let makeBind: @Sendable (UUID, SessionsEvidenceFreshness) throws -> SessionsBindMutation
    package let makeMutation: @Sendable (UUID, SessionsEvidenceFreshness) throws -> SessionsMutation

    package init(
        paneId: UUID, providerIdentifier: String, providerConversationId: String,
        occurrence: SessionsProviderOccurrenceIdentity, providerIntentFingerprint: String,
        occurredAt: Date, sourceOccurredAt: Date?, evidenceKind: SessionsEvidenceKind?,
        makeBind: @escaping @Sendable (UUID, SessionsEvidenceFreshness) throws -> SessionsBindMutation,
        makeMutation: @escaping @Sendable (UUID, SessionsEvidenceFreshness) throws -> SessionsMutation
    ) {
        self.paneId = paneId
        self.providerIdentifier = providerIdentifier
        self.providerConversationId = providerConversationId
        self.occurrence = occurrence
        self.providerIntentFingerprint = providerIntentFingerprint
        self.occurredAt = occurredAt
        self.sourceOccurredAt = sourceOccurredAt
        self.evidenceKind = evidenceKind
        self.makeBind = makeBind
        self.makeMutation = makeMutation
    }

    func repositoryOperation(correlationId: UUID) throws -> SessionsRepositoryOperation {
        SessionsRepositoryOperation(
            correlationId: correlationId, operationScope: "pane:\(paneId.uuidString)",
            operationKind: occurrence.kind.rawValue,
            semanticFingerprint: try SessionsMutation.providerSemanticFingerprint(providerIntentFingerprint),
            providerOccurrence: occurrence,
            contextQuery: .bind(
                paneId: paneId, providerIdentifier: providerIdentifier, providerConversationId: providerConversationId),
            createdAt: occurredAt,
            sourceOccurredAt: sourceOccurredAt.flatMap {
                $0 <= occurredAt.addingTimeInterval(AppPolicies.Sessions.maximumSourceFutureSkew) ? $0 : nil
            })
    }

    /// Only the serialized transaction may decide whether a source is new.
    func resolve(against context: SessionsRepositoryContext) throws -> SessionsQualifiedHookResolution {
        let binding = context.bindings.first {
            $0.providerIdentifier == providerIdentifier && $0.providerConversationId == providerConversationId
        }
        let freshness: SessionsEvidenceFreshness =
            binding.map {
                $0.status == .active && context.currentBinding?.bindingGenerationId == $0.bindingGenerationId
                    ? .live : .historical
            } ?? .live
        let generation = binding?.sourceGenerationId ?? UUIDv7.generate()
        let impliedBind: SessionsBindMutation? =
            if occurrence.kind != .bind && binding == nil { try makeBind(generation, .live) } else { nil }
        return SessionsQualifiedHookResolution(
            impliedBind: impliedBind, mutation: try makeMutation(generation, freshness))
    }
}

struct SessionsQualifiedHookResolution: Sendable {
    let impliedBind: SessionsBindMutation?
    let mutation: SessionsMutation
}
