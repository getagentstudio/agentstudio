import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge metadata native application registry")
struct BridgeMetadataNativeApplicationRegistryTests {
    @Test("one bound fixture registration owns schema open cancel and active close lifecycle")
    func boundFixtureRegistrationOwnsNativeLifecycle() async throws {
        let registration = AnyBridgeProductMetadataApplicationProtocol(FixtureLifecycleApplication.self)
        let (events, continuation) = AsyncStream<String>.makeStream()
        var iterator = events.makeAsyncIterator()
        let adapter = BridgePaneProductMetadataNativeAdapter(
            open: { _, subscription, _, _, _, _, _ in
                continuation.yield("open:\(subscription.subscriptionId)")
            },
            cancel: { _, subscriptionId in
                continuation.yield("cancel:\(subscriptionId)")
            }
        )
        let nativeRegistry = try BridgePaneProductMetadataNativeApplicationRegistry(
            applications: [.init(registration: registration, adapter: adapter)]
        )
        #expect(
            try nativeRegistry.schemaRegistry.registration(for: registration.kind).kind
                == registration.kind
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            nativeApplicationRegistry: nativeRegistry
        )
        await coordinator.install(
            request: try coordinatorMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let request = try BridgeProductSubscriptionRequest.registered(
            registration: registration,
            options: FixtureLifecycleApplication.SubscriptionOptions()
        )
        let explicitlyCancelledSnapshot = BridgeProductSubscriptionSnapshot(
            subscription: request,
            subscriptionId: "fixture-explicit-cancel",
            subscriptionKind: registration.kind,
            workerDerivationEpoch: 0
        )
        await coordinator.apply(
            .subscriptionOpened(explicitlyCancelledSnapshot),
            productAdmission: harness.productAdmission.context
        )
        #expect(await iterator.next() == "open:fixture-explicit-cancel")
        await coordinator.apply(
            .subscriptionCancelled(explicitlyCancelledSnapshot),
            productAdmission: harness.productAdmission.context
        )
        #expect(await iterator.next() == "cancel:fixture-explicit-cancel")

        let closeDrainedSnapshot = replacingSubscriptionId(
            of: explicitlyCancelledSnapshot,
            with: "fixture-close-drain"
        )
        await coordinator.apply(
            .subscriptionOpened(closeDrainedSnapshot),
            productAdmission: harness.productAdmission.context
        )
        #expect(await iterator.next() == "open:fixture-close-drain")
        await coordinator.closeAndDrain()
        #expect(await iterator.next() == "cancel:fixture-close-drain")
        #expect(!(await coordinator.hasActiveStream))
        continuation.finish()
    }
}

private func replacingSubscriptionId(
    of snapshot: BridgeProductSubscriptionSnapshot,
    with subscriptionId: String
) -> BridgeProductSubscriptionSnapshot {
    BridgeProductSubscriptionSnapshot(
        subscription: snapshot.subscription,
        subscriptionId: subscriptionId,
        subscriptionKind: snapshot.subscriptionKind,
        workerDerivationEpoch: snapshot.workerDerivationEpoch
    )
}

private enum FixtureLifecycleApplication: BridgeProductMetadataApplicationProtocol {
    struct SubscriptionOptions: Codable, Equatable, Sendable {}

    static let kind = try! BridgeProductSubscriptionKind("fixture.lifecycle")
    static let surface = BridgeProductSurface.file
    static let telemetryDescriptor = BridgeMetadataApplicationTelemetryDescriptor(
        applicationName: "fixture-lifecycle"
    )
}
