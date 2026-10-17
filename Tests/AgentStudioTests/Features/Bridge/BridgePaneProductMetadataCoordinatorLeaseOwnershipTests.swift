import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product metadata coordinator lease ownership")
struct BridgeMetadataCoordinatorLeaseTests {
    @Test("stale uninstall cannot clear a replacement metadata stream")
    func staleUninstallCannotClearReplacementMetadataStream() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let firstHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let firstLease = try await firstHarness.admitMetadataFrames(through: 0)
        let replacementHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let replacementLease = try await replacementHarness.admitMetadataFrames(through: 0)
        let fileMetadataSource = LeaseOwnershipGatedFileMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try leaseOwnershipMetadataStreamRequest(streamId: "metadata-stream-first"),
            lease: firstLease,
            productAdmission: firstHarness.productAdmission.context,
            session: firstHarness.session
        )
        await coordinator.apply(
            .subscriptionOpened(try leaseOwnershipFileSubscriptionSnapshot()),
            productAdmission: firstHarness.productAdmission.context
        )

        let staleUninstall = Task {
            await coordinator.uninstall(lease: firstLease)
        }
        await fileMetadataSource.waitUntilCancellationStarted()

        // Act
        let replacementInstall = Task {
            await coordinator.install(
                request: try leaseOwnershipMetadataStreamRequest(streamId: "metadata-stream-replacement"),
                lease: replacementLease,
                productAdmission: replacementHarness.productAdmission.context,
                session: replacementHarness.session
            )
        }
        await fileMetadataSource.releaseCancellation()
        await staleUninstall.value
        try await replacementInstall.value

        // Assert
        #expect(await coordinator.hasActiveStream)
        try await firstHarness.closeProducer(firstLease)
        try await replacementHarness.closeProducer(replacementLease)
    }
}

private actor LeaseOwnershipGatedFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private var cancellationRelease: CheckedContinuation<Void, Never>?
    private var cancellationStarted = false
    private var cancellationStartedWaiters: [CheckedContinuation<Void, Never>] = []

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId _: String) async {
        cancellationStarted = true
        let waiters = cancellationStartedWaiters
        cancellationStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            cancellationRelease = continuation
        }
    }

    func publish(
        status _: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] { [] }

    func publish(
        changeset _: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] { [] }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }

    func waitUntilCancellationStarted() async {
        guard !cancellationStarted else { return }
        await withCheckedContinuation { continuation in
            cancellationStartedWaiters.append(continuation)
        }
    }

    func releaseCancellation() {
        cancellationRelease?.resume()
        cancellationRelease = nil
    }
}

private enum LeaseOwnershipCoordinatorTestError: Error {
    case invalidFileSubscription
}

private func leaseOwnershipFileSubscriptionSnapshot() throws -> BridgeProductSubscriptionSnapshot {
    let request = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    guard case .subscriptionOpen(let openRequest) = request else {
        throw LeaseOwnershipCoordinatorTestError.invalidFileSubscription
    }
    var state = BridgeProductSubscriptionState()
    _ = try state.open(openRequest)
    guard let snapshot = state.snapshot(subscriptionId: openRequest.subscriptionId) else {
        throw LeaseOwnershipCoordinatorTestError.invalidFileSubscription
    }
    return snapshot
}

private func leaseOwnershipMetadataStreamRequest(
    streamId: String
) throws -> BridgeProductMetadataStreamRequest {
    let data = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": streamId,
            "paneSessionId": "pane-session-1",
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ],
        options: [.sortedKeys]
    )
    return try BridgeProductStrictJSON.decode(BridgeProductMetadataStreamRequest.self, from: data)
}
