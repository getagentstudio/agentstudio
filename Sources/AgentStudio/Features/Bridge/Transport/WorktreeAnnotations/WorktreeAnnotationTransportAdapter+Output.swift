import Foundation

extension WorktreeAnnotationTransportAdapter {
    func executeOutputPreparation(
        _ body: BridgeProductWorktreeAnnotationOperation.OutputScopeCommitBody,
        surface: BridgeProductSurface,
        reviewPublicationIdentity: BridgeProductReviewAnnotationPublicationIdentity?,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationOutputCommandOutcome {
        guard let outputCoordinator, let outputLabels else {
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        }
        let sessionID = WorktreeAnnotationSessionID(rawValue: body.sessionId)
        let sessionDetail = try await store.outputSessionDetail(
            sessionID: sessionID,
            expectedSessionRevision: body.expectedSessionRevision,
            expectedProjectionRevision: body.displayedProjectionRevision
        )
        guard
            try await sourceResolver.currentSourceGeneration(
                surface,
                reviewPublicationIdentity,
                productAdmission
            )
                == body.sourceGeneration
        else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let sourceSnapshot = WorktreeAnnotationServiceActor.sourceRefreshSnapshot(
            from: sessionDetail
        )
        let sourceCapture = try await sourceResolver.refresh(
            surface,
            reviewPublicationIdentity,
            productAdmission,
            sourceSnapshot.requirements
        )
        let sourceEvaluation = try WorktreeAnnotationSourceEvaluator.evaluate(
            .init(
                session: sessionDetail.session,
                threads: sessionDetail.threads.map(\.thread),
                surface: surface,
                sourceEpoch: contextID,
                currentFingerprint: sourceCapture.fingerprint,
                material: sourceCapture.material
            )
        )
        guard
            try await sourceResolver.currentSourceGeneration(
                surface,
                reviewPublicationIdentity,
                productAdmission
            )
                == body.sourceGeneration
        else {
            throw WorktreeAnnotationServiceError.staleSourceEpoch
        }
        let outputKind: WorktreeAnnotationOutputKind =
            switch body.outputKind {
            case .clipboardMarkdown: .clipboardMarkdown
            case .jsonFile: .jsonFile
            }
        let scopeEligibleThreads = sessionDetail.threads.filter { threadDetail in
            switch body.scope {
            case .pending: threadDetail.thread.resolution == .open
            case .all: true
            }
        }
        let selectedMessages = scopeEligibleThreads.flatMap(\.messages).filter { message in
            guard message.savedBody != nil, message.savedRevision != nil, message.draft == nil else {
                return false
            }
            switch body.scope {
            case .pending: return message.authorKind == .human && !message.handled
            case .all: return true
            }
        }
        guard !selectedMessages.isEmpty else { throw WorktreeAnnotationRepositoryError.emptySelection }
        let comparisonLabel =
            try outputLabels.comparisonLabel
            ?? WorktreeAnnotationComparisonLabelProjector.project(
                sessionDetail.session.acceptedSourceFingerprint.reviewComparisonOrigin
            )
        let result = try await outputCoordinator.executeNew(
            .init(
                outputKind: outputKind,
                destination: body.destination,
                sessionDetail: sessionDetail,
                selectedMessages: try selectedMessages.map { message in
                    guard let savedRevision = message.savedRevision else {
                        throw WorktreeAnnotationRepositoryError.invalidState
                    }
                    return .init(messageID: message.id, expectedSavedRevision: savedRevision)
                },
                placementsByThreadID: sourceEvaluation.placements,
                sessionLabel: outputLabels.sessionLabel,
                worktreeLabel: outputLabels.worktreeLabel,
                comparisonLabel: comparisonLabel,
                expectedSessionRevision: body.expectedSessionRevision,
                expectedProjectionRevision: body.displayedProjectionRevision
            ),
            productAdmission: productAdmission
        )
        return result.commandOutcome
    }

    func executeOutputRepeat(
        attemptID: WorktreeAnnotationOutputAttemptID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> WorktreeAnnotationOutputCommandOutcome {
        guard let outputCoordinator else {
            throw WorktreeAnnotationTransportAdapterError.outputUnavailable
        }
        return try await outputCoordinator.executeRepeat(sourceAttemptID: attemptID, productAdmission: productAdmission)
            .commandOutcome
    }
}
