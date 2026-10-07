import Foundation

extension SessionsEvidenceReducer {
    static func replacing(
        _ binding: SessionsBindingRecord,
        status: SessionsBindingStatus,
        endedAt: Date?
    ) -> SessionsBindingRecord {
        SessionsBindingRecord(
            bindingGenerationId: binding.bindingGenerationId,
            paneId: binding.paneId,
            conversationId: binding.conversationId,
            providerIdentifier: binding.providerIdentifier,
            providerConversationId: binding.providerConversationId,
            sourceGenerationId: binding.sourceGenerationId,
            transitionOccurrenceId: binding.transitionOccurrenceId,
            origin: binding.origin,
            status: status,
            startedAt: binding.startedAt,
            endedAt: endedAt,
            resumeHint: binding.resumeHint,
            ownerPaneId: binding.ownerPaneId
        )
    }

    static func replacing(
        _ source: SessionsSourceRecord,
        status: SessionsSourceStatus,
        endedAt: Date?, providerVersion: String? = nil
    ) -> SessionsSourceRecord {
        SessionsSourceRecord(
            id: source.id,
            bindingGenerationId: source.bindingGenerationId,
            sourceIdentifier: source.sourceIdentifier,
            sourceGenerationId: source.sourceGenerationId,
            providerIdentifier: source.providerIdentifier,
            providerVersion: providerVersion ?? source.providerVersion,
            providerMode: source.providerMode,
            qualification: source.qualification,
            status: status,
            lastCursor: source.lastCursor,
            startedAt: source.startedAt,
            endedAt: endedAt
        )
    }

}
