import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation transport output selection", .serialized)
struct WorktreeAnnotationOutputSelectionTests {
    @Test("Pending excludes resolved threads while All and reopened Pending preserve canonical membership")
    func pendingExcludesResolvedThreadsWithoutChangingAllMembership() async throws {
        let outputEffect = TransportTestOutputEffect(outcome: .failed("capture selection"))
        let harness = try await makeTransportAdapterHarness(outputEffect: outputEffect)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let fixture = try await prepareMixedOutputSelectionFixture(harness: harness)

        try await executeOutputScope(
            harness: harness,
            scope: .pending,
            sessionID: fixture.openLocked.sessionID,
            requestID: "resolved-pending"
        )
        try await executeOutputScope(
            harness: harness,
            scope: .all,
            sessionID: fixture.openLocked.sessionID,
            requestID: "resolved-all"
        )

        let resolvedRequests = await outputEffect.requests
        #expect(resolvedRequests.count == 2)
        let resolvedPendingSnapshot = try WorktreeAnnotationBatchProjector.decodeJSON(
            try #require(resolvedRequests.first?.exactBytes)
        )
        #expect(
            outputBodiesByMessageID(resolvedPendingSnapshot)
                == [fixture.openLocked.message.id: "Open locked human"]
        )
        #expect(resolvedPendingSnapshot.entries.first?.placement != .unavailable)

        let allSnapshot = try WorktreeAnnotationBatchProjector.decodeJSON(
            try #require(resolvedRequests.last?.exactBytes)
        )
        #expect(
            outputBodiesByMessageID(allSnapshot)
                == [
                    fixture.openLocked.message.id: "Open locked human",
                    fixture.resolvedHuman.message.id: "Resolved human",
                    fixture.agent.message.id: "Agent context",
                    fixture.handledHuman.message.id: "Handled human",
                ]
        )
        #expect(
            allSnapshot.entries.first { $0.messageID == fixture.resolvedHuman.message.id }?.resolution
                == .resolved
        )

        let reopenedThread = try #require(
            fixture.resolvedDetail.threads.first { $0.thread.id == fixture.resolvedHuman.threadID }
        )
        _ = try await harness.store.setThreadResolution(
            .init(
                sessionID: fixture.openLocked.sessionID,
                threadID: fixture.resolvedHuman.threadID,
                resolution: .open,
                expectedThreadRevision: reopenedThread.thread.semanticRevision,
                now: Date(timeIntervalSince1970: 503)
            )
        )
        try await executeOutputScope(
            harness: harness,
            scope: .pending,
            sessionID: fixture.openLocked.sessionID,
            requestID: "reopened-pending"
        )

        let reopenedRequests = await outputEffect.requests
        #expect(reopenedRequests.count == 3)
        let reopenedPendingSnapshot = try WorktreeAnnotationBatchProjector.decodeJSON(
            try #require(reopenedRequests.last?.exactBytes)
        )
        #expect(
            outputBodiesByMessageID(reopenedPendingSnapshot)
                == [
                    fixture.openLocked.message.id: "Open locked human",
                    fixture.resolvedHuman.message.id: "Resolved human",
                ]
        )
    }

    @Test("Resolve invalidates an older displayed Pending revision before any output effect")
    func resolveRejectsOlderDisplayedPendingRevisionWithoutEffect() async throws {
        let outputEffect = TransportTestOutputEffect(outcome: .succeeded(destinationPath: nil))
        let harness = try await makeTransportAdapterHarness(outputEffect: outputEffect)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let savedRoot = try await createSavedOutputRoot(
            body: "Must not escape stale Pending",
            editToken: "stale-resolve",
            harness: harness
        )
        let displayedProjection = try await harness.store.captureProjection(
            worktreeID: "worktree-1",
            demandedSessionIDs: [savedRoot.sessionID]
        )
        let displayedSessionRevision = try #require(
            displayedProjection.repositorySnapshot.details.first?.session.semanticRevision
        )
        let displayedThreadRevision = try #require(
            displayedProjection.repositorySnapshot.details.first?.threads.first?.thread.semanticRevision
        )
        _ = try await harness.store.setThreadResolution(
            .init(
                sessionID: savedRoot.sessionID,
                threadID: savedRoot.threadID,
                resolution: .resolved,
                expectedThreadRevision: displayedThreadRevision,
                now: Date(timeIntervalSince1970: 601)
            )
        )

        let outcome = await harness.adapter.apply(
            try decodeAnnotationCommand(
                """
                { "operation": {
                  "displayedProjectionRevision": \(displayedProjection.revision),
                  "expectedSessionRevision": \(displayedSessionRevision),
                  "kind": "output.scope.commit", "outputKind": "clipboardMarkdown",
                  "scope": "pending",
                  "sessionId": "\(savedRoot.sessionID.rawValue.uuidString.lowercased())",
                  "sourceGeneration": 7
                } }
                """
            ),
            surface: .file,
            correlation: try makeAnnotationCorrelation(requestID: "stale-after-resolve"),
            productAdmission: harness.productAdmission
        )

        #expect(outcome.status == .failed(.conflict))
        #expect(await outputEffect.requests.isEmpty)
        let persisted = try await persistedDetail(sessionID: savedRoot.sessionID, harness: harness)
        #expect(persisted.threads.first?.thread.resolution == .resolved)
        #expect(persisted.threads.first?.messages.first?.handled == false)
    }

    @Test("Reveal refuses unknown attempts and files that no longer exist")
    func revealIsBoundToARecordedFile() async throws {
        let outputEffect = TransportTestOutputEffect(
            outcome: .succeeded(destinationPath: nil),
            revealSucceeds: false
        )
        let harness = try await makeTransportAdapterHarness(outputEffect: outputEffect)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let savedRoot = try await createSavedOutputRoot(
            body: "Export for reveal", editToken: "reveal-output", harness: harness
        )
        let unknownID = UUIDv7.generate().uuidString.lowercased()
        let unknown = await harness.adapter.apply(
            try decodeAnnotationCommand(
                "{ \"operation\": { \"attemptId\": \"\(unknownID)\", \"kind\": \"output.reveal\" } }"
            ),
            surface: .file,
            correlation: try makeAnnotationCorrelation(requestID: "unknown-reveal"),
            productAdmission: harness.productAdmission
        )
        #expect(unknown.status == .failed(.notFound))

        try await executeOutputScope(
            harness: harness,
            scope: .all,
            sessionID: savedRoot.sessionID,
            requestID: "export-for-reveal"
        )
        let recordedOutput = try #require(
            try await harness.store.fetchOutputHistory(sessionID: savedRoot.sessionID, limit: 1).first
        )
        let missingFile = await harness.adapter.apply(
            try decodeAnnotationCommand(
                """
                { "operation": {
                  "attemptId": "\(recordedOutput.attemptID.rawValue.uuidString.lowercased())",
                  "kind": "output.reveal"
                } }
                """
            ),
            surface: .file,
            correlation: try makeAnnotationCorrelation(requestID: "missing-file-reveal"),
            productAdmission: harness.productAdmission
        )
        #expect(missingFile.status == .failed(.outputFileMissing))
    }
}

private struct SavedOutputRoot {
    let sessionID: WorktreeAnnotationSessionID
    let threadID: WorktreeAnnotationThreadID
    let message: WorktreeAnnotationMessage
}

private struct MixedOutputSelectionFixture {
    let openLocked: SavedOutputRoot
    let resolvedHuman: SavedOutputRoot
    let agent: SavedOutputRoot
    let handledHuman: SavedOutputRoot
    let resolvedDetail: WorktreeAnnotationSessionDetail
}

@MainActor
private func prepareMixedOutputSelectionFixture(
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> MixedOutputSelectionFixture {
    let openLocked = try await createSavedOutputRoot(
        body: "Open locked human", editToken: "open-locked", harness: harness
    )
    let resolvedHuman = try await createSavedOutputRoot(
        sessionID: openLocked.sessionID,
        body: "Resolved human",
        editToken: "resolved-human",
        harness: harness
    )
    let agent = try await createSavedOutputRoot(
        sessionID: openLocked.sessionID,
        body: "Agent context",
        editToken: "agent-context",
        harness: harness
    )
    let handledHuman = try await createSavedOutputRoot(
        sessionID: openLocked.sessionID,
        body: "Handled human",
        editToken: "handled-human",
        harness: harness
    )
    let draftedHuman = try await createSavedOutputRoot(
        sessionID: openLocked.sessionID,
        body: "Saved body hidden by draft",
        editToken: "drafted-human",
        harness: harness
    )
    let databasePool = try SQLiteDatabaseFactory.makeFileBackedPool(
        at: harness.root.appending(path: "local.sqlite"),
        label: "annotation-output-selection-test"
    )
    try await databasePool.write { database in
        try database.execute(
            sql: "UPDATE annotation_message SET status = 'locked' WHERE id = ?",
            arguments: [openLocked.message.id.databaseValue]
        )
        try database.execute(
            sql: "UPDATE annotation_message SET author_kind = 'agent' WHERE id = ?",
            arguments: [agent.message.id.databaseValue]
        )
        try database.execute(
            sql: "UPDATE annotation_message SET handled = 1 WHERE id = ?",
            arguments: [handledHuman.message.id.databaseValue]
        )
    }
    _ = try await harness.store.flushDraft(
        .init(
            sessionID: draftedHuman.sessionID,
            messageID: draftedHuman.message.id,
            editToken: "drafted-human-v2",
            expectedMessageRevision: draftedHuman.message.semanticRevision,
            expectedDraftRevision: nil,
            body: "Working replacement",
            now: Date(timeIntervalSince1970: 501)
        )
    )
    let currentDetail = try await persistedDetail(sessionID: openLocked.sessionID, harness: harness)
    let resolvedThread = try #require(
        currentDetail.threads.first { $0.thread.id == resolvedHuman.threadID }
    )
    let resolvedDetail = try await harness.store.setThreadResolution(
        .init(
            sessionID: openLocked.sessionID,
            threadID: resolvedHuman.threadID,
            resolution: .resolved,
            expectedThreadRevision: resolvedThread.thread.semanticRevision,
            now: Date(timeIntervalSince1970: 502)
        )
    )
    return .init(
        openLocked: openLocked,
        resolvedHuman: resolvedHuman,
        agent: agent,
        handledHuman: handledHuman,
        resolvedDetail: resolvedDetail
    )
}

@MainActor
private func createSavedOutputRoot(
    sessionID: WorktreeAnnotationSessionID? = nil,
    body: String,
    editToken: String,
    harness: WorktreeAnnotationTransportAdapterHarness
) async throws -> SavedOutputRoot {
    let admission =
        if let sessionID {
            "{ \"kind\": \"selected\", \"sessionId\": \"\(sessionID.rawValue.uuidString.lowercased())\" }"
        } else {
            "{ \"kind\": \"implicitOrSingle\" }"
        }
    let createOutcome = await harness.adapter.apply(
        try decodeAnnotationCommand(
            """
            { "operation": {
              "admission": \(admission),
              "body": "\(body)",
              "editToken": "\(editToken)",
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
            } }
            """
        ),
        surface: .file,
        correlation: try makeAnnotationCorrelation(requestID: "create-\(editToken)"),
        productAdmission: harness.productAdmission
    )
    let createdSessionID = WorktreeAnnotationSessionID(rawValue: try #require(createOutcome.sessionId))
    guard case .message(_, let receipt) = try #require(createOutcome.receipt) else {
        throw WorktreeAnnotationRepositoryError.invalidState
    }
    let savedDetail = try await harness.store.saveDraft(
        .init(
            sessionID: createdSessionID,
            messageID: .init(rawValue: receipt.messageId),
            editToken: editToken,
            expectedMessageRevision: receipt.messageRevision,
            expectedDraftRevision: try #require(receipt.draft?.revision),
            now: Date(timeIntervalSince1970: 500)
        )
    )
    let savedThread = try #require(
        savedDetail.threads.first { $0.thread.id.rawValue == receipt.threadId }
    )
    let savedMessage = try #require(
        savedThread.messages.first { $0.id.rawValue == receipt.messageId }
    )
    return .init(
        sessionID: createdSessionID,
        threadID: savedThread.thread.id,
        message: savedMessage
    )
}

private func outputBodiesByMessageID(
    _ snapshot: WorktreeAnnotationBatchSnapshotV2
) -> [WorktreeAnnotationMessageID: String] {
    Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.messageID, $0.bodyMarkdown) })
}
