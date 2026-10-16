import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileMetadataSourceTests {
    @Test("invalidated foreground descriptor work neither caches nor fulfills its revision")
    @MainActor
    func invalidatedForegroundDescriptorWorkCanRetrySameRevision() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let materializationGate = ProductFileMaterializationGate()
        let cancellationProbe = ActivityFileDescriptorCancellationProbe()
        let source = fixture.makeSource(descriptorMaterializer: { request in
            await materializationGate.markStarted()
            await materializationGate.waitUntilReleased()
            await cancellationProbe.record(Task.isCancelled)
            return try await BridgePaneProductFileContentSource.materialize(request)
        })
        let openSnapshot = try fixture.openSnapshot()
        let viewDemand = try fixture.viewDemand()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let collector = ProductFileSourceFactCollector()
        let activity = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let originalForegroundWork = try #require(activity.acquireForegroundWork())
        let staleUpdateTask = Task {
            try await updateFileMetadata(
                source: source,
                subscriptionId: openSnapshot.subscriptionId,
                demand: viewDemand,
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: originalForegroundWork,
                collector: collector
            )
        }
        await materializationGate.waitUntilStarted()

        // Act
        activity.applyActivity(.loadedHidden)
        await materializationGate.release()
        _ = await staleUpdateTask.result
        let snapshotAfterInvalidation = await source.diagnosticSnapshot()
        let descriptorCountAfterInvalidation = await collector.descriptorReadyCount
        activity.applyActivity(.foreground)
        let retryForegroundWork = try #require(activity.acquireForegroundWork())
        try await updateFileMetadata(
            source: source,
            subscriptionId: openSnapshot.subscriptionId,
            demand: viewDemand,
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: retryForegroundWork,
            collector: collector
        )
        let snapshotAfterRetry = await source.diagnosticSnapshot()
        let descriptorCountAfterRetry = await collector.descriptorReadyCount

        // Assert
        #expect(!(await cancellationProbe.observedCancellation))
        #expect(descriptorCountAfterInvalidation == 0)
        #expect(snapshotAfterInvalidation.descriptorCount == 0)
        #expect(snapshotAfterInvalidation.inFlightDescriptorCount == 0)
        #expect(descriptorCountAfterRetry == 1)
        #expect(snapshotAfterRetry.descriptorCount == 1)
        #expect(snapshotAfterRetry.inFlightDescriptorCount == 0)
    }

    @Test("loaded-hidden File metadata rejects before tree refresh and manifest mutation")
    @MainActor
    func loadedHiddenFileMetadataRejectsBeforeTreeRefresh() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshProbe = ActivityFileRefreshGate(shouldSuspend: false)
        let source = fixture.makeSource(treeRowRefresher: { rootURL, paths, includeAncestors in
            await refreshProbe.refresh(
                rootURL: rootURL,
                paths: paths,
                includeAncestors: includeAncestors
            )
        })
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let baselineSnapshot = await source.diagnosticSnapshot()
        let activity = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let admittedForegroundWork = try #require(activity.acquireForegroundWork())
        activity.applyActivity(.loadedHidden)

        // Act
        let emissions = try await source.publish(
            changeset: activityMetadataChangeset(fixture: fixture, batchSequence: 81),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: admittedForegroundWork
        )

        // Assert
        #expect(await refreshProbe.refreshCount == 0)
        #expect(emissions.isEmpty)
        #expect(await source.diagnosticSnapshot() == baselineSnapshot)
    }

    @Test("hiding during File metadata refresh preserves manifest and emits nothing")
    @MainActor
    func hidingDuringFileMetadataRefreshSuppressesLateMutation() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshGate = ActivityFileRefreshGate(shouldSuspend: true)
        let source = fixture.makeSource(treeRowRefresher: { rootURL, paths, includeAncestors in
            await refreshGate.refresh(
                rootURL: rootURL,
                paths: paths,
                includeAncestors: includeAncestors
            )
        })
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let baselineSnapshot = await source.diagnosticSnapshot()
        let activity = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let admittedForegroundWork = try #require(activity.acquireForegroundWork())
        let publishTask = Task {
            try await source.publish(
                changeset: activityMetadataChangeset(fixture: fixture, batchSequence: 82),
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: admittedForegroundWork
            )
        }
        await refreshGate.waitUntilStarted()

        // Act
        activity.applyActivity(.loadedHidden)
        await refreshGate.release()
        let emissions = try await publishTask.value

        // Assert
        #expect(await refreshGate.refreshCount == 1)
        #expect(emissions.isEmpty)
        #expect(await source.diagnosticSnapshot() == baselineSnapshot)
    }
}

private actor ActivityFileDescriptorCancellationProbe {
    private(set) var observedCancellation = false

    func record(_ isCancelled: Bool) {
        observedCancellation = isCancelled
    }
}

private func updateFileMetadata(
    source: BridgePaneProductFileMetadataSource,
    subscriptionId: String,
    demand: BridgePaneProductFileViewDemand,
    productAdmission: BridgeProductAdmissionContext,
    foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
    collector: ProductFileSourceFactCollector
) async throws {
    guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
        throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
    }
    try await source.applyViewDemand(
        subscriptionId: subscriptionId,
        demand: demand,
        productAdmission: productAdmission,
        foregroundWorkAdmission: foregroundWorkAdmission,
        forceRecapture: false
    ) { event in
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
            throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
        }
        await collector.append(event, source: source)
    }
    guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
        throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
    }
}

extension ProductFileSourceFactCollector {
    fileprivate var descriptorReadyCount: Int {
        events.count { event in
            if case .descriptorReady = event { true } else { false }
        }
    }
}

private actor ActivityFileRefreshGate {
    private let shouldSuspend: Bool
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshCount = 0

    init(shouldSuspend: Bool) {
        self.shouldSuspend = shouldSuspend
    }

    func refresh(
        rootURL: URL,
        paths: Set<String>,
        includeAncestors: Bool
    ) async -> BridgeWorktreeRefreshedTreeRows {
        refreshCount += 1
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        if shouldSuspend, !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return await BridgeWorktreeFileMaterializer.refreshTreeRows(
            rootURL: rootURL,
            relativePaths: paths,
            includeAncestorDirectories: includeAncestors
        )
    }

    func waitUntilStarted() async {
        guard refreshCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

private func activityMetadataChangeset(
    fixture: ProductFileSourceFixture,
    batchSequence: UInt64
) -> FileChangeset {
    FileChangeset(
        worktreeId: fixture.worktreeId,
        repoId: fixture.repoId,
        rootPath: fixture.rootURL,
        paths: [fixture.demandedPath],
        timestamp: .now,
        batchSeq: batchSequence
    )
}
