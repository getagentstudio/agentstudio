import Foundation

package enum SessionsEvidenceReducer {
    package static func currentTurnId(
        evidence: [SessionsEvidenceRecord],
        bindingGenerationId: UUID,
        activeSourceGenerationIds: Set<UUID>
    ) -> String? {
        let matchingRootEvidence = evidenceOrder(
            evidence.filter {
                $0.bindingGenerationId == bindingGenerationId
                    && $0.subject == .root
                    && $0.freshness == .live
                    && $0.turnId != nil
                    && activeSourceGenerationIds.contains($0.sourceGenerationId)
                    && $0.kind.establishesTurnContext
            })
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

    /// Unstamped facts retain their admission slots. Only stamped hook facts
    /// for the same binding trade places; missing source time is never invented.
    static func evidenceOrder(_ evidence: [SessionsEvidenceRecord]) -> [SessionsEvidenceRecord] {
        let admitted = evidence.sorted(by: admissionOrder)
        let stampedByBinding = Dictionary(
            grouping: admitted.filter { SessionsSourceHookOrder($0) != nil }, by: \.bindingGenerationId)
        let orderedByBinding = stampedByBinding.mapValues { records in
            records.sorted { left, right in
                guard let leftOrder = SessionsSourceHookOrder(left), let rightOrder = SessionsSourceHookOrder(right)
                else {
                    return admissionOrder(left, right)
                }
                return leftOrder < rightOrder
            }
        }
        var indicesByBinding: [UUID: Int] = [:]
        return admitted.map { record in
            guard SessionsSourceHookOrder(record) != nil, let ordered = orderedByBinding[record.bindingGenerationId]
            else {
                return record
            }
            let index = indicesByBinding[record.bindingGenerationId, default: 0]
            indicesByBinding[record.bindingGenerationId] = index + 1
            return ordered[index]
        }
    }

    static func admissionOrder(_ left: SessionsEvidenceRecord, _ right: SessionsEvidenceRecord) -> Bool {
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

/// Compact source watermark; admission sequence resolves equal source times.
struct SessionsSourceHookOrder: Sendable, Comparable {
    let sourceOccurredAt: Date
    let admissionSequence: Int64?
    let admittedWallTime: Date
    let occurrenceId: UUID

    init?(_ evidence: SessionsEvidenceRecord) {
        guard evidence.origin == .reported, let sourceOccurredAt = evidence.sourceOccurredAt else { return nil }
        self.sourceOccurredAt = sourceOccurredAt
        admissionSequence = evidence.admissionSequence
        admittedWallTime = evidence.occurredAt
        occurrenceId = evidence.occurrenceId
    }

    static func < (left: Self, right: Self) -> Bool {
        if left.sourceOccurredAt != right.sourceOccurredAt { return left.sourceOccurredAt < right.sourceOccurredAt }
        switch (left.admissionSequence, right.admissionSequence) {
        case (.none, .some): return true
        case (.some, .none): return false
        case (.some(let leftSequence), .some(let rightSequence)):
            if leftSequence != rightSequence { return leftSequence < rightSequence }
        case (.none, .none):
            if left.admittedWallTime != right.admittedWallTime { return left.admittedWallTime < right.admittedWallTime }
        }
        return left.occurrenceId.uuidString < right.occurrenceId.uuidString
    }

    static func == (left: Self, right: Self) -> Bool {
        !(left < right) && !(right < left)
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
