import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

struct ProjectionSourceHarness {
    let detail: WorktreeAnnotationSessionDetail
    let additionalDetail: WorktreeAnnotationSessionDetail?
    let repositoryAccess: ProjectionSnapshotRepositoryAccess
    let productAdmission: BridgeProductAdmissionContext
    let source: BridgeAnnotationProjectionSource
    let sourceGeneration: Int
}

func makeProjectionSourceHarness(messageCount: Int, additionalSession: Bool = false) async throws
    -> ProjectionSourceHarness
{
    let baseDetail = try makeLocatedCommittedDetail()
    let detail = projectionDetail(base: baseDetail, messageCount: messageCount)
    let additionalDetail =
        additionalSession ? try projectionDetail(base: makeLocatedCommittedDetail(), messageCount: 1) : nil
    let repositoryAccess = ProjectionSnapshotRepositoryAccess(detail: detail, additionalDetail: additionalDetail)
    let service = WorktreeAnnotationServiceActor(repositoryAccess: repositoryAccess)
    let sourceGeneration = 7
    let sourceFingerprint = makeSourceFingerprint(identity: "source-current")
    let sourceResolver = WorktreeAnnotationSourceResolver(
        capture: { _, _, _, _ in throw WorktreeAnnotationSourceResolutionError.unavailable },
        currentFingerprint: { _, _, _ in sourceFingerprint },
        refresh: { _, _, _, _ in
            WorktreeAnnotationSourceRefreshCapture(
                fingerprint: sourceFingerprint,
                material: .available([
                    .init(
                        path: "Sources/RenamedFeature.swift",
                        sourceRole: .file,
                        sourceIdentity: "source-current",
                        body: "before\nselected line\nafter\n"
                    )
                ])
            )
        }
    )
    return ProjectionSourceHarness(
        detail: detail,
        additionalDetail: additionalDetail,
        repositoryAccess: repositoryAccess,
        productAdmission: try BridgeProductAdmissionTestContext.make().context,
        source: BridgeAnnotationProjectionSource(
            service: service,
            sourceResolver: sourceResolver,
            worktreeID: detail.session.worktreeID,
            currentSourceGeneration: { _, _, admission in
                guard admission.withValidAdmission({ true }) == true else {
                    throw BridgeAnnotationProjectionSourceError.unavailable
                }
                return sourceGeneration
            }
        ),
        sourceGeneration: sourceGeneration
    )
}

func projectionDetail(
    base: WorktreeAnnotationSessionDetail,
    messageCount: Int
) -> WorktreeAnnotationSessionDetail {
    precondition(messageCount > 0)
    let thread = base.threads[0].thread
    let body = String(repeating: "m", count: WorktreeAnnotationMessagePolicy.maximumBodyUTF8Bytes)
    let messages = (0..<messageCount).map { ordinal in
        WorktreeAnnotationMessage(
            id: .generate(),
            threadID: thread.id,
            ordinal: ordinal,
            semanticRevision: 1,
            createdAt: Date(timeIntervalSince1970: TimeInterval(ordinal + 1)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(ordinal + 1)),
            savedBody: body,
            savedRevision: 1,
            draft: nil,
            handled: false,
            status: .editable
        )
    }
    return WorktreeAnnotationSessionDetail(
        session: base.session,
        threads: [.init(thread: thread, messages: messages)]
    )
}

func projectionQuery(
    sessionID: WorktreeAnnotationSessionID,
    sourceGeneration: Int,
    surface: BridgeProductSurface,
    cursor: String? = nil,
    operationCorrelationID: String = String(repeating: "a", count: 64),
    additionalSessionID: WorktreeAnnotationSessionID? = nil
) throws -> BridgeProductAnnotationProjectionQueryRequest {
    var object: [String: Any] = [
        "cursor": cursor ?? NSNull(),
        "operationCorrelationId": operationCorrelationID,
        "sessionIds": ([sessionID] + [additionalSessionID].compactMap { $0 }).map {
            $0.rawValue.uuidString.lowercased()
        },
        "sourceGeneration": sourceGeneration,
        "surface": surface.rawValue,
    ]
    if surface == .review {
        object["reviewPublicationIdentity"] = projectionReviewPublicationIdentity(
            sourceGeneration: sourceGeneration
        )
    }
    return try BridgeProductStrictJSON.decode(
        BridgeProductAnnotationProjectionQueryRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

func projectionControlRequest(
    surface: BridgeProductSurface,
    paneSessionID: String = "pane-session-1",
    workerInstanceID: String = "worker-instance-1"
) throws -> BridgeProductControlRequest {
    let method = "\(surface.rawValue).annotations.projection.query"
    var queryRequest: [String: Any] = [
        "cursor": NSNull(),
        "operationCorrelationId": String(repeating: "a", count: 64),
        "sessionIds": [],
        "sourceGeneration": 7,
        "surface": surface.rawValue,
    ]
    if surface == .review {
        queryRequest["reviewPublicationIdentity"] = projectionReviewPublicationIdentity(
            sourceGeneration: 7
        )
    }
    let object: [String: Any] = [
        "call": [
            "method": method,
            "request": queryRequest,
        ],
        "kind": "product.call",
        "paneSessionId": paneSessionID,
        "requestId": "projection-query-1",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 3,
        "workerInstanceId": workerInstanceID,
    ]
    return try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

func projectionReviewPublicationIdentity(sourceGeneration: Int) -> [String: Any] {
    [
        "packageId": "package-installed",
        "publicationId": "00000000-0000-7000-8000-000000000041",
        "reviewGeneration": sourceGeneration,
        "revision": 3,
        "sourceIdentity": "source-installed",
    ]
}

func projectionContentRequest(
    descriptor: BridgeProductAnnotationProjectionContentDescriptor,
    paneSessionID: String,
    workerInstanceID: String
) throws -> BridgeProductAnnotationProjectionContentRequest {
    let descriptorObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any]
    )
    let object: [String: Any] = [
        "contentKind": "annotation.projection",
        "contentRequestId": "annotation-content-1",
        "descriptor": descriptorObject,
        "kind": "content.open",
        "leaseId": "annotation-lease-1",
        "operationCorrelationId": NSNull(),
        "paneSessionId": paneSessionID,
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 3,
        "workerInstanceId": workerInstanceID,
    ]
    return try BridgeProductStrictJSON.decode(
        BridgeProductAnnotationProjectionContentRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

func collectProjectionRecords(
    cursor: inout BridgeProductAnnotationProjectionPageRecordCursor
) throws -> [BridgeProductAnnotationProjectionRecord] {
    var records: [BridgeProductAnnotationProjectionRecord] = []
    while let batch = try cursor.nextEncodedBatch() {
        records.append(
            contentsOf: try batch.split(separator: 0x0A).map { line in
                try JSONDecoder().decode(
                    BridgeProductAnnotationProjectionRecord.self,
                    from: Data(line)
                )
            }
        )
    }
    return records
}

actor ProjectionSnapshotRepositoryAccess: WorktreeAnnotationRepositoryAccess {
    let detail: WorktreeAnnotationSessionDetail
    let additionalDetail: WorktreeAnnotationSessionDetail?
    private var heldNextCapture: HeldStep<[WorktreeAnnotationSessionID]>?
    init(detail: WorktreeAnnotationSessionDetail, additionalDetail: WorktreeAnnotationSessionDetail? = nil) {
        self.detail = detail
        self.additionalDetail = additionalDetail
    }
    func holdNextCapture(_ capture: HeldStep<[WorktreeAnnotationSessionID]>) { heldNextCapture = capture }
    func discoverSessions(worktreeID: String) async throws -> [WorktreeAnnotationSession] {
        detail.session.worktreeID == worktreeID ? [detail.session] : []
    }
    func fetchProjectionSnapshot(
        worktreeID: String,
        demandedSessionIDs: [WorktreeAnnotationSessionID]
    ) async throws -> WorktreeAnnotationRepositoryProjectionSnapshot {
        if let heldCapture = heldNextCapture {
            heldNextCapture = nil
            try await heldCapture.arrive(demandedSessionIDs)
        }
        let details = [detail] + [additionalDetail].compactMap { $0 }
        let demanded = Set(demandedSessionIDs)
        guard worktreeID == detail.session.worktreeID,
            demanded.isSubset(of: Set(details.map { $0.session.id }))
        else {
            throw WorktreeAnnotationRepositoryError.notFound
        }
        return WorktreeAnnotationRepositoryProjectionSnapshot(
            details: details.filter { demanded.contains($0.session.id) },
            sessions: details.map(\.session)
        )
    }
    func fetchSessionDetail(sessionID: WorktreeAnnotationSessionID) async throws
        -> WorktreeAnnotationSessionDetail
    {
        guard sessionID == detail.session.id else { throw WorktreeAnnotationRepositoryError.notFound }
        return detail
    }
    func createRootDraft(_: WorktreeAnnotationSQLiteRepository.CreateRootDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func flushDraft(_: WorktreeAnnotationSQLiteRepository.FlushDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try unsupportedProjectionMutation()
    }
    func saveDraft(_: WorktreeAnnotationSQLiteRepository.SaveDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func revertDraft(_: WorktreeAnnotationSQLiteRepository.RevertDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationDraftMutationResult>
    {
        try unsupportedProjectionMutation()
    }
    func createReplyDraft(_: WorktreeAnnotationSQLiteRepository.CreateReplyDraftProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func setThreadResolution(_: WorktreeAnnotationSQLiteRepository.SetThreadResolutionProps)
        async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func setSessionLifecycle(_: WorktreeAnnotationSQLiteRepository.SetSessionLifecycleProps)
        async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func setSourceRelationship(_: WorktreeAnnotationSQLiteRepository.SetSourceRelationshipProps)
        async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSessionDetail>
    {
        try unsupportedProjectionMutation()
    }
    func prepareOutput(_: WorktreeAnnotationSQLiteRepository.PrepareOutputProps) async throws
        -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput>
    {
        try unsupportedProjectionMutation()
    }
    func inspectOutputAttempt(attemptID _: WorktreeAnnotationOutputAttemptID) async throws
        -> WorktreeAnnotationSQLiteRepository.PreparedOutput
    {
        try unsupportedProjectionMutation()
    }
    func cancelOutputAttempt(
        attemptID _: WorktreeAnnotationOutputAttemptID,
        now _: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try unsupportedProjectionMutation()
    }
    func finalizeOutputAttempt(
        attemptID _: WorktreeAnnotationOutputAttemptID,
        eventKind _: WorktreeAnnotationOutputEventKind,
        destinationPath _: String?,
        now _: Date
    ) async throws -> WorktreeAnnotationCommittedMutation<WorktreeAnnotationSQLiteRepository.PreparedOutput> {
        try unsupportedProjectionMutation()
    }
    func markPreparedOutputAttemptsUnknown(now _: Date) async throws
        -> WorktreeAnnotationCommittedMutation<Int>
    {
        .init(canonicalResult: 0, change: .noChange)
    }
    func fetchUnacknowledgedRecoveryProvenance() async throws
        -> WorktreeAnnotationRecoveryProvenance?
    {
        nil
    }
    func acknowledgeRecoveryProvenance(
        id _: WorktreeAnnotationRecoveryProvenanceID,
        acknowledgedAt _: Date
    ) async throws -> WorktreeAnnotationRecoveryProvenance {
        try unsupportedProjectionMutation()
    }
}

func unsupportedProjectionMutation<TValue>() throws -> TValue {
    throw WorktreeAnnotationRepositoryError.invalidState
}

func makeProjectionQueryProvider(source: BridgeAnnotationProjectionSource) async -> BridgePaneProductSchemeProvider {
    let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    return BridgePaneProductSchemeProvider(
        annotationProjectionSource: source,
        fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
        markReviewItemViewed: { _, _ in },
        refreshWorkAdmissionSource: refreshWorkAdmission.source)
}
