import AgentStudioTestSupport
import Foundation
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

@Suite("Bridge development annotation durability HTTP routing")
struct BridgeAnnotationDurabilityHTTPRoutingTests {
    @MainActor
    @Test("root and five replies persist through product HTTP and SQLite restart")
    func rootAndFiveRepliesPersistThroughProductHTTPAndSQLiteRestart() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-annotation-root-five-replies"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-http-annotation-root-five-replies-\(paneID.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let expectedBodies = [
            "Backend durability root.",
            "Backend durability reply 1.",
            "Backend durability reply 2.",
            "Backend durability reply 3.",
            "Backend durability reply 4.",
            "Backend durability reply 5.",
        ]

        let firstRuntime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneID,
            worktreeRoot: repositoryURL
        )
        let savedThread = try await createHTTPRootAndFiveSavedReplies(
            runtime: firstRuntime,
            expectedBodies: expectedBodies
        )
        try await firstRuntime.composition.shutdown()

        let restartedRuntime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneID,
            worktreeRoot: repositoryURL
        )

        // Act
        let restoredProjection = try await restoreHTTPRootAndFiveSavedReplies(
            runtime: restartedRuntime,
            sessionID: savedThread.sessionID
        )
        try await restartedRuntime.composition.shutdown()

        // Assert
        assertHTTPRootAndFiveSavedReplies(
            projection: restoredProjection,
            expectedBodies: expectedBodies,
            expectedMessageIDs: savedThread.messageIDs,
            expectedSessionID: savedThread.sessionID,
            expectedThreadID: savedThread.threadID
        )
    }
}

private struct HTTPSavedAnnotationThreadObservation {
    let messageIDs: [UUID]
    let sessionID: UUID
    let threadID: UUID
}

private struct HTTPSavedRootObservation {
    let createReceipt: BridgeProductWorktreeAnnotationMessageEntry
    let savedReceipt: BridgeProductWorktreeAnnotationMessageEntry
    let sessionID: UUID
}

private struct HTTPAnnotationMessageMutation {
    let body: String
    let createReceipt: BridgeProductWorktreeAnnotationMessageEntry
    let editToken: String
    let requestSequence: Int
    let sessionID: UUID
}

@MainActor
private func createHTTPRootAndFiveSavedReplies(
    runtime: HTTPDevelopmentProductRuntime,
    expectedBodies: [String]
) async throws -> HTTPSavedAnnotationThreadObservation {
    try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
        let connection = try await openHTTPProductConnection(client: client)
        let context = try await prepareHTTPAnnotationAuthoring(
            client: client,
            runtime: runtime,
            connection: connection
        )
        let rootBody = try #require(expectedBodies.first)
        let root = try await createHTTPSavedRoot(
            body: rootBody,
            client: client,
            connection: connection,
            commentSubscription: context.commentSubscription,
            descriptorID: context.descriptor.descriptorId,
            recorder: context.metadataStream.recorder
        )
        let sessionID = root.sessionID
        var latestSavedReceipt = root.savedReceipt
        var messageIDs = [latestSavedReceipt.messageId]
        var requestSequence = 11
        for (replyIndex, replyBody) in expectedBodies.dropFirst().enumerated() {
            let editToken = "backend-reply-editor-\(replyIndex + 1)"
            let replyCreateOutcome = try await executeHTTPAnnotationCommand(
                client: client,
                connection: connection,
                operation: [
                    "body": "\(replyBody) initial",
                    "editToken": editToken,
                    "expectedThreadRevision": latestSavedReceipt.threadRevision,
                    "kind": "reply.create",
                    "sessionId": sessionID.uuidString.lowercased(),
                    "threadId": latestSavedReceipt.threadId.uuidString.lowercased(),
                ],
                requestID: "backend-reply-\(replyIndex + 1)-create",
                requestSequence: requestSequence
            )
            #expect(replyCreateOutcome.status == .committed)
            let replyCreateReceipt = try requireHTTPAnnotationMessage(replyCreateOutcome)
            _ = try await waitForHTTPAnnotationCatalogCommit(
                client: client,
                connection: connection,
                recorder: context.metadataStream.recorder
            )
            latestSavedReceipt = try await flushAndSaveHTTPAnnotationMessage(
                client: client,
                connection: connection,
                recorder: context.metadataStream.recorder,
                mutation: HTTPAnnotationMessageMutation(
                    body: replyBody,
                    createReceipt: replyCreateReceipt,
                    editToken: editToken,
                    requestSequence: requestSequence + 1,
                    sessionID: sessionID
                )
            )
            messageIDs.append(latestSavedReceipt.messageId)
            requestSequence += 3
        }
        let savedProjection = try await fetchHTTPFileAnnotationProjection(
            client: client,
            host: runtime.host,
            connection: connection,
            demandedSessionIDs: [sessionID],
            sourceGeneration: context.fileSourceGeneration,
            requestSequence: requestSequence
        )
        assertHTTPRootAndFiveSavedReplies(
            projection: savedProjection,
            expectedBodies: expectedBodies,
            expectedMessageIDs: messageIDs,
            expectedSessionID: sessionID,
            expectedThreadID: root.createReceipt.threadId
        )
        try await shutdownHTTPHostAndDrainMetadataStream(
            host: runtime.host,
            drain: context.metadataStream.drain
        )
        return HTTPSavedAnnotationThreadObservation(
            messageIDs: messageIDs,
            sessionID: sessionID,
            threadID: root.createReceipt.threadId
        )
    }
}

private func createHTTPSavedRoot(
    body: String,
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    commentSubscription: BridgeProductSubscriptionOpenAcceptedResponse,
    descriptorID: String,
    recorder: HTTPMetadataFrameRecorder
) async throws -> HTTPSavedRootObservation {
    let createOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: [
            "admission": ["kind": "implicitOrSingle"],
            "body": "\(body) initial",
            "editToken": "backend-root-editor",
            "kind": "root.create",
            "origin": [
                "diffSide": NSNull(),
                "endLine": 2,
                "kind": "located",
                "path": "tracked.txt",
                "sourceIdentity": descriptorID,
                "sourceRole": "file",
                "startLine": 2,
            ],
        ],
        requestID: "backend-root-create",
        requestSequence: 7
    )
    #expect(createOutcome.status == .committed)
    let sessionID = try #require(createOutcome.sessionId)
    let createReceipt = try requireHTTPAnnotationMessage(createOutcome)
    try await acceptHTTPCommentViewScope(
        client: client,
        connection: connection,
        openResponse: commentSubscription,
        requestSequence: 8,
        scopeRevision: 2,
        sessionIDs: [sessionID]
    )
    _ = try await waitForHTTPAnnotationCatalogCommit(
        client: client,
        connection: connection,
        recorder: recorder
    )
    let savedReceipt = try await flushAndSaveHTTPAnnotationMessage(
        client: client,
        connection: connection,
        recorder: recorder,
        mutation: HTTPAnnotationMessageMutation(
            body: body,
            createReceipt: createReceipt,
            editToken: "backend-root-editor",
            requestSequence: 9,
            sessionID: sessionID
        )
    )
    return HTTPSavedRootObservation(
        createReceipt: createReceipt,
        savedReceipt: savedReceipt,
        sessionID: sessionID
    )
}

private func flushAndSaveHTTPAnnotationMessage(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    mutation: HTTPAnnotationMessageMutation
) async throws -> BridgeProductWorktreeAnnotationMessageEntry {
    let flushOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: [
            "body": mutation.body,
            "editToken": mutation.editToken,
            "expectedDraftRevision": try #require(mutation.createReceipt.draft?.revision),
            "expectedMessageRevision": mutation.createReceipt.messageRevision,
            "kind": "draft.flush",
            "messageId": mutation.createReceipt.messageId.uuidString.lowercased(),
            "sessionId": mutation.sessionID.uuidString.lowercased(),
        ],
        requestID: "backend-draft-flush-\(mutation.requestSequence)",
        requestSequence: mutation.requestSequence
    )
    #expect(flushOutcome.status == .committed)
    let flushReceipt = try requireHTTPAnnotationMessage(flushOutcome)
    _ = try await waitForHTTPAnnotationSessionChange(
        client: client,
        connection: connection,
        recorder: recorder,
        expectedSessionID: mutation.sessionID
    )
    let saveOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: [
            "editToken": mutation.editToken,
            "expectedDraftRevision": try #require(flushReceipt.draft?.revision),
            "expectedMessageRevision": flushReceipt.messageRevision,
            "kind": "draft.save",
            "messageId": flushReceipt.messageId.uuidString.lowercased(),
            "sessionId": mutation.sessionID.uuidString.lowercased(),
        ],
        requestID: "backend-draft-save-\(mutation.requestSequence + 1)",
        requestSequence: mutation.requestSequence + 1
    )
    #expect(saveOutcome.status == .committed)
    let saveReceipt = try requireHTTPAnnotationMessage(saveOutcome)
    #expect(saveReceipt.messageId == mutation.createReceipt.messageId)
    #expect(saveReceipt.draft == nil)
    #expect(saveReceipt.savedRevision != nil)
    _ = try await waitForHTTPAnnotationSessionChange(
        client: client,
        connection: connection,
        recorder: recorder,
        expectedSessionID: mutation.sessionID
    )
    return saveReceipt
}

@MainActor
private func restoreHTTPRootAndFiveSavedReplies(
    runtime: HTTPDevelopmentProductRuntime,
    sessionID: UUID
) async throws -> HTTPAnnotationProjectionSnapshot {
    try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
        let context = try await prepareHTTPAnnotationLocatedRestore(
            client: client,
            runtime: runtime,
            sessionID: sessionID
        )
        let projection = try await fetchHTTPFileAnnotationProjection(
            client: client,
            host: runtime.host,
            connection: context.connection,
            demandedSessionIDs: [sessionID],
            sourceGeneration: context.fileSourceGeneration,
            requestSequence: 7
        )
        try await shutdownHTTPHostAndDrainMetadataStream(
            host: runtime.host,
            drain: context.metadataStream.drain
        )
        return projection
    }
}

private func assertHTTPRootAndFiveSavedReplies(
    projection: HTTPAnnotationProjectionSnapshot,
    expectedBodies: [String],
    expectedMessageIDs: [UUID],
    expectedSessionID: UUID,
    expectedThreadID: UUID
) {
    let messages = projection.messages.map(\.message).sorted { $0.ordinal < $1.ordinal }
    #expect(messages.count == 6)
    #expect(messages.map(\.savedBody) == expectedBodies.map(Optional.some))
    #expect(messages.map(\.messageId) == expectedMessageIDs)
    #expect(messages.map(\.ordinal) == Array(0..<6))
    #expect(messages.allSatisfy { $0.draft == nil })
    #expect(messages.allSatisfy { $0.sessionId == expectedSessionID })
    #expect(messages.allSatisfy { $0.threadId == expectedThreadID })
    #expect(Set(messages.map(\.messageId)).count == 6)
}
