import AgentStudioCore
import AgentStudioInfrastructure
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File metadata source")
struct BridgePaneProductFileMetadataSourceTests {
    @Test("a rebuilt File context continues the retained view's revision namespace")
    func rebuiltContextContinuesRetainedViewRevisions() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand()
        let firstCollector = ProductFileSourceFactCollector()

        try await source.open(
            subscription: subscription,
            productAdmission: fixture.productAdmission.context
        ) { event in await firstCollector.append(event, source: source) }
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId,
            demand: demand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in await firstCollector.append(event, source: source) }
        let first = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId,
                demand: demand,
                productAdmission: fixture.productAdmission.context
            )
        )
        let firstDescriptor = try #require(
            (await firstCollector.events).compactMap(\.availableDescriptorForTest).first
        )
        try Data("rebuilt content\n".utf8).write(to: fixture.demandedFileURL)

        let secondCollector = ProductFileSourceFactCollector()
        try await source.open(
            subscription: subscription,
            productAdmission: fixture.productAdmission.context
        ) { event in await secondCollector.append(event, source: source) }
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId,
            demand: demand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in await secondCollector.append(event, source: source) }
        let second = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId,
                demand: demand,
                productAdmission: fixture.productAdmission.context
            )
        )
        let secondDescriptor = try #require(
            (await secondCollector.events).compactMap(\.availableDescriptorForTest).first
        )

        #expect(second.memberStatus.revision > first.targetRevision)
        #expect(second.records.allSatisfy { $0.revision > first.targetRevision })
        #expect(secondDescriptor.source.subscriptionGeneration == 2)
        #expect(secondDescriptor.expectedSha256 != firstDescriptor.expectedSha256)
    }

    @Test("same-subscription source replacement excludes stale lineage and content")
    func sameSubscriptionSourceReplacementExcludesStaleLineageAndContent() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        let updatedSnapshot = try fixture.viewDemand()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let originalCollector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await originalCollector.append(event, source: source)
        }
        let originalDescriptor = try #require(
            (await originalCollector.events).compactMap(\.availableDescriptorForTest).first
        )
        let originalRequest = try fixture.contentRequest(descriptor: originalDescriptor)
        #expect(
            await source.contentReadPlan(
                for: originalRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )

        // Act
        let replacementCollector = ProductFileSourceFactCollector()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await replacementCollector.append(event, source: source)
        }
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await replacementCollector.append(event, source: source)
        }
        let replacementEvents = await replacementCollector.events
        let replacementDescriptor = try #require(
            replacementEvents.compactMap(\.availableDescriptorForTest).first
        )
        let replacementRequest = try fixture.contentRequest(descriptor: replacementDescriptor)
        let replacementPlanBeforePublish = await source.contentReadPlan(
            for: replacementRequest,
            productAdmission: fixture.productAdmission.context
        )
        try Data("replacement\n".utf8).write(to: fixture.demandedFileURL)
        let replacementEmissions = try await source.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: [fixture.demandedPath],
                timestamp: .now,
                batchSeq: 2
            ),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        #expect(originalDescriptor.source.subscriptionGeneration == 1)
        #expect(replacementDescriptor.source.subscriptionGeneration == 2)
        #expect(originalDescriptor.source != replacementDescriptor.source)
        #expect(
            await source.contentReadPlan(
                for: originalRequest,
                productAdmission: fixture.productAdmission.context
            ) == nil
        )
        #expect(replacementPlanBeforePublish != nil)
        #expect(!replacementEmissions.isEmpty)
        #expect(
            replacementEmissions.allSatisfy {
                $0.fact.sourceIdentity == replacementDescriptor.source
            }
        )
    }

    @Test("same-subscription replacement fences an in-flight stale producer")
    func sameSubscriptionReplacementFencesInFlightStaleProducer() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let materializationGate = ProductFileMaterializationGate()
        let source = fixture.makeSource(descriptorMaterializer: { request in
            await materializationGate.markStarted()
            await materializationGate.waitUntilReleased()
            return try await BridgePaneProductFileContentSource.materialize(request)
        })
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let staleCollector = ProductFileSourceFactCollector()
        let staleUpdateTask = Task {
            try await source.applyViewDemand(
                subscriptionId: openSnapshot.subscriptionId,
                demand: fixture.viewDemand(),
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                await staleCollector.append(event, source: source)
            }
        }
        await materializationGate.waitUntilStarted()
        await staleCollector.removeAll()

        // Act
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let replacementGeneration = try await source.currentWorktreeAnnotationSourceGeneration(
            productAdmission: fixture.productAdmission.context
        )
        await materializationGate.release()
        _ = try await staleUpdateTask.value

        // Assert
        #expect((await staleCollector.events).isEmpty)
        #expect(replacementGeneration == 2)
        #expect(
            try await source.currentWorktreeAnnotationSourceGeneration(
                productAdmission: fixture.productAdmission.context
            ) == replacementGeneration
        )
    }

    @Test("cancelling a retired subscription preserves the current annotation read context")
    func cancellingRetiredSubscriptionPreservesCurrentAnnotationReadContext() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let retiredSnapshot = try fixture.openSnapshot(subscriptionId: "file-subscription-a")
        try await source.open(
            subscription: retiredSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let currentOpenSnapshot = try fixture.openSnapshot(subscriptionId: "file-subscription-b")
        try await source.open(
            subscription: currentOpenSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let currentSnapshot = try fixture.viewDemand()
        let currentCollector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: currentOpenSnapshot.subscriptionId,
            demand: currentSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await currentCollector.append(event, source: source)
        }
        let currentDescriptor = try #require(
            (await currentCollector.events).compactMap(\.availableDescriptorForTest).first
        )
        let currentGeneration = try await source.currentWorktreeAnnotationSourceGeneration(
            productAdmission: fixture.productAdmission.context
        )

        // Act
        await source.cancel(subscriptionId: retiredSnapshot.subscriptionId)
        let currentFingerprint = try await source.currentWorktreeAnnotationFingerprint(
            productAdmission: fixture.productAdmission.context
        )
        let diagnostics = await source.diagnosticSnapshot()
        let capturedSource = try await source.captureWorktreeAnnotationSource(
            origin: BridgeProductWorktreeAnnotationOrigin(
                path: fixture.demandedPath,
                startLine: 1,
                endLine: 1,
                sourceRole: .file,
                diffSide: nil,
                sourceIdentity: currentDescriptor.descriptorId
            ),
            productAdmission: fixture.productAdmission.context
        )

        // Assert
        #expect(currentOpenSnapshot.subscriptionId == "file-subscription-b")
        #expect(currentGeneration == 2)
        #expect(diagnostics.subscriptionCount == 1)
        #expect(
            try await source.currentWorktreeAnnotationSourceGeneration(
                productAdmission: fixture.productAdmission.context
            ) == currentGeneration
        )
        #expect(capturedSource.fingerprint == currentFingerprint)
        #expect(currentFingerprint.fileSourceIdentity == currentDescriptor.source.sourceId)
    }

    @Test("nonmatching worktree and repository changes cannot route File metadata")
    func nonmatchingSourceChangesCannotRouteFileMetadata() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        try await source.open(
            subscription: fixture.openSnapshot(),
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let nonmatchingWorktreeChangeset = FileChangeset(
            worktreeId: UUIDv7.generate(),
            repoId: fixture.repoId,
            rootPath: fixture.rootURL,
            paths: [fixture.demandedPath],
            timestamp: .now,
            batchSeq: 3
        )
        let nonmatchingRepositoryChangeset = FileChangeset(
            worktreeId: fixture.worktreeId,
            repoId: UUIDv7.generate(),
            rootPath: fixture.rootURL,
            paths: [fixture.demandedPath],
            timestamp: .now,
            batchSeq: 4
        )

        // Act
        let worktreeEmissions = try await source.publish(
            changeset: nonmatchingWorktreeChangeset,
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let repositoryEmissions = try await source.publish(
            changeset: nonmatchingRepositoryChangeset,
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        #expect(worktreeEmissions.isEmpty)
        #expect(repositoryEmissions.isEmpty)
    }

    @Test("issued descriptor streams accepted data and terminal integrity frames")
    func issuedDescriptorStreamsContentFrames() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try ProductFileSourceFixture(
            fileCount: 1,
            demandedLineCount: 10_200,
            productAdmission: harness.productAdmission
        )
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let updatedSnapshot = try fixture.viewDemand()
        let collector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }
        let descriptor = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileContentDescriptor? in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return nil }
                return descriptor
            }.first
        )
        let fileRequest = try fixture.contentRequest(descriptor: descriptor)
        let expectedData = try Data(contentsOf: fixture.demandedFileURL)
        let expectedSHA256 = fileMetadataSourceSHA256Hex(expectedData)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let request = BridgeProductContentRequest.fileContent(fileRequest)
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
        var decodedFrames: [BridgeProductContentFrame] = []

        // Act
        while !decodedFrames.contains(where: { $0.isTerminalForTest }) {
            let queuedFrame = try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: lease,
                    from: harness.session,
                    productAdmission: harness.productAdmission.context
                )
            )
            let frames = try decoder.append(queuedFrame.data)
            decodedFrames.append(contentsOf: frames)
            if frames.contains(where: { if case .accepted = $0.header { true } else { false } }) {
                #expect(
                    await harness.session.acknowledgeContentFrameObservation(
                        try bridgeProductOpeningContentAcknowledgement(for: request),
                        productAdmission: harness.productAdmission.context
                    )
                )
            }
        }

        // Assert
        guard case .accepted = decodedFrames.first?.header,
            case .end(let endHeader) = decodedFrames.last?.header
        else {
            Issue.record("Expected accepted and end content frames")
            return
        }
        let dataFrames = decodedFrames.compactMap { frame -> Data? in
            guard case .data = frame.header else { return nil }
            return frame.payload
        }
        #expect(
            dataFrames.allSatisfy {
                $0.count <= BridgeProductWireContract.maximumContentDataPayloadBytes
            })
        #expect(dataFrames.reduce(into: Data()) { $0.append($1) } == expectedData)
        #expect(endHeader.endOfSource)
        #expect(endHeader.observedByteLength == expectedData.count)
        #expect(endHeader.observedSha256 == expectedSHA256)

        for _ in 0..<1000 where (await harness.session.producerSnapshot()).activeProducerTaskCount > 0 {
            await Task.yield()
        }
        let acknowledgement = try #require(await harness.session.unregisterProducer(lease))
        #expect(await harness.session.acknowledgeProducerLifecycle(acknowledgement))
    }

    @Test("exact issued File descriptor derives demand priority from committed path membership")
    func exactIssuedDescriptorDerivesCommittedDemandPriority() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let committedSnapshot = try fixture.viewDemand()
        let collector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: committedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }
        let descriptor = try #require(
            (await collector.events).compactMap(\.availableDescriptorForTest).first
        )
        let request = BridgeProductContentRequest.fileContent(
            try fixture.contentRequest(descriptor: descriptor)
        )
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = fixture.productAdmission.context
        await coordinator.apply(
            .subscriptionOpened(openSnapshot),
            productAdmission: productAdmission
        )
        let scopeRequest = try BridgeProductStrictJSON.decode(
            BridgeProductViewScopeRequest.self,
            from: Data(
                """
                {"kind":"subscription.setScope","wireVersion":2,"paneSessionId":"pane-session-1",\
                "workerInstanceId":"worker-instance-1","requestId":"file-priority-scope-1","requestSequence":3,\
                "subscriptionId":"file-subscription-1","subscriptionKind":"file.metadata",\
                "domain":"default","handle":"file-view-handle-1","incarnation":"file-incarnation-1",\
                "scopeRevision":1,"scope":{"kind":"file","changeFilter":{"kind":"none"},\
                "interests":[{"lane":"foreground","paths":["File-0000.swift"]}],"pathScope":[]}}
                """.utf8
            )
        )
        await coordinator.apply(.viewScopeAccepted(scopeRequest), productAdmission: productAdmission)

        // Act / Assert
        #expect(
            await coordinator.contentDemandInterest(
                for: request,
                productAdmission: productAdmission
            ) == .selected
        )

        await coordinator.apply(
            .subscriptionCancelled(openSnapshot),
            productAdmission: productAdmission
        )
        #expect(
            await coordinator.contentDemandInterest(
                for: request,
                productAdmission: productAdmission
            ) == .unspecified
        )
    }

    @Test("cancelled interest materialization cannot resurrect a removed subscription")
    func cancelledMaterializationCannotResurrectRemovedSubscription() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let gate = ProductFileMaterializationGate()
        let source = fixture.makeSource(descriptorMaterializer: { request in
            await gate.markStarted()
            await gate.waitUntilReleased()
            return try await BridgePaneProductFileContentSource.materialize(request)
        })
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let collector = ProductFileSourceFactCollector()
        let updateTask = Task {
            try await source.applyViewDemand(
                subscriptionId: openSnapshot.subscriptionId,
                demand: fixture.viewDemand(),
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                await collector.append(event, source: source)
            }
        }
        await gate.waitUntilStarted()
        await collector.removeAll()

        // Act
        updateTask.cancel()
        await source.cancel(subscriptionId: openSnapshot.subscriptionId)
        await gate.release()
        _ = await updateTask.result

        // Assert
        #expect((await collector.events).isEmpty)
    }

}

func fileMetadataSourceSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
