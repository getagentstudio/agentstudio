import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File retained-view revision floor")
struct BridgeProductFileRevisionFloorTests {
    @Test(
        "failed or given-up progressive bootstrap keeps the revision floor for a smaller Retry",
        arguments: [false, true])
    func smallerRetryContinuesInstalledCoverage(giveUp: Bool) async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 12)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let laterRead = HeldStep<Void>("File builder after published coverage before later read")
        let coverage = HeldStep<BridgeWorktreeFileKeyedSnapshot>("File source issued progressive coverage")
        coverage.release()
        defer { laterRead.release() }
        let builder = RevisionFloorProgressiveBuilder(laterRead: laterRead)
        let source = fixture.makeSource(constructionCoordinator: coordinator, sharedSnapshotBuilder: builder.build)
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(foregroundPaths: [])
        let activity = await MainActor.run { BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground) }
        let foreground = try #require(await activity.acquireForegroundWork())
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: foreground
            ) { event in
                if case .sourceAccepted = event {
                    try await source.applyViewDemand(
                        subscriptionId: subscription.subscriptionId, demand: demand,
                        productAdmission: fixture.productAdmission.context, foregroundWorkAdmission: foreground,
                        forceRecapture: false, emit: { _ in })
                }
                if case .inventoryProgress = event,
                    let capture = await source.captureKeyedSnapshot(
                        subscriptionId: subscription.subscriptionId,
                        demand: demand, productAdmission: fixture.productAdmission.context),
                    !capture.isEnumerationComplete
                {
                    try await coverage.arrive(capture)
                }
            }
        }
        _ = try await laterRead.firstArrival()
        let installedCoverage = try await coverage.firstArrival()
        let coverageBatch = try sealProductFileSourceCapture(installedCoverage, demand: demand)
        #expect(coverageBatch.mode == .coverage)
        #expect(installedCoverage.records.count == 10)
        if giveUp {
            await activity.applyActivity(.loadedHidden)
            laterRead.release()
        } else {
            laterRead.fail(RevisionFloorTestError.laterReadFailed)
        }
        let outcome = await opening.result
        if giveUp {
            if case .failure(let error) = outcome {
                Issue.record("Given-up bootstrap should release normally: \(error)")
            }
        } else {
            if case .success = outcome { Issue.record("Later construction read must fail") }
        }
        #expect(await source.contextBySubscriptionId[subscription.subscriptionId] == nil)
        try repairToSmallerInventory(fixture)
        // Explicit Retry restarts only the source, on the same subscription and handle.
        try await source.open(
            subscription: subscription, productAdmission: fixture.productAdmission.context, emit: { _ in })
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false, emit: { _ in })
        let repaired = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId,
                demand: demand, productAdmission: fixture.productAdmission.context))
        let certificate = try sealProductFileSourceCapture(repaired, demand: demand)
        #expect(certificate.mode == .snapshot)
        #expect(certificate.handle == coverageBatch.handle)
        #expect(certificate.viewDomain == coverageBatch.viewDomain)
        #expect(certificate.targetRevision > coverageBatch.targetRevision)
        #expect(repaired.records.map(\.row.path) == [fixture.demandedPath])
        #expect(repaired.records.allSatisfy { $0.revision > installedCoverage.targetRevision })
        #expect(repaired.memberStatus.revision > installedCoverage.targetRevision)
        #expect(repaired.isEnumerationComplete)
        try assertRevisionFloorCorpus(coverage: coverageBatch, certificate: certificate)
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }

    @Test("overlapping cancel and open transfers the retiring floor before initializing the successor")
    func overlappingCancellationCannotLoseRevisionFloor() async throws {
        let fixture = try ProductFileSourceFixture(fileCount: 12)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let captureHeld = HeldStep<Int>("Retiring File revision captured before source handoff")
        defer { captureHeld.release() }
        let capture = RevisionFloorCaptureProbe(firstCapture: captureHeld)
        let source = fixture.makeSource(constructionCoordinator: coordinator, revisionFloorCapture: capture.read)
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand(foregroundPaths: [])
        try await source.open(
            subscription: subscription, productAdmission: fixture.productAdmission.context, emit: { _ in })
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false, emit: { _ in })
        let old = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId,
                demand: demand, productAdmission: fixture.productAdmission.context))
        let retiring = Task { await source.cancel(subscriptionId: subscription.subscriptionId) }
        let retiringFloor = try await captureHeld.firstArrival()
        #expect(retiringFloor == old.targetRevision)
        #expect(await source.contextBySubscriptionId[subscription.subscriptionId] == nil)
        try repairToSmallerInventory(fixture)
        let successor = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context, emit: { _ in })
            try await source.applyViewDemand(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context, forceRecapture: false, emit: { _ in })
            return await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId,
                demand: demand, productAdmission: fixture.productAdmission.context)
        }
        // A second cancel may finish the same index capture while the first reply
        // is held; initialization must still consume that published floor.
        let new = try #require(try await successor.value)
        #expect(new.records.map(\.row.path) == [fixture.demandedPath])
        #expect(new.targetRevision > retiringFloor)
        #expect(new.records.allSatisfy { $0.revision > retiringFloor })
        #expect(await capture.captureCount == 2)
        let successorIdentity = await source.contextBySubscriptionId[subscription.subscriptionId]?.productSource
        captureHeld.release()
        await retiring.value
        #expect(await source.contextBySubscriptionId[subscription.subscriptionId]?.productSource == successorIdentity)
        #expect(await source.lastIssuedFileViewRevision >= retiringFloor)
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
    }
}

private enum RevisionFloorTestError: Error { case laterReadFailed }

private actor RevisionFloorProgressiveBuilder {
    let laterRead: HeldStep<Void>
    private var buildCount = 0
    init(laterRead: HeldStep<Void>) { self.laterRead = laterRead }

    func build(
        request: BridgeWorktreeFileMaterializationRequest, preparation: BridgeSharedFileSnapshotPreparation,
        publisher: BridgeSharedFileSnapshotPublisher
    ) async throws -> BridgeSharedFileSnapshotCompletion {
        buildCount += 1
        if buildCount > 1 {
            return try await BridgeWorktreeFileMaterializer.buildSharedSnapshot(
                request: request,
                preparation: preparation, publisher: publisher)
        }
        try await publisher.publishPreparation(preparation)
        let prepared = BridgeWorktreeFileMaterializationRequest(
            rootURL: request.rootURL,
            openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy))
        var ordinal = 0
        for try await batch in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
            request: prepared, afterCount: 0, windowSize: 10)
        {
            try await publisher.append(
                .init(
                    ordinal: ordinal, startIndex: batch.startIndex,
                    discoveredRowCount: batch.discoveredRowCount, isFinalWindow: batch.isFinalWindow,
                    rows: batch.rows, retainedByteCount: 256))
            if ordinal == 0 { try await laterRead.arrive(()) }
            ordinal += 1
        }
        return .init()
    }
}

private actor RevisionFloorCaptureProbe {
    let firstCapture: HeldStep<Int>
    private(set) var captureCount = 0
    init(firstCapture: HeldStep<Int>) { self.firstCapture = firstCapture }
    func read(_ index: BridgeWorktreeFileManifestIndex) async -> Int {
        captureCount += 1
        let ordinal = captureCount
        let revision = await index.captureKeyedSnapshot().targetRevision
        if ordinal == 1 { _ = try? await firstCapture.arrive(revision) }
        return revision
    }
}

private func repairToSmallerInventory(_ fixture: ProductFileSourceFixture) throws {
    for index in 1..<12 {
        try FileManager.default.removeItem(
            at: fixture.rootURL.appending(path: String(format: "File-%04d.swift", index)))
    }
    try Data("repaired smaller inventory\n".utf8).write(to: fixture.demandedFileURL)
}

private struct FileRevisionFloorCorpus: Decodable {
    struct Capture: Decodable, Equatable {
        let mode: BridgeProductBatchMode
        let targetRevision: Int
        let parts: [BridgeProductBatchPart]
        let snapshotCause: BridgeProductSnapshotCause?

        init(batch: BridgeProductSealedViewBatch, snapshotCause: BridgeProductSnapshotCause?) {
            mode = batch.mode
            targetRevision = batch.targetRevision
            parts = batch.parts.map(normalizeRevisionFloorPart)
            self.snapshotCause = snapshotCause
        }
    }

    let coverage: Capture
    let certificate: Capture
}

private func assertRevisionFloorCorpus(
    coverage: BridgeProductSealedViewBatch,
    certificate: BridgeProductSealedViewBatch
) throws {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let relativePath = "valid/bridge-product-file-retained-minter-corpus.json"
    let swiftBytes = try Data(contentsOf: projectRoot.appending(path: "Tests/BridgeContractFixtures/" + relativePath))
    let mirroredBytes = try Data(
        contentsOf: projectRoot.appending(path: "BridgeWeb/src/test-fixtures/bridge-contract-fixtures/" + relativePath))
    #expect(swiftBytes == mirroredBytes)
    let corpus = try JSONDecoder().decode(FileRevisionFloorCorpus.self, from: swiftBytes)
    // Apart from physical root spelling/hash, compare every field replayed by
    // W4. A native revision, row or mode drift must fail this permanent gate.
    let causes = try emittedRetrySnapshotCauses(coverage: coverage, certificate: certificate)
    #expect(FileRevisionFloorCorpus.Capture(batch: coverage, snapshotCause: causes.coverage) == corpus.coverage)
    #expect(
        FileRevisionFloorCorpus.Capture(batch: certificate, snapshotCause: causes.certificate) == corpus.certificate)
}

private func emittedRetrySnapshotCauses(
    coverage: BridgeProductSealedViewBatch,
    certificate: BridgeProductSealedViewBatch
) throws -> (coverage: BridgeProductSnapshotCause?, certificate: BridgeProductSnapshotCause?) {
    var sender = BridgeProductViewSenderState(maximumDirtyKeys: 32, creditParts: 4, creditBytes: 100_000)
    let stream = BridgeProductMetadataStreamCorrelation(
        metadataStreamId: "retained-minter-stream", paneSessionId: "retained-minter-pane",
        wireVersion: BridgeProductWireContract.version, workerInstanceId: "retained-minter-worker")
    sender.open(coverage.viewDomain, handle: coverage.handle, scanGeneration: coverage.producerScanGeneration)
    try sender.seal(coverage)
    var coverageCause: BridgeProductSnapshotCause?
    for ordinal in 0..<coverage.frameCount {
        let frame = try #require(try sender.nextFrame(stream: stream, streamSequence: ordinal + 1))
        if case .batch(.begin(let begin)) = frame {
            #expect(begin.mode == .coverage)
            #expect(begin.snapshotCause == nil)
            coverageCause = begin.snapshotCause
        }
        if case .batch(.part(let part)) = frame {
            #expect(
                sender.acknowledge(for: coverage.viewDomain, handle: coverage.handle, through: part.deliverySequence))
        }
    }
    #expect(sender.pending(for: coverage.viewDomain) == .snapshotRequired(.open))
    // Explicit Retry can request a snapshot, but partial coverage never paid
    // the initial open obligation. C5 reuses this domain rather than opening it.
    // ViewDelivery:533 marks requested; BatchWireContract:17 preserves open;
    // ViewSenderState:98-106 consumes the owed cause only for snapshots.
    sender.resnapshot(coverage.viewDomain, cause: .requested)
    #expect(sender.pending(for: coverage.viewDomain) == .snapshotRequired(.open))
    try sender.seal(certificate)
    let frame = try #require(try sender.nextFrame(stream: stream, streamSequence: coverage.frameCount + 1))
    guard case .batch(.begin(let begin)) = frame else {
        throw ProductFileSourceFixtureError.invalidControlRequest
    }
    #expect(begin.mode == .snapshot)
    #expect(begin.snapshotCause == .open)
    #expect(sender.pending(for: coverage.viewDomain) == .keys([:]))
    return (coverageCause, begin.snapshotCause)
}

private func normalizeRevisionFloorPart(_ part: BridgeProductBatchPart) -> BridgeProductBatchPart {
    func key(_ original: String) -> String {
        original.hasPrefix("/")
            ? "/retained-minter-fixture/" + URL(fileURLWithPath: original).lastPathComponent : original
    }
    switch part {
    case .put(let originalKey, let revision, let value):
        var normalizedValue = value
        if originalKey == BridgeProductFileMemberStatusRecord.recordKey,
            case .object(var fields) = value,
            case .object(var source)? = fields["source"],
            case .string? = source["rootRevisionToken"]
        {
            source["rootRevisionToken"] = .string("retained-minter-root")
            fields["source"] = .object(source)
            normalizedValue = .object(fields)
        }
        return .put(key: key(originalKey), revision: revision, value: normalizedValue)
    case .delete(let originalKey, let revision):
        return .delete(key: key(originalKey), revision: revision)
    case .evict(let originalKey):
        return .evict(key: key(originalKey))
    }
}
