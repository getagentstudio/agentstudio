import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests.BridgePaneControllerTests {

    @Test("an explicit Review target waits for the first accepted mode and owns initial intake")
    func explicitReviewTargetWaitsForFirstAcceptedModeAndOwnsInitialIntake() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        #expect(fixture.controller.activeViewerModeSignalState.acceptedMode == nil)
        let target = WorkspaceReviewContributionTarget.branch(name: "target-before-first-mode")
        #expect(await fixture.updateTarget(target, workerDerivationEpoch: 1) == .applied)
        let artifact = fixture.artifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate()
        )
        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: nil
            )
        }

        try await fixture.factTrace.expectPendingCommand(commandId)
        #expect(await fixture.provider.recordedContributionRequests().isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)
        #expect(fixture.controller.paneState.diff.packageMetadata == nil)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let result = await commandTask.value
        assertDiffCommandWasAccepted(result, commandId: commandId)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        let contributionRequests = await fixture.provider.recordedContributionRequests()
        #expect(contributionRequests.count == 1)
        #expect(contributionRequests.map(\.headEndpoint.worktreeId) == [artifact.worktreeId])
        #expect(
            contributionRequests.map(\.symbolicTarget) == [target]
        )
        #expect(fixture.controller.paneState.diff.packageMetadata?.orderedItemIds == ["item-pending"])
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .completed)

        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("the latest explicit Review target replaces an earlier target before mode acceptance")
    func latestExplicitReviewTargetReplacesEarlierTargetBeforeModeAcceptance() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let firstTarget = WorkspaceReviewContributionTarget.branch(name: "target-superseded")
        #expect(await fixture.updateTarget(firstTarget, workerDerivationEpoch: 1) == .applied)
        let firstArtifact = fixture.artifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate()
        )
        let firstCommandId = UUIDv7.generate()
        let firstCommandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(firstArtifact),
                commandId: firstCommandId,
                correlationId: nil
            )
        }
        try await fixture.factTrace.expectPendingCommand(firstCommandId)

        let latestTarget = WorkspaceReviewContributionTarget.branch(name: "target-latest")
        #expect(await fixture.updateTarget(latestTarget, workerDerivationEpoch: 2) == .applied)
        let latestArtifact = fixture.artifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate()
        )
        let latestCommandId = UUIDv7.generate()
        let latestCommandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(latestArtifact),
                commandId: latestCommandId,
                correlationId: nil
            )
        }
        try await fixture.factTrace.expectPendingCommand(latestCommandId)

        #expect(
            await firstCommandTask.value
                == .failure(.invalidPayload(description: "Stale bridge review load"))
        )
        #expect(await fixture.provider.recordedContributionRequests().isEmpty)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        assertDiffCommandWasAccepted(
            await latestCommandTask.value,
            commandId: latestCommandId
        )
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        let contributionRequests = await fixture.provider.recordedContributionRequests()
        #expect(contributionRequests.count == 1)
        #expect(contributionRequests.map(\.headEndpoint.worktreeId) == [latestArtifact.worktreeId])
        #expect(
            contributionRequests.map(\.symbolicTarget) == [latestTarget]
        )
        try await fixture.factTrace.expectCommandEnded(firstCommandId, outcome: .superseded)
        try await fixture.factTrace.expectCommandEnded(latestCommandId, outcome: .completed)

        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("an explicit Review target stays pending while File is accepted, then builds on Review show")
    func explicitReviewTargetWaitsWhileFileIsAcceptedThenBuildsOnReviewShow() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let target = WorkspaceReviewContributionTarget.branch(name: "target-on-show")
        #expect(await fixture.updateTarget(target, workerDerivationEpoch: 1) == .applied)
        let artifact = fixture.artifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate()
        )
        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: nil
            )
        }

        try await fixture.factTrace.expectPendingCommand(commandId)
        #expect(await fixture.provider.recordedContributionRequests().isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 2
        )
        assertDiffCommandWasAccepted(await commandTask.value, commandId: commandId)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        let contributionRequests = await fixture.provider.recordedContributionRequests()
        #expect(contributionRequests.count == 1)
        #expect(contributionRequests.map(\.headEndpoint.worktreeId) == [artifact.worktreeId])
        #expect(
            contributionRequests.map(\.symbolicTarget) == [target]
        )
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .completed)

        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("hiding before a resumed explicit Review load starts preserves its original command waiter")
    func hidingBeforeResumedExplicitLoadStartsKeepsOriginalCommandPending() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let defaultTargetGate = BridgeContributionCaptureGate()
        await fixture.provider.setDefaultTargetGate(defaultTargetGate)
        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let target = WorkspaceReviewContributionTarget.branch(name: "target-survives-rehide")
        #expect(await fixture.updateTarget(target, workerDerivationEpoch: 1) == .applied)
        let artifact = fixture.artifact(diffId: UUIDv7.generate())
        let commandId = UUIDv7.generate()
        let correlationId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: correlationId
            )
        }
        try await fixture.factTrace.expectPendingCommand(commandId)
        let originalPendingCommand = try #require(fixture.controller.pendingExplicitReviewCommand)
        #expect(originalPendingCommand.correlationId == correlationId)

        // Hold the resumed preflight after it starts, before any package construction begins.
        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 2
        )
        await defaultTargetGate.waitForStart()
        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 3
        )
        await defaultTargetGate.releaseAll()

        try await fixture.factTrace.expectPendingCommandDeferral(commandId)
        #expect(fixture.controller.pendingExplicitReviewCommand === originalPendingCommand)
        #expect(await fixture.provider.recordedContributionRequests().isEmpty)
        #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 0)

        await sendPageActiveViewerMode(
            .review,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 4
        )
        assertDiffCommandWasAccepted(await commandTask.value, commandId: commandId)
        #expect(fixture.controller.pendingReviewPackageBuildReasons.isEmpty)
        #expect(fixture.controller.activeReviewRefreshTask == nil)

        let requests = await fixture.provider.recordedContributionRequests()
        #expect(requests.count == 1)
        #expect(requests.map(\.headEndpoint.worktreeId) == [artifact.worktreeId])
        #expect(requests.map(\.symbolicTarget) == [target])
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .completed)
        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    @Test("closing the resumed command's E1 installation cancels construction and fences its late result")
    func closingInstallationCancelsResumedExplicitLoadAndFencesLateResult() async throws {
        try await assertResumedExplicitCommandRetiresWhileCaptureIsHeld(.closeInstallation)
    }

    @Test("reloading the page cancels resumed construction and fences its late result")
    func reloadingPageCancelsResumedExplicitLoadAndFencesLateResult() async throws {
        try await assertResumedExplicitCommandRetiresWhileCaptureIsHeld(.reloadPage)
    }

    @Test("pane teardown cancels and drains the resumed command task after capture release")
    func paneTeardownCancelsAndDrainsResumedExplicitCommandTask() async throws {
        try await assertResumedExplicitCommandRetiresWhileCaptureIsHeld(.paneTeardown)
    }

    @Test("retiring the page installation ends a pending explicit Review command without a build")
    func retiringPageInstallationEndsPendingExplicitReviewCommandWithoutBuild() async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        defer { _ = fixture.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only

        let artifact = fixture.artifact(
            diffId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate()
        )
        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: nil
            )
        }
        try await fixture.factTrace.expectPendingCommand(commandId)
        #expect(await fixture.provider.recordedContributionRequests().isEmpty)

        let currentInstallation = try #require(
            fixture.controller.productSessionOwner.installationFenceProjection.snapshot.installation
        )
        currentInstallation.close()
        #expect(
            await commandTask.value
                == .failure(.invalidPayload(description: "Bridge pane is closed"))
        )

        #expect(await fixture.provider.recordedContributionRequests().isEmpty)
        try await fixture.factTrace.expectCommandEnded(commandId, outcome: .retired)
        _ = await fixture.controller.beginTeardown().value
        try await fixture.factTrace.finish()
    }

    private func assertResumedExplicitCommandRetiresWhileCaptureIsHeld(
        _ retirement: ResumedExplicitCommandRetirement
    ) async throws {
        let fixture = try await makeDiffCommandPageModeFixture()
        let captureGate = BridgeContributionCaptureGate()
        await fixture.provider.setContributionCaptureGate(captureGate)
        let target = WorkspaceReviewContributionTarget.branch(name: "target-retired-in-capture")
        #expect(await fixture.updateTarget(target, workerDerivationEpoch: 1) == .applied)

        await sendPageActiveViewerMode(
            .file,
            controller: fixture.controller,
            productAdmission: fixture.productAdmission,
            sequence: 1
        )
        let artifact = fixture.artifact(diffId: UUIDv7.generate())
        let commandId = UUIDv7.generate()
        let commandTask = Task { @MainActor in
            await fixture.controller.handleDiffCommand(
                .loadDiff(artifact),
                commandId: commandId,
                correlationId: nil
            )
        }
        var teardownTask: Task<Bool, Never>?
        do {
            try await fixture.factTrace.expectPendingCommand(commandId)
            await sendPageActiveViewerMode(
                .review,
                controller: fixture.controller,
                productAdmission: fixture.productAdmission,
                sequence: 2
            )
            await captureGate.waitForStart()
            #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 1)
            #expect(await fixture.provider.recordedContributionRequests().count == 1)

            switch retirement {
            case .closeInstallation:
                let installation = try #require(
                    fixture.controller.productSessionOwner.installationFenceProjection.snapshot.installation
                )
                installation.close()
            case .reloadPage:
                #expect(fixture.controller.reloadWebView())
            case .paneTeardown:
                teardownTask = fixture.controller.beginTeardown()
                #expect(fixture.controller.resumingExplicitReviewCommandTasksById[commandId] != nil)
            }

            #expect(
                await commandTask.value
                    == .failure(.invalidPayload(description: "Bridge pane is closed"))
            )
            try await fixture.factTrace.expectCommandEnded(commandId, outcome: .retired)
            #expect(fixture.controller.reviewConstructionProgress.activeWaitCount() == 0)

            let physicalTasks = fixture.controller.reviewConstructionProgress.physicalTaskHandles()
            #expect(physicalTasks.count == 1)
            #expect(fixture.controller.paneState.diff.packageMetadata == nil)
            let statusAtLogicalRetirement = fixture.controller.paneState.diff.status

            // This provider deliberately ignores task cancellation until released.
            await captureGate.releaseAll()
            for task in physicalTasks { await task.value }
            #expect(fixture.controller.paneState.diff.status == statusAtLogicalRetirement)
            #expect(fixture.controller.paneState.diff.packageMetadata == nil)
            #expect(fixture.controller.reviewConstructionProgress.physicalTaskHandles().isEmpty)

            if let teardownTask {
                #expect(await teardownTask.value)
            } else {
                _ = await fixture.controller.beginTeardown().value
            }
            #expect(fixture.controller.resumingExplicitReviewCommandTasksById[commandId] == nil)
            try await fixture.factTrace.finish()
        } catch {
            await captureGate.releaseAll()
            for task in fixture.controller.reviewConstructionProgress.physicalTaskHandles() {
                await task.value
            }
            _ = await fixture.controller.beginTeardown().value
            throw error
        }
    }
}

private enum ResumedExplicitCommandRetirement {
    case closeInstallation
    case reloadPage
    case paneTeardown
}

@MainActor
private struct DiffCommandPageModeFixture {
    let controller: BridgePaneController
    let provider: BridgeReviewSourceProviderFake
    let productAdmission: BridgeProductAdmissionContext
    let metadataProducerLease: BridgeProductProducerLease
    let worktreeId: UUID
    let factTrace: DiffCommandPageModeAdmissionTrace

    func artifact(diffId: UUID, worktreeId: UUID? = nil) -> DiffArtifact {
        DiffArtifact(diffId: diffId, worktreeId: worktreeId ?? self.worktreeId, patchData: Data())
    }

    func updateTarget(
        _ target: WorkspaceReviewContributionTarget,
        workerDerivationEpoch: Int
    ) async -> BridgePaneReviewComparisonEffectDisposition {
        guard
            productAdmission.withValidAdmission({
                controller.refreshAdmissionCoordinator.workAdmissionSource.admitReviewComparisonIntent(
                    workerDerivationEpoch: workerDerivationEpoch,
                    productAdmission: productAdmission
                )
            }) != nil
        else { return .rejected }
        return await controller.handleCommittedProductReviewComparisonUpdate(
            BridgeProductReviewComparisonUpdateRequest(target: target),
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }
}

private struct DiffCommandPageModeAdmissionTrace {
    let source: LocalFactSource<BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact>
    let recorder: FactRecorder<BridgePaneReviewBuildAdmissionScope, BridgePaneReviewBuildAdmissionFact>

    init() throws {
        let vocabulary = FactVocabulary<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: isDiffCommandPageModeFactClosing
        )
        let source = LocalFactSource<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(vocabulary: vocabulary)
        self.source = source
        recorder = try source.attach()
    }

    func expectPendingCommand(_ commandId: UUID) async throws {
        let expectedScope = BridgePaneReviewBuildAdmissionScope.pendingExplicitCommand(commandId)
        let scope = try await recorder.expectNextOperation(
            matching: { $0 == expectedScope },
            opening: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "Explicit Review command waits for page mode"
        )
        #expect(scope == expectedScope)
        _ = try await recorder.expectNext(
            in: expectedScope,
            where: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "Explicit Review command is pending on page mode"
        )
    }

    func expectPendingCommandDeferral(_ commandId: UUID) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: {
                $0 == .pendingExplicitCommandAwaitingPageMode(commandId: commandId)
            },
            "The original explicit Review command returns to pending page-mode ownership"
        )
    }

    func expectCommandEnded(
        _ commandId: UUID,
        outcome: BridgePanePendingExplicitReviewCommandOutcome
    ) async throws {
        _ = try await recorder.expectNext(
            in: .pendingExplicitCommand(commandId),
            where: {
                $0 == .pendingExplicitCommandEnded(commandId: commandId, outcome: outcome)
            },
            "Explicit Review command ends with \(outcome)"
        )
    }

    func finish() async throws {
        source.end()
        try await recorder.finish()
    }
}

private func isDiffCommandPageModeFactClosing(
    scope: BridgePaneReviewBuildAdmissionScope,
    fact: BridgePaneReviewBuildAdmissionFact
) -> Bool {
    switch (scope, fact) {
    case (.pendingExplicitCommand(let commandId), .pendingExplicitCommandEnded(let endedCommandId, _)):
        commandId == endedCommandId
    default:
        false
    }
}

@MainActor
private func makeDiffCommandPageModeFixture() async throws -> DiffCommandPageModeFixture {
    let baseEndpoint = makeBridgeEndpoint(endpointId: "baseline-headMinusOne", kind: .gitRef)
    let headEndpoint = makeBridgeEndpoint(endpointId: "working-tree", kind: .workingTree)
    let changedFile = makeBridgeEndpointChangedFile(
        fileId: "pending",
        path: "Sources/App/Pending.swift",
        sizeBytes: 100
    )
    let provider = BridgeReviewSourceProviderFake(
        comparison: BridgeEndpointComparison(
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            changedFiles: [changedFile]
        ),
        contentByHandleId: [:],
        contributionCapture: BridgeContributionComparisonCapture(
            resolvedTargetOID: "resolved-target",
            reviewedHeadOID: "reviewed-head",
            baseRole: .commonCommit,
            baseOID: "contribution-base",
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: headEndpoint,
                changedFiles: [changedFile]
            )
        )
    )
    let factTrace = try DiffCommandPageModeAdmissionTrace()
    let controller = BridgePaneController(
        paneId: UUIDv7.generate(),
        state: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(
                rootPath: "/tmp/bridge-diff-command-page-mode",
                baseline: WorkspaceBaseline(contributionTarget: .branch(name: "main"))
            )
        ),
        appRootURL: testBridgeAppRootURL(),
        metadata: PaneMetadata(
            contentType: .diff,
            title: "Pending Review command",
            facets: PaneContextFacets(
                repoId: headEndpoint.repoId,
                worktreeId: headEndpoint.worktreeId,
                cwd: URL(fileURLWithPath: "/tmp/bridge-diff-command-page-mode")
            )
        ),
        reviewSourceProvider: provider,
        initialPaneActivity: .foreground,
        contributionTargetCommit: { target in
            .applied(
                BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: "/tmp/bridge-diff-command-page-mode",
                        baseline: WorkspaceBaseline(contributionTarget: target)
                    )
                )
            )
        },
        reviewBuildAdmissionFactSink: factTrace.source.sink
    )
    let installation = try #require(await controller.productSessionOwner.activeInstallation)
    let productAdmission = try #require(installation.productAdapter.acquireAdmission())
    let productProvider = try #require(controller.productSchemeProvider)
    let metadataProducerLease = try await installRefreshAdmissionMetadataProducer(
        installation: installation,
        productProvider: productProvider,
        productAdmission: productAdmission
    )

    return DiffCommandPageModeFixture(
        controller: controller,
        provider: provider,
        productAdmission: productAdmission,
        metadataProducerLease: metadataProducerLease,
        worktreeId: headEndpoint.worktreeId,
        factTrace: factTrace
    )
}

private func assertDiffCommandWasAccepted(_ result: ActionResult, commandId: UUID) {
    guard case .success(let acceptedCommandId) = result else {
        Issue.record("Expected the explicit Review load to be accepted")
        return
    }
    #expect(acceptedCommandId == commandId)
}
