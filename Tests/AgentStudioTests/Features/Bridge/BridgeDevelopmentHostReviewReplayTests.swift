import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioCore

@MainActor
@Suite(
    "Bridge development product host Review replay integration",
    .serialized,
    .timeLimit(.minutes(1))
)
struct BridgeDevelopmentHostReviewReplayTests {
    @Test("fresh File bootstrap replays every certified Review batch part with returned credits")
    func freshFileBootstrapReplaysEveryCertifiedReviewBatchPart() async throws {
        // Arrange
        let expectedItemCount = 1699
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-product-host-review-replay"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let provider = makeReviewReplayProvider(itemCount: expectedItemCount)
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: repositoryURL),
            operationDeadlineClock: TestPushClock(),
            contributionTargetCommit: developmentContributionTargetCommit(
                worktreeRoot: repositoryURL
            ),
            makeReviewProvider: { _, _ in provider }
        )
        var activeMetadataStream: DevelopmentDisplayMetadataStream?
        var replayStage = "first worker bootstrap"

        do {
            let bootstrapRequest = try developmentDisplayBootstrapRequest(
                reason: "initial",
                surface: "file"
            )
            let firstWorker = try DevelopmentDisplayWorkerClient(
                host: host,
                delivery: await host.issueBootstrap(for: bootstrapRequest)
            )
            replayStage = "first worker session open"
            try await firstWorker.openSession()
            replayStage = "first metadata stream opening"
            var firstMetadataStream = try firstWorker.startMetadataStream()
            activeMetadataStream = firstMetadataStream
            try await firstMetadataStream.requireOpeningFrame()
            replayStage = "first Review mode and scope"
            try await firstWorker.activateReviewViewerMode()
            try await firstWorker.openReviewMetadataSubscription(itemIDs: [])
            replayStage = "first Review batch replay"
            let firstReplay = try await firstMetadataStream.consumeCompleteReviewPublication(
                expectedItemCount: expectedItemCount,
                using: firstWorker
            )
            let retainedPublication = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(retainedPublication.package.orderedItemIds.count == expectedItemCount)
            #expect(firstReplay.identity.publicationId == retainedPublication.publicationId)
            #expect(firstReplay.partCount == expectedItemCount + 1)
            #expect(firstReplay.partCount > AppPolicies.Bridge.productViewCreditParts)
            try await admitAndApplyReviewPublication(retainedPublication.publicationId, using: firstWorker)

            // Act — ending the first document's real stream lets a fresh initial File bootstrap
            // retire that worker before the successor asks for the retained Review publication.
            await firstMetadataStream.stop()
            activeMetadataStream = nil
            let secondWorker = try DevelopmentDisplayWorkerClient(
                host: host,
                delivery: await host.issueBootstrap(for: bootstrapRequest)
            )
            replayStage = "second worker session open"
            try await secondWorker.openSession()
            replayStage = "second metadata stream opening"
            var secondMetadataStream = try secondWorker.startMetadataStream()
            activeMetadataStream = secondMetadataStream
            try await secondMetadataStream.requireOpeningFrame()
            replayStage = "second Review mode and scope"
            try await secondWorker.activateReviewViewerMode()
            try await secondWorker.openReviewMetadataSubscription(
                itemIDs: retainedPublication.package.orderedItemIds
            )
            replayStage = "second Review batch replay"
            let secondReplay = try await secondMetadataStream.consumeCompleteReviewPublication(
                expectedItemCount: expectedItemCount,
                using: secondWorker
            )
            try await admitAndApplyReviewPublication(retainedPublication.publicationId, using: secondWorker)

            await assertReviewReplaySurvivesWorkerReplacement(
                host: host,
                workers: (first: firstWorker, second: secondWorker),
                replays: (first: firstReplay, second: secondReplay),
                retainedPublication: retainedPublication,
                expectedItemCount: expectedItemCount
            )

            await secondMetadataStream.stop()
            activeMetadataStream = nil
            await host.shutdown()
        } catch {
            await activeMetadataStream?.stop()
            await host.shutdown()
            Issue.record("Review replay failed during \(replayStage): \(error)")
        }
    }
}

@MainActor
private func admitAndApplyReviewPublication(
    _ publicationID: UUID,
    using worker: DevelopmentDisplayWorkerClient
) async throws {
    #expect(
        try await worker.admitReviewPublication(
            candidatePublicationId: publicationID,
            expectedDisplayedPublicationId: nil,
            workerDerivationEpoch: 1
        )
    )
    try await worker.applyReviewPublication(publicationID, workerDerivationEpoch: 1)
}

@MainActor
private func assertReviewReplaySurvivesWorkerReplacement(
    host: BridgeDevelopmentProductHost,
    workers: (first: DevelopmentDisplayWorkerClient, second: DevelopmentDisplayWorkerClient),
    replays: (first: DevelopmentDisplayReviewReplayObservation, second: DevelopmentDisplayReviewReplayObservation),
    retainedPublication: BridgeReviewCommittedPublication,
    expectedItemCount: Int
) async {
    #expect(workers.second.paneSessionId == workers.first.paneSessionId)
    #expect(workers.second.workerInstanceId != workers.first.workerInstanceId)
    #expect(replays.second.identity.publicationId == replays.first.identity.publicationId)
    #expect(replays.second.identity.displayed == replays.first.identity.displayed)
    #expect(replays.second.identity.desired == replays.first.identity.desired)
    #expect(replays.second.identity.revision > 0)
    #expect(replays.second.itemCount == expectedItemCount)
    #expect(replays.second.partCount == replays.first.partCount)
    #expect(
        await host.diagnosticCommittedReviewPublication()?.publicationId
            == retainedPublication.publicationId
    )
    let coordinator = await host.reviewPublicationCoordinator
    #expect(
        coordinator.diagnosticSnapshot.acknowledgedDisplayed?.publicationId
            == retainedPublication.publicationId
    )
}

@MainActor
private func makeReviewReplayProvider(itemCount: Int) -> BridgeDevelopmentSharedConstructionReviewProvider {
    BridgeDevelopmentSharedConstructionReviewProvider(
        changedFiles: (0..<itemCount).map { itemIndex in
            makeBridgeEndpointChangedFile(
                fileId: String(format: "review-replay-%05d", itemIndex),
                path: String(
                    format: "Sources/Module%02d/File%05d.swift",
                    itemIndex % 32,
                    itemIndex
                ),
                sizeBytes: 100
            )
        }
    )
}
