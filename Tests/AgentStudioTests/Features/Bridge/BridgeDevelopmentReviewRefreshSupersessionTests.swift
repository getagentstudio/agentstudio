import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Testing

@testable import AgentStudioBridge

@Suite("Development Review refresh supersession", .timeLimit(.minutes(1)))
struct BridgeDevelopmentReviewRefreshSupersessionTests {
    @Test("cancelled unreserved failure cannot overwrite a pending Review attempt")
    func cancelledUnreservedFailureCannotOverwritePendingReviewAttempt() async throws {
        // Arrange — the current generation is pending before stale unreserved work finishes.
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "development-review-cancelled-unreserved-failure"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in BridgeDevelopmentSharedConstructionReviewProvider() }
        )

        try await withShutdownDevelopmentProductHost(host) {
            let reviewGeneration = await host.nextReviewGeneration
            let refreshAdmissionCoordinator = await host.refreshAdmissionCoordinator
            await MainActor.run {
                refreshAdmissionCoordinator.beginReviewComparisonAttempt(
                    activeTarget: .ref(name: "HEAD"),
                    reviewGeneration: reviewGeneration.rawValue
                )
            }
            #expect(
                await host.diagnosticPanePresentation().reviewComparison?.attempt
                    == .pending(reviewGeneration: reviewGeneration.rawValue)
            )

            // Act — reproduce stale unreserved preparation failure with cancellation already set.
            let cancelledFailure = Task {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return await host.failReviewComparisonAttempt(
                    reviewGeneration,
                    failureKind: "publication_failed",
                    refreshReservation: nil
                )
            }
            let didPublishFailure = await cancelledFailure.value

            // Assert — cancelled work cannot publish failure over the current pending generation.
            #expect(!didPublishFailure)
            #expect(
                await host.diagnosticPanePresentation().reviewComparison?.attempt
                    == .pending(reviewGeneration: reviewGeneration.rawValue)
            )

            // A current, uncancelled failure must still reach the presentation owner.
            #expect(
                await host.failReviewComparisonAttempt(
                    reviewGeneration,
                    failureKind: "publication_failed",
                    refreshReservation: nil
                )
            )
            #expect(
                await host.diagnosticPanePresentation().reviewComparison?.attempt
                    == .unavailable(failureKind: "publication_failed", retryable: true)
            )
        }
    }

    @Test("cancelled same-lineage refresh cannot fail its pending successor")
    func cancelledSameLineageRefreshCannotFailPendingSuccessor() async throws {
        // Arrange — an installed, nonempty Review takes the same-lineage refresh path.
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "development-review-same-lineage-race")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let provider = BridgeDevelopmentSharedConstructionReviewProvider(
            changedFiles: [
                makeBridgeEndpointChangedFile(
                    fileId: "reviewed-file",
                    path: "tracked.txt",
                    sizeBytes: 100,
                    newContentHash: "sha256:initial"
                )
            ]
        )
        let source = makeDevelopmentProductSource(worktreeRoot: repositoryURL)
        let host = try await BridgeDevelopmentProductHost(
            source: source,
            contributionTargetCommit: developmentContributionTargetCommit(worktreeRoot: repositoryURL),
            makeReviewProvider: { _, _ in provider }
        )
        let predecessorCapture = try ReviewRefreshCaptureProbe(phase: .predecessor)
        let successorCapture = try ReviewRefreshCaptureProbe(phase: .successor)
        var completionObservers: [Task<Void, Never>] = []
        do {
            try await withShutdownDevelopmentProductHost(host) {
                // Release cancellation-ignoring dependencies before the host drains on any exit.
                defer {
                    predecessorCapture.retire()
                    successorCapture.retire()
                }
                _ = try await host.issueBootstrap(for: makeDevelopmentBootstrapRequest(surface: "review"))
                let predecessor = try #require(await host.diagnosticCommittedReviewPublication())
                let installation = await installDevelopmentReviewPredecessor(host: host, publication: predecessor)
                #expect(installation.admission == .admitted)
                #expect(installation.application == .advanced)
                await provider.setChangedFiles([
                    makeBridgeEndpointChangedFile(
                        fileId: "reviewed-file",
                        path: "tracked.txt",
                        sizeBytes: 101,
                        newContentHash: "sha256:successor"
                    )
                ])
                await provider.setContributionCaptureHold { request in
                    try await predecessorCapture.hold(request)
                }

                // Act — finish cancelled work while the newer reservation is still pending.
                await host.handleObservedWorktreeInvalidation(
                    developmentFileInvalidation(source: source, batchSequence: 1)
                )
                let retiredTask = try #require(await host.activeReviewComparisonTask)
                completionObservers.append(predecessorCapture.observeCompletion(of: retiredTask))
                _ = try await predecessorCapture.requireCaptureStarted()
                await provider.setContributionCaptureHold { request in
                    try await successorCapture.hold(request)
                }
                await host.handleObservedWorktreeInvalidation(
                    developmentFileInvalidation(source: source, batchSequence: 2)
                )
                let successorTask = try #require(await host.activeReviewComparisonTask)
                completionObservers.append(successorCapture.observeCompletion(of: successorTask))
                #expect(try await predecessorCapture.requireCancellationObserved())
                _ = try await successorCapture.requireCaptureStarted()
                predecessorCapture.release()
                await retiredTask.value
                #expect(try await predecessorCapture.requireOperationFinished() == .operationFinished)

                // Assert — stale failure cannot mutate current presentation or publication.
                #expect(
                    await host.diagnosticPanePresentation().reviewComparison?.attempt
                        == .pending(reviewGeneration: predecessor.package.reviewGeneration.rawValue)
                )
                #expect(await host.diagnosticCommittedReviewPublication()?.publicationId == predecessor.publicationId)
                let requests = await provider.snapshot()
                #expect(requests.reviewGenerationValues == [1, 1, 1])
                #expect(requests.reviewAttemptAuthorityGenerations.count == 3)
                #expect(requests.reviewAttemptAuthorityGenerations[2] > requests.reviewAttemptAuthorityGenerations[1])

                successorCapture.release()
                await successorTask.value
                #expect(try await successorCapture.requireOperationFinished() == .operationFinished)
                let successor = try #require(await host.diagnosticCommittedReviewPublication())
                #expect(successor.package.reviewGeneration == predecessor.package.reviewGeneration)
                #expect(successor.package.revision == predecessor.package.revision + 1)
                #expect(successor.publicationId != predecessor.publicationId)
                #expect(
                    await host.diagnosticPanePresentation().reviewComparison?.attempt
                        == .settled(reviewGeneration: successor.package.reviewGeneration.rawValue)
                )
                #expect(await host.retiringReviewComparisonTasks.isEmpty)
                #expect(await host.activeReviewComparisonTask == nil)
            }
        } catch {
            for observer in completionObservers { await observer.value }
            try await predecessorCapture.finish()
            try await successorCapture.finish()
            throw error
        }
        for observer in completionObservers { await observer.value }
        try await predecessorCapture.finish()
        try await successorCapture.finish()
    }
}

private struct DevelopmentReviewDisplayInstallationObservation: Sendable {
    let admission: BridgeReviewDisplayInstallAdmissionResult
    let application: BridgeReviewDisplayedApplicationResult
}

private func installDevelopmentReviewPredecessor(
    host: BridgeDevelopmentProductHost,
    publication: BridgeReviewCommittedPublication
) async -> DevelopmentReviewDisplayInstallationObservation {
    let coordinator = await host.reviewPublicationCoordinator
    let productAdmission = await host.productAdmission
    let workerInstanceId = "development-same-lineage-worker"
    let admission = await coordinator.admitDisplayInstallation(
        expectedDisplayedPublicationId: nil,
        candidatePublicationId: publication.publicationId,
        workerInstanceId: workerInstanceId,
        productAdmission: productAdmission
    )
    let application = await coordinator.recordDisplayedApplication(
        publicationId: publication.publicationId,
        workerInstanceId: workerInstanceId,
        productAdmission: productAdmission
    )
    return DevelopmentReviewDisplayInstallationObservation(admission: admission, application: application)
}

private enum ReviewRefreshCapturePhase: String, Sendable {
    case predecessor
    case successor
}

private enum ReviewRefreshCaptureFact: String, Sendable {
    case captureStarted
    case operationFinished
}

/// A capture arrival and the existing host task's completion share one ordered vocabulary.
/// Completion before arrival is a named failure rather than an unfinishable start wait.
private struct ReviewRefreshCaptureProbe: Sendable {
    private let phase: ReviewRefreshCapturePhase
    private let step: HeldStep<BridgeContributionComparisonRequest>
    private let source: LocalFactSource<ReviewRefreshCapturePhase, ReviewRefreshCaptureFact>
    private let recorder: FactRecorder<ReviewRefreshCapturePhase, ReviewRefreshCaptureFact>

    init(phase: ReviewRefreshCapturePhase) throws {
        self.phase = phase
        step = HeldStep("\(phase.rawValue) contribution capture", cancellation: .holdThroughCancellation)
        source = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { "\($0.rawValue) contribution capture" },
                describeFact: { $0.rawValue },
                isClosing: { _, fact in fact == .operationFinished }
            )
        )
        recorder = try source.attach()
    }

    func hold(_ request: BridgeContributionComparisonRequest) async throws {
        source.sink(phase, .captureStarted)
        try await step.arrive(request)
    }

    func observeCompletion(of task: Task<Void, Never>) -> Task<Void, Never> {
        Task {
            await task.value
            source.sink(phase, .operationFinished)
        }
    }

    func requireCaptureStarted() async throws -> BridgeContributionComparisonRequest {
        try await recorder.expectNext(in: phase, .captureStarted)
        return try await step.firstArrival()
    }

    func requireOperationFinished() async throws -> ReviewRefreshCaptureFact {
        try await recorder.expectNext(in: phase, where: { $0 == .operationFinished }, "operationFinished")
    }

    func requireCancellationObserved() async throws -> Bool {
        try await step.cancellationObserved()
        return step.hasObservedCancellation
    }

    func release() { step.release() }
    func retire() { step.retire() }

    func finish() async throws {
        source.end()
        try await recorder.finish()
    }
}
