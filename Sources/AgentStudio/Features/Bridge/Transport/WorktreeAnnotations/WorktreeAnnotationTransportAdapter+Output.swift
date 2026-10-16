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
        let sessionDetail: WorktreeAnnotationSessionDetail
        do {
            sessionDetail = try await store.outputSessionDetail(sessionID: sessionID)
        } catch WorktreeAnnotationRepositoryError.notFound {
            throw WorktreeAnnotationRepositoryError.conflict(currentRevision: 0)
        }
        let selectedMessages = try await Self.selectOutputMessages(body.messages, from: sessionDetail)
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
        let outputKind: WorktreeAnnotationOutputKind =
            switch body.outputKind {
            case .clipboardMarkdown: .clipboardMarkdown
            case .jsonFile: .jsonFile
            }
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
                selectedMessages: selectedMessages,
                placementsByThreadID: sourceEvaluation.placements,
                sessionLabel: outputLabels.sessionLabel,
                worktreeLabel: outputLabels.worktreeLabel,
                comparisonLabel: comparisonLabel
            ),
            productAdmission: productAdmission
        )
        return result.commandOutcome
    }

    @concurrent nonisolated private static func selectOutputMessages(
        _ requestedMessages: [BridgeProductWorktreeAnnotationOperation.OutputMessage],
        from sessionDetail: WorktreeAnnotationSessionDetail
    ) async throws -> [WorktreeAnnotationSQLiteRepository.OutputMessageSelection] {
        let messagesByID = Dictionary(
            uniqueKeysWithValues: sessionDetail.threads.flatMap(\.messages).map { ($0.id.rawValue, $0) }
        )
        return try requestedMessages.map { requestedMessage in
            guard let message = messagesByID[requestedMessage.messageId],
                message.savedRevision == requestedMessage.savedRevision,
                message.savedBody != nil, message.draft == nil
            else {
                throw WorktreeAnnotationRepositoryError.conflict(
                    currentRevision: messagesByID[requestedMessage.messageId]?.semanticRevision ?? 0
                )
            }
            return WorktreeAnnotationSQLiteRepository.OutputMessageSelection(
                messageID: message.id,
                expectedSavedRevision: requestedMessage.savedRevision
            )
        }
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
