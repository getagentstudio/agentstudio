import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileMetadataSourceTests {
    @Test("pane close during descriptor materialization cannot cache or emit the descriptor")
    func paneCloseDuringDescriptorMaterializationRejectsLateDescriptor() async throws {
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
        await materializationGate.waitUntilStarted()
        await collector.removeAll()

        // Act
        fixture.productAdmission.close()
        await materializationGate.release()
        try await updateTask.value

        // Assert
        let snapshot = await source.diagnosticSnapshot()
        #expect((await collector.events).isEmpty)
        #expect(snapshot.descriptorCount == 0)
        #expect(snapshot.inFlightDescriptorCount == 0)
        #expect(snapshot.manifestRowCount == 1)
        #expect(snapshot.subscriptionCount == 1)
    }

    @Test("pane close during changeset refresh rejects manifest context and emission mutation")
    func paneCloseDuringChangesetRefreshRejectsLateMutation() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let refreshGate = ProductFileRefreshGate()
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
        let descriptorCollector = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: fixture.viewDemand(),
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await descriptorCollector.append(event, source: source)
        }
        let baselineSnapshot = await source.diagnosticSnapshot()
        let addedPath = "Added.swift"
        try Data("let added = true\n".utf8).write(to: fixture.rootURL.appending(path: addedPath))
        try Data("replacement\n".utf8).write(to: fixture.demandedFileURL)
        let publishTask = Task {
            try await source.publish(
                changeset: FileChangeset(
                    worktreeId: fixture.worktreeId,
                    repoId: fixture.repoId,
                    rootPath: fixture.rootURL,
                    paths: [fixture.demandedPath, addedPath],
                    timestamp: .now,
                    batchSeq: 5
                ),
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: refreshWorkAdmission.admission
            )
        }
        await refreshGate.waitUntilStarted()

        // Act
        fixture.productAdmission.close()
        await refreshGate.release()
        let emissions = try await publishTask.value

        // Assert
        let finalSnapshot = await source.diagnosticSnapshot()
        #expect(emissions.isEmpty)
        #expect(baselineSnapshot.descriptorCount == 1)
        #expect(baselineSnapshot.manifestRowCount == 1)
        #expect(finalSnapshot == baselineSnapshot)
    }

    @Test("subscription cleanup remains legal after pane admission closes")
    func subscriptionCleanupRemainsLegalAfterClose() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        fixture.productAdmission.close()

        // Act
        await source.cancel(subscriptionId: openSnapshot.subscriptionId)

        // Assert
        #expect(
            await source.diagnosticSnapshot()
                == .init(
                    descriptorCount: 0,
                    inFlightDescriptorCount: 0,
                    manifestRowCount: 0,
                    subscriptionCount: 0
                )
        )
    }
}

actor ProductFileMaterializationGate {
    private var didStart = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll(keepingCapacity: false)
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}

private actor ProductFileRefreshGate {
    private var didStart = false
    private var isReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func refresh(
        rootURL: URL,
        paths: Set<String>,
        includeAncestors: Bool
    ) async -> BridgeWorktreeRefreshedTreeRows {
        guard includeAncestors else {
            return await BridgeWorktreeFileMaterializer.refreshTreeRows(
                rootURL: rootURL,
                relativePaths: paths
            )
        }
        didStart = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll(keepingCapacity: false)
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return await BridgeWorktreeFileMaterializer.refreshTreeRows(
            rootURL: rootURL,
            relativePaths: paths,
            includeAncestorDirectories: true
        )
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll(keepingCapacity: false)
    }
}
