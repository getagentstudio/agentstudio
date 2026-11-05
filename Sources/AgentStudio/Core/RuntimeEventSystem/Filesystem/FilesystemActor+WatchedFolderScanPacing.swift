import AgentStudioInfrastructure
import Foundation

enum WatchedFolderScanTriggerReason: Hashable, Sendable {
    case relevantChange, nativeCoverageLoss, intakeCoverageLoss
}

typealias WatchedFolderScanTriggerReasons = Set<WatchedFolderScanTriggerReason>

struct OpenInterval: Equatable, Sendable {
    let firstTriggerAt: Duration
    var lastTriggerAt: Duration
    var triggerRevision: UInt64
    var foldedTriggerCount: Int
    var quietGapCount: Int
    let intervalOrdinal: UInt64
    var reasons: WatchedFolderScanTriggerReasons

    var deadline: Duration {
        min(
            lastTriggerAt + AppPolicies.WatchedFolderScanning.changeDebounce,
            firstTriggerAt + AppPolicies.WatchedFolderScanning.changeMaximumWait)
    }

    mutating func fold(reason: WatchedFolderScanTriggerReason, revision: UInt64, at now: Duration) {
        if now - lastTriggerAt >= AppPolicies.WatchedFolderScanning.changeDebounce { quietGapCount += 1 }
        lastTriggerAt = now
        triggerRevision = revision
        foldedTriggerCount += 1
        reasons.insert(reason)
    }
}

struct InFlightSubmission: Equatable, Sendable {
    let submissionSequence: UInt64
    let coveredRevision: UInt64
    let cause: WatchedFolderScanCause
    let reservedAt: Duration
}

enum PacedScanObligation: Equatable, Sendable {
    case open(OpenInterval)
    case submitted(InFlightSubmission, pendingInterval: OpenInterval?)

    var pendingInterval: OpenInterval? {
        switch self {
        case .open(let interval): interval
        case .submitted(_, let pendingInterval): pendingInterval
        }
    }
}

struct WatchedFolderPacingObligation: Equatable, Sendable {
    var state: PacedScanObligation
    let obligationOrdinal: UInt64
    let openedAt: Duration
    var lastTriggerAt: Duration
    var quietGapCount = 0
    var completedChangeDrivenRunCount = 0
    /// Highest interval ordinal allocated within this obligation; this is an identity counter.
    var lastIssuedOrdinal: UInt64 = 1

    var pendingInterval: OpenInterval? { state.pendingInterval }
}

enum WatchedFolderPacingDecision: Equatable, Sendable {
    case submit([(FilesystemSourceID, coveredRevision: UInt64)])
    case wait(until: Duration)
    case idle

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.wait(let first), .wait(let second)): first == second
        case (.submit(let first), .submit(let second)):
            first.count == second.count && zip(first, second).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }
}

enum WatchedFolderPacingClosure: Equatable, Sendable { case closed, stillOpen, notCovered }

enum WatchedFolderSubmissionContext: Equatable, Sendable {
    case explicit
    case obligation(ordinal: UInt64, openedAt: Duration, interval: OpenInterval)
}

struct WatchedFolderPacingSubmission: Equatable, Sendable {
    let inFlight: InFlightSubmission
    let context: WatchedFolderSubmissionContext
}

/// Pure timing and coverage state; the actor owns effects and supplies monotonic time.
struct WatchedFolderScanPacing: Sendable {
    private(set) var obligationsBySourceID: [FilesystemSourceID: WatchedFolderPacingObligation] = [:]
    private(set) var triggerRevisionBySourceID: [FilesystemSourceID: UInt64] = [:]
    private(set) var submissionsBySourceID: [FilesystemSourceID: [UInt64: WatchedFolderPacingSubmission]] = [:]
    private var nextObligationOrdinalBySourceID: [FilesystemSourceID: UInt64] = [:]
    private var acceptedCoverageBySourceID: [FilesystemSourceID: AcceptedCoverage] = [:]

    private struct AcceptedCoverage: Sendable {
        let coveredRevision: UInt64
        let coverage: WatchedFolderScanDemandCoverage
    }

    @discardableResult
    mutating func recordTrigger(_ id: FilesystemSourceID, reason: WatchedFolderScanTriggerReason, at now: Duration)
        -> UInt64
    {
        let revision = (triggerRevisionBySourceID[id] ?? 0) + 1
        triggerRevisionBySourceID[id] = revision
        if var obligation = obligationsBySourceID[id] {
            if now - obligation.lastTriggerAt >= AppPolicies.WatchedFolderScanning.changeDebounce {
                obligation.quietGapCount += 1
            }
            obligation.lastTriggerAt = now
            if var interval = obligation.pendingInterval {
                interval.fold(reason: reason, revision: revision, at: now)
                switch obligation.state {
                case .open: obligation.state = .open(interval)
                case .submitted(let submission, _): obligation.state = .submitted(submission, pendingInterval: interval)
                }
            } else if case .submitted(let submission, nil) = obligation.state {
                obligation.lastIssuedOrdinal += 1
                let interval = makeInterval(
                    reason: reason, revision: revision, ordinal: obligation.lastIssuedOrdinal, at: now)
                obligation.state = .submitted(submission, pendingInterval: interval)
            }
            obligationsBySourceID[id] = obligation
        } else {
            let ordinal = (nextObligationOrdinalBySourceID[id] ?? 0) + 1
            nextObligationOrdinalBySourceID[id] = ordinal
            obligationsBySourceID[id] = .init(
                state: .open(makeInterval(reason: reason, revision: revision, ordinal: 1, at: now)),
                obligationOrdinal: ordinal, openedAt: now, lastTriggerAt: now)
        }
        return revision
    }

    func decision(at now: Duration) -> WatchedFolderPacingDecision {
        let pending = obligationsBySourceID.compactMap { id, obligation in
            obligation.pendingInterval.map { (id, $0) }
        }
        let eligible = pending.filter { $0.1.deadline <= now }
            .sorted { $0.0.rootID.uuidString < $1.0.rootID.uuidString }
            .map { ($0.0, coveredRevision: $0.1.triggerRevision) }
        if !eligible.isEmpty { return .submit(eligible) }
        if let deadline = pending.map({ $0.1.deadline }).min() { return .wait(until: deadline) }
        return .idle
    }

    mutating func reserveSubmission(
        _ id: FilesystemSourceID, sequence: UInt64, cause: WatchedFolderScanCause, at now: Duration
    ) {
        let submission = InFlightSubmission(
            submissionSequence: sequence, coveredRevision: triggerRevisionBySourceID[id] ?? 0, cause: cause,
            reservedAt: now)
        var context = WatchedFolderSubmissionContext.explicit
        if var obligation = obligationsBySourceID[id] {
            let interval: OpenInterval?
            if let pending = obligation.pendingInterval {
                interval = pending
            } else if case .submitted(let previous, _) = obligation.state,
                case .obligation(_, _, let previousInterval) = submissionsBySourceID[id]?[previous.submissionSequence]?
                    .context
            {
                interval = previousInterval
            } else {
                interval = nil
            }
            if let interval {
                context = .obligation(
                    ordinal: obligation.obligationOrdinal, openedAt: obligation.openedAt, interval: interval)
            }
            obligation.state = .submitted(submission, pendingInterval: nil)
            obligationsBySourceID[id] = obligation
        }
        submissionsBySourceID[id, default: [:]][sequence] = .init(inFlight: submission, context: context)
    }

    mutating func recordAccepted(
        _ id: FilesystemSourceID, coveredRevision: UInt64, coverage: WatchedFolderScanDemandCoverage, at _: Duration
    ) {
        if let previous = acceptedCoverageBySourceID[id], previous.coverage.covers(coverage) { return }
        acceptedCoverageBySourceID[id] = .init(coveredRevision: coveredRevision, coverage: coverage)
    }

    mutating func recordRunCompleted(_ id: FilesystemSourceID, coverage: WatchedFolderScanDemandCoverage)
        -> WatchedFolderPacingClosure
    {
        guard let obligation = obligationsBySourceID[id], let accepted = acceptedCoverageBySourceID[id],
            coverage.covers(accepted.coverage), accepted.coveredRevision == triggerRevisionBySourceID[id]
        else { return .notCovered }
        guard obligation.pendingInterval == nil else { return .stillOpen }
        obligationsBySourceID.removeValue(forKey: id)
        return .closed
    }

    /// Results cover every reservation through the newest merged request's sequence.
    @discardableResult
    mutating func settleSubmissions(_ id: FilesystemSourceID, through sequence: UInt64) -> InFlightSubmission? {
        let covered = submissionsBySourceID[id, default: [:]].values.filter {
            $0.inFlight.submissionSequence <= sequence
        }
        let newest = covered.max { $0.inFlight.submissionSequence < $1.inFlight.submissionSequence }?.inFlight
        submissionsBySourceID[id] = submissionsBySourceID[id, default: [:]].filter { $0.key > sequence }
        if var obligation = obligationsBySourceID[id] {
            if covered.contains(where: { $0.inFlight.cause == .callback }) {
                obligation.completedChangeDrivenRunCount += 1
            }
            if case .submitted(let submission, let pending?) = obligation.state,
                submission.submissionSequence <= sequence
            {
                obligation.state = .open(pending)
            }
            obligationsBySourceID[id] = obligation
        }
        return newest
    }

    mutating func rejectSubmission(_ id: FilesystemSourceID, sequence: UInt64) {
        guard let rejected = submissionsBySourceID[id]?.removeValue(forKey: sequence),
            var obligation = obligationsBySourceID[id],
            case .submitted(let submission, let pending) = obligation.state, submission.submissionSequence == sequence,
            case .obligation(_, _, var interval) = rejected.context
        else { return }
        if let pending {
            if pending.firstTriggerAt - interval.lastTriggerAt >= AppPolicies.WatchedFolderScanning.changeDebounce {
                interval.quietGapCount += 1
            }
            interval.lastTriggerAt = pending.lastTriggerAt
            interval.triggerRevision = pending.triggerRevision
            interval.foldedTriggerCount += pending.foldedTriggerCount
            interval.quietGapCount += pending.quietGapCount
            interval.reasons.formUnion(pending.reasons)
        }
        obligation.state = .open(interval)
        obligationsBySourceID[id] = obligation
    }

    mutating func removeFolder(_ id: FilesystemSourceID) {
        obligationsBySourceID.removeValue(forKey: id)
        triggerRevisionBySourceID.removeValue(forKey: id)
        submissionsBySourceID.removeValue(forKey: id)
        acceptedCoverageBySourceID.removeValue(forKey: id)
        nextObligationOrdinalBySourceID.removeValue(forKey: id)
    }

    private func makeInterval(
        reason: WatchedFolderScanTriggerReason, revision: UInt64, ordinal: UInt64, at now: Duration
    ) -> OpenInterval {
        .init(
            firstTriggerAt: now, lastTriggerAt: now, triggerRevision: revision, foldedTriggerCount: 1, quietGapCount: 0,
            intervalOrdinal: ordinal, reasons: [reason])
    }
}

extension FilesystemActor {
    func recordWatchedFolderScanTrigger(_ sourceID: FilesystemSourceID, reason: WatchedFolderScanTriggerReason) {
        guard !watchedFolderScanState.isShuttingDown,
            watchedFolderScanState.registrationsBySourceID[sourceID] != nil
        else { return }
        watchedFolderScanState.latestDemandCoverageBySourceID.removeValue(forKey: sourceID)
        watchedFolderScanState.pacing.recordTrigger(sourceID, reason: reason, at: schedulingClock.now())
        scheduleWatchedFolderScanPacing()
    }

    func scheduleWatchedFolderScanPacing() {
        guard !watchedFolderScanState.isShuttingDown, watchedFolderScanState.pacingDeadlineTask == nil else { return }
        if case .idle = watchedFolderScanState.pacing.decision(at: schedulingClock.now()) { return }
        watchedFolderScanState.pacingDeadlineTask = Task { [weak self] in
            await self?.drainWatchedFolderScanPacing()
        }
    }

    private func drainWatchedFolderScanPacing() async {
        defer { watchedFolderScanState.pacingDeadlineTask = nil }
        while !Task.isCancelled && !watchedFolderScanState.isShuttingDown {
            let now = schedulingClock.now()
            switch watchedFolderScanState.pacing.decision(at: now) {
            case .idle: return
            case .wait(let deadline):
                do { try await schedulingClock.sleep(deadline - now) } catch is CancellationError { return } catch {
                    Self.logger.warning(
                        "Unexpected watched-folder pacing sleep failure: \(String(describing: error), privacy: .public)"
                    )
                }
            case .submit(let eligible):
                for (sourceID, revision) in eligible {
                    guard !Task.isCancelled, !watchedFolderScanState.isShuttingDown else { return }
                    guard let registration = watchedFolderScanState.registrationsBySourceID[sourceID],
                        watchedFolderScanState.pacing.obligationsBySourceID[sourceID]?.pendingInterval?.triggerRevision
                            == revision
                    else { continue }
                    let request = watchedFolderScanRequest(for: registration, cause: .callback)
                    if case .rejected = await submitWatchedFolderScanRequest(request, intent: .untracked) {
                        return  // Keep the interval open for the next decision; terminal rejections cannot spin.
                    }
                }
                await recordLogicalDebtSnapshotIfChanged()
            }
        }
    }

    /// Reserve records make this independent of acceptance/result arrival order.
    func prepareWatchedFolderScanResultCurrency(_ result: ScheduledWatchedFolderScanResult) -> Bool {
        let sourceID = result.request.sourceID
        guard let covered = currentWatchedFolderScanSubmission(for: result) else { return false }
        watchedFolderScanState.pacing.recordAccepted(
            sourceID, coveredRevision: covered.coveredRevision, coverage: result.demandCoverage,
            at: schedulingClock.now())
        watchedFolderScanState.latestDemandCoverageBySourceID[sourceID] = result.demandCoverage
        return true
    }

    func currentWatchedFolderScanSubmission(for result: ScheduledWatchedFolderScanResult) -> InFlightSubmission? {
        let sourceID = result.request.sourceID
        let reservations = watchedFolderScanState.pacing.submissionsBySourceID[sourceID] ?? [:]
        guard
            let covered = reservations.values.filter({
                $0.inFlight.submissionSequence <= result.request.submissionSequence
            })
            .max(by: { $0.inFlight.submissionSequence < $1.inFlight.submissionSequence })?.inFlight,
            covered.coveredRevision == watchedFolderScanState.pacing.triggerRevisionBySourceID[sourceID, default: 0],
            !reservations.keys.contains(where: { $0 > result.request.submissionSequence })
        else { return nil }
        if let marker = watchedFolderScanState.latestDemandCoverageBySourceID[sourceID],
            marker.registration == result.demandCoverage.registration,
            marker.throughDemandGeneration > result.demandCoverage.throughDemandGeneration
        {
            return nil
        }
        return covered
    }

    func finishWatchedFolderScanPacingResult(_ result: ScheduledWatchedFolderScanResult, wasCurrent: Bool) {
        let sourceID = result.request.sourceID
        watchedFolderScanState.pacing.settleSubmissions(sourceID, through: result.request.submissionSequence)
        if wasCurrent, watchedFolderScanState.pacing.submissionsBySourceID[sourceID, default: [:]].isEmpty {
            _ = watchedFolderScanState.pacing.recordRunCompleted(sourceID, coverage: result.demandCoverage)
        }
        scheduleWatchedFolderScanPacing()
    }
}
