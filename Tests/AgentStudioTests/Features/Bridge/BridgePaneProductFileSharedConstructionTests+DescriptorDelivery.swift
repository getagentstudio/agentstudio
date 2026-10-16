import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileSharedConstructionTests {
    @Test("visible File inventory precedes certification and selected descriptor follows in a change batch")
    func selectedFileBecomesUsableBeforeCompleteTreeCommit() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let delivery = try await FileChangeDeliveryFixture.open(harness: harness)
        let fixture = try ProductFileSourceFixture(fileCount: 300, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let constructionHeld = HeldStep<Void>("Selected File construction after its first inventory window")
        let coverageHeld = HeldStep<ProductFileDescriptorBatchObservation>("First File coverage installed through N3")
        defer {
            constructionHeld.release()
            coverageHeld.release()
        }
        let source = fixture.makeSource(
            constructionCoordinator: coordinator,
            sharedSnapshotBuilder: { request, preparation, publisher in
                let windowPublisher = BridgeSharedFileSnapshotPublisher(
                    preparationSink: publisher.publishPreparation,
                    windowSink: { window in
                        try await publisher.append(window)
                        if window.ordinal == 0 { try await constructionHeld.arrive(()) }
                    })
                return try await BridgeWorktreeFileMaterializer.buildSharedSnapshot(
                    request: request, preparation: preparation, publisher: windowPublisher)
            })
        let subscription = try fixture.openSnapshot()
        let demand = try fixture.viewDemand()
        let recording = ProductFileDescriptorDeliveryContext(
            source: source, subscription: subscription, demand: demand,
            admission: fixture.productAdmission.context, delivery: delivery)
        let batches = ProductFileDescriptorBatchCollector()
        let observations = ProductFileSourceFactCollector()
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context
            ) { fact in
                await observations.append(fact, source: source)
                switch fact {
                case .sourceAccepted:
                    try await source.applyViewDemand(
                        subscriptionId: subscription.subscriptionId, demand: demand,
                        productAdmission: fixture.productAdmission.context, forceRecapture: false
                    ) { _ in }
                case .inventoryProgress(let progress):
                    let batch = try await recording.captureAndDeliver()
                    await batches.append(batch)
                    if progress.updatedPaths.contains(fixture.demandedPath) {
                        try await coverageHeld.arrive(batch)
                    }
                default: break
                }
            }
            // Exercise the existing post-open demand reconciliation after the certificate is emitted.
            try await source.applyViewDemand(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context, forceRecapture: true
            ) { fact in
                await observations.append(fact, source: source)
                if case .descriptorReady = fact {
                    await batches.append(try await recording.captureAndDeliver())
                }
            }
        }
        try await constructionHeld.firstArrival()
        let firstCoverage = try await coverageHeld.firstArrival()
        #expect(firstCoverage.begin.mode == .coverage)
        let firstRows = try firstCoverage.rows
        #expect(firstRows.contains { $0.displayKey == fixture.demandedPath })
        #expect(firstRows.count < 300)
        #expect(firstRows.allSatisfy { $0.readDescriptor == nil })
        let partial = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: subscription.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        #expect(!partial.isEnumerationComplete)
        #expect(partial.memberStatus.record.status == .loading)
        coverageHeld.release()
        constructionHeld.release()
        try await opening.value
        let delivered = await batches.batches
        let certificateIndex = try #require(delivered.firstIndex { $0.begin.mode == .snapshot })
        let descriptorIndex = try #require(delivered.firstIndex { $0.begin.mode == .change })
        #expect(descriptorIndex > certificateIndex)
        let certificate = delivered[certificateIndex]
        #expect(try certificate.rows.count == 300)
        try assertProductFileDescriptorChange(
            delivered[descriptorIndex], certificate: certificate, demandedPath: fixture.demandedPath)
        #expect(delivered.filter { $0.begin.mode == .change }.count == 1)
        #expect((await observations.events).compactMap(\.availableDescriptorForTest).count == 1)
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await assertSharedFileConstructionDrained(coordinator)
        try await harness.closeProducer(delivery.lease)
    }
}
