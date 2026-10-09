import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {
    @Test("visible invalidation refreshes a pending-first E1 Review publication")
    func visibleInvalidationRefreshesPendingFirstInstallationBoundReviewPackage() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(fixture.artifact(diffId: UUIDv7.generate())),
                commandId: commandId,
                correlationId: nil
            )
        }
        try await fixture.factTrace.expectPendingCommand(commandId)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        try await fixture.factTrace.expectResumedBuildStarted(commandId)
        assertDiffCommandWasAccepted(await commandTask.value, commandId: commandId)
        try await fixture.factTrace.expectPackageDelivery(commandId)
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .completed)

        let initialPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: fixture.productAdmission
            )
        )
        let contributionCountBeforeInvalidation =
            await fixture.provider.recordedContributionRequests().count
        await fixture.setContributionComparison(
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "refreshed",
                    path: "Sources/App/Refreshed.swift",
                    sizeBytes: 100
                )
            ]
        )

        await fixture.controller.handleWorktreeProductInvalidation(
            .filesChanged(
                fixture.makeChangeset(
                    paths: ["Sources/App/Refreshed.swift"],
                    batchSequence: 71
                )
            )
        )
        let refreshAttempt = try await fixture.factTrace.nextAdmittedAttempt()
        try await fixture.factTrace.expectAttemptEnded(refreshAttempt, outcome: .succeeded)

        let refreshedPublication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: fixture.productAdmission
            )
        )
        #expect(refreshedPublication.publicationId != initialPublication.publicationId)
        #expect(
            await fixture.provider.recordedContributionRequests().count
                == contributionCountBeforeInvalidation + 1
        )
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-refreshed"])
        #expect(fixture.controller.paneState.diff.status == .ready)
        #expect(fixture.controller.refreshAdmissionCoordinator.diagnosticSnapshot.dirtyFact == nil)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("pending-first E1 publication remains readable through IPC selection and content")
    func pendingFirstInstallationBoundPublicationSupportsIPCReaders() async throws {
        let fixture = try await makeDiffCommandPageModeFixture(includesContentHandle: true)
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
        let contentHandle = try #require(fixture.contentHandle)

        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(fixture.artifact(diffId: UUIDv7.generate())),
                commandId: commandId,
                correlationId: nil
            )
        }
        try await fixture.factTrace.expectPendingCommand(commandId)
        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        try await fixture.factTrace.expectResumedBuildStarted(commandId)
        assertDiffCommandWasAccepted(await commandTask.value, commandId: commandId)
        try await fixture.factTrace.expectPackageDelivery(commandId)
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .completed)

        let publication = try #require(
            fixture.controller.reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: fixture.productAdmission
            )
        )
        let publishedHandle = try #require(
            publication.package.itemsById[contentHandle.itemId]?.contentRoles.head
        )
        #expect(publishedHandle == contentHandle)
        let directContentLease = try #require(
            fixture.controller.reviewPublicationCoordinator.acquireContentLease(
                handleId: contentHandle.handleId,
                packageId: publication.package.packageId,
                requestedGeneration: contentHandle.reviewGeneration,
                sourceIdentity: publication.package.query.queryId,
                productAdmission: fixture.productAdmission
            )
        )
        #expect(directContentLease.handle == contentHandle)
        #expect(fixture.controller.reviewPublicationCoordinator.settleContentLease(directContentLease))

        var selectionResult: IPCBridgeReviewSelectFileResult?
        do {
            selectionResult = try await fixture.controller.selectReviewItemForIPC(
                itemId: contentHandle.itemId,
                correlationId: nil
            )
        } catch {
            Issue.record("Current E1 IPC selection should read its committed Review publication: \(error)")
        }
        #expect(selectionResult?.itemId == contentHandle.itemId)
        #expect(selectionResult?.selected == true)
        if selectionResult != nil {
            let request = try await consumeBootstrapSurfaceSelectionRequest(
                producerLease: fixture.metadataProducerLease,
                installation: fixture.installation,
                productAdmission: fixture.productAdmission
            )
            if case .activateReviewTarget(_, _, let source, let target) = request.navigationCommand {
                #expect(source.packageId == publication.package.packageId)
                #expect(target.reviewItemId == contentHandle.itemId)
            } else {
                Issue.record("Expected IPC selection to publish the selected Review target")
            }
        }

        var contentResult: IPCBridgeContentGetResult?
        do {
            contentResult = try await fixture.controller.loadContentForIPC(
                contentHandleId: contentHandle.handleId,
                reviewGeneration: contentHandle.reviewGeneration.rawValue
            )
        } catch {
            Issue.record("Current E1 IPC content read should resolve its committed handle: \(error)")
        }
        #expect(contentResult?.handle.handleId == contentHandle.handleId)
        #expect(contentResult?.byteCount == contentHandle.sizeBytes)

        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("successor installation builds after a held resumed predecessor retires")
    func successorInstallationBuildsAfterHeldResumedPredecessorIsFenced() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        let predecessorCaptureGate = BridgeContributionCaptureGate()
        let successorCaptureGate = BridgeContributionCaptureGate()
        await fixture.provider.setContributionCaptureGate(predecessorCaptureGate)

        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(fixture.artifact(diffId: UUIDv7.generate())),
                commandId: commandId,
                correlationId: nil
            )
        }

        do {
            try await fixture.factTrace.expectPendingCommand(commandId)
            await sendPageActiveViewerMode(
                .review,
                controller: fixture.controller,
                productAdmission: fixture.productAdmission,
                sequence: 2
            )
            await predecessorCaptureGate.waitForStart()
            try await fixture.factTrace.expectResumedBuildStarted(commandId)
            #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 1)
            let predecessorPhysicalTasks = fixture.controller.reviewConstructionProgress.physicalTaskHandles()
            #expect(predecessorPhysicalTasks.count == 1)

            let paneAdmission = try #require(fixture.controller.productAdmissionGate.acquire())
            let successorInstallation = try await fixture.controller.productSessionOwner.prepareCandidate(
                productAdmission: paneAdmission
            )
            #expect(
                await fixture.controller.productSessionOwner.activatePreparedCandidate(
                    successorInstallation,
                    productAdmission: paneAdmission
                ) == .activated
            )

            #expect(
                await commandTask.value
                    == .failure(.invalidPayload(description: "Bridge pane is closed"))
            )
            try await fixture.factTrace.expectCommandEnded(commandId, outcome: .retired)
            #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 0)
            #expect(fixture.controller.paneState.diff.packageMetadata == nil)

            await fixture.provider.setContributionCaptureGate(successorCaptureGate)
            await predecessorCaptureGate.releaseAll()
            for task in predecessorPhysicalTasks { await task.value }
            #expect(fixture.controller.paneState.diff.packageMetadata == nil)

            let successorAdmission = try #require(successorInstallation.productAdapter.acquireAdmission())
            await sendPageActiveViewerMode(
                .review,
                controller: fixture.controller,
                productAdmission: successorAdmission,
                sequence: 1,
                sessionId: "successor-\(successorInstallation.bootstrap.workerInstanceId)"
            )
            let successorAttempt = try await fixture.factTrace.nextAdmittedAttempt()
            await successorCaptureGate.waitForStart()
            #expect(await fixture.provider.recordedContributionRequests().count == 2)
            let successorTask = try #require(fixture.controller.activeReviewRefreshTask)

            await successorCaptureGate.releaseAll()
            await successorTask.value
            try await fixture.factTrace.expectAttemptEnded(successorAttempt, outcome: .succeeded)
            #expect(fixture.controller.paneState.diff.status == .ready)
            #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-pending"])
            #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 0)

            _ = await fixture.controller.beginTeardown().value
            try await fixture.factTrace.finish()
        } catch {
            await predecessorCaptureGate.releaseAll()
            await successorCaptureGate.releaseAll()
            for task in fixture.controller.reviewConstructionProgress.physicalTaskHandles() {
                await task.value
            }
            _ = await fixture.controller.beginTeardown().value
            throw error
        }
    }
}
