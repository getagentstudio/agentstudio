import Foundation

package enum SessionsEvidenceReducer {
    package static func currentTurnId(
        evidence: [SessionsEvidenceRecord],
        bindingGenerationId: UUID,
        activeSourceGenerationIds: Set<UUID>
    ) -> String? {
        let matchingRootEvidence = evidence.filter {
            $0.bindingGenerationId == bindingGenerationId
                && $0.subject == .root
                && $0.freshness == .live
                && $0.turnId != nil
                && activeSourceGenerationIds.contains($0.sourceGenerationId)
                && $0.kind.establishesTurnContext
        }.sorted(by: evidenceOrder)
        return matchingRootEvidence.last(where: { $0.origin == .reported })?.turnId
            ?? matchingRootEvidence.last(where: { $0.origin == .agentReported })?.turnId
            ?? matchingRootEvidence.last(where: { $0.origin == .estimated })?.turnId
    }

    package static func reduce(
        mutation: SessionsMutation,
        against context: SessionsRepositoryContext
    ) throws -> SessionsRepositoryReduction {
        switch mutation {
        case .bind(let bindMutation):
            try reduceBind(bindMutation, context: context)
        case .recordEvidence(let evidenceMutation):
            try reduceEvidence(evidenceMutation, context: context)
        case .sourceEnded(let sourceEndMutation):
            try reduceSourceEnd(sourceEndMutation, context: context)
        case .recordLiveLoss(let lossMutation):
            reduceLiveLoss(lossMutation, context: context)
        case .prepareForLaunch(let launchDate):
            reducePrepareForLaunch(at: launchDate, context: context)
        }
    }

    static func evidenceOrder(_ left: SessionsEvidenceRecord, _ right: SessionsEvidenceRecord) -> Bool {
        switch (left.admissionSequence, right.admissionSequence) {
        case (.none, .some): return true
        case (.some, .none): return false
        case (.some(let leftSequence), .some(let rightSequence)):
            if leftSequence != rightSequence { return leftSequence < rightSequence }
            return left.occurrenceId.uuidString < right.occurrenceId.uuidString
        case (.none, .none): break
        }
        if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
        return left.occurrenceId.uuidString < right.occurrenceId.uuidString
    }
}
extension SessionsEvidenceKind {
    fileprivate var establishesTurnContext: Bool {
        switch self {
        case .activityStarted, .completed, .aborted: true
        case .needsYouOpened, .needsYouResolved: false
        }
    }
}
