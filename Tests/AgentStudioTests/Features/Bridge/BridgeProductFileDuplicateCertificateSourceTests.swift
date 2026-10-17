import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("File duplicate certificate source lifetime")
struct BridgeProductFileDuplicateCertificateSourceTests {
    @Test("selection during a duplicate certificate survives resnapshot and delivers its descriptor")
    func selectionSurvivesDuplicateCertificate() async throws {
        let registrations = LocalFactSource<String, BridgeProductViewDomainKey>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { $0.viewId }, isClosing: { _, _ in false }))
        let recorder = try registrations.attach()
        let registrationSink = registrations.sink
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { registrationSink("File", $0) })
        let delivery = try await FileChangeDeliveryFixture.open(harness: harness)
        let fixture = try ProductFileSourceFixture(fileCount: 9, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        let coordinator = BridgeWorktreeProductConstructionCoordinator()
        let source = fixture.makeSource(constructionCoordinator: coordinator)
        let subscription = try fixture.openSnapshot()
        let inventoryDemand = try fixture.viewDemand(foregroundPaths: [], handle: delivery.handle)
        let certificateHeld = HeldStep<BridgeWorktreeFileKeyedSnapshot>(
            "Real File source certificate at N3 emission")
        defer { certificateHeld.release() }
        let opening = Task {
            try await source.open(
                subscription: subscription, productAdmission: fixture.productAdmission.context
            ) { event in
                if case .sourceAccepted = event {
                    try await source.applyViewDemand(
                        subscriptionId: subscription.subscriptionId, demand: inventoryDemand,
                        productAdmission: fixture.productAdmission.context, forceRecapture: false
                    ) { _ in }
                }
                guard case .inventoryProgress = event,
                    let capture = await source.captureKeyedSnapshot(
                        subscriptionId: subscription.subscriptionId, demand: inventoryDemand,
                        productAdmission: fixture.productAdmission.context), capture.isEnumerationComplete
                else { return }
                try await delivery.seal(capture)
                try await certificateHeld.arrive(capture)
                // This is the production source-open callback's outcome mapping.
                switch await harness.session.awaitViewEmissionCompletion(
                    for: delivery.domain, handle: delivery.handle)
                {
                case .completed: break
                case .resnapshotRequired, .retired:
                    throw BridgePaneProductMetadataCoordinatorError.foregroundWorkInvalidated
                }
            }
        }
        let certificate = try await certificateHeld.firstArrival()
        for _ in 0..<9 { _ = try await delivery.nextFrame() }
        certificateHeld.release()
        _ = try await recorder.expectNext(
            in: "File", where: { $0 == delivery.domain }, "Real File source awaits certificate emission")
        let selection = try duplicateCertificateSelectionScope(delivery, path: fixture.demandedPath)
        #expect(
            await harness.session.acceptViewScope(
                selection, productAdmission: fixture.productAdmission.context) == nil)
        let selectedDemand = try fixture.viewDemand(
            scopeRevision: selection.scopeRevision, admissionSequence: selection.correlation.requestSequence,
            handle: delivery.handle)
        let observations = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: subscription.subscriptionId, demand: selectedDemand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false
        ) { event in await observations.append(event, source: source) }
        #expect(await source.contextBySubscriptionId[subscription.subscriptionId]?.initialEnumerationInFlight == true)
        #expect((await observations.events).isEmpty)
        try await delivery.seal(certificate)
        try await delivery.acknowledge(through: 8)
        for _ in 0..<3 {
            let frame = try await delivery.nextFrame()
            if case .batch(.part(let part)) = frame {
                try await delivery.acknowledge(through: part.deliverySequence)
            }
        }
        try await harness.session.enqueueNextViewFrameIfAvailable(for: delivery.lease)
        #expect(await harness.session.pendingFileSnapshotByViewDomain[delivery.domain] == nil)
        #expect(await harness.session.viewEmissionWaiterByDomain[delivery.domain] == nil)
        // The accepted recovery control must not invalidate an already-finished source open.
        let resnapshot = try BridgeProductStrictJSON.decode(
            BridgeProductViewResnapshotRequest.self,
            from: JSONSerialization.data(
                withJSONObject: delivery.requestObject(kind: "subscription.resnapshot", revision: 2)))
        #expect(
            await harness.session.acceptViewResnapshot(
                resnapshot, productAdmission: fixture.productAdmission.context) == nil)
        let outcome = await opening.result
        if case .failure(let error) = outcome {
            Issue.record("Completed certificate lost its source context on resnapshot: \(error)")
        }
        let context = await source.contextBySubscriptionId[subscription.subscriptionId]
        #expect(context != nil)
        if context != nil {
            #expect(context?.initialEnumerationInFlight == false)
            try await DuplicateCertificateEnrichmentProof(
                fixture: fixture, source: source, delivery: delivery, demand: selectedDemand,
                observations: observations
            ).verify()
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        await coordinator.shutdown()
        await assertBridgeConstructionCoordinatorDrained(coordinator)
        registrations.end()
        try await recorder.finish()
        try await harness.closeProducer(delivery.lease)
    }
}

private func duplicateCertificateSelectionScope(
    _ delivery: FileChangeDeliveryFixture, path: String
) throws -> BridgeProductViewScopeRequest {
    var object = delivery.requestObject(kind: "subscription.setScope", revision: 2)
    object["scope"] = [
        "kind": "file", "changeFilter": ["kind": "none"], "pathScope": [],
        "interests": [["lane": "foreground", "paths": [path]]],
    ]
    return try BridgeProductStrictJSON.decode(
        BridgeProductViewScopeRequest.self, from: JSONSerialization.data(withJSONObject: object))
}

private struct DuplicateCertificateEnrichmentProof {
    let fixture: ProductFileSourceFixture
    let source: BridgePaneProductFileMetadataSource
    let delivery: FileChangeDeliveryFixture
    let demand: BridgePaneProductFileViewDemand
    let observations: ProductFileSourceFactCollector

    func verify() async throws {
        try await source.applyViewDemand(
            subscriptionId: delivery.subscriptionId, demand: demand,
            productAdmission: fixture.productAdmission.context, forceRecapture: false
        ) { event in await observations.append(event, source: source) }
        #expect((await observations.events).compactMap(\.availableDescriptorForTest).count == 1)
        let enriched = try #require(
            await source.captureKeyedSnapshot(
                subscriptionId: delivery.subscriptionId, demand: demand,
                productAdmission: fixture.productAdmission.context))
        try await delivery.seal(enriched)
        let beginFrame = try await delivery.nextFrame()
        guard case .batch(.begin(let begin)) = beginFrame else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        #expect(begin.identity.scopeRevision == demand.scopeRevision)
        #expect(begin.mode == .snapshot)
        var descriptorCount = 0
        for _ in 0..<begin.partCount {
            let frame = try await delivery.nextFrame()
            if case .batch(.part(let part)) = frame {
                if case .put(_, _, .object(let fields)) = part.part,
                    let descriptor = fields["readDescriptor"], descriptor != .null
                {
                    descriptorCount += 1
                }
                try await delivery.acknowledge(through: part.deliverySequence)
            }
        }
        #expect(descriptorCount == 1)
        #expect(try await delivery.nextFrame().kind == "subscription.batchComplete")
        #expect(await source.contextBySubscriptionId[delivery.subscriptionId] != nil)
    }
}
