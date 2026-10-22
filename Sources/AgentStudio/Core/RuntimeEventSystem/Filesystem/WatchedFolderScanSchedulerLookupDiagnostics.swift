import AgentStudioInfrastructure
import Foundation

extension WatchedFolderScanScheduler {
    struct LeaseLookupCheckpoints: Equatable, Sendable {
        let afterSelection: String
        let beforeLeaseCreation: String
        let afterLeaseCreation: String

        var firstAbsentCheckpoint: String {
            if afterSelection == "absent" { return "after-selection" }
            if beforeLeaseCreation == "absent" { return "before-lease-id" }
            if afterLeaseCreation == "absent" { return "after-lease-id" }
            return "none"
        }
    }

    struct LeaseLookupResultIdentity: Equatable, Sendable {
        let resultTag: String
        let completionOrdinal: UInt64

        var reportText: String { "\(resultTag)@\(completionOrdinal)" }
    }

    struct LeaseLookupEntry: Equatable, Sendable {
        let stateCase: String
        let result: LeaseLookupResultIdentity?
        let hashesAgree: Bool
    }

    struct SchedulingTransition: Equatable, Sendable {
        let ordinal: UInt64
        private let sourceHash: UInt32
        private let fromState: SchedulingStateCase
        private let toState: SchedulingStateCase
        let isNoOp: Bool

        var sourceTag: String { String(sourceHash, radix: 16) }
        var fromCase: String { fromState.rawValue }
        var toCase: String { toState.rawValue }

        init(
            ordinal: UInt64, sourceHash: UInt32, fromState: SchedulingStateCase,
            toState: SchedulingStateCase, isNoOp: Bool
        ) {
            self.ordinal = ordinal
            self.sourceHash = sourceHash
            self.fromState = fromState
            self.toState = toState
            self.isNoOp = isNoOp
        }

        // Value snapshots accept canonical diagnostic text; the live writer uses scalar values.
        init(ordinal: UInt64, sourceTag: String, fromCase: String, toCase: String, isNoOp: Bool) {
            guard let sourceHash = UInt32(sourceTag, radix: 16),
                String(sourceHash, radix: 16) == sourceTag,
                let fromState = SchedulingStateCase(rawValue: fromCase),
                let toState = SchedulingStateCase(rawValue: toCase)
            else { preconditionFailure("invalid scheduling transition diagnostic value") }
            self.init(
                ordinal: ordinal, sourceHash: sourceHash, fromState: fromState, toState: toState, isNoOp: isNoOp)
        }
    }

    struct LeaseDiagnosticBuild: Equatable, Sendable {
        let compilerRange: String
        let languageRange: String

        static var compiledRanges: Self {
            let compilerRange: String
            #if compiler(>=6.4)
                compilerRange = ">=6.4"
            #elseif compiler(>=6.3)
                compilerRange = ">=6.3,<6.4"
            #elseif compiler(>=6.2)
                compilerRange = ">=6.2,<6.3"
            #else
                compilerRange = "<6.2"
            #endif
            let languageRange: String
            #if swift(>=6.2)
                languageRange = ">=6.2"
            #elseif swift(>=6.0)
                languageRange = ">=6.0,<6.2"
            #else
                languageRange = "<6.0"
            #endif
            return Self(compilerRange: compilerRange, languageRange: languageRange)
        }
    }

    struct LeaseLookupSnapshot: Equatable, Sendable {
        let checkpoints: LeaseLookupCheckpoints
        let selectedSourceTag: String
        let selectedResult: LeaseLookupResultIdentity
        let selectedKeyMatchesRequest: Bool
        let equalKeyEntries: [LeaseLookupEntry]
        let candidateCount: Int
        let scheduledRootCount: Int
        let storedPendingCount: Int
        let leasedCount: Int
        let enumeratedPendingCount: Int
        let selectedResultIsPending: Bool
        let transitions: [SchedulingTransition]
        let build: LeaseDiagnosticBuild
    }

    // Swift's process-seeded hash is a short correlation tag, never an identity comparison.
    static func diagnosticTag<Value: Hashable>(_ value: Value) -> String {
        String(UInt32(truncatingIfNeeded: value.hashValue), radix: 16)
    }

    static func formatLeaseLookup(_ snapshot: LeaseLookupSnapshot) -> String {
        let summary =
            "Selected result must remain pending until leased; reread state: \(snapshot.checkpoints.afterLeaseCreation), "
            + "candidates: \(snapshot.candidateCount), scheduled roots: \(snapshot.scheduledRootCount), "
            + "pending: \(snapshot.storedPendingCount), leased: \(snapshot.leasedCount)"
        let checkpoints =
            "checkpoints: after-selection=\(snapshot.checkpoints.afterSelection), "
            + "before-lease-id=\(snapshot.checkpoints.beforeLeaseCreation), "
            + "after-lease-id=\(snapshot.checkpoints.afterLeaseCreation), first-nil=\(snapshot.checkpoints.firstAbsentCheckpoint)"
        let selected =
            "selected: source=\(snapshot.selectedSourceTag), result=\(snapshot.selectedResult.reportText), "
            + "key-matches-request=\(snapshot.selectedKeyMatchesRequest)"
        let entries = snapshot.equalKeyEntries.map { entry in
            "equal-key: \(entry.stateCase):\(entry.result?.reportText ?? "none"):hash-agree=\(entry.hashesAgree)"
        }
        let recount =
            "pending-recount: \(snapshot.enumeratedPendingCount), "
            + "matches-stored=\(snapshot.enumeratedPendingCount == snapshot.storedPendingCount), "
            + "selected-result-present=\(snapshot.selectedResultIsPending)"
        let transitions = snapshot.transitions.map { entry in
            "transition: \(entry.ordinal):\(entry.sourceTag):\(entry.fromCase)->\(entry.toCase):no-op=\(entry.isNoOp)"
        }
        let build =
            "build: compiler-range=\(snapshot.build.compilerRange), language-range=\(snapshot.build.languageRange), "
            + "optimization=unknown at compile time, exclusivity=unknown at compile time"
        return
            ([summary, checkpoints, selected, "equal-keys: count=\(entries.count)"] + entries
            + [recount, "transitions: count=\(transitions.count)"] + transitions + [build]).joined(separator: "\n")
    }
}

extension WatchedFolderScanScheduler.SchedulingStateStore {
    func captureLeaseLookup(
        selectedSourceID: FilesystemSourceID,
        selected: WatchedFolderScanScheduler.PendingResult,
        checkpoints: WatchedFolderScanScheduler.LeaseLookupCheckpoints,
        candidateCount: Int
    ) -> WatchedFolderScanScheduler.LeaseLookupSnapshot {
        var equalKeyEntries: [WatchedFolderScanScheduler.LeaseLookupEntry] = []
        var pendingCount = 0
        var selectedResultIsPending = false
        for (sourceID, state) in self {
            if sourceID == selectedSourceID {
                equalKeyEntries.append(
                    .init(
                        stateCase: state.diagnosticCaseName,
                        result: state.retainedDiagnosticResult.map(Self.resultIdentity),
                        hashesAgree: sourceID.hashValue == selectedSourceID.hashValue))
            }
            switch state {
            case .pendingResult(let pending), .pendingResultAndDirty(let pending, _):
                pendingCount += 1
                if pending.result.resultID == selected.result.resultID,
                    pending.completionOrdinal == selected.completionOrdinal
                {
                    selectedResultIsPending = true
                }
            default: break
            }
        }
        return .init(
            checkpoints: checkpoints, selectedSourceTag: WatchedFolderScanScheduler.diagnosticTag(selectedSourceID),
            selectedResult: Self.resultIdentity(selected),
            selectedKeyMatchesRequest: selectedSourceID == selected.result.request.sourceID,
            equalKeyEntries: equalKeyEntries,
            candidateCount: candidateCount, scheduledRootCount: scheduledRootCount,
            storedPendingCount: counts.pending, leasedCount: counts.leased,
            enumeratedPendingCount: pendingCount, selectedResultIsPending: selectedResultIsPending,
            transitions: recentTransitions, build: .compiledRanges)
    }

    private static func resultIdentity(
        _ pending: WatchedFolderScanScheduler.PendingResult
    ) -> WatchedFolderScanScheduler.LeaseLookupResultIdentity {
        .init(
            resultTag: WatchedFolderScanScheduler.diagnosticTag(pending.result.resultID),
            completionOrdinal: pending.completionOrdinal)
    }
}

extension WatchedFolderScanScheduler.RootSchedulingState {
    fileprivate var retainedDiagnosticResult: WatchedFolderScanScheduler.PendingResult? {
        switch self {
        case .pendingResult(let pending), .pendingResultAndDirty(let pending, _): pending
        case .leasedResult(let leased), .leasedResultAndDirty(let leased, _): leased.pending
        default: nil
        }
    }
}
