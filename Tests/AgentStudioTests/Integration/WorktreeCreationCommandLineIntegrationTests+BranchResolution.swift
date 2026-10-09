import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

/// LR1 and LR30 through the real command line, against a local bare `origin` and a second bare remote.
extension WorktreeCreationCommandLineIntegrationTests {
    @Test("new -c (or --create) with a name the remote lacks starts at the source's HEAD after notOnRemote")
    func createsNewNameAtSourceHead() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-fresh")
        defer { fixture.destroy() }

        let destination = try fixture.destination(for: "feature/fresh")
        let human = await fixture.runNew("feature/fresh", ["-c"], json: false)
        #expect(human.exit == 0)
        #expect(human.line == "created feature/fresh at \(destination.path) (copy-on-write)")

        let json = await fixture.runNew("feature/fresh-json", ["--create"], json: true)
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

    @Test("new without -c refuses a name that exists nowhere, naming -c, and changes nothing")
    func refusesUnknownNameWithoutCreate() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-not-found")
        defer { fixture.destroy() }
        let before = try await fixture.observedState()

        let human = await fixture.runNew("feature/nowhere", json: false)
        let json = await fixture.runNew("feature/nowhere", json: true)

        #expect(human.exit == 1)
        #expect(
            human.line
                == "refused: noSuchBranch feature/nowhere; options: [agentstudio worktree new -c <branch>: "
                + "Create it as a new branch.]\nfetch: notOnRemote origin/feature/nowhere")
        #expect(json.exit == 1)
        #expect(
            json.line
                == #"{"detail":"feature/nowhere","details":{"noSuchBranch":{"branch":"feature/nowhere"}},"fetch":{"branch":"feature/nowhere","remote":"origin","status":"notOnRemote"},"message":"No branch with that name exists locally or on origin.","options":[{"command":"agentstudio worktree new -c <branch>","effect":"Create it as a new branch."}],"outcome":"refused","reason":"noSuchBranch"}"#
        )
        #expect(try await fixture.observedState() == before)

        // A failed refresh leaves only the refs on disk, which don't have it either: still refused, with the
        // failed fetch reported.
        try await fixture.git("remote", "set-url", "origin", fixture.folder.appending(path: "missing.git").path)
        let unreachable = await fixture.runNew("feature/nowhere", json: true)
        #expect(unreachable.exit == 1)
        #expect(try unreachable.refused().reason == "noSuchBranch")
        #expect(
            try unreachable.refused().fetch
                == .init(
                    remote: "origin", branch: "feature/nowhere", status: "failed", commit: nil,
                    reason: "processFailure"))
    }

    @Test("new -c refuses a name taken locally or on origin; with --no-fetch, the ref on disk decides")
    func createRefusesAnExistingName() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-create-existing")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/local")

        let local = await fixture.runNew("feature/local", ["-c"], json: false)

        #expect(local.exit == 1)
        #expect(
            local.line
                == "refused: branchAlreadyExists feature/local; options: [agentstudio worktree new <branch>: Open the existing branch in a new worktree.; use another branch name: Create a new branch under a name that does not exist.]"
        )

        // Only origin has it: origin's answer refuses, and nothing is fetched.
        try await fixture.advance("feature/remote", file: "remote.txt")
        let remote = await fixture.runNew("feature/remote", ["-c"], json: true)
        #expect(remote.exit == 1)
        #expect(
            remote.line
                == #"{"detail":"origin/feature/remote","details":{"branchAlreadyExists":{"branch":"feature/remote","remoteName":"origin"}},"message":"A branch with that name already exists.","options":[{"command":"agentstudio worktree new <branch>","effect":"Open the existing branch in a new worktree."},{"command":"use another branch name","effect":"Create a new branch under a name that does not exist."}],"outcome":"refused","reason":"branchAlreadyExists"}"#
        )
        #expect(try await fixture.git("for-each-ref", "refs/remotes/origin/feature/remote").isEmpty)
        #expect(try await fixture.git("branch", "--list", "feature/remote").isEmpty)

        // --no-fetch: the origin ref on disk answers. On disk, the name is taken; not on disk, -c creates it.
        try await fixture.advance("feature/on-disk", file: "on-disk.txt")
        try await fixture.git("fetch", "origin", "+refs/heads/feature/on-disk:refs/remotes/origin/feature/on-disk")
        let onDisk = await fixture.runNew("feature/on-disk", ["-c", "--no-fetch"], json: true)
        #expect(onDisk.exit == 1)
        #expect(try onDisk.refused().reason == "branchAlreadyExists")
        #expect(try onDisk.refused().detail == "origin/feature/on-disk")
        try await fixture.advance("feature/not-on-disk", file: "not-on-disk.txt")
        let notOnDisk = await fixture.runNew("feature/not-on-disk", ["-c", "--no-fetch"], json: true)
        #expect(notOnDisk.exit == 0, "\(notOnDisk.output)")
        #expect(
            try notOnDisk.created().fetch
                == .init(remote: nil, branch: nil, status: "skipped", commit: nil, reason: "noFetchFlag"))
    }

    @Test("new -c refuses originCheckFailed when origin can't be asked, naming --no-fetch, and creates nothing")
    func createFailsClosedWhenOriginCannotBeAsked() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-origin-check-failed")
        defer { fixture.destroy() }
        try "changed\n".write(to: fixture.repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await fixture.git("remote", "set-url", "origin", fixture.folder.appending(path: "missing.git").path)
        let before = try await fixture.observedState()

        let human = await fixture.runNew("feature/new", ["-c"], json: false)
        let json = await fixture.runNew("feature/new", ["-c"], json: true)
        // --changes-only refreshes nothing, but -c's question about the name still runs.
        let changesOnly = await fixture.runNew(
            "feature/new", ["-c", "--from", fixture.repository.path, "--changes-only"], json: true)

        #expect(human.exit == 1)
        #expect(
            human.line
                == "refused: originCheckFailed origin/feature/new (processFailure); options: [--no-fetch: "
                + "Answer from the origin/<branch> ref on disk instead of asking origin.]")
        #expect(json.exit == 1)
        #expect(
            json.line
                == #"{"detail":"origin/feature/new (processFailure)","details":{"originCheckFailed":{"branch":"feature/new","reason":"processFailure","remoteName":"origin"}},"message":"Origin could not be asked whether the branch exists, so nothing was created.","options":[{"effect":"Answer from the origin/<branch> ref on disk instead of asking origin.","flag":"--no-fetch"}],"outcome":"refused","reason":"originCheckFailed"}"#
        )
        #expect(changesOnly.exit == 1)
        #expect(try changesOnly.refused().reason == "originCheckFailed")
        #expect(try await fixture.observedState() == before)

        // The option: with --no-fetch, the ref on disk answers and the branch is created.
        let noFetch = await fixture.runNew("feature/new", ["-c", "--no-fetch"], json: true)
        #expect(noFetch.exit == 0, "\(noFetch.output)")
        #expect(try noFetch.created().branch == .init(name: "feature/new", status: "created", upstream: nil))
    }

    @Test("new -c with no origin remote checks local branches only and reports skipped(noRemote)")
    func createWithoutOriginChecksLocalBranchesOnly() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-no-origin")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/taken")
        try await fixture.git("remote", "remove", "origin")

        let created = await fixture.runNew("feature/local-only", ["-c"], json: true)
        #expect(created.exit == 0, "\(created.output)")
        let document = try created.created()
        #expect(document.fetch == .init(remote: nil, branch: nil, status: "skipped", commit: nil, reason: "noRemote"))
        #expect(document.start.from == "sourceHead")

        let taken = await fixture.runNew("feature/taken", ["-c"], json: true)
        #expect(taken.exit == 1)
        #expect(try taken.refused().reason == "branchAlreadyExists")
        #expect(try taken.refused().detail == "feature/taken")
    }

    @Test("a branch deleted on origin is absent even with its old remote-tracking ref still on disk")
    func treatsBranchDeletedOnOriginAsAbsent() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-deleted-on-origin")
        defer { fixture.destroy() }
        let staleTip = try await fixture.advance("feature/gone", file: "gone.txt")
        try await fixture.git("fetch", "origin", "+refs/heads/feature/gone:refs/remotes/origin/feature/gone")
        try await WorktreeCreationRemoteFixture.git(fixture.originClone, "push", "origin", "--delete", "feature/gone")
        #expect(try await fixture.git("rev-parse", "refs/remotes/origin/feature/gone") == staleTip)

        let created = await fixture.runNew("feature/gone", ["-c"], json: true)
        #expect(created.exit == 0)
        let document = try created.created()
        #expect(document.branch == .init(name: "feature/gone", status: "created", upstream: nil))
        #expect(document.start.from == "sourceHead")
        #expect(document.fetch.status == "notOnRemote")
        let destination = try fixture.destination(for: "feature/gone")
        #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == fixture.mainCommit)

        let fromStale = await fixture.runNew(
            "feature/other", ["-c", "--from-branch", "origin/feature/gone"], json: true)
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
                "feature/from-local", ["-c", "--from-branch", "release/local"], localTip, "copy-on-write"),
            WorktreeCreationLineCase(
                "feature/from-behind", ["-c", "--from-branch", "release/behind"], behindRemoteTip,
                "copy-on-write; from origin/release/behind"),
            WorktreeCreationLineCase(
                "feature/from-diverged", ["-c", "--from-branch", "release/diverged"], divergedLocal,
                "copy-on-write; kept local release/diverged: 1 commit not on origin"),
            WorktreeCreationLineCase(
                "feature/from-origin", ["-c", "--from-branch", "release/origin"], originOnlyTip,
                "copy-on-write; from origin/release/origin"),
            WorktreeCreationLineCase(
                "feature/from-origin-prefix", ["-c", "--from-branch", "origin/release/origin"], originOnlyTip,
                "copy-on-write; from origin/release/origin"),
            WorktreeCreationLineCase(
                "feature/from-upstream", ["-c", "--from-branch", "upstream/release/upstream"], upstreamTip,
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
            "feature/from-upstream-json", ["-c", "--from-branch", "upstream/release/upstream"], json: true
        ).created()
        #expect(
            upstreamJSON.fetch
                == .init(
                    remote: "upstream", branch: "release/upstream", status: "fetched", commit: upstreamTip, reason: nil)
        )
        #expect(upstreamJSON.branch.upstream == nil)

        let missing = await fixture.runNew(
            "feature/from-missing", ["-c", "--from-branch", "release/missing"], json: true)
        #expect(missing.exit == 1)
        #expect(try missing.refused().reason == "startBranchNotFound")

        // -c refuses an existing <branch> before the start is read or anything is fetched (D23).
        try await fixture.git("branch", "feature/taken")
        let taken = await fixture.runNew("feature/taken", ["-c", "--from-branch", "release/local"], json: true)
        #expect(taken.exit == 1)
        let refusal = try taken.refused()
        #expect(refusal.reason == "branchAlreadyExists")
        #expect(refusal.options?.first?.action == .command("agentstudio worktree new <branch>"))
        #expect(refusal.fetch == nil)
    }

    @Test("--changes-only refuses a name taken locally or on origin and refreshes nothing")
    func changesOnlyRefusesExistingBranchAndSkipsFetch() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-changes-only")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/existing")
        try await fixture.advance("feature/origin-only", file: "origin-only.txt")

        let existing = await fixture.runNew(
            "feature/existing", ["-c", "--from", fixture.repository.path, "--changes-only"], json: true)
        #expect(existing.exit == 1)
        #expect(try existing.refused().reason == "branchAlreadyExists")
        let originOnly = await fixture.runNew(
            "feature/origin-only", ["-c", "--from", fixture.repository.path, "--changes-only"], json: true)
        #expect(originOnly.exit == 1)
        #expect(try originOnly.refused().reason == "branchAlreadyExists")
        #expect(try originOnly.refused().detail == "origin/feature/origin-only")
        #expect(try await fixture.git("for-each-ref", "refs/remotes/origin/feature/origin-only").isEmpty)

        try "changed\n".write(to: fixture.repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let created = await fixture.runNew(
            "feature/changes", ["-c", "--from", fixture.repository.path, "--changes-only"], json: true)
        #expect(created.exit == 0)
        let document = try created.created()
        #expect(document.fetch == .init(remote: nil, branch: nil, status: "skipped", commit: nil, reason: "notNeeded"))
        #expect(document.materialization?.kind == "changesOnly")
    }

    @Test("re-running new for a branch already at its own sibling destination says where it is")
    func refusesBranchHeldAtItsOwnDestination() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-held-at-destination")
        defer { fixture.destroy() }
        let destination = try fixture.destination(for: "feature/again")
        try await fixture.git("worktree", "add", "-b", "feature/again", destination.path)
        // Origin has the branch too, so a fetch would leave refs/remotes/origin/feature/again behind.
        try await fixture.advance("feature/again", file: "again.txt")
        let before = try await fixture.observedState()

        let run = await fixture.runNew("feature/again", json: true)
        #expect(run.exit == 1)
        let refusal = try run.refused()
        #expect(refusal.reason == "branchCheckedOut")
        #expect(refusal.path.map(Self.realPath) == Self.realPath(destination.path))
        #expect(refusal.options?.first?.action == .command("cd <path>"))
        #expect(refusal.fetch == nil)
        #expect(try await fixture.observedState() == before)
        #expect(try await fixture.git("for-each-ref", "refs/remotes/origin/feature/again").isEmpty)
    }

    @Test("re-running new --no-fork for a branch already at its own sibling destination says where it is")
    func refusesCheckoutOfBranchHeldAtItsOwnDestination() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-checkout-held-at-destination")
        defer { fixture.destroy() }
        let destination = try fixture.destination(for: "feature/again")
        try await fixture.git("worktree", "add", "-b", "feature/again", destination.path)
        try await fixture.advance("feature/again", file: "again.txt")
        let before = try await fixture.observedState()

        let run = await fixture.runNew("feature/again", ["--no-fork"], json: false)

        #expect(run.exit == 1)
        #expect(run.line?.hasPrefix("refused: branchCheckedOut \(Self.realPath(destination.path))") == true)
        #expect(try await fixture.observedState() == before)
        #expect(try await fixture.git("for-each-ref", "refs/remotes/origin/feature/again").isEmpty)
    }

    @Test("a remote prefix wins over a local branch literally named like it")
    func remotePrefixWinsOverLocalBranch() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-prefix")
        defer { fixture.destroy() }
        let originTip = try await fixture.advance("release/origin", file: "origin.txt")
        try await fixture.git("branch", "origin/release/origin", "main")
        #expect(try await fixture.git("rev-parse", "refs/heads/origin/release/origin") != originTip)

        let prefixedDestination = try fixture.destination(for: "feature/prefixed")
        let prefixed = await fixture.runNew(
            "feature/prefixed", ["-c", "--from-branch", "origin/release/origin"], json: false)
        #expect(
            prefixed.line
                == "created feature/prefixed at \(prefixedDestination.path) (copy-on-write; from origin/release/origin)"
        )
        #expect(try await WorktreeCreationRemoteFixture.git(prefixedDestination, "rev-parse", "HEAD") == originTip)
    }

    @Test("a branch taken by another worktree at the attach, after the fetch, still reports the fetch")
    func lateBranchCheckedOutKeepsFetch() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-late-held")
        defer { fixture.destroy() }
        let tip = try await fixture.advance("feature/late", file: "late.txt")
        let racer = fixture.folder.appending(path: "racer")
        // The SDK refuses at the attach when another worktree took the branch after resolution.
        let client = try await fixture.stubClient(forkFailure: .branchCheckedOut(worktreePath: racer))

        let outcome = await fixture.runCreate("feature/late", client: client)

        #expect(
            outcome
                == .refused(
                    .creationStopped(.branchCheckedOut(path: racer.standardizedFileURL.path)),
                    creationFetch: .fetched(
                        remoteName: "origin", branchName: "feature/late", commit: tip, lockResidue: nil)))
        let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(human.text.hasSuffix("\nfetch: fetched origin/feature/late \(tip)"))
    }

    @Test("a fork whose fast-forward couldn't be undone names the branch and both commits in its leftovers")
    func forkLeftoverNamesTheUndoneFastForward() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-fork-move-not-undone")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/ff", "main")
        let originTip = try await fixture.advance("feature/ff", file: "ff.txt")
        // The SDK fast-forwarded the strictly-behind branch, failed later, and couldn't move it back. Its residue
        // names only the ref; the plan knows the move.
        let client = try await fixture.stubClient(
            forkFailure: .cleanupIncomplete(
                primary: .cancelled,
                residue: [GitWorktreeForkResidue(kind: .branchMoveNotUndone, location: "refs/heads/feature/ff")]))

        let outcome = await fixture.runCreate("feature/ff", client: client)

        let mainCommit = fixture.mainCommit
        #expect(
            outcome
                == .failed(
                    WorktreeOperationFailure(
                        failure: .cancelled,
                        leftovers: .incomplete([
                            WorktreeCleanupLeftover(
                                kind: .branchMoveNotUndone, location: "refs/heads/feature/ff", base: .branchReference,
                                branchMove: WorktreeBranchMove(fromCommit: mainCommit, toCommit: originTip))
                        ]),
                        creationFetch: .fetched(
                            remoteName: "origin", branchName: "feature/ff", commit: originTip, lockResidue: nil))))
        let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(human.exitCode == 2)
        #expect(
            human.text
                == "failed: cancelled; leftovers: incomplete [branchMoveNotUndone refs/heads/feature/ff from \(mainCommit) "
                + "to \(originTip) (branch reference)]\nfetch: fetched origin/feature/ff \(originTip)")
        #expect(
            try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true).text
                == #"{"failure":{"kind":"cancelled"},"fetch":{"branch":"feature/ff","commit":"\#(originTip)","remote":"origin","status":"fetched"},"leftovers":{"items":[{"base":"branchReference","fromCommit":"\#(mainCommit)","kind":"branchMoveNotUndone","location":"refs/heads/feature/ff","toCommit":"\#(originTip)"}],"status":"incomplete"},"outcome":"failed"}"#
        )
    }

    @Test("a malformed copy config doesn't hide a branch held by another worktree")
    func heldBranchWinsOverInvalidConfig() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-held-invalid-config")
        defer { fixture.destroy() }
        let holder = fixture.folder.appending(path: "holder")
        try await fixture.git("worktree", "add", "-b", "feature/held", holder.path)
        try Data("{".utf8).write(to: fixture.repository.appending(path: ".agentstudio.config.json"))

        let held = await fixture.runNew("feature/held", json: true)
        #expect(held.exit == 1)
        let refusal = try held.refused()
        #expect(refusal.reason == "branchCheckedOut")
        #expect(refusal.path.map(Self.realPath) == Self.realPath(holder.path))

        // With nothing held, the same config still refuses configInvalid.
        let free = await fixture.runNew("feature/free", ["-c"], json: true)
        #expect(free.exit == 1)
        #expect(try free.refused().reason == "configInvalid")
    }

    @Test("a branch-use read that fails stops new before the fetch, with nothing changed")
    func branchUseReadFailureFailsClosed() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-branch-use-unreadable")
        defer { fixture.destroy() }
        // Origin has the branch, so a fetch would leave refs/remotes/origin/feature/unreadable behind.
        try await fixture.advance("feature/unreadable", file: "unreadable.txt")
        // Stands in for the SDK's non-ENOENT read of a worktree's administration (no search permission, an
        // I/O error), which throws rather than report the branch free.
        let client = try await fixture.stubClient(
            branchUseFailure: .unsupported(message: "worktree administration is unreadable"))
        let before = try await fixture.observedState()

        let outcome = await fixture.runCreate("feature/unreadable", client: client)

        // The failure carries no creation fetch: none ran.
        #expect(outcome == .failed(WorktreeOperationFailure(failure: .readFailed(.unsupported), leftovers: .notNeeded)))
        #expect(!FileManager.default.fileExists(atPath: try fixture.destination(for: "feature/unreadable").path))
        #expect(try await fixture.observedState() == before)
    }

    @Test("a branch deleted between resolution and the fork refuses branchMoved through the real SDK")
    func branchDeletedBeforeTheForkRefusesBranchMoved() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-branch-gone")
        defer { fixture.destroy() }
        try await fixture.git("branch", "feature/gone", "main")
        let repository = fixture.repository
        let realClient = LibGit2AgentStudioGitLocalClient()
        // Another process deletes the branch after `new` resolved it as existing, just before the SDK forks.
        let client = try await fixture.stubClient(forkHandler: { request in
            do {
                try await WorktreeCreationRemoteFixture.git(repository, "branch", "-D", "feature/gone")
            } catch {
                Issue.record("deleting feature/gone before the fork failed: \(error)")
            }
            do throws(GitWorktreeForkError) {
                return .success(try await realClient.forkWorktree(request))
            } catch {
                return .failure(error)
            }
        })
        let before = try await fixture.observedState()

        let outcome = await fixture.runCreate("feature/gone", client: client)

        #expect(
            outcome
                == .refused(
                    .creationStopped(.branchMoved),
                    creationFetch: .notOnRemote(remoteName: "origin", branchName: "feature/gone")))
        let json = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        let refusal = try JSONDecoder().decode(
            WorktreeCreationCommandLineDocuments.RefusedDocument.self, from: Data(json.text.utf8))
        #expect(refusal.reason == "branchMoved")
        #expect(refusal.options?.first?.action == .command("retry"))
        let human = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(human.text.hasSuffix("\nfetch: notOnRemote origin/feature/gone"))
        #expect(!FileManager.default.fileExists(atPath: try fixture.destination(for: "feature/gone").path))
        #expect(try await fixture.observedState().folderEntries == before.folderEntries)
        #expect(try await fixture.git("for-each-ref", "refs/heads/feature/gone").isEmpty)
    }

    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
