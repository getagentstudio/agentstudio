extension WatchedFolderScanScheduler {
    static func formatSubmittedResultLease(
        _ submitted: SubmittedLeaseDiagnostics, transitionOrdinalAtResolve: UInt64?
    ) -> String {
        "result=\(submitted.resultIdentity), source=\(submitted.sourceTag), "
            + "registration-at-lease=\(submitted.registrationGeneration), lease-start-ordinal=\(submitted.leaseStartOrdinal)"
            + "\ntransition-at-lease=\(submitted.transitionOrdinalAtLease), "
            + "transition-at-resolve=\(transitionOrdinalAtResolve.map(String.init) ?? "unavailable"), "
            + "global-replaceState-calls=\(submitted.globalReplaceStateCalls(at: transitionOrdinalAtResolve).map(String.init) ?? "unavailable") "
            + "(across-all-roots-including-no-ops)\ncorrelation=per-process-only"
    }

    static func formatResultLeaseOutcomeCheckpoints(_ observations: ResultLeaseOutcomeCheckpoints) -> String {
        let outcomes =
            "scheduler-outcome=\(observations.scheduler?.rawValue ?? "unknown"), "
            + "after-resolve=\(observations.afterResolve?.rawValue ?? "unavailable"), "
            + "before-switch=\(observations.beforeSwitch?.rawValue ?? "unavailable")"
        return outcomes + "\n"
            + "disagreements: a-b=\(compareLeaseOutcomes(observations.scheduler, observations.afterResolve)), "
            + "a-c=\(compareLeaseOutcomes(observations.scheduler, observations.beforeSwitch)), "
            + "b-c=\(compareLeaseOutcomes(observations.afterResolve, observations.beforeSwitch))"
    }

    private static func compareLeaseOutcomes(_ first: ResultLeaseOutcomeCase?, _ second: ResultLeaseOutcomeCase?)
        -> String
    {
        guard let first, let second else { return "unknown(unavailable)" }
        guard first != second else { return "agreed" }
        switch (first.isRejection, second.isRejection) {
        case (false, true): return "success-to-rejection"
        case (true, false): return "rejection-to-success"
        case (true, true): return "different-rejections"
        case (false, false): return "different-successes"
        }
    }

    static func formatRejectedResultLease(_ snapshot: RejectedResultLeaseSnapshot) -> String {
        let submitted = snapshot.submitted
        let identity =
            "outcome=\(snapshot.outcome.rawValue), submitted-lease=\(String(snapshot.submittedLeaseHash, radix: 16))"
        let submittedContext = formatSubmittedResultLease(
            submitted, transitionOrdinalAtResolve: snapshot.transitionOrdinalAtResolve)
        let counts = "pending=\(snapshot.pendingCount), leased=\(snapshot.leasedCount)"
        let history = snapshot.transitions.map {
            "transition: \($0.ordinal):\($0.sourceTag):\($0.fromCase)->\($0.toCase):no-op=\($0.isNoOp)"
        }
        return
            ([
                identity, submittedContext, formatCurrentResultLease(snapshot.current), counts,
                "submitted-source-current-registration=unavailable", "transitions: count=\(history.count)",
            ] + history).joined(separator: "\n")
    }

    private static func formatCurrentResultLease(_ current: RejectedResultLeaseCurrentView) -> String {
        switch current {
        case .unavailable:
            return "expected-lease=unavailable, scheduler-source-registered=unavailable, "
                + "scheduler-current-registration=unavailable, scheduler-lease-registration=unavailable, "
                + "scheduler-source=unavailable, scheduler-state=unavailable"
        case .located(let located):
            let registered: String
            let generation: String
            switch located.registration {
            case .unregistered:
                registered = "false"
                generation = "unavailable"
            case .registered(let currentGeneration):
                registered = "true"
                generation = String(currentGeneration)
            }
            return "expected-lease=\(String(located.expectedLeaseHash, radix: 16)), "
                + "scheduler-source=\(String(located.sourceHash, radix: 16)), "
                + "scheduler-source-registered=\(registered), scheduler-current-registration=\(generation), "
                + "scheduler-lease-registration=\(located.leaseRegistrationGeneration), scheduler-state=\(located.stateCase.rawValue)"
        }
    }
}

extension WatchedFolderScanScheduler.ResultLeaseOutcomeCase {
    fileprivate var isRejection: Bool {
        switch self {
        case .transferred, .queuedForRetry, .staleResultDiscarded: false
        case .consumerMismatch, .noLeaseOutstanding, .leaseMismatch: true
        }
    }
}
