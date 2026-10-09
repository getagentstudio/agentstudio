import AgentStudioGit
import Foundation

/// What `new` asked for, as LR1 reads it.
package struct WorktreeCreationBranchRequest: Sendable, Equatable {
    package let branch: String
    /// `-c` (D23): create `<branch>`; without it, open an existing one.
    package let create: Bool
    /// `--from-branch <start>` as typed; only with `-c`.
    package let startBranch: String?
    package let changesOnly: Bool

    package init(branch: String, create: Bool, startBranch: String?, changesOnly: Bool) {
        self.branch = branch
        self.create = create
        self.startBranch = startBranch
        self.changesOnly = changesOnly
    }
}

/// D23: whether `-c` may create its name.
package enum WorktreeCreateNameCheck: Sendable, Equatable {
    /// The name is free. `originAnswer` is origin's reply in LR30's terms, which a `-c` without a start
    /// reports as its creation fetch.
    case free(originAnswer: WorktreeCreationFetchStatus)
    /// `branchAlreadyExists`, or `originCheckFailed` when origin couldn't be asked: `-c` refuses rather than
    /// risk creating a branch origin already has.
    case refused(WorktreeCreationStop)
    case unreadable(GitDataPlaneError)
}

/// What origin said about `-c`'s name, or why it wasn't asked.
package enum WorktreeOriginNameAnswer: Sendable, Equatable {
    case asked(WorktreeRemoteBranchProbe)
    /// `--no-fetch`: the `origin/<branch>` ref on disk answers, when origin is configured.
    case notAskedNoFetch(originConfigured: Bool)
    /// No `origin` remote is configured.
    case noOrigin
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
///
/// Names are matched with canonical `==` on purpose, for the remote here and for `-c`'s local-name check:
/// git on macOS precomposes typed names (`core.precomposeunicode`), so a spelling in another Unicode
/// normalization names the same remote or branch. Only syntax validity is decided on bytes.
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

    /// D23: `-c` refuses a name that exists locally or on origin. Origin's own answer decides; with `--no-fetch`
    /// the `origin/<branch>` ref on disk does, and with no origin remote only local branches count.
    @concurrent
    package func checkNameIsFree(
        _ branch: String,
        repositoryPath: URL,
        localBranches: [GitBranchSnapshot],
        originAnswer: WorktreeOriginNameAnswer
    ) async -> WorktreeCreateNameCheck {
        let origin = WorktreeStartReference.defaultRemoteName
        guard !localBranches.contains(where: { $0.name == branch }) else {
            return .refused(.branchAlreadyExists(branch: branch))
        }
        switch originAnswer {
        case .asked(.present):
            return .refused(.branchAlreadyExists(branch: branch, remoteName: origin))
        case .asked(.absent):
            return .free(originAnswer: .notOnRemote(remoteName: origin, branchName: branch))
        case .asked(.failed(let failure)):
            return .refused(.originCheckFailed(branch: branch, remoteName: origin, reason: failure.reason))
        case .noOrigin:
            return .free(originAnswer: .skipped(.noRemote))
        case .notAskedNoFetch(originConfigured: false):
            return .free(originAnswer: .skipped(.noFetchFlag))
        case .notAskedNoFetch(originConfigured: true):
            break
        }
        let reads = WorktreeBranchReads(
            client: client, repositoryPath: repositoryPath, localBranches: localBranches, remoteNames: [origin],
            fetch: .skipped(.noFetchFlag))
        do throws(GitDataPlaneError) {
            guard try await reads.remoteTip(remoteName: origin, branchName: branch) == nil else {
                return .refused(.branchAlreadyExists(branch: branch, remoteName: origin))
            }
            return .free(originAnswer: .skipped(.noFetchFlag))
        } catch {
            return .unreadable(error)
        }
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
            guard request.create else {
                return try await resolveExistingBranch(
                    request.branch, remoteName: WorktreeStartReference.defaultRemoteName, reads: reads)
            }
            // `-c`'s name was checked free before this (D23); `--changes-only` always starts at the source's HEAD.
            guard let startBranch = request.startBranch, !request.changesOnly else {
                return .planned(Self.sourceHeadPlan)
            }
            let start = WorktreeStartReference.parse(startBranch, remoteNames: remoteNames)
            return try await resolveStart(start, typedStart: startBranch, reads: reads)
        } catch {
            return .unreadable(error)
        }
    }

    /// The branch LR30 reports on: `-c --from-branch`'s start, else `<branch>` on origin.
    private static func comparedReference(
        for request: WorktreeCreationBranchRequest,
        remoteNames: [String]
    ) -> WorktreeStartReference {
        guard request.create, let startBranch = request.startBranch else {
            return .unqualified(branchName: request.branch)
        }
        return WorktreeStartReference.parse(startBranch, remoteNames: remoteNames)
    }

    /// `-c` with no start, and `--changes-only`: a new branch at the source's HEAD, with no upstream.
    private static let sourceHeadPlan = WorktreeBranchPlan(
        target: .newBranch(start: .sourceHead, upstream: nil), status: .created, upstreamReference: nil,
        startSource: .sourceHead, startReference: nil, localOnlyCommits: nil)

    /// Steps (2)–(4) without `-c`: `<branch>` itself, compared with `<remoteName>/<branch>`.
    private func resolveExistingBranch(
        _ branch: String,
        remoteName: String,
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
        // Step (4): opening needs a branch; creating one takes `-c` (D23).
        return .refused(.creationStopped(.noSuchBranch(branch: branch)))
    }

    /// `-c --from-branch`: a new `<branch>` at the start's commit.
    private func resolveStart(
        _ start: WorktreeStartReference,
        typedStart: String,
        reads: WorktreeBranchReads
    ) async throws(GitDataPlaneError) -> WorktreeBranchResolution {
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
