import AgentStudioInfrastructure

extension WatchedFolderScanScheduler {
    struct SubmittedLeaseDiagnostics: Equatable, Sendable {
        let resultHash: UInt32
        let completionOrdinal: UInt64
        let sourceHash: UInt32
        let registrationGeneration: UInt64
        let leaseStartOrdinal: UInt64
        let transitionOrdinalAtLease: UInt64

        var resultTag: String { String(resultHash, radix: 16) }
        var sourceTag: String { String(sourceHash, radix: 16) }
        var resultIdentity: String { "\(resultTag)@\(completionOrdinal)" }

        func globalReplaceStateCalls(at resolveOrdinal: UInt64?) -> UInt64? {
            guard let resolveOrdinal, resolveOrdinal < UInt64.max,
                resolveOrdinal >= transitionOrdinalAtLease
            else { return nil }
            return resolveOrdinal - transitionOrdinalAtLease
        }
    }

    package enum ResultLeaseOutcomeCase: String, Sendable {
        case transferred
        case queuedForRetry
        case staleResultDiscarded
        case consumerMismatch = "rejected.consumerMismatch"
        case noLeaseOutstanding = "rejected.noLeaseOutstanding"
        case leaseMismatch = "rejected.leaseMismatch"

        init(_ resolution: borrowing WatchedFolderScanResultLeaseResolutionResult) {
            switch copy resolution {
            case .transferred: self = .transferred
            case .queuedForRetry: self = .queuedForRetry
            case .staleResultDiscarded: self = .staleResultDiscarded
            case .rejected(.consumerMismatch): self = .consumerMismatch
            case .rejected(.noLeaseOutstanding): self = .noLeaseOutstanding
            case .rejected(.leaseMismatch): self = .leaseMismatch
            }
        }
    }

    struct ResultLeaseOutcomeCheckpoints: Equatable, Sendable {
        let scheduler: ResultLeaseOutcomeCase?
        let afterResolve: ResultLeaseOutcomeCase?
        let beforeSwitch: ResultLeaseOutcomeCase?
    }

    enum ResultLeaseRegistrationView: Equatable, Sendable {
        case unregistered
        case registered(generation: UInt64)
    }

    struct LocatedResultLeaseDiagnostics: Equatable, Sendable {
        let expectedLeaseHash: UInt32
        let sourceHash: UInt32
        let registration: ResultLeaseRegistrationView
        let leaseRegistrationGeneration: UInt64
        let stateCase: SchedulingStateCase
    }

    enum RejectedResultLeaseCurrentView: Equatable, Sendable {
        case unavailable
        case located(LocatedResultLeaseDiagnostics)
    }

    struct RejectedResultLeaseSnapshot: Equatable, Sendable {
        let outcome: ResultLeaseOutcomeCase
        let submittedLeaseHash: UInt32
        let submitted: SubmittedLeaseDiagnostics
        let current: RejectedResultLeaseCurrentView
        let pendingCount: Int
        let leasedCount: Int
        let transitionOrdinalAtResolve: UInt64
        let transitions: [SchedulingTransition]

        var globalReplaceStateCalls: UInt64? {
            submitted.globalReplaceStateCalls(at: transitionOrdinalAtResolve)
        }
    }

    struct ResultLeaseResolutionObservation: Equatable, Sendable {
        let leaseID: WatchedFolderScanResultLeaseID
        let leaseStartOrdinal: UInt64
        let outcome: ResultLeaseOutcomeCase
        let transitionOrdinalAtResolve: UInt64
        let rejection: RejectedResultLeaseSnapshot?
    }

    func resultLeaseResolutionObservation(
        for consumer: WatchedFolderScanResultConsumerToken,
        leaseID: WatchedFolderScanResultLeaseID,
        leaseStartOrdinal: UInt64
    ) -> ResultLeaseResolutionObservation? {
        guard let recorded = lastResultLeaseOutcomes[consumer],
            recorded.leaseID == leaseID, recorded.leaseStartOrdinal == leaseStartOrdinal
        else { return nil }
        return recorded
    }

    func makeSubmittedLeaseDiagnostics(for pending: PendingResult) -> SubmittedLeaseDiagnostics {
        let (nextOrdinal, overflow) = nextDiagnosticLeaseOrdinal.addingReportingOverflow(1)
        nextDiagnosticLeaseOrdinal = overflow ? UInt64.max : nextOrdinal
        return .init(
            resultHash: UInt32(truncatingIfNeeded: pending.result.resultID.hashValue),
            completionOrdinal: pending.completionOrdinal,
            sourceHash: UInt32(truncatingIfNeeded: pending.result.request.sourceID.hashValue),
            registrationGeneration: pending.result.request.canonicalRoot.registration.registrationGeneration,
            leaseStartOrdinal: nextDiagnosticLeaseOrdinal,
            transitionOrdinalAtLease: stateBySourceID.currentTransitionOrdinal)
    }

    func locatedResultLeaseDiagnostics(
        sourceID: FilesystemSourceID, leased: LeasedResult
    ) -> RejectedResultLeaseCurrentView {
        let registration: ResultLeaseRegistrationView
        if let current = currentRootBySourceID[sourceID]?.registration {
            registration = .registered(generation: current.registrationGeneration)
        } else {
            registration = .unregistered
        }
        return .located(
            .init(
                expectedLeaseHash: UInt32(truncatingIfNeeded: leased.leaseID.hashValue),
                sourceHash: UInt32(truncatingIfNeeded: sourceID.hashValue), registration: registration,
                leaseRegistrationGeneration: leased.pending.result.request.canonicalRoot.registration
                    .registrationGeneration,
                stateCase: stateBySourceID[sourceID]?.diagnosticStateCase ?? .absent))
    }

    func recordResultLeaseResolution(
        _ resolution: WatchedFolderScanResultLeaseResolutionResult,
        for consumer: WatchedFolderScanResultConsumerToken,
        leaseID: WatchedFolderScanResultLeaseID,
        submitted: SubmittedLeaseDiagnostics,
        transitionOrdinalAtResolve: UInt64,
        current: RejectedResultLeaseCurrentView = .unavailable
    ) -> WatchedFolderScanResultLeaseResolutionResult {
        let outcome = ResultLeaseOutcomeCase(resolution)
        let rejection: RejectedResultLeaseSnapshot?
        if case .rejected = resolution {
            let counts = stateBySourceID.counts
            let snapshot = RejectedResultLeaseSnapshot(
                outcome: outcome, submittedLeaseHash: UInt32(truncatingIfNeeded: leaseID.hashValue),
                submitted: submitted, current: current, pendingCount: counts.pending,
                leasedCount: counts.leased, transitionOrdinalAtResolve: transitionOrdinalAtResolve,
                transitions: stateBySourceID.recentTransitions)
            rejection = snapshot
            for line in Self.formatRejectedResultLease(snapshot).split(separator: "\n") {
                Self.logger.fault(
                    "Result custody \(submitted.resultIdentity, privacy: .public): \(line, privacy: .public)")
            }
        } else {
            rejection = nil
        }
        lastResultLeaseOutcomes[consumer] = .init(
            leaseID: leaseID, leaseStartOrdinal: submitted.leaseStartOrdinal, outcome: outcome,
            transitionOrdinalAtResolve: transitionOrdinalAtResolve, rejection: rejection)
        return resolution
    }
}
