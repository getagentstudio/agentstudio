import AgentStudioGit
import Foundation

/// What `new` asked for, as LR1 reads it.
package struct WorktreeCreationBranchRequest: Sendable, Equatable {
    package let branch: String
    /// `--from-branch <start>` as typed.
    package let startBranch: String?
    package let changesOnly: Bool

    package init(branch: String, startBranch: String?, changesOnly: Bool) {
        self.branch = branch
        self.startBranch = startBranch
        self.changesOnly = changesOnly
    }
}

/// LR1's answer: the branch the worktree ends on, at which start, and what the output says.
package struct WorktreeBranchPlan: Sendable, Equatable {
    package let target: WorktreeBranchTarget
    package let status: WorktreeCreatedBranchStatus
    /// The branch's upstream as a full ref: its configured one, or the one D20 writes.
    package let upstreamReference: String?
    package let startSource: WorktreeCreationStartSource
    package let startReference: String?
    package let localOnlyCommits: WorktreeLocalOnlyCommits?
}

/// Every resolved ref is pinned to an object id before the SDK call, so a ref that moves after
/// resolution refuses `branchMoved` instead of creating from a commit the resolver didn't see.
package enum WorktreeBranchTarget: Sendable, Equatable {
    case newBranch(start: GitForkStart, upstream: GitBranchUpstream?)
    case existingBranch(expectedTip: String, fastForwardTo: String?)
}

package enum WorktreeBranchResolution: Sendable, Equatable {
    case planned(WorktreeBranchPlan)
    case refused(WorktreeOperationRefusal)
    /// A ref or comparison couldn't be read; `new` fails with nothing changed and never guesses.
    case unreadable(GitDataPlaneError)
}

/// `--from-branch <start>` read against the configured remotes: a first segment naming a remote
/// means that remote's branch, even over a local branch literally named `origin/x`.
package enum WorktreeStartReference: Sendable, Equatable {
    case remote(remoteName: String, branchName: String)
    /// A local branch, else `origin/<name>`.
    case unqualified(branchName: String)

    package static let defaultRemoteName = "origin"

    package static func parse(_ start: String, remoteNames: [String]) -> Self {
        // Split at the first `/` scalar, as git reads the name. A `Character` search would miss a `/` that a
        // combining mark joins into one grapheme: `origin/<U+0301>x` is origin's branch `<U+0301>x`.
        let scalars = start.unicodeScalars
        if let separator = scalars.firstIndex(of: "/") {
            let remoteName = String(scalars[..<separator])
            let branchName = String(scalars[scalars.index(after: separator)...])
            if !branchName.isEmpty, remoteNames.contains(remoteName) {
                return .remote(remoteName: remoteName, branchName: branchName)
            }
        }
        return .unqualified(branchName: start)
    }

    package var branchName: String {
        switch self {
        case .remote(_, let branchName), .unqualified(let branchName): branchName
        }
    }

    /// The remote this start is compared with and refreshed from.
    package var remoteName: String {
        switch self {
        case .remote(let remoteName, _): remoteName
        case .unqualified: Self.defaultRemoteName
        }
    }
}

/// LR1: picks the branch a created worktree ends on, from Git facts. It owns the policy of which
/// branch an agent meant; the SDK receives an exact mode with object ids and enforces it under
/// its locks, re-checking branch use at the attach.
package struct WorktreeCreationBranchResolver: Sendable {
    private let client: any AgentStudioGitLocalClient

    package init(client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient()) {
        self.client = client
    }

    /// Step (1), before any network call: the worktree that has `<branch>` checked out, or is
    /// rebasing or bisecting it, as `git worktree add` refuses it.
    @concurrent
    package func branchHolder(repositoryPath: URL, branch: String) async throws(GitDataPlaneError) -> URL? {
        switch try await client.branchUse(GitBranchUseRequest(repositoryPath: repositoryPath, branchName: branch)) {
        case .free: nil
        case .inUse(let worktreePath): worktreePath
        }
    }

    /// LR30: the one branch `new` refreshes, from the remote LR1 will compare with.
    package static func fetchTarget(
        for request: WorktreeCreationBranchRequest,
        remoteNames: [String],
        fetchPolicy: WorktreeFetchPolicy
    ) -> WorktreeCreationFetchTarget {
        if request.changesOnly { return .skip(.notNeeded) }
        if fetchPolicy == .skip { return .skip(.noFetchFlag) }
        let reference = comparedReference(for: request, remoteNames: remoteNames)
        guard remoteNames.contains(reference.remoteName) else { return .skip(.noRemote) }
        return .branch(remoteName: reference.remoteName, branchName: reference.branchName)
    }

    /// Steps (2)–(4), `--from-branch`, and `--changes-only`, after LR30's fetch.
    @concurrent
    package func resolve(
        _ request: WorktreeCreationBranchRequest,
        repositoryPath: URL,
        localBranches: [GitBranchSnapshot],
        remoteNames: [String],
        fetch: WorktreeCreationFetchStatus
    ) async -> WorktreeBranchResolution {
        let reads = WorktreeBranchReads(
            client: client, repositoryPath: repositoryPath, localBranches: localBranches,
            remoteNames: remoteNames, fetch: fetch)
        do throws(GitDataPlaneError) {
            if request.changesOnly {
                return Self.resolveChangesOnly(request, localBranches: localBranches)
            }
            guard let startBranch = request.startBranch else {
                return try await resolveOwnBranch(
                    request.branch, remoteName: WorktreeStartReference.defaultRemoteName, sameNameStart: nil,
                    reads: reads)
            }
            let start = WorktreeStartReference.parse(startBranch, remoteNames: remoteNames)
            if start.branchName == request.branch {
                return try await resolveOwnBranch(
                    request.branch, remoteName: start.remoteName, sameNameStart: startBranch, reads: reads)
            }
            return try await resolveOtherStart(request.branch, start: start, typedStart: startBranch, reads: reads)
        } catch {
            return .unreadable(error)
        }
    }

    private static func comparedReference(
        for request: WorktreeCreationBranchRequest,
        remoteNames: [String]
    ) -> WorktreeStartReference {
        guard let startBranch = request.startBranch else {
            return .unqualified(branchName: request.branch)
        }
        let start = WorktreeStartReference.parse(startBranch, remoteNames: remoteNames)
        guard start.branchName == request.branch else { return start }
        return .remote(remoteName: start.remoteName, branchName: request.branch)
    }

    /// `--changes-only` carries changes only at the source's own commit, so it only creates.
    private static func resolveChangesOnly(
        _ request: WorktreeCreationBranchRequest,
        localBranches: [GitBranchSnapshot]
    ) -> WorktreeBranchResolution {
        guard !localBranches.contains(where: { $0.name == request.branch }) else {
            return .refused(.creationStopped(.branchAlreadyExists(branch: request.branch)))
        }
        return .planned(
            WorktreeBranchPlan(
                target: .newBranch(start: .sourceHead, upstream: nil), status: .created, upstreamReference: nil,
                startSource: .sourceHead, startReference: nil, localOnlyCommits: nil))
    }

    /// Steps (2)–(4): `<branch>` itself, compared with `<remoteName>/<branch>`.
    private func resolveOwnBranch(
        _ branch: String,
        remoteName: String,
        sameNameStart: String?,
        reads: WorktreeBranchReads
    ) async throws(GitDataPlaneError) -> WorktreeBranchResolution {
        let remoteReference = "refs/remotes/\(remoteName)/\(branch)"
        let remoteTip = try await reads.remoteTip(remoteName: remoteName, branchName: branch)
        if let localBranch = reads.localBranch(named: branch),
            let localTip = try await reads.localTip(branchName: branch)
        {
            let localReference = "refs/heads/\(branch)"
            guard let remoteTip else {
                return .planned(
                    Self.existingBranchPlan(
                        localBranch, expectedTip: localTip, fastForwardTo: nil, startReference: localReference))
            }
            switch try await reads.newestOf(localTip: localTip, remoteTip: remoteTip) {
            case .same:
                return .planned(
                    Self.existingBranchPlan(
                        localBranch, expectedTip: localTip, fastForwardTo: nil, startReference: localReference))
            case .remoteStrictlyAhead:
                return .planned(
                    Self.existingBranchPlan(
                        localBranch, expectedTip: localTip, fastForwardTo: remoteTip,
                        startReference: remoteReference))
            case .localOnly(let count):
                return .planned(
                    Self.existingBranchPlan(
                        localBranch, expectedTip: localTip, fastForwardTo: nil, startReference: localReference,
                        localOnlyCommits: WorktreeLocalOnlyCommits(count: count, remoteName: remoteName)))
            }
        }
        if let remoteTip {
            // D20: a branch created from the same-named remote branch tracks it.
            return .planned(
                WorktreeBranchPlan(
                    target: .newBranch(
                        start: .commit(remoteTip),
                        upstream: GitBranchUpstream(remoteName: remoteName, branchName: branch)),
                    status: .created, upstreamReference: remoteReference, startSource: .remoteBranch,
                    startReference: remoteReference, localOnlyCommits: nil))
        }
        if let sameNameStart {
            // A same-name start never falls through to step (4).
            return .refused(.startBranchNotFound(sameNameStart))
        }
        return .planned(
            WorktreeBranchPlan(
                target: .newBranch(start: .sourceHead, upstream: nil), status: .created, upstreamReference: nil,
                startSource: .sourceHead, startReference: nil, localOnlyCommits: nil))
    }

    /// `--from-branch` naming another branch: always a new `<branch>`, at the start's commit.
    private func resolveOtherStart(
        _ branch: String,
        start: WorktreeStartReference,
        typedStart: String,
        reads: WorktreeBranchReads
    ) async throws(GitDataPlaneError) -> WorktreeBranchResolution {
        guard reads.localBranch(named: branch) == nil else {
            return .refused(.creationStopped(.branchAlreadyExists(branch: branch)))
        }
        // No branch with a malformed name can exist, and reading one would fail as a bad revision. A start
        // names an existing branch (D15), so the new-branch length cap doesn't apply.
        guard WorktreeBranchName.isWellFormedExistingName(start.branchName) else {
            return .refused(.startBranchNotFound(typedStart))
        }
        let remoteReference = "refs/remotes/\(start.remoteName)/\(start.branchName)"
        let remoteTip = try await reads.remoteTip(remoteName: start.remoteName, branchName: start.branchName)
        if case .unqualified(let name) = start, reads.localBranch(named: name) != nil,
            let localTip = try await reads.localTip(branchName: name)
        {
            let localReference = "refs/heads/\(name)"
            guard let remoteTip else {
                return .planned(Self.newBranchPlan(at: localTip, source: .localBranch, reference: localReference))
            }
            switch try await reads.newestOf(localTip: localTip, remoteTip: remoteTip) {
            case .same:
                return .planned(Self.newBranchPlan(at: localTip, source: .localBranch, reference: localReference))
            case .remoteStrictlyAhead:
                // The start is the remote's commit; the local branch itself isn't moved.
                return .planned(Self.newBranchPlan(at: remoteTip, source: .remoteBranch, reference: remoteReference))
            case .localOnly(let count):
                return .planned(
                    Self.newBranchPlan(
                        at: localTip, source: .localBranch, reference: localReference,
                        localOnlyCommits: WorktreeLocalOnlyCommits(count: count, remoteName: start.remoteName)))
            }
        }
        guard let remoteTip else { return .refused(.startBranchNotFound(typedStart)) }
        return .planned(Self.newBranchPlan(at: remoteTip, source: .remoteBranch, reference: remoteReference))
    }

    private static func existingBranchPlan(
        _ branch: GitBranchSnapshot,
        expectedTip: String,
        fastForwardTo: String?,
        startReference: String,
        localOnlyCommits: WorktreeLocalOnlyCommits? = nil
    ) -> WorktreeBranchPlan {
        WorktreeBranchPlan(
            target: .existingBranch(expectedTip: expectedTip, fastForwardTo: fastForwardTo),
            status: fastForwardTo == nil ? .existing : .fastForwarded,
            upstreamReference: branch.upstreamName,
            startSource: fastForwardTo == nil ? .localBranch : .remoteBranch,
            startReference: startReference,
            localOnlyCommits: localOnlyCommits
        )
    }

    private static func newBranchPlan(
        at commit: String,
        source: WorktreeCreationStartSource,
        reference: String,
        localOnlyCommits: WorktreeLocalOnlyCommits? = nil
    ) -> WorktreeBranchPlan {
        WorktreeBranchPlan(
            target: .newBranch(start: .commit(commit), upstream: nil), status: .created, upstreamReference: nil,
            startSource: source, startReference: reference, localOnlyCommits: localOnlyCommits)
    }
}

/// Tells a ref that doesn't exist apart from one that couldn't be read. The SDK passes libgit2's
/// codes through `libgit2Failure`; `GIT_ENOTFOUND` (-3) is the only one that means "absent".
enum WorktreeReferenceRead {
    private static let notFoundCode: Int32 = -3

    static func isNotFound(_ error: GitDataPlaneError) -> Bool {
        guard case .libgit2Failure(let code, _, _) = error else { return false }
        return code == notFoundCode
    }
}

/// The refs one resolution reads, after LR30's fetch.
private struct WorktreeBranchReads: Sendable {
    let client: any AgentStudioGitLocalClient
    let repositoryPath: URL
    let localBranches: [GitBranchSnapshot]
    let remoteNames: [String]
    let fetch: WorktreeCreationFetchStatus

    enum Newest: Equatable {
        case same
        /// The local tip is an ancestor of the remote's: strictly behind.
        case remoteStrictlyAhead
        /// The local branch has commits the remote's lacks (ahead or diverged), so it is kept.
        case localOnly(Int)
    }

    func localBranch(named name: String) -> GitBranchSnapshot? {
        localBranches.first(where: { $0.name == name })
    }

    func localTip(branchName: String) async throws(GitDataPlaneError) -> String? {
        try await tip(of: "refs/heads/\(branchName)")
    }

    /// The remote-tracking tip, or nil when the remote isn't configured, LR30 found the branch
    /// absent on the remote (even if an old remote-tracking ref is on disk), or no ref exists.
    func remoteTip(remoteName: String, branchName: String) async throws(GitDataPlaneError) -> String? {
        guard remoteNames.contains(remoteName),
            !fetch.confirmsAbsent(remoteName: remoteName, branchName: branchName)
        else { return nil }
        return try await tip(of: "refs/remotes/\(remoteName)/\(branchName)")
    }

    /// LR1's one comparison, for step (2) and a local `--from-branch` start.
    func newestOf(localTip: String, remoteTip: String) async throws(GitDataPlaneError) -> Newest {
        guard localTip != remoteTip else { return .same }
        let counts = try await client.aheadBehind(
            GitAheadBehindRequest(repositoryPath: repositoryPath, localCommit: localTip, otherCommit: remoteTip))
        if counts.ahead > 0 { return .localOnly(counts.ahead) }
        return counts.behind > 0 ? .remoteStrictlyAhead : .same
    }

    private func tip(of reference: String) async throws(GitDataPlaneError) -> String? {
        do throws(GitDataPlaneError) {
            return try await client.resolveRevision(
                GitRevisionResolutionRequest(repositoryPath: repositoryPath, target: .named(reference))
            ).oid
        } catch {
            if WorktreeReferenceRead.isNotFound(error) { return nil }
            throw error
        }
    }
}
