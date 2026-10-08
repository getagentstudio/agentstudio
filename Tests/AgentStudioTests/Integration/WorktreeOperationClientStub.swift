import AgentStudioGit
import Foundation

actor WorktreeDefaultTargetResolutionFailureSchedule {
    private let failingReadNumbers: Set<Int>
    private var readCount = 0

    init(failingReadNumbers: Set<Int>) {
        self.failingReadNumbers = failingReadNumbers
    }

    func shouldFailNextRead() -> Bool {
        readCount += 1
        return failingReadNumbers.contains(readCount)
    }

    func observedReadCount() -> Int {
        readCount
    }
}

struct WorktreeOperationClientStub: AgentStudioGitLocalClient {
    let startPath: URL
    let snapshot: GitWorktreeSnapshot
    let identity: GitRepositoryIdentity
    let baseClient: (any AgentStudioGitLocalClient)?
    let largeFileFillOverride: GitLargeFileFill?
    let listedWorktrees: [GitWorktreeSnapshot]?
    let branchSnapshots: [GitBranchSnapshot]?
    let integrationGrades: [String: GitBranchIntegrationGrade]?
    let integrationAssessmentHandler:
        (
            @Sendable (GitBranchIntegrationRequest) async
                -> Result<GitBranchIntegrationReport, GitDataPlaneError>
        )?
    let statusFailurePaths: Set<String>
    let failsWorktreeListing: Bool
    let failsDefaultTargetResolution: Bool
    let defaultTargetResolutionFailureSchedule: WorktreeDefaultTargetResolutionFailureSchedule?
    let removeWorktreeHandler:
        (@Sendable (GitRemoveWorktreeRequest) async -> Result<GitWorktreeRemovalResult, GitDataPlaneError>)?
    let deleteLocalBranchHandler:
        (
            @Sendable (GitDeleteLocalBranchRequest) async -> Result<
                GitDeleteLocalBranchResult, GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>
            >
        )?
    /// What every fork throws; by default the capability rejection.
    let forkFailure: GitWorktreeForkError

    init(
        startPath: URL,
        snapshot: GitWorktreeSnapshot,
        identity: GitRepositoryIdentity,
        baseClient: (any AgentStudioGitLocalClient)? = nil,
        largeFileFillOverride: GitLargeFileFill? = nil,
        listedWorktrees: [GitWorktreeSnapshot]? = nil,
        branchSnapshots: [GitBranchSnapshot]? = nil,
        integrationGrades: [String: GitBranchIntegrationGrade]? = nil,
        integrationAssessmentHandler: (
            @Sendable (GitBranchIntegrationRequest) async
                -> Result<GitBranchIntegrationReport, GitDataPlaneError>
        )? = nil,
        statusFailurePaths: Set<String> = [],
        failsWorktreeListing: Bool = false,
        failsDefaultTargetResolution: Bool = false,
        defaultTargetResolutionFailureSchedule: WorktreeDefaultTargetResolutionFailureSchedule? = nil,
        removeWorktreeHandler: (
            @Sendable (GitRemoveWorktreeRequest) async -> Result<GitWorktreeRemovalResult, GitDataPlaneError>
        )? = nil,
        deleteLocalBranchHandler: (
            @Sendable (GitDeleteLocalBranchRequest) async -> Result<
                GitDeleteLocalBranchResult, GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>
            >
        )? = nil,
        forkFailure: GitWorktreeForkError = .rejected(reason: .clientCapabilityUnavailable)
    ) {
        self.startPath = startPath
        self.snapshot = snapshot
        self.identity = identity
        self.baseClient = baseClient
        self.largeFileFillOverride = largeFileFillOverride
        self.listedWorktrees = listedWorktrees
        self.branchSnapshots = branchSnapshots
        self.integrationGrades = integrationGrades
        self.integrationAssessmentHandler = integrationAssessmentHandler
        self.statusFailurePaths = statusFailurePaths
        self.failsWorktreeListing = failsWorktreeListing
        self.failsDefaultTargetResolution = failsDefaultTargetResolution
        self.defaultTargetResolutionFailureSchedule = defaultTargetResolutionFailureSchedule
        self.removeWorktreeHandler = removeWorktreeHandler
        self.deleteLocalBranchHandler = deleteLocalBranchHandler
        self.forkFailure = forkFailure
    }

    func repositoryIdentity(for worktreePath: URL) async throws(GitDataPlaneError) -> GitRepositoryIdentity {
        if let baseClient { return try await baseClient.repositoryIdentity(for: worktreePath) }
        return identity
    }

    func worktrees(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitWorktreeSnapshot] {
        if failsWorktreeListing {
            throw .unsupported(message: "injected worktree-list read failure")
        }
        if let listedWorktrees { return listedWorktrees }
        if let baseClient { return try await baseClient.worktrees(for: repositoryPath) }
        throw .unsupported(message: "unexpected worktree listing")
    }

    func validateWorktree(_ request: GitValidateWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreeValidation
    {
        guard request.worktreePath == startPath else {
            return GitWorktreeValidation(snapshot: nil, isValid: false)
        }
        return GitWorktreeValidation(snapshot: snapshot, isValid: true)
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeCreation {
        if let baseClient {
            let creation = try await baseClient.createWorktree(request)
            guard let largeFileFillOverride else { return creation }
            return GitWorktreeCreation(worktree: creation.worktree, largeFiles: largeFileFillOverride)
        }
        throw .unsupported(message: "unexpected worktree creation")
    }

    func forkWorktree(_: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        throw forkFailure
    }

    func forkWorktreeEligibility(sourceWorktreePath _: URL, destinationPath _: URL) async
        -> GitWorktreeForkEligibility
    {
        .unavailable(.clientCapabilityUnavailable)
    }

    func pruneStaleWorktree(_: GitPruneStaleWorktreeRequest) async throws(GitDataPlaneError)
        -> GitWorktreePruneResult
    {
        throw .unsupported(message: "unexpected stale worktree prune")
    }

    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeRemovalResult
    {
        if let removeWorktreeHandler {
            switch await removeWorktreeHandler(request) {
            case .success(let result): return result
            case .failure(let error): throw error
            }
        }
        if let baseClient { return try await baseClient.removeWorktree(request) }
        throw .unsupported(message: "unexpected worktree removal")
    }

    func lockWorktree(_: GitLockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(message: "unexpected worktree lock")
    }

    func unlockWorktree(_: GitUnlockWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeSnapshot {
        throw .unsupported(message: "unexpected worktree unlock")
    }

    func statusObservationPlan(for _: URL) async throws(GitDataPlaneError) -> GitStatusObservationPlan {
        throw .unsupported(message: "unexpected status observation plan")
    }

    func statusFacts(for worktreePath: URL, options: GitStatusOptions, observationPlan: GitStatusObservationPlan?)
        async
        throws(GitDataPlaneError) -> GitStatusFactsRead
    {
        if statusFailurePaths.contains(worktreePath.standardizedFileURL.path) {
            throw .permissionDenied(path: worktreePath)
        }
        if let baseClient {
            return try await baseClient.statusFacts(
                for: worktreePath,
                options: options,
                observationPlan: observationPlan
            )
        }
        throw .unsupported(message: "unexpected status facts")
    }

    func exactLineCountDetail(for _: URL) async throws(GitDataPlaneError) -> GitStatusLineCountDetail {
        throw .unsupported(message: "unexpected status line count")
    }

    func completeStatus(for _: URL, options _: GitStatusOptions) async throws(GitDataPlaneError)
        -> GitCompleteStatusSnapshot
    {
        throw .unsupported(message: "unexpected complete status")
    }

    func trackedPaths(for _: URL, options _: GitTrackedPathsOptions) async throws(GitDataPlaneError)
        -> GitTrackedPathsSnapshot
    {
        throw .unsupported(message: "unexpected tracked paths")
    }

    func isPathIgnored(repositoryAt _: URL, relativePath _: String) async throws(GitDataPlaneError) -> Bool {
        throw .unsupported(message: "unexpected ignored path check")
    }

    func ignoredPaths(repositoryAt _: URL, relativePaths _: [String]) async throws(GitDataPlaneError)
        -> [GitIgnoreCheck]
    {
        throw .unsupported(message: "unexpected ignored path list")
    }

    func branches(for repositoryPath: URL) async throws(GitDataPlaneError) -> [GitBranchSnapshot] {
        if let branchSnapshots { return branchSnapshots }
        if let baseClient { return try await baseClient.branches(for: repositoryPath) }
        throw .unsupported(message: "unexpected branch lookup")
    }

    func remoteNames(for repositoryPath: URL) async throws(GitDataPlaneError) -> [String] {
        if let baseClient { return try await baseClient.remoteNames(for: repositoryPath) }
        throw .unsupported(message: "unexpected remote name lookup")
    }

    /// Preflight reads branch use before the destination checks; without a real client the branch is free.
    func branchUse(_ request: GitBranchUseRequest) async throws(GitDataPlaneError) -> GitBranchUse {
        if let baseClient { return try await baseClient.branchUse(request) }
        return .free
    }

    func aheadBehind(_ request: GitAheadBehindRequest) async throws(GitDataPlaneError) -> GitAheadBehind {
        if let baseClient { return try await baseClient.aheadBehind(request) }
        throw .unsupported(message: "unexpected ahead/behind read")
    }

    func assessBranchIntegration(_ request: GitBranchIntegrationRequest) async throws(GitDataPlaneError)
        -> GitBranchIntegrationReport
    {
        if let integrationAssessmentHandler {
            switch await integrationAssessmentHandler(request) {
            case .success(let report): return report
            case .failure(let error): throw error
            }
        }
        if let integrationGrades {
            let baseAssessments: [String: GitBranchIntegrationAssessment]
            if let baseClient,
                let report = try? await baseClient.assessBranchIntegration(request)
            {
                baseAssessments = Dictionary(
                    report.assessments.map { ($0.branchName, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            } else {
                baseAssessments = [:]
            }
            let assessments = request.branchNames.map { branchName in
                let baseAssessment = baseAssessments[branchName]
                return GitBranchIntegrationAssessment(
                    branchName: branchName,
                    branchCommit: baseAssessment?.branchCommit,
                    grade: integrationGrades[branchName] ?? baseAssessment?.grade ?? .unknown(.readFailed)
                )
            }
            return GitBranchIntegrationReport(targetCommit: request.targetCommit, assessments: assessments)
        }
        if let baseClient { return try await baseClient.assessBranchIntegration(request) }
        throw .unsupported(message: "unexpected branch integration assessment")
    }

    func deleteLocalBranch(_ request: GitDeleteLocalBranchRequest)
        async throws(GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>) -> GitDeleteLocalBranchResult
    {
        if let deleteLocalBranchHandler {
            switch await deleteLocalBranchHandler(request) {
            case .success(let result): return result
            case .failure(let error): throw error
            }
        }
        if let baseClient { return try await baseClient.deleteLocalBranch(request) }
        throw GitLockedOperationFailure(
            reason: .gitFailure(.unsupported(message: "unexpected local branch deletion")),
            lockResidue: nil
        )
    }

    func resolveReviewDefaultTarget(for repositoryPath: URL) async throws(GitDataPlaneError)
        -> GitReviewComparisonBranchTarget?
    {
        let scheduledFailure = await defaultTargetResolutionFailureSchedule?.shouldFailNextRead() ?? false
        if failsDefaultTargetResolution || scheduledFailure {
            throw .unsupported(message: "injected default-target read failure")
        }
        if let baseClient { return try await baseClient.resolveReviewDefaultTarget(for: repositoryPath) }
        throw .unsupported(message: "unexpected default target lookup")
    }

    func captureReviewComparisonTargets(_: GitReviewComparisonTargetCaptureRequest)
        async
        throws(GitDataPlaneError) -> GitReviewComparisonTargetCapture
    {
        throw .unsupported(message: "unexpected comparison target capture")
    }

    func resolveRevision(_ request: GitRevisionResolutionRequest) async throws(GitDataPlaneError) -> GitResolvedRevision
    {
        if let baseClient { return try await baseClient.resolveRevision(request) }
        throw .unsupported(message: "unexpected revision resolution")
    }

    func readTree(_: GitTreeReadRequest) async throws(GitDataPlaneError) -> GitTreeSnapshot {
        throw .unsupported(message: "unexpected tree read")
    }

    func diff(_: GitDiffRequest) async throws(GitDataPlaneError) -> GitDiffSnapshot {
        throw .unsupported(message: "unexpected diff")
    }

    func countCommitRange(_: GitCommitRangeCountRequest) async throws(GitDataPlaneError) -> GitCommitRangeCount {
        throw .unsupported(message: "unexpected commit range count")
    }

    func summarizeDiffImpact(_: GitDiffImpactSummaryRequest) async throws(GitDataPlaneError)
        -> GitDiffImpactSummary
    {
        throw .unsupported(message: "unexpected diff impact summary")
    }

    func contributionDiff(_: GitContributionDiffRequest) async throws(GitDataPlaneError)
        -> GitContributionDiffResult
    {
        throw .unsupported(message: "unexpected contribution diff")
    }

    func directReviewComparison(_: GitDirectReviewComparisonRequest) async throws(GitDataPlaneError)
        -> GitDirectReviewComparisonResult
    {
        throw .unsupported(message: "unexpected direct review comparison")
    }

    func content(_: GitContentRequest) async throws(GitDataPlaneError) -> GitContentPayload {
        throw .unsupported(message: "unexpected content read")
    }
}
