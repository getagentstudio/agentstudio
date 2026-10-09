import AgentStudioTestHarness
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

/// D15: which existing branches `--from-branch` can start from. A start follows git's rule for a branch
/// name, not the app's stricter policy for a branch it creates.
extension WorktreeCreationCommandLineIntegrationTests {
    @Test("--from-branch starts from an existing branch whose name is longer than a new branch's may be")
    func startsFromLongExistingBranchNames() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-long-start")
        defer { fixture.destroy() }
        let segment = String(repeating: "s", count: 60)
        let localStart = "release/\(segment)/\(segment)/\(segment)/\(segment)/local"
        let remoteStart = "release/\(segment)/\(segment)/\(segment)/\(segment)/remote"
        #expect(localStart.count > WorktreeCreationPolicy.maximumBranchNameLength)
        try await fixture.git("branch", localStart, "main")
        let remoteTip = try await fixture.advance(remoteStart, file: "long.txt")

        let fromLocal = await fixture.runNew("feature/short-local", ["-c", "--from-branch", localStart], json: true)
        #expect(fromLocal.exit == 0, "\(fromLocal.output)")
        #expect(
            try fromLocal.created().start
                == .init(
                    commit: fixture.mainCommit, from: "localBranch", ref: "refs/heads/\(localStart)",
                    localOnlyCommits: nil))

        let fromRemote = await fixture.runNew(
            "feature/short-remote", ["-c", "--from-branch", "origin/\(remoteStart)"], json: true)
        #expect(fromRemote.exit == 0, "\(fromRemote.output)")
        #expect(try fromRemote.created().start.commit == remoteTip)

        // A malformed start is still refused, and a new branch name still gets the full check before the
        // branch-use read: the length cap, and HEAD, which `git check-ref-format --branch` rejects.
        let malformed = await fixture.runNew("feature/short-bad", ["-c", "--from-branch", "release..bad"], json: true)
        #expect(malformed.exit == 1)
        #expect(try malformed.refused().reason == "startBranchNotFound")
        let tooLong = await fixture.runNew(localStart + "-new", json: true)
        #expect(tooLong.exit == 1)
        #expect(try tooLong.refused().reason == "invalidBranchName")
        let head = await fixture.runNew("HEAD", json: true)
        #expect(head.exit == 1)
        let headRefusal = try head.refused()
        #expect(headRefusal.reason == "invalidBranchName")
        // Refused by the name check itself, not later by Git: nothing was fetched.
        #expect(headRefusal.fetch == nil)
    }

    @Test("--from-branch starts from existing branches whose Git-legal names a new branch may not use")
    func startsFromGitLegalUnicodeBranchNames() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-unicode-start")
        defer { fixture.destroy() }
        // `git check-ref-format --branch` accepts a no-break space and a zero-width joiner; of whitespace and
        // control characters it refuses only the ASCII control characters, DEL and the space.
        let startsAndBranches = [
            ("release/a\u{00A0}b", "feature/no-break-space"),
            ("release/\u{1F469}\u{200D}\u{1F4BB}", "feature/zero-width-joiner"),
        ]
        for (start, branch) in startsAndBranches {
            try await fixture.git("branch", start, "main")
            let created = await fixture.runNew(branch, ["-c", "--from-branch", start], json: true)
            #expect(created.exit == 0, "\(start): \(created.output)")
            #expect(
                try created.created().start
                    == .init(
                        commit: fixture.mainCommit, from: "localBranch", ref: "refs/heads/\(start)",
                        localOnlyCommits: nil),
                "\(start)")
        }

        let spaced = await fixture.runNew("feature/ascii-space", ["-c", "--from-branch", "release/a b"], json: true)
        #expect(spaced.exit == 1)
        #expect(try spaced.refused().reason == "startBranchNotFound")
    }

    @Test("an existing start name is accepted exactly when git accepts it as a branch name")
    func existingStartNamesFollowGit() async throws {
        let names = [
            "@", "release/a./b", "release/a.", "a.lock/b", ".a", "a/.b", "a..b", "a@{b", "a//b", "/a", "a/", "-a",
            "HEAD", "a b", "a\tb", "a\u{7F}b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a\u{00A0}b",
            "\u{1F469}\u{200D}\u{1F4BB}", "x@y", "@a", "a@", "a.", "a./b", "a.lock", "@{-1}",
            // A combining mark after a forbidden byte doesn't hide it from git.
            "a~\u{301}b", ".\u{301}a", "a..\u{301}b", "/\u{301}a", "a.lock/\u{301}b", "-\u{301}bad",
            "a/\u{301}b", "a.\u{301}/b", "a.\u{301}",
        ]
        for name in names {
            // The plain refname form: `--branch` would expand `@` and `@{-N}`. `git branch` also refuses a
            // leading `-` and `HEAD`, which the refname rules allow. Both are decided on bytes, as git decides
            // them: `hasPrefix("-")` compares graphemes and would miss `-` under a combining mark.
            let gitAccepts = try await Self.gitAcceptsReferenceName("refs/heads/\(name)")
            let refusedByBranch = name.utf8.first == UInt8(ascii: "-") || name.utf8.elementsEqual("HEAD".utf8)
            let expected = !refusedByBranch && gitAccepts
            #expect(WorktreeBranchName.isWellFormedExistingName(name) == expected, "\(name.debugDescription)")
        }
    }

    @Test("--from-branch @ starts from a branch literally named @, not from HEAD")
    func startsFromBranchNamedAt() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-at-start")
        defer { fixture.destroy() }
        try await fixture.git("branch", "side", "main")
        let sideTip = try await fixture.commitLocally("side", file: "side.txt")
        try await fixture.git("update-ref", "refs/heads/@", sideTip)
        #expect(sideTip != fixture.mainCommit)

        let created = await fixture.runNew("feature/at", ["-c", "--from-branch", "@"], json: true)

        #expect(created.exit == 0, "\(created.output)")
        #expect(
            try created.created().start
                == .init(commit: sideTip, from: "localBranch", ref: "refs/heads/@", localOnlyCommits: nil))
        let destination = try fixture.destination(for: "feature/at")
        #expect(try await WorktreeCreationRemoteFixture.git(destination, "rev-parse", "HEAD") == sideTip)
    }

    @Test("--from-branch origin/<name> starts from a remote branch with a dot-ended inner component")
    func startsFromRemoteBranchWithInnerDotEndedComponent() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-dotted-remote-start")
        defer { fixture.destroy() }
        let originTip = try await fixture.advance("release/a./b", file: "dotted.txt")

        let created = await fixture.runNew(
            "feature/dotted", ["-c", "--from-branch", "origin/release/a./b"], json: true)

        #expect(created.exit == 0, "\(created.output)")
        #expect(
            try created.created().start
                == .init(
                    commit: originTip, from: "remoteBranch", ref: "refs/remotes/origin/release/a./b",
                    localOnlyCommits: nil))
    }

    @Test(
        "--from-branch origin/<U+0301>x takes origin's branch over a local shadow, and its tracking ref without a fetch"
    )
    func startsFromRemoteBranchBeginningWithCombiningMark() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-combining-remote-start")
        defer { fixture.destroy() }
        // `/` and U+0301 form one grapheme, but git reads `origin/<U+0301>x` as origin's branch `<U+0301>x`.
        let originTip = try await fixture.advance("\u{301}x", file: "mark.txt")
        // A local branch literally named `origin/<U+0301>x`, at another commit: the remote prefix still wins.
        try await fixture.git("branch", "origin/\u{301}x", "main")
        #expect(originTip != fixture.mainCommit)
        let fromOrigin = WorktreeCreationCommandLineDocuments.StartDocument(
            commit: originTip, from: "remoteBranch", ref: "refs/remotes/origin/\u{301}x", localOnlyCommits: nil)

        let created = await fixture.runNew("feature/mark", ["-c", "--from-branch", "origin/\u{301}x"], json: true)

        #expect(created.exit == 0, "\(created.output)")
        #expect(try created.created().start == fromOrigin)

        // Without a fetch, the start is the tracking ref already on disk, not origin's newer tip.
        let newerTip = try await fixture.advance("\u{301}x", file: "mark-again.txt")
        let offline = await fixture.runNew(
            "feature/mark-offline", ["-c", "--no-fetch", "--from-branch", "origin/\u{301}x"], json: true)

        #expect(offline.exit == 0, "\(offline.output)")
        #expect(try offline.created().start == fromOrigin)
        #expect(newerTip != originTip)
    }

    @Test("--from-branch origin/<name> starts from origin's branch whose name holds U+2028, after fetching it")
    func startsFromRemoteBranchWithLineSeparator() async throws {
        let fixture = try await WorktreeCreationRemoteFixture.create(named: "new-line-separator-start")
        defer { fixture.destroy() }
        // A branch only origin has, at a commit no local ref names. Swift splits lines at U+2028, so the remote
        // probe has to frame `ls-remote` output by bytes to find it (SDK 14d6d18).
        let originTip = try await fixture.advance("a\u{2028}b", file: "line.txt")
        #expect(!(try await fixture.git("for-each-ref", "--format=%(objectname)").contains(originTip)))

        let created = await fixture.runNew("feature/line", ["-c", "--from-branch", "origin/a\u{2028}b"], json: true)

        #expect(created.exit == 0, "\(created.output)")
        let document = try created.created()
        #expect(
            document.start
                == .init(
                    commit: originTip, from: "remoteBranch", ref: "refs/remotes/origin/a\u{2028}b",
                    localOnlyCommits: nil))
        #expect(
            document.fetch
                == .init(remote: "origin", branch: "a\u{2028}b", status: "fetched", commit: originTip, reason: nil))
    }

    /// Whether `git check-ref-format <refname>` accepts it. A refusal is the answer here, not a failed
    /// launch, so it is not reported as one.
    private static func gitAcceptsReferenceName(_ refname: String) async throws -> Bool {
        let git = try await TestToolResolver.resolved().git
        return try await withoutBlockingCooperativePool {
            let process = Process()
            process.executableURL = git
            process.arguments = ["check-ref-format", refname]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try TestToolResolver.launch(process)
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}
