import AgentStudioTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

@Suite("Bridge development annotation HTTP routing")
struct BridgeDevelopmentAnnotationHTTPRoutingTests {
    @MainActor
    @Test("successful annotation output returns its completed HTTP result")
    func successfulAnnotationOutputReturnsCompletedHTTPResult() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-annotation-output-result"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        for fileIndex in 0..<8 {
            try "extra file \(fileIndex)\n".write(
                to: repositoryURL.appending(path: "extra-\(fileIndex).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-http-annotation-output-result-\(paneID.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let runtime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneID,
            worktreeRoot: repositoryURL
        )
        try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
            try await assertHTTPAnnotationOutputResult(client: client, runtime: runtime)
        }
        try await runtime.composition.shutdown()
    }

    @MainActor
    @Test("annotation mutation converges through independent pane projections")
    func annotationMutationConvergesThroughIndependentPaneProjections() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-annotation-two-pane"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let paneAID = PaneId.generateUUIDv7().uuid
        let paneBID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-http-annotation-two-pane-\(paneAID.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let paneA = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneAID,
            worktreeRoot: repositoryURL
        )
        let paneB = try await makeSiblingHTTPDevelopmentProductRuntime(
            composition: paneA.composition,
            paneID: paneBID
        )
        try await withBridgeDevelopmentHTTPRouterTestClient(host: paneA.host) { clientA in
            try await withBridgeDevelopmentHTTPRouterTestClient(host: paneB.host) { clientB in
                let connectionA = try await openHTTPProductConnection(client: clientA)
                let connectionB = try await openHTTPProductConnection(client: clientB)
                let preparationA = try await prepareHTTPAnnotationAuthoring(
                    client: clientA,
                    runtime: paneA,
                    connection: connectionA
                )
                let preparationB = try await prepareHTTPAnnotationAuthoring(
                    client: clientB,
                    runtime: paneB,
                    connection: connectionB
                )
                let outcome = try await executeHTTPAnnotationCommand(
                    client: clientA,
                    connection: connectionA,
                    operation: twoPaneRootCreateOperation(
                        sourceIdentity: preparationA.descriptor.descriptorId
                    ),
                    requestID: "annotation-create-two-pane",
                    requestSequence: 7
                )
                guard case .committed = outcome.status,
                    let sessionID = outcome.sessionId
                else { throw HTTPAnnotationIntegrationError.annotationCommandFailed }
                try await acceptHTTPCommentScopeInBothPanes(
                    sessionID: sessionID,
                    clientA: clientA,
                    connectionA: connectionA,
                    clientB: clientB,
                    connectionB: connectionB,
                    commentSubscriptions: (preparationA.commentSubscription, preparationB.commentSubscription)
                )
                let catalogA = try await waitForHTTPAnnotationCatalogCommit(
                    client: clientA,
                    connection: connectionA,
                    recorder: preparationA.metadataStream.recorder
                )
                let catalogB = try await waitForHTTPAnnotationCatalogCommit(
                    client: clientB,
                    connection: connectionB,
                    recorder: preparationB.metadataStream.recorder
                )
                let projectionA = try await fetchHTTPFileAnnotationProjection(
                    client: clientA,
                    host: paneA.host,
                    connection: connectionA,
                    demandedSessionIDs: [sessionID],
                    sourceGeneration: preparationA.fileSourceGeneration,
                    requestSequence: 9
                )
                let projectionB = try await fetchHTTPFileAnnotationProjection(
                    client: clientB,
                    host: paneB.host,
                    connection: connectionB,
                    demandedSessionIDs: [sessionID],
                    sourceGeneration: preparationB.fileSourceGeneration,
                    requestSequence: 8
                )

                #expect(catalogA.targetRevision == catalogB.targetRevision)
                #expect(catalogA.putRecordKeys == catalogB.putRecordKeys)
                #expect(projectionA.header.projectionRevision == projectionB.header.projectionRevision)
                #expect(projectionA.header.sessions == projectionB.header.sessions)
                #expect(projectionA.messages == projectionB.messages)
                #expect(projectionB.messages.first?.message.draft?.body == "Visible from both panes")

                try await shutdownHTTPHostAndDrainMetadataStream(
                    host: paneA.host,
                    drain: preparationA.metadataStream.drain
                )
                try await shutdownHTTPHostAndDrainMetadataStream(
                    host: paneB.host,
                    drain: preparationB.metadataStream.drain
                )
            }
        }
        try await paneA.composition.shutdown()
    }

    @MainActor
    @Test("annotation draft survives a development host restart through the product HTTP carrier")
    func annotationDraftSurvivesDevelopmentHostRestart() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-annotation-restart"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let paneID = PaneId.generateUUIDv7().uuid
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-http-annotation-data-\(paneID.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let draftBody = "Draft restored from local.sqlite"

        let firstRuntime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneID,
            worktreeRoot: repositoryURL
        )
        let firstObservation = try await createHTTPAnnotationDraftBeforeRestart(
            runtime: firstRuntime,
            draftBody: draftBody
        )
        try await firstRuntime.composition.shutdown()

        let secondRuntime = try await makeHTTPDevelopmentProductRuntime(
            dataRoot: dataRoot,
            paneID: paneID,
            worktreeRoot: repositoryURL
        )
        let restoredProjection = try await restoreHTTPAnnotationDraftAfterRestart(
            runtime: secondRuntime,
            draftBody: draftBody,
            sessionID: firstObservation.sessionID
        )
        try await secondRuntime.composition.shutdown()

        #expect(firstObservation.connection.bootstrap.paneSessionId == paneID.uuidString)
        let restoredDraft = try #require(restoredProjection.messages.first?.message)
        #expect(restoredProjection.header.sessions.map(\.sessionId) == [firstObservation.sessionID])
        #expect(restoredDraft.draft?.body == draftBody)
        #expect(restoredDraft.savedBody == nil)
        #expect(restoredDraft.sessionId == firstObservation.sessionID)
    }

    @Test("metadata frame decode failure wakes a suspended recorder reader")
    func metadataFrameDecodeFailureWakesSuspendedRecorderReader() async throws {
        let recorder = try HTTPMetadataFrameRecorder()
        let pendingFrame = Task {
            try await recorder.nextFrame()
        }
        await recorder.waitUntilNextFrameSuspends()

        let writerError = await capturedErrorDescription {
            try await recorder.write(ByteBuffer(bytes: [0, 0, 0, 1, 0xFF]))
        }
        let readerError = await capturedErrorDescription {
            _ = try await pendingFrame.value
        }

        #expect(writerError != nil)
        #expect(readerError == writerError)
    }
}

@MainActor
private func assertHTTPAnnotationOutputResult(
    client: some TestClientProtocol,
    runtime: HTTPDevelopmentProductRuntime
) async throws {
    let connection = try await openHTTPProductConnection(client: client)
    let preparation = try await prepareHTTPAnnotationAuthoring(
        client: client,
        runtime: runtime,
        connection: connection,
        minimumFileBatchPartCount: connection.bootstrap.policy.viewCreditParts + 1
    )
    #expect(preparation.fileBatchPartCount > connection.bootstrap.policy.viewCreditParts)
    let createOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: twoPaneRootCreateOperation(sourceIdentity: preparation.descriptor.descriptorId),
        requestID: "annotation-output-result-create",
        requestSequence: 7
    )
    let createReceipt = try requireHTTPAnnotationMessage(createOutcome)
    let sessionID = try #require(createOutcome.sessionId)
    try await acceptHTTPCommentViewScope(
        client: client,
        connection: connection,
        openResponse: preparation.commentSubscription,
        requestSequence: 8,
        scopeRevision: 2,
        sessionIDs: [sessionID]
    )
    _ = try await waitForHTTPAnnotationCatalogCommit(
        client: client,
        connection: connection,
        recorder: preparation.metadataStream.recorder
    )
    let saveOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: [
            "editToken": "two-pane-editor",
            "expectedDraftRevision": try #require(createReceipt.draft?.revision),
            "expectedMessageRevision": createReceipt.messageRevision,
            "kind": "draft.save",
            "messageId": createReceipt.messageId.uuidString.lowercased(),
            "sessionId": sessionID.uuidString.lowercased(),
        ],
        requestID: "annotation-output-result-save",
        requestSequence: 9
    )
    #expect(saveOutcome.status == .committed)
    _ = try await waitForHTTPAnnotationSessionChange(
        client: client,
        connection: connection,
        recorder: preparation.metadataStream.recorder,
        expectedSessionID: sessionID
    )
    let projection = try await fetchHTTPFileAnnotationProjection(
        client: client,
        host: runtime.host,
        connection: connection,
        demandedSessionIDs: [sessionID],
        sourceGeneration: preparation.fileSourceGeneration,
        requestSequence: 10
    )
    let savedMessage = try #require(projection.messages.first?.message)
    let outputOutcome = try await executeHTTPAnnotationCommand(
        client: client,
        connection: connection,
        operation: [
            "displayedProjectionRevision": projection.header.projectionRevision,
            "expectedSessionRevision": savedMessage.sessionRevision,
            "kind": "output.scope.commit",
            "outputKind": "clipboardMarkdown",
            "scope": "all",
            "sessionId": sessionID.uuidString.lowercased(),
            "sourceGeneration": preparation.fileSourceGeneration,
        ],
        requestID: "annotation-output-result-copy",
        requestSequence: 11
    )
    guard case .output(.succeeded(let summary)) = outputOutcome.status else {
        Issue.record("Expected the successful output result to cross the HTTP response")
        return
    }
    #expect(summary.sessionId == sessionID)
    #expect(summary.outputKind == .clipboardMarkdown)
    #expect(summary.messageCount == 1)
    try await shutdownHTTPHostAndDrainMetadataStream(
        host: runtime.host,
        drain: preparation.metadataStream.drain
    )
}

@MainActor
private func acceptHTTPCommentScopeInBothPanes(
    sessionID: UUID,
    clientA: some TestClientProtocol,
    connectionA: HTTPProductConnection,
    clientB: some TestClientProtocol,
    connectionB: HTTPProductConnection,
    commentSubscriptions: (
        paneA: BridgeProductSubscriptionOpenAcceptedResponse,
        paneB: BridgeProductSubscriptionOpenAcceptedResponse
    )
) async throws {
    try await acceptHTTPCommentViewScope(
        client: clientA,
        connection: connectionA,
        openResponse: commentSubscriptions.paneA,
        requestSequence: 8,
        scopeRevision: 2,
        sessionIDs: [sessionID]
    )
    try await acceptHTTPCommentViewScope(
        client: clientB,
        connection: connectionB,
        openResponse: commentSubscriptions.paneB,
        requestSequence: 7,
        scopeRevision: 2,
        sessionIDs: [sessionID]
    )
}

private func twoPaneRootCreateOperation(sourceIdentity: String) -> [String: Any] {
    [
        "admission": ["kind": "implicitOrSingle"],
        "body": "Visible from both panes",
        "editToken": "two-pane-editor",
        "kind": "root.create",
        "origin": [
            "diffSide": NSNull(),
            "endLine": 2,
            "kind": "located",
            "path": "tracked.txt",
            "sourceIdentity": sourceIdentity,
            "sourceRole": "file",
            "startLine": 2,
        ],
    ]
}

@MainActor
private func makeSiblingHTTPDevelopmentProductRuntime(
    composition: BridgeDevelopmentServerCoreComposition,
    paneID: UUID
) async throws -> HTTPDevelopmentProductRuntime {
    let source = BridgeDevelopmentProductSource(
        paneID: paneID,
        paneState: composition.productSource.paneState,
        repoID: composition.productSource.repoID,
        reviewedSubjectLabel: composition.productSource.reviewedSubjectLabel,
        worktreeID: composition.productSource.worktreeID,
        worktreeRoot: composition.productSource.worktreeRoot
    )
    return try await HTTPDevelopmentProductRuntime(
        composition: composition,
        host: BridgeDevelopmentProductHost(
            source: source,
            worktreeAnnotationStore: composition.worktreeAnnotationStore,
            worktreeAnnotationOutputCoordinator: composition.worktreeAnnotationOutputCoordinator,
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: { target in
                composition.applyContributionTarget(target)
            }
        )
    )
}

@MainActor
private struct HTTPAnnotationDraftObservation {
    let connection: HTTPProductConnection
    let sessionID: UUID
}

@MainActor
private func createHTTPAnnotationDraftBeforeRestart(
    runtime: HTTPDevelopmentProductRuntime,
    draftBody: String
) async throws -> HTTPAnnotationDraftObservation {
    try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
        let connection = try await openHTTPProductConnection(client: client)
        let preparation = try await prepareHTTPAnnotationAuthoring(
            client: client,
            runtime: runtime,
            connection: connection
        )
        let createOperation: [String: Any] = [
            "admission": ["kind": "implicitOrSingle"],
            "body": draftBody,
            "editToken": "restart-editor-1",
            "kind": "root.create",
            "origin": [
                "diffSide": NSNull(),
                "endLine": 2,
                "kind": "located",
                "path": "tracked.txt",
                "sourceIdentity": preparation.descriptor.descriptorId,
                "sourceRole": "file",
                "startLine": 2,
            ],
        ]
        let createOutcome = try await executeHTTPAnnotationCommand(
            client: client,
            connection: connection,
            operation: createOperation,
            requestID: "annotation-create-before-restart",
            requestSequence: 7
        )
        guard case .committed = createOutcome.status,
            let sessionID = createOutcome.sessionId
        else { throw HTTPAnnotationIntegrationError.annotationCommandFailed }
        try await acceptHTTPCommentViewScope(
            client: client,
            connection: connection,
            openResponse: preparation.commentSubscription,
            requestSequence: 8,
            scopeRevision: 2,
            sessionIDs: [sessionID]
        )
        _ = try await waitForHTTPAnnotationCatalogCommit(
            client: client,
            connection: connection,
            recorder: preparation.metadataStream.recorder
        )
        let projection = try await fetchHTTPFileAnnotationProjection(
            client: client,
            host: runtime.host,
            connection: connection,
            demandedSessionIDs: [sessionID],
            sourceGeneration: preparation.fileSourceGeneration,
            requestSequence: 9
        )
        let createdMessage = try #require(projection.messages.first?.message)
        #expect(createdMessage.draft?.body == draftBody)
        #expect(createdMessage.savedBody == nil)
        let releaseOperation: [String: Any] = [
            "editToken": "restart-editor-1",
            "expectedDraftRevision": try #require(createdMessage.draft?.revision),
            "expectedMessageRevision": createdMessage.messageRevision,
            "kind": "draft.edit.release",
            "messageId": createdMessage.messageId.uuidString.lowercased(),
            "sessionId": sessionID.uuidString.lowercased(),
        ]
        let releaseOutcome = try await executeHTTPAnnotationCommand(
            client: client,
            connection: connection,
            operation: releaseOperation,
            requestID: "annotation-release-before-restart",
            requestSequence: 10
        )
        guard case .committed = releaseOutcome.status else {
            throw HTTPAnnotationIntegrationError.annotationCommandFailed
        }
        _ = try await waitForHTTPAnnotationSessionChange(
            client: client,
            connection: connection,
            recorder: preparation.metadataStream.recorder,
            expectedSessionID: sessionID
        )
        let releasedProjection = try await fetchHTTPFileAnnotationProjection(
            client: client,
            host: runtime.host,
            connection: connection,
            demandedSessionIDs: [sessionID],
            sourceGeneration: preparation.fileSourceGeneration,
            requestSequence: 11
        )
        #expect(releasedProjection.messages.first?.message.draft?.activeEditToken == nil)
        try await shutdownHTTPHostAndDrainMetadataStream(
            host: runtime.host,
            drain: preparation.metadataStream.drain
        )
        return HTTPAnnotationDraftObservation(connection: connection, sessionID: sessionID)
    }
}

@MainActor
private func restoreHTTPAnnotationDraftAfterRestart(
    runtime: HTTPDevelopmentProductRuntime,
    draftBody: String,
    sessionID: UUID
) async throws -> HTTPAnnotationProjectionSnapshot {
    try await withBridgeDevelopmentHTTPRouterTestClient(host: runtime.host) { client in
        let connection = try await openHTTPProductConnection(client: client)
        let metadataStream = try await startHTTPMetadataStream(
            host: runtime.host,
            connection: connection,
            streamID: "metadata-stream-annotation-second"
        )
        let _: BridgeProductMetadataStreamAcceptedFrame = try await waitForAcknowledgedMetadataFrame(
            client: client,
            connection: connection,
            recorder: metadataStream.recorder
        ) { frame -> BridgeProductMetadataStreamAcceptedFrame? in
            guard case .metadataStreamAccepted(let accepted) = frame else { return nil }
            return accepted
        }
        let fileSource = try await queryHTTPFileSource(
            client: client,
            connection: connection,
            requestSequence: 2,
        )
        _ = try await openHTTPSubscription(
            client: client,
            connection: connection,
            requestSequence: 3,
            subscription: [
                "source": try jsonObject(fileSource),
                "subscriptionKind": "file.metadata",
            ],
            subscriptionID: "file-metadata-annotation-second"
        )
        _ = try await waitForAcknowledgedSubscription(
            client: client,
            connection: connection,
            recorder: metadataStream.recorder,
            subscriptionID: "file-metadata-annotation-second"
        )
        try await acceptHTTPFileViewScope(
            path: nil,
            client: client,
            connection: connection,
            requestSequence: 4,
            subscriptionID: "file-metadata-annotation-second"
        )
        let acceptedFileSource = try await waitForHTTPFileSourceIdentity(
            client: client, connection: connection, recorder: metadataStream.recorder
        )
        let commentOpen = try await openHTTPSubscription(
            client: client,
            connection: connection,
            requestSequence: 5,
            subscription: ["subscriptionKind": "file.annotations"],
            subscriptionID: "file-annotations-second"
        )
        _ = try await waitForAcknowledgedSubscription(
            client: client,
            connection: connection,
            recorder: metadataStream.recorder,
            subscriptionID: "file-annotations-second"
        )
        try await acceptHTTPCommentViewScope(
            client: client,
            connection: connection,
            openResponse: commentOpen,
            requestSequence: 6,
            sessionIDs: [sessionID]
        )
        _ = try await waitForHTTPAnnotationCatalogCommit(
            client: client,
            connection: connection,
            recorder: metadataStream.recorder
        )
        let restoredProjection = try await fetchHTTPFileAnnotationProjection(
            client: client,
            host: runtime.host,
            connection: connection,
            demandedSessionIDs: [sessionID],
            sourceGeneration: acceptedFileSource.subscriptionGeneration,
            requestSequence: 7
        )
        #expect(restoredProjection.messages.first?.message.draft?.body == draftBody)
        try await shutdownHTTPHostAndDrainMetadataStream(
            host: runtime.host,
            drain: metadataStream.drain
        )
        return restoredProjection
    }
}
