import AgentStudioWorktreeOperations
import Foundation
import Testing

/// LR1's sources and starts, and LR30's fetch outcomes, through the real command line.
extension WorktreeCreationCommandLineIntegrationTests {
    @Test("--from with --from-branch copies that worktree and resets the copy to the start")
    func copiesNamedWorktreeResetToStart() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-from-and-start")
        defer { fixture.destroy() }
        let source = fixture.folder.appending(path: "source")
        try await fixture.git("worktree", "add", "-b", "feature/source", source.path)
        try "work in progress\n".write(to: source.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("branch", "release/start")
        let startTip = try await fixture.commitLocally("release/start", file: "start.txt")

        let destination = try fixture.destination(for: "feature/reset")
        let run = await fixture.runNew(
            "feature/reset", ["-c", "--from", source.path, "--from-branch", "release/start"], json: true)
        #expect(run.exit == 0, "\(run.output)")
        let document = try run.created()
        #expect(document.materialization?.kind == "copyOnWrite")
        #expect(document.materialization?.sourceState == "reset")
        #expect(document.start.commit == startTip)
        #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == startTip)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "start.txt").path))
        // The source's work in progress belongs to its own branch, so the reset leaves it out.
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "wip.txt").path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "wip.txt").path))
    }

    @Test("--no-fork checks out tracked files at the same start the fork would use, for each form")
    func checksOutAtTheForkStart() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-no-fork")
        defer { fixture.destroy() }
        // The main worktree sits on another branch, so its HEAD differs from origin's main.
        try await fixture.git("checkout", "-b", "feature/main-source")
        try "main source\n".write(to: fixture.repository.appending(path: "main.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("add", "main.txt")
        try await fixture.git("commit", "-m", "main source")
        let mainSourceHead = try await fixture.git("rev-parse", "HEAD")
        let linked = fixture.folder.appending(path: "linked")
        try await fixture.git("worktree", "add", "-b", "feature/linked", linked.path, "main")
        try "linked\n".write(to: linked.appending(path: "linked.txt"), atomically: true, encoding: .utf8)
        try await WorktreeCreationRemoteFixture.git(linked, "add", "linked.txt")
        try await WorktreeCreationRemoteFixture.git(linked, "commit", "-m", "linked")
        let linkedHead = try await WorktreeCreationRemoteFixture.git(linked, "rev-parse", "HEAD")
        let originTip = try await fixture.advance("release/origin", file: "origin.txt")
        try await fixture.git("branch", "feature/behind", "main")
        let behindTip = try await fixture.advance("feature/behind", file: "behind.txt")
        let plainOriginTip = try await fixture.advance("feature/plain-origin", file: "plain-origin.txt")

        let cases = [
            WorktreeCreationLineCase("feature/plain", ["-c", "--no-fork"], mainSourceHead, "checkout"),
            WorktreeCreationLineCase(
                "feature/plain-from", ["-c", "--no-fork", "--from", linked.path], linkedHead, "checkout"),
            WorktreeCreationLineCase(
                "feature/plain-start", ["-c", "--no-fork", "--from-branch", "release/origin"], originTip,
                "checkout; from origin/release/origin"),
            WorktreeCreationLineCase(
                "feature/behind", ["--no-fork"], behindTip,
                "checkout; existing branch; fast-forwarded to origin/feature/behind"),
            WorktreeCreationLineCase(
                "feature/plain-origin", ["--no-fork"], plainOriginTip, "checkout; from origin/feature/plain-origin"),
        ]
        for testCase in cases {
            let destination = try fixture.destination(for: testCase.branch)
            let run = await fixture.runNew(testCase.branch, testCase.options, json: false)
            #expect(run.exit == 0, "\(testCase.options): \(run.output)")
            #expect(run.line == "created \(testCase.branch) at \(destination.path) (\(testCase.details))")
            #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == testCase.commit)
            #expect(
                try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "--abbrev-ref", "HEAD")
                    == testCase.branch)
        }
        // Step 3 on the checkout path writes the same upstream as the fork (D20).
        #expect(try await fixture.git("config", "branch.feature/plain-origin.remote") == "origin")
        #expect(
            try await fixture.git("config", "branch.feature/plain-origin.merge") == "refs/heads/feature/plain-origin")
    }

    @Test("--no-fetch reads the remote-tracking refs already on disk")
    func noFetchReadsRefsOnDisk() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-no-fetch")
        defer { fixture.destroy() }
        let fetchedTip = try await fixture.advance("feature/stale", file: "first.txt")
        try await fixture.git("fetch", "origin", "+refs/heads/feature/stale:refs/remotes/origin/feature/stale")
        let newerTip = try await fixture.advance("feature/stale", file: "second.txt")
        #expect(newerTip != fetchedTip)

        let run = await fixture.runNew("feature/stale", ["--no-fetch"], json: true)
        #expect(run.exit == 0, "\(run.output)")
        let document = try run.created()
        #expect(
            document.fetch == .init(remote: nil, branch: nil, status: "skipped", commit: nil, reason: "noFetchFlag"))
        #expect(document.start.commit == fetchedTip)
        #expect(document.branch.upstream == "refs/remotes/origin/feature/stale")
        #expect(try await fixture.git("rev-parse", "refs/remotes/origin/feature/stale") == fetchedTip)
    }

    @Test("a failed remote question or fetch continues with the local refs and says so")
    func failedQuestionOrFetchContinuesWithLocalRefs() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-fetch-failed")
        defer { fixture.destroy() }

        // The question fails: origin points at a repository that doesn't exist. A local branch opens as it is.
        try await fixture.git("branch", "feature/unreachable")
        try await fixture.git("branch", "feature/unreachable-human")
        try await fixture.git("remote", "set-url", "origin", fixture.folder.appending(path: "missing.git").path)
        let unreachable = await fixture.runNew("feature/unreachable", json: true)
        #expect(unreachable.exit == 0, "\(unreachable.output)")
        let unreachableDocument = try unreachable.created()
        #expect(unreachableDocument.fetch.status == "failed")
        #expect(unreachableDocument.fetch.remote == "origin")
        #expect(unreachableDocument.fetch.branch == "feature/unreachable")
        #expect(unreachableDocument.branch.status == "existing")
        #expect(unreachableDocument.start.from == "localBranch")
        let reason = try #require(unreachableDocument.fetch.reason)
        let humanDestination = try fixture.destination(for: "feature/unreachable-human")
        let human = await fixture.runNew("feature/unreachable-human", json: false)
        #expect(
            human.line
                == "created feature/unreachable-human at \(humanDestination.path) "
                + "(copy-on-write; existing branch; fetch failed: \(reason); used local refs)")

        // The question succeeds but the fetch fails: a held lock on the remote-tracking ref. The local branch
        // opens as it is.
        try await fixture.git("remote", "set-url", "origin", fixture.origin.path)
        try await fixture.git("branch", "feature/locked", "main")
        try await fixture.advance("feature/locked", file: "locked.txt")
        let lock = fixture.repository.appending(path: ".git/refs/remotes/origin/feature/locked.lock")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let locked = await fixture.runNew("feature/locked", json: true)
        #expect(locked.exit == 0, "\(locked.output)")
        let lockedDocument = try locked.created()
        #expect(lockedDocument.fetch.status == "failed")
        #expect(lockedDocument.fetch.reason == "gitLockHeld")
        // With no remote-tracking ref on disk, the local branch is used as it is.
        #expect(lockedDocument.branch.status == "existing")
        #expect(
            lockedDocument.start
                == .init(
                    commit: fixture.mainCommit, from: "localBranch", ref: "refs/heads/feature/locked",
                    localOnlyCommits: nil))
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }
}
