import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgeProductFileChangeDeliveryTests {
    @Test("a real bootstrap sealing failure cannot report inventory completion")
    func sealingFailureCannotCompleteBootstrap() async throws {
        let partialFacts = LocalFactSource<String, Bool>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { "partial:\($0)" }, isClosing: { _, _ in false }))
        let partialRecorder = try partialFacts.attach()
        let partialSink = partialFacts.sink
        let completionFacts = LocalFactSource<String, BridgeProductMetadataLifecycleTraceEvent>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { $0.result.rawValue }, isClosing: { _, _ in false }))
        let completionRecorder = try completionFacts.attach()
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            fileCaptureBatchSealer: { input, base in
                if input.snapshot.isEnumerationComplete { throw FileCaptureSealingProofFailure.rejectedCertificate }
                if input.snapshot.records.count == 1 { partialSink("File", true) }
                if let base { return try BridgeProductFileViewBatchFactory.sealChange(input, baseRevision: base) }
                return try BridgeProductFileViewBatchFactory.sealSnapshot(input)
            })
        let fixture = try ProductFileSourceFixture(fileCount: 1, productAdmission: harness.productAdmission)
        defer { fixture.remove() }
        let beforeWindow = HeldStep<Void>("File preparation before the first window")
        let beforeCompletion = HeldStep<Void>("File construction before the final certificate")
        defer {
            beforeWindow.release()
            beforeCompletion.release()
        }
        let source = fixture.makeSource(sharedSnapshotBuilder: { request, preparation, publisher in
            try await publisher.publishPreparation(preparation)
            try await beforeWindow.arrive(())
            let prepared = BridgeWorktreeFileMaterializationRequest(
                rootURL: request.rootURL, openedSource: request.openedSource.withIgnorePolicy(preparation.ignorePolicy))
            var ordinal = 0
            for try await window in BridgeWorktreeFileMaterializer.materializeTreeRowWindows(
                request: prepared, afterCount: 0, windowSize: 2)
            {
                try await publisher.append(
                    .init(
                        ordinal: ordinal, startIndex: window.startIndex,
                        discoveredRowCount: window.discoveredRowCount, isFinalWindow: window.isFinalWindow,
                        rows: window.rows, retainedByteCount: 256))
                ordinal += 1
            }
            try await beforeCompletion.arrive(())
            return .init()
        })
        let lease = try await harness.admitMetadataFrames(through: 0)
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: source, reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: foreground.source,
            lifecycleTraceRecorder: FileSealingCompletionTrace(sink: completionFacts.sink))
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(), lease: lease,
            productAdmission: harness.productAdmission.context, session: harness.session)
        let delivery = try await beginFileSealingBootstrap(
            fixture: fixture, harness: harness, coordinator: coordinator, lease: lease)
        try await beforeWindow.firstArrival()
        let scope = try delivery.scopeRequest(revision: 1, paths: [])
        #expect(await harness.session.acceptViewScope(scope, productAdmission: harness.productAdmission.context) == nil)
        try await source.applyViewDemand(
            subscriptionId: delivery.subscriptionId,
            demand: .init(
                admissionSequence: scope.correlation.requestSequence, handle: scope.handle,
                scopeRevision: scope.scopeRevision, state: .init(interests: [], pathScope: [])),
            productAdmission: harness.productAdmission.context, forceRecapture: false
        ) { _ in }
        let pumping = Task { try await pumpSealingProofFrames(delivery) }
        beforeWindow.release()
        try await beforeCompletion.firstArrival()
        try await partialRecorder.expectNext(in: "File", true)
        #expect(
            await harness.session.awaitViewEmissionCompletion(for: delivery.domain, handle: delivery.handle)
                == .completed)
        beforeCompletion.release()
        let completion = try await completionRecorder.expectNext(
            in: "File", where: { $0.stage == .bootstrapFinished }, "File bootstrap terminal")
        #expect(completion.result == .failure)
        #expect(await source.diagnosticSnapshot().subscriptionCount == 0)
        await coordinator.closeAndDrain()
        try await harness.closeProducer(lease)
        try await pumping.value
        partialFacts.end()
        completionFacts.end()
        try await partialRecorder.finish()
        try await completionRecorder.finish()
    }
}

private enum FileCaptureSealingProofFailure: Error {
    case rejectedCertificate
}

private struct FileSealingCompletionTrace: BridgeProductMetadataLifecycleTraceRecording {
    let sink: @Sendable (String, BridgeProductMetadataLifecycleTraceEvent) -> Void

    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        if event.stage == .bootstrapFinished { sink("File", event) }
    }

    func record(_: BridgeAnnotationLifecycleTraceEvent) async {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}
}

private func beginFileSealingBootstrap(
    fixture: ProductFileSourceFixture, harness: BridgeProductSessionLifecycleHarness,
    coordinator: BridgePaneProductMetadataCoordinator, lease: BridgeProductProducerLease
) async throws -> FileChangeDeliveryFixture {
    var object = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    object["subscription"] = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(fixture.openSnapshot().subscription))
    let request = try bridgeProductLifecycleControlRequest(object)
    let token = try #require(controlExecutionToken(try await harness.begin(request)))
    #expect(await harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(correlating: request, worktreeId: nil)
    let effect = try await harness.session.completeAdmittedControl(
        token: token, exactResponseBytes: JSONEncoder().encode(response))
    _ = try #require(
        await consumeNextBridgeProductProducerFrame(
            for: lease, from: harness.session, productAdmission: harness.productAdmission.context))
    await coordinator.apply(effect, productAdmission: harness.productAdmission.context)
    await harness.session.settleControlProviderDispatch(token: token)
    return .init(harness: harness, lease: lease)
}

private func pumpSealingProofFrames(_ delivery: FileChangeDeliveryFixture) async throws {
    while true {
        let result = await delivery.harness.session.pullProducerFrame(
            for: delivery.lease, productAdmission: delivery.harness.productAdmission.context)
        guard case .frame(let frame) = result else { return }
        #expect(
            await delivery.harness.session.acknowledgeProducerFrameConsumed(
                frame.receipt, productAdmission: delivery.harness.productAdmission.context))
        for decoded in try BridgeProductMetadataFrameDecoder().append(frame.frame.data) {
            if case .batch(.part(let part)) = decoded {
                try await delivery.acknowledge(through: part.deliverySequence)
            }
        }
    }
}
