import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree listing lock observations with real Git")
struct WorktreeListingLockIntegrationTests {
    @Test("fresh and stale index locks block removal with only eligible options")
    func listsFreshAndStaleIndexLockBlockers() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-list-index-lock")
        defer { fixture.destroy() }
        let worktreePath = try await fixture.addWorktree(branch: "feature/index-lock")
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktreePath.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let foreignBytes = Data("active index writer\n".utf8)
        try foreignBytes.write(to: lockPath)
        let runner = WorktreeOperationRunner(
            client: fixture.client,
            staleLockAssessment: WorktreeStaleLockAssessment(
                processProbe: ListingFixedGitProcessProbe(result: .notFound)
            )
        )

        let freshOutcome = await runner.run(
            .list(start: fixture.path, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let freshListing) = freshOutcome,
            let freshRow = freshListing.worktrees.first(where: { $0.branch == "feature/index-lock" })
        else {
            Issue.record("expected the fresh-lock worktree row, got \(freshOutcome)")
            return
        }
        let mainRow = try #require(freshListing.worktrees.first(where: { $0.isMain }))
        #expect(mainRow.blockers.map(\.reason) == [.mainWorktree])
        #expect(freshRow.changes.status == .clean)
        #expect(freshRow.blockers.map(\.reason) == [.gitLockHeld])
        #expect(!freshRow.removable)
        #expect(freshRow.remove == nil)
        guard case .gitLockHeld(let freshObservation) = freshRow.blockers[0].details else {
            Issue.record("expected an exact index lock observation, got \(freshRow.blockers)")
            return
        }
        #expect(freshObservation.path == lockPath.standardizedFileURL.path)
        #expect(freshObservation.resource == .index(worktreePath: snapshot.canonicalPath))
        #expect(!freshObservation.looksStale)
        #expect(freshRow.blockers[0].options.map(\.action) == [.command("retry")])
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        let freshJSON = try WorktreeCommandLineFormatter.format(outcome: freshOutcome, usesJSONOutput: true)
        #expect(freshJSON.exitCode == 0)
        #expect(freshJSON.text.contains(#""reason":"gitLockHeld""#))
        #expect(freshJSON.text.contains(lockPath.standardizedFileURL.path))
        #expect(freshJSON.text.contains(#""remove":null"#))

        try await setModificationTimeUsingTouch(Date(timeIntervalSinceNow: -300), at: lockPath)
        let staleOutcome = await runner.run(
            .list(start: fixture.path, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let staleListing) = staleOutcome,
            let staleRow = staleListing.worktrees.first(where: { $0.branch == "feature/index-lock" }),
            case .gitLockHeld(let staleObservation) = staleRow.blockers.first?.details
        else {
            Issue.record("expected the stale index lock observation, got \(staleOutcome)")
            return
        }
        #expect(staleObservation.looksStale)
        #expect(staleRow.blockers[0].options.map(\.action) == [.command("retry"), .flag("--remove-stale-lock")])
        #expect(!staleRow.removable)
        #expect(staleRow.remove == nil)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        let staleJSON = try WorktreeCommandLineFormatter.format(outcome: staleOutcome, usesJSONOutput: true)
        #expect(staleJSON.text.contains(#""flag":"--remove-stale-lock""#))
    }

    @Test("integrated branch ref and packed-refs locks block the removal command")
    func listsBranchAndPackedRefsLockBlockers() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-list-reference-lock")
        defer { fixture.destroy() }
        let branchName = "feature/reference-lock"
        let worktreePath = try await fixture.addWorktree(branch: branchName)
        let referenceLockPath = fixture.path.appending(path: ".git/refs/heads/feature/reference-lock.lock")
        let packedRefsLockPath = fixture.path.appending(path: ".git/packed-refs.lock")
        let referenceLockBytes = Data("active branch writer\n".utf8)
        let packedRefsLockBytes = Data("active packed refs writer\n".utf8)
        try FileManager.default.createDirectory(
            at: referenceLockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try referenceLockBytes.write(to: referenceLockPath)
        try packedRefsLockBytes.write(to: packedRefsLockPath)
        let runner = WorktreeOperationRunner(
            client: fixture.client,
            staleLockAssessment: WorktreeStaleLockAssessment(
                processProbe: ListingFixedGitProcessProbe(result: .notFound)
            )
        )

        let outcome = await runner.run(
            .list(start: fixture.path, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let listing) = outcome,
            let row = listing.worktrees.first(where: { $0.branch == branchName })
        else {
            Issue.record("expected the branch-lock worktree row, got \(outcome)")
            return
        }
        #expect(row.integration == .integrated(.sameCommit))
        #expect(row.blockers.map(\.reason) == [.gitLockHeld, .gitLockHeld])
        guard row.blockers.count == 2,
            case .gitLockHeld(let referenceObservation) = row.blockers[0].details,
            case .gitLockHeld(let packedRefsObservation) = row.blockers[1].details
        else {
            Issue.record("expected reference then packed-refs lock observations, got \(row.blockers)")
            return
        }
        #expect(referenceObservation.path == referenceLockPath.standardizedFileURL.path)
        #expect(referenceObservation.resource == .reference(name: "refs/heads/\(branchName)"))
        #expect(!referenceObservation.looksStale)
        #expect(packedRefsObservation.path == packedRefsLockPath.standardizedFileURL.path)
        #expect(packedRefsObservation.resource == .packedRefs)
        #expect(!packedRefsObservation.looksStale)
        #expect(row.blockers.allSatisfy { $0.options.map(\.action) == [.command("retry")] })
        #expect(!row.removable)
        #expect(row.remove == nil)
        #expect(try Data(contentsOf: referenceLockPath) == referenceLockBytes)
        #expect(try Data(contentsOf: packedRefsLockPath) == packedRefsLockBytes)
        #expect(FileManager.default.fileExists(atPath: worktreePath.path))
    }
}

private struct ListingFixedGitProcessProbe: WorktreeGitProcessProbing {
    let result: WorktreeGitProcessProbeResult

    func probe(for purpose: WorktreeGitProcessProbePurpose) -> WorktreeGitProcessProbeResult {
        result
    }
}
