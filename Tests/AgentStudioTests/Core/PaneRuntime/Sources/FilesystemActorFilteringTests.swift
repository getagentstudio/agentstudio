import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite(.serialized)
struct FilesystemActorFilteringTests {
    @Test("Unicode prefix spellings retain their distinct batch changeset outcomes", arguments: [true, false])
    func unicodePrefixSpellingsRetainChangesetOutcomes(composedFirst: Bool) async throws {
        // Arrange
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)
        let worktreeId = UUIDv7.generate()
        let rootPath = FileManager.default.temporaryDirectory.appending(path: "unicode-prefix-batch-\(worktreeId)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "caf?\n".write(to: rootPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
        let composedPath = "caf\u{00E9}/first.swift"
        let decomposedPath = "cafe\u{0301}/second.swift"
        let closingPath = "Sources/unicode-close-\(UUIDv7.generate()).swift"
        let projectedPaths = [closingPath, decomposedPath]
        let batchPaths = composedFirst ? [composedPath, decomposedPath] : [decomposedPath, composedPath]
        // Native ingress supplies absolute strings. Avoid the relative-path URL
        // append, which can decompose Unicode before the lexical routing path.
        let rawPaths = (batchPaths + [closingPath]).map { rootPath.path + "/" + $0 }
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let recorder = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, FileChangeset>(
                describeScope: { $0.uuidString }, describeFact: { "changeset \($0.batchSeq): \($0.paths)" },
                isClosing: { _, fact in fact.paths.contains(closingPath) }),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { envelope in
                guard case .worktree(let worktree) = envelope,
                    case .filesystem(.filesChanged(let changeset)) = worktree.event
                else { return nil }
                return (changeset.worktreeId, changeset)
            })
        let opening = await recorder.mark(worktreeId)

        do {
            // Act
            await actor.enqueueRawPaths(worktreeId: worktreeId, paths: rawPaths)

            // Assert: caf? excludes only the composed ancestor. Distinct leaves
            // prevent full-path set equality from concealing a prefix-cache error.
            let closingChangeset = try await recorder.expectNext(
                in: worktreeId, where: { $0.paths.contains(closingPath) }, "Unicode batch changeset close")
            #expect(closingChangeset.paths == projectedPaths)
            #expect(closingChangeset.suppressedIgnoredPathCount == 1)
            try await recorder.expectNone(
                of: {
                    $0.paths != projectedPaths || $0.containsGitInternalChanges || $0.suppressedGitInternalPathCount > 0
                },
                "incorrect Unicode projected paths or Git invalidation", from: opening,
                closedBy: { $0.paths.contains(closingPath) })
        } catch {
            await actor.shutdown()
            try? await recorder.finish()
            throw error
        }
        await actor.shutdown()
        try await recorder.finish()
    }

    @Test("ignored build burst closes with only its projected path")
    func ignoredBuildBurstClosesWithOnlyProjectedPath() async throws {
        // Arrange
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)
        let worktreeId = UUIDv7.generate()
        let rootPath = FileManager.default.temporaryDirectory.appending(path: "ignored-build-burst-\(worktreeId)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try ".build-*/\n".write(to: rootPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
        let closingPath = "Sources/burst-close-\(UUIDv7.generate()).swift"
        let ignoredPaths = (0..<512).map { ".build-agent-1/checkouts/dep/Sources/file-\($0).swift" }
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let recorder = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, FileChangeset>(
                describeScope: { $0.uuidString }, describeFact: { "changeset \($0.batchSeq): \($0.paths)" },
                isClosing: { _, fact in fact.paths.contains(closingPath) }),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { envelope in
                guard case .worktree(let worktree) = envelope,
                    case .filesystem(.filesChanged(let changeset)) = worktree.event
                else { return nil }
                return (changeset.worktreeId, changeset)
            })
        let opening = await recorder.mark(worktreeId)

        do {
            // Act
            await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ignoredPaths + [closingPath])

            // Assert: consume all facts through the correlated real flush, so
            // ignored-only or Git-internal changesets cannot precede the close.
            let closingChangeset = try await recorder.expectNext(
                in: worktreeId, where: { $0.paths.contains(closingPath) }, "build burst changeset close")
            #expect(closingChangeset.paths == [closingPath])
            #expect(closingChangeset.suppressedIgnoredPathCount == ignoredPaths.count)
            try await recorder.expectNone(
                of: {
                    $0.paths != [closingPath] || $0.containsGitInternalChanges || $0.suppressedGitInternalPathCount > 0
                },
                "extra projected paths or Git invalidation in build burst", from: opening,
                closedBy: { $0.paths.contains(closingPath) })
        } catch {
            await actor.shutdown()
            try? await recorder.finish()
            throw error
        }
        await actor.shutdown()
        try await recorder.finish()
    }

    @Test("ignored nested Git ingress emits no Git invalidation through its correlated changeset close")
    func ignoredNestedGitIngressDoesNotInvalidateOwningWorktree() async throws {
        // Arrange
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)
        let worktreeId = UUIDv7.generate()
        let rootPath = FileManager.default.temporaryDirectory.appending(
            path: "ignored-nested-git-\(worktreeId)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try ".build-*\n".write(to: rootPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
        let closingPath = "Sources/ingress-close-\(UUIDv7.generate()).swift"
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let recorder = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, FileChangeset>(
                describeScope: { $0.uuidString },
                describeFact: {
                    "changeset \($0.batchSeq): \($0.paths), Git internal: \($0.containsGitInternalChanges)"
                },
                isClosing: { _, fact in fact.paths.contains(closingPath) }),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { envelope in
                guard case .worktree(let worktree) = envelope,
                    case .filesystem(.filesChanged(let changeset)) = worktree.event
                else { return nil }
                return (changeset.worktreeId, changeset)
            })
        let opening = await recorder.mark(worktreeId)

        do {
            // Act: the included path closes this batch through the owner's real flush.
            await actor.enqueueRawPaths(
                worktreeId: worktreeId,
                paths: [rootPath.appending(path: ".build-agent-1/checkouts/dep/.git/index").path, closingPath])

            // Assert
            try await recorder.expectNone(
                of: { $0.containsGitInternalChanges || $0.suppressedGitInternalPathCount > 0 },
                "Git-internal invalidation from an ignored build checkout", from: opening,
                closedBy: { $0.paths.contains(closingPath) })
        } catch {
            await actor.shutdown()
            try? await recorder.finish()
            throw error
        }
        await actor.shutdown()
        try await recorder.finish()
    }

    @Test("own Git index ingress remains a Git-internal invalidation under build ignore rules")
    func ownGitIndexIngressStillInvalidatesOwningWorktree() async throws {
        // Arrange
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)
        let worktreeId = UUIDv7.generate()
        let rootPath = FileManager.default.temporaryDirectory.appending(path: "own-git-index-\(worktreeId)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try ".build-*\n".write(to: rootPath.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let recorder = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, FileChangeset>(
                describeScope: { $0.uuidString }, describeFact: { "changeset \($0.batchSeq)" },
                isClosing: { _, _ in true }),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: { envelope in
                guard case .worktree(let worktree) = envelope,
                    case .filesystem(.filesChanged(let changeset)) = worktree.event
                else { return nil }
                return (changeset.worktreeId, changeset)
            })

        do {
            // Act
            await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [rootPath.appending(path: ".git/index").path])

            // Assert
            _ = try await recorder.expectNext(
                in: worktreeId,
                where: { $0.containsGitInternalChanges && $0.suppressedGitInternalPathCount == 1 },
                "own Git index changeset")
        } catch {
            await actor.shutdown()
            try? await recorder.finish()
            throw error
        }
        await actor.shutdown()
        try await recorder.finish()
    }

    @Test("path-free full Git invalidation reaches the existing debounced changeset path")
    func pathFreeFullGitInvalidationReachesExistingDebounce() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let fseventStreamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: fseventStreamClient,
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/full-git-invalidation-\(worktreeId.uuidString)")
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        fseventStreamClient.send(
            FSEventBatch(
                worktreeId: worktreeId,
                paths: [],
                requiresFullGitRefresh: true
            )
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(changeset.paths.isEmpty)
        #expect(changeset.containsGitInternalChanges)

        await actor.shutdown()
    }

    @Test("path-free full Git overflow recovery retains its scope through admission")
    func pathFreeFullGitOverflowRecoveryRetainsScope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let fseventStreamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: fseventStreamClient,
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/full-git-overflow-\(worktreeId.uuidString)")
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        fseventStreamClient.sendOverflowRecovery(
            worktreeId: worktreeId,
            paths: [],
            requiresFullGitRefresh: true
        )
        fseventStreamClient.send(
            FSEventBatch(worktreeId: worktreeId, paths: ["Sources/App.swift"])
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(changeset.paths == ["Sources/App.swift"])
        #expect(changeset.containsGitInternalChanges)

        await actor.shutdown()
    }

    @Test("git internal paths are suppressed from projection payload and annotated for downstream sinks")
    func gitInternalPathsAreSuppressedFromProjectionPayload() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/git-internal-\(UUIDv7.generate().uuidString)")
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: worktreeId,
            paths: [".git/index", ".git/objects/aa/bb", "Sources/App.swift"]
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(changeset.paths == ["Sources/App.swift"])
        #expect(changeset.containsGitInternalChanges)
        #expect(changeset.suppressedGitInternalPathCount == 1)
        #expect(changeset.suppressedIgnoredPathCount == 0)

        await actor.shutdown()
    }

    @Test("git object database writes do not become downstream invalidations")
    func gitObjectDatabaseWritesDoNotBecomeDownstreamInvalidations() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/git-objects-\(UUIDv7.generate().uuidString)")
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: worktreeId,
            paths: [".git/objects/aa/bb", "Sources/App.swift"]
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.paths == ["Sources/App.swift"])
        #expect(!changeset.containsGitInternalChanges)
        #expect(changeset.suppressedGitInternalPathCount == 0)

        await actor.shutdown()
    }

    @Test("gitignore policy suppresses ignored paths while preserving included and unignored paths")
    func gitignorePolicySuppressesIgnoredPaths() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "gitignore-filter-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }

        let gitignoreContents = """
            *.log
            build/*
            !build/include.log
            """
        try gitignoreContents.write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: worktreeId,
            paths: ["app.log", "build/out.txt", "build/include.log", "Sources/App.swift", ".git/index"]
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(Set(changeset.paths) == Set(["build/include.log", "Sources/App.swift"]))
        #expect(changeset.containsGitInternalChanges)
        #expect(changeset.suppressedIgnoredPathCount == 2)
        #expect(changeset.suppressedGitInternalPathCount == 1)

        await actor.shutdown()
    }

    @Test("filtered-only changes still emit filesChanged to drive git projector refresh")
    func filteredOnlyChangesStillEmitFilesChangedEvent() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "filtered-only-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "*.tmp\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: worktreeId,
            paths: [".git/index", "cache.tmp"]
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(Set(changeset.paths).isSubset(of: ["."]))
        #expect(changeset.containsGitInternalChanges)
        #expect(changeset.suppressedIgnoredPathCount == 1)
        #expect(changeset.suppressedGitInternalPathCount == 1)

        await actor.shutdown()
    }

    @Test("ignored-only changes do not emit filesChanged envelope")
    func ignoredOnlyChangesDoNotEmitFilesChangedEnvelope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = FilesystemActor(
            bus: bus, fseventStreamClient: ControllableFSEventStreamClient(), sleepClock: TestPushClock(),
            debounceWindow: .zero, maxFlushLatency: .zero)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "ignored-only-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "*.tmp\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let probe = await FilesystemPublicationProbe(bus: bus)
        _ = await probe.begin()

        await actor.enqueueRawPaths(
            worktreeId: worktreeId,
            paths: ["cache.tmp", ".git/FETCH_HEAD"]
        )
        #expect(await actor.pendingWorktreeLogicalDebtCount == 0)

        await actor.shutdown()
        try await probe.closeAfterProducerReturn()
        #expect(probe.changesets.isEmpty)
    }

    @Test("gitignore modification reloads filter for subsequent batches")
    func gitignoreModificationReloadsFilterForSubsequentBatches() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "gitignore-reload-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "*.tmp\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let observed = FilteringObservedFilesystemChanges()
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let collectionTask = Task {
            for await envelope in stream {
                await observed.record(envelope)
            }
        }
        defer { collectionTask.cancel() }

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [".git/index", "cache.tmp"])
        let initialChangeset = await observed.next()
        #expect(initialChangeset.paths.isEmpty)
        #expect(initialChangeset.containsGitInternalChanges)
        #expect(initialChangeset.suppressedIgnoredPathCount == 1)

        try "# no ignore rules\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [".gitignore"])

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["cache.tmp"])
        let nextChangeset = await observed.next()
        let postReloadChangeset: FileChangeset
        if nextChangeset.paths.contains("cache.tmp") {
            postReloadChangeset = nextChangeset
        } else {
            #expect(!nextChangeset.paths.contains(".gitignore"))
            postReloadChangeset = await observed.next()
        }
        #expect(postReloadChangeset.paths.contains("cache.tmp"))
        #expect(!postReloadChangeset.paths.contains(".gitignore"))
        #expect(postReloadChangeset.suppressedIgnoredPathCount == 0)

        await actor.shutdown()
    }

    @Test("gitignore-only modification emits refresh-worthy empty changeset")
    func gitignoreOnlyModificationEmitsRefreshWorthyEmptyChangeset() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "gitignore-only-refresh-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "*.tmp\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        try "# no ignore rules\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [".gitignore"])

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(changeset.paths.isEmpty)
        #expect(changeset.containsGitInternalChanges)
        #expect(changeset.suppressedIgnoredPathCount == 0)
        #expect(changeset.suppressedGitInternalPathCount == 0)

        await actor.shutdown()
    }

    @Test("gitignore reload batch does not leak .gitignore into projected paths when coalesced")
    func gitignoreReloadBatchDoesNotLeakGitignoreIntoProjectedPathsWhenCoalesced() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let rootPath = FileManager.default.temporaryDirectory
            .appending(path: "gitignore-coalesced-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }
        try "*.tmp\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)

        let observed = FilteringObservedFilesystemChanges()
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let collectionTask = Task {
            for await envelope in stream {
                await observed.record(envelope)
            }
        }

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [".git/index", "cache.tmp"])
        let initialChangeset = await observed.next()
        #expect(initialChangeset.paths.isEmpty)
        #expect(initialChangeset.containsGitInternalChanges)
        #expect(initialChangeset.suppressedIgnoredPathCount == 1)

        try "# no ignore rules\n".write(
            to: rootPath.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: [".gitignore", "cache.tmp"])

        let nextChangeset = await observed.next()
        let postReloadChangeset: FileChangeset
        if nextChangeset.paths.contains("cache.tmp") {
            postReloadChangeset = nextChangeset
        } else {
            #expect(!nextChangeset.paths.contains(".gitignore"))
            postReloadChangeset = await observed.next()
        }
        #expect(postReloadChangeset.paths.contains("cache.tmp"))
        #expect(!postReloadChangeset.paths.contains(".gitignore"))
        #expect(postReloadChangeset.suppressedIgnoredPathCount == 0)

        await actor.shutdown()
        collectionTask.cancel()
        await collectionTask.value
    }

    private func filesChangedChangeset(from envelope: RuntimeEnvelope) -> FileChangeset? {
        guard case .worktree(let worktreeEnvelope) = envelope else { return nil }
        guard case .filesystem(.filesChanged(let changeset)) = worktreeEnvelope.event else {
            return nil
        }
        return changeset
    }

    private func makeActor(bus: EventBus<RuntimeEnvelope>) -> FilesystemActor {
        FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
    }
}

private actor FilteringObservedFilesystemChanges {
    private var changesetsByWorktreeId: [UUID: [FileChangeset]] = [:]
    private var pendingChangesets: [FileChangeset] = []
    private var nextWaiters: [CheckedContinuation<FileChangeset, Never>] = []

    func record(_ envelope: RuntimeEnvelope) {
        guard case .worktree(let worktreeEnvelope) = envelope else { return }
        guard case .filesystem(.filesChanged(let changeset)) = worktreeEnvelope.event else { return }
        changesetsByWorktreeId[changeset.worktreeId, default: []].append(changeset)
        if nextWaiters.isEmpty {
            pendingChangesets.append(changeset)
            return
        }

        let waiter = nextWaiters.removeFirst()
        waiter.resume(returning: changeset)
    }

    func filesChangedCount(for worktreeId: UUID) -> Int {
        changesetsByWorktreeId[worktreeId]?.count ?? 0
    }

    func next() async -> FileChangeset {
        if !pendingChangesets.isEmpty {
            return pendingChangesets.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            nextWaiters.append(continuation)
        }
    }
}
