import AgentStudioGit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

extension WebKitSerializedTests {
    /// End-to-end Review package load through the production git provider and
    /// direct product metadata source against a real git repository. Mirrors
    /// the shape a workspace pane gets from `openBridgeReviewInNewTab`: `.workspace`
    /// with the `.localDefaultBranch("main")` baseline over a single-commit
    /// repository containing working-tree changes.
    @MainActor
    @Suite(.serialized)
    struct BridgePaneControllerRealGitReviewLoadTests {
        init() {
            installTestCoreAtomsIfNeeded()
        }

        @Test("a real single-commit repo publishes a ready Review product snapshot")
        func realGitSingleCommitRepoPublishesReadyReviewProductSnapshot() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-review-controller-load")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repoURL)
            let harness = try await RealGitReviewLoadHarness.make(repositoryURL: repoURL)
            defer { _ = harness.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let metadataLease = try await harness.openReviewMetadataSubscription()
            let metadataEventsTask = Task { @MainActor in
                try await harness.nextReviewBatchPublication(for: metadataLease)
            }

            // Act
            let result = try await beginInitialReviewInNativeFixture(harness.controller, facts: harness.buildFacts)
            let completedResult = result
            guard case .succeeded = completedResult else {
                metadataEventsTask.cancel()
                try await closeBridgeProductSessionProducer(
                    metadataLease,
                    in: harness.installation.session
                )
                _ = await metadataEventsTask.result
                Issue.record("Real-git Review package load failed: \(String(describing: completedResult))")
                return
            }
            let publication = try await metadataEventsTask.value

            // Assert
            let package = try #require(harness.controller.paneState.diff.packageMetadata)
            #expect(harness.controller.paneState.diff.status == .ready)

            #expect(publication.displayed?.packageId == package.packageId)
            #expect(publication.displayed?.generation == package.reviewGeneration.rawValue)
            #expect(publication.displayed?.revision == package.revision)
            let trackedItem = try #require(
                package.itemsById.values.first { $0.headPath == "tracked.txt" }
            )
            let trackedBaseHandle = try #require(trackedItem.contentRoles.base)
            let trackedHeadHandle = try #require(trackedItem.contentRoles.head)
            let trackedBaseContent = try await harness.reviewSourceProvider.loadContent(
                BridgeContentLoadRequest(
                    handle: trackedBaseHandle,
                    requestedGeneration: package.reviewGeneration
                )
            )
            let trackedHeadContent = try await harness.reviewSourceProvider.loadContent(
                BridgeContentLoadRequest(
                    handle: trackedHeadHandle,
                    requestedGeneration: package.reviewGeneration
                )
            )
            #expect(trackedBaseContent.data == Data("initial\n".utf8))
            #expect(trackedHeadContent.data == Data("initial\nupdated\n".utf8))
            let untrackedItem = try #require(
                package.itemsById.values.first { $0.headPath == "untracked.txt" }
            )
            #expect(untrackedItem.contentRoles.base == nil)
            let untrackedHeadHandle = try #require(untrackedItem.contentRoles.head)
            let untrackedHeadContent = try await harness.reviewSourceProvider.loadContent(
                BridgeContentLoadRequest(
                    handle: untrackedHeadHandle,
                    requestedGeneration: package.reviewGeneration
                )
            )
            #expect(untrackedHeadContent.data == Data("new file\n".utf8))
            #expect(harness.controller.reviewSharedConstructionBinder != nil)
            let constructionSnapshot = await harness.constructionCoordinator.snapshot()
            #expect(constructionSnapshot.entryCount == 1)
            #expect(constructionSnapshot.leaseCount == 1)
            #expect(constructionSnapshot.payloadCount == 1)
            #expect(constructionSnapshot.locatorCount > 0)
            #expect(await harness.controller.beginTeardown().value)
            #expect((await harness.installation.session.producerSnapshot()).hasZeroResidue)
            await assertBridgeConstructionCoordinatorDrained(harness.constructionCoordinator)
            #expect(await harness.reviewDataClient.registeredContentLocatorCount() == 0)
        }

        @Test("a real contribution publishes complete dirty state and excludes target-only movement")
        func realContributionPublishesCompleteDirtyStateAndExcludesTargetOnlyMovement() async throws {
            // Arrange
            let repoURL = try await FilesystemTestGitRepo.create(named: "bridge-review-contribution")
            defer { FilesystemTestGitRepo.destroy(repoURL) }
            let fixture = try await seedCompleteContribution(at: repoURL)
            let harness = try await RealGitReviewLoadHarness.make(repositoryURL: repoURL)
            defer { _ = harness.controller.beginTeardown() }  // fire-and-forget: defer cannot await; cleanup only
            let metadataLease = try await harness.openReviewMetadataSubscription()
            let initialEventsTask = Task { @MainActor in
                try await harness.nextReviewBatchPublication(for: metadataLease)
            }

            // Act
            let initialResult = try #require(
                try await beginInitialReviewInNativeFixture(harness.controller, facts: harness.buildFacts)
            )
            guard case .succeeded = initialResult else {
                Issue.record("Expected the real contribution package to load: \(initialResult)")
                return
            }
            let initialPublication = try await initialEventsTask.value
            let initialPackage = try #require(harness.controller.paneState.diff.packageMetadata)

            // Assert
            guard let initialDisplayed = initialPublication.displayed,
                case .contribution(let initialOrigin) = initialPackage.comparisonOrigin
            else {
                Issue.record("Expected a displayed contribution batch publication and origin")
                return
            }
            #expect(initialDisplayed.comparisonOrigin == initialPackage.comparisonOrigin)
            #expect(initialDisplayed.reviewedSubjectLabel == "real-git-review")
            #expect(initialOrigin.symbolicTarget == .localDefaultBranch(branchName: "main"))
            #expect(initialOrigin.resolvedTargetOID == fixture.initialTargetOID)
            #expect(initialOrigin.reviewedHeadOID == fixture.reviewedHeadOID)
            #expect(initialOrigin.baseOID == fixture.sharedBaseOID)
            let initialPaths = Set(initialPackage.itemsById.values.compactMap(\.headPath))
            #expect(initialPaths.isSuperset(of: fixture.expectedContributionPaths))
            #expect(!initialPaths.contains("target-only.txt"))
            try await assertCompleteContributionContent(
                package: initialPackage,
                provider: harness.reviewSourceProvider
            )

            let successorTargetOID = try await advanceTargetOnlyHistory(at: repoURL)
            let successorEventsTask = Task { @MainActor in
                try await harness.nextReviewBatchPublication(for: metadataLease)
            }
            harness.controller.refreshAdmissionCoordinator.recordInvalidation(
                fileChangeset: nil,
                requiresReviewRefresh: true
            )
            let reservation = try #require(
                harness.controller.refreshAdmissionCoordinator.reserveForegroundRefreshPass(
                    for: .review
                )
            )

            let refreshOutcome = await harness.controller.refreshCurrentReviewPackage(
                reservation: reservation,
                foregroundWorkAdmission: reservation.foregroundWorkAdmission,
                productAdmission: harness.paneProductAdmission
            )
            harness.controller.refreshAdmissionCoordinator.completeRefreshPass(
                reservation,
                outcome: refreshOutcome
            )
            let successorPublication = try await successorEventsTask.value
            let successorPackage = try #require(harness.controller.paneState.diff.packageMetadata)

            #expect(refreshOutcome == .succeeded)
            guard let successorDisplayed = successorPublication.displayed,
                case .contribution(let successorOrigin) = successorPackage.comparisonOrigin
            else {
                Issue.record("Expected target movement to publish a successor contribution batch")
                return
            }
            #expect(successorPackage.reviewGeneration == initialPackage.reviewGeneration)
            #expect(successorPackage.revision > initialPackage.revision)
            #expect(successorPackage != initialPackage)
            #expect(successorOrigin.resolvedTargetOID == successorTargetOID)
            #expect(successorOrigin.reviewedHeadOID == initialOrigin.reviewedHeadOID)
            #expect(successorOrigin.baseOID == initialOrigin.baseOID)
            #expect(successorPackage.itemsById.keys == initialPackage.itemsById.keys)
            #expect(!successorPackage.itemsById.values.compactMap(\.headPath).contains("target-only.txt"))
            #expect(successorDisplayed.comparisonOrigin == successorPackage.comparisonOrigin)
            #expect(successorPublication.publicationId != initialPublication.publicationId)
            #expect(initialPackage.comparisonOrigin == .contribution(initialOrigin))
            #expect(initialPackage.itemsById.values.compactMap(\.headPath).contains("target-only.txt") == false)

            #expect(await harness.controller.beginTeardown().value)
            #expect((await harness.installation.session.producerSnapshot()).hasZeroResidue)
            await assertBridgeConstructionCoordinatorDrained(harness.constructionCoordinator)
            #expect(await harness.reviewDataClient.registeredContentLocatorCount() == 0)
        }
    }
}

private struct CompleteContributionFixture {
    let expectedContributionPaths: Set<String>
    let initialTargetOID: String
    let reviewedHeadOID: String
    let sharedBaseOID: String
}

private func seedCompleteContribution(at repositoryURL: URL) async throws -> CompleteContributionFixture {
    try "initial\n".write(
        to: repositoryURL.appending(path: "tracked.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["add", "tracked.txt"])
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["commit", "-m", "shared base"])
    let sharedBaseOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["rev-parse", "HEAD"])
    )

    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["switch", "-c", "feature/review"])
    try "committed\n".write(
        to: repositoryURL.appending(path: "committed.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["add", "committed.txt"])
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["commit", "-m", "reviewed commit"])
    let reviewedHeadOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["rev-parse", "HEAD"])
    )

    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["switch", "main"])
    try "target only\n".write(
        to: repositoryURL.appending(path: "target-only.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["add", "target-only.txt"])
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["commit", "-m", "target-only commit"])
    let initialTargetOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["rev-parse", "HEAD"])
    )

    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["switch", "feature/review"])
    try "staged\n".write(
        to: repositoryURL.appending(path: "staged.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["add", "staged.txt"])
    try "initial\nunstaged\n".write(
        to: repositoryURL.appending(path: "tracked.txt"),
        atomically: true,
        encoding: .utf8
    )
    try "untracked\n".write(
        to: repositoryURL.appending(path: "untracked.txt"),
        atomically: true,
        encoding: .utf8
    )
    return CompleteContributionFixture(
        expectedContributionPaths: ["committed.txt", "staged.txt", "tracked.txt", "untracked.txt"],
        initialTargetOID: initialTargetOID,
        reviewedHeadOID: reviewedHeadOID,
        sharedBaseOID: sharedBaseOID
    )
}

private func advanceTargetOnlyHistory(at repositoryURL: URL) async throws -> String {
    let targetTreeOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["rev-parse", "main^{tree}"])
    )
    let targetParentOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(at: repositoryURL, args: ["rev-parse", "main"])
    )
    let successorTargetOID = try normalizedGitOID(
        await FilesystemTestGitRepo.runGit(
            at: repositoryURL,
            args: ["commit-tree", targetTreeOID, "-p", targetParentOID, "-m", "advance target only"]
        )
    )
    try await FilesystemTestGitRepo.runGit(
        at: repositoryURL,
        args: ["update-ref", "refs/heads/main", successorTargetOID, targetParentOID]
    )
    return successorTargetOID
}

private func normalizedGitOID(_ output: String) throws -> String {
    let oid = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(oid.isEmpty ? nil : oid)
}

private func assertCompleteContributionContent(
    package: BridgeReviewPackage,
    provider: BridgeGitReviewSourceProvider
) async throws {
    let expectedContentByPath: [String: String] = [
        "committed.txt": "committed\n",
        "staged.txt": "staged\n",
        "tracked.txt": "initial\nunstaged\n",
        "untracked.txt": "untracked\n",
    ]
    for (path, expectedContent) in expectedContentByPath {
        let item = try #require(package.itemsById.values.first { $0.headPath == path })
        let headHandle = try #require(item.contentRoles.head)
        let loadedContent = try await provider.loadContent(
            BridgeContentLoadRequest(
                handle: headHandle,
                requestedGeneration: package.reviewGeneration
            )
        )
        #expect(loadedContent.data == Data(expectedContent.utf8))
    }
}

@MainActor
private struct RealGitReviewLoadHarness {
    let buildFacts: BridgePaneReviewBuildAdmissionTrace
    let capabilityHeader: String
    let controlDispatcher: BridgeProductSchemeControlDispatcher
    let controller: BridgePaneController
    let constructionCoordinator: BridgeWorktreeProductConstructionCoordinator
    let installation: BridgeProductSessionInstallation
    let paneProductAdmission: BridgeProductAdmissionContext
    let productAdmission: BridgeProductAdmissionContext
    let productProvider: BridgePaneProductSchemeProvider
    let reviewDataClient: AgentStudioGitBridgeReviewDataClient<LibGit2AgentStudioGitLocalClient>
    let reviewSourceProvider: BridgeGitReviewSourceProvider

    static func make(repositoryURL: URL) async throws -> Self {
        let paneId = UUIDv7.generate()
        let gitReadContext = makeBridgeGitReadContext(rootURL: repositoryURL)
        let constructionCoordinator = BridgeWorktreeProductConstructionCoordinator()
        let reviewDataClient = AgentStudioGitBridgeReviewDataClient(
            repositoryPath: repositoryURL,
            client: LibGit2AgentStudioGitLocalClient(),
            gitReadContext: gitReadContext,
            statusPhysicalGate: AgentStudioGitStatusPhysicalGate()
        )
        let reviewSourceProvider = BridgeGitReviewSourceProvider(client: reviewDataClient)
        let buildFacts = try BridgePaneReviewBuildAdmissionTrace()
        let controller = BridgePaneController(
            paneId: paneId,
            state: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: repositoryURL.path,
                    baseline: .localDefaultBranch(branchName: "main")
                )
            ),
            appRootURL: testBridgeAppRootURL(),
            metadata: PaneMetadata(
                contentType: .diff,
                launchDirectory: repositoryURL,
                title: "Bridge Review",
                facets: PaneContextFacets(
                    repoId: UUIDv7.generate(),
                    worktreeId: UUIDv7.generate(),
                    worktreeName: "real-git-review",
                    cwd: repositoryURL
                )
            ),
            reviewSourceProvider: reviewSourceProvider,
            gitReadContext: gitReadContext,
            worktreeProductConstructionCoordinator: constructionCoordinator,
            initialPaneActivity: .foreground,
            reviewBuildAdmissionFactSink: buildFacts.source.sink
        )
        let productProvider = try #require(controller.productSchemeProvider)
        let installation = try #require(
            await controller.productSessionOwner.activeInstallation
        )
        let paneProductAdmission = try #require(controller.productAdmissionGate.acquire())
        let productAdmission = try #require(installation.productAdapter.acquireAdmission())
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let controlDispatcher = BridgeProductSchemeControlDispatcher(
            session: installation.session,
            provider: productProvider,
            productAdmission: productAdmission
        )
        #expect(controller.handleBridgeReady())
        return Self(
            buildFacts: buildFacts,
            capabilityHeader: capabilityHeader,
            controlDispatcher: controlDispatcher,
            controller: controller,
            constructionCoordinator: constructionCoordinator,
            installation: installation,
            paneProductAdmission: paneProductAdmission,
            productAdmission: productAdmission,
            productProvider: productProvider,
            reviewDataClient: reviewDataClient,
            reviewSourceProvider: reviewSourceProvider
        )
    }

    func openReviewMetadataSubscription() async throws -> BridgeProductProducerLease {
        let workerOpenRequest = try realGitReviewWorkerOpenRequest(installation: installation)
        let workerOpenResponse = try await readAdmittedBridgeProductControlResponse(
            try await controlDispatcher.dispatch(
                exactRequestBytes: try realGitReviewControlRequestBytes(workerOpenRequest),
                presentedCapability: capabilityHeader
            ),
            installation: installation,
            capabilityHeader: capabilityHeader
        )
        guard case .workerSessionAccepted = workerOpenResponse else {
            throw RealGitReviewMetadataEventError.expectedWorkerSessionAccepted
        }
        let metadataRequest = try realGitReviewMetadataRequest(installation: installation)
        let registration = await installation.session.registerMetadataProducer(
            request: metadataRequest,
            productAdmission: productAdmission
        ) { lease in
            await productProvider.runMetadataProducer(
                request: metadataRequest,
                lease: lease,
                productAdmission: productAdmission,
                session: installation.session
            )
        }
        let metadataLease = try bridgeProductAcceptedLease(registration)
        let metadataOpeningFrame = try realGitReviewMetadataFrame(
            from: try #require(
                await consumeNextBridgeProductProducerFrame(
                    for: metadataLease,
                    from: installation.session,
                    productAdmission: productAdmission
                )
            )
        )
        guard case .metadataStreamAccepted = metadataOpeningFrame else {
            throw RealGitReviewMetadataEventError.expectedMetadataStreamAccepted
        }
        let reviewOpenRequest = try realGitReviewSubscriptionOpenRequest(
            installation: installation
        )
        var metadataStreamIsReady = false
        for _ in 0..<1000 {
            if case .subscriptionOpenAccepted = await productProvider.response(for: reviewOpenRequest) {
                metadataStreamIsReady = true
                break
            }
            await Task.yield()
        }
        #expect(metadataStreamIsReady)
        let reviewOpenResponse = try await readAdmittedBridgeProductControlResponse(
            try await controlDispatcher.dispatch(
                exactRequestBytes: try realGitReviewControlRequestBytes(reviewOpenRequest),
                presentedCapability: capabilityHeader
            ),
            installation: installation,
            capabilityHeader: capabilityHeader
        )
        guard case .subscriptionOpenAccepted = reviewOpenResponse else {
            throw RealGitReviewMetadataEventError.expectedReviewSubscriptionControlAccepted
        }
        var observedSubscriptionAcceptance = false
        for _ in 0..<2 {
            let frame = try realGitReviewMetadataFrame(
                from: try #require(
                    await consumeNextBridgeProductProducerFrame(
                        for: metadataLease,
                        from: installation.session,
                        productAdmission: productAdmission
                    )
                )
            )
            switch frame {
            case .panePresentation(let presentation):
                #expect(presentation.nativeActivity == .foreground)
            case .subscriptionAccepted:
                observedSubscriptionAcceptance = true
            default:
                throw RealGitReviewMetadataEventError.unexpectedReviewSubscriptionFrame(
                    String(describing: frame)
                )
            }
            if observedSubscriptionAcceptance { break }
        }
        guard observedSubscriptionAcceptance else {
            throw RealGitReviewMetadataEventError.expectedReviewSubscriptionFrameAccepted
        }
        try await admitReviewViewScope()
        return metadataLease
    }

    private func admitReviewViewScope() async throws {
        let scopeRequest = try realGitReviewControlRequest([
            "kind": "subscription.setScope",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
            "wireVersion": BridgeProductWireContract.version,
            "requestId": "request-review-scope-real-git-review",
            "requestSequence": 3,
            "subscriptionId": "review-subscription-real-git-review",
            "subscriptionKind": "review.metadata",
            "domain": "default",
            "handle": "real-git-review-handle",
            "incarnation": "real-git-review-incarnation",
            "scopeRevision": 1,
            "scope": ["kind": "review", "interests": []],
        ])
        let scopeResponse = try await readAdmittedBridgeProductControlResponse(
            try await controlDispatcher.dispatch(
                exactRequestBytes: try realGitReviewControlRequestBytes(scopeRequest),
                presentedCapability: capabilityHeader
            ),
            installation: installation,
            capabilityHeader: capabilityHeader
        )
        guard case .viewAccepted = scopeResponse else {
            throw RealGitReviewMetadataEventError.expectedReviewBatchPublication
        }
    }

    func nextReviewBatchPublication(
        for metadataLease: BridgeProductProducerLease
    ) async throws -> BridgeProductReviewBatchPublicationRecord {
        var publication: BridgeProductReviewBatchPublicationRecord?
        while true {
            let frame = try realGitReviewMetadataFrame(
                from: try #require(
                    await consumeNextBridgeProductProducerFrame(
                        for: metadataLease,
                        from: installation.session,
                        productAdmission: productAdmission
                    )
                )
            )
            switch frame {
            case .batch(.begin(let begin)):
                guard begin.mode == .snapshot else {
                    throw RealGitReviewMetadataEventError.expectedReviewBatchPublication
                }
            case .batch(.part(let part)):
                guard case .put(_, _, let value) = part.part else { continue }
                let record = try JSONDecoder().decode(
                    BridgeProductReviewBatchRecord.self,
                    from: JSONEncoder().encode(value)
                )
                if case .publication(let receivedPublication) = record {
                    publication = receivedPublication
                }
            case .batch(.complete):
                guard let publication else {
                    throw RealGitReviewMetadataEventError.expectedReviewBatchPublication
                }
                return publication
            case .panePresentation:
                continue
            default:
                throw RealGitReviewMetadataEventError.expectedReviewBatchPublication
            }
        }
    }
}

private enum RealGitReviewMetadataEventError: Error {
    case expectedMetadataStreamAccepted
    case expectedReviewSubscriptionControlAccepted
    case expectedReviewSubscriptionFrameAccepted
    case unexpectedReviewSubscriptionFrame(String)
    case expectedReviewBatchPublication
    case expectedSingleMetadataFrame
    case expectedWorkerSessionAccepted
}

private func realGitReviewWorkerOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try realGitReviewControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-real-git-review",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func realGitReviewSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try realGitReviewControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-review-open-real-git-review",
        "requestSequence": 2,
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": "review-subscription-real-git-review",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func realGitReviewMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "metadata-real-git-review",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    )
}

private func realGitReviewControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func realGitReviewControlRequestBytes(
    _ request: BridgeProductControlRequest
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request)
}

private func realGitReviewMetadataFrame(
    from queuedFrame: BridgeProductQueuedProducerFrame
) throws -> BridgeProductMetadataFrame {
    let decoder = try BridgeProductMetadataFrameDecoder()
    let frames = try decoder.append(queuedFrame.data)
    guard frames.count == 1, let frame = frames.first else {
        throw RealGitReviewMetadataEventError.expectedSingleMetadataFrame
    }
    return frame
}
