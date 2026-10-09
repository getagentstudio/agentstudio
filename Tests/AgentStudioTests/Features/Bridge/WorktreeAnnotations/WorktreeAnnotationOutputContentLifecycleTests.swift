import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@MainActor
@Suite("Worktree annotation output content lifecycle")
struct WorktreeAnnotationOutputContentLifecycleTests {
    @Test("restart inspection streams exact SQLite bytes and rejects altered descriptors")
    func restartInspectionStreamsExactSQLiteBytesAndRejectsAlteredDescriptors() async throws {
        let fixture = try await makeRestartedOutputFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = await makeProvider(outputSource: fixture.outputSource)
        let descriptor = try await inspectDescriptor(
            provider: provider,
            attemptID: fixture.attemptID
        )

        for (label, alteredDescriptor) in try alteredDescriptors(from: descriptor) {
            let result = try await openContent(
                provider: provider,
                request: contentRequest(descriptor: alteredDescriptor, suffix: label)
            )
            #expect(result.body.isEmpty)
            #expect(result.errorMessage == "Content descriptor is not active")
        }

        let exactResult = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: descriptor, suffix: "exact")
        )
        let secondExactResult = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: descriptor, suffix: "exact-again")
        )

        #expect(exactResult.body == fixture.exactBytes)
        #expect(exactResult.errorMessage == nil)
        #expect(secondExactResult.body.isEmpty)
        #expect(secondExactResult.errorMessage == "Content descriptor is not active")
    }

    @Test("issued descriptors are metadata-only and bounded")
    func issuedDescriptorsAreBounded() async throws {
        let fixture = try await makeRestartedOutputFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var descriptors: [BridgeProductAnnotationOutputContentDescriptor] = []
        for _ in 0...AppPolicies.Bridge.worktreeAnnotationMaximumIssuedOutputDescriptors {
            descriptors.append(
                try await fixture.outputSource.descriptor(
                    attemptID: fixture.attemptID,
                    surface: .file
                )
            )
        }

        await #expect(throws: BridgeWorktreeAnnotationOutputSourceError.descriptorMismatch) {
            try await fixture.outputSource.body(for: descriptors[0])
        }
        let newestDescriptor = try #require(descriptors.last)
        let newestBody = try await fixture.outputSource.body(for: newestDescriptor)
        #expect(newestBody.data == fixture.exactBytes)
    }

    @Test("strict output content contracts accept exactly stored versions one and two")
    func strictOutputContentContractsAcceptOnlySupportedVersions() throws {
        let descriptor: [String: Any] = [
            "attemptId": "00000000-0000-7000-8000-000000000015",
            "contentKind": "annotation.output",
            "contentType": "text/markdown; charset=utf-8",
            "declaredByteLength": 5,
            "descriptorId": "00000000-0000-7000-8000-000000000016",
            "encoding": "utf-8",
            "expectedSha256": String(repeating: "a", count: 64),
            "formatVersion": 1,
            "maximumBytes": 5,
            "outputKind": "clipboard_markdown",
            "surface": "file",
        ]

        for supportedVersion in [1, 2] {
            let request = try BridgeProductStrictJSON.decode(
                BridgeProductContentRequest.self,
                from: try JSONSerialization.data(withJSONObject: [
                    "contentKind": "annotation.output",
                    "contentRequestId": "annotation-output-content-supported-\(supportedVersion)",
                    "descriptor": descriptor.merging(["formatVersion": supportedVersion]) { _, replacement in
                        replacement
                    },
                    "kind": "content.open",
                    "leaseId": "annotation-output-lease-supported",
                    "operationCorrelationId": NSNull(),
                    "paneSessionId": "pane-session-1",
                    "wireVersion": 2,
                    "workerDerivationEpoch": 0,
                    "workerInstanceId": "worker-instance-1",
                ])
            )
            guard case .annotationOutput(let decoded) = request else {
                Issue.record("Expected annotation output content request")
                continue
            }
            #expect(decoded.descriptor.formatVersion == supportedVersion)
            guard case .annotationOutput(let identity) = decoded.admission.identity else {
                Issue.record("Expected annotation output content identity")
                continue
            }
            #expect(identity.formatVersion == supportedVersion)
        }

        for mutation in [
            ["contentKind": "annotation.bytes"],
            ["contentType": "application/json; charset=utf-8"],
            ["formatVersion": 0],
            ["formatVersion": 3],
            ["unexpected": true],
        ] {
            #expect(throws: (any Error).self) {
                _ = try BridgeProductStrictJSON.decode(
                    BridgeProductContentRequest.self,
                    from: try JSONSerialization.data(withJSONObject: [
                        "contentKind": "annotation.output",
                        "contentRequestId": "annotation-output-content-invalid",
                        "descriptor": descriptor.merging(mutation) { _, replacement in replacement },
                        "kind": "content.open",
                        "leaseId": "annotation-output-lease-invalid",
                        "operationCorrelationId": NSNull(),
                        "paneSessionId": "pane-session-1",
                        "wireVersion": 2,
                        "workerDerivationEpoch": 0,
                        "workerInstanceId": "worker-instance-1",
                    ])
                )
            }
        }
    }

    private func alteredDescriptors(
        from descriptor: BridgeProductAnnotationOutputContentDescriptor
    ) throws -> [(String, BridgeProductAnnotationOutputContentDescriptor)] {
        [
            (
                "digest",
                try copyDescriptor(descriptor, expectedSHA256: String(repeating: "b", count: 64))
            ),
            (
                "length",
                try copyDescriptor(
                    descriptor,
                    declaredByteLength: descriptor.declaredByteLength + 1,
                    maximumBytes: descriptor.maximumBytes + 1
                )
            ),
            (
                "kind",
                try copyDescriptor(
                    descriptor,
                    contentType: "application/json; charset=utf-8",
                    outputKind: .jsonFile
                )
            ),
            (
                "attempt",
                try copyDescriptor(
                    descriptor,
                    attemptID: UUID(uuidString: "00000000-0000-7000-8000-000000000099")!
                )
            ),
            (
                "surface",
                try copyDescriptor(descriptor, surface: .review)
            ),
        ]
    }

    private func copyDescriptor(
        _ descriptor: BridgeProductAnnotationOutputContentDescriptor,
        attemptID: UUID? = nil,
        contentType: String? = nil,
        declaredByteLength: Int? = nil,
        expectedSHA256: String? = nil,
        maximumBytes: Int? = nil,
        outputKind: WorktreeAnnotationOutputKind? = nil,
        surface: BridgeProductSurface? = nil
    ) throws -> BridgeProductAnnotationOutputContentDescriptor {
        try .init(
            attemptID: attemptID ?? descriptor.attemptID,
            contentType: contentType ?? descriptor.contentType,
            declaredByteLength: declaredByteLength ?? descriptor.declaredByteLength,
            descriptorID: descriptor.descriptorID,
            expectedSHA256: expectedSHA256 ?? descriptor.expectedSHA256,
            formatVersion: descriptor.formatVersion,
            maximumBytes: maximumBytes ?? descriptor.maximumBytes,
            outputKind: outputKind ?? descriptor.outputKind,
            surface: surface ?? descriptor.surface
        )
    }

    private func makeProvider(
        outputSource: BridgePaneProductWorktreeAnnotationOutputSource
    ) async -> BridgePaneProductSchemeProvider {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        return BridgePaneProductSchemeProvider(
            annotationOutputSource: outputSource,
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
    }

    private func inspectDescriptor(
        provider: BridgePaneProductSchemeProvider,
        attemptID: WorktreeAnnotationOutputAttemptID
    ) async throws -> BridgeProductAnnotationOutputContentDescriptor {
        let request = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: Data(
                """
                {"call":{"method":"file.annotations.output.inspect","request":{"attemptId":"\(attemptID.rawValue.uuidString.lowercased())"}},"kind":"product.call","paneSessionId":"pane-session-1","requestId":"annotation-output-inspect-1","requestSequence":1,"wireVersion":2,"workerDerivationEpoch":0,"workerInstanceId":"worker-instance-1"}
                """.utf8
            )
        )
        let response = await provider.response(for: request)
        guard case .callCompleted(let completed) = response,
            case .fileAnnotationsOutputInspect(let result) = completed.call
        else {
            throw TestError.expectedDescriptor
        }
        return result.descriptor
    }

    private func contentRequest(
        descriptor: BridgeProductAnnotationOutputContentDescriptor,
        suffix: String
    ) throws -> BridgeProductContentRequest {
        try BridgeProductStrictJSON.decode(
            BridgeProductContentRequest.self,
            from: JSONEncoder().encode(
                AnnotationOutputContentRequestTest(descriptor: descriptor, suffix: suffix)
            )
        )
    }

    private func openContent(
        provider: BridgePaneProductSchemeProvider,
        request: BridgeProductContentRequest
    ) async throws -> ContentResult {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in
            await provider.runContentProducer(
                request: request,
                lease: lease,
                productAdmission: harness.productAdmission.context,
                session: harness.session
            )
        }
        let lease = try bridgeProductAcceptedLease(registration)
        let decoder = try BridgeProductContentFrameDecoder()
        let openingDelivery = try await nextFrame(for: lease, in: harness)
        let opening = try #require(decoder.append(openingDelivery.frame.data).first)
        #expect(opening.header.kind == "content.accepted")
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: harness.productAdmission.context
            )
        )
        var body = Data()
        while true {
            let delivery = try await nextFrame(for: lease, in: harness)
            let frame = try #require(decoder.append(delivery.frame.data).first)
            switch frame.header {
            case .data:
                let observed = await harness.session.acknowledgeContentFrameObservation(
                    try contentFrameAcknowledgement(
                        for: request.admission,
                        contentSequence: delivery.frame.sequence
                    ),
                    productAdmission: harness.productAdmission.context
                )
                #expect(observed)
                body.append(frame.payload)
            case .end:
                try await harness.closeProducer(lease)
                return .init(body: body, errorMessage: nil)
            case .error(let header):
                try await harness.closeProducer(lease)
                return .init(body: body, errorMessage: header.safeMessage)
            case .accepted, .reset:
                Issue.record("Unexpected non-terminal annotation output content frame")
            }
        }
    }

    private func nextFrame(
        for lease: BridgeProductProducerLease,
        in harness: BridgeProductSessionLifecycleHarness
    ) async throws -> BridgeProductProducerFrameDelivery {
        let result = await harness.session.pullProducerFrame(
            for: lease,
            productAdmission: harness.productAdmission.context
        )
        guard case .frame(let delivery) = result else {
            throw TestError.expectedFrame
        }
        #expect(
            await harness.session.acknowledgeProducerFrameConsumed(
                delivery.receipt,
                productAdmission: harness.productAdmission.context
            ))
        return delivery
    }

    private func contentFrameAcknowledgement(
        for admission: BridgeProductContentAdmission,
        contentSequence: Int
    ) throws -> BridgeProductContentFrameAcknowledgement {
        try BridgeProductStrictJSON.decode(
            BridgeProductContentFrameAcknowledgement.self,
            from: try JSONSerialization.data(withJSONObject: [
                "contentRequestId": admission.contentRequestId,
                "receivedThroughContentSequence": contentSequence,
                "kind": "content.acknowledge",
                "leaseId": admission.leaseId,
                "paneSessionId": admission.paneSessionId,
                "wireVersion": admission.wireVersion,
                "workerInstanceId": admission.workerInstanceId,
            ])
        )
    }
}

private struct RestartedOutputFixture {
    let attemptID: WorktreeAnnotationOutputAttemptID
    let exactBytes: Data
    let outputSource: BridgePaneProductWorktreeAnnotationOutputSource
    let root: URL
}

@MainActor
private func makeRestartedOutputFixture() async throws -> RestartedOutputFixture {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "annotation-output-content-\(UUIDv7.generate().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coreURL = root.appending(path: "core.sqlite")
    let localURL = root.appending(path: "local.sqlite")
    let workspaceID = UUIDv7.generate()
    let firstDatastore = WorkspaceSQLiteDatastoreFactory(
        coreDatabaseURL: coreURL,
        localDatabaseURL: localURL
    ).makeDatastore()
    guard case .prepared = await firstDatastore.prepareDatabasesForBoot() else {
        throw WorktreeAnnotationServiceError.unavailable
    }
    let workspaceStore = WorkspaceStore(
        identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceID),
        sqliteDatastore: firstDatastore,
        startsObserving: false
    )
    guard case .initializedDefaultWorkspace = await workspaceStore.loadCanonicalComposition() else {
        throw WorktreeAnnotationServiceError.unavailable
    }
    let firstStore = WorktreeAnnotationServiceActor(
        sqliteAdapter: .init(workspaceID: workspaceID, datastore: firstDatastore)
    )
    let preparedOutput = try await prepareSavedOutput(
        firstStore: firstStore,
        workspaceID: workspaceID
    )

    let restartedDatastore = WorkspaceSQLiteDatastoreFactory(
        coreDatabaseURL: coreURL,
        localDatabaseURL: localURL
    ).makeDatastore()
    guard case .prepared = await restartedDatastore.prepareDatabasesForBoot() else {
        throw WorktreeAnnotationServiceError.unavailable
    }
    let restartedStore = WorktreeAnnotationServiceActor(
        sqliteAdapter: .init(workspaceID: workspaceID, datastore: restartedDatastore)
    )
    return .init(
        attemptID: preparedOutput.attemptID,
        exactBytes: preparedOutput.exactBytes,
        outputSource: .init(store: restartedStore),
        root: root
    )
}

private struct PreparedSavedOutput {
    let attemptID: WorktreeAnnotationOutputAttemptID
    let exactBytes: Data
}

@MainActor
private func prepareSavedOutput(
    firstStore: WorktreeAnnotationServiceActor,
    workspaceID: UUID
) async throws -> PreparedSavedOutput {
    let savedFixture = try await createSavedLocatedMessage(
        store: firstStore,
        workspaceID: workspaceID
    )
    let attemptID = WorktreeAnnotationOutputAttemptID.generate()
    let snapshot = try makeSavedOutputSnapshot(
        attemptID: attemptID,
        savedFixture: savedFixture
    )
    let markdownPresentation = WorktreeAnnotationMarkdownPresentationContext(
        worktreeLabel: "agent-studio.review-comments",
        comparisonLabel: nil
    )
    let exactBytes = WorktreeAnnotationBatchProjector.markdownData(
        for: snapshot,
        presentation: markdownPresentation
    )
    let selectedMessages = [
        WorktreeAnnotationSQLiteRepository.OutputMessageSelection(
            messageID: savedFixture.message.id,
            expectedSavedRevision: savedFixture.savedRevision
        )
    ]
    let projection = try await firstStore.captureProjection(
        worktreeID: savedFixture.detail.session.worktreeID,
        demandedSessionIDs: [savedFixture.detail.session.id]
    )
    _ = try await firstStore.prepareOutput(
        .init(
            attemptID: attemptID,
            sessionID: savedFixture.detail.session.id,
            outputKind: .clipboardMarkdown,
            formatVersion: 2,
            contentType: "text/markdown; charset=utf-8",
            canonicalSnapshot: snapshot,
            exactBytes: exactBytes,
            markdownPresentation: markdownPresentation,
            destinationPath: nil,
            repeatedFromAttemptID: nil,
            selectedMessages: selectedMessages,
            expectedProjectionRevision: projection.revision,
            now: Date(timeIntervalSince1970: 3)
        )
    )
    _ = try await firstStore.finalizeOutputAttempt(
        attemptID: attemptID,
        eventKind: .copied,
        now: Date(timeIntervalSince1970: 4)
    )

    return .init(attemptID: attemptID, exactBytes: exactBytes)
}

private struct SavedLocatedMessageFixture {
    let detail: WorktreeAnnotationSessionDetail
    let message: WorktreeAnnotationMessage
    let savedRevision: Int
    let threadID: WorktreeAnnotationThreadID
}

@MainActor
private func createSavedLocatedMessage(
    store: WorktreeAnnotationServiceActor,
    workspaceID: UUID
) async throws -> SavedLocatedMessageFixture {
    let draftDetail = try await store.createRootDraft(
        .init(
            admission: .implicitOrSingle,
            repositoryID: "repo-1",
            worktreeID: "worktree-1",
            sourceFingerprint: .init(
                repositoryID: "repo-1",
                worktreeID: "worktree-1",
                fileSourceIdentity: "source-1",
                reviewComparisonOrigin: nil
            ),
            origin: .located(
                .init(
                    repositoryRelativePath: "Sources/Feature.swift",
                    startLine: 1,
                    endLine: 1,
                    sourceRole: .file,
                    diffSide: nil,
                    sourceIdentity: "source-1",
                    selectedExcerpt: "let value = 1",
                    contextBefore: nil,
                    contextAfter: nil
                )
            ),
            body: "## Preserve this behavior",
            editToken: "editor-1",
            now: Date(timeIntervalSince1970: 1)
        )
    )
    let draftMessage = try #require(draftDetail.threads.first?.messages.first)
    let savedDetail = try await store.saveDraft(
        .init(
            sessionID: draftDetail.session.id,
            messageID: draftMessage.id,
            editToken: "editor-1",
            expectedMessageRevision: draftMessage.semanticRevision,
            expectedDraftRevision: 0,
            now: Date(timeIntervalSince1970: 2)
        )
    )
    let savedMessage = try #require(savedDetail.threads.first?.messages.first)
    return try .init(
        detail: savedDetail,
        message: savedMessage,
        savedRevision: #require(savedMessage.savedRevision),
        threadID: #require(savedDetail.threads.first?.thread.id)
    )
}

private func makeSavedOutputSnapshot(
    attemptID: WorktreeAnnotationOutputAttemptID,
    savedFixture: SavedLocatedMessageFixture
) throws -> WorktreeAnnotationBatchSnapshotV2 {
    try WorktreeAnnotationBatchProjector.makeSnapshot(
        .init(
            batchID: attemptID,
            createdAt: Date(timeIntervalSince1970: 3),
            sessionDetail: savedFixture.detail,
            selectedMessages: [
                .init(
                    messageID: savedFixture.message.id,
                    expectedSavedRevision: savedFixture.savedRevision
                )
            ],
            placementsByThreadID: [
                savedFixture.threadID: .init(
                    placement: .exact,
                    currentPath: "Sources/Feature.swift",
                    currentStartLine: 1,
                    currentEndLine: 1,
                    currentSourceIdentity: "source-1"
                )
            ],
            sessionLabel: "Current review",
            worktreeLabel: "agent-studio.review-comments",
            comparisonLabel: nil
        )
    )
}

private struct ContentResult {
    let body: Data
    let errorMessage: String?
}

private struct AnnotationOutputContentRequestTest: Encodable {
    let descriptor: BridgeProductAnnotationOutputContentDescriptor
    let suffix: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("annotation.output", forKey: .contentKind)
        try container.encode("annotation-output-content-\(suffix)", forKey: .contentRequestId)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encode("content.open", forKey: .kind)
        try container.encode("annotation-output-lease-\(suffix)", forKey: .leaseId)
        try container.encodeNil(forKey: .operationCorrelationId)
        try container.encode("pane-session-1", forKey: .paneSessionId)
        try container.encode(2, forKey: .wireVersion)
        try container.encode(0, forKey: .workerDerivationEpoch)
        try container.encode("worker-instance-1", forKey: .workerInstanceId)
    }

    private enum CodingKeys: String, CodingKey {
        case contentKind
        case contentRequestId
        case descriptor
        case kind
        case leaseId
        case operationCorrelationId
        case paneSessionId
        case wireVersion
        case workerDerivationEpoch
        case workerInstanceId
    }
}

private enum TestError: Error {
    case expectedDescriptor
    case expectedFrame
}
