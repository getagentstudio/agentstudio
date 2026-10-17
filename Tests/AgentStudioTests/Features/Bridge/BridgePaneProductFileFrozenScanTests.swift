import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File admitted scan remains frozen under churn")
struct BridgePaneProductFileFrozenScanTests {
    @Test(
        "ordinary churn leaves the admitted inventory unchanged and drains after its certificate",
        arguments: [false, true])
    func churnFollowsCertificate(invalidateConstruction: Bool) async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let delivery = try await FileChangeDeliveryFixture.open(harness: harness)
        let fixture = try ProductFileSourceFixture(fileCount: 3, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let constructionHeld = HeldStep<Void>("Frozen File construction after its first window")
        let firstWindow = HeldStep<Void>("Frozen File source indexed its first window")
        defer {
            constructionHeld.release()
            firstWindow.release()
        }
        let source = fixture.makeSource(
            constructionCoordinator: coordinator,
            sharedSnapshotBuilder: frozenScanBuilder(held: constructionHeld))
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(foregroundPaths: [])
        let captures = FrozenFileCaptureCollector()
        let recording = FrozenFileDeliveryContext(
            source: source, subscription: subscription, demand: demand,
            productAdmission: fixture.productAdmission.context, delivery: delivery, captures: captures)
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context
            ) { event in
                try await recording.recordCurrentCapture()
                if case .inventoryProgress(let window) = event, window.updatedPaths.contains(fixture.demandedPath) {
                    try await firstWindow.arrive(())
                }
            }
        }
        try await constructionHeld.firstArrival()
        try await firstWindow.firstArrival()
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false
        ) { _ in }
        let beforeChurn = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let addedPath = "Added.swift"
        for sequence in 1...3 {
            try Data("changed \(sequence)\n".utf8).write(to: fixture.rootURL.appending(path: addedPath))
            try Data("replaced \(sequence)\n".utf8).write(to: fixture.demandedFileURL)
            if invalidateConstruction {
                _ = await coordinator.invalidate(
                    worktree: .init(
                        repoIdentity: fixture.repoId.uuidString, worktreeIdentity: fixture.worktreeId.uuidString,
                        stableRootIdentity: StableKey.fromPath(fixture.rootURL)))
            }
            let emissions = try await source.publish(
                changeset: .init(
                    worktreeId: fixture.worktreeId, repoId: fixture.repoId, rootPath: fixture.rootURL,
                    paths: [fixture.demandedPath, addedPath], timestamp: .now, batchSeq: UInt64(sequence)),
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground.admission)
            #expect(emissions.isEmpty)
        }
        let duringChurn = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        #expect(duringChurn.targetRevision == beforeChurn.targetRevision)
        #expect(duringChurn.records.map(\.row.path) == beforeChurn.records.map(\.row.path))
        #expect(!duringChurn.isEnumerationComplete)
        firstWindow.release()
        constructionHeld.release()
        let result = await opening.result
        if case .failure(let error) = result {
            Issue.record("Ordinary churn failed the admitted File scan: \(error)")
        } else {
            let snapshots = await captures.snapshots
            let certificate = try #require(snapshots.first { $0.isEnumerationComplete })
            #expect(certificate.records.count == 3)
            #expect(!certificate.records.contains { $0.row.path == addedPath })
            let drained = try #require(
                await source.captureKeyedSnapshot(
                    subscriptionId: subscription.subscriptionId, demand: demand,
                    productAdmission: fixture.productAdmission.context))
            #expect(drained.records.contains { $0.row.path == addedPath })
            #expect(drained.targetRevision > certificate.targetRevision)
            #expect(
                (drained.records.first { $0.row.path == fixture.demandedPath }?.revision
                    ?? 0) > certificate.targetRevision)
            try await assertFrozenScanDelivery(
                captures: captures, certificateRevision: certificate.targetRevision,
                changedPaths: [addedPath, fixture.demandedPath])
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
        try await harness.closeProducer(delivery.lease)
    }
}

private func assertFrozenScanDelivery(
    captures: FrozenFileCaptureCollector, certificateRevision: Int, changedPaths: [String]
) async throws {
    let deliveries = await captures.deliveries
    let certificateDelivery = try #require(deliveries.first { $0.begin.mode == .snapshot })
    #expect(certificateDelivery.begin.targetRevision == certificateRevision)
    #expect(certificateDelivery.recordKeys.count == 4)
    let changes = deliveries.filter { $0.begin.mode == .change }
    #expect(changes.count == 1)
    if let change = changes.first {
        #expect(change.begin.baseRevision == certificateDelivery.begin.targetRevision)
        #expect(change.recordKeys.count == changedPaths.count)
        for path in changedPaths {
            #expect(change.recordKeys.contains { $0.hasSuffix("/\(path)") })
        }
    }
}

private actor FrozenFileCaptureCollector {
    struct Delivery: Sendable {
        let begin: BridgeProductBatchBeginFrame
        let recordKeys: [String]
    }

    private(set) var snapshots: [BridgeWorktreeFileKeyedSnapshot] = []
    private(set) var deliveries: [Delivery] = []

    func append(_ snapshot: BridgeWorktreeFileKeyedSnapshot) {
        snapshots.append(snapshot)
    }

    func recordDelivery(begin: BridgeProductBatchBeginFrame, recordKeys: [String]) {
        deliveries.append(.init(begin: begin, recordKeys: recordKeys))
    }
}

private func frozenScanBuilder(held: HeldStep<Void>) -> BridgePaneProductFileSharedSnapshotBuilder {
    { request, preparation, publisher in
        try await publisher.publishPreparation(preparation)
        let preparedRequest = BridgeWorktreeFileMaterializationRequest(
            rootURL: request.rootURL,
            openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy))
        // Freeze real materialized input before delivering windows to the leased reader.
        var windows: [BridgeWorktreeTreeRowWindowBatch] = []
        for try await window in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
            request: preparedRequest, afterCount: 0, windowSize: 2)
        {
            windows.append(window)
        }
        for (ordinal, window) in windows.enumerated() {
            try await publisher.append(
                .init(
                    ordinal: ordinal, startIndex: window.startIndex,
                    discoveredRowCount: window.discoveredRowCount, isFinalWindow: window.isFinalWindow,
                    rows: window.rows, retainedByteCount: 256))
            if ordinal == 0 { try await held.arrive(()) }
        }
        return .init()
    }
}

private struct FrozenFileDeliveryContext: Sendable {
    let source: BridgePaneProductFileMetadataSource
    let subscription: BridgeProductSubscriptionSnapshot
    let demand: BridgePaneProductFileViewDemand
    let productAdmission: BridgeProductAdmissionContext
    let delivery: FileChangeDeliveryFixture
    let captures: FrozenFileCaptureCollector

    func recordCurrentCapture() async throws {
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: productAdmission, forceRecapture: false
        ) { _ in }
        if let snapshot = await source.captureKeyedSnapshot(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: productAdmission)
        {
            await captures.append(snapshot)
            // The real N3 session seals and pumps each canonical source capture.
            // No legacy event payload is used to build the wire inventory.
            try await delivery.seal(snapshot)
            let beginFrame = try await delivery.nextFrame()
            guard case .batch(.begin(let begin)) = beginFrame else {
                throw ProductFileSourceFixtureError.invalidControlRequest
            }
            var recordKeys: [String] = []
            for _ in 0..<begin.partCount {
                let frame = try await delivery.nextFrame()
                if case .batch(.part(let part)) = frame {
                    switch part.part {
                    case .put(let key, _, _), .delete(let key, _), .evict(let key):
                        recordKeys.append(key)
                    }
                    try await delivery.acknowledge(through: part.deliverySequence)
                }
            }
            #expect(try await delivery.nextFrame().kind == "subscription.batchComplete")
            await captures.recordDelivery(begin: begin, recordKeys: recordKeys)
        }
    }
}
