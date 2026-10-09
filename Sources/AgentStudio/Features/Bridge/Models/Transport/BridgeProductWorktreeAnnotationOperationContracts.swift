import Foundation

enum BridgeProductWorktreeAnnotationOperation: Codable, Equatable, Sendable {
    case discoverSessions
    case acquireDemand(sessionID: UUID)
    case releaseDemand(sessionID: UUID)
    case createRoot(
        admission: BridgeProductWorktreeAnnotationAdmission,
        body: String,
        editToken: String,
        origin: BridgeProductWorktreeAnnotationOrigin
    )
    case createReply(MutationBody)
    case flushDraft(DraftMutationBody)
    case acquireEditToken(DraftRevisionBody)
    case releaseEditToken(DraftRevisionBody)
    case saveDraft(DraftRevisionBody)
    case revertDraft(DraftRevisionBody)
    case setThreadResolution(ThreadResolutionBody)
    case setSessionLifecycle(SessionLifecycleBody)
    case chooseContinuity(ContinuityBody)
    case refreshSource(SourceRefreshBody)
    case outputScopeCommit(OutputScopeCommitBody)
    case outputPreferenceChangeFolder
    case outputReveal(attemptID: UUID)
    case outputHandledClear(OutputHandledClearBody)
    case outputHistory(sessionID: UUID)
    case repeatOutput(attemptID: UUID)
    case markMessagesViewed(ViewedBody)
    case acknowledgeRecovery

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case admission
        case attemptId
        case body
        case confirmsUnresolvedWork
        case decision
        case destination
        case displayedProjectionRevision
        case editToken
        case expectedDraftRevision
        case expectedMessageRevision
        case expectedOpenThreadCount
        case expectedSessionRevision
        case expectedSavedRevision
        case expectedThreadRevision
        case items
        case kind
        case lifecycle
        case messageId
        case origin
        case outputKind
        case scope
        case resolution
        case sessionId
        case sourceGeneration
        case sourceEpoch
        case threadId
    }

    private enum Kind: String, Codable {
        case acknowledgeRecovery = "recovery.acknowledge"
        case acquireDemand = "demand.acquire"
        case chooseContinuity = "continuity.choose"
        case createReply = "reply.create"
        case createRoot = "root.create"
        case discoverSessions = "session.discover"
        case acquireEditToken = "draft.edit.acquire"
        case releaseEditToken = "draft.edit.release"
        case flushDraft = "draft.flush"
        case outputHistory = "output.history"
        case outputHandledClear = "output.handled.clear"
        case outputScopeCommit = "output.scope.commit"
        case outputPreferenceChangeFolder = "output.preference.changeFolder"
        case outputReveal = "output.reveal"
        case markMessagesViewed = "message.viewed.mark"
        case releaseDemand = "demand.release"
        case repeatOutput = "output.repeat"
        case revertDraft = "draft.revert"
        case saveDraft = "draft.save"
        case setSessionLifecycle = "session.lifecycle.set"
        case refreshSource = "source.refresh"
        case setThreadResolution = "thread.resolution.set"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        try rejectUnknownKeys(decoder, allowed: Self.allowedKeys(for: kind))
        switch kind {
        case .discoverSessions:
            self = .discoverSessions
        case .acquireDemand:
            self = .acquireDemand(sessionID: try Self.decodeID(container, .sessionId, decoder))
        case .releaseDemand:
            self = .releaseDemand(sessionID: try Self.decodeID(container, .sessionId, decoder))
        case .createRoot:
            self = try Self.decodeCreateRoot(container, decoder)
        case .createReply:
            self = try Self.decodeCreateReply(container, decoder)
        case .flushDraft:
            self = try Self.decodeFlushDraft(container, decoder)
        case .acquireEditToken, .releaseEditToken:
            let body = try Self.decodeDraftRevisionBody(container, decoder)
            self = kind == .acquireEditToken ? .acquireEditToken(body) : .releaseEditToken(body)
        case .saveDraft, .revertDraft:
            let body = try Self.decodeDraftRevisionBody(container, decoder)
            self = kind == .saveDraft ? .saveDraft(body) : .revertDraft(body)
        case .setThreadResolution:
            self = try Self.decodeThreadResolution(container, decoder)
        case .setSessionLifecycle:
            self = try Self.decodeSessionLifecycle(container, decoder)
        case .chooseContinuity:
            self = try Self.decodeContinuity(container, decoder)
        case .refreshSource:
            self = try Self.decodeSourceRefresh(container, decoder)
        case .outputScopeCommit:
            let outputKind = try container.decode(OutputKind.self, forKey: .outputKind)
            let destination = try container.decodeIfPresent(OutputDestination.self, forKey: .destination)
            guard
                (outputKind == .jsonFile && destination != nil)
                    || (outputKind == .clipboardMarkdown && destination == nil)
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Only JSON export requires a destination",
                    codingPath: decoder.codingPath
                )
            }
            self = .outputScopeCommit(
                OutputScopeCommitBody(
                    displayedProjectionRevision: try Self.nonnegative(
                        container,
                        .displayedProjectionRevision,
                        decoder
                    ),
                    expectedSessionRevision: try Self.nonnegative(
                        container,
                        .expectedSessionRevision,
                        decoder
                    ),
                    outputKind: outputKind,
                    destination: destination,
                    scope: try container.decode(OutputScope.self, forKey: .scope),
                    sessionId: try Self.decodeID(container, .sessionId, decoder),
                    sourceGeneration: try Self.nonnegative(container, .sourceGeneration, decoder)
                )
            )
        case .outputPreferenceChangeFolder:
            self = .outputPreferenceChangeFolder
        case .outputReveal:
            self = .outputReveal(attemptID: try Self.decodeID(container, .attemptId, decoder))
        case .outputHandledClear:
            self = .outputHandledClear(
                OutputHandledClearBody(
                    attemptId: try Self.decodeID(container, .attemptId, decoder),
                    expectedSessionRevision: try Self.nonnegative(
                        container,
                        .expectedSessionRevision,
                        decoder
                    )
                )
            )
        case .outputHistory:
            self = .outputHistory(sessionID: try Self.decodeID(container, .sessionId, decoder))
        case .repeatOutput:
            self = .repeatOutput(attemptID: try Self.decodeID(container, .attemptId, decoder))
        case .markMessagesViewed:
            let items = try container.decode([ViewedItem].self, forKey: .items)
            guard (1...256).contains(items.count), Set(items).count == items.count,
                items.allSatisfy({ $0.expectedSavedRevision > 0 })
            else {
                throw BridgeProductContractDecoding.invalidValue(
                    "Viewed annotation items must be unique, nonempty, bounded, and positive",
                    codingPath: decoder.codingPath
                )
            }
            self = .markMessagesViewed(
                ViewedBody(
                    items: items,
                    sessionId: try Self.decodeID(container, .sessionId, decoder)
                )
            )
        case .acknowledgeRecovery:
            self = .acknowledgeRecovery
        }
    }

    private static func decodeCreateRoot(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .createRoot(
            admission: try container.decode(
                BridgeProductWorktreeAnnotationAdmission.self,
                forKey: .admission
            ),
            body: try validatedBody(container, decoder),
            editToken: try validatedIdentifier(container, .editToken, decoder),
            origin: try container.decode(BridgeProductWorktreeAnnotationOrigin.self, forKey: .origin)
        )
    }

    private static func decodeCreateReply(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .createReply(
            MutationBody(
                body: try validatedBody(container, decoder),
                editToken: try validatedIdentifier(container, .editToken, decoder),
                expectedThreadRevision: try nonnegative(container, .expectedThreadRevision, decoder),
                sessionId: try decodeID(container, .sessionId, decoder),
                threadId: try decodeID(container, .threadId, decoder)
            )
        )
    }

    private static func decodeThreadResolution(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .setThreadResolution(
            ThreadResolutionBody(
                expectedThreadRevision: try nonnegative(container, .expectedThreadRevision, decoder),
                resolution: try container.decode(WorktreeAnnotationThreadResolution.self, forKey: .resolution),
                sessionId: try decodeID(container, .sessionId, decoder),
                threadId: try decodeID(container, .threadId, decoder)
            )
        )
    }

    private static func decodeSessionLifecycle(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .setSessionLifecycle(
            SessionLifecycleBody(
                confirmsUnresolvedWork: try container.decode(Bool.self, forKey: .confirmsUnresolvedWork),
                expectedOpenThreadCount: try nonnegative(container, .expectedOpenThreadCount, decoder),
                expectedSessionRevision: try nonnegative(container, .expectedSessionRevision, decoder),
                lifecycle: try container.decode(WorktreeAnnotationSessionLifecycle.self, forKey: .lifecycle),
                sessionId: try decodeID(container, .sessionId, decoder)
            )
        )
    }

    private static func decodeContinuity(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .chooseContinuity(
            ContinuityBody(
                decision: try container.decode(ContinuityDecision.self, forKey: .decision),
                expectedSessionRevision: try nonnegative(container, .expectedSessionRevision, decoder),
                sessionId: try decodeID(container, .sessionId, decoder)
            )
        )
    }

    private static func decodeSourceRefresh(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        .refreshSource(
            SourceRefreshBody(
                sessionId: try decodeID(container, .sessionId, decoder),
                sourceEpoch: try nonnegative(container, .sourceEpoch, decoder)
            )
        )
    }

    private static func decodeFlushDraft(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> Self {
        let expectedDraftRevision = try BridgeProductContractDecoding.decodeRequiredNullable(
            Int.self,
            forKey: .expectedDraftRevision,
            from: container,
            codingPath: decoder.codingPath
        )
        if let expectedDraftRevision, expectedDraftRevision < 0 {
            throw invalidRevision(decoder)
        }
        return .flushDraft(
            DraftMutationBody(
                body: try validatedBody(container, decoder, allowsEmptyDraft: true),
                editToken: try validatedIdentifier(container, .editToken, decoder),
                expectedDraftRevision: expectedDraftRevision,
                expectedMessageRevision: try nonnegative(container, .expectedMessageRevision, decoder),
                messageId: try decodeID(container, .messageId, decoder),
                sessionId: try decodeID(container, .sessionId, decoder)
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .discoverSessions:
            try container.encode(Kind.discoverSessions, forKey: .kind)
        case .acquireDemand(let sessionID):
            try Self.encode(kind: .acquireDemand, id: sessionID, key: .sessionId, into: &container)
        case .releaseDemand(let sessionID):
            try Self.encode(kind: .releaseDemand, id: sessionID, key: .sessionId, into: &container)
        case .createRoot(let admission, let body, let editToken, let origin):
            try container.encode(Kind.createRoot, forKey: .kind)
            try container.encode(admission, forKey: .admission)
            try container.encode(body, forKey: .body)
            try container.encode(editToken, forKey: .editToken)
            try container.encode(origin, forKey: .origin)
        case .createReply(let body):
            try Self.encode(body, kind: .createReply, into: &container)
        case .flushDraft(let body):
            try Self.encode(body, kind: .flushDraft, into: &container)
        case .acquireEditToken(let body):
            try Self.encode(body, kind: .acquireEditToken, into: &container)
        case .releaseEditToken(let body):
            try Self.encode(body, kind: .releaseEditToken, into: &container)
        case .saveDraft(let body):
            try Self.encode(body, kind: .saveDraft, into: &container)
        case .revertDraft(let body):
            try Self.encode(body, kind: .revertDraft, into: &container)
        case .setThreadResolution(let body):
            try Self.encode(body, kind: .setThreadResolution, into: &container)
        case .setSessionLifecycle(let body):
            try Self.encode(body, kind: .setSessionLifecycle, into: &container)
        case .chooseContinuity(let body):
            try Self.encode(body, kind: .chooseContinuity, into: &container)
        case .refreshSource(let body):
            try container.encode(Kind.refreshSource, forKey: .kind)
            try container.encode(
                BridgeProductReviewPublicationIdContract.encode(body.sessionId),
                forKey: .sessionId
            )
            try container.encode(body.sourceEpoch, forKey: .sourceEpoch)
        case .outputScopeCommit(let body):
            try container.encode(Kind.outputScopeCommit, forKey: .kind)
            try container.encode(body.displayedProjectionRevision, forKey: .displayedProjectionRevision)
            try container.encode(body.expectedSessionRevision, forKey: .expectedSessionRevision)
            try container.encode(body.outputKind, forKey: .outputKind)
            if let destination = body.destination {
                try container.encode(destination, forKey: .destination)
            }
            try container.encode(body.scope, forKey: .scope)
            try container.encode(
                BridgeProductReviewPublicationIdContract.encode(body.sessionId),
                forKey: .sessionId
            )
            try container.encode(body.sourceGeneration, forKey: .sourceGeneration)
        case .outputPreferenceChangeFolder:
            try container.encode(Kind.outputPreferenceChangeFolder, forKey: .kind)
        case .outputReveal(let attemptID):
            try Self.encode(kind: .outputReveal, id: attemptID, key: .attemptId, into: &container)
        case .outputHandledClear(let body):
            try container.encode(Kind.outputHandledClear, forKey: .kind)
            try container.encode(
                BridgeProductReviewPublicationIdContract.encode(body.attemptId),
                forKey: .attemptId
            )
            try container.encode(body.expectedSessionRevision, forKey: .expectedSessionRevision)
        case .outputHistory(let sessionID):
            try Self.encode(kind: .outputHistory, id: sessionID, key: .sessionId, into: &container)
        case .repeatOutput(let attemptID):
            try Self.encode(kind: .repeatOutput, id: attemptID, key: .attemptId, into: &container)
        case .markMessagesViewed(let body):
            try container.encode(Kind.markMessagesViewed, forKey: .kind)
            try container.encode(body.items, forKey: .items)
            try container.encode(
                BridgeProductReviewPublicationIdContract.encode(body.sessionId),
                forKey: .sessionId
            )
        case .acknowledgeRecovery:
            try container.encode(Kind.acknowledgeRecovery, forKey: .kind)
        }
    }

    private static func allowedKeys(for kind: Kind) -> Set<CodingKeys> {
        switch kind {
        case .discoverSessions, .acknowledgeRecovery:
            [.kind]
        case .acquireDemand, .releaseDemand, .outputHistory:
            [.kind, .sessionId]
        case .repeatOutput:
            [.attemptId, .kind]
        case .outputReveal:
            [.attemptId, .kind]
        case .outputPreferenceChangeFolder:
            [.kind]
        case .markMessagesViewed:
            [.items, .kind, .sessionId]
        case .createRoot:
            [.admission, .body, .editToken, .kind, .origin]
        case .createReply:
            [.body, .editToken, .expectedThreadRevision, .kind, .sessionId, .threadId]
        case .flushDraft:
            [
                .body, .editToken, .expectedDraftRevision, .expectedMessageRevision, .kind,
                .messageId, .sessionId,
            ]
        case .acquireEditToken, .releaseEditToken, .saveDraft, .revertDraft:
            [.editToken, .expectedDraftRevision, .expectedMessageRevision, .kind, .messageId, .sessionId]
        case .setThreadResolution:
            [.expectedThreadRevision, .kind, .resolution, .sessionId, .threadId]
        case .setSessionLifecycle:
            [
                .confirmsUnresolvedWork, .expectedOpenThreadCount, .expectedSessionRevision,
                .kind, .lifecycle, .sessionId,
            ]
        case .chooseContinuity:
            [.decision, .expectedSessionRevision, .kind, .sessionId]
        case .refreshSource:
            [.kind, .sessionId, .sourceEpoch]
        case .outputScopeCommit:
            [
                .destination, .displayedProjectionRevision, .expectedSessionRevision, .kind,
                .outputKind, .scope, .sessionId, .sourceGeneration,
            ]
        case .outputHandledClear:
            [.attemptId, .expectedSessionRevision, .kind]
        }
    }

    private static func decodeID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ decoder: Decoder
    ) throws -> UUID {
        try decodeUUIDv7(container, forKey: key, decoder: decoder)
    }

    private static func decodeDraftRevisionBody(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder
    ) throws -> DraftRevisionBody {
        DraftRevisionBody(
            editToken: try validatedIdentifier(container, .editToken, decoder),
            expectedDraftRevision: try nonnegative(container, .expectedDraftRevision, decoder),
            expectedMessageRevision: try nonnegative(container, .expectedMessageRevision, decoder),
            messageId: try decodeID(container, .messageId, decoder),
            sessionId: try decodeID(container, .sessionId, decoder)
        )
    }

    private static func validatedBody(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ decoder: Decoder,
        allowsEmptyDraft: Bool = false
    ) throws -> String {
        do {
            let body = try container.decode(String.self, forKey: .body)
            // Clearing an editor is a draft mutation; Save/create still require content.
            if allowsEmptyDraft, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                body.utf8.count <= WorktreeAnnotationMessagePolicy.maximumBodyUTF8Bytes
            {
                return body
            }
            return try WorktreeAnnotationMessagePolicy.validate(body)
        } catch {
            throw BridgeProductContractDecoding.invalidValue(
                "Annotation body is invalid",
                codingPath: decoder.codingPath
            )
        }
    }

    private static func validatedIdentifier(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ decoder: Decoder
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
        try BridgeProductContractDecoding.validateIdentifier(value, codingPath: decoder.codingPath)
        return value
    }

    private static func nonnegative(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        _ decoder: Decoder
    ) throws -> Int {
        let value = try container.decode(Int.self, forKey: key)
        guard value >= 0 else { throw invalidRevision(decoder) }
        return value
    }

    private static func invalidRevision(_ decoder: Decoder) -> DecodingError {
        BridgeProductContractDecoding.invalidValue(
            "Annotation revision or count must be nonnegative",
            codingPath: decoder.codingPath
        )
    }

    private static func encode(
        kind: Kind,
        id: UUID,
        key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(BridgeProductReviewPublicationIdContract.encode(id), forKey: key)
    }

    private static func encode(
        _ body: MutationBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.body, forKey: .body)
        try container.encode(body.editToken, forKey: .editToken)
        try container.encode(body.expectedThreadRevision, forKey: .expectedThreadRevision)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.threadId),
            forKey: .threadId
        )
    }

    private static func encode(
        _ body: DraftMutationBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.body, forKey: .body)
        try container.encode(body.editToken, forKey: .editToken)
        try container.encode(body.expectedDraftRevision, forKey: .expectedDraftRevision)
        try container.encode(body.expectedMessageRevision, forKey: .expectedMessageRevision)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.messageId),
            forKey: .messageId
        )
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
    }

    private static func encode(
        _ body: DraftRevisionBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.editToken, forKey: .editToken)
        try container.encode(body.expectedDraftRevision, forKey: .expectedDraftRevision)
        try container.encode(body.expectedMessageRevision, forKey: .expectedMessageRevision)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.messageId),
            forKey: .messageId
        )
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
    }

    private static func encode(
        _ body: ThreadResolutionBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.expectedThreadRevision, forKey: .expectedThreadRevision)
        try container.encode(body.resolution, forKey: .resolution)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.threadId),
            forKey: .threadId
        )
    }

    private static func encode(
        _ body: SessionLifecycleBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.confirmsUnresolvedWork, forKey: .confirmsUnresolvedWork)
        try container.encode(body.expectedOpenThreadCount, forKey: .expectedOpenThreadCount)
        try container.encode(body.expectedSessionRevision, forKey: .expectedSessionRevision)
        try container.encode(body.lifecycle, forKey: .lifecycle)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
    }

    private static func encode(
        _ body: ContinuityBody,
        kind: Kind,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(body.decision, forKey: .decision)
        try container.encode(body.expectedSessionRevision, forKey: .expectedSessionRevision)
        try container.encode(
            BridgeProductReviewPublicationIdContract.encode(body.sessionId),
            forKey: .sessionId
        )
    }

}

private func rejectUnknownKeys<TCodingKey: CodingKey & RawRepresentable>(
    _ decoder: Decoder,
    allowed: Set<TCodingKey>
) throws where TCodingKey.RawValue == String {
    try BridgeProductContractDecoding.rejectUnknownKeys(
        from: decoder,
        allowedKeys: Set(allowed.map(\.rawValue)),
        contract: "worktree annotation transport value"
    )
}

private func decodeUUIDv7<TCodingKey: CodingKey>(
    _ container: KeyedDecodingContainer<TCodingKey>,
    forKey key: TCodingKey,
    decoder: Decoder
) throws -> UUID {
    try BridgeProductReviewPublicationIdContract.decode(
        container.decode(String.self, forKey: key),
        codingPath: decoder.codingPath
    )
}
