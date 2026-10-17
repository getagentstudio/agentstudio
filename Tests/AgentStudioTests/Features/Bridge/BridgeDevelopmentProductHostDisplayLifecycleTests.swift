import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioCore

@MainActor
@Suite("Bridge development product host display lifecycle")
struct BridgeDevelopmentProductHostDisplayLifecycleTests {
    @Test("File bootstrap Review activation constructs the initial Review publication")
    func fileBootstrapReviewActivationConstructsInitialReviewPublication() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-product-host-file-to-review"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let commitObserver = ReviewPublicationCommitObserver()
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in BridgeObservabilitySmokeReviewSourceProvider() },
            didCommitReviewPublication: { [commitObserver] in
                commitObserver.recordCommit()
            }
        )

        try await withMainActorShutdownDevelopmentProductHost(host) {
            let bootstrapRequest = try developmentDisplayBootstrapRequest(
                reason: "initial",
                surface: "file"
            )
            let worker = try DevelopmentDisplayWorkerClient(
                host: host,
                delivery: await host.issueBootstrap(for: bootstrapRequest)
            )
            try await worker.openSession()
            #expect(await host.diagnosticCommittedReviewPublication() == nil)

            // Act
            try await worker.activateReviewViewerMode()

            // Assert — await the coordinator's own commit, then still read the host once,
            // so the host's diagnostic read path stays proved rather than assumed.
            await commitObserver.waitForFirstCommit()
            #expect(await host.diagnosticCommittedReviewPublication() != nil)
        }
    }

    @Test("fresh and replacement workers preserve bounded Review display installation")
    func freshAndReplacementWorkersPreserveBoundedReviewDisplayInstallation() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-product-host-display-lifecycle"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in BridgeObservabilitySmokeReviewSourceProvider() }
        )

        try await withMainActorShutdownDevelopmentProductHost(host) {
            let established = try await establishInitialAndFreshDocumentDisplay(in: host)
            let successor = try await establishReplacementWorkerAndAdmitB(
                established: established,
                host: host
            )
            try await commitAndApplyC(established: established, host: host, successor: successor)
        }
    }
}

/// Observes `BridgeReviewPublicationCoordinator.commit()`, the one moment the coordinator
/// publishes that a Review publication exists. Installed before the action that triggers
/// the commit, so there is no lost-wakeup window and nothing to poll.
@MainActor
private final class ReviewPublicationCommitObserver {
    private var commitCount = 0
    private var firstCommitWaiters: [CheckedContinuation<Void, Never>] = []

    func recordCommit() {
        commitCount += 1
        let waiters = firstCommitWaiters
        firstCommitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Returns at once if a commit already happened, so a late waiter is never stranded.
    func waitForFirstCommit() async {
        if commitCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            firstCommitWaiters.append(continuation)
        }
    }
}

@MainActor
private func establishInitialAndFreshDocumentDisplay(
    in host: BridgeDevelopmentProductHost
) async throws -> DevelopmentDisplayEstablishedContext {
    let initialBootstrapRequest = try developmentDisplayBootstrapRequest(reason: "initial")
    let workerOne = try DevelopmentDisplayWorkerClient(
        host: host,
        delivery: await host.issueBootstrap(for: initialBootstrapRequest)
    )
    try await workerOne.openSession()
    let publicationA = try #require(await host.diagnosticCommittedReviewPublication())
    let coordinator = await host.reviewPublicationCoordinator

    #expect(
        try await workerOne.admitReviewPublication(
            candidatePublicationId: publicationA.publicationId,
            expectedDisplayedPublicationId: nil
        )
    )
    try await workerOne.applyReviewPublication(publicationA.publicationId)
    #expect(coordinator.diagnosticSnapshot.acknowledgedDisplayed?.publicationId == publicationA.publicationId)
    #expect(coordinator.diagnosticSnapshot.admitted == nil)

    let workerTwo = try DevelopmentDisplayWorkerClient(
        host: host,
        delivery: await host.issueBootstrap(for: initialBootstrapRequest)
    )
    try await workerTwo.openSession()
    #expect(workerTwo.paneSessionId == workerOne.paneSessionId)
    #expect(workerTwo.workerInstanceId != workerOne.workerInstanceId)
    #expect(
        try await workerTwo.admitReviewPublication(
            candidatePublicationId: publicationA.publicationId,
            expectedDisplayedPublicationId: nil
        )
    )
    try await workerTwo.applyReviewPublication(publicationA.publicationId)
    #expect(coordinator.diagnosticSnapshot.acknowledgedDisplayed?.publicationId == publicationA.publicationId)
    #expect(coordinator.diagnosticSnapshot.admitted == nil)
    return DevelopmentDisplayEstablishedContext(
        coordinator: coordinator,
        publicationA: publicationA,
        workerTwo: workerTwo
    )
}

@MainActor
private func establishReplacementWorkerAndAdmitB(
    established: DevelopmentDisplayEstablishedContext,
    host: BridgeDevelopmentProductHost
) async throws -> DevelopmentDisplaySuccessorContext {
    let replacementBootstrapRequest = try developmentDisplayBootstrapRequest(
        paneSessionId: established.workerTwo.paneSessionId,
        reason: "workerReplacement"
    )
    let workerThree = try DevelopmentDisplayWorkerClient(
        host: host,
        delivery: await host.issueBootstrap(for: replacementBootstrapRequest)
    )
    try await workerThree.openSession()
    #expect(workerThree.paneSessionId == established.workerTwo.paneSessionId)
    #expect(workerThree.workerInstanceId != established.workerTwo.workerInstanceId)
    try await workerThree.applyReviewPublication(established.publicationA.publicationId)

    let preparedB = try await makeReviewPreparedPublication(
        suffix: "development-display-b",
        reviewGeneration: 2
    )
    let publicationB = try commitObserved(
        preparedB,
        in: established.coordinator,
        productAdmission: await host.productAdmission
    )
    #expect(
        !(try await workerThree.admitReviewPublication(
            candidatePublicationId: publicationB.publicationId,
            expectedDisplayedPublicationId: nil
        ))
    )
    #expect(
        try await workerThree.admitReviewPublication(
            candidatePublicationId: publicationB.publicationId,
            expectedDisplayedPublicationId: established.publicationA.publicationId
        )
    )
    return DevelopmentDisplaySuccessorContext(publicationB: publicationB, workerThree: workerThree)
}

@MainActor
private func commitAndApplyC(
    established: DevelopmentDisplayEstablishedContext,
    host: BridgeDevelopmentProductHost,
    successor: DevelopmentDisplaySuccessorContext
) async throws {
    let preparedC = try await makeReviewPreparedPublication(
        suffix: "development-display-c",
        reviewGeneration: 3
    )
    let publicationC = try commitObserved(
        preparedC,
        in: established.coordinator,
        productAdmission: await host.productAdmission
    )
    #expect(
        await host.diagnosticCommittedReviewPublication()?.publicationId
            == publicationC.publicationId
    )

    try await successor.workerThree.applyReviewPublication(successor.publicationB.publicationId)
    #expect(
        established.coordinator.diagnosticSnapshot.acknowledgedDisplayed?.publicationId
            == successor.publicationB.publicationId
    )
    #expect(established.coordinator.diagnosticSnapshot.active?.publicationId == publicationC.publicationId)
    #expect(established.coordinator.diagnosticSnapshot.admitted == nil)
    #expect(
        try await successor.workerThree.admitReviewPublication(
            candidatePublicationId: publicationC.publicationId,
            expectedDisplayedPublicationId: successor.publicationB.publicationId
        )
    )
    try await successor.workerThree.applyReviewPublication(publicationC.publicationId)
    #expect(
        established.coordinator.diagnosticSnapshot.acknowledgedDisplayed?.publicationId
            == publicationC.publicationId
    )
    #expect(established.coordinator.diagnosticSnapshot.active?.publicationId == publicationC.publicationId)
    #expect(established.coordinator.diagnosticSnapshot.admitted == nil)
}

private struct DevelopmentDisplayEstablishedContext {
    let coordinator: BridgeReviewPublicationCoordinator
    let publicationA: BridgeReviewCommittedPublication
    let workerTwo: DevelopmentDisplayWorkerClient
}

private struct DevelopmentDisplaySuccessorContext {
    let publicationB: BridgeReviewCommittedPublication
    let workerThree: DevelopmentDisplayWorkerClient
}
