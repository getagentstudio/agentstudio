import AgentStudioWorktreeOperations
import Foundation
import Testing

enum WorktreeListingIntegrationAssertions {
    static func expectMixedRows(
        _ listing: WorktreeListingSummary,
        repository: URL,
        cleanPath: URL
    ) throws {
        let rowsByBranch = Dictionary(
            uniqueKeysWithValues: listing.worktrees.compactMap { row in row.branch.map { ($0, row) } }
        )
        let main = try #require(rowsByBranch["main"])
        #expect(main.isMain)
        #expect(main.isCurrent)
        #expect(main.integration == nil)
        #expect(main.blockers.map(\.reason) == [.mainWorktree, .targetIsCurrent])

        let clean = try #require(rowsByBranch["feature/clean"])
        #expect(clean.changes.status == .clean)
        #expect(clean.integration == .integrated(.sameCommit))
        #expect(clean.tmp == .empty)
        #expect(clean.removable)
        #expect(
            clean.remove
                == "agentstudio worktree remove --repo \(repository.path) \(cleanPath.path)"
        )

        let dirty = try #require(rowsByBranch["feature/dirty"])
        #expect(dirty.changes.status == .dirty)
        #expect(dirty.tmp == .nonEmpty)
        #expect(dirty.blockers.map(\.reason) == [.dirty, .evidenceInTmp])
        if case .dirty(let details) = dirty.blockers[0].details {
            #expect(details.firstPaths.contains("tracked.txt"))
        } else {
            Issue.record("expected the dirty blocker details, got \(dirty.blockers[0].details)")
        }
        #expect(!dirty.removable)
        #expect(dirty.remove == nil)

        let lockedRow = try #require(rowsByBranch["feature/locked"])
        #expect(lockedRow.isLocked)
        #expect(lockedRow.blockers.map(\.reason) == [.worktreeLocked])
        #expect(!lockedRow.removable)

        let remaining = try #require(rowsByBranch["feature/remaining"])
        #expect(remaining.integration == .hasRemainingContribution)
        #expect(remaining.removable)

        let detached = try #require(listing.worktrees.first(where: { $0.branch == nil }))
        #expect(detached.integration == nil)
        #expect(detached.changes.status == .clean)
        #expect(detached.removable)
    }

    static func expectMixedOutput(_ outcome: WorktreeOperationOutcome) throws {
        let json = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(json.exitCode == 0)
        #expect(json.text.contains(#""remove":null"#))
        #expect(human.text.contains("fetch: skipped (noFetchFlag)"))
        #expect(human.text.contains("integrated (sameCommit)"))
        #expect(human.text.contains("hasRemainingContribution"))
    }

    static func expectTargetAndCurrentDirectoryFiltering(
        runner: WorktreeOperationRunner,
        repository: URL,
        cleanPath: URL
    ) async throws {
        let branchFilter = await runner.run(
            .list(start: repository, callerDirectory: repository, targets: ["feature/clean"], fetchPolicy: .skip)
        )
        guard case .listed(let branchListing) = branchFilter else {
            Issue.record("expected branch-filtered listing, got \(branchFilter)")
            return
        }
        #expect(branchListing.worktrees.map(\.branch) == ["feature/clean"])

        let nestedTarget = cleanPath.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedTarget, withIntermediateDirectories: true)
        let pathFilter = await runner.run(
            .list(
                start: repository,
                callerDirectory: repository,
                targets: ["../\(cleanPath.lastPathComponent)/nested"],
                fetchPolicy: .skip
            )
        )
        guard case .listed(let pathListing) = pathFilter else {
            Issue.record("expected path-filtered listing, got \(pathFilter)")
            return
        }
        #expect(pathListing.worktrees.map(\.branch) == ["feature/clean"])

        let fromLinkedDirectory = await runner.run(
            .list(start: repository, callerDirectory: cleanPath, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let linkedListing) = fromLinkedDirectory else {
            Issue.record("expected listing from a linked worktree, got \(fromLinkedDirectory)")
            return
        }
        #expect(linkedListing.worktrees.first(where: { $0.branch == "feature/clean" })?.isCurrent == true)
        #expect(linkedListing.worktrees.first(where: { $0.branch == "main" })?.isCurrent == false)

        let outsideCaller = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outsideCaller, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideCaller) }
        let fromOutside = await runner.run(
            .list(start: repository, callerDirectory: outsideCaller, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let outsideListing) = fromOutside else {
            Issue.record("expected a listing with --repo selected from outside, got \(fromOutside)")
            return
        }
        #expect(outsideListing.worktrees.allSatisfy { !$0.isCurrent })
    }
}
