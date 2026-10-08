import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File shared construction")
struct BridgePaneProductFileSharedConstructionTests {
    @Test("missing-root construction failure survives a source paused after preparation")
    func missingRootFailureSurvivesPreparedSourcePause() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let eventProbe = BridgeWorktreeProductConstructionEventProbe()
        let coordinator = BridgeWorktreeProductConstructionCoordinator(eventSink: eventProbe.eventSink)
        let beforeRootProbe = HeldStep<Void>(
            "File construction before missing-root probe", cancellation: .holdThroughCancellation)
        let preparedSource = HeldStep<Void>(
            "File source prepared before first window read", cancellation: .holdThroughCancellation)
        defer {
            beforeRootProbe.release()
            preparedSource.release()
        }
        let source = fixture.makeSource(
            constructionCoordinator: coordinator,
            sharedSnapshotBuilder: { request, preparation, publisher in
                try await publisher.publishPreparation(preparation)
                try await beforeRootProbe.arrive(())
                for try await _ in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
                    request: request, afterCount: 0, windowSize: 1)
                {}
                return BridgeSharedFileSnapshotCompletion()
            })
        let subscription = try fixture.openSnapshot()
        let displacedRootURL = fixture.rootURL.deletingLastPathComponent()
            .appending(path: "\(fixture.rootURL.lastPathComponent)-temporarily-unavailable")
        try FileManager.default.moveItem(at: fixture.rootURL, to: displacedRootURL)
        defer { try? FileManager.default.moveItem(at: displacedRootURL, to: fixture.rootURL) }
        let pausePreparedSource: BridgePaneProductFileSourceFactSink = { fact in
            if case .statusChanged = fact { try await preparedSource.arrive(()) }
        }
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context,
                emit: pausePreparedSource)
        }
        _ = try await beforeRootProbe.firstArrival()
        _ = try await preparedSource.firstArrival()
        beforeRootProbe.release()
        _ = await eventProbe.waitFor(.buildFailed)
        preparedSource.release()
        switch await opening.result {
        case .success:
            Issue.record("Expected the real missing-root construction failure")
        case .failure(let error):
            let failure = BridgeFileSurfaceReconciler.failure(for: error, phase: .build)
            #expect(failure.cause == .missingRoot, "Observed source-open error: \(String(reflecting: error))")
            #expect(failure.refreshFailure.failureKind == .missingRoot)
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("preparation accounting includes retained ignore and status payloads")
    func preparationAccountingIsNonzeroAndDeterministic() {
        // Arrange
        let ignorePolicy = BridgeWorktreeFileIgnorePolicy(
            filesystemPathFilter: .empty,
            publishableFilePaths: ["Sources/App.swift"],
            trackedPathsAndAncestors: ["Sources", "Sources/App.swift"]
        )
        let status = GitWorkingTreeStatus(
            summary: .init(changed: 1, staged: 0, untracked: 0),
            branch: "feature/shared-file",
            originResolution: .resolved("origin/main"),
            entries: [
                GitWorkingTreeStatusEntry(
                    path: "Sources/App.swift",
                    hasStagedChange: false,
                    hasUnstagedChange: true,
                    isUntracked: false
                )
            ]
        )

        // Act
        let firstEstimate = BridgeWorktreeFileMaterializer.estimatedPreparationRetainedByteCount(
            ignorePolicy: ignorePolicy,
            statusResult: .available(status)
        )
        let secondEstimate = BridgeWorktreeFileMaterializer.estimatedPreparationRetainedByteCount(
            ignorePolicy: ignorePolicy,
            statusResult: .available(status)
        )

        // Assert
        #expect(firstEstimate > "Sources/App.swift".utf8.count)
        #expect(firstEstimate == secondEstimate)
    }

    @Test("empty worktree emits inventory progress and its completing notification")
    func emptyWorktreeEmitsOneFinalWindow() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 0)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let preparationProbe = SharedFilePreparationProbe()
        let source = fixture.makeSource(
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load
        )
        let collector = ProductFileSourceFactCollector()
        let subscription = try fixture.openSnapshot()

        // Act
        try await source.open(
            subscription: subscription,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await collector.append(event, source: source)
        }

        // Assert
        let windows = (await collector.events).fileTreeWindows
        #expect(windows.count == 2)
        #expect(windows[0].finalWindow)
        #expect(windows[0].rows.isEmpty)
        #expect(windows[0].inventoryRowCount == 0)
        #expect(windows[1].finalWindow)
        #expect(windows[1].rows.isEmpty)
        #expect(windows[1].inventory?.isEnumerationComplete == true)
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await assertSharedFileConstructionDrained(coordinator)
    }

    @Test("two panes share one real snapshot build and keep pane-local identities")
    func identicalPanesShareOneRealBuild() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 260)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let preparationProbe = SharedFilePreparationProbe()
        let firstSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load
        )
        let secondSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load
        )
        let firstCollector = ProductFileSourceFactCollector()
        let secondCollector = ProductFileSourceFactCollector()
        let subscription = try fixture.openSnapshot()

        // Act
        async let firstOpen: Void = firstSource.open(
            subscription: subscription,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await firstCollector.append(event, source: firstSource)
        }
        async let secondOpen: Void = secondSource.open(
            subscription: subscription,
            productAdmission: fixture.productAdmission.context
        ) { event in
            await secondCollector.append(event, source: secondSource)
        }
        _ = try await (firstOpen, secondOpen)

        // Assert
        let firstEvents = await firstCollector.events
        let secondEvents = await secondCollector.events
        let firstSourceIdentity = try #require(firstEvents.firstFileSourceIdentity)
        let secondSourceIdentity = try #require(secondEvents.firstFileSourceIdentity)
        #expect(await preparationProbe.invocationCount == 1)
        let constructionScopeTokens = await preparationProbe.scopeTokens
        #expect(
            constructionScopeTokens
                == ["file-construction:\(StableKey.fromPath(fixture.rootURL)):epoch:1"]
        )
        #expect(!constructionScopeTokens[0].contains(firstSourceIdentity.sourceId))
        #expect(!constructionScopeTokens[0].contains(secondSourceIdentity.sourceId))
        #expect(firstSourceIdentity != secondSourceIdentity)
        #expect(firstEvents.fileTreePaths == secondEvents.fileTreePaths)
        #expect(firstEvents.fileTreePaths.count == 260)
        await firstSource.cancel(subscriptionId: subscription.subscriptionId)
        await secondSource.cancel(subscriptionId: subscription.subscriptionId)
        await assertSharedFileConstructionDrained(coordinator)
    }

    @Test("late pane replays then tails without backpressuring its peer")
    func latePaneReplaysAndTailsWithoutBackpressure() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 300)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let preparationProbe = SharedFilePreparationProbe()
        let buildGate = SharedFileBuildWindowGate()
        let lateDeliveryGate = SharedFilePaneDeliveryGate()
        let firstSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load,
            sharedSnapshotBuilder: buildGate.build
        )
        let lateSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load,
            sharedSnapshotBuilder: buildGate.build
        )
        let firstCollector = ProductFileSourceFactCollector()
        let lateCollector = ProductFileSourceFactCollector()
        let subscription = try fixture.openSnapshot()
        let firstOpen = Task {
            try await firstSource.open(
                subscription: subscription,
                productAdmission: fixture.productAdmission.context
            ) { event in
                await firstCollector.append(event, source: firstSource)
            }
        }
        await buildGate.waitUntilFirstWindowPublished()
        await firstCollector.waitForTreeWindowCount(1)

        // Act
        let lateOpen = Task {
            try await lateSource.open(
                subscription: subscription,
                productAdmission: fixture.productAdmission.context
            ) { event in
                if case .inventoryProgress = event {
                    await lateDeliveryGate.pauseFirstWindowDelivery()
                }
                await lateCollector.append(event, source: lateSource)
            }
        }
        await lateDeliveryGate.waitUntilPaused()
        await buildGate.releaseBuilder()
        try await firstOpen.value
        await lateDeliveryGate.releaseDelivery()
        try await lateOpen.value

        // Assert
        #expect(await preparationProbe.invocationCount == 1)
        #expect(await buildGate.completedBuildCount == 1)
        #expect((await firstCollector.events).fileTreePaths.count == 300)
        #expect((await lateCollector.events).fileTreePaths == (await firstCollector.events).fileTreePaths)
        await firstSource.cancel(subscriptionId: subscription.subscriptionId)
        await lateSource.cancel(subscriptionId: subscription.subscriptionId)
        await assertSharedFileConstructionDrained(coordinator)
    }

    @Test("one-field-different cwd selectors construct independently")
    func differentWorkingDirectorySelectorsDoNotShare() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let preparationProbe = SharedFilePreparationProbe()
        let firstSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000031")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load
        )
        let scopedSource = fixture.makeSource(
            paneId: UUID(uuidString: "00000000-0000-4000-8000-000000000032")!,
            constructionCoordinator: coordinator,
            snapshotPreparationLoader: preparationProbe.load
        )
        let rootSubscription = try fixture.openSnapshot()
        let scopedSubscription = try fixture.openSnapshot(cwdScope: "Scoped")

        // Act
        async let firstOpen: Void = firstSource.open(
            subscription: rootSubscription,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        async let scopedOpen: Void = scopedSource.open(
            subscription: scopedSubscription,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        _ = try await (firstOpen, scopedOpen)

        // Assert
        #expect(await preparationProbe.invocationCount == 2)
        await firstSource.cancel(subscriptionId: rootSubscription.subscriptionId)
        await scopedSource.cancel(subscriptionId: scopedSubscription.subscriptionId)
        await assertSharedFileConstructionDrained(coordinator)
    }
}

private actor SharedFilePreparationProbe {
    private(set) var invocationCount = 0
    private(set) var scopeTokens: [String] = []

    func load(
        rootURL: URL,
        gitReadContext: BridgeGitReadContext
    ) async -> BridgeSharedFileSnapshotPreparation {
        invocationCount += 1
        scopeTokens.append(gitReadContext.scopeKey.token)
        return BridgeSharedFileSnapshotPreparation(
            ignorePolicy: await loadTestBridgeFileIgnorePolicy(rootURL: rootURL),
            statusResult: .available(makeSharedFileStatus()),
            retainedByteCount: 0
        )
    }
}

private actor SharedFileBuildWindowGate {
    private var completedBuildWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWindowWaiters: [CheckedContinuation<Void, Never>] = []
    private var isBuilderReleased = false
    private var isFirstWindowPublished = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var completedBuildCount = 0

    func build(
        request: BridgeWorktreeFileMaterializationRequest,
        preparation: BridgeSharedFileSnapshotPreparation,
        publisher: BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion {
        let gatedPublisher = BridgeSharedFileSnapshotPublisher(
            preparationSink: publisher.publishPreparation,
            windowSink: { window in
                try await publisher.append(window)
                if window.ordinal == 0 {
                    await self.pauseAfterFirstWindow()
                }
            }
        )
        let completion = try await BridgeWorktreeFileMaterializer.buildSharedSnapshot(
            request: request,
            preparation: preparation,
            publisher: gatedPublisher
        )
        completedBuildCount += 1
        let waiters = completedBuildWaiters
        completedBuildWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        return completion
    }

    private func pauseAfterFirstWindow() async {
        isFirstWindowPublished = true
        let waiters = firstWindowWaiters
        firstWindowWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        guard !isBuilderReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilFirstWindowPublished() async {
        guard !isFirstWindowPublished else { return }
        await withCheckedContinuation { continuation in
            firstWindowWaiters.append(continuation)
        }
    }

    func releaseBuilder() {
        isBuilderReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private actor SharedFilePaneDeliveryGate {
    private var isPaused = false
    private var isReleased = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstWindowDelivery() async {
        guard !isReleased else { return }
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func releaseDelivery() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

extension Array where Element == ProductFileSourceObservation {
    fileprivate var firstFileSourceIdentity: BridgeProductFileSourceIdentity? {
        compactMap(\.sourceForTest).first
    }

    fileprivate var fileTreePaths: [String] {
        flatMap(\.inventoryProgressRowsForTest).map(\.path)
    }

    fileprivate var fileTreeWindows: [ProductFileInventoryObservation] {
        compactMap { event in
            guard case .inventoryProgress(let window) = event else { return nil }
            return window
        }
    }
}

private func makeSharedFileStatus() -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: .init(changed: 0, staged: 0, untracked: 0),
        branch: "main",
        origin: nil
    )
}

func assertSharedFileConstructionDrained(
    _ coordinator: BridgeWorktreeProductConstructionCoordinator
) async {
    let snapshot = await coordinator.snapshot()
    #expect(snapshot.entryCount == 0)
    #expect(snapshot.leaseCount == 0)
    #expect(snapshot.retainedArtifactByteCount == 0)
    #expect(snapshot.drainingTombstoneCount == 0)
}
