import Testing

@testable import AgentStudioCore

@Suite("FilesystemActor result custody outcome observations")
struct FilesystemActorResultCustodyFormatterTests {
    typealias Scheduler = WatchedFolderScanScheduler
    typealias Outcome = Scheduler.ResultLeaseOutcomeCase

    struct PairRow: Sendable {
        let first: Outcome?
        let second: Outcome?
        let expected: String
    }

    static var pairRows: [PairRow] {
        let outcomes: [Outcome?] = [
            .transferred, .queuedForRetry, .staleResultDiscarded, .consumerMismatch, .noLeaseOutstanding,
            .leaseMismatch, nil,
        ]
        let matrix = [
            [
                "agreed", "different-successes", "different-successes", "success-to-rejection", "success-to-rejection",
                "success-to-rejection", "unknown",
            ],
            [
                "different-successes", "agreed", "different-successes", "success-to-rejection", "success-to-rejection",
                "success-to-rejection", "unknown",
            ],
            [
                "different-successes", "different-successes", "agreed", "success-to-rejection", "success-to-rejection",
                "success-to-rejection", "unknown",
            ],
            [
                "rejection-to-success", "rejection-to-success", "rejection-to-success", "agreed",
                "different-rejections", "different-rejections", "unknown",
            ],
            [
                "rejection-to-success", "rejection-to-success", "rejection-to-success", "different-rejections",
                "agreed", "different-rejections", "unknown",
            ],
            [
                "rejection-to-success", "rejection-to-success", "rejection-to-success", "different-rejections",
                "different-rejections", "agreed", "unknown",
            ],
            ["unknown", "unknown", "unknown", "unknown", "unknown", "unknown", "unknown"],
        ]
        return outcomes.enumerated().flatMap { firstIndex, first in
            outcomes.enumerated().map { secondIndex, second in
                PairRow(first: first, second: second, expected: matrix[firstIndex][secondIndex])
            }
        }
    }

    @Test("every pair is classified at all three observation boundaries", arguments: pairRows)
    func disagreementPairs(row: PairRow) {
        let first = Scheduler.formatResultLeaseOutcomeCheckpoints(
            .init(scheduler: row.first, afterResolve: row.second, beforeSwitch: row.second))
        #expect(first.contains("a-b=\(row.expected)"))
        #expect(first.contains("a-c=\(row.expected)"))
        let second = Scheduler.formatResultLeaseOutcomeCheckpoints(
            .init(scheduler: row.first, afterResolve: row.first, beforeSwitch: row.second))
        #expect(second.contains("b-c=\(row.expected)"))
        if row.first == nil || row.second == nil { #expect(first.contains("unavailable")) }
        if row.first == nil {
            #expect(first.contains("scheduler-outcome=unknown"))
            #expect(!first.contains("a-b=agreed"))
        }
    }

    @Test("outcome names identify the actual main rejection variants")
    func rejectionNames() {
        #expect(Outcome(.rejected(.consumerMismatch)).rawValue == "rejected.consumerMismatch")
        #expect(Outcome(.rejected(.noLeaseOutstanding)).rawValue == "rejected.noLeaseOutstanding")
        #expect(
            Outcome(.rejected(.leaseMismatch(submitted: .make(), current: .make()))).rawValue
                == "rejected.leaseMismatch")
        #expect(Outcome(.transferred).rawValue == "transferred")
        #expect(Outcome(.queuedForRetry).rawValue == "queuedForRetry")
        #expect(Outcome(.staleResultDiscarded).rawValue == "staleResultDiscarded")
    }
    @Test("submitted context remains reportable when scheduler observation is unavailable")
    func submittedContextWithoutSchedulerObservation() {
        let submitted = Scheduler.SubmittedLeaseDiagnostics(
            resultHash: 0xa, completionOrdinal: 7, sourceHash: 0xb,
            registrationGeneration: 3, leaseStartOrdinal: 4, transitionOrdinalAtLease: 11)
        let report = Scheduler.formatSubmittedResultLease(submitted, transitionOrdinalAtResolve: nil)
        #expect(report.contains("result=a@7"))
        #expect(report.contains("source=b"))
        #expect(report.contains("registration-at-lease=3"))
        #expect(report.contains("lease-start-ordinal=4"))
        #expect(report.contains("transition-at-lease=11"))
        #expect(report.contains("transition-at-resolve=unavailable"))
        #expect(report.contains("global-replaceState-calls=unavailable"))
        #expect(report.contains("across-all-roots-including-no-ops"))
    }

}
