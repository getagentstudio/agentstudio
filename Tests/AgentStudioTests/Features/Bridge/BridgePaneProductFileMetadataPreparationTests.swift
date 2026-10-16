import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File metadata preparation and post-open enrichment")
struct BridgePaneProductFileMetadataPreparationTests {
    @Test("source acceptance does not wait for ignore-policy preparation")
    func sourceAcceptancePrecedesIgnorePolicyPreparation() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let preparationGate = ProductFileMaterializationGate()
        let source = fixture.makeSource(ignorePolicyLoader: { _ in
            await preparationGate.markStarted()
            await preparationGate.waitUntilReleased()
            return .empty
        })
        let collector = ProductFileSourceFactCollector()

        // Act
        let openTask = Task {
            try await source.open(
                subscription: fixture.openSnapshot(),
                productAdmission: fixture.productAdmission.context
            ) { event in
                await collector.append(event, source: source)
            }
        }
        await preparationGate.waitUntilStarted()
        let eventsBeforePreparationFinished = await collector.events
        await preparationGate.release()
        try await openTask.value

        // Assert
        #expect(
            eventsBeforePreparationFinished.contains {
                if case .sourceAccepted = $0 { true } else { false }
            }
        )
    }

    @Test("interest committed during preparation is fulfilled after the manifest is ready")
    func interestCommittedDuringPreparationIsFulfilled() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let delivery = try await FileChangeDeliveryFixture.open(harness: harness)
        let fixture = try ProductFileSourceFixture(fileCount: 1, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        let preparationGate = ProductFileMaterializationGate()
        let source = fixture.makeSource(ignorePolicyLoader: { _ in
            await preparationGate.markStarted()
            await preparationGate.waitUntilReleased()
            return .empty
        })
        let collector = ProductFileSourceFactCollector()
        let openSnapshot = try fixture.openSnapshot()
        let openTask = Task {
            try await source.open(
                subscription: openSnapshot,
                productAdmission: fixture.productAdmission.context
            ) { event in
                await collector.append(event, source: source)
            }
        }
        await preparationGate.waitUntilStarted()

        // Act
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: fixture.viewDemand(),
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            await collector.append(event, source: source)
        }
        await preparationGate.release()
        try await openTask.value

        #expect((await collector.events).compactMap(\.availableDescriptorForTest).isEmpty)
        let demand = try fixture.viewDemand()
        let recording = ProductFileDescriptorDeliveryContext(
            source: source, subscription: openSnapshot, demand: demand,
            admission: fixture.productAdmission.context, delivery: delivery)
        let certificate = try await recording.captureAndDeliver()
        let batchFacts = LocalFactSource<String, ProductFileDescriptorBatchObservation>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { "\($0.begin.mode.rawValue):\($0.begin.targetRevision)" },
                isClosing: { _, _ in false }))
        let recorder = try batchFacts.attach()
        let emitBatch = batchFacts.sink
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: demand,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: true
        ) { event in
            await collector.append(event, source: source)
            if case .descriptorReady = event {
                emitBatch("File", try await recording.captureAndDeliver())
            }
        }
        let enrichment = try await recorder.expectNext(
            in: "File", where: { $0.begin.mode == .change }, "the demanded File descriptor change batch")
        try assertProductFileDescriptorChange(
            enrichment, certificate: certificate, demandedPath: fixture.demandedPath)
        batchFacts.end()
        try await recorder.finish()
        await source.cancel(subscriptionId: openSnapshot.subscriptionId)
        try await harness.closeProducer(delivery.lease)

        // Assert
        #expect(
            (await collector.events).contains {
                if case .descriptorReady = $0 { true } else { false }
            }
        )
    }

}
