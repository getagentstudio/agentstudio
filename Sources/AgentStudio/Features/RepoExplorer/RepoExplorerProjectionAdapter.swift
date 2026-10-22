import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation

enum RepoExplorerProjectionSlot: Hashable, Sendable {
    case sidebar
}

private enum RepoExplorerRenderedRowContent: Equatable {
    case sectionHeader(RepoExplorerSidebarSectionKind)
    case loadingSectionHeader(RepoExplorerSidebarSectionKind, RepoExplorerLoadingSectionState)
    case loadingRepo(RepoExplorerSidebarSectionKind, UUID, String, Bool)
    case groupHeader(RepoExplorerRenderedGroupHeaderContent)
    case worktree(RepoExplorerRenderedWorktreeContent)
    case pane(RepoExplorerProjectedPaneRow)
    case unassociatedPane(RepoExplorerUnassociatedPaneDestination, RepoExplorerPaneRowFacts?)
    case topologyFault(Int)
    case unresolved(RepoExplorerRowID)
}

private struct RepoExplorerRenderedGroupHeaderContent: Equatable {
    let id: String
    let title: String
    let organizationName: String?
    let colorHex: String?
    let isExpanded: Bool
    let semanticRepoPath: URL?
    let paneDestinations: [RepoExplorerPaneDestination]
}

private struct RepoExplorerRenderedWorktreeContent: Equatable {
    let groupId: String
    let rowId: RepoExplorerRowID
    let repoId: UUID
    let worktreeId: UUID
    let worktreePath: URL
    let checkoutTitle: String
    let isMainCheckout: Bool
    let projectedFavoriteState: Bool
    let isMainWorktree: Bool
    let checkoutColorHex: String
    let placementText: String
    let branchStatus: GitBranchStatus
    let branchName: String
    let bridgeCommandResolution: BridgePaneCommandResolution
    let paneDestinations: [RepoExplorerPaneDestination]
}

typealias RepoExplorerMaterializedProjection = EagerDerivedAtom<
    RepoExplorerProjectionIntent,
    Int,
    RepoExplorerProjectionWork,
    RepoExplorerProjectionCandidate,
    RepoExplorerProjectionResult
>

typealias RepoExplorerMaterializedProjectionFamily = EagerDerivedAtomFamily<
    RepoExplorerProjectionSlot,
    RepoExplorerProjectionIntent,
    Int,
    RepoExplorerProjectionWork,
    RepoExplorerProjectionCandidate,
    RepoExplorerProjectionResult
>

@MainActor
@Observable
final class RepoExplorerProjectionAdapter {
    var publishedResult: RepoExplorerProjectionResult?
    var publishedRevision = 0
    @ObservationIgnored var projectionFamily: RepoExplorerMaterializedProjectionFamily!
    @ObservationIgnored let onProjectionSuppressed:
        @MainActor @Sendable (
            RepoExplorerProjectionResult
        ) -> Void
    @ObservationIgnored var hasStopped = false
    @ObservationIgnored var observationGeneration = 0
    @ObservationIgnored var semanticBaselineSequence: UInt64 = 0
    @ObservationIgnored var semanticBaselineResult: RepoExplorerProjectionResult?
    @ObservationIgnored var acknowledgedMaterializationBaseline: RepoExplorerMaterializationBaseline?
    @ObservationIgnored var materializationDemandEpoch: UInt64 = 0
    @ObservationIgnored var isMaterializationDemandSuspended = false
    @ObservationIgnored weak var materializationHost: RepoExplorerMaterializationHost?
    @ObservationIgnored var pendingMaterializationSettlement: RepoExplorerPendingMaterializationSettlement?
    @ObservationIgnored var nextMaterializationCandidateID: UInt64 = 0
    @ObservationIgnored var lastRecoveryBaselineIdentity: RepoExplorerAcknowledgedBaselineIdentity?
    @ObservationIgnored let inputCapture: RepoExplorerProjectionInputCapture?
    @ObservationIgnored let performanceTraceRecorder: AgentStudioPerformanceTraceRecorder?
    @ObservationIgnored let recencyNow: @MainActor @Sendable () -> Date
    @ObservationIgnored var deadlineWorker: RepoExplorerProjectionWorker!
    @ObservationIgnored var deadlineMessageTask: Task<Void, Never>?
    @ObservationIgnored var deadlineRequestGeneration = 0
    @ObservationIgnored var activeDeadlineObservationGeneration: Int?
    @ObservationIgnored let initialProjectionTrigger: AppPolicies.SidebarProjection.Trigger
    @ObservationIgnored var isDemanded = false
    @ObservationIgnored var query = ""
    @ObservationIgnored var projectionGeneration = 0
    @ObservationIgnored var cachedProjectionRequest: RepoExplorerProjectionRequest?
    @ObservationIgnored var recencyReferenceDate = Date()
    @ObservationIgnored var observationTokens: Set<RepoExplorerObservationToken> = []
    @ObservationIgnored var pendingInvalidation = RepoExplorerPendingInvalidation()
    @ObservationIgnored var invalidationTask: Task<Void, Never>?
    @ObservationIgnored var observationRegistration = RepoExplorerObservationRegistration.hidden

    func performanceProofReadback(
        focusDisposition: RepoExplorerPerformanceProofReadback.FocusDisposition
    ) -> RepoExplorerPerformanceProofReadback? {
        guard let semanticBaselineResult, let materializationHost,
            let visibleBaseline = acknowledgedMaterializationBaseline ?? materializationHost.acceptedBaseline
        else { return nil }
        let proofSummary =
            visibleBaseline.presentation.contentSnapshot?
            .performanceProofPresentationSummary
            ?? RepoExplorerPerformanceProofPresentationSummary(
                inactiveRepositoryHeaderCount: 0,
                suppressedRepositoryFactRowCount: 0,
                updatingRepositoryHeaderCount: 0
            )
        return RepoExplorerPerformanceProofReadback(
            semanticGeneration: semanticBaselineResult.generation,
            acknowledgedRevision: visibleBaseline.revision,
            visibleGeneration: visibleBaseline.visibleGeneration,
            representedRowCount: visibleBaseline.rowCount,
            materializationFingerprint: visibleBaseline.fingerprint.rawValue,
            inactiveRepositoryHeaderCount: proofSummary.inactiveRepositoryHeaderCount,
            suppressedRepositoryFactRowCount: proofSummary.suppressedRepositoryFactRowCount,
            updatingRepositoryHeaderCount: proofSummary.updatingRepositoryHeaderCount,
            groupingMode: semanticBaselineResult.snapshot.groupingMode,
            query: semanticBaselineResult.snapshot.query,
            isDemanded: isDemanded,
            presentationIsReady: materializationHost.isPresentationReady,
            focusDisposition: focusDisposition,
            accessibilityDisposition: materializationHost.isPresentationReady && materializationHost.window != nil
                ? .ready
                : .unavailable
        )
    }

    init(
        inputCapture: RepoExplorerProjectionInputCapture? = nil,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil,
        recencyNow: @escaping @MainActor @Sendable () -> Date = Date.init,
        deadlineNow: @escaping @Sendable () -> Date = Date.init,
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        recencyDelay: AsyncDelay = .taskSleep,
        initialProjectionTrigger: AppPolicies.SidebarProjection.Trigger = .startupDiagnostic,
        onProjectionSuppressed:
            @escaping @MainActor @Sendable (
                RepoExplorerProjectionResult
            ) -> Void = { _ in },
        onProjectionCompletion:
            @escaping @MainActor @Sendable (RepoExplorerMaterializedProjection.ProjectionCompletion) -> Void = { _ in },
        project:
            @escaping @Sendable (RepoExplorerProjectionWork) throws(CancellationError)
            -> RepoExplorerProjectionResult = { work throws(CancellationError) in
                do {
                    return try RepoExplorerProjectionWorker.project(work)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    preconditionFailure("Repo Explorer projection threw a non-cancellation error: \(error)")
                }
            }
    ) {
        self.inputCapture = inputCapture
        self.performanceTraceRecorder = performanceTraceRecorder
        self.recencyNow = recencyNow
        self.initialProjectionTrigger = initialProjectionTrigger
        self.onProjectionSuppressed = onProjectionSuppressed
        projectionFamily = RepoExplorerMaterializedProjectionFamily(
            telemetryLabel: "repo_explorer_projection",
            performanceOutcome: { stage, outcome in
                RepoExplorerPerformanceTelemetry.shared.record(stage: stage, outcome: outcome)
            },
            intentIdentity: \.generation,
            combinePendingIntents: RepoExplorerProjectionIntent.combinePending,
            prepare: { [weak self] intent, _ in
                self?.prepareProjectionWork(intent) ?? .rejected
            },
            project: { work throws(CancellationError) in
                RepoExplorerProjectionCandidate(work: work, result: try project(work))
            },
            classify: { [weak self] candidate, _ in
                self?.classifyProjectionCandidate(candidate) ?? .rejected
            },
            onAwaitingOwner: { [weak self] _, token, candidate, proposedValue in
                self?.applyAwaitingProjectionCandidate(
                    token: token,
                    candidate: candidate,
                    proposedValue: proposedValue
                )
            },
            onProjectionCompletion: { [weak self] _, completion in
                self?.handleProjectionCompletion(completion)
                onProjectionCompletion(completion)
            }
        )
        deadlineWorker = RepoExplorerProjectionWorker(
            deadlineDelay: recencyDelay,
            deadlineNow: deadlineNow,
            continuousNow: continuousNow,
            onDeadline: { [weak self] generation, preparedDeadline in
                self?.applyPreparedPresentationDeadline(preparedDeadline, generation: generation)
            }
        )
        _ = projectionFamily.materialize(for: .sidebar)
    }

    var materializedProjection: RepoExplorerMaterializedProjection? {
        projectionFamily.atom(for: .sidebar)
    }

    func admit(_ request: RepoExplorerProjectionRequest) {
        guard !hasStopped else { return }
        establishDirectAdmissionIntentIfNeeded(request)
        projectionFamily.admit(.full(request), for: .sidebar)
    }

    func admitDelta(
        _ changes: Set<RepoExplorerScopedProjectionChange>,
        request: RepoExplorerProjectionRequest
    ) {
        guard !hasStopped, !changes.isEmpty else { return }
        establishDirectAdmissionIntentIfNeeded(request)
        projectionFamily.admit(
            .delta(
                RepoExplorerProjectionDeltaIntent(
                    targetRequest: request,
                    changes: changes,
                    structuralTarget: RepoExplorerProjectionStructuralTarget(request: request)
                )
            ),
            for: .sidebar
        )
    }

    private func establishDirectAdmissionIntentIfNeeded(
        _ request: RepoExplorerProjectionRequest
    ) {
        guard inputCapture == nil else { return }
        projectionGeneration = request.generation
        cachedProjectionRequest = request
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        suspendDemand()
        projectionFamily.stop()
    }

    func stopAndDrain() async {
        stop()
        await deadlineMessageTask?.value
        await projectionFamily.stopAndDrain()
    }

    func traceAttributes(
        for request: RepoExplorerProjectionRequest,
        phase: String,
        extra: [String: AgentStudioTraceValue] = [:]
    ) -> [String: AgentStudioTraceValue] {
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.sidebar.surface": .string(request.snapshot.surface == .panes ? "panes" : "repo"),
            "agentstudio.performance.sidebar.phase": .string(phase),
            "agentstudio.performance.sidebar.trigger": .string(request.trigger.rawValue),
            "agentstudio.performance.sidebar.query_state": .string(
                request.snapshot.query.isEmpty ? "empty" : "non_empty"),
            "agentstudio.performance.sidebar.group_mode": .string(request.snapshot.groupingMode.rawValue),
            "agentstudio.performance.sidebar.sort_order": .string(request.snapshot.sortOrder.rawValue),
            "agentstudio.performance.sidebar.repo.count": .int(request.snapshot.repos.count),
            "agentstudio.performance.sidebar.query_character.count": .int(request.snapshot.query.count),
            "agentstudio.performance.sidebar.collapsed_group.count": .int(request.collapsedGroupIds.count),
            "agentstudio.performance.sidebar.is_filtering": .bool(request.isFiltering),
        ]
        attributes.merge(extra) { _, newValue in newValue }
        return attributes
    }

}
