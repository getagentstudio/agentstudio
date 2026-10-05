import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal safety with real Git")
struct WorktreeRemovalSafetyIntegrationTests {
    @Test("main, current, dirty, evidence, and locked stops preserve repository state")
    func refusesEveryPreflightStopWithoutMutation() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-preflight")
        defer { fixture.destroy() }
        let dirtyPath = try await fixture.addWorktree(branch: "feature/dirty")
        let evidencePath = try await fixture.addWorktree(branch: "feature/evidence")
        let lockedPath = try await fixture.addWorktree(branch: "feature/locked")
        try "changed\n".write(
            to: dirtyPath.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let evidenceFile = evidencePath.appending(path: "tmp/keep.txt")
        try FileManager.default.createDirectory(
            at: evidenceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep evidence".utf8).write(to: evidenceFile)
        let lockedSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == lockedPath.standardizedFileURL.path
            }
        )
        _ = try await fixture.client.lockWorktree(GitLockWorktreeRequest(worktreeID: lockedSnapshot.id, reason: "test"))
        let before = try await removalRepositorySnapshot(fixture.path)
        let runner = WorktreeRemovalRunner(client: fixture.client)

        let cases: [(target: String, caller: URL?, expected: WorktreeStopReason)] = [
            (fixture.path.path, fixture.path, .mainWorktree),
            (dirtyPath.path, dirtyPath, .targetIsCurrent),
            (dirtyPath.path, fixture.path, .dirty),
            (evidencePath.path, fixture.path, .evidenceInTmp),
            (lockedPath.path, fixture.path, .worktreeLocked),
        ]
        for testCase in cases {
            let report = await runner.run(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [testCase.target],
                    callerDirectory: testCase.caller
                )
            )
            guard case .refused(let entry)? = report.entries.first else {
                Issue.record("expected \(testCase.expected) refusal for \(testCase.target), got \(report)")
                continue
            }
            #expect(entry.refusal.reason == testCase.expected)
            #expect(try await removalRepositorySnapshot(fixture.path) == before)
        }
        #expect(try Data(contentsOf: evidenceFile) == Data("keep evidence".utf8))
        #expect(try String(contentsOf: dirtyPath.appending(path: "tracked.txt"), encoding: .utf8) == "changed\n")
    }

    @Test("unknown changes refuse before mutation")
    func failsClosedWhenStatusCannotBeRead() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-status-unknown")
        defer { fixture.destroy() }
        let statusPath = try await fixture.addWorktree(branch: "feature/status-unknown")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let statusReader = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            statusFailurePaths: [statusPath.standardizedFileURL.path]
        )
        let before = try await removalRepositorySnapshot(fixture.path)
        let statusReport = await WorktreeRemovalRunner(client: statusReader).run(
            worktreeRemovalRequest(repository: fixture.path, targets: [statusPath.path], callerDirectory: fixture.path)
        )
        guard case .refused(let statusEntry)? = statusReport.entries.first else {
            Issue.record("expected changesUnknown refusal, got \(statusReport)")
            return
        }
        #expect(statusEntry.refusal.reason == .changesUnknown)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("unknown tmp evidence refuses before mutation")
    func failsClosedWhenEvidenceCannotBeRead() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-evidence-unknown")
        defer { fixture.destroy() }
        let evidencePath = try await fixture.addWorktree(branch: "feature/evidence-unknown")
        let tmpPath = evidencePath.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpPath, withIntermediateDirectories: true)
        try Data("unreadable evidence".utf8).write(to: tmpPath.appending(path: "note.txt"))
        let before = try await removalRepositorySnapshot(fixture.path)
        let originalMode =
            try FileManager.default.attributesOfItem(atPath: tmpPath.path)[.posixPermissions] as? NSNumber
        defer {
            if let originalMode {
                try? FileManager.default.setAttributes([.posixPermissions: originalMode], ofItemAtPath: tmpPath.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: tmpPath.path)
        let evidenceReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path, targets: [evidencePath.path], callerDirectory: fixture.path)
        )
        try FileManager.default.setAttributes([.posixPermissions: originalMode ?? 0o700], ofItemAtPath: tmpPath.path)
        guard case .refused(let evidenceEntry)? = evidenceReport.entries.first else {
            Issue.record("expected evidenceUnknown refusal, got \(evidenceReport)")
            return
        }
        #expect(evidenceEntry.refusal.reason == .evidenceUnknown)
        #expect(try Data(contentsOf: tmpPath.appending(path: "note.txt")) == Data("unreadable evidence".utf8))
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("a fresh index lock is identified and preserved")
    func refusesFreshIndexLockWithoutMutation() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-fresh-lock")
        defer { fixture.destroy() }
        let worktreePath = try await fixture.addWorktree(branch: "feature/fresh-lock")
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktreePath.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let foreignBytes = Data("foreign lock owner\n".utf8)
        try foreignBytes.write(to: lockPath)
        let before = try await removalRepositorySnapshot(fixture.path)

        let report = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path, targets: [worktreePath.path], callerDirectory: fixture.path)
        )

        guard case .refused(let entry)? = report.entries.first,
            case .gitLockHeld(let observation) = entry.refusal.details
        else {
            Issue.record("expected an exact fresh index lock refusal, got \(report)")
            return
        }
        #expect(observation.path == lockPath.standardizedFileURL.path)
        guard case .index(let observedWorktreePath) = observation.resource else {
            Issue.record("expected index resource, got \(observation.resource)")
            return
        }
        #expect(observedWorktreePath.standardizedFileURL.path == worktreePath.standardizedFileURL.path)
        #expect(!observation.looksStale)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("an exact stale index lock can be removed when requested")
    func removesOnlyTheObservedStaleIndexLock() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-stale-lock")
        defer { fixture.destroy() }
        let worktreePath = try await fixture.addWorktree(branch: "feature/stale-lock")
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktreePath.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        try Data("stale lock owner\n".utf8).write(to: lockPath)
        try await setModificationTimeUsingTouch(Date(timeIntervalSinceNow: -300), at: lockPath)
        let staleLockAssessment = WorktreeStaleLockAssessment(
            processProbe: RemovalFixedGitProcessProbe(result: .notFound)
        )

        let report = await WorktreeRemovalRunner(
            client: fixture.client,
            staleLockAssessment: staleLockAssessment
        ).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktreePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                removeStaleLock: true
            )
        )

        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected stale lock removal to proceed, got \(report)")
            return
        }
        #expect(entry.effects.lockResidue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lockPath.path))
        #expect(!FileManager.default.fileExists(atPath: worktreePath.path))
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/stale-lock").isEmpty == false
        )
    }

    @Test("a replacement during the last process probe is preserved and refused")
    func refusesWhenIndexLockIsReplacedDuringFinalProcessProbe() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-replaced-stale-lock")
        defer { fixture.destroy() }
        let worktreePath = try await fixture.addWorktree(branch: "feature/replaced-stale-lock")
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktreePath.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let originalBytes = Data("original stale lock\n".utf8)
        let replacementBytes = Data("replacement stale lock\n".utf8)
        try originalBytes.write(to: lockPath)
        try await setModificationTimeUsingTouch(Date(timeIntervalSinceNow: -300), at: lockPath)
        let before = try await removalRepositorySnapshot(fixture.path)
        let processProbe = ReplacingLockDuringFinalProcessProbe(
            lockPath: lockPath,
            replacementBytes: replacementBytes,
            modificationDate: Date(timeIntervalSinceNow: -300)
        )

        let report = await WorktreeRemovalRunner(
            client: fixture.client,
            staleLockAssessment: WorktreeStaleLockAssessment(processProbe: processProbe)
        ).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktreePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                removeStaleLock: true
            )
        )

        #expect(processProbe.didReplaceDuringProbe)
        guard case .refused(let entry)? = report.entries.first,
            case .gitLockHeld(let observation) = entry.refusal.details
        else {
            Issue.record("expected replacement lock refusal, got \(report)")
            return
        }
        #expect(observation.path == lockPath.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: worktreePath.path))
        #expect(try Data(contentsOf: lockPath) == replacementBytes)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("dry-run reports but does not remove an exact stale index lock")
    func previewsStaleIndexLockWithoutMutation() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-preview-stale-lock")
        defer { fixture.destroy() }
        let worktreePath = try await fixture.addWorktree(branch: "feature/preview-stale-lock")
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktreePath.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let lockBytes = Data("would remove only this lock\n".utf8)
        try lockBytes.write(to: lockPath)
        try await setModificationTimeUsingTouch(Date(timeIntervalSinceNow: -300), at: lockPath)
        let staleLockAssessment = WorktreeStaleLockAssessment(
            processProbe: RemovalFixedGitProcessProbe(result: .notFound)
        )
        let before = try await removalRepositorySnapshot(fixture.path)

        let report = await WorktreeRemovalRunner(
            client: fixture.client,
            staleLockAssessment: staleLockAssessment
        ).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktreePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                removeStaleLock: true,
                dryRun: true
            )
        )

        guard case .planned(let entry)? = report.entries.first else {
            Issue.record("expected stale-lock preview plan, got \(report)")
            return
        }
        let checksStep = entry.plan.steps.first { $0.kind == .checks }
        #expect(checksStep?.detail == "would remove stale lock \(lockPath.standardizedFileURL.path)")
        #expect(try Data(contentsOf: lockPath) == lockBytes)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
        #expect(FileManager.default.fileExists(atPath: worktreePath.path))
    }

    @Test("archive destination collisions and paths inside the worktree stop before copying")
    func refusesUnsafeArchiveDestinations() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-destination")
        defer { fixture.destroy() }
        let existingDestinationPath = try await fixture.addWorktree(branch: "feature/archive-existing")
        let insideDestinationPath = try await fixture.addWorktree(branch: "feature/archive-inside")
        let existingTmpFile = try addEvidence("existing", to: existingDestinationPath)
        let insideTmpFile = try addEvidence("inside", to: insideDestinationPath)
        let archiveRoot = fixture.path.appending(path: "archives", directoryHint: .isDirectory)
        let existingDestination = archiveRoot.appending(
            path: existingDestinationPath.lastPathComponent,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: existingDestination, withIntermediateDirectories: true)
        let before = try await removalRepositorySnapshot(fixture.path)

        let existingReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [existingDestinationPath.path],
                callerDirectory: fixture.path,
                evidencePolicy: .archive(to: archiveRoot)
            )
        )
        guard case .refused(let existingEntry)? = existingReport.entries.first else {
            Issue.record("expected archiveDestinationExists, got \(existingReport)")
            return
        }
        #expect(existingEntry.refusal.reason == .archiveDestinationExists)
        #expect(try Data(contentsOf: existingTmpFile) == Data("existing".utf8))

        let insideArchiveRoot = insideDestinationPath.appending(path: "archives", directoryHint: .isDirectory)
        let insideReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [insideDestinationPath.path],
                callerDirectory: fixture.path,
                evidencePolicy: .archive(to: insideArchiveRoot)
            )
        )
        guard case .refused(let insideEntry)? = insideReport.entries.first else {
            Issue.record("expected archiveDestinationInsideWorktree, got \(insideReport)")
            return
        }
        #expect(insideEntry.refusal.reason == .archiveDestinationInsideWorktree)
        #expect(try Data(contentsOf: insideTmpFile) == Data("inside".utf8))
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("an unregistered sibling folder is not mistaken for an absent repeat")
    func refusesUnregisteredSiblingFolder() async throws {
        let fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-not-found")
        defer { fixture.destroy() }
        let sibling = fixture.path.deletingLastPathComponent()
            .appending(path: "\(fixture.path.lastPathComponent).feature-unregistered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let before = try await removalRepositorySnapshot(fixture.path)

        let report = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: ["feature/unregistered"],
                callerDirectory: fixture.path
            )
        )

        guard case .refused(let entry)? = report.entries.first else {
            Issue.record("expected notFound refusal, got \(report)")
            return
        }
        #expect(entry.refusal.reason == .notFound)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }
}

private struct RemovalFixedGitProcessProbe: WorktreeGitProcessProbing {
    let result: WorktreeGitProcessProbeResult

    func probe(for purpose: WorktreeGitProcessProbePurpose) -> WorktreeGitProcessProbeResult {
        result
    }
}

private final class ReplacingLockDuringFinalProcessProbe: WorktreeGitProcessProbing, @unchecked Sendable {
    private let stateLock = NSLock()
    private let lockPath: URL
    private let replacementBytes: Data
    private let modificationDate: Date
    private var replacementOccurred = false

    init(lockPath: URL, replacementBytes: Data, modificationDate: Date) {
        self.lockPath = lockPath
        self.replacementBytes = replacementBytes
        self.modificationDate = modificationDate
    }

    var didReplaceDuringProbe: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return replacementOccurred
    }

    func probe(for purpose: WorktreeGitProcessProbePurpose) -> WorktreeGitProcessProbeResult {
        stateLock.lock()
        let shouldReplace = purpose == .removalIdentityRecheck && !replacementOccurred
        stateLock.unlock()
        guard shouldReplace else { return .notFound }

        let originalPath = lockPath.appendingPathExtension("probe-original")
        let replacementPath = lockPath.appendingPathExtension("probe-replacement")
        do {
            try replacementBytes.write(to: replacementPath)
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: replacementPath.path
            )
            try FileManager.default.moveItem(at: lockPath, to: originalPath)
            do {
                try FileManager.default.moveItem(at: replacementPath, to: lockPath)
            } catch {
                try FileManager.default.moveItem(at: originalPath, to: lockPath)
                throw error
            }
            try FileManager.default.removeItem(at: originalPath)
            stateLock.lock()
            replacementOccurred = true
            stateLock.unlock()
            return .notFound
        } catch {
            if FileManager.default.fileExists(atPath: replacementPath.path) {
                try? FileManager.default.removeItem(at: replacementPath)
            }
            if FileManager.default.fileExists(atPath: originalPath.path),
                !FileManager.default.fileExists(atPath: lockPath.path)
            {
                try? FileManager.default.moveItem(at: originalPath, to: lockPath)
            }
            return .found
        }
    }
}
