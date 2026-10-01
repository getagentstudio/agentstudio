import AgentStudioCore
import AgentStudioGit
import CryptoKit
import Foundation

@testable import AgentStudioBridge

extension AgentStudioGitLocalClient {
    func resolveReviewDefaultTarget(for _: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    {
        throw GitDataPlaneError.unsupported(message: "review comparison targets not configured")
    }

    func captureReviewComparisonTargets(_ request: GitReviewComparisonTargetCaptureRequest)
        async throws(GitDataPlaneError) -> GitReviewComparisonTargetCapture
    {
        throw GitDataPlaneError.unsupported(message: "review comparison targets not configured")
    }

    func contributionDiff(_: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    {
        throw GitDataPlaneError.unsupported(message: "contribution diff not configured")
    }

    func directReviewComparison(_: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    {
        throw GitDataPlaneError.unsupported(message: "direct review comparison not configured")
    }
}

struct GitContentLocator: Hashable, Sendable {
    let target: GitDiffTarget
    let path: String
}

func makeBridgeStatusPhysicalGate() -> AgentStudioGitStatusPhysicalGate {
    AgentStudioGitStatusPhysicalGate()
}

actor AgentStudioGitLocalClientFake: AgentStudioGitLocalClient {
    private let reviewComparisonTargetCapture: GitReviewComparisonTargetCapture?
    private var contributionDiffSnapshot: GitContributionDiffSnapshot?
    private var directReviewComparisonSnapshot: GitDirectReviewComparisonSnapshot?
    private let commitRangeCount: GitCommitRangeCount?
    private var diffSnapshot: GitDiffSnapshot
    private let diffFailure: GitDataPlaneError?
    private var contentByLocator: [GitContentLocator: GitContentPayload]
    private var resolvedRevisionByTarget: [GitRevisionTarget: GitResolvedRevision]
    private let contentFailureByLocator: [GitContentLocator: GitDataPlaneError]
    private let treeSnapshotByRequest: [GitTreeReadRequest: GitTreeSnapshot]
    private let treeFailure: GitDataPlaneError?
    private let statusSnapshot: GitStatusFactsSnapshot?
    private let statusFailure: GitDataPlaneError?
    private let statusSnapshotByOptions: [GitStatusOptions: GitStatusFactsSnapshot]
    private let statusFailureByOptions: [GitStatusOptions: GitDataPlaneError]
    private let contentReadGateByLocator: [GitContentLocator: BridgeGitContentReadGate]
    private let revisionResolutionGate: BridgeGitContentReadGate?
    private let revisionResolutionFailure: GitDataPlaneError?
    private var diffRequests: [GitDiffRequest] = []
    private var contentRequests: [GitContentRequest] = []
    private var treeRequests: [GitTreeReadRequest] = []
    private var statusRequests: [(URL, GitStatusOptions)] = []
    private var revisionResolutionRequests: [GitRevisionResolutionRequest] = []
    private var reviewComparisonTargetRequests: [GitReviewComparisonTargetCaptureRequest] = []
    private var contributionDiffRequests: [GitContributionDiffRequest] = []
    private var directReviewComparisonRequests: [GitDirectReviewComparisonRequest] = []
    private var commitRangeCountRequests: [GitCommitRangeCountRequest] = []

    init(
        reviewComparisonTargetCapture: GitReviewComparisonTargetCapture? = nil,
        contributionDiffSnapshot: GitContributionDiffSnapshot? = nil,
        directReviewComparisonSnapshot: GitDirectReviewComparisonSnapshot? = nil,
        commitRangeCount: GitCommitRangeCount? = nil,
        diffSnapshot: GitDiffSnapshot = GitDiffSnapshot(files: []),
        diffFailure: GitDataPlaneError? = nil,
        contentByLocator: [GitContentLocator: GitContentPayload] = [:],
        contentFailureByLocator: [GitContentLocator: GitDataPlaneError] = [:],
        treeSnapshotByRequest: [GitTreeReadRequest: GitTreeSnapshot] = [:],
        treeFailure: GitDataPlaneError? = nil,
        statusSnapshot: GitStatusFactsSnapshot? = nil,
        statusFailure: GitDataPlaneError? = nil,
        statusSnapshotByOptions: [GitStatusOptions: GitStatusFactsSnapshot] = [:],
        statusFailureByOptions: [GitStatusOptions: GitDataPlaneError] = [:],
        resolvedRevisionByTarget: [GitRevisionTarget: GitResolvedRevision] = [:],
        contentReadGateByLocator: [GitContentLocator: BridgeGitContentReadGate] = [:],
        revisionResolutionGate: BridgeGitContentReadGate? = nil,
        revisionResolutionFailure: GitDataPlaneError? = nil
    ) {
        self.reviewComparisonTargetCapture = reviewComparisonTargetCapture
        self.contributionDiffSnapshot = contributionDiffSnapshot
        self.directReviewComparisonSnapshot = directReviewComparisonSnapshot
        self.commitRangeCount = commitRangeCount
        self.diffSnapshot = diffSnapshot
        self.diffFailure = diffFailure
        self.contentByLocator = contentByLocator
        self.contentFailureByLocator = contentFailureByLocator
        self.treeSnapshotByRequest = treeSnapshotByRequest
        self.treeFailure = treeFailure
        self.statusSnapshot = statusSnapshot
        self.statusFailure = statusFailure
        self.statusSnapshotByOptions = statusSnapshotByOptions
        self.statusFailureByOptions = statusFailureByOptions
        self.resolvedRevisionByTarget = resolvedRevisionByTarget
        self.contentReadGateByLocator = contentReadGateByLocator
        self.revisionResolutionGate = revisionResolutionGate
        self.revisionResolutionFailure = revisionResolutionFailure
    }

    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func pruneStaleWorktree(_ request: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeRemovalResult
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func lockWorktree(_ request: GitLockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func unlockWorktree(_ request: GitUnlockWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeSnapshot
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func statusObservationPlan(for _: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func statusFacts(
        for worktreePath: URL,
        options: GitStatusOptions,
        observationPlan _: GitStatusObservationPlan?
    ) async throws(GitDataPlaneError) -> GitStatusFactsRead {
        statusRequests.append((worktreePath, options))
        if let optionFailure = statusFailureByOptions[options] {
            throw optionFailure
        }
        if let optionSnapshot = statusSnapshotByOptions[options] {
            return GitStatusFactsRead(facts: optionSnapshot, exactCleanBaseline: nil)
        }
        if let statusFailure {
            throw statusFailure
        }
        guard let statusSnapshot else {
            throw GitDataPlaneError.unsupported(message: "not used")
        }
        return GitStatusFactsRead(facts: statusSnapshot, exactCleanBaseline: nil)
    }

    func exactLineCountDetail(for worktreePath: URL) async throws(GitDataPlaneError)
        -> GitStatusLineCountDetail
    {
        GitStatusLineCountDetail(
            repositoryRoot: worktreePath,
            worktreePath: worktreePath,
            generatedAtUnixMilliseconds: 10,
            linesAdded: 0,
            linesDeleted: 0
        )
    }

    func completeStatus(for worktreePath: URL, options: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    {
        GitCompleteStatusSnapshot(
            facts: try await statusFacts(for: worktreePath, options: options).facts,
            lineCountDetail: try await exactLineCountDetail(for: worktreePath)
        )
    }

    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func assessBranchIntegration(_: GitBranchIntegrationRequest) async throws(GitDataPlaneError)
        -> GitBranchIntegrationReport
    {
        throw GitDataPlaneError.unsupported(message: "not used")
    }

    func deleteLocalBranch(_: GitDeleteLocalBranchRequest)
        async throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitDeleteLocalBranchResult
    {
        throw GitLockedOperationFailure(reason: .gitFailure(.unsupported(message: "not used")), lockResidue: nil)
    }

    func captureReviewComparisonTargets(_ request: GitReviewComparisonTargetCaptureRequest)
        async throws(GitDataPlaneError) -> GitReviewComparisonTargetCapture
    {
        reviewComparisonTargetRequests.append(request)
        guard let reviewComparisonTargetCapture else {
            throw GitDataPlaneError.unsupported(message: "review comparison targets not configured")
        }
        return reviewComparisonTargetCapture
    }

    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError)
        -> GitResolvedRevision
    {
        revisionResolutionRequests.append(request)
        if let revisionResolutionFailure {
            throw revisionResolutionFailure
        }
        guard let revision = resolvedRevisionByTarget[request.target] else {
            throw GitDataPlaneError.unsupported(message: "missing revision")
        }
        if let revisionResolutionGate {
            await revisionResolutionGate.waitUntilReleased()
        }
        return revision
    }

    func trackedPaths(
        for worktreePath: URL,
        options: GitTrackedPathsOptions
    ) async throws(GitDataPlaneError) -> GitTrackedPathsSnapshot {
        GitTrackedPathsSnapshot(entries: [], rawIndexEntryCount: 0)
    }

    func isPathIgnored(
        repositoryAt worktreePath: URL,
        relativePath: String
    ) async throws(GitDataPlaneError) -> Bool {
        false
    }

    func ignoredPaths(
        repositoryAt worktreePath: URL,
        relativePaths: [String]
    ) async throws(GitDataPlaneError) -> [GitIgnoreCheck] {
        relativePaths.map { GitIgnoreCheck(relativePath: $0, isIgnored: false) }
    }

    func readTree(_ request: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        treeRequests.append(request)
        if let treeFailure {
            throw treeFailure
        }
        guard let treeSnapshot = treeSnapshotByRequest[request] else {
            throw GitDataPlaneError.unsupported(message: "missing tree for \(request.path ?? "<root>")")
        }
        return treeSnapshot
    }

    func diff(_ request: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        diffRequests.append(request)
        if let diffFailure {
            throw diffFailure
        }
        return diffSnapshot
    }

    func countCommitRange(_ request: GitCommitRangeCountRequest) async throws(GitDataPlaneError)
        -> GitCommitRangeCount
    {
        commitRangeCountRequests.append(request)
        guard let commitRangeCount else {
            throw GitDataPlaneError.unsupported(message: "commit range count not configured")
        }
        return commitRangeCount
    }

    func summarizeDiffImpact(_: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    {
        throw GitDataPlaneError.unsupported(message: "diff impact summary not configured")
    }

    func contributionDiff(_ request: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    {
        contributionDiffRequests.append(request)
        guard let contributionDiffSnapshot else {
            throw GitDataPlaneError.unsupported(message: "contribution diff not configured")
        }
        return .clientFixture(snapshot: contributionDiffSnapshot)
    }

    func directReviewComparison(_ request: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    {
        directReviewComparisonRequests.append(request)
        guard let directReviewComparisonSnapshot else {
            throw GitDataPlaneError.unsupported(message: "direct review comparison not configured")
        }
        return .clientFixture(snapshot: directReviewComparisonSnapshot)
    }

    func content(_ request: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        contentRequests.append(request)
        let locator = GitContentLocator(target: request.target, path: request.path)
        if let contentReadGate = contentReadGateByLocator[locator] {
            await contentReadGate.waitUntilReleased()
        }
        if let failure = contentFailureByLocator[locator] {
            throw failure
        }
        guard let content = contentByLocator[locator] else {
            throw GitDataPlaneError.unsupported(message: "missing content for \(request.path)")
        }
        return content
    }

    func recordedDiffRequests() -> [GitDiffRequest] {
        diffRequests
    }

    func recordedDirectReviewComparisonRequests() -> [GitDirectReviewComparisonRequest] {
        directReviewComparisonRequests
    }

    func recordedContentRequests() -> [GitContentRequest] {
        contentRequests
    }

    func recordedTreeRequests() -> [GitTreeReadRequest] {
        treeRequests
    }

    func recordedStatusRequestsCount() -> Int {
        statusRequests.count
    }

    func recordedStatusOptions() -> [GitStatusOptions] {
        statusRequests.map(\.1)
    }

    func recordedRevisionResolutionRequests() -> [GitRevisionResolutionRequest] {
        revisionResolutionRequests
    }

    func recordedReviewComparisonTargetRequests() -> [GitReviewComparisonTargetCaptureRequest] {
        reviewComparisonTargetRequests
    }

    func recordedContributionDiffRequests() -> [GitContributionDiffRequest] {
        contributionDiffRequests
    }

    func recordedCommitRangeCountRequests() -> [GitCommitRangeCountRequest] {
        commitRangeCountRequests
    }

    func replaceDiffSnapshot(_ snapshot: GitDiffSnapshot) {
        diffSnapshot = snapshot
    }

    func replaceContributionDiffSnapshot(_ snapshot: GitContributionDiffSnapshot) {
        contributionDiffSnapshot = snapshot
    }

    func replaceContent(_ content: GitContentPayload, for locator: GitContentLocator) {
        contentByLocator[locator] = content
    }

    func replaceResolvedRevision(
        _ revision: GitResolvedRevision,
        for target: GitRevisionTarget
    ) {
        resolvedRevisionByTarget[target] = revision
    }
}

actor BridgeGitContentReadGate {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        guard !didRelease else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

func gitContentPayload(_ content: String) -> GitContentPayload {
    GitContentPayload(
        data: Data(content.utf8),
        contentHash: bridgeSHA256ContentHash(content),
        contentHashAlgorithm: "sha256",
        isBinary: false
    )
}

func gitBlobSHA1ContentHash(_ content: String) -> String {
    let data = Data(content.utf8)
    var blobData = Data("blob \(data.count)\0".utf8)
    blobData.append(data)
    return Insecure.SHA1.hash(data: blobData).map { String(format: "%02x", $0) }.joined()
}
