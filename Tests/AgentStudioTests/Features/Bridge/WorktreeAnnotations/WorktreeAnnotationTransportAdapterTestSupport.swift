import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
func prepareSavedOutputCommandFixture(
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> (sessionID: WorktreeAnnotationSessionID, message: WorktreeAnnotationMessage) {
    let createCorrelation = try makeAnnotationCorrelation(requestID: "annotation-output-create")
    let createOutcome = await harness.adapter.apply(
        try decodeAnnotationCommand(
            """
            {
              "operation": {
                "admission": { "kind": "implicitOrSingle" },
                "body": "## Preserve this behavior",
                "editToken": "editor-output",
                "kind": "root.create",
                "origin": {
                  "diffSide": null,
                  "endLine": 3,
                  "kind": "located",
                  "path": "Sources/Example.swift",
                  "sourceIdentity": "file-source-1",
                  "sourceRole": "file",
                  "startLine": 2
                }
              }
            }
            """
        ),
        surface: .file,
        correlation: createCorrelation,
        productAdmission: harness.productAdmission
    )
    let sessionID = WorktreeAnnotationSessionID(rawValue: try #require(createOutcome.sessionId))
    let draftDetail = try await persistedDetail(sessionID: sessionID, harness: harness)
    let draftMessage = try #require(draftDetail.threads.first?.messages.first)
    let savedDetail = try await harness.store.saveDraft(
        .init(
            sessionID: sessionID,
            messageID: draftMessage.id,
            editToken: "editor-output",
            expectedMessageRevision: draftMessage.semanticRevision,
            expectedDraftRevision: try #require(draftMessage.draft?.draftRevision),
            now: Date(timeIntervalSince1970: 101)
        )
    )
    return (sessionID, try #require(savedDetail.threads.first?.messages.first))
}

@MainActor
func executeOutputScope(
    harness: WorktreeAnnotationTransportAdapterHarness,
    scope: BridgeProductWorktreeAnnotationOperation.OutputScope,
    sessionID: WorktreeAnnotationSessionID,
    requestID: String
) async throws {
    let sessionIDString = sessionID.rawValue.uuidString.lowercased()
    let detail = try await persistedDetail(sessionID: sessionID, harness: harness)
    let messages = detail.threads.flatMap { thread in
        thread.messages.filter { message in
            message.savedBody != nil && message.savedRevision != nil && message.draft == nil
                && (scope == .all
                    || (thread.thread.resolution == .open
                        && message.authorKind == .human && !message.handled))
        }
    }
    let selectionJSON = try outputSelectionJSON(messages)
    _ = await harness.adapter.apply(
        try decodeAnnotationCommand(
            """
            { "operation": {
              "messages": \(selectionJSON),
              "kind": "output.scope.commit", "outputKind": "jsonFile",
              "destination": "remembered",
              "scope": "\(scope.rawValue)", "sessionId": "\(sessionIDString)"
            } }
            """
        ),
        surface: .file,
        correlation: try makeAnnotationCorrelation(requestID: requestID),
        productAdmission: harness.productAdmission
    )
}

struct TransportOutputHistoryFixture {
    let attemptID: WorktreeAnnotationOutputAttemptID
    let sessionID: WorktreeAnnotationSessionID
}

@MainActor
func prepareTransportOutputHistoryFixture(
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> TransportOutputHistoryFixture {
    let savedMessage = try await createSavedTransportMessage(harness: harness)
    let attemptID = WorktreeAnnotationOutputAttemptID.generate()
    let selectedMessages = [
        WorktreeAnnotationSQLiteRepository.OutputMessageSelection(
            messageID: savedMessage.message.id,
            expectedSavedRevision: savedMessage.savedRevision
        )
    ]
    let snapshot = try WorktreeAnnotationBatchProjector.makeSnapshot(
        .init(
            batchID: attemptID,
            createdAt: Date(timeIntervalSince1970: 102),
            sessionDetail: savedMessage.detail,
            selectedMessages: selectedMessages,
            placementsByThreadID: [:],
            sessionLabel: "Current review",
            worktreeLabel: "worktree-1",
            comparisonLabel: nil
        )
    )
    let markdownPresentation = WorktreeAnnotationMarkdownPresentationContext(
        worktreeLabel: "worktree-1",
        comparisonLabel: nil
    )
    _ = try await harness.store.prepareOutput(
        .init(
            attemptID: attemptID,
            sessionID: savedMessage.detail.session.id,
            outputKind: .clipboardMarkdown,
            formatVersion: snapshot.formatVersion,
            contentType: "text/markdown; charset=utf-8",
            canonicalSnapshot: snapshot,
            exactBytes: WorktreeAnnotationBatchProjector.markdownData(
                for: snapshot,
                presentation: markdownPresentation
            ),
            markdownPresentation: markdownPresentation,
            destinationPath: nil,
            repeatedFromAttemptID: nil,
            selectedMessages: selectedMessages,
            now: Date(timeIntervalSince1970: 102)
        )
    )
    _ = try await harness.store.finalizeOutputAttempt(
        attemptID: attemptID,
        eventKind: .copied,
        now: Date(timeIntervalSince1970: 103)
    )
    return .init(attemptID: attemptID, sessionID: savedMessage.detail.session.id)
}

struct SavedTransportMessage {
    let detail: WorktreeAnnotationSessionDetail
    let message: WorktreeAnnotationMessage
    let savedRevision: Int
}

@MainActor
func createSavedTransportMessage(
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> SavedTransportMessage {
    let createCorrelation = try makeAnnotationCorrelation(requestID: "annotation-history-create")
    let createOutcome = await harness.adapter.apply(
        try decodeAnnotationCommand(
            """
            {
              "operation": {
                "admission": { "kind": "implicitOrSingle" },
                "body": "Durable output body",
                "editToken": "editor-history",
                "kind": "root.create",
                "origin": {
                  "diffSide": null,
                  "endLine": 3,
                  "kind": "located",
                  "path": "Sources/Example.swift",
                  "sourceIdentity": "file-source-1",
                  "sourceRole": "file",
                  "startLine": 2
                }
              }
            }
            """
        ),
        surface: .file,
        correlation: createCorrelation,
        productAdmission: harness.productAdmission
    )
    let sessionID = WorktreeAnnotationSessionID(rawValue: try #require(createOutcome.sessionId))
    let draftDetail = try await persistedDetail(sessionID: sessionID, harness: harness)
    let draftMessage = try #require(draftDetail.threads.first?.messages.first)
    let savedDetail = try await harness.store.saveDraft(
        .init(
            sessionID: sessionID,
            messageID: draftMessage.id,
            editToken: "editor-history",
            expectedMessageRevision: draftMessage.semanticRevision,
            expectedDraftRevision: try #require(draftMessage.draft?.draftRevision),
            now: Date(timeIntervalSince1970: 101)
        )
    )
    let savedMessage = try #require(savedDetail.threads.first?.messages.first)
    return try .init(
        detail: savedDetail,
        message: savedMessage,
        savedRevision: #require(savedMessage.savedRevision)
    )
}

@MainActor
struct WorktreeAnnotationTransportAdapterHarness {
    let adapter: WorktreeAnnotationTransportAdapter
    let productAdmission: BridgeProductAdmissionContext
    let root: URL
    let store: WorktreeAnnotationServiceActor
}

@MainActor
func persistedDetail(
    sessionID: WorktreeAnnotationSessionID,
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> WorktreeAnnotationSessionDetail {
    let capture = try await harness.store.captureProjection(
        worktreeID: "worktree-1",
        demandedSessionIDs: [sessionID]
    )
    return try #require(capture.repositorySnapshot.details.first)
}

@MainActor
func makeTransportAdapterHarness(
    outputEffect: (any WorktreeAnnotationOutputEffect)? = nil,
    sourceRefresh: (@Sendable () async throws -> Void)? = nil,
    sourceGeneration: @escaping @Sendable () async throws -> Int = { 7 },
    sourceBody: String = "1 │ func example() {\n2 │ let value = 1\n3 │ return value\n4 │ }"
) async throws -> WorktreeAnnotationTransportAdapterHarness {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "annotation-transport-adapter-\(UUIDv7.generate().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let datastore = WorkspaceSQLiteDatastoreFactory(
        coreDatabaseURL: root.appending(path: "core.sqlite"),
        localDatabaseURL: root.appending(path: "local.sqlite")
    ).makeDatastore()
    guard case .prepared = await datastore.prepareDatabasesForBoot() else {
        throw WorktreeAnnotationServiceError.unavailable
    }
    let store = WorktreeAnnotationServiceActor(
        sqliteAdapter: .init(workspaceID: UUIDv7.generate(), datastore: datastore)
    )
    let fingerprint = WorktreeAnnotationSourceFingerprint(
        repositoryID: "repository-1",
        worktreeID: "worktree-1",
        fileSourceIdentity: "file-source-1",
        reviewComparisonOrigin: nil
    )
    let sourceResolver = WorktreeAnnotationSourceResolver(
        capture: { origin, _, _, _ in
            .init(
                fingerprint: fingerprint,
                origin: .located(
                    .init(
                        repositoryRelativePath: origin.path,
                        startLine: origin.startLine,
                        endLine: origin.endLine,
                        sourceRole: .file,
                        diffSide: nil,
                        sourceIdentity: origin.sourceIdentity,
                        selectedExcerpt: "2 │ let value = 1\n3 │ return value",
                        contextBefore: "1 │ func example() {",
                        contextAfter: "4 │ }"
                    )
                )
            )
        },
        currentFingerprint: { _, _, _ in fingerprint },
        refresh: { _, _, _, _ in
            try await sourceRefresh?()
            return .init(
                fingerprint: fingerprint,
                material: .available([
                    .init(
                        path: "Sources/Example.swift",
                        sourceRole: .file,
                        sourceIdentity: "file-source-1",
                        body: sourceBody
                    )
                ])
            )
        },
        currentSourceGeneration: { _, _, _ in try await sourceGeneration() }
    )
    let outputCoordinator = outputEffect.map {
        WorktreeAnnotationOutputCoordinatorActor(
            store: store,
            effect: $0,
            now: { Date(timeIntervalSince1970: 102) }
        )
    }
    return try WorktreeAnnotationTransportAdapterHarness(
        adapter: WorktreeAnnotationTransportAdapter(
            store: store,
            contextID: "pane-test",
            repositoryID: fingerprint.repositoryID,
            worktreeID: fingerprint.worktreeID,
            sourceResolver: sourceResolver,
            now: { Date(timeIntervalSince1970: 100) },
            outputCoordinator: outputCoordinator,
            outputLabels: .init(
                sessionLabel: "Current review",
                worktreeLabel: "agent-studio.review-comments",
                comparisonLabel: nil
            )
        ),
        productAdmission: BridgeProductAdmissionTestContext.make().context,
        root: root,
        store: store
    )
}

actor TransportTestOutputEffect: WorktreeAnnotationOutputEffect {
    private let outcome: WorktreeAnnotationOutputEffectOutcome
    private let revealSucceeds: Bool
    private(set) var requests: [WorktreeAnnotationOutputEffectRequest] = []
    var lastRequest: WorktreeAnnotationOutputEffectRequest? { requests.last }

    init(outcome: WorktreeAnnotationOutputEffectOutcome, revealSucceeds: Bool = true) {
        self.outcome = outcome
        self.revealSucceeds = revealSucceeds
    }

    func rememberedJSONFolder() -> String { "/tmp" }

    func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext)
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        .selected(path: "/tmp")
    }

    func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) -> Bool {
        _ = path
        return revealSucceeds
    }

    func perform(
        _ request: WorktreeAnnotationOutputEffectRequest
    ) -> WorktreeAnnotationOutputEffectOutcome {
        requests.append(request)
        return outcome
    }
}

func decodeAnnotationCommand(
    _ json: String
) throws -> BridgeProductWorktreeAnnotationCommandRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductWorktreeAnnotationCommandRequest.self,
        from: Data(json.utf8)
    )
}

func makeAnnotationCorrelation(requestID: String) throws -> BridgeProductControlCorrelation {
    try BridgeProductControlCorrelation(
        paneSessionId: "00000000-0000-7000-8000-000000000001",
        requestId: requestID,
        requestSequence: 1,
        workerInstanceId: "00000000-0000-7000-8000-000000000002"
    )
}

func outputSelectionJSON(_ messages: [WorktreeAnnotationMessage]) throws -> String {
    let selections = try messages.map { message in
        [
            "messageId": message.id.rawValue.uuidString.lowercased(),
            "savedRevision": try #require(message.savedRevision),
        ] as [String: Any]
    }
    return try #require(String(data: JSONSerialization.data(withJSONObject: selections), encoding: .utf8))
}
