import AgentStudioGit
import CoreServices
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("DarwinFSEventStreamClient")
struct DarwinFSEventStreamClientTests {
    @Test("local callback metadata survives bounded ingress")
    func localCallbackMetadataSurvivesBoundedIngress() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-metadata-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: worktreeId, repoId: UUIDv7.generate(), rootPath: fixtureRoot)
        let changedPath = DarwinFSEventPathCanonicalizer.canonicalURL(fixtureRoot)
            .appending(path: "Changed.swift").path
        let expectedFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagOwnEvent
        )
        let batchTask = Task<FSEventBatch?, Never> {
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem else { continue }
                if batch.worktreeId == worktreeId,
                    batch.observations.contains(where: { $0.eventID == 42 })
                {
                    return batch
                }
            }
            return nil
        }

        // Act
        client.receiveLocalRawEvents(
            worktreeId: worktreeId,
            rawEvents: [(path: changedPath, eventId: 42, flags: expectedFlags)]
        )

        // Assert
        let batch = try #require(await batchTask.value)
        #expect(batch.paths == [changedPath])
        #expect(batch.participant?.scopeKey == "local:\(worktreeId.uuidString)")
        #expect(batch.participant?.generation ?? 0 > 0)
        #expect(batch.participant?.volumeIdentifier.isEmpty == false)
        #expect(
            batch.observations
                == [
                    FSEventObservation(
                        path: changedPath,
                        eventID: 42,
                        flags: UInt32(expectedFlags)
                    )
                ]
        )
        let fenceConsumer = Task {
            for await ingressItem in client.events() {
                guard case .activityProcessingFence(let fenceID) = ingressItem else { continue }
                client.acknowledgeActivityProcessingFence(fenceID)
                return
            }
        }
        let barrier = try #require(await client.captureActivityBarrier())
        await fenceConsumer.value
        let participant = try #require(batch.participant)
        #expect(barrier.deliveredEventIDByParticipant[participant] ?? 0 >= 42)
        #expect(
            barrier.bindings.contains(
                FSEventParticipantBinding(worktreeId: worktreeId, participant: participant)
            )
        )
    }

    @Test("real stream delivers events from a temporary-directory root")
    func realStreamDeliversTemporaryDirectoryEvents() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-real-stream-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        let createdFile = fixtureRoot.appending(path: "created.txt")
        _ = client.register(worktreeId: worktreeId, repoId: UUIDv7.generate(), rootPath: fixtureRoot)

        let batchTask = Task<FSEventBatch?, Never> {
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem else { continue }
                if batch.worktreeId == worktreeId,
                    batch.paths.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "created.txt" })
                {
                    return batch
                }
            }
            return nil
        }
        try Data("created".utf8).write(to: createdFile)

        let batch = await batchTask.value

        #expect(batch?.worktreeId == worktreeId)
        #expect(
            batch?.paths.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "created.txt" }) == true
        )
    }

    @Test("event classification retains an in-root symlink object whose target is outside the root")
    func eventClassificationRetainsInRootSymlinkObject() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-classifier-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let rootPath = fixtureRoot.appending(path: "repo", directoryHint: .isDirectory)
        let outsideTargetPath = fixtureRoot.appending(path: "outside-target")
        let symlinkPath = rootPath.appending(path: "README.md")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        try Data().write(to: outsideTargetPath)
        try FileManager.default.createSymbolicLink(
            at: symlinkPath,
            withDestinationURL: outsideTargetPath
        )

        let classification = DarwinFSEventPathClassifier.classify(
            rawEvents: [(path: symlinkPath.path, eventId: 40, flags: 0)],
            ordinaryPaths: [symlinkPath.path],
            rootPath: rootPath.path,
            observationScopes: [
                AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: rootPath)
            ]
        )

        #expect(classification.rawEvents.map(\.hasRelevantMutation) == [true])
        #expect(classification.ordinaryPaths == [symlinkPath.path])
    }

    @Test("event classification normalizes lexical callback path spellings")
    func eventClassificationNormalizesLexicalCallbackPathSpellings() {
        let rootPath = "/tmp/repo"
        let canonicalChangedPath = "/tmp/repo/Sources/Changed.swift"
        let callbackPathSpellings = [
            "/tmp//repo/Sources/Changed.swift",
            "/tmp/repo/./Sources/Changed.swift",
            "/tmp/repo/Generated/../Sources/Changed.swift",
        ]

        let classification = DarwinFSEventPathClassifier.classify(
            rawEvents: callbackPathSpellings.enumerated().map { index, path in
                (path: path, eventId: FSEventStreamEventId(index + 41), flags: 0)
            },
            ordinaryPaths: callbackPathSpellings,
            rootPath: rootPath,
            observationScopes: [
                AgentStudioGit.GitStatusObservationScope(
                    kind: .item,
                    path: URL(fileURLWithPath: canonicalChangedPath)
                )
            ]
        )

        #expect(classification.rawEvents.map(\.hasRelevantMutation) == [true, true, true])
        #expect(classification.ordinaryPaths == callbackPathSpellings)
    }

    @Test("event classification excludes sibling prefixes and the loss sentinel")
    func eventClassificationExcludesSiblingPrefixesAndLossSentinel() {
        let rootPath = "/tmp/repo"
        let siblingPrefixPath = "/tmp/repository/Sources/Changed.swift"

        let classification = DarwinFSEventPathClassifier.classify(
            rawEvents: [
                (path: siblingPrefixPath, eventId: 41, flags: 0),
                (path: "/", eventId: 42, flags: 0),
            ],
            ordinaryPaths: [siblingPrefixPath, "/"],
            rootPath: rootPath,
            observationScopes: [
                AgentStudioGit.GitStatusObservationScope(
                    kind: .subtree,
                    path: URL(fileURLWithPath: rootPath)
                )
            ]
        )

        #expect(classification.rawEvents.map(\.hasRelevantMutation) == [false, false])
        #expect(classification.ordinaryPaths.isEmpty)
    }

    @Test("event classification normalizes each unique callback path once")
    func eventClassificationNormalizesEachUniqueCallbackPathOnce() {
        let rootPath = "/tmp/repo"
        let changedPath = "/tmp/repo/Sources/Changed.swift"
        let ignoredPath = "/tmp/outside/Other.swift"
        var normalizationCountByPath: [String: Int] = [:]

        let classification = DarwinFSEventPathClassifier.classify(
            rawEvents: [
                (path: changedPath, eventId: 41, flags: 0),
                (path: ignoredPath, eventId: 42, flags: 0),
            ],
            ordinaryPaths: [changedPath, ignoredPath],
            rootPath: rootPath,
            observationScopes: [
                AgentStudioGit.GitStatusObservationScope(
                    kind: .subtree,
                    path: URL(fileURLWithPath: rootPath)
                )
            ],
            normalize: { path in
                normalizationCountByPath[path, default: 0] += 1
                return path
            }
        )

        #expect(normalizationCountByPath == [changedPath: 1, ignoredPath: 1])
        #expect(classification.rawEvents.map(\.hasRelevantMutation) == [true, false])
        #expect(classification.ordinaryPaths == [changedPath])
    }

    @Test("continuity ledger rejects a baseline when mutation crosses its barrier")
    func continuityLedgerRejectsMutationAcrossBaselineBarrier() throws {
        let ledger = GitCleanContinuityLedger()
        let registrationId = UUIDv7.generate()
        let identity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-a")

        ledger.register(registrationId: registrationId, identity: identity)
        let preparation = try #require(ledger.beginBarrier(registrationId: registrationId, identity: identity))
        ledger.recordMutation(registrationId: registrationId, eventId: 41)

        #expect(ledger.commitBarrier(preparation) == .requiresExact(.mutationObserved))
    }

    @Test("continuity ledger rejects loss and discontinuity flags fail closed")
    func continuityLedgerRejectsLossFlags() throws {
        let lossFlags: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
            FSEventStreamEventFlags(kFSEventStreamEventFlagMount),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount),
        ]

        for flags in lossFlags {
            let ledger = GitCleanContinuityLedger()
            let registrationId = UUIDv7.generate()
            let identity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-\(flags)")
            ledger.register(registrationId: registrationId, identity: identity)
            let preparation = try #require(
                ledger.beginBarrier(registrationId: registrationId, identity: identity)
            )

            ledger.recordRawEvent(
                registrationId: registrationId,
                eventId: 42,
                flags: flags,
                hasRelevantMutation: false
            )

            #expect(ledger.commitBarrier(preparation) == .requiresExact(.eventStreamUncertain))
        }
    }

    @Test("continuity ledger applies one callback batch without losing mutation or cursor order")
    func continuityLedgerAppliesCallbackBatchInOrder() throws {
        let mutationLedger = GitCleanContinuityLedger()
        let mutationRegistrationId = UUIDv7.generate()
        let mutationIdentity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-mutation")
        mutationLedger.register(registrationId: mutationRegistrationId, identity: mutationIdentity)
        let mutationBarrier = try #require(
            mutationLedger.beginBarrier(
                registrationId: mutationRegistrationId,
                identity: mutationIdentity
            )
        )

        mutationLedger.recordRawEvents(
            registrationId: mutationRegistrationId,
            events: [
                DarwinFSEventClassifiedRawEvent(
                    eventId: 41,
                    flags: 0,
                    hasRelevantMutation: false
                ),
                DarwinFSEventClassifiedRawEvent(
                    eventId: 42,
                    flags: 0,
                    hasRelevantMutation: true
                ),
            ]
        )

        #expect(mutationLedger.commitBarrier(mutationBarrier) == .requiresExact(.mutationObserved))

        let cursorLedger = GitCleanContinuityLedger()
        let cursorRegistrationId = UUIDv7.generate()
        let cursorIdentity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-cursor")
        cursorLedger.register(registrationId: cursorRegistrationId, identity: cursorIdentity)
        let cursorBarrier = try #require(
            cursorLedger.beginBarrier(
                registrationId: cursorRegistrationId,
                identity: cursorIdentity
            )
        )

        cursorLedger.recordRawEvents(
            registrationId: cursorRegistrationId,
            events: [
                DarwinFSEventClassifiedRawEvent(
                    eventId: 42,
                    flags: 0,
                    hasRelevantMutation: false
                ),
                DarwinFSEventClassifiedRawEvent(
                    eventId: 41,
                    flags: 0,
                    hasRelevantMutation: false
                ),
            ]
        )

        #expect(cursorLedger.commitBarrier(cursorBarrier) == .requiresExact(.eventStreamUncertain))
    }

    @Test("continuity ledger renews only the same registration identity and epochs")
    func continuityLedgerRenewsStableAuthority() throws {
        let ledger = GitCleanContinuityLedger()
        let registrationId = UUIDv7.generate()
        let identity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-a")
        ledger.register(registrationId: registrationId, identity: identity)
        let preparation = try #require(ledger.beginBarrier(registrationId: registrationId, identity: identity))
        guard case .authoritative(let authority) = ledger.commitBarrier(preparation) else {
            Issue.record("stable barrier did not mint authority")
            return
        }

        let renewed = ledger.renew(authority)

        #expect(renewed == .authoritative(authority))
        ledger.register(
            registrationId: registrationId,
            identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-b")
        )
        #expect(ledger.renew(authority) == .requiresExact(.identityChanged))
    }

    @Test("continuity ledger resolves only the ambiguity epoch captured by the exact scan")
    func continuityLedgerResolvesOnlyCapturedAncestorAmbiguity() throws {
        let ledger = GitCleanContinuityLedger()
        let registrationId = UUIDv7.generate()
        let identity = AgentStudioGit.GitStatusObservationIdentity(rawValue: "identity-ancestor")
        ledger.register(registrationId: registrationId, identity: identity)
        let staleBarrier = try #require(
            ledger.beginBarrier(registrationId: registrationId, identity: identity)
        )

        #expect(ledger.recordAncestorAmbiguity(registrationId: registrationId) == 1)
        #expect(ledger.commitBarrier(staleBarrier) == .requiresExact(.eventStreamUncertain))

        let currentBarrier = try #require(
            ledger.beginBarrier(registrationId: registrationId, identity: identity)
        )
        guard case .authoritative(let authority) = ledger.commitBarrier(currentBarrier) else {
            Issue.record("current ancestor ambiguity barrier did not mint authority")
            return
        }
        #expect(authority.resolvedAncestorAmbiguityEpoch == 1)
        #expect(ledger.renew(authority) == .authoritative(authority))

        #expect(ledger.recordAncestorAmbiguity(registrationId: registrationId) == 2)
        let resolved = ledger.resolveAncestorAmbiguity(
            expectedAuthority: authority,
            expectedObservedEpoch: 2
        )
        guard case .authoritative(let renewedAuthority) = resolved else {
            Issue.record("matching ancestor ambiguity did not renew authority")
            return
        }
        #expect(renewedAuthority.resolvedAncestorAmbiguityEpoch == 2)
        #expect(ledger.renew(authority) == .authoritative(renewedAuthority))
    }

    @Test("filesystem ingress does not retain more fine batches than its configured capacity")
    func ingressRetainsAtMostConfiguredFineBatchCapacity() async throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 2)
        let worktreeId = UUID()
        ingressBuffer.yield(FSEventBatch(worktreeId: worktreeId, paths: ["first"]))
        ingressBuffer.yield(FSEventBatch(worktreeId: worktreeId, paths: ["second"]))
        ingressBuffer.yield(FSEventBatch(worktreeId: worktreeId, paths: ["third"]))
        ingressBuffer.finish()

        var retainedBatches: [FSEventBatch] = []
        for await ingressItem in ingressBuffer.events() {
            guard case .batch(let batch) = ingressItem else { continue }
            retainedBatches.append(batch)
        }

        #expect(retainedBatches.count <= 2)
        #expect(ingressBuffer.consumeOverflowRecoveries().map(\.worktreeId) == [worktreeId])
    }

    @Test("activity processing fence follows every previously accepted batch")
    func activityProcessingFencePreservesIngressOrder() async throws {
        // Arrange
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 2)
        let worktreeId = UUIDv7.generate()
        let batch = FSEventBatch(worktreeId: worktreeId, paths: ["Sources/Changed.swift"])
        ingressBuffer.yield(batch)
        let fenceTask = Task { await ingressBuffer.enqueueActivityProcessingFence() }
        var iterator = ingressBuffer.events().makeAsyncIterator()

        // Act / Assert
        guard case .batch(let receivedBatch) = try #require(await iterator.next()) else {
            Issue.record("activity fence overtook its preceding filesystem batch")
            return
        }
        #expect(receivedBatch.worktreeId == worktreeId)
        guard case .activityProcessingFence(let fenceID) = try #require(await iterator.next()) else {
            Issue.record("activity processing fence was not delivered after its batch")
            return
        }
        ingressBuffer.acknowledgeActivityProcessingFence(fenceID)
        #expect(await fenceTask.value)
        ingressBuffer.finish()
    }

    @Test("activity processing fence fails closed when bounded ingress is full")
    func activityProcessingFenceRejectsFullIngress() async {
        // Arrange
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 1)
        let worktreeId = UUIDv7.generate()
        ingressBuffer.yield(
            FSEventBatch(worktreeId: worktreeId, paths: ["Sources/Retained.swift"])
        )

        // Act
        let didCrossProcessedIngress = await ingressBuffer.enqueueActivityProcessingFence()

        // Assert
        #expect(!didCrossProcessedIngress)
        var iterator = ingressBuffer.events().makeAsyncIterator()
        guard case .batch(let retainedBatch) = await iterator.next() else {
            Issue.record("full ingress displaced the earlier filesystem batch")
            return
        }
        #expect(retainedBatch.worktreeId == worktreeId)
        ingressBuffer.finish()
    }

    @Test("activity overflow scope churn collapses to bounded coverage loss")
    func activityOverflowScopeChurnCollapsesToBoundedCoverageLoss() {
        let ingressBuffer = DarwinFSEventIngressBuffer(
            capacity: 1,
            maximumRetainedActivityOverflowParticipantScopes: 1
        )
        let retainedWorktreeId = UUIDv7.generate()
        let firstLostWorktreeId = UUIDv7.generate()
        let secondLostWorktreeId = UUIDv7.generate()
        ingressBuffer.yield(
            FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"])
        )
        ingressBuffer.yieldActivityObservations(
            FSEventActivityObservationBatch(
                participant: FSEventParticipant(
                    scopeKey: "shared:first",
                    generation: 1,
                    volumeIdentifier: "1"
                ),
                processedThroughEventID: 10,
                participantWorktreeIds: [firstLostWorktreeId],
                qualifyingWorktreeIds: [],
                coverageLostWorktreeIds: []
            )
        )
        ingressBuffer.yieldActivityObservations(
            FSEventActivityObservationBatch(
                participant: FSEventParticipant(
                    scopeKey: "shared:second",
                    generation: 1,
                    volumeIdentifier: "1"
                ),
                processedThroughEventID: 11,
                participantWorktreeIds: [secondLostWorktreeId],
                qualifyingWorktreeIds: [],
                coverageLostWorktreeIds: []
            )
        )

        #expect(ingressBuffer.consumeActivityOverflowRecoveries().isEmpty)
        #expect(
            ingressBuffer.consumeCoarseActivityOverflowWorktreeIds()
                == [firstLostWorktreeId, secondLostWorktreeId]
        )
        ingressBuffer.finish()
    }

    @Test("overflow debt coalesces per affected worktree and stays isolated")
    func overflowDebtCoalescesPerAffectedWorktree() {
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 1)
        let retainedWorktreeId = UUID()
        let overflowedWorktreeId = UUID()
        let otherOverflowedWorktreeId = UUID()

        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["first"]))
        ingressBuffer.yield(FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["second"]))
        ingressBuffer.yield(FSEventBatch(worktreeId: otherOverflowedWorktreeId, paths: ["other"]))

        let recoveries = ingressBuffer.consumeOverflowRecoveries()
        #expect(Set(recoveries.map(\.worktreeId)) == [overflowedWorktreeId, otherOverflowedWorktreeId])
        #expect(recoveries.first { $0.worktreeId == overflowedWorktreeId }?.paths == ["first", "second"])
        #expect(recoveries.first { $0.worktreeId == otherOverflowedWorktreeId }?.paths == ["other"])
        #expect(ingressBuffer.consumeOverflowRecoveries().isEmpty)
        ingressBuffer.finish()
    }

    @Test("ingress buffer attributes dispositions and overflow drains by bounded source")
    func ingressBufferAttributesDispositionsAndOverflowDrains() {
        let accumulator = DarwinFSEventIngressPerformanceAccumulator()
        let ingressBuffer = DarwinFSEventIngressBuffer(
            capacity: 1,
            performanceAccumulator: accumulator
        )
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()

        ingressBuffer.yield(
            FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]),
            source: .local
        )
        ingressBuffer.yield(
            FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["dropped"]),
            source: .sharedExact
        )
        _ = ingressBuffer.consumeOverflowRecoveries()
        ingressBuffer.finish()
        ingressBuffer.yield(
            FSEventBatch(
                worktreeId: overflowedWorktreeId,
                paths: [],
                requiresFullGitRefresh: true
            ),
            source: .sharedUncertainty
        )

        let snapshot = accumulator.snapshotAndReset()
        #expect(snapshot.localIngress.acceptedBatchCount == 1)
        #expect(snapshot.localIngress.acceptedPathCount == 1)
        #expect(snapshot.sharedExactIngress.droppedBatchCount == 1)
        #expect(snapshot.sharedExactIngress.droppedPathCount == 1)
        #expect(snapshot.sharedUncertaintyIngress.terminatedBatchCount == 1)
        #expect(snapshot.sharedUncertaintyIngress.terminatedPathCount == 0)
        #expect(snapshot.overflowDrainCount == 1)
        #expect(snapshot.overflowRecoveryCount == 1)
        #expect(snapshot.overflowRetainedPathCount == 1)
        #expect(snapshot.overflowCoarseRecoveryCount == 0)
    }

    @Test("overflow recovery preserves known path scope")
    func overflowRecoveryPreservesKnownPathScope() throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 1)
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()

        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(
            FSEventBatch(
                worktreeId: overflowedWorktreeId,
                paths: ["Sources/First.swift", "Sources/Second.swift"]
            )
        )

        let recovery = try #require(ingressBuffer.consumeOverflowRecoveries().first)
        #expect(recovery.worktreeId == overflowedWorktreeId)
        #expect(recovery.paths == ["Sources/First.swift", "Sources/Second.swift"])
        ingressBuffer.finish()
    }

    @Test("overflow recovery preserves path-free full Git invalidation")
    func overflowRecoveryPreservesPathFreeFullGitInvalidation() throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 1)
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()

        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(
            FSEventBatch(
                worktreeId: overflowedWorktreeId,
                paths: [],
                requiresFullGitRefresh: true
            )
        )
        ingressBuffer.yield(
            FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["Sources/Later.swift"])
        )
        let isolatedWorktreeId = UUIDv7.generate()
        ingressBuffer.yield(
            FSEventBatch(worktreeId: isolatedWorktreeId, paths: ["Sources/Isolated.swift"])
        )

        let recoveries = ingressBuffer.consumeOverflowRecoveries()
        let recovery = try #require(recoveries.first { $0.worktreeId == overflowedWorktreeId })
        #expect(recovery.worktreeId == overflowedWorktreeId)
        #expect(recovery.paths == ["Sources/Later.swift"])
        #expect(recovery.requiresFullGitRefresh)
        let isolatedRecovery = try #require(recoveries.first { $0.worktreeId == isolatedWorktreeId })
        #expect(!isolatedRecovery.requiresFullGitRefresh)
        ingressBuffer.finish()
    }

    @Test("binding plan shares external exact-item parents without broadening local streams")
    func bindingPlanSeparatesSharedExternalExactItems() throws {
        let worktreeRoot = URL(fileURLWithPath: "/private/tmp/project/repo")
        let commonRefsRoot = URL(fileURLWithPath: "/private/tmp/project/common/refs")
        let externalParent = URL(fileURLWithPath: "/Users/example")
        let configurationPath = externalParent.appending(path: ".gitconfig")
        let ignorePath = externalParent.appending(path: ".gitignore-global")
        let scopes = [
            AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: worktreeRoot),
            AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: commonRefsRoot),
            AgentStudioGit.GitStatusObservationScope(
                kind: .item,
                path: worktreeRoot.appending(path: ".git/HEAD")
            ),
            AgentStudioGit.GitStatusObservationScope(
                kind: .item,
                path: commonRefsRoot.appending(path: "heads/main")
            ),
            AgentStudioGit.GitStatusObservationScope(kind: .item, path: configurationPath),
            AgentStudioGit.GitStatusObservationScope(kind: .item, path: ignorePath),
        ]

        let plans = (0..<148).compactMap { _ in
            DarwinFSEventBindingPlanner.plan(
                scopes: scopes,
                volumeSystemNumberForPath: { _ in 1 }
            )
        }
        let sharedParentKeys = Set(plans.flatMap { $0.sharedExactItemsByParent.keys })
        let plan = try #require(plans.first)

        #expect(plans.count == 148)
        #expect(sharedParentKeys.count == 1)
        #expect(plan.localWatchedPaths == [commonRefsRoot.path, worktreeRoot.path])
        #expect(plan.localScopes.count == 4)
        #expect(plan.sharedExactItemsByParent.count == 1)
        #expect(
            plan.sharedExactItemsByParent.values.first == Set([configurationPath.path, ignorePath.path])
        )
        #expect(
            plan.localScopes.count
                + plan.sharedExactItemsByParent.values.reduce(0) { $0 + $1.count } == scopes.count
        )
    }

    @Test("overflow recovery becomes coarse when retained path scope exceeds its bound")
    func overflowRecoveryBecomesCoarseWhenScopeExceedsBound() throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(
            capacity: 1,
            maximumRetainedOverflowPathsPerRegistration: 2
        )
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()
        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(
            FSEventBatch(
                worktreeId: overflowedWorktreeId,
                paths: ["one", "two", "three"]
            )
        )
        ingressBuffer.yield(FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["later"]))

        let recovery = try #require(ingressBuffer.consumeOverflowRecoveries().first)
        #expect(recovery.worktreeId == overflowedWorktreeId)
        #expect(recovery.paths == nil)
        #expect(recovery.requiresWatchedFolderScan == false)
        ingressBuffer.finish()
    }

    @Test("coarse overflow recovery retains git topology classification")
    func coarseOverflowRecoveryRetainsGitTopologyClassification() throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(
            capacity: 1,
            maximumRetainedOverflowPathsPerRegistration: 2
        )
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()
        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(
            FSEventBatch(
                worktreeId: overflowedWorktreeId,
                paths: ["one", "two", "three", "repo/.git/HEAD"]
            )
        )

        let recovery = try #require(ingressBuffer.consumeOverflowRecoveries().first)
        #expect(recovery.paths == nil)
        #expect(recovery.requiresWatchedFolderScan)
        ingressBuffer.finish()
    }

    @Test("already-coarse overflow recovery upgrades when a later batch contains git topology")
    func coarseOverflowRecoveryUpgradesForLaterGitTopologyBatch() throws {
        let ingressBuffer = DarwinFSEventIngressBuffer(
            capacity: 1,
            maximumRetainedOverflowPathsPerRegistration: 2
        )
        let retainedWorktreeId = UUIDv7.generate()
        let overflowedWorktreeId = UUIDv7.generate()
        ingressBuffer.yield(FSEventBatch(worktreeId: retainedWorktreeId, paths: ["retained"]))
        ingressBuffer.yield(
            FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["one", "two", "three"])
        )
        ingressBuffer.yield(
            FSEventBatch(worktreeId: overflowedWorktreeId, paths: ["repo/.git/HEAD"])
        )

        let recovery = try #require(ingressBuffer.consumeOverflowRecoveries().first)
        #expect(recovery.paths == nil)
        #expect(recovery.requiresWatchedFolderScan)
        ingressBuffer.finish()
    }

    @Test("shutdown terminates ingress without minting new overflow debt")
    func shutdownTerminatesIngressWithoutNewDebt() {
        let ingressBuffer = DarwinFSEventIngressBuffer(capacity: 1)
        ingressBuffer.finish()

        ingressBuffer.yield(FSEventBatch(worktreeId: UUID(), paths: ["post-shutdown"]))

        #expect(ingressBuffer.consumeOverflowRecoveries().isEmpty)
    }
}

extension DarwinFSEventStreamClientTests {
    @Test("conforms to FSEventStreamClient protocol")
    func conformsToProtocol() {
        let client: any FSEventStreamClient = DarwinFSEventStreamClient()
        _ = client.events()
        client.shutdown()
    }

    @Test("register/unregister lifecycle is idempotent")
    func registerUnregisterLifecycleIsIdempotent() async {
        let client = DarwinFSEventStreamClient()
        let worktreeId = UUID()
        let repoId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/darwin-fsevents-\(UUID().uuidString)")

        let firstOutcome = client.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        let secondOutcome = client.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)

        #expect(firstOutcome == .observing)
        #expect(secondOutcome == .observing)
        client.unregister(worktreeId: worktreeId)
        client.unregister(worktreeId: worktreeId)

        client.shutdown()
    }

    @Test("replacement native registration receives events from its own root")
    func replacementNativeRegistrationReceivesItsOwnRootEvents() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-local-root-change-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let firstRoot = fixtureRoot.appending(path: "first", directoryHint: .isDirectory)
        let replacementRoot = fixtureRoot.appending(path: "replacement", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        let repositoryId = UUIDv7.generate()
        try #require(client.register(worktreeId: worktreeId, repoId: repositoryId, rootPath: firstRoot) == .observing)
        let firstBatch = try await requireNativeRootEvent(client: client, worktreeId: worktreeId, rootPath: firstRoot)
        let canonicalFirstRoot = DarwinFSEventPathCanonicalizer.canonicalURL(firstRoot).path
        #expect(firstBatch.worktreeId == worktreeId)
        #expect(firstBatch.paths.contains { $0.hasPrefix(canonicalFirstRoot + "/") })

        try #require(
            client.register(worktreeId: worktreeId, repoId: repositoryId, rootPath: replacementRoot) == .observing
        )
        let replacementBatch = try await requireNativeRootEvent(
            client: client, worktreeId: worktreeId, rootPath: replacementRoot
        )
        let canonicalReplacementRoot = DarwinFSEventPathCanonicalizer.canonicalURL(replacementRoot).path
        #expect(replacementBatch.worktreeId == worktreeId)
        #expect(replacementBatch.paths.contains { $0.hasPrefix(canonicalReplacementRoot + "/") })
        let firstParticipant = try #require(firstBatch.participant)
        let replacementParticipant = try #require(replacementBatch.participant)
        #expect(replacementParticipant.generation != firstParticipant.generation)
    }

    private func requireNativeRootEvent(
        client: DarwinFSEventStreamClient,
        worktreeId: UUID,
        rootPath: URL
    ) async throws -> FSEventBatch {
        let sentinelPath = rootPath.appending(
            path: "native-stream-ready-\(UUIDv7.generate().uuidString).sentinel"
        )
        let canonicalSentinelPath = DarwinFSEventPathCanonicalizer.canonicalURL(sentinelPath).path
        let observedBatchTask = Task<FSEventBatch?, Never> {
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem else { continue }
                if batch.worktreeId == worktreeId, batch.paths.contains(canonicalSentinelPath) {
                    return batch
                }
            }
            return nil
        }
        try Data("ready".utf8).write(to: sentinelPath)
        return try #require(await observedBatchTask.value)
    }

    @Test("shutdown is idempotent and blocks future registration")
    func shutdownIsIdempotent() async {
        let client = DarwinFSEventStreamClient()
        client.shutdown()
        client.shutdown()

        let outcome = client.register(
            worktreeId: UUID(),
            repoId: UUID(),
            rootPath: URL(fileURLWithPath: "/tmp/darwin-fsevents-post-shutdown-\(UUID().uuidString)")
        )
        #expect(outcome == .unavailable(.clientShutdown))
        client.unregister(worktreeId: UUID())
    }

}
