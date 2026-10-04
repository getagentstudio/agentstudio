import AgentStudioInfrastructure
import Foundation

extension SessionsEvidenceReducer {
    static func reduceBind(
        _ mutation: SessionsBindMutation,
        context: SessionsRepositoryContext
    ) throws -> SessionsRepositoryReduction {
        if let currentBinding = context.currentBinding,
            currentBinding.status == .active,
            currentBinding.providerIdentifier == mutation.providerIdentifier,
            currentBinding.providerConversationId == mutation.providerConversationId,
            currentBinding.sourceGenerationId == mutation.sourceGenerationId
        {
            return SessionsRepositoryReduction(outcome: .binding(.unchanged(currentBinding)))
        }
        if let historicalReduction = historicalBindReduction(mutation, context: context) {
            return historicalReduction
        }
        guard let admittedOrigin = mutation.transition.admittedOrigin else {
            throw SessionsRepositoryError.bindingConflict(mutation.paneId)
        }

        let existingConversation = context.matchingConversation
        let conversationId = existingConversation?.id ?? UUIDv7.generate()
        let conversation = SessionsConversationRecord(
            id: conversationId,
            providerIdentifier: mutation.providerIdentifier,
            providerConversationId: mutation.providerConversationId,
            createdAt: existingConversation?.createdAt ?? mutation.reportedAt,
            lastReportedAt: mutation.reportedAt
        )
        let newBinding = SessionsBindingRecord(
            bindingGenerationId: UUIDv7.generate(),
            paneId: mutation.paneId,
            conversationId: conversationId,
            providerIdentifier: mutation.providerIdentifier,
            providerConversationId: mutation.providerConversationId,
            sourceGenerationId: mutation.sourceGenerationId,
            transitionOccurrenceId: mutation.transition.occurrenceId,
            origin: admittedOrigin,
            status: .active,
            startedAt: mutation.reportedAt,
            endedAt: nil,
            resumeHint: mutation.resumeHint,
            ownerPaneId: mutation.ownerPaneId
        )
        let newSource = SessionsSourceRecord(
            id: UUIDv7.generate(),
            bindingGenerationId: newBinding.bindingGenerationId,
            sourceIdentifier: mutation.sourceId,
            sourceGenerationId: mutation.sourceGenerationId,
            providerIdentifier: mutation.providerIdentifier,
            providerVersion: mutation.providerVersion,
            providerMode: mutation.providerMode,
            qualification: "qualified",
            status: .active,
            lastCursor: nil,
            startedAt: mutation.reportedAt,
            endedAt: nil
        )
        var bindingChanges = [newBinding]
        var sourceChanges = [newSource]
        let outcome: SessionsMutationOutcome
        if let currentBinding = context.currentBinding, currentBinding.status == .active {
            let endedBinding = replacing(currentBinding, status: .ended, endedAt: mutation.reportedAt)
            bindingChanges.insert(endedBinding, at: 0)
            sourceChanges.insert(
                contentsOf: context.sources.filter { $0.bindingGenerationId == currentBinding.bindingGenerationId }
                    .map { source in
                        SessionsSourceRecord(
                            id: source.id,
                            bindingGenerationId: source.bindingGenerationId,
                            sourceIdentifier: source.sourceIdentifier,
                            sourceGenerationId: source.sourceGenerationId,
                            providerIdentifier: source.providerIdentifier,
                            providerVersion: source.providerVersion,
                            providerMode: source.providerMode,
                            qualification: source.qualification,
                            status: .ended,
                            lastCursor: source.lastCursor,
                            startedAt: source.startedAt,
                            endedAt: mutation.reportedAt
                        )
                    },
                at: 0
            )
            outcome = .binding(.replaced(endedBinding, newBinding))
        } else {
            outcome = .binding(.established(newBinding))
        }
        return SessionsRepositoryReduction(
            conversationChanges: [conversation],
            bindingChanges: bindingChanges,
            sourceChanges: sourceChanges,
            outcome: outcome
        )
    }

    private static func historicalBindReduction(
        _ mutation: SessionsBindMutation,
        context: SessionsRepositoryContext
    ) -> SessionsRepositoryReduction? {
        let isNonLiveProviderBind: Bool
        if case .qualifiedSessionStart = mutation.transition {
            isNonLiveProviderBind = mutation.freshness != .live
        } else {
            isNonLiveProviderBind = false
        }
        let isKnownGeneration = context.sources.contains {
            $0.sourceGenerationId == mutation.sourceGenerationId
        }
        guard isNonLiveProviderBind || isKnownGeneration else { return nil }
        return SessionsRepositoryReduction(outcome: .historical(occurrenceId: mutation.transition.occurrenceId))
    }

    static func reduceEvidence(
        _ mutation: SessionsEvidenceMutation,
        context: SessionsRepositoryContext
    ) throws -> SessionsRepositoryReduction {
        guard case .sourceGeneration(let paneId, let sourceGenerationId) = mutation.context,
            let binding = context.binding(sourceGenerationId: sourceGenerationId),
            binding.paneId == paneId
        else {
            throw SessionsRepositoryError.sourceNotFound(mutation.context.sourceGenerationIdForError)
        }
        let source = context.source(sourceGenerationId: sourceGenerationId)
        let isCurrent =
            binding.status == .active && source?.status == .active
            && context.currentBinding?.bindingGenerationId == binding.bindingGenerationId
            && mutation.freshness == .live
        let freshness: SessionsEvidenceFreshness = isCurrent ? .live : .historical
        let evidence = SessionsEvidenceRecord(
            occurrenceId: mutation.occurrenceId,
            conversationId: binding.conversationId,
            bindingGenerationId: binding.bindingGenerationId,
            sourceGenerationId: sourceGenerationId,
            turnId: mutation.turnId,
            subject: mutation.subject,
            kind: mutation.kind,
            origin: mutation.origin,
            freshness: freshness,
            occurredAt: mutation.occurredAt,
            sourceOccurredAt: SessionsMutation.recordEvidence(mutation).boundedSourceOccurredAt,
            providerSignal: mutation.providerSignal
        )
        let sourceChanges =
            source.flatMap { source in
                mutation.sourceCursor.map { cursor in
                    SessionsSourceRecord(
                        id: source.id,
                        bindingGenerationId: source.bindingGenerationId,
                        sourceIdentifier: source.sourceIdentifier,
                        sourceGenerationId: source.sourceGenerationId,
                        providerIdentifier: source.providerIdentifier,
                        providerVersion: source.providerVersion,
                        providerMode: source.providerMode,
                        qualification: source.qualification,
                        status: source.status,
                        lastCursor: cursor,
                        startedAt: source.startedAt,
                        endedAt: source.endedAt
                    )
                }
            }.map { [$0] } ?? []
        guard isCurrent else {
            return SessionsRepositoryReduction(
                sourceChanges: sourceChanges,
                evidenceChanges: [evidence],
                outcome: .historical(occurrenceId: mutation.occurrenceId)
            )
        }
        var reduction = SessionsRepositoryReduction(
            sourceChanges: sourceChanges,
            evidenceChanges: [evidence],
            outcome: .evidenceRecorded(occurrenceId: mutation.occurrenceId)
        )
        applyEvidenceProjection(evidence, source: source, context: context, reduction: &reduction)
        return reduction
    }
}

extension SessionsReportContext {
    fileprivate var sourceGenerationIdForError: UUID {
        if case .sourceGeneration(_, let sourceGenerationId) = self { return sourceGenerationId }
        return paneId
    }
}
