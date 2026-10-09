import AgentStudioCore
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer

@Suite("Bridge development seeded worktree observation", .serialized)
struct BridgeDevelopmentSeededWorktreeObservationTests {
    @Test("registration failure prevents readiness and leaves no registered worktree")
    func registrationFailurePreventsReadiness() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        fixture.fseventClient.setNextRegistrationOutcome(
            .unavailable(.streamStartFailed)
        )
        let observation = fixture.makeObservation()

        // Act / Assert
        await #expect(
            throws: BridgeDevelopmentSeededWorktreeObservationError.registrationUnavailable(
                .streamStartFailed
            )
        ) {
            try await observation.start()
        }
        #expect(fixture.fseventClient.registeredWorktreeIds.isEmpty)
        #expect(await fixture.bus.subscriberCount == 0)
        await observation.shutdown()
    }

    @Test("production filesystem and Git actors route exact seeded-worktree invalidations")
    func productionActorsRouteExactSeededWorktreeInvalidations() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let observation = fixture.makeObservation()
        try await observation.start()

        // Act
        fixture.fseventClient.send(
            FSEventBatch(
                worktreeId: fixture.source.worktreeID,
                paths: [fixture.source.worktreeRoot.appending(path: "Sources/App.swift").path]
            )
        )
        #expect(await fixture.probe.waitForFileChangesetCount(1))
        #expect(await fixture.probe.waitForStatusCount(1))

        // Assert
        let changeset = try #require(await fixture.probe.fileChangesets.last)
        #expect(changeset.repoId == fixture.source.repoID)
        #expect(changeset.worktreeId == fixture.source.worktreeID)
        #expect(changeset.rootPath == fixture.source.worktreeRoot)
        #expect(changeset.paths == ["Sources/App.swift"])
        let status = try #require(await fixture.probe.statuses.last)
        #expect(status.branch == "feature/observation-proof")
        await observation.shutdown()
        #expect(fixture.fseventClient.unregisteredWorktreeIds == [fixture.source.worktreeID])
        #expect(await fixture.bus.subscriberCount == 0)
    }

    @Test("router rejects unrelated repo worktree and root facts")
    func routerRejectsUnrelatedFacts() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let observation = fixture.makeObservation()
        try await observation.start()
        #expect(await fixture.probe.waitForStatusCount(1))
        let initialFileCount = await fixture.probe.fileChangesets.count
        let initialStatusCount = await fixture.probe.statuses.count

        // Act
        await fixture.bus.post(
            .worktree(
                WorktreeEnvelope(
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: 90,
                    timestamp: .now,
                    repoId: fixture.source.repoID,
                    worktreeId: fixture.source.worktreeID,
                    event: .filesystem(
                        .filesChanged(
                            changeset: FileChangeset(
                                worktreeId: fixture.source.worktreeID,
                                repoId: fixture.source.repoID,
                                rootPath: fixture.source.worktreeRoot.appending(path: "foreign"),
                                paths: ["Sources/Foreign.swift"],
                                timestamp: .now,
                                batchSeq: 90
                            )
                        )
                    )
                )
            )
        )
        await fixture.bus.post(
            .worktree(
                WorktreeEnvelope(
                    source: .system(.builtin(.gitWorkingDirectoryProjector)),
                    seq: 91,
                    timestamp: .now,
                    repoId: fixture.source.repoID,
                    worktreeId: fixture.source.worktreeID,
                    event: .gitWorkingDirectory(
                        .snapshotChanged(
                            snapshot: GitWorkingTreeSnapshot(
                                worktreeId: fixture.source.worktreeID,
                                repoId: fixture.source.repoID,
                                rootPath: fixture.source.worktreeRoot.appending(path: "foreign"),
                                summary: GitWorkingTreeSummary(
                                    changed: 0,
                                    staged: 0,
                                    untracked: 0
                                ),
                                branch: "foreign"
                            )
                        )
                    )
                )
            )
        )
        for _ in 0..<200 {
            await Task.yield()
        }

        // Assert
        #expect(await fixture.probe.fileChangesets.count == initialFileCount)
        #expect(await fixture.probe.statuses.count == initialStatusCount)
        await observation.shutdown()
    }

    @Test("detected filesystem ingress completion stops fact admission")
    func detectedFilesystemIngressCompletionStopsFactAdmission() async throws {
        // Arrange
        let fixture = try BridgeDevelopmentObservationFixture.make()
        defer { fixture.removeRoot() }
        let observation = fixture.makeObservation()
        let terminalProbe = BridgeDevelopmentObservationTerminalProbe()
        try await observation.start { terminal in
            await terminalProbe.record(terminal)
        }
        #expect(await fixture.probe.waitForStatusCount(1))
        let initialFileCount = await fixture.probe.fileChangesets.count

        // Act
        fixture.fseventClient.shutdown()
        #expect(await fixture.waitForUnregisteredWorktreeCount(1))
        #expect(await terminalProbe.waitForTerminalCount(1))
        await fixture.bus.post(
            .worktree(
                WorktreeEnvelope(
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: 92,
                    timestamp: .now,
                    repoId: fixture.source.repoID,
                    worktreeId: fixture.source.worktreeID,
                    event: .filesystem(
                        .filesChanged(
                            changeset: FileChangeset(
                                worktreeId: fixture.source.worktreeID,
                                repoId: fixture.source.repoID,
                                rootPath: fixture.source.worktreeRoot,
                                paths: ["Sources/Late.swift"],
                                timestamp: .now,
                                batchSeq: 92
                            )
                        )
                    )
                )
            )
        )
        for _ in 0..<200 {
            await Task.yield()
        }

        // Assert
        #expect(await fixture.probe.fileChangesets.count == initialFileCount)
        #expect(fixture.fseventClient.unregisteredWorktreeIds == [fixture.source.worktreeID])
        await observation.shutdown()
        await observation.shutdown()
        #expect(await fixture.bus.subscriberCount == 0)
        #expect(await terminalProbe.terminals == [.eventsEnded])
    }

    @Test("real Darwin observation routes a post-start Git worktree edit")
    func realDarwinObservationRoutesPostStartEdit() async throws {
        // Arrange
        let root = try await FilesystemTestGitRepo.create(
            named: "bridge-development-live-observation"
        )
        defer { FilesystemTestGitRepo.destroy(root) }
        let trackedFile = root.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
        let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
        let probe = BridgeDevelopmentObservationProbe()
        let bus = EventBus<RuntimeEnvelope>(name: "BridgeDevelopmentRealObservation")
        let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let observation = BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus,
                fseventStreamClient: DarwinFSEventStreamClient(),
                gitWorkingTreeProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: statusPhysicalGate
                ),
                filesystemDebounceWindow: .milliseconds(10),
                filesystemMaximumFlushLatency: .milliseconds(25),
                gitCoalescingWindow: .milliseconds(10)
            ),
            invalidationSink: { invalidation in
                await probe.record(invalidation)
            }
        )
        try await observation.start()
        #expect(await probe.waitForStatusCount(1, timeout: .seconds(5)))
        let statusCountBeforeEdit = await probe.statuses.count

        // Act
        try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
        let changeset = try #require(
            await probe.waitForFileChangeset(
                paths: ["tracked.txt"],
                timeout: .seconds(5)
            )
        )
        #expect(
            await probe.waitForStatusCount(
                statusCountBeforeEdit + 1,
                timeout: .seconds(5)
            )
        )

        // Assert
        #expect(changeset.paths == ["tracked.txt"])
        let status = try #require(await probe.statuses.last)
        #expect(status.summary.changed == 1)
        await observation.shutdown()
        #expect(await bus.subscriberCount == 0)
    }

    @Test("real Darwin deletion emits a file invalidation and refreshes Review")
    func realDarwinDeletionEmitsInvalidationAndRefreshesReview() async throws {
        // Arrange
        let root = try await FilesystemTestGitRepo.create(
            named: "bridge-development-live-review"
        )
        defer { FilesystemTestGitRepo.destroy(root) }
        let trackedFile = root.appending(path: "tracked.txt")
        try "initial\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: root, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: root, args: ["commit", "-m", "Initial"])
        try "initial\nupdated\n".write(to: trackedFile, atomically: false, encoding: .utf8)
        let source = BridgeDevelopmentObservationFixture.makeSource(root: root)
        let probe = BridgeDevelopmentObservationProbe()
        let bus = EventBus<RuntimeEnvelope>(name: "BridgeDevelopmentRealDeletionObservation")
        let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        // Every Review commit the host makes, so the deletion is awaited as the
        // commit that publishes it instead of by sampling the diagnostic read.
        let reviewCommits = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        defer { reviewCommits.continuation.finish() }
        let host = try await makeReviewCommitObservedHost(
            source: source,
            statusPhysicalGate: statusPhysicalGate,
            reviewCommits: reviewCommits.continuation
        )
        let observation = BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus,
                fseventStreamClient: DarwinFSEventStreamClient(),
                gitWorkingTreeProvider: AgentStudioGitWorkingTreeStatusProvider(
                    physicalGate: statusPhysicalGate
                ),
                filesystemDebounceWindow: .milliseconds(10),
                filesystemMaximumFlushLatency: .milliseconds(25),
                gitCoalescingWindow: .milliseconds(10)
            ),
            invalidationSink: { invalidation in
                await host.handleObservedWorktreeInvalidation(invalidation)
                await probe.record(invalidation)
            }
        )
        do {
            let bootstrapRequest = try JSONDecoder().decode(
                BridgeDevelopmentProductBootstrapRequest.self,
                from: Data(
                    #"{"navigationIntent":{"commandId":"live-review","commandKind":"activateContext","surface":"review"},"reason":"initial","tabId":"owner-tab-1"}"#
                        .utf8
                )
            )
            _ = try await host.issueBootstrap(for: bootstrapRequest)
            try await observation.start()
            #expect(await host.diagnosticCommittedReviewPublication()?.package.reviewGeneration == 1)
            #expect(await probe.waitForStatusCount(1, timeout: .seconds(5)))
            #expect(
                await waitForReviewRefreshSettlement(
                    host: host,
                    timeout: .seconds(5)
                )
            )
            let baselinePublication = try #require(
                await host.diagnosticCommittedReviewPublication()
            )
            #expect(baselinePublication.package.reviewGeneration == 1)
            #expect(
                baselinePublication.package.itemsById.values.contains {
                    $0.headPath == "tracked.txt"
                }
            )

            // Act deletion as the only post-start filesystem mutation.
            try FileManager.default.removeItem(at: trackedFile)
            let deletionChangeset = try #require(
                await probe.waitForFileChangeset(
                    paths: ["tracked.txt"],
                    timeout: .seconds(5)
                )
            )
            #expect(deletionChangeset.paths == ["tracked.txt"])
            #expect(
                await waitForCommittedReviewDeletion(
                    path: "tracked.txt",
                    host: host,
                    reviewCommits: reviewCommits.stream
                )
            )

            // Assert deletion.
            let deletedPublication = try #require(await host.diagnosticCommittedReviewPublication())
            #expect(deletedPublication.package.reviewGeneration == baselinePublication.package.reviewGeneration)
            #expect(deletedPublication.package.revision > baselinePublication.package.revision)
            #expect(
                deletedPublication.package.itemsById.values.contains {
                    $0.basePath == "tracked.txt" && $0.headPath == nil
                }
            )
            await observation.stopFactAdmissionAndDrainRouting()
            await host.shutdown()
            await observation.shutdownSources()
        } catch {
            await observation.stopFactAdmissionAndDrainRouting()
            await host.shutdown()
            await observation.shutdownSources()
            throw error
        }
    }

}

private struct BridgeDevelopmentObservationFixture {
    let bus: EventBus<RuntimeEnvelope>
    let fseventClient: ControllableFSEventStreamClient
    let gitProvider: BridgeDevelopmentObservationGitProvider
    let probe: BridgeDevelopmentObservationProbe
    let source: BridgeDevelopmentProductSource

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-seeded-observation-tests"
        )
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources"),
            withIntermediateDirectories: true
        )
        try Data("let observationProof = true\n".utf8).write(
            to: root.appending(path: "Sources/App.swift")
        )
        return Self(
            bus: EventBus<RuntimeEnvelope>(name: "BridgeDevelopmentObservationTests"),
            fseventClient: ControllableFSEventStreamClient(),
            gitProvider: BridgeDevelopmentObservationGitProvider(),
            probe: BridgeDevelopmentObservationProbe(),
            source: makeSource(root: root)
        )
    }

    static func makeSource(root: URL) -> BridgeDevelopmentProductSource {
        BridgeDevelopmentProductSource(
            paneID: UUID(uuidString: "00000000-0000-7000-8000-000000000063")!,
            paneState: BridgePaneState(
                panelKind: .diffViewer,
                source: .workspace(
                    rootPath: root.path,
                    baseline: WorkspaceBaseline(
                        contributionTarget: .ref(name: "HEAD")
                    )
                )
            ),
            repoID: UUID(uuidString: "00000000-0000-7000-8000-000000000061")!,
            reviewedSubjectLabel: "observation-tests",
            worktreeID: UUID(uuidString: "00000000-0000-7000-8000-000000000062")!,
            worktreeRoot: root
        )
    }

    func makeObservation() -> BridgeDevelopmentSeededWorktreeObservation {
        BridgeDevelopmentSeededWorktreeObservation(
            source: source,
            dependencies: .init(
                bus: bus,
                fseventStreamClient: fseventClient,
                gitWorkingTreeProvider: gitProvider,
                filesystemDebounceWindow: .zero,
                filesystemMaximumFlushLatency: .zero,
                gitCoalescingWindow: .zero
            ),
            invalidationSink: { invalidation in
                await probe.record(invalidation)
            }
        )
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: source.worktreeRoot)
    }

    func waitForUnregisteredWorktreeCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if fseventClient.unregisteredWorktreeIds.count >= expectedCount { return true }
            await Task.yield()
        }
        return false
    }
}

private actor BridgeDevelopmentObservationGitProvider: GitWorkingTreeStatusProvider {
    func statusResult(
        for _: URL,
        pathspecs _: [String]?
    ) -> GitWorkingTreeStatusResult {
        .available(
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(
                    changed: 0,
                    staged: 0,
                    untracked: 0
                ),
                branch: "feature/observation-proof",
                origin: nil
            )
        )
    }
}

private actor BridgeDevelopmentObservationProbe {
    private(set) var fileChangesets: [FileChangeset] = []
    private(set) var statuses: [GitWorkingTreeStatus] = []

    func record(_ invalidation: BridgePaneWorktreeProductInvalidation) {
        switch invalidation {
        case .filesChanged(let changeset):
            fileChangesets.append(changeset)
        case .statusChanged(let status):
            statuses.append(status)
        }
    }

    func waitForFileChangesetCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if fileChangesets.count >= expectedCount { return true }
            await Task.yield()
        }
        return false
    }

    func waitForFileChangeset(
        paths expectedPaths: [String],
        timeout: Duration
    ) async -> FileChangeset? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let matchingChangeset = fileChangesets.last(where: { $0.paths == expectedPaths }) {
                return matchingChangeset
            }
            await Task.yield()
        }
        return nil
    }

    func waitForStatusCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if statuses.count >= expectedCount { return true }
            await Task.yield()
        }
        return false
    }
}

private actor BridgeDevelopmentObservationTerminalProbe {
    private(set) var terminals: [FSEventStreamRuntimeTerminal] = []

    func record(_ terminal: FSEventStreamRuntimeTerminal) {
        terminals.append(terminal)
    }

    func waitForTerminalCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if terminals.count >= expectedCount { return true }
            await Task.yield()
        }
        return false
    }
}

private func waitForReviewRefreshSettlement(
    host: BridgeDevelopmentProductHost,
    timeout: Duration
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await !host.diagnosticPanePresentation().refreshingLanes.contains(.review) { return true }
        await Task.yield()
    }
    return false
}

/// The development host over the real git provider, reporting each Review
/// commit it makes on `reviewCommits`.
private func makeReviewCommitObservedHost(
    source: BridgeDevelopmentProductSource,
    statusPhysicalGate: AgentStudioGitStatusPhysicalGate,
    reviewCommits: AsyncStream<Void>.Continuation
) async throws -> BridgeDevelopmentProductHost {
    try await BridgeDevelopmentProductHost(
        source: source,
        contributionTargetCommit: { _ in .unchanged(source.paneState) },
        statusPhysicalGate: statusPhysicalGate,
        makeReviewProvider: { repositoryPath, gitReadContext in
            BridgeReviewSourceProviderFactory.gitProvider(
                repositoryPath: repositoryPath,
                gitReadContext: gitReadContext,
                statusPhysicalGate: statusPhysicalGate
            )
        },
        didCommitReviewPublication: { reviewCommits.yield() }
    )
}

/// Returns once a committed Review publication shows `path` deleted. Each
/// check follows a Review commit the host announced, so it waits for the event
/// that can change the answer and never re-reads on a clock. `false` means the
/// commit stream ended first.
private func waitForCommittedReviewDeletion(
    path: String,
    host: BridgeDevelopmentProductHost,
    reviewCommits: AsyncStream<Void>
) async -> Bool {
    var commits = reviewCommits.makeAsyncIterator()
    while true {
        if let publication = await host.diagnosticCommittedReviewPublication(),
            publication.package.itemsById.values.contains(where: { $0.basePath == path && $0.headPath == nil })
        {
            return true
        }
        guard await commits.next() != nil else { return false }
    }
}
