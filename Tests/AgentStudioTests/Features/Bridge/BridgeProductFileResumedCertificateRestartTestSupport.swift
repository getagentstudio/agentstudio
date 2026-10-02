import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

enum ResumedFileRestartFact: Sendable {
    case lifecycle(BridgeProductMetadataLifecycleTraceEvent)
    case waiter(BridgeProductViewDomainKey)
    case descriptorDelivered(BridgeProductFileContentDescriptor)
    case interruptedState(contextCount: Int, deferred: Bool)

    var recordingScope: String {
        switch self {
        case .lifecycle: "lifecycle"
        case .waiter: "waiter"
        case .descriptorDelivered: "descriptor"
        case .interruptedState: "pump-state"
        }
    }

    var description: String {
        switch self {
        case .lifecycle(let event): "\(event.stage.rawValue):\(event.result.rawValue)"
        case .waiter(let domain): "certificate waiter for \(domain.viewId)"
        case .descriptorDelivered(let descriptor):
            "descriptor generation \(descriptor.source.subscriptionGeneration), SHA \(descriptor.expectedSha256)"
        case .interruptedState(let count, let deferred):
            "after interrupted bootstrap: contexts=\(count), deferred=\(deferred)"
        }
    }
    var descriptor: BridgeProductFileContentDescriptor? {
        if case .descriptorDelivered(let descriptor) = self { descriptor } else { nil }
    }
    var isWaiter: Bool { if case .waiter = self { true } else { false } }
    var isSuccessfulBootstrap: Bool {
        if case .lifecycle(let event) = self {
            event.stage == .bootstrapFinished && event.result == .success
        } else {
            false
        }
    }
    var isInterruptedBootstrap: Bool {
        if case .lifecycle(let event) = self {
            event.stage == .bootstrapFinished && event.result == .failure
        } else {
            false
        }
    }
}

struct ResumedFileRestartTrace: BridgeProductMetadataLifecycleTraceRecording {
    let sink: @Sendable (String, ResumedFileRestartFact) -> Void
    func record(_ event: BridgeProductMetadataLifecycleTraceEvent) async {
        if event.subscriptionKind == .fileMetadata, event.stage == .bootstrapFinished {
            sink("File", .lifecycle(event))
        }
    }
    func record(_: BridgeAnnotationLifecycleTraceEvent) async {}
    func record(_: BridgeProductReviewMetadataPublicationTraceEvent) async {}
}

struct ResumedFileRestartContext: Sendable {
    let harness: BridgeProductSessionLifecycleHarness
    let fixture: ProductFileSourceFixture
    let source: BridgePaneProductFileMetadataSource
    let provider: BridgePaneProductSchemeProvider
    let dispatcher: BridgeProductSchemeControlDispatcher
    let initialSourceHeld: HeldStep<BridgeProductFileSourceIdentity>
    let replaySourceHeld: HeldStep<BridgeProductFileSourceIdentity>
    let sink: @Sendable (String, ResumedFileRestartFact) -> Void

    static func make(sink: @escaping @Sendable (String, ResumedFileRestartFact) -> Void) async throws -> Self {
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            deadlineClock: TestPushClock(), viewEmissionWaiterRegistrationObserver: { sink("File", .waiter($0)) })
        let fixture = try ProductFileSourceFixture(fileCount: 9, productAdmission: harness.productAdmission)
        let source = fixture.makeSource()
        let foreground = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: source, reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(), markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: foreground.source, lifecycleTraceRecorder: ResumedFileRestartTrace(sink: sink))
        let context = Self(
            harness: harness, fixture: fixture, source: source, provider: provider,
            dispatcher: makeBridgeProductSchemeControlDispatcher(
                session: harness.session, provider: provider, productAdmission: harness.productAdmission.context),
            initialSourceHeld: HeldStep("Initial File source before inventory"),
            replaySourceHeld: HeldStep("Retained File replay source before inventory"), sink: sink)
        await source.setSourceAcceptedObserver { identity in
            if identity.subscriptionGeneration == 1 {
                try? await context.initialSourceHeld.arrive(identity)
            } else if identity.subscriptionGeneration == 2 {
                try? await context.replaySourceHeld.arrive(identity)
            } else {
                try? await context.applyRetainedDemand()
            }
        }
        return context
    }

    func openStream(id: String, barrier: Int?) async throws -> ReconnectMetadataStream {
        try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(metadataStreamId: id, resumeFromStreamSequence: barrier),
            provider: provider, harness: harness)
    }

    func openSubscription() async throws {
        var object = bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
        object["subscription"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fixture.openSnapshot().subscription))
        _ = try await dispatchReconnectControl(
            bridgeProductLifecycleControlRequest(object), dispatcher: dispatcher,
            capabilityHeader: harness.capabilityHeader)
    }

    func acceptInitialScope() async throws {
        let requestData = try JSONEncoder().encode(reconnectFileScopeRequest())
        var object = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        object["scope"] = [
            "kind": "file", "changeFilter": ["kind": "none"], "pathScope": [],
            "interests": [["lane": "foreground", "paths": [fixture.demandedPath]]],
        ]
        _ = try await dispatchReconnectControl(
            bridgeProductLifecycleControlRequest(object), dispatcher: dispatcher,
            capabilityHeader: harness.capabilityHeader)
        try await applyRetainedDemand()
    }

    func applyRetainedDemand() async throws {
        let scope = try #require(await harness.session.acceptedViewScope(subscriptionId: "file-subscription-1"))
        await provider.metadataCoordinator.applyAcceptedFileViewDemand(
            subscriptionId: "file-subscription-1", expectedHandle: scope.handle, expectedRevision: scope.revision,
            forceRecapture: true, productAdmission: harness.productAdmission.context)
    }

    func reconcile(subscription: BridgeProductSubscriptionSnapshot) async throws -> Int {
        let sequence = max(0, await harness.session.producerSnapshot().nextMetadataStreamSequence - 1)
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(subscription: subscription, lastAcceptedStreamSequence: sequence),
            dispatcher: dispatcher, capabilityHeader: harness.capabilityHeader)
        guard case .resyncAccepted(let accepted) = response else {
            throw ReconnectSubscriptionTestError.expectedControlResponse
        }
        #expect(accepted.reconciliation.map(\.dispositionName) == ["retained"])
        return accepted.metadataStreamSequenceBarrier
    }

    func resnapshot(sequence: Int) async throws -> BridgeProductControlResponse {
        let data = try JSONEncoder().encode(reconnectFileResnapshotRequest())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["requestSequence"] = sequence
        object["requestId"] = "resumed-file-resnapshot-\(sequence)"
        return try await dispatchReconnectControl(
            bridgeProductLifecycleControlRequest(object), dispatcher: dispatcher,
            capabilityHeader: harness.capabilityHeader)
    }

    func pump(_ pump: BridgeProductSchemeFramePump, holding held: HeldStep<BridgeProductBatchBeginFrame>?) async throws
    {
        var certificate: BridgeProductBatchBeginFrame?
        var hasHeldCertificate = false
        var descriptorsByBatch: [String: [BridgeProductFileContentDescriptor]] = [:]
        while case .frame(let delivery) = await pump.nextFrame() {
            #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
            for frame in try BridgeProductMetadataFrameDecoder().append(delivery.frame.data) {
                switch frame {
                case .batch(.begin(let begin)):
                    if held != nil && !hasHeldCertificate && begin.mode == .snapshot { certificate = begin }
                case .batch(.part(let part)):
                    if case .put(_, _, .object(let fields)) = part.part,
                        case .string(let path)? = fields["displayKey"], path == fixture.demandedPath,
                        let value = fields["readDescriptor"], value != .null
                    {
                        let descriptor = try JSONDecoder().decode(
                            BridgeProductFileContentDescriptor.self, from: JSONEncoder().encode(value))
                        descriptorsByBatch[part.identity.batchId, default: []].append(descriptor)
                    }
                    if let certificate, let held, part.identity.batchId == certificate.identity.batchId {
                        if part.partIndex == 7 {
                            hasHeldCertificate = true
                            try await held.arrive(certificate)
                            self.sink(
                                "File",
                                .interruptedState(
                                    contextCount: await source.diagnosticSnapshot().subscriptionCount, deferred: false))
                            try await acknowledgeReconnectPart(part, harness: harness)
                        }
                    } else {
                        try await acknowledgeReconnectPart(part, harness: harness)
                    }
                case .batch(.complete(let complete)):
                    for descriptor in descriptorsByBatch.removeValue(forKey: complete.identity.batchId) ?? [] {
                        sink("File", .descriptorDelivered(descriptor))
                    }
                default: break
                }
            }
        }
    }
}
