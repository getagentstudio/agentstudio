import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation transport exact output interleavings", .serialized)
struct WorktreeAnnotationOutputInterleavingTests {
    @Test(
        "Listed staleness is conflict before capture and during held preparation, with zero durable output",
        arguments: OutputSelectionMutation.allCases, [false, true])
    func listedStalenessHasNoEffects(mutation: OutputSelectionMutation, heldPreparation: Bool) async throws {
        let destination = HeldStep<Void>("output destination before materialization and preparation")
        defer { destination.release() }
        let effect = HeldDestinationOutputEffect(hold: heldPreparation ? destination : nil)
        let harness = try await makeTransportAdapterHarness(outputEffect: effect)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let selected = try await createSavedOutputRoot(body: "Listed comment", editToken: "listed", harness: harness)
        let command = try exactOutputCommand(sessionID: selected.sessionID, messages: [selected.message])
        if !heldPreparation {
            try await mutateListedSelection(mutation, selected: selected, harness: harness)
        }
        let operation = Task {
            await harness.adapter.apply(
                command, surface: .file,
                correlation: try makeAnnotationCorrelation(
                    requestID: "selection-\(mutation.rawValue)-\(heldPreparation)"),
                productAdmission: harness.productAdmission
            )
        }
        if heldPreparation {
            try await destination.firstArrival()
            try await mutateListedSelection(mutation, selected: selected, harness: harness)
            destination.release()
        }
        let outcome = try await operation.value
        #expect(outcome.status == .failed(.conflict))
        #expect(await effect.requests.isEmpty)
        let counts = try await outputDurableCounts(harness: harness)
        #expect(counts == [0, 0, 0])
    }

    @Test("File source generation may change from seven to eight during held source capture")
    func fileGenerationChangeDuringCapturePreservesExactBatch() async throws {
        let capture = HeldStep<Void>("File output source capture")
        defer { capture.release() }
        let generation = OutputSourceGeneration()
        let effect = TransportTestOutputEffect(outcome: .succeeded(destinationPath: nil))
        let harness = try await makeTransportAdapterHarness(
            outputEffect: effect,
            sourceRefresh: { try await capture.arrive(()) },
            sourceGeneration: { await generation.read() }
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let selected = try await createSavedOutputRoot(
            body: "Generation independent", editToken: "generation", harness: harness)
        #expect(await generation.value == 7)
        let readsBeforeOutput = await generation.readCount
        let command = try exactOutputCommand(sessionID: selected.sessionID, messages: [selected.message])
        let operation = Task {
            await harness.adapter.apply(
                command, surface: .file,
                correlation: try makeAnnotationCorrelation(requestID: "changed-file-generation"),
                productAdmission: harness.productAdmission
            )
        }
        try await capture.firstArrival()
        await generation.advance()
        capture.release()
        let outcome = try await operation.value
        guard case .output(.succeeded(let summary)) = outcome.status else {
            Issue.record("Expected output after File generation change, got \(outcome.status)")
            return
        }
        #expect(await generation.value == 8)
        #expect(await generation.readCount == readsBeforeOutput)
        #expect(summary.messageCount == 1)
        let request = try #require(await effect.lastRequest)
        let snapshot = try WorktreeAnnotationBatchProjector.decodeJSON(request.exactBytes)
        #expect(snapshot.entries.map(\.messageID) == [selected.message.id])
        #expect(snapshot.entries.map(\.bodyMarkdown) == ["Generation independent"])
    }

    @Test(
        "Mutable context during preparation preserves exactly the requested batch",
        arguments: OutputContextMutation.allCases)
    func unrelatedChangesDoNotFenceOutput(mutation: OutputContextMutation) async throws {
        let destination = HeldStep<Void>("captured output waiting for destination")
        defer { destination.release() }
        let effect = HeldDestinationOutputEffect(hold: destination)
        let harness = try await makeTransportAdapterHarness(outputEffect: effect)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let selected = try await createSavedOutputRoot(
            body: "Selected original", editToken: "selected", harness: harness)
        let unlisted = try await createSavedOutputRoot(
            sessionID: selected.sessionID, body: "Unlisted original", editToken: "unlisted", harness: harness)
        let command = try exactOutputCommand(sessionID: selected.sessionID, messages: [selected.message])
        let operation = Task {
            await harness.adapter.apply(
                command, surface: .file,
                correlation: try makeAnnotationCorrelation(requestID: "context-\(mutation.rawValue)"),
                productAdmission: harness.productAdmission
            )
        }
        try await destination.firstArrival()
        try await mutateOutputContext(mutation, selected: selected, unlisted: unlisted, harness: harness)
        destination.release()
        let outcome = try await operation.value
        guard case .output(.succeeded(let summary)) = outcome.status else {
            Issue.record("Expected exact-set success after \(mutation), got \(outcome.status)")
            return
        }
        #expect(summary.messageCount == 1)
        let request = try #require(await effect.requests.first)
        let snapshot = try WorktreeAnnotationBatchProjector.decodeJSON(request.exactBytes)
        #expect(snapshot.entries.map(\.messageID) == [selected.message.id])
        #expect(snapshot.entries.map(\.bodyMarkdown) == ["Selected original"])
        let persisted = try await harness.store.inspectOutputAttempt(attemptID: .init(rawValue: summary.attemptId))
        #expect(persisted.memberships.map(\.messageID) == [selected.message.id])
        #expect(try await outputDurableCounts(harness: harness) == [1, 1, 1])
    }
}

enum OutputSelectionMutation: String, CaseIterable, Sendable {
    case changedRevision, deleted, openDraft, foreignSession
}

enum OutputContextMutation: String, CaseIterable, Sendable {
    case sourceRefresh, resolve, unlistedEdit, unrelatedWorktreePublication, projectionBump, lifecycle
}

@MainActor
func exactOutputCommand(
    sessionID: WorktreeAnnotationSessionID,
    messages: [WorktreeAnnotationMessage],
    outputKind: String = "jsonFile"
) throws -> BridgeProductWorktreeAnnotationCommandRequest {
    let destination = outputKind == "jsonFile" ? ", \"destination\": \"remembered\"" : ""
    return try decodeAnnotationCommand(
        """
        { "operation": {
          "kind": "output.scope.commit", "scope": "pending",
          "outputKind": "\(outputKind)"\(destination),
          "sessionId": "\(sessionID.rawValue.uuidString.lowercased())",
          "messages": \(try outputSelectionJSON(messages))
        } }
        """
    )
}

@MainActor
private func mutateListedSelection(
    _ mutation: OutputSelectionMutation,
    selected: SavedOutputRoot,
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws {
    switch mutation {
    case .changedRevision, .openDraft:
        let detail = try await harness.store.flushDraft(
            .init(
                sessionID: selected.sessionID, messageID: selected.message.id,
                editToken: "changed", expectedMessageRevision: selected.message.semanticRevision,
                expectedDraftRevision: nil, body: "Changed selected body", now: Date(timeIntervalSince1970: 700))
        )
        if mutation == .changedRevision {
            let message = try #require(detail.detail.threads.flatMap(\.messages).first { $0.id == selected.message.id })
            _ = try await harness.store.saveDraft(
                .init(
                    sessionID: selected.sessionID, messageID: message.id, editToken: "changed",
                    expectedMessageRevision: message.semanticRevision,
                    expectedDraftRevision: try #require(message.draft?.draftRevision),
                    now: Date(timeIntervalSince1970: 701))
            )
        }
    case .deleted:
        // There is no saved-message deletion service command; exercise durable disappearance.
        let pool = try outputDatabasePool(harness: harness)
        try await pool.write { database in
            try database.execute(
                sql: "DELETE FROM annotation_message WHERE id = ?", arguments: [selected.message.id.databaseValue])
        }
    case .foreignSession:
        let detail = try await persistedDetail(sessionID: selected.sessionID, harness: harness)
        let other = try await harness.store.createRootDraft(
            .init(
                admission: .newSession, repositoryID: "repository-1", worktreeID: "worktree-foreign",
                sourceFingerprint: .init(
                    repositoryID: "repository-1", worktreeID: "worktree-foreign",
                    fileSourceIdentity: "foreign-source", reviewComparisonOrigin: nil
                ),
                origin: try #require(detail.threads.first?.thread.origin), body: "Foreign draft",
                editToken: "foreign", now: Date(timeIntervalSince1970: 702))
        )
        try #require(other.session.id != selected.sessionID)
        let pool = try outputDatabasePool(harness: harness)
        try await pool.write { database in
            try database.execute(
                sql: "UPDATE annotation_thread SET session_id = ?, created_ordinal = 2 WHERE id = ?",
                arguments: [other.session.id.databaseValue, selected.threadID.databaseValue]
            )
        }
    }
}

@MainActor
private func mutateOutputContext(
    _ mutation: OutputContextMutation,
    selected: SavedOutputRoot,
    unlisted: SavedOutputRoot,
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws {
    let detail = try await persistedDetail(sessionID: selected.sessionID, harness: harness)
    switch mutation {
    case .sourceRefresh:
        _ = try await harness.store.setSourceRelationship(
            .init(
                sessionID: selected.sessionID, relationship: .uncertain,
                sourceFingerprint: .init(
                    repositoryID: "repository-1", worktreeID: "worktree-1",
                    fileSourceIdentity: "refreshed-source", reviewComparisonOrigin: nil),
                expectedSessionRevision: detail.session.semanticRevision,
                now: Date(timeIntervalSince1970: 710))
        )
    case .resolve:
        let thread = try #require(detail.threads.first { $0.thread.id == selected.threadID }).thread
        _ = try await harness.store.setThreadResolution(
            .init(
                sessionID: selected.sessionID, threadID: selected.threadID, resolution: .resolved,
                expectedThreadRevision: thread.semanticRevision, now: Date(timeIntervalSince1970: 711))
        )
    case .unlistedEdit:
        try await mutateListedSelection(.changedRevision, selected: unlisted, harness: harness)
    case .unrelatedWorktreePublication:
        _ = try await harness.store.createRootDraft(
            .init(
                admission: .newSession, repositoryID: "repository-1", worktreeID: "worktree-other",
                sourceFingerprint: .init(
                    repositoryID: "repository-1", worktreeID: "worktree-other",
                    fileSourceIdentity: "other-source", reviewComparisonOrigin: nil),
                origin: try #require(detail.threads.first?.thread.origin), body: "Other worktree",
                editToken: "other-worktree", now: Date(timeIntervalSince1970: 712))
        )
    case .lifecycle:
        _ = try await harness.store.setSessionLifecycle(
            .init(
                sessionID: selected.sessionID, lifecycle: .completed,
                expectedSessionRevision: detail.session.semanticRevision,
                expectedOpenThreadCount: detail.threads.filter { $0.thread.resolution == .open }.count,
                confirmsUnresolvedWork: true, now: Date(timeIntervalSince1970: 713)
            )
        )
    case .projectionBump:
        let before = try await harness.store.captureProjection(
            worktreeID: "worktree-1", demandedSessionIDs: [selected.sessionID])
        _ = try await createSavedOutputRoot(
            sessionID: selected.sessionID, body: "New unlisted comment", editToken: "new-unlisted", harness: harness)
        let after = try await harness.store.captureProjection(
            worktreeID: "worktree-1", demandedSessionIDs: [selected.sessionID])
        #expect(after.revision > before.revision)
    }
}

@MainActor
func outputDatabasePool(harness: WorktreeAnnotationTransportAdapterHarness) throws -> DatabasePool {
    try SQLiteDatabaseFactory.makeFileBackedPool(
        at: harness.root.appending(path: "local.sqlite"), label: "annotation-output-interleaving")
}

@MainActor
func outputDurableCounts(harness: WorktreeAnnotationTransportAdapterHarness) async throws -> [Int] {
    let pool = try outputDatabasePool(harness: harness)
    return try await pool.read { database in
        try ["annotation_output_attempt", "annotation_output_attempt_message", "annotation_output_event"].map { table in
            try #require(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)"))
        }
    }
}

actor HeldDestinationOutputEffect: WorktreeAnnotationOutputEffect {
    private let hold: HeldStep<Void>?
    private(set) var requests: [WorktreeAnnotationOutputEffectRequest] = []

    init(hold: HeldStep<Void>?) { self.hold = hold }

    func rememberedJSONFolder() async -> String {
        if let hold { try? await hold.arrive(()) }
        return "/tmp"
    }

    func chooseJSONDestination(productAdmission: BridgeProductAdmissionContext)
        -> WorktreeAnnotationOutputDestinationOutcome
    {
        .selected(path: "/tmp")
    }

    func revealJSONFile(path: String, productAdmission: BridgeProductAdmissionContext) -> Bool { false }

    func perform(_ request: WorktreeAnnotationOutputEffectRequest) -> WorktreeAnnotationOutputEffectOutcome {
        requests.append(request)
        return .succeeded(destinationPath: nil)
    }
}

private actor OutputSourceGeneration {
    private(set) var value = 7
    private(set) var readCount = 0

    func read() -> Int {
        readCount += 1
        return value
    }

    func advance() { value = 8 }
}
