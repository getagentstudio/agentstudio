import AgentStudioInfrastructure
import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("FilesystemActor repository activity", .serialized)
struct FilesystemActorActivityTests {
    @Test("remove and re-add revokes repository authority before a replacement checkpoint")
    func removeAndReAddRevokesAuthorityBeforeReplacementCheckpoint() async {
        // Arrange
        let streamClient = ControllableFSEventStreamClient()
        let authorityRevocationRecorder = FilesystemActivityAuthorityRevocationRecorder()
        let activityProjector = RepositoryLocalActivityProjector(
            authorityRevocationSink: { repositoryStableKeys in
                await authorityRevocationRecorder.record(repositoryStableKeys)
            },
            commitSink: { _ in }
        )
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let rootPath = URL(filePath: "/tmp/activity-authority-\(worktreeId)")
        let stableKey = "1111111122222222"
        let unaffectedWorktreeId = UUIDv7.generate()
        let unaffectedRepoId = UUIDv7.generate()
        let unaffectedRootPath = URL(
            filePath: "/tmp/activity-authority-\(unaffectedWorktreeId)"
        )
        let unaffectedStableKey = "3333333344444444"
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: rootPath),
                    unaffectedWorktreeId: WorktreeFilesystemContext(
                        repoId: unaffectedRepoId,
                        rootPath: unaffectedRootPath
                    ),
                ],
                repositoryStableKeysByWorktreeId: [
                    worktreeId: stableKey,
                    unaffectedWorktreeId: unaffectedStableKey,
                ]
            )
        )
        await authorityRevocationRecorder.reset()

        // Act
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 2,
                contextsByWorktreeId: [
                    unaffectedWorktreeId: WorktreeFilesystemContext(
                        repoId: unaffectedRepoId,
                        rootPath: unaffectedRootPath
                    )
                ],
                repositoryStableKeysByWorktreeId: [
                    unaffectedWorktreeId: unaffectedStableKey
                ]
            )
        )
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 3,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: rootPath),
                    unaffectedWorktreeId: WorktreeFilesystemContext(
                        repoId: unaffectedRepoId,
                        rootPath: unaffectedRootPath
                    ),
                ],
                repositoryStableKeysByWorktreeId: [
                    worktreeId: stableKey,
                    unaffectedWorktreeId: unaffectedStableKey,
                ]
            )
        )

        // Assert
        #expect(await authorityRevocationRecorder.revocations == [[stableKey], [stableKey]])
        await actor.shutdown()
    }

    @Test("stable-key topology enrichment preserves the existing stream registration")
    func stableKeyTopologyEnrichmentPreservesExistingStreamRegistration() async {
        // Arrange
        let streamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            sleepClock: TestPushClock()
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let rootPath = URL(filePath: "/tmp/activity-stable-key-\(worktreeId)")
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)

        // Act
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: rootPath)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: "stable-repository-key"]
            )
        )

        // Assert
        #expect(streamClient.registeredWorktreeIds == [worktreeId])
        #expect(streamClient.unregisteredWorktreeIds.isEmpty)
        #expect(await actor.repositoryStableKeysByWorktreeId[worktreeId] == "stable-repository-key")
        await actor.shutdown()
    }

    @Test("shutdown commits accepted activity before retiring streams")
    func shutdownCommitsAcceptedActivityBeforeRetiringStreams() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "filesystem-activity-shutdown-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamClient = DarwinFSEventStreamClient(
            localStreamFactory: { _ in ActivityTestLocalFSEventStreamLifetime() }
        )
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: clock,
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "1111111122222222"
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: fixtureRoot)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        let changedPath = DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
            .appending(path: "Sources/Shutdown.swift").path
        streamClient.receiveLocalRawEvents(
            worktreeId: worktreeId,
            rawEvents: [
                (
                    path: changedPath,
                    eventId: 77,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
                )
            ]
        )

        await actor.shutdown()

        let commits = await activityCommitRecorder.commits
        #expect(commits.count == 1)
        #expect(commits.first?.repositoryUpdates.first?.repositoryStableKey == repositoryStableKey)
        #expect(commits.first?.repositoryUpdates.first?.qualifyingActivityAt != nil)
        #expect(commits.first?.cursorWatermarks.first?.lastEventID == 77)
    }

    @Test("shutdown completes after start with no registered filesystem roots")
    func shutdownCompletesAfterStartWithNoRegisteredFilesystemRoots() async {
        let activityProjector = RepositoryLocalActivityProjector { _ in }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: DarwinFSEventStreamClient(),
            repositoryLocalActivityProjector: activityProjector
        )

        await actor.start()
        await actor.shutdown()

        #expect(await actor.hasBegunShutdown)
    }

    @Test("owned remote-ref updates preserve Git correctness without minting local activity")
    func ownedRemoteRefUpdatesDoNotMintLocalActivity() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "filesystem-owned-ref-activity-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamClient = DarwinFSEventStreamClient(
            localStreamFactory: { _ in ActivityTestLocalFSEventStreamLifetime() }
        )
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "3333333344444444"
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: fixtureRoot)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        let changedPath = DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
            .appending(path: ".git/refs/remotes/origin/main").path
        streamClient.receiveLocalRawEvents(
            worktreeId: worktreeId,
            rawEvents: [
                (
                    path: changedPath,
                    eventId: 88,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagOwnEvent
                    )
                )
            ]
        )

        await actor.shutdown()

        let commit = try #require(await activityCommitRecorder.commits.first)
        let update = try #require(commit.repositoryUpdates.first)
        #expect(update.repositoryStableKey == repositoryStableKey)
        #expect(update.qualifyingActivityAt == nil)
        guard case .restart = update.coverageChange else {
            Issue.record("owned canonical-ref activity must conservatively restart coverage")
            return
        }
        #expect(commit.cursorWatermarks.first?.lastEventID == 88)
    }

    @Test("owned projected worktree mutations still qualify as local activity")
    func ownedProjectedWorktreeMutationsQualifyAsLocalActivity() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "filesystem-owned-projected-activity-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamClient = DarwinFSEventStreamClient(
            localStreamFactory: { _ in ActivityTestLocalFSEventStreamLifetime() }
        )
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "5555555566666666"
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: fixtureRoot)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        let changedPath = DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
            .appending(path: "Sources/Edited.swift").path
        streamClient.receiveLocalRawEvents(
            worktreeId: worktreeId,
            rawEvents: [
                (
                    path: changedPath,
                    eventId: 89,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagOwnEvent
                    )
                )
            ]
        )

        await actor.shutdown()

        let commit = try #require(await activityCommitRecorder.commits.first)
        let update = try #require(commit.repositoryUpdates.first)
        #expect(update.repositoryStableKey == repositoryStableKey)
        #expect(update.qualifyingActivityAt != nil)
        #expect(commit.cursorWatermarks.first?.lastEventID == 89)
    }

    @Test("activity burst uses one existing filesystem drain checkpoint")
    func activityBurstUsesOneExistingFilesystemDrainCheckpoint() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "filesystem-activity-checkpoint-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamClient = DarwinFSEventStreamClient(
            localStreamFactory: { _ in ActivityTestLocalFSEventStreamLifetime() }
        )
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: clock,
            debounceWindow: .seconds(1),
            maxFlushLatency: .seconds(10)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "eeeeeeeeffffffff"
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: fixtureRoot)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        await clock.waitForPendingSleepCount()
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { await activityCommitRecorder.commits.count == 1 })
        await activityCommitRecorder.reset()
        #expect(await waitUntil { await actor.drainTaskLogicalDebtCount == 0 })
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 2,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        #expect(await actor.drainTaskLogicalDebtCount == 0)
        #expect(clock.pendingSleepCount == 0)

        let canonicalRoot = DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
        for eventID in 41...43 {
            streamClient.receiveLocalRawEvents(
                worktreeId: worktreeId,
                rawEvents: [
                    (
                        path: canonicalRoot.appending(path: "Sources/File\(eventID).swift").path,
                        eventId: FSEventStreamEventId(eventID),
                        flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
                    )
                ]
            )
        }

        let burstBarrier = try #require(await streamClient.captureActivityBarrier())
        #expect(burstBarrier.deliveredEventIDByParticipant.values.max() ?? 0 >= 43)
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .seconds(1))
        let burstCommitted = await waitUntil {
            await activityCommitRecorder.commits.count == 1
        }
        #expect(burstCommitted)
        let commits = await activityCommitRecorder.commits
        #expect(commits.count == 1)
        #expect(commits.first?.repositoryUpdates.first?.qualifyingActivityAt != nil)
        await actor.shutdown()
    }

    @Test("activity fence consumes retained activity loss before acknowledgement")
    func activityFenceConsumesRetainedActivityLossBeforeAcknowledgement() async throws {
        let streamClient = ControllableFSEventStreamClient()
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "aaaaaaaabbbbbbbb"
        let participant = FSEventParticipant(
            scopeKey: "local-\(worktreeId.uuidString)",
            generation: 1,
            volumeIdentifier: "volume-1"
        )
        await actor.register(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: URL(filePath: "/tmp/activity-overflow-\(worktreeId.uuidString)")
        )
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(
                        repoId: repoId,
                        rootPath: URL(filePath: "/tmp/activity-overflow-\(worktreeId.uuidString)")
                    )
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        await activityProjector.replaceParticipants(
            [
                RepositoryLocalActivityParticipant(
                    scopeKey: participant.scopeKey,
                    generation: participant.generation,
                    volumeIdentifier: participant.volumeIdentifier,
                    repositoryStableKeys: [repositoryStableKey]
                )
            ],
            coverageRestartedAt: Date(timeIntervalSince1970: 100)
        )
        let fenceID = FSEventActivityProcessingFenceID(rawValue: 1)
        streamClient.sendActivityOverflowRecovery(
            participant: participant,
            processedThroughEventID: 42,
            coverageLostWorktreeIds: [worktreeId]
        )

        streamClient.sendActivityProcessingFence(fenceID)

        let fenceWasAcknowledged = await waitUntil {
            streamClient.acknowledgedActivityProcessingFenceIDs.contains(fenceID)
        }
        #expect(fenceWasAcknowledged)
        let didCommit = try await activityProjector.commitBarrier(
            RepositoryLocalActivityBarrier(
                deliveredEventIDByParticipant: [
                    RepositoryLocalActivityParticipantIdentity(
                        scopeKey: participant.scopeKey,
                        generation: participant.generation
                    ): 42
                ],
                completedAt: Date(timeIntervalSince1970: 120)
            )
        )
        #expect(didCommit)
        let commit = try #require(await activityCommitRecorder.commits.first)
        guard case .restart = commit.repositoryUpdates.first?.coverageChange else {
            Issue.record("activity loss was not projected before fence acknowledgement")
            await actor.shutdown()
            return
        }
        await actor.shutdown()
    }

    @Test("activity barrier waits for FilesystemActor ingress acknowledgement")
    func activityBarrierWaitsForFilesystemActorIngressAcknowledgement() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "filesystem-activity-fence-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamClient = DarwinFSEventStreamClient(
            localStreamFactory: { _ in ActivityTestLocalFSEventStreamLifetime() }
        )
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let repositoryStableKey = "ccccccccdddddddd"
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: fixtureRoot)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: repoId, rootPath: fixtureRoot)
                ],
                repositoryStableKeysByWorktreeId: [worktreeId: repositoryStableKey]
            )
        )
        streamClient.receiveLocalRawEvents(
            worktreeId: worktreeId,
            rawEvents: [
                (
                    path: DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
                        .appending(path: "Sources/Changed.swift").path,
                    eventId: 42,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
                )
            ]
        )

        let barrier = try #require(await streamClient.captureActivityBarrier())

        let participant = try #require(
            barrier.bindings.first(where: { $0.worktreeId == worktreeId })?.participant
        )
        #expect(barrier.deliveredEventIDByParticipant[participant] ?? 0 >= 42)
        await activityProjector.replaceParticipants(
            [
                RepositoryLocalActivityParticipant(
                    scopeKey: participant.scopeKey,
                    generation: participant.generation,
                    volumeIdentifier: participant.volumeIdentifier,
                    repositoryStableKeys: [repositoryStableKey]
                )
            ],
            coverageRestartedAt: Date(timeIntervalSince1970: 100)
        )
        let didCommit = try await activityProjector.commitBarrier(
            RepositoryLocalActivityBarrier(
                deliveredEventIDByParticipant: [
                    RepositoryLocalActivityParticipantIdentity(
                        scopeKey: participant.scopeKey,
                        generation: participant.generation
                    ): barrier.deliveredEventIDByParticipant[participant] ?? 0
                ],
                completedAt: Date(timeIntervalSince1970: 120)
            )
        )
        #expect(didCommit)
        let commit = try #require(await activityCommitRecorder.commits.first)
        #expect(commit.repositoryUpdates.first?.qualifyingActivityAt != nil)
        #expect(commit.repositoryUpdates.first?.repositoryStableKey == repositoryStableKey)
        await actor.shutdown()
    }

    @Test("unmapped watched-folder participants do not block repository activity commits")
    func unmappedWatchedFolderParticipantDoesNotBlockRepositoryActivityCommit() async throws {
        // Arrange
        let streamClient = ControllableFSEventStreamClient()
        let activityCommitRecorder = FilesystemActivityCommitRecorder()
        let activityProjector = RepositoryLocalActivityProjector { commit in
            await activityCommitRecorder.record(commit)
        }
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            repositoryLocalActivityProjector: activityProjector,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120)
        )
        let repositoryWorktreeID = UUIDv7.generate()
        let watchedFolderRegistrationID = UUIDv7.generate()
        let repositoryID = UUIDv7.generate()
        let repositoryStableKey = "ababababcdcdcdcd"
        let repositoryRoot = URL(
            filePath: "/tmp/activity-mapped-repository-\(repositoryWorktreeID.uuidString)"
        )
        let repositoryParticipant = FSEventParticipant(
            scopeKey: "local:\(repositoryWorktreeID.uuidString)",
            generation: 1,
            volumeIdentifier: "volume-1"
        )
        let watchedFolderParticipant = FSEventParticipant(
            scopeKey: "local:\(watchedFolderRegistrationID.uuidString)",
            generation: 2,
            volumeIdentifier: "volume-1"
        )
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    repositoryWorktreeID: WorktreeFilesystemContext(
                        repoId: repositoryID,
                        rootPath: repositoryRoot
                    )
                ],
                repositoryStableKeysByWorktreeId: [
                    repositoryWorktreeID: repositoryStableKey
                ]
            )
        )
        streamClient.setActivityBarrier(
            FSEventActivityBarrier(
                bindings: [
                    FSEventParticipantBinding(
                        worktreeId: repositoryWorktreeID,
                        participant: repositoryParticipant
                    ),
                    FSEventParticipantBinding(
                        worktreeId: watchedFolderRegistrationID,
                        participant: watchedFolderParticipant
                    ),
                ],
                deliveredEventIDByParticipant: [
                    repositoryParticipant: 42,
                    watchedFolderParticipant: 91,
                ]
            )
        )

        // Act
        let changedPath = repositoryRoot.appending(path: "Sources/Changed.swift").path
        streamClient.send(
            FSEventBatch(
                worktreeId: repositoryWorktreeID,
                paths: [changedPath],
                participant: repositoryParticipant,
                observations: [
                    FSEventObservation(
                        path: changedPath,
                        eventID: 42,
                        flags: UInt32(kFSEventStreamEventFlagItemModified)
                    )
                ]
            )
        )
        #expect(await waitUntil { await actor.pendingWorktreeLogicalDebtCount == 1 })
        await actor.shutdown()

        // Assert
        let commit = try #require(await activityCommitRecorder.commits.first)
        #expect(commit.repositoryUpdates.map(\.repositoryStableKey) == [repositoryStableKey])
        #expect(commit.repositoryUpdates.first?.qualifyingActivityAt != nil)
        #expect(commit.cursorWatermarks.first?.lastEventID == 42)
    }

    private func waitUntil(
        maxTurns: Int = 10_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxTurns {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}

private actor FilesystemActivityCommitRecorder {
    private(set) var commits: [RepositoryLocalActivityCommit] = []

    func record(_ commit: RepositoryLocalActivityCommit) {
        commits.append(commit)
    }

    func reset() {
        commits.removeAll(keepingCapacity: true)
    }
}

private actor FilesystemActivityAuthorityRevocationRecorder {
    private(set) var revocations: [Set<String>] = []

    func record(_ repositoryStableKeys: Set<String>) {
        revocations.append(repositoryStableKeys)
    }

    func reset() {
        revocations.removeAll(keepingCapacity: true)
    }
}

// These tests inject raw events and exact synthetic cursor IDs. A live native
// stream would mix machine-global event IDs into the same activity checkpoint.
private final class ActivityTestLocalFSEventStreamLifetime: DarwinLocalFSEventStreamLifetime, Sendable {
    func flush() -> Bool { true }

    func retire() {}

    func scheduleRetirement() {}
}
