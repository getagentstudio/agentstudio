import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

enum BridgePaneRefreshLane: String, Codable, Hashable, Sendable {
    case file
    case review
}

enum BridgePaneRefreshCatchUpOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case stale
    case streamReset
}

struct BridgePaneRefreshDirtyFact: Sendable {
    let generation: UInt64
    let fileChangeset: FileChangeset?
    let latestFileStatus: GitWorkingTreeStatus?
    let latestBatchSequence: UInt64
    let requiresReviewRefresh: Bool
    let reviewRefreshScope: ReviewGitRefreshScope?
    let operationCorrelationID: String?
    let operationStageAttempt: Int

    var filePaths: [String] {
        fileChangeset?.paths ?? []
    }
}

struct BridgePaneRefreshWorkAdmission: Sendable {
    fileprivate let gate: BridgePaneRefreshWorkAdmissionGate
    fileprivate let token: BridgePaneRefreshWorkAdmissionGate.Token

    func withValidAdmission<MutationResult>(
        _ mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try gate.withValidAdmission(token, perform: mutation)
    }

    func registerInvalidationHandler(
        _ handler: @escaping @Sendable () -> Void
    ) -> UUID? {
        gate.registerInvalidationHandler(token, handler: handler)
    }

    func removeInvalidationHandler(_ handlerId: UUID) {
        gate.removeInvalidationHandler(handlerId)
    }
}

/// Thread-safe foreground-work admission shared with off-main Bridge producers.
///
/// The MainActor coordinator remains the sole activity writer. Product actors
/// may only acquire and validate tokens through this source; they cannot mint or
/// change pane activity. Catch-up reservations additionally bind their token to
/// one File or Review authority generation, while generic content admissions
/// remain activity-only.
struct BridgePaneRefreshWorkAdmissionSource: Sendable {
    fileprivate let gate: BridgePaneRefreshWorkAdmissionGate

    /// Mirror the Review epoch accepted by BridgeProductSession.prepare.
    /// Call while the matching product admission is valid so source updates and
    /// canonical target commits share the product-admission → intent-lock order.
    func admitReviewComparisonIntent(
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext
    ) {
        gate.admitReviewComparisonIntent(
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission
        )
    }

    /// Keep the floor lock held through the synchronous target mutation so a
    /// newer admitted Review intent cannot slip between validation and commit.
    func withCurrentReviewComparisonIntent<MutationResult>(
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext,
        perform mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try gate.withCurrentReviewComparisonIntent(
            workerDerivationEpoch: workerDerivationEpoch,
            productAdmission: productAdmission,
            perform: mutation
        )
    }

    func acquire() -> BridgePaneRefreshWorkAdmission? {
        gate.acquire(validity: .foregroundOnly)
    }

    func acquireReviewContentContinuation() -> BridgePaneRefreshWorkAdmission? {
        gate.acquire(validity: .foregroundOrLoadedHidden)
    }
}

struct BridgePaneRefreshCatchUpReservation: Sendable {
    let id: UUID
    let authorityGeneration: UInt64
    let dirtyGeneration: UInt64
    let lanes: Set<BridgePaneRefreshLane>
    let fileChangeset: FileChangeset?
    let latestFileStatus: GitWorkingTreeStatus?
    let latestBatchSequence: UInt64
    let requiresReviewRefresh: Bool
    let reviewRefreshScope: ReviewGitRefreshScope?
    let operationCorrelationID: String
    let operationStageAttempt: Int
    let foregroundWorkAdmission: BridgePaneRefreshWorkAdmission

    fileprivate let dirtyFact: BridgePaneRefreshDirtyFact

    var filePaths: [String] {
        fileChangeset?.paths ?? []
    }
}

struct BridgePaneRefreshAdmissionSnapshot: Sendable {
    let activity: BridgePaneActivity
    let foregroundWorkEpoch: UInt64
    let dirtyFact: BridgePaneRefreshDirtyFact?
    let activeRefreshPass: BridgePaneRefreshCatchUpReservation?
    let refreshPassCount: Int
    let fileRefreshFailure: BridgePaneProductFileRefreshFailure?
}

struct BridgePaneProductPresentationSnapshot: Equatable, Sendable {
    let nativeActivity: BridgePaneActivity
    let presentationRevision: Int
    let refreshingLanes: Set<BridgePaneRefreshLane>
    let fileRefreshFailure: BridgePaneProductFileRefreshFailure?
    let operationCorrelationID: String?
    let reviewComparison: BridgePaneReviewComparisonPresentation?

    init(
        nativeActivity: BridgePaneActivity,
        presentationRevision: Int,
        refreshingLanes: Set<BridgePaneRefreshLane>,
        fileRefreshFailure: BridgePaneProductFileRefreshFailure? = nil,
        operationCorrelationID: String? = nil,
        reviewComparison: BridgePaneReviewComparisonPresentation?
    ) {
        self.nativeActivity = nativeActivity
        self.presentationRevision = presentationRevision
        self.refreshingLanes = refreshingLanes
        self.fileRefreshFailure = fileRefreshFailure
        self.operationCorrelationID = operationCorrelationID
        self.reviewComparison = reviewComparison
    }
}

/// Owns foreground work admission and the one pane-wide hidden freshness fact.
///
/// Activity admission is synchronous and lock-backed so File/Review producer
/// actors can validate their original epoch after suspension without hopping to
/// `MainActor`. Dirty-state and catch-up sequencing remain pane-controller state.
@MainActor
final class BridgePaneRefreshAdmissionCoordinator {
    private let workAdmissionGate: BridgePaneRefreshWorkAdmissionGate
    private var activity: BridgePaneActivity
    private var dirtyFactByLane: [BridgePaneRefreshLane: BridgePaneRefreshDirtyFact] = [:]
    private var activeRefreshPassByLane: [BridgePaneRefreshLane: BridgePaneRefreshCatchUpReservation] = [:]
    private var nextDirtyGeneration: UInt64 = 0
    private var nextAuthorityGeneration: UInt64 = 0
    private var authorityGenerationByLane: [BridgePaneRefreshLane: UInt64] = [:]
    private var presentationRevision = 1
    private var refreshPassCount = 0
    private var reviewComparison: BridgePaneReviewComparisonPresentation?
    private var fileRefreshFailure: BridgePaneProductFileRefreshFailure?

    init(
        initialActivity: BridgePaneActivity = .dormant,
        initialReviewComparison: BridgePaneReviewComparisonPresentation? = nil
    ) {
        activity = initialActivity
        reviewComparison = initialReviewComparison
        workAdmissionGate = BridgePaneRefreshWorkAdmissionGate(initialActivity: initialActivity)
    }

    var diagnosticSnapshot: BridgePaneRefreshAdmissionSnapshot {
        BridgePaneRefreshAdmissionSnapshot(
            activity: activity,
            foregroundWorkEpoch: workAdmissionGate.diagnosticSnapshot.epoch,
            dirtyFact: combinedDirtyFact,
            activeRefreshPass: activeRefreshPassByLane[.file] ?? activeRefreshPassByLane[.review],
            refreshPassCount: refreshPassCount,
            fileRefreshFailure: fileRefreshFailure
        )
    }

    var workAdmissionSource: BridgePaneRefreshWorkAdmissionSource {
        BridgePaneRefreshWorkAdmissionSource(gate: workAdmissionGate)
    }

    var productPresentationSnapshot: BridgePaneProductPresentationSnapshot {
        BridgePaneProductPresentationSnapshot(
            nativeActivity: activity,
            presentationRevision: presentationRevision,
            refreshingLanes: Set(activeRefreshPassByLane.keys),
            fileRefreshFailure: fileRefreshFailure,
            operationCorrelationID: activeRefreshPassByLane[.review]?.operationCorrelationID,
            reviewComparison: reviewComparison
        )
    }

    func publishReviewComparisonDefaultTarget(
        _ repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    ) {
        guard let reviewComparison else { return }
        let nextComparison = BridgePaneReviewComparisonPresentation(
            activeTarget: reviewComparison.activeTarget,
            attempt: reviewComparison.attempt,
            displayedSnapshot: reviewComparison.displayedSnapshot,
            repositoryDefaultTarget: repositoryDefaultTarget
        )
        guard nextComparison != reviewComparison else { return }
        self.reviewComparison = nextComparison
        presentationRevision += 1
    }

    func beginReviewComparisonAttempt(
        activeTarget: WorkspaceReviewContributionTarget,
        reviewGeneration: Int
    ) {
        let nextComparison = BridgePaneReviewComparisonPresentation(
            activeTarget: activeTarget,
            attempt: .pending(reviewGeneration: reviewGeneration),
            displayedSnapshot: reviewComparison?.displayedSnapshot.stalePredecessor ?? .absent,
            repositoryDefaultTarget: reviewComparison?.repositoryDefaultTarget
        )
        guard nextComparison != reviewComparison else { return }
        reviewComparison = nextComparison
        presentationRevision += 1
    }

    func beginAndFailReviewComparisonAttempt(
        activeTarget: WorkspaceReviewContributionTarget,
        reviewGeneration: Int,
        failureKind: String,
        retryable: Bool
    ) {
        beginReviewComparisonAttempt(
            activeTarget: activeTarget,
            reviewGeneration: reviewGeneration
        )
        failReviewComparisonAttempt(
            reviewGeneration: reviewGeneration,
            failureKind: failureKind,
            retryable: retryable
        )
    }

    func isReviewComparisonAttemptPending(reviewGeneration: Int) -> Bool {
        reviewComparison?.attempt == .pending(reviewGeneration: reviewGeneration)
    }

    func settleReviewComparisonAttempt(
        reviewGeneration: Int,
        displayedSnapshotIdentity: BridgePaneReviewDisplayedSnapshotIdentity
    ) {
        guard let reviewComparison,
            case .pending(let pendingGeneration) = reviewComparison.attempt,
            pendingGeneration <= reviewGeneration
        else { return }
        self.reviewComparison = BridgePaneReviewComparisonPresentation(
            activeTarget: reviewComparison.activeTarget,
            attempt: .settled(reviewGeneration: reviewGeneration),
            displayedSnapshot: .current(displayedSnapshotIdentity),
            repositoryDefaultTarget: reviewComparison.repositoryDefaultTarget
        )
        presentationRevision += 1
    }

    func recordCommittedReviewComparisonSnapshot(
        reviewGeneration: Int,
        displayedSnapshotIdentity: BridgePaneReviewDisplayedSnapshotIdentity
    ) {
        guard let reviewComparison else { return }
        if case .pending(let pendingGeneration) = reviewComparison.attempt {
            guard pendingGeneration <= reviewGeneration else { return }
            settleReviewComparisonAttempt(
                reviewGeneration: reviewGeneration,
                displayedSnapshotIdentity: displayedSnapshotIdentity
            )
            return
        }
        let nextAttempt: BridgePaneReviewComparisonAttempt
        switch reviewComparison.attempt {
        case .pending, .unavailable:
            nextAttempt = .settled(reviewGeneration: reviewGeneration)
        case .selectionRequired, .settled:
            nextAttempt = reviewComparison.attempt
        }
        let nextComparison = BridgePaneReviewComparisonPresentation(
            activeTarget: reviewComparison.activeTarget,
            attempt: nextAttempt,
            displayedSnapshot: .current(displayedSnapshotIdentity),
            repositoryDefaultTarget: reviewComparison.repositoryDefaultTarget
        )
        guard nextComparison != reviewComparison else { return }
        self.reviewComparison = nextComparison
        presentationRevision += 1
    }

    func failReviewComparisonAttempt(
        reviewGeneration: Int,
        failureKind: String,
        retryable: Bool
    ) {
        guard let reviewComparison,
            case .pending(let pendingGeneration) = reviewComparison.attempt,
            pendingGeneration <= reviewGeneration
        else { return }
        self.reviewComparison = BridgePaneReviewComparisonPresentation(
            activeTarget: reviewComparison.activeTarget,
            attempt: .unavailable(
                failureKind: failureKind,
                retryable: retryable
            ),
            displayedSnapshot: reviewComparison.displayedSnapshot.stalePredecessor,
            repositoryDefaultTarget: reviewComparison.repositoryDefaultTarget
        )
        presentationRevision += 1
    }

    @discardableResult
    func recordInvalidation(
        fileChangeset: FileChangeset?,
        latestFileStatus: GitWorkingTreeStatus? = nil,
        requiresReviewRefresh: Bool
    ) -> Set<BridgePaneRefreshLane> {
        guard activity != .closed else { return [] }
        let previousPresentation = productPresentationSnapshot
        var supersededLanes: Set<BridgePaneRefreshLane> = []
        nextDirtyGeneration &+= 1
        nextAuthorityGeneration &+= 1
        let invalidationGeneration = nextDirtyGeneration
        if fileChangeset != nil || latestFileStatus != nil {
            fileRefreshFailure = nil
            authorityGenerationByLane[.file] = nextAuthorityGeneration
            workAdmissionGate.updateAuthority(
                for: .file,
                generation: nextAuthorityGeneration
            )
            if supersedeActiveReservation(for: .file) {
                supersededLanes.insert(.file)
            }
            dirtyFactByLane[.file] = mergingInvalidation(
                into: dirtyFactByLane[.file],
                generation: invalidationGeneration,
                fileChangeset: fileChangeset,
                latestFileStatus: latestFileStatus,
                requiresReviewRefresh: false
            )
        }
        if requiresReviewRefresh {
            authorityGenerationByLane[.review] = nextAuthorityGeneration
            workAdmissionGate.updateAuthority(
                for: .review,
                generation: nextAuthorityGeneration
            )
            if supersedeActiveReservation(for: .review) {
                supersededLanes.insert(.review)
            }
            dirtyFactByLane[.review] = mergingInvalidation(
                into: dirtyFactByLane[.review],
                generation: invalidationGeneration,
                fileChangeset: fileChangeset,
                latestFileStatus: latestFileStatus,
                requiresReviewRefresh: true
            )
        }
        advancePresentationRevisionIfNeeded(from: previousPresentation)
        return supersededLanes
    }

    func applyActivity(_ nextActivity: BridgePaneActivity) {
        let previousPresentation = productPresentationSnapshot
        guard activity != .closed, nextActivity != .closed else {
            if nextActivity == .closed { close() }
            return
        }
        let previousActivity = activity
        guard previousActivity != nextActivity else { return }
        activity = nextActivity
        workAdmissionGate.updateActivity(nextActivity)
        if nextActivity != .foreground {
            restoreActiveReservationToDirtyFact()
        }
        advancePresentationRevisionIfNeeded(from: previousPresentation)
    }

    func acquireForegroundWork() -> BridgePaneRefreshWorkAdmission? {
        workAdmissionGate.acquire(validity: .foregroundOnly)
    }

    func acquireReviewContentContinuation() -> BridgePaneRefreshWorkAdmission? {
        workAdmissionGate.acquire(validity: .foregroundOrLoadedHidden)
    }

    func isRefreshLaneActive(_ lane: BridgePaneRefreshLane) -> Bool {
        activeRefreshPassByLane[lane] != nil
    }

    func currentAuthorityGeneration(for lane: BridgePaneRefreshLane) -> UInt64 {
        authorityGenerationByLane[lane, default: 0]
    }

    func isRefreshPassCurrent(_ reservation: BridgePaneRefreshCatchUpReservation) -> Bool {
        guard reservation.lanes.count == 1,
            let lane = reservation.lanes.first
        else { return false }
        return activeRefreshPassByLane[lane]?.id == reservation.id
            && authorityGenerationByLane[lane, default: 0] == reservation.authorityGeneration
    }

    @discardableResult
    func advanceAuthority(for lane: BridgePaneRefreshLane) -> UInt64 {
        let previousPresentation = productPresentationSnapshot
        nextAuthorityGeneration &+= 1
        authorityGenerationByLane[lane] = nextAuthorityGeneration
        workAdmissionGate.updateAuthority(for: lane, generation: nextAuthorityGeneration)
        _ = supersedeActiveReservation(for: lane)
        advancePresentationRevisionIfNeeded(from: previousPresentation)
        return nextAuthorityGeneration
    }

    func completeRefreshPass(
        _ reservation: BridgePaneRefreshCatchUpReservation,
        outcome: BridgePaneRefreshCatchUpOutcome
    ) {
        // Leaving foreground already restores and clears the active reservation.
        // Its later cancelled/stale completion must not merge the same fact twice.
        guard reservation.lanes.count == 1,
            let lane = reservation.lanes.first,
            activeRefreshPassByLane[lane]?.id == reservation.id
        else { return }
        let previousPresentation = productPresentationSnapshot
        activeRefreshPassByLane[lane] = nil
        guard activity != .closed else { return }
        switch outcome {
        case .succeeded:
            if lane == .file { fileRefreshFailure = nil }
        case .failed, .stale:
            restoreDirtyFact(reservation.dirtyFact, lane: lane, operationCorrelationID: nil)
        case .streamReset:
            restoreDirtyFact(
                reservation.dirtyFact,
                lane: lane,
                operationCorrelationID: reservation.operationCorrelationID
            )
        }
        advancePresentationRevisionIfNeeded(from: previousPresentation)
    }

    func reserveForegroundRefreshPass() -> BridgePaneRefreshCatchUpReservation? {
        guard activity == .foreground else { return nil }
        if let fileReservation = reserveCatchUpIfPossible(for: .file) {
            return fileReservation
        }
        return reserveCatchUpIfPossible(for: .review)
    }

    func reserveForegroundRefreshPass(
        for lane: BridgePaneRefreshLane
    ) -> BridgePaneRefreshCatchUpReservation? {
        guard activity == .foreground else { return nil }
        return reserveCatchUpIfPossible(for: lane)
    }

    func close() {
        guard activity != .closed else { return }
        let previousPresentation = productPresentationSnapshot
        activity = .closed
        workAdmissionGate.close()
        dirtyFactByLane.removeAll()
        activeRefreshPassByLane.removeAll()
        advancePresentationRevisionIfNeeded(from: previousPresentation)
    }

    func recordCurrentFileRefreshFailure(_ failure: BridgePaneProductFileRefreshFailure?) {
        guard activity != .closed, fileRefreshFailure != failure else { return }
        fileRefreshFailure = failure
        presentationRevision += 1
    }

    var hasPendingFileRefreshWork: Bool {
        dirtyFactByLane[.file] != nil
    }

    @discardableResult
    func beginExplicitFileRefreshRetry() -> Bool {
        guard activity == .foreground,
            dirtyFactByLane[.file] != nil,
            fileRefreshFailure != nil,
            activeRefreshPassByLane[.file] == nil
        else { return false }
        let previousPresentation = productPresentationSnapshot
        nextAuthorityGeneration &+= 1
        authorityGenerationByLane[.file] = nextAuthorityGeneration
        workAdmissionGate.updateAuthority(for: .file, generation: nextAuthorityGeneration)
        fileRefreshFailure = nil
        advancePresentationRevisionIfNeeded(from: previousPresentation)
        return true
    }

    private func mergingInvalidation(
        into current: BridgePaneRefreshDirtyFact?,
        generation: UInt64,
        fileChangeset: FileChangeset?,
        latestFileStatus: GitWorkingTreeStatus?,
        requiresReviewRefresh: Bool
    ) -> BridgePaneRefreshDirtyFact {
        let incomingReviewRefreshScope =
            requiresReviewRefresh
            ? ReviewGitRefreshScope.classify(
                fileChangeset: fileChangeset,
                latestFileStatus: latestFileStatus
            )
            : nil
        guard let current else {
            return BridgePaneRefreshDirtyFact(
                generation: generation,
                fileChangeset: mergedFileChangeset(current: nil, incoming: fileChangeset),
                latestFileStatus: latestFileStatus,
                latestBatchSequence: fileChangeset?.batchSeq ?? 0,
                requiresReviewRefresh: requiresReviewRefresh,
                reviewRefreshScope: incomingReviewRefreshScope,
                operationCorrelationID: nil,
                operationStageAttempt: 0
            )
        }
        return BridgePaneRefreshDirtyFact(
            generation: current.generation,
            fileChangeset: mergedFileChangeset(current: current.fileChangeset, incoming: fileChangeset),
            latestFileStatus: latestFileStatus ?? current.latestFileStatus,
            latestBatchSequence: max(current.latestBatchSequence, fileChangeset?.batchSeq ?? 0),
            requiresReviewRefresh: current.requiresReviewRefresh || requiresReviewRefresh,
            reviewRefreshScope: mergedReviewRefreshScope(
                current: current,
                incomingChangeset: fileChangeset,
                incomingScope: incomingReviewRefreshScope
            ),
            operationCorrelationID: current.operationCorrelationID,
            operationStageAttempt: current.operationStageAttempt
        )
    }

    private func reserveCatchUpIfPossible(
        for lane: BridgePaneRefreshLane
    ) -> BridgePaneRefreshCatchUpReservation? {
        let authorityGeneration = authorityGenerationByLane[lane, default: 0]
        guard activeRefreshPassByLane[lane] == nil,
            let dirtyFact = dirtyFactByLane[lane],
            let activityAdmission = workAdmissionGate.acquire(
                validity: .foregroundOnly,
                authorityFence: .init(
                    lane: lane,
                    generation: authorityGeneration
                )
            )
        else { return nil }
        dirtyFactByLane[lane] = nil
        let reservation = BridgePaneRefreshCatchUpReservation(
            id: UUIDv7.generate(),
            authorityGeneration: authorityGeneration,
            dirtyGeneration: dirtyFact.generation,
            lanes: [lane],
            fileChangeset: dirtyFact.fileChangeset,
            latestFileStatus: dirtyFact.latestFileStatus,
            latestBatchSequence: dirtyFact.latestBatchSequence,
            requiresReviewRefresh: dirtyFact.requiresReviewRefresh,
            reviewRefreshScope: dirtyFact.reviewRefreshScope,
            operationCorrelationID:
                dirtyFact.operationCorrelationID ?? BridgeOperationCorrelation.mintScrubbedID(),
            operationStageAttempt: dirtyFact.operationStageAttempt,
            foregroundWorkAdmission: activityAdmission,
            dirtyFact: dirtyFact
        )
        activeRefreshPassByLane[lane] = reservation
        refreshPassCount += 1
        presentationRevision += 1
        return reservation
    }

    private func restoreActiveReservationToDirtyFact() {
        let activeReservations = activeRefreshPassByLane
        activeRefreshPassByLane.removeAll()
        for (lane, reservation) in activeReservations {
            restoreDirtyFact(reservation.dirtyFact, lane: lane, operationCorrelationID: nil)
        }
    }

    private func supersedeActiveReservation(for lane: BridgePaneRefreshLane) -> Bool {
        guard let reservation = activeRefreshPassByLane.removeValue(forKey: lane) else {
            return false
        }
        restoreDirtyFact(reservation.dirtyFact, lane: lane, operationCorrelationID: nil)
        return true
    }

    private func restoreDirtyFact(
        _ restored: BridgePaneRefreshDirtyFact,
        lane: BridgePaneRefreshLane,
        operationCorrelationID: String?
    ) {
        guard activity != .closed else { return }
        guard let current = dirtyFactByLane[lane] else {
            dirtyFactByLane[lane] = BridgePaneRefreshDirtyFact(
                generation: restored.generation,
                fileChangeset: restored.fileChangeset,
                latestFileStatus: restored.latestFileStatus,
                latestBatchSequence: restored.latestBatchSequence,
                requiresReviewRefresh: restored.requiresReviewRefresh,
                reviewRefreshScope: restored.reviewRefreshScope,
                operationCorrelationID: operationCorrelationID,
                operationStageAttempt:
                    operationCorrelationID == nil ? 0 : restored.operationStageAttempt + 1
            )
            return
        }
        dirtyFactByLane[lane] = BridgePaneRefreshDirtyFact(
            generation: min(current.generation, restored.generation),
            fileChangeset: mergedFileChangeset(
                current: current.fileChangeset,
                incoming: restored.fileChangeset
            ),
            latestFileStatus: current.latestFileStatus ?? restored.latestFileStatus,
            latestBatchSequence: max(current.latestBatchSequence, restored.latestBatchSequence),
            requiresReviewRefresh: current.requiresReviewRefresh || restored.requiresReviewRefresh,
            reviewRefreshScope: mergedReviewRefreshScope(current: current, restored: restored),
            operationCorrelationID: current.operationCorrelationID ?? operationCorrelationID,
            operationStageAttempt: max(
                current.operationStageAttempt,
                operationCorrelationID == nil ? 0 : restored.operationStageAttempt + 1
            )
        )
    }

    private func advancePresentationRevisionIfNeeded(
        from previousPresentation: BridgePaneProductPresentationSnapshot
    ) {
        guard
            previousPresentation.nativeActivity != activity
                || previousPresentation.refreshingLanes != Set(activeRefreshPassByLane.keys)
                || previousPresentation.fileRefreshFailure != fileRefreshFailure
        else { return }
        presentationRevision += 1
    }

    private var combinedDirtyFact: BridgePaneRefreshDirtyFact? {
        switch (dirtyFactByLane[.file], dirtyFactByLane[.review]) {
        case (nil, nil):
            nil
        case (.some(let file), nil):
            file
        case (nil, .some(let review)):
            review
        case (.some(let file), .some(let review)):
            BridgePaneRefreshDirtyFact(
                generation: min(file.generation, review.generation),
                fileChangeset: file.fileChangeset,
                latestFileStatus: file.latestFileStatus,
                latestBatchSequence: file.latestBatchSequence,
                requiresReviewRefresh: true,
                reviewRefreshScope: review.reviewRefreshScope,
                operationCorrelationID: nil,
                operationStageAttempt: 0
            )
        }
    }

    private func mergedFileChangeset(
        current: FileChangeset?,
        incoming: FileChangeset?
    ) -> FileChangeset? {
        guard let incoming else { return current }
        guard let current else {
            return FileChangeset(
                worktreeId: incoming.worktreeId,
                repoId: incoming.repoId,
                rootPath: incoming.rootPath,
                paths: Array(Set(incoming.paths)).sorted(),
                containsGitInternalChanges: incoming.containsGitInternalChanges,
                suppressedIgnoredPathCount: incoming.suppressedIgnoredPathCount,
                suppressedGitInternalPathCount: incoming.suppressedGitInternalPathCount,
                timestamp: incoming.timestamp,
                batchSeq: incoming.batchSeq
            )
        }
        return FileChangeset(
            worktreeId: incoming.worktreeId,
            repoId: incoming.repoId,
            rootPath: incoming.rootPath,
            paths: Array(Set(current.paths).union(incoming.paths)).sorted(),
            containsGitInternalChanges: current.containsGitInternalChanges
                || incoming.containsGitInternalChanges,
            suppressedIgnoredPathCount: current.suppressedIgnoredPathCount
                + incoming.suppressedIgnoredPathCount,
            suppressedGitInternalPathCount: current.suppressedGitInternalPathCount
                + incoming.suppressedGitInternalPathCount,
            timestamp: incoming.batchSeq >= current.batchSeq ? incoming.timestamp : current.timestamp,
            batchSeq: max(current.batchSeq, incoming.batchSeq)
        )
    }

    private func mergedReviewRefreshScope(
        current: BridgePaneRefreshDirtyFact,
        incomingChangeset: FileChangeset?,
        incomingScope: ReviewGitRefreshScope?
    ) -> ReviewGitRefreshScope? {
        guard let incomingScope else { return current.reviewRefreshScope }
        guard let currentScope = current.reviewRefreshScope else { return incomingScope }
        return currentScope.union(
            incomingScope,
            hasCommonAuthority: sameChangesetAuthority(
                current.fileChangeset,
                incomingChangeset
            )
        )
    }

    private func mergedReviewRefreshScope(
        current: BridgePaneRefreshDirtyFact,
        restored: BridgePaneRefreshDirtyFact
    ) -> ReviewGitRefreshScope? {
        guard let restoredScope = restored.reviewRefreshScope else { return current.reviewRefreshScope }
        guard let currentScope = current.reviewRefreshScope else { return restoredScope }
        return currentScope.union(
            restoredScope,
            hasCommonAuthority: sameChangesetAuthority(
                current.fileChangeset,
                restored.fileChangeset
            )
        )
    }

    private func sameChangesetAuthority(
        _ current: FileChangeset?,
        _ incoming: FileChangeset?
    ) -> Bool {
        guard let current, let incoming else { return current == nil && incoming == nil }
        return current.worktreeId == incoming.worktreeId
            && current.repoId == incoming.repoId
            && current.rootPath.standardizedFileURL == incoming.rootPath.standardizedFileURL
    }
}

private final class BridgePaneRefreshWorkAdmissionGate: @unchecked Sendable {
    private struct ReviewComparisonIntent {
        let productAdmission: BridgeProductAdmissionContext
        var workerDerivationEpoch: Int
    }

    fileprivate enum Validity: Sendable {
        case foregroundOnly
        case foregroundOrLoadedHidden
    }

    fileprivate final class Identity: Sendable {}

    fileprivate struct Token: Sendable {
        let identity: Identity
        let epoch: UInt64
        let validity: Validity
        let authorityFence: AuthorityFence?
    }

    fileprivate struct AuthorityFence: Sendable {
        let lane: BridgePaneRefreshLane
        let generation: UInt64
    }

    private struct InvalidationHandler {
        let handler: @Sendable () -> Void
        let token: Token
    }

    struct DiagnosticSnapshot: Sendable {
        let epoch: UInt64
    }

    private let lock = NSLock()
    private let reviewComparisonIntentLock = NSLock()
    private let identity = Identity()
    private var activity: BridgePaneActivity
    private var foregroundEpoch: UInt64 = 0
    private var reviewContinuationEpoch: UInt64 = 0
    private var authorityGenerationByLane: [BridgePaneRefreshLane: UInt64] = [:]
    private var invalidationHandlerById: [UUID: InvalidationHandler] = [:]
    private var reviewComparisonIntent: ReviewComparisonIntent?

    init(initialActivity: BridgePaneActivity) {
        activity = initialActivity
    }

    var diagnosticSnapshot: DiagnosticSnapshot {
        lock.withLock { DiagnosticSnapshot(epoch: foregroundEpoch) }
    }

    func admitReviewComparisonIntent(
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext
    ) {
        reviewComparisonIntentLock.withLock {
            guard var currentIntent = reviewComparisonIntent,
                currentIntent.productAdmission.matches(productAdmission)
            else {
                reviewComparisonIntent = ReviewComparisonIntent(
                    productAdmission: productAdmission,
                    workerDerivationEpoch: workerDerivationEpoch
                )
                return
            }
            guard workerDerivationEpoch >= currentIntent.workerDerivationEpoch else { return }
            currentIntent.workerDerivationEpoch = workerDerivationEpoch
            reviewComparisonIntent = currentIntent
        }
    }

    func withCurrentReviewComparisonIntent<MutationResult>(
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext,
        perform mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try reviewComparisonIntentLock.withLock {
            guard let currentIntent = reviewComparisonIntent,
                currentIntent.productAdmission.matches(productAdmission),
                workerDerivationEpoch >= currentIntent.workerDerivationEpoch
            else { return nil }
            return try mutation()
        }
    }

    func acquire(
        validity: Validity,
        authorityFence: AuthorityFence? = nil
    ) -> BridgePaneRefreshWorkAdmission? {
        lock.withLock {
            guard activity == .foreground else { return nil }
            if let authorityFence {
                guard
                    authorityGenerationByLane[authorityFence.lane, default: 0]
                        == authorityFence.generation
                else {
                    return nil
                }
            }
            return BridgePaneRefreshWorkAdmission(
                gate: self,
                token: Token(
                    identity: identity,
                    epoch: validity == .foregroundOnly
                        ? foregroundEpoch
                        : reviewContinuationEpoch,
                    validity: validity,
                    authorityFence: authorityFence
                )
            )
        }
    }

    func updateAuthority(
        for lane: BridgePaneRefreshLane,
        generation: UInt64
    ) {
        let invalidationHandlers: [@Sendable () -> Void] = lock.withLock {
            authorityGenerationByLane[lane] = generation
            return takeInvalidationHandlersInvalidatedByCurrentState()
        }
        for invalidationHandler in invalidationHandlers {
            invalidationHandler()
        }
    }

    func updateActivity(_ nextActivity: BridgePaneActivity) {
        let invalidationHandlers: [@Sendable () -> Void] = lock.withLock {
            guard activity != .closed, activity != nextActivity else { return [] }
            activity = nextActivity
            foregroundEpoch &+= 1
            if nextActivity == .dormant {
                reviewContinuationEpoch &+= 1
            }
            return takeInvalidationHandlersInvalidatedByCurrentState()
        }
        for invalidationHandler in invalidationHandlers {
            invalidationHandler()
        }
    }

    func close() {
        let invalidationHandlers: [@Sendable () -> Void] = lock.withLock {
            guard activity != .closed else { return [] }
            activity = .closed
            foregroundEpoch &+= 1
            reviewContinuationEpoch &+= 1
            return takeInvalidationHandlersInvalidatedByCurrentState()
        }
        for invalidationHandler in invalidationHandlers {
            invalidationHandler()
        }
    }

    func withValidAdmission<MutationResult>(
        _ token: Token,
        perform mutation: () throws -> MutationResult
    ) rethrows -> MutationResult? {
        try lock.withLock {
            guard isValid(token) else { return nil }
            return try mutation()
        }
    }

    func registerInvalidationHandler(
        _ token: Token,
        handler: @escaping @Sendable () -> Void
    ) -> UUID? {
        lock.withLock {
            guard isValid(token) else { return nil }
            let handlerId = UUIDv7.generate()
            invalidationHandlerById[handlerId] = InvalidationHandler(
                handler: handler,
                token: token
            )
            return handlerId
        }
    }

    func removeInvalidationHandler(_ handlerId: UUID) {
        _ = lock.withLock {
            invalidationHandlerById.removeValue(forKey: handlerId)
        }
    }

    private func isValid(_ token: Token) -> Bool {
        guard token.identity === identity else { return false }
        if let authorityFence = token.authorityFence,
            authorityGenerationByLane[authorityFence.lane, default: 0]
                != authorityFence.generation
        {
            return false
        }
        switch token.validity {
        case .foregroundOnly:
            return activity == .foreground && token.epoch == foregroundEpoch
        case .foregroundOrLoadedHidden:
            return (activity == .foreground || activity == .loadedHidden)
                && token.epoch == reviewContinuationEpoch
        }
    }

    private func takeInvalidationHandlersInvalidatedByCurrentState() -> [@Sendable () -> Void] {
        let invalidatedHandlerIds = invalidationHandlerById.compactMap { handlerId, registration in
            isValid(registration.token) ? nil : handlerId
        }
        return invalidatedHandlerIds.compactMap { handlerId in
            invalidationHandlerById.removeValue(forKey: handlerId)?.handler
        }
    }
}
