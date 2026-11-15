import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// The hold is proven against the production scanner and real Git: a linked worktree
/// created under a hold must not publish from any scan, and must publish from the
/// first scan after release.
@Suite("Watched-folder publication hold")
struct WatchedFolderPublicationHoldIntegrationTests {
    @Test("a held linked worktree stays unpublished until the hold is released and the folder rescanned")
    func heldLinkedWorktreePublishesOnlyAfterRelease() async throws {
        // Arrange
        let fixture = try await PublicationHoldFixture.make()
        defer { fixture.remove() }
        let filesystem = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: ControllableFSEventStreamClient(),
            watchedFolderScanScheduler: .production(deadlineScheduler: InertPublicationHoldDiscoveryDeadline())
        )
        let watchedPath = WatchedPath(path: fixture.watchedRoot)
        let initialSummary = await filesystem.refreshWatchedFolders([watchedPath])
        #expect(
            initialSummary.repoPaths(in: fixture.watchedRoot).map(canonicalPath)
                == [canonicalPath(fixture.repositoryPath)])

        let holdID = await filesystem.holdWatchedFolderPublication(of: fixture.destination)
        try await FilesystemTestGitRepo.runGit(
            at: fixture.repositoryPath,
            args: ["worktree", "add", "-b", "feature/held", fixture.destination.path]
        )

        // Act
        let heldSummary = await filesystem.refreshWatchedFolders([watchedPath])
        let heldReceipts = await filesystem.currentWatchedFolderObservationReceipts()
        await filesystem.releaseWatchedFolderPublicationHold(holdID)
        let releasedSummary = await filesystem.refreshWatchedFolders([watchedPath])

        // Assert
        #expect(!linkedWorktreePaths(heldSummary, fixture: fixture).contains(canonicalPath(fixture.destination)))
        #expect(
            heldReceipts.flatMap(\.observation.entries).allSatisfy {
                canonicalPath($0.path) != canonicalPath(fixture.destination)
            })
        #expect(linkedWorktreePaths(releasedSummary, fixture: fixture) == [canonicalPath(fixture.destination)])

        await filesystem.shutdown()
    }

    @Test("directory churn inside a held destination admits no scan until the hold is released")
    func heldDestinationChurnAdmitsNoScan() async throws {
        // Arrange
        let fixture = try await PublicationHoldFixture.make()
        defer { fixture.remove() }
        let probe = try WatchedFolderScanPacingProbe()
        let origin = probe.clock.now
        let submissions = WatchedFolderScanSubmissionLog()
        let filesystem = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: ControllableFSEventStreamClient(),
            watchedFolderScanScheduler: .production(deadlineScheduler: InertPublicationHoldDiscoveryDeadline()),
            watchedFolderScanSubmission: .init { scheduler, request, intent in
                submissions.record(request, at: origin.duration(to: probe.clock.now))
                return await scheduler.submit(request, intent: intent)
            }, sleepClock: probe.clock
        )
        let watchedPath = WatchedPath(path: fixture.watchedRoot)
        _ = await filesystem.refreshWatchedFolders([watchedPath])
        let sourceID = FilesystemSourceID(kind: .watchedParentMembership, rootID: watchedPath.id)
        let routingID = try #require(
            await filesystem.watchedFolderScanState.registrationsBySourceID[sourceID]?.legacyCallbackRoutingID)
        let materializingDirectory = fixture.destination.appending(path: "Sources/Generated")
        try FileManager.default.createDirectory(at: materializingDirectory, withIntermediateDirectories: true)
        let churn = FSEventBatch(
            worktreeId: routingID,
            paths: [materializingDirectory.path],
            observations: [
                .init(
                    path: materializingDirectory.path, eventID: 1,
                    flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated))
            ]
        )
        let holdID = await filesystem.holdWatchedFolderPublication(of: fixture.destination)
        let coverageBeforeHeldChurn = await filesystem.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]

        // Act
        await filesystem.handleWatchedFolderFSEvent(churn)
        let coverageAfterHeldChurn = await filesystem.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
        await filesystem.releaseWatchedFolderPublicationHold(holdID)
        await filesystem.handleWatchedFolderFSEvent(churn)
        let coverageAfterReleasedChurn = await filesystem.watchedFolderScanState.latestDemandCoverageBySourceID[
            sourceID]

        // Assert
        #expect(coverageBeforeHeldChurn != nil)
        #expect(coverageAfterHeldChurn == coverageBeforeHeldChurn)
        #expect(coverageAfterReleasedChurn != coverageBeforeHeldChurn)
        #expect(coverageAfterReleasedChurn == nil)
        #expect(!submissions.entries.contains { $0.request.cause == .callback })
        do {
            let producer = try #require(await filesystem.watchedFolderScanState.pacingDeadlineTask)
            let deadline = try await probe.nextSleep(producedBy: producer)
            probe.clock.advance(to: deadline)
            await producer.value
            let callbacks = submissions.entries.filter { $0.request.cause == .callback }
            #expect(callbacks.count == 1)
            #expect(callbacks.first?.submittedAt == .seconds(2))
            #expect(
                await filesystem.watchedFolderScanState.latestDemandCoverageBySourceID[sourceID]
                    != coverageBeforeHeldChurn)
        } catch {
            await filesystem.shutdown()
            try? await probe.finish()
            throw error
        }

        await filesystem.shutdown()
        try await probe.finish()
    }

    private func linkedWorktreePaths(_ summary: WatchedFolderRefreshSummary, fixture: PublicationHoldFixture)
        -> [String]
    {
        summary.linkedWorktreePaths(in: fixture.watchedRoot).map(canonicalPath)
    }
}

/// The production scanner and real Git discovery, minus the production discovery
/// deadline: a wall-clock validation deadline would let machine load decide whether the
/// fixture repository is admitted, so the deadline never fires here and the lane's hang
/// bound is the only elapsed-time bound.
private struct InertPublicationHoldDiscoveryDeadline: RepoDiscoveryDeadlineScheduler {
    func scheduleDeadline(
        after duration: Duration,
        _ handler: @escaping @Sendable () -> Void
    ) -> RepoDiscoveryScheduledDeadline {
        RepoDiscoveryScheduledDeadline(cancel: {})
    }
}

/// Canonical path text; URL equality would also compare a trailing slash that
/// `URL(fileURLWithPath:)` adds only once the directory exists.
private func canonicalPath(_ url: URL) -> String {
    FilesystemRootOwnership.canonicalizeKernelPath(url.standardizedFileURL.path)
}

private struct PublicationHoldFixture {
    let watchedRoot: URL
    let repositoryPath: URL
    let destination: URL

    static func make() async throws -> Self {
        let watchedRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "tmp/worktree-publication-hold-tests/\(UUIDv7.generate().uuidString)")
            .standardizedFileURL
        let repositoryPath = watchedRoot.appending(path: "repo")
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        for args in [
            ["init"], ["symbolic-ref", "HEAD", "refs/heads/main"],
            ["config", "user.email", "luna-tests@example.com"], ["config", "user.name", "Luna Tests"],
            ["config", "commit.gpgsign", "false"], ["commit", "--allow-empty", "-m", "Initial commit"],
        ] {
            try await FilesystemTestGitRepo.runGit(at: repositoryPath, args: args)
        }
        return Self(
            watchedRoot: watchedRoot,
            repositoryPath: repositoryPath,
            destination: watchedRoot.appending(path: "repo.feature-held")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: watchedRoot)
    }
}
