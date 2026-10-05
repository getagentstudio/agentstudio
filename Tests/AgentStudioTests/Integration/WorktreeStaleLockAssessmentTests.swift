import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree stale lock assessment")
struct WorktreeStaleLockAssessmentTests {
    @Test("removes only an old lock whose identity is unchanged")
    func removesTheInspectedStaleLock() throws {
        let fixture = try LockFixture.make()
        defer { fixture.destroy() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.writeLock(modifiedAt: Date(timeIntervalSince1970: 1_799_999_800), contents: "old")
        let assessment = WorktreeStaleLockAssessment(processProbe: FixedGitProcessProbe(.notFound))
        let result = assessment.inspect(fixture.fact, now: now)

        #expect(result.observation.path == fixture.lockPath.path)
        #expect(result.observation.ageSeconds >= 120)
        #expect(result.observation.gitProcessFound == false)
        #expect(result.observation.looksStale)
        #expect(assessment.removeIfStillStale(result, lockPath: fixture.lockPath, now: now))
        #expect(FileManager.default.fileExists(atPath: fixture.lockPath.path) == false)
    }

    @Test("leaves a replacement lock and a lock with a git process untouched")
    func protectsReplacementAndActiveLocks() throws {
        let fixture = try LockFixture.make()
        defer { fixture.destroy() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = Date(timeIntervalSince1970: 1_799_999_800)
        try fixture.writeLock(modifiedAt: oldDate, contents: "original")
        let assessment = WorktreeStaleLockAssessment(processProbe: FixedGitProcessProbe(.notFound))
        let oldResult = assessment.inspect(fixture.fact, now: now)
        let movedOriginal = fixture.root.appending(path: "original.lock")
        try FileManager.default.moveItem(at: fixture.lockPath, to: movedOriginal)
        try fixture.writeLock(modifiedAt: oldDate, contents: "replacement")

        #expect(assessment.removeIfStillStale(oldResult, lockPath: fixture.lockPath, now: now) == false)
        #expect(try String(contentsOf: fixture.lockPath, encoding: .utf8) == "replacement")

        let activeAssessment = WorktreeStaleLockAssessment(processProbe: FixedGitProcessProbe(.found))
        let activeResult = activeAssessment.inspect(fixture.fact, now: now)
        #expect(activeResult.observation.gitProcessFound)
        #expect(activeResult.observation.looksStale == false)
        #expect(activeAssessment.removeIfStillStale(activeResult, lockPath: fixture.lockPath, now: now) == false)
        #expect(try String(contentsOf: fixture.lockPath, encoding: .utf8) == "replacement")
    }
}

private struct FixedGitProcessProbe: WorktreeGitProcessProbing {
    let result: WorktreeGitProcessProbeResult

    init(_ result: WorktreeGitProcessProbeResult) {
        self.result = result
    }

    func probe(for purpose: WorktreeGitProcessProbePurpose) -> WorktreeGitProcessProbeResult {
        result
    }
}

private struct LockFixture {
    let root: URL
    let lockPath: URL
    let fact: GitLockFact

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "worktree-stale-lock-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockPath = root.appending(path: "index.lock")
        return Self(
            root: root, lockPath: lockPath, fact: GitLockFact(path: lockPath, resource: .index(worktreePath: root)))
    }

    func writeLock(modifiedAt: Date, contents: String) throws {
        try Data(contents.utf8).write(to: lockPath)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: lockPath.path)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}
