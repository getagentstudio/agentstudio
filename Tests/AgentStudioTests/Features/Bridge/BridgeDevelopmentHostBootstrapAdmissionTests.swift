import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioCore

/// A successor bootstrap must be usable while an old stream claim retires.
@MainActor
@Suite(
    "Bridge development product host bootstrap admission",
    .serialized,
    .timeLimit(.minutes(1))
)
struct BridgeDevelopmentHostBootstrapAdmissionTests {
    @Test("a live old metadata stream does not block its owning tab's fresh initial bootstrap")
    func liveMetadataStreamPermitsSuccessorBootstrap() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-host-bootstrap-admission-live"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            )
        )
        let bootstrapRequest = try developmentDisplayBootstrapRequest(
            reason: "initial",
            surface: "file"
        )
        let firstWorker = try DevelopmentDisplayWorkerClient(
            host: host,
            delivery: await host.issueBootstrap(for: bootstrapRequest)
        )
        try await firstWorker.openSession()
        var firstMetadataStream = try firstWorker.startMetadataStream()
        try await firstMetadataStream.requireOpeningFrame()

        // Act — the old stream task still holds its physical claim.
        let secondDelivery = try await host.issueBootstrap(for: bootstrapRequest)
        let secondWorker = try DevelopmentDisplayWorkerClient(host: host, delivery: secondDelivery)
        try await secondWorker.openSession()

        #expect(secondWorker.workerInstanceId != firstWorker.workerInstanceId)
        #expect(secondWorker.paneSessionId == firstWorker.paneSessionId)

        await firstMetadataStream.stop()
    }

    @Test("another tab receives a conflict until the owner's stream ends, then takes over")
    func competingTabCannotTakeOverLiveOwner() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-host-tab-ownership"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            )
        )
        let ownerRequest = try developmentDisplayBootstrapRequest(
            reason: "initial", surface: "file", tabId: "owner-tab-1"
        )
        let competingRequest = try developmentDisplayBootstrapRequest(
            reason: "initial", surface: "file", tabId: "other-tab-2"
        )
        let firstWorker = try DevelopmentDisplayWorkerClient(
            host: host,
            delivery: await host.issueBootstrap(for: ownerRequest)
        )
        await #expect(throws: BridgeDevelopmentProductHostError.sessionAlreadyOpen) {
            _ = try await host.issueBootstrap(for: competingRequest)
        }
        try await firstWorker.openSession()
        var firstMetadataStream = try firstWorker.startMetadataStream()
        try await firstMetadataStream.requireOpeningFrame()

        await #expect(throws: BridgeDevelopmentProductHostError.sessionAlreadyOpen) {
            _ = try await host.issueBootstrap(for: competingRequest)
        }
        await firstMetadataStream.stop()
        let takeover = try await host.issueBootstrap(for: competingRequest)
        let nextWorker = try DevelopmentDisplayWorkerClient(host: host, delivery: takeover)
        try await nextWorker.openSession()
        #expect(nextWorker.workerInstanceId != firstWorker.workerInstanceId)
    }

    @Test("a terminated old stream's pending retirement does not block a successor")
    func terminatedStreamPendingRetirementDoesNotBlockSuccessor() async throws {
        // Arrange — the census observer holds the reply task's cancellation at
        // exactly the point where the stream is recorded terminated and its
        // retirement has not been written. Without the fix the bootstrap gate
        // sees "a lease with no retirement" and refuses.
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-host-bootstrap-admission-join"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let terminationHold = BridgeSchemeTaskTerminationHold()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { repositoryPath, gitReadContext in
                BridgeReviewSourceProviderFactory.gitProvider(
                    repositoryPath: repositoryPath,
                    gitReadContext: gitReadContext,
                    statusPhysicalGate: AgentStudioGitStatusPhysicalGate()
                )
            },
            schemeTaskCensus: BridgeProductSchemeTaskCensus { _ in
                await terminationHold.holdUntilReleased()
            }
        )
        let bootstrapRequest = try developmentDisplayBootstrapRequest(
            reason: "initial",
            surface: "file"
        )
        let firstDelivery = try await host.issueBootstrap(for: bootstrapRequest)
        let firstWorker = try DevelopmentDisplayWorkerClient(host: host, delivery: firstDelivery)
        try await firstWorker.openSession()
        var firstMetadataStream = try firstWorker.startMetadataStream()
        try await firstMetadataStream.requireOpeningFrame()

        // Act — stop the stream, then wait for the hold to be ENTERED. At that
        // instant the census says terminated and no retirement is recorded.
        await firstMetadataStream.stop()
        await terminationHold.waitUntilEntered()

        let bootstrap = Task { try await host.issueBootstrap(for: bootstrapRequest) }
        let bootstrapDelivery = try await bootstrap.value
        let secondWorker = try DevelopmentDisplayWorkerClient(
            host: host,
            delivery: bootstrapDelivery
        )
        try await secondWorker.openSession()
        #expect(secondWorker.paneSessionId == firstWorker.paneSessionId)
        #expect(secondWorker.workerInstanceId != firstWorker.workerInstanceId)
        await terminationHold.release()
    }
}

/// Holds a scheme task's cancellation open so a test can observe the window
/// between "stream terminated" and "retirement recorded". Event-driven on both
/// sides: no sleeping, no polling.
private actor BridgeSchemeTaskTerminationHold {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdUntilReleased() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
