import AgentStudioWorktreeOperations
import Foundation
import Testing

/// LR1 and LR30 through the real command line, against a local bare `origin` and a second bare remote.
extension WorktreeCreationCommandLineIntegrationTests {
    @Test("a new name the remote lacks starts at the source's HEAD after the remote says notOnRemote")
    func createsNewNameAtSourceHead() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-fresh")
        defer { fixture.destroy() }

        let destination = try fixture.destination(for: "feature/fresh")
        let human = await fixture.runNew("feature/fresh", json: false)
        #expect(human.exit == 0)
        #expect(human.line == "created feature/fresh at \(destination.path) (copy-on-write)")

        let json = await fixture.runNew("feature/fresh-json", json: true)
        #expect(json.exit == 0)
        let document = try json.created()
        #expect(document.branch == .init(name: "feature/fresh-json", status: "created", upstream: nil))
        #expect(
            document.start == .init(commit: fixture.mainCommit, from: "sourceHead", ref: nil, localOnlyCommits: nil))
        #expect(
            document.fetch
                == .init(
                    remote: "origin", branch: "feature/fresh-json", status: "notOnRemote", commit: nil, reason: nil))
        #expect(document.materialization?.sourceState == "asIs")
    }

    @Test("a branch deleted on origin is absent even with its old remote-tracking ref still on disk")
    func treatsBranchDeletedOnOriginAsAbsent() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-deleted-on-origin")
        defer { fixture.destroy() }
        let staleTip = try await fixture.advance("feature/gone", file: "gone.txt")
        try await fixture.git("fetch", "origin", "+refs/heads/feature/gone:refs/remotes/origin/feature/gone")
        try await WorktreeCreationRemoteFixture.git(fixture.originClone, "push", "origin", "--delete", "feature/gone")
        #expect(try await fixture.git("rev-parse", "refs/remotes/origin/feature/gone") == staleTip)

        let created = await fixture.runNew("feature/gone", json: true)
        #expect(created.exit == 0)
        let document = try created.created()
        #expect(document.branch == .init(name: "feature/gone", status: "created", upstream: nil))
        #expect(document.start.from == "sourceHead")
        #expect(document.fetch.status == "notOnRemote")
        let destination = try fixture.destination(for: "feature/gone")
        #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == fixture.mainCommit)

        let fromStale = await fixture.runNew("feature/other", ["--from-branch", "origin/feature/gone"], json: true)
        #expect(fromStale.exit == 1)
        #expect(try fromStale.refused().reason == "startBranchNotFound")
        #expect(try fromStale.refused().detail == "origin/feature/gone")
        // The refusal came after the fetch, so it still reports what the remote said.
        #expect(
            try fromStale.refused().fetch
                == .init(remote: "origin", branch: "feature/gone", status: "notOnRemote", commit: nil, reason: nil))
        let otherDestination = try fixture.destination(for: "feature/other")
        #expect(!FileManager.default.fileExists(atPath: otherDestination.path))
    }

    @Test("a same-name --from-branch found nowhere refuses startBranchNotFound instead of creating")
    func refusesSameNameStartFoundNowhere() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-same-name-missing")
        defer { fixture.destroy() }

        for start in ["feature/nowhere", "origin/feature/nowhere"] {
            let run = await fixture.runNew("feature/nowhere", ["--from-branch", start], json: true)
            #expect(run.exit == 1)
            #expect(try run.refused().reason == "startBranchNotFound")
            #expect(try run.refused().detail == start)
        }
        #expect(try await fixture.git("branch", "--list", "feature/nowhere").isEmpty)
    }

    @Test("a branch checked out or bisected in another worktree refuses branchCheckedOut before any fetch")
    func refusesBranchHeldElsewhereBeforeFetching() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-held")
        defer { fixture.destroy() }
        let holder = fixture.folder.appending(path: "holder")
        try await fixture.git("worktree", "add", "-b", "feature/held", holder.path)
        try await fixture.advance("feature/held", file: "held.txt")

        let held = await fixture.runNew("feature/held", json: true)
        #expect(held.exit == 1)
        let refusal = try held.refused()
        #expect(refusal.reason == "branchCheckedOut")
        #expect(refusal.fetch == nil)
        #expect(refusal.path.map(Self.realPath) == Self.realPath(holder.path))
        #expect(
            refusal.options == [
                WorktreeStopOption(
                    action: .command("cd <path>"),
                    effect: "Work in the worktree that already has the branch checked out.")
            ])
        // Nothing was fetched: the repository still has no remote-tracking ref for the branch.
        #expect(try await fixture.git("for-each-ref", "refs/remotes/origin/feature/held").isEmpty)

        let bisecting = fixture.folder.appending(path: "bisecting")
        try await fixture.git("worktree", "add", "-b", "feature/bisected", bisecting.path)
        for file in ["one.txt", "two.txt", "three.txt"] {
            try "\(file)\n".write(to: bisecting.appending(path: file), atomically: true, encoding: .utf8)
            try await WorktreeCreationRemoteFixture.git(bisecting, "add", file)
            try await WorktreeCreationRemoteFixture.git(bisecting, "commit", "-m", file)
        }
        try await WorktreeCreationRemoteFixture.git(bisecting, "bisect", "start", "HEAD", "HEAD~3")
        let bisected = await fixture.runNew("feature/bisected", json: false)
        #expect(bisected.exit == 1)
        #expect(bisected.line?.hasPrefix("refused: branchCheckedOut \(Self.realPath(bisecting.path))") == true)
    }

    @Test("an existing branch opens as it is, fast-forwards when strictly behind, and is kept when diverged")
    func opensExistingBranches() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-existing")
        defer { fixture.destroy() }
        for suffix in ["", "-json"] {
            try await fixture.git("branch", "feature/equal\(suffix)")
            try await fixture.git("push", "origin", "feature/equal\(suffix)")
            try await fixture.git("branch", "feature/behind\(suffix)")
            try await fixture.advance("feature/behind\(suffix)", file: "behind.txt")
            try await fixture.git("branch", "feature/diverged\(suffix)")
            try await fixture.advance("feature/diverged\(suffix)", file: "remote-only.txt")
            try await fixture.commitLocally("feature/diverged\(suffix)", file: "local-only.txt")
        }

        let equalDestination = try fixture.destination(for: "feature/equal")
        let equal = await fixture.runNew("feature/equal", json: false)
        #expect(equal.line == "created feature/equal at \(equalDestination.path) (copy-on-write; existing branch)")
        let equalJSON = try await fixture.runNew("feature/equal-json", json: true).created()
        #expect(equalJSON.branch == .init(name: "feature/equal-json", status: "existing", upstream: nil))
        #expect(
            equalJSON.start
                == .init(
                    commit: fixture.mainCommit, from: "localBranch", ref: "refs/heads/feature/equal-json",
                    localOnlyCommits: nil))
        #expect(equalJSON.fetch.status == "fetched")

        let behindLocal = try await fixture.git("rev-parse", "refs/heads/feature/behind")
        let behindDestination = try fixture.destination(for: "feature/behind")
        let behind = await fixture.runNew("feature/behind", json: false)
        #expect(
            behind.line
                == "created feature/behind at \(behindDestination.path) "
                + "(copy-on-write; existing branch; fast-forwarded to origin/feature/behind)")
        let behindRemote = try await fixture.git("rev-parse", "refs/remotes/origin/feature/behind")
        #expect(behindRemote != behindLocal)
        #expect(try await fixture.git("rev-parse", "refs/heads/feature/behind") == behindRemote)
        let behindJSON = try await fixture.runNew("feature/behind-json", json: true).created()
        let behindJSONRemote = try await fixture.git("rev-parse", "refs/remotes/origin/feature/behind-json")
        #expect(behindJSON.branch.status == "fastForwarded")
        #expect(
            behindJSON.start
                == .init(
                    commit: behindJSONRemote, from: "remoteBranch", ref: "refs/remotes/origin/feature/behind-json",
                    localOnlyCommits: nil))
        #expect(behindJSON.materialization?.sourceState == "reset")
        let behindJSONDestination = try fixture.destination(for: "feature/behind-json")
        #expect(
            try await WorktreeCreationRemoteFixture.git(behindJSONDestination, "rev-parse", "HEAD") == behindJSONRemote)

        let divergedLocal = try await fixture.git("rev-parse", "refs/heads/feature/diverged")
        let divergedDestination = try fixture.destination(for: "feature/diverged")
        let diverged = await fixture.runNew("feature/diverged", json: false)
        #expect(
            diverged.line
                == "created feature/diverged at \(divergedDestination.path) "
                + "(copy-on-write; existing branch; kept local feature/diverged: 1 commit not on origin)")
        #expect(try await fixture.git("rev-parse", "refs/heads/feature/diverged") == divergedLocal)
        let divergedJSON = try await fixture.runNew("feature/diverged-json", json: true).created()
        #expect(divergedJSON.branch.status == "existing")
        #expect(divergedJSON.start.localOnlyCommits == 1)
        #expect(divergedJSON.start.from == "localBranch")
    }

    @Test("an origin-only branch is created at origin's tip and tracks it")
    func createsOriginOnlyBranchWithUpstream() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-origin-only")
        defer { fixture.destroy() }
        try await fixture.advance("feature/remote", file: "remote.txt")
        let tipJSON = try await fixture.advance("feature/remote-json", file: "remote.txt")

        let destination = try fixture.destination(for: "feature/remote")
        let human = await fixture.runNew("feature/remote", json: false)
        #expect(
            human.line == "created feature/remote at \(destination.path) (copy-on-write; from origin/feature/remote)")
        #expect(try await fixture.git("config", "branch.feature/remote.remote") == "origin")
        #expect(try await fixture.git("config", "branch.feature/remote.merge") == "refs/heads/feature/remote")

        let document = try await fixture.runNew("feature/remote-json", json: true).created()
        #expect(
            document.branch
                == .init(
                    name: "feature/remote-json", status: "created", upstream: "refs/remotes/origin/feature/remote-json")
        )
        #expect(
            document.start
                == .init(
                    commit: tipJSON, from: "remoteBranch", ref: "refs/remotes/origin/feature/remote-json",
                    localOnlyCommits: nil))
        #expect(
            document.fetch
                == .init(
                    remote: "origin", branch: "feature/remote-json", status: "fetched", commit: tipJSON, reason: nil))
    }

    @Test("--from-branch starts a new branch at a local, origin, or second-remote start")
    func startsNewBranchFromAnotherBranch() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-from-branch")
        defer { fixture.destroy() }
        try await fixture.git("branch", "release/local")
        let localTip = try await fixture.commitLocally("release/local", file: "local.txt")
        try await fixture.git("branch", "release/behind")
        let behindRemoteTip = try await fixture.advance("release/behind", file: "behind.txt")
        try await fixture.git("branch", "release/diverged")
        try await fixture.advance("release/diverged", file: "remote-only.txt")
        let divergedLocal = try await fixture.commitLocally("release/diverged", file: "local-only.txt")
        let originOnlyTip = try await fixture.advance("release/origin", file: "origin.txt")
        let upstreamTip = try await fixture.advance("release/upstream", on: "upstream", file: "upstream.txt")

        let cases = [
            WorktreeCreationLineCase(
                "feature/from-local", ["--from-branch", "release/local"], localTip, "copy-on-write"),
            WorktreeCreationLineCase(
                "feature/from-behind", ["--from-branch", "release/behind"], behindRemoteTip,
                "copy-on-write; from origin/release/behind"),
            WorktreeCreationLineCase(
                "feature/from-diverged", ["--from-branch", "release/diverged"], divergedLocal,
                "copy-on-write; kept local release/diverged: 1 commit not on origin"),
            WorktreeCreationLineCase(
                "feature/from-origin", ["--from-branch", "release/origin"], originOnlyTip,
                "copy-on-write; from origin/release/origin"),
            WorktreeCreationLineCase(
                "feature/from-origin-prefix", ["--from-branch", "origin/release/origin"], originOnlyTip,
                "copy-on-write; from origin/release/origin"),
            WorktreeCreationLineCase(
                "feature/from-upstream", ["--from-branch", "upstream/release/upstream"], upstreamTip,
                "copy-on-write; from upstream/release/upstream"),
        ]
        for testCase in cases {
            let run = await fixture.runNew(testCase.branch, testCase.options, json: false)
            let destination = try fixture.destination(for: testCase.branch)
            #expect(run.exit == 0, "\(testCase.options): \(run.output)")
            #expect(run.line == "created \(testCase.branch) at \(destination.path) (\(testCase.details))")
            #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == testCase.commit)
            // A start never writes an upstream; only a branch created from its same-named remote branch does.
            let configuration = try await fixture.git("config", "--list")
            #expect(!configuration.contains("branch.\(testCase.branch)."))
        }
        // A local start strictly behind origin uses origin's commit without moving the local branch.
        #expect(try await fixture.git("rev-parse", "refs/heads/release/behind") == fixture.mainCommit)

        let upstreamJSON = try await fixture.runNew(
            "feature/from-upstream-json", ["--from-branch", "upstream/release/upstream"], json: true
        ).created()
        #expect(
            upstreamJSON.fetch
                == .init(
                    remote: "upstream", branch: "release/upstream", status: "fetched", commit: upstreamTip, reason: nil)
        )
        #expect(upstreamJSON.branch.upstream == nil)

        let missing = await fixture.runNew("feature/from-missing", ["--from-branch", "release/missing"], json: true)
        #expect(missing.exit == 1)
        #expect(try missing.refused().reason == "startBranchNotFound")

        try await fixture.git("branch", "feature/taken")
        let taken = await fixture.runNew("feature/taken", ["--from-branch", "release/local"], json: true)
        #expect(taken.exit == 1)
        let refusal = try taken.refused()
        #expect(refusal.reason == "branchAlreadyExists")
        #expect(refusal.options?.first?.action == .command("agentstudio worktree new <branch>"))
        #expect(
            refusal.fetch
                == .init(remote: "origin", branch: "release/local", status: "notOnRemote", commit: nil, reason: nil))
    }

    @Test("a same-name --from-branch takes the existing-branch steps with that start's remote")
    func sameNameStartUsesItsRemote() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-same-name")
        defer { fixture.destroy() }
        let tip = try await fixture.advance("feature/shared", on: "upstream", file: "shared.txt")

        let run = await fixture.runNew("feature/shared", ["--from-branch", "upstream/feature/shared"], json: true)
        #expect(run.exit == 0)
        let document = try run.created()
        #expect(
            document.branch
                == .init(name: "feature/shared", status: "created", upstream: "refs/remotes/upstream/feature/shared"))
        #expect(document.start.commit == tip)
        #expect(try await fixture.git("config", "branch.feature/shared.remote") == "upstream")
    }

    @Test("--changes-only refuses an existing branch and fetches nothing")
    func changesOnlyRefusesExistingBranchAndSkipsFetch() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-changes-only")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/existing")

        let existing = await fixture.runNew(
            "feature/existing", ["--from", fixture.repository.path, "--changes-only"], json: true)
        #expect(existing.exit == 1)
        #expect(try existing.refused().reason == "branchAlreadyExists")

        try "changed\n".write(to: fixture.repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let created = await fixture.runNew(
            "feature/changes", ["--from", fixture.repository.path, "--changes-only"], json: true)
        #expect(created.exit == 0)
        let document = try created.created()
        #expect(document.fetch == .init(remote: nil, branch: nil, status: "skipped", commit: nil, reason: "notNeeded"))
        #expect(document.materialization?.kind == "changesOnly")
    }

    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
