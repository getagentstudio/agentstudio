import AgentStudioGit
import AgentStudioTestHarness
import AgentStudioTestSupport
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

final class SharedExactItemRealStreamFixture: @unchecked Sendable {
    let firstWorktreeId = UUIDv7.generate()
    let secondWorktreeId = UUIDv7.generate()
    let firstRepositoryPath: URL
    let secondRepositoryPath: URL
    let externalParentPath: String
    let excludesFilePath: URL
    let unrelatedSiblingPath: URL
    let nativeStreamRecorder: NativeSharedExactItemStreamRecorder
    let readRecorder = GitPhysicalReadRecorder()

    private let fixtureRoot: URL
    private let streamClient: DarwinFSEventStreamClient
    private let exactItemParent: SharedExactItemParent
    private let gitClient: AgentStudioGit.LibGit2AgentStudioGitLocalClient

    /// `DarwinFSEventIngressBuffer.events()` is ONE AsyncStream with single-consumer
    /// semantics, and `captureActivityBarrier()` only returns once that consumer
    /// acknowledges its fence. So the fixture owns the consumer for its whole life:
    /// it acks fences, and forwards everything else into an unbounded stream the
    /// tests' collectors read. Unbounded because items that arrive before a
    /// collector starts must be buffered, not dropped.
    private let forwardedIngress: AsyncStream<FSEventIngressItem>
    private let forwardedIngressContinuation: AsyncStream<FSEventIngressItem>.Continuation
    private var ingressTask: Task<Void, Never>?
    private var sentinelWriteSequence = 0

    init(nativeSharedStreamIsEnabled: Bool) async throws {
        fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-shared-real-stream-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        firstRepositoryPath = fixtureRoot.appending(path: "first-repository", directoryHint: .isDirectory)
        secondRepositoryPath = fixtureRoot.appending(path: "second-repository", directoryHint: .isDirectory)
        let externalParent = fixtureRoot.appending(path: "external", directoryHint: .isDirectory)
        exactItemParent = SharedExactItemParent(initialURL: externalParent)
        unrelatedSiblingPath = externalParent.appending(path: "unrelated.txt")
        excludesFilePath = externalParent.appending(path: "global-excludes")

        do {
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
            try "ignored.txt\n".write(
                to: excludesFilePath,
                atomically: true,
                encoding: .utf8
            )
            try await Self.initializeRepository(
                at: firstRepositoryPath,
                excludesFilePath: excludesFilePath
            )
            try await Self.initializeRepository(
                at: secondRepositoryPath,
                excludesFilePath: excludesFilePath
            )
        } catch {
            try? FileManager.default.removeItem(at: fixtureRoot)
            throw error
        }

        externalParentPath = DarwinFSEventPathCanonicalizer.canonicalURL(externalParent).path
        nativeStreamRecorder = NativeSharedExactItemStreamRecorder(
            nativeSharedStreamIsEnabled: nativeSharedStreamIsEnabled
        )
        streamClient = DarwinFSEventStreamClient(
            sharedExactItemStreamFactory: nativeStreamRecorder.makeStream
        )
        gitClient = AgentStudioGit.LibGit2AgentStudioGitLocalClient()

        let (forwardedIngress, forwardedIngressContinuation) = AsyncStream.makeStream(
            of: FSEventIngressItem.self,
            bufferingPolicy: .unbounded
        )
        self.forwardedIngress = forwardedIngress
        self.forwardedIngressContinuation = forwardedIngressContinuation
        // Started BEFORE the streams are registered, so no item can arrive with
        // nobody draining the ingress.
        ingressTask = Task { [streamClient, forwardedIngressContinuation] in
            for await ingressItem in streamClient.events() {
                if case .activityProcessingFence(let fenceID) = ingressItem {
                    streamClient.acknowledgeActivityProcessingFence(fenceID)
                    continue
                }
                forwardedIngressContinuation.yield(ingressItem)
            }
            forwardedIngressContinuation.finish()
        }

        _ = streamClient.register(
            worktreeId: firstWorktreeId,
            repoId: UUIDv7.generate(),
            rootPath: firstRepositoryPath
        )
        _ = streamClient.register(
            worktreeId: secondWorktreeId,
            repoId: UUIDv7.generate(),
            rootPath: secondRepositoryPath
        )
        do {
            try await installIntendedObservationBindings()
        } catch {
            remove()
            throw error
        }
    }

    func collectFullGitRefreshBatches(
        expectedWorktreeIds: Set<UUID>
    ) -> Task<[UUID: FSEventBatch], Never> {
        // Reads the fixture's forwarded stream, not the client's: fences are
        // already acknowledged by the long-lived consumer, so none reach here.
        let forwardedIngress = forwardedIngress
        return Task {
            var batchByWorktreeId: [UUID: FSEventBatch] = [:]
            for await ingressItem in forwardedIngress {
                guard case .batch(let batch) = ingressItem else { continue }
                guard expectedWorktreeIds.contains(batch.worktreeId) else { continue }
                guard batch.requiresFullGitRefresh else { continue }
                batchByWorktreeId[batch.worktreeId] = batch
                if batchByWorktreeId.keys.count == expectedWorktreeIds.count {
                    return batchByWorktreeId
                }
            }
            return batchByWorktreeId
        }
    }

    func armLocalSentinelCallback(
        at sentinelPath: URL,
        for worktreeId: UUID
    ) -> Task<FSEventBatch?, Never> {
        let expectedPath = DarwinFSEventPathCanonicalizer.canonicalURL(sentinelPath).path
        let forwardedIngress = forwardedIngress
        return Task {
            for await ingressItem in forwardedIngress {
                guard case .batch(let batch) = ingressItem,
                    batch.worktreeId == worktreeId,
                    batch.paths.contains(where: {
                        DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath($0)
                            == expectedPath
                    })
                else {
                    continue
                }
                return batch
            }
            return nil
        }
    }

    /// Captures the production activity fence for the currently installed streams.
    /// It checks the bindings and activity already delivered through the fence; a
    /// later callback can still report earlier filesystem activity.
    func awaitActivityBarrier() async -> Bool {
        await captureActivityBarrier() != nil
    }

    private func captureActivityBarrier() async -> FSEventActivityBarrier? {
        guard let barrier = await streamClient.captureActivityBarrier() else { return nil }

        let expectedWorktreeIds: Set<UUID> = [firstWorktreeId, secondWorktreeId]
        let localBindings = barrier.bindings.filter {
            $0.participant.scopeKey == "local:\($0.worktreeId.uuidString)"
        }
        guard Set(localBindings.map(\.worktreeId)) == expectedWorktreeIds else { return nil }

        let currentParentPath = DarwinFSEventPathCanonicalizer.canonicalURL(
            exactItemParent.currentURL
        ).path
        guard
            let volumeSystemNumber = DarwinFSEventBindingPlanner.volumeSystemNumber(
                for: currentParentPath
            )
        else { return nil }
        let expectedSharedScopeKey = "shared:\(volumeSystemNumber):\(currentParentPath)"
        let sharedBindings = barrier.bindings.filter {
            $0.participant.scopeKey == expectedSharedScopeKey
        }
        guard Set(sharedBindings.map(\.worktreeId)) == expectedWorktreeIds else { return nil }
        guard Set(sharedBindings.map(\.participant)).count == 1 else { return nil }
        return barrier
    }

    /// Drives real activity through each freshly bound stream and waits for it to
    /// come back.
    ///
    /// Initially and after `rebindWorktreeRegistrations()`, the sentinel proves
    /// each local stream delivers real events. The final activity barrier checks
    /// that current local and shared coverage is quiescent; exact authority belongs
    /// to the subsequent status read's prepare/commit sequence.
    func awaitLocalStreamSentinelBarrier() async throws -> Bool {
        sentinelWriteSequence += 1
        let sentinelPathByWorktreeId = [
            firstWorktreeId: Self.sentinelPath(in: firstRepositoryPath),
            secondWorktreeId: Self.sentinelPath(in: secondRepositoryPath),
        ]
        let batchTask = collectLocalSentinelBatches(
            expectedPathByWorktreeId: sentinelPathByWorktreeId.mapValues {
                DarwinFSEventPathCanonicalizer.canonicalURL($0).path
            }
        )

        for sentinelPath in sentinelPathByWorktreeId.values {
            try "sentinel \(sentinelWriteSequence)\n".write(
                to: sentinelPath,
                atomically: false,
                encoding: .utf8
            )
        }

        let observedWorktreeIds = await batchTask.value
        return observedWorktreeIds == Set(sentinelPathByWorktreeId.keys)
    }

    private func collectLocalSentinelBatches(
        expectedPathByWorktreeId: [UUID: String]
    ) -> Task<Set<UUID>, Never> {
        let forwardedIngress = forwardedIngress
        return Task {
            var observedWorktreeIds: Set<UUID> = []
            for await ingressItem in forwardedIngress {
                guard case .batch(let batch) = ingressItem else { continue }
                guard let expectedPath = expectedPathByWorktreeId[batch.worktreeId] else {
                    continue
                }
                guard
                    batch.paths.contains(where: {
                        DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath($0) == expectedPath
                    })
                else {
                    continue
                }
                observedWorktreeIds.insert(batch.worktreeId)
                if observedWorktreeIds.count == expectedPathByWorktreeId.count {
                    return observedWorktreeIds
                }
            }
            return observedWorktreeIds
        }
    }

    private static func sentinelPath(in repositoryPath: URL) -> URL {
        repositoryPath
            .appending(path: ".git", directoryHint: .isDirectory)
            .appending(path: "agentstudio-real-stream-sentinel")
    }

    func waitForNativeCallback(at path: URL) async -> Bool {
        let expectedPath = DarwinFSEventPathCanonicalizer.canonicalURL(path).path
        let callbackTask = Task {
            await nativeStreamRecorder.waitForCallback(at: expectedPath)
            return true
        }
        return await callbackTask.value
    }

    func waitForNativeCallbackUnderExternalParent() async -> Bool {
        let callbackTask = Task {
            await nativeStreamRecorder.waitForCallback(under: externalParentPath)
            return true
        }
        return await callbackTask.value
    }

    func waitForNativeRootChangedCallback() async -> Bool {
        let callbackTask = Task {
            await nativeStreamRecorder.waitForRootChangedCallback()
            return true
        }
        return await callbackTask.value
    }

    func perform(_ mutation: SharedExactItemReplacementMutation) throws {
        switch mutation {
        case .delete:
            try FileManager.default.removeItem(at: excludesFilePath)
        case .rename:
            try FileManager.default.moveItem(
                at: excludesFilePath,
                to: excludesFilePath.deletingLastPathComponent().appending(
                    path: "renamed-excludes"
                )
            )
        case .atomicReplacement:
            try "ignored.txt\nanother-ignored.txt\n".write(
                to: excludesFilePath,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func replaceExternalParent() throws -> URL {
        let replacementParent = fixtureRoot.appending(
            path: "external-replacement",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(
            at: excludesFilePath.deletingLastPathComponent(),
            to: replacementParent
        )
        return replacementParent
    }

    func pointRepositoriesToExternalParent(_ replacementParent: URL) async throws {
        let replacementExcludes = replacementParent.appending(path: excludesFilePath.lastPathComponent)
        for repositoryPath in [firstRepositoryPath, secondRepositoryPath] {
            let git = IsolatedGitProcess(repositoryPath: repositoryPath)
            try await git.run(["config", "core.excludesFile", replacementExcludes.path])
        }
        exactItemParent.replace(with: replacementParent)
    }

    func rebindWorktreeRegistrations() async throws {
        for (worktreeId, repositoryPath) in [
            (firstWorktreeId, firstRepositoryPath),
            (secondWorktreeId, secondRepositoryPath),
        ] {
            streamClient.unregister(worktreeId: worktreeId)
            _ = streamClient.register(
                worktreeId: worktreeId,
                repoId: UUIDv7.generate(),
                rootPath: repositoryPath
            )
        }
        try await installIntendedObservationBindings()
    }

    func remove() {
        streamClient.shutdown()
        ingressTask?.cancel()
        ingressTask = nil
        forwardedIngressContinuation.finish()
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private static func initializeRepository(
        at repositoryPath: URL,
        excludesFilePath: URL
    ) async throws {
        try FileManager.default.createDirectory(at: repositoryPath, withIntermediateDirectories: true)
        let git = IsolatedGitProcess(repositoryPath: repositoryPath)
        try await git.run(["init"])
        try "initial\n".write(
            to: repositoryPath.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await git.run(["add", "README.md"])
        try await git.run(["commit", "-m", "initial"])
        try await git.run(["config", "core.excludesFile", excludesFilePath.path])
    }

    private func installIntendedObservationBindings() async throws {
        for (worktreeId, repositoryPath) in [
            (firstWorktreeId, firstRepositoryPath),
            (secondWorktreeId, secondRepositoryPath),
        ] {
            let observationPlan = try await Self.validatedObservationPlan(
                repositoryPath: repositoryPath,
                exactItemName: excludesFilePath.lastPathComponent,
                exactItemParent: exactItemParent,
                gitClient: gitClient,
                readRecorder: readRecorder
            )
            _ = await streamClient.prepare(
                worktreeId: worktreeId,
                rootPath: repositoryPath,
                observationPlan: observationPlan
            )
        }
    }

    private static func validatedObservationPlan(
        repositoryPath: URL,
        exactItemName: String,
        exactItemParent: SharedExactItemParent,
        gitClient: AgentStudioGit.LibGit2AgentStudioGitLocalClient,
        readRecorder: GitPhysicalReadRecorder
    ) async throws -> AgentStudioGit.GitStatusObservationPlan {
        let observationPlan = try await filteredObservationPlan(
            repositoryPath: repositoryPath,
            exactItemParent: exactItemParent,
            gitClient: gitClient,
            readRecorder: readRecorder
        )
        guard observationPlan.support == .supported else {
            throw SharedExactItemFixtureSetupError(
                reason: "Git status observation is unsupported for the fixture repository"
            )
        }

        let canonicalRepositoryPath = DarwinFSEventPathCanonicalizer.canonicalURL(
            repositoryPath
        ).path
        let expectedExactItemPath = DarwinFSEventPathCanonicalizer.canonicalURL(
            exactItemParent.currentURL.appending(path: exactItemName)
        ).path
        guard
            observationPlan.scopes.contains(where: {
                $0.kind == .subtree
                    && DarwinFSEventPathCanonicalizer.canonicalURL($0.path).path
                        == canonicalRepositoryPath
            }),
            observationPlan.scopes.contains(where: {
                $0.kind == .item
                    && DarwinFSEventPathCanonicalizer.canonicalURL($0.path).path
                        == expectedExactItemPath
            })
        else {
            throw SharedExactItemFixtureSetupError(
                reason: "Git status observation omitted the fixture repository or current excludes item"
            )
        }
        return observationPlan
    }

    private static func filteredObservationPlan(
        repositoryPath: URL,
        exactItemParent: SharedExactItemParent,
        gitClient: AgentStudioGit.LibGit2AgentStudioGitLocalClient,
        readRecorder: GitPhysicalReadRecorder
    ) async throws -> AgentStudioGit.GitStatusObservationPlan {
        readRecorder.recordObservationPlanRead()
        let resolvedPlan = try await gitClient.statusObservationPlan(for: repositoryPath)
        let canonicalRepositoryPath = DarwinFSEventPathCanonicalizer.canonicalURL(
            repositoryPath
        ).path
        let currentExactItemParent = exactItemParent.currentURL
        let productionScopes = resolvedPlan.scopes.filter { scope in
            switch scope.kind {
            case .item:
                path(scope.path, isWithin: currentExactItemParent)
            case .subtree:
                DarwinFSEventPathCanonicalizer.canonicalURL(scope.path).path
                    == canonicalRepositoryPath
            }
        }
        return AgentStudioGit.GitStatusObservationPlan(
            identity: AgentStudioGit.GitStatusObservationIdentity(
                rawValue:
                    productionScopes
                    .map { "\($0.kind.rawValue):\($0.path.path)" }
                    .sorted()
                    .joined(separator: "\u{0}")
            ),
            scopes: productionScopes,
            support: resolvedPlan.support
        )
    }

    private static func path(_ candidate: URL, isWithin root: URL) -> Bool {
        let canonicalCandidate = DarwinFSEventPathCanonicalizer.canonicalURL(candidate).path
        let canonicalRoot = DarwinFSEventPathCanonicalizer.canonicalURL(root).path
        return canonicalCandidate == canonicalRoot
            || canonicalCandidate.hasPrefix(canonicalRoot + "/")
    }
}

private struct SharedExactItemFixtureSetupError: Error {
    let reason: String
}

final class SharedExactItemParent: @unchecked Sendable {
    private let lock = NSLock()
    private var parentURL: URL

    init(initialURL: URL) {
        parentURL = initialURL
    }

    var currentURL: URL {
        lock.withLock { parentURL }
    }

    func replace(with replacementURL: URL) {
        lock.withLock {
            parentURL = replacementURL
        }
    }
}

struct GitPhysicalReadSnapshot: Sendable, Equatable {
    let observationPlanReadCount: Int
    let verifiedFactsReadCount: Int
    let ordinaryFactsReadCount: Int
    let lineDetailReadCount: Int
    let completeStatusReadCount: Int
}

final class GitPhysicalReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observationPlanReadCount = 0
    private var verifiedFactsReadCount = 0
    private var ordinaryFactsReadCount = 0
    private var lineDetailReadCount = 0
    private var completeStatusReadCount = 0

    var snapshot: GitPhysicalReadSnapshot {
        lock.withLock {
            GitPhysicalReadSnapshot(
                observationPlanReadCount: observationPlanReadCount,
                verifiedFactsReadCount: verifiedFactsReadCount,
                ordinaryFactsReadCount: ordinaryFactsReadCount,
                lineDetailReadCount: lineDetailReadCount,
                completeStatusReadCount: completeStatusReadCount
            )
        }
    }

    func recordObservationPlanRead() {
        lock.withLock { observationPlanReadCount += 1 }
    }

    func recordVerifiedFactsRead() {
        lock.withLock { verifiedFactsReadCount += 1 }
    }

    func recordOrdinaryFactsRead() {
        lock.withLock { ordinaryFactsReadCount += 1 }
    }

    func recordLineDetailRead() {
        lock.withLock { lineDetailReadCount += 1 }
    }

    func recordCompleteStatusRead() {
        lock.withLock { completeStatusReadCount += 1 }
    }
}

private struct IsolatedGitProcess {
    let repositoryPath: URL

    func run(_ arguments: [String]) async throws {
        let repositoryPath = repositoryPath
        let git = try await TestToolResolver.resolved().git
        try await withoutBlockingCooperativePool {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "darwin-real-stream-git-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let stderrURL = outputDirectory.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderrHandle.close() }

            let process = Process()
            process.executableURL = git
            process.arguments =
                [
                    "-c", "user.name=AgentStudio Test",
                    "-c", "user.email=agentstudio@example.invalid",
                    "-c", "commit.gpgsign=false",
                    "-c", "init.defaultBranch=main",
                ] + arguments
            process.currentDirectoryURL = repositoryPath
            process.environment = ProcessInfo.processInfo.environment.merging(
                [
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_CONFIG_XDG": "/dev/null",
                    "GIT_TERMINAL_PROMPT": "0",
                    "LC_ALL": "C",
                ]
            ) { _, testValue in testValue }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrHandle

            try TestToolResolver.launch(process)
            process.waitUntilExit()
            TestToolResolver.recordFailedExit(process)
            try stderrHandle.close()

            guard process.terminationStatus == 0 else {
                let errorText = try String(contentsOf: stderrURL, encoding: .utf8)
                throw IsolatedGitProcessError(
                    arguments: arguments,
                    exitCode: process.terminationStatus,
                    errorText: errorText
                )
            }
        }
    }
}

private struct IsolatedGitProcessError: Error {
    let arguments: [String]
    let exitCode: Int32
    let errorText: String
}

extension NativeSharedExactItemStreamRecorder {
    func waitForCallback(at expectedPath: String) async {
        _ = await waitForCallbackEvent(at: expectedPath)
    }

    func waitForCallbackEvent(at expectedPath: String) async -> UInt64? {
        for await event in callbackEvents {
            guard
                DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath(event.path)
                    == expectedPath
            else {
                continue
            }
            return UInt64(event.eventId)
        }
        return nil
    }

    func waitForCallback(under parentPath: String) async {
        for await event in callbackEvents {
            let normalizedPath = DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath(
                event.path
            )
            if normalizedPath == parentPath || normalizedPath.hasPrefix(parentPath + "/") {
                return
            }
        }
    }

    func waitForRootChangedCallback() async {
        for await event in callbackEvents
        where event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            return
        }
    }
}
