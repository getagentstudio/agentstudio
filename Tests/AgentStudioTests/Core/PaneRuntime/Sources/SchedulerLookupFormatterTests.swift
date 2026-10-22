import Testing

@testable import AgentStudioCore

@Suite("Scheduler lookup diagnostic formatter")
struct SchedulerLookupFormatterTests {
    typealias Scheduler = WatchedFolderScanScheduler

    struct FormatterRow: Sendable {
        let name: String
        let checkpoints: Scheduler.LeaseLookupCheckpoints
        let firstNil: String
        var keyMatchesRequest = true
        var entries: [Scheduler.LeaseLookupEntry] = []
        var entryLines: [String] = []
        var enumeratedPending = 1
        var selectedPending = true
        var hasHistory = false
        var compilerRange = ">=6.4"
        var languageRange = ">=6.0"
    }

    @Test("all diagnostic evidence survives exact report formatting", arguments: rows)
    func literalReport(row: FormatterRow) {
        let selected = Scheduler.LeaseLookupResultIdentity(resultTag: "abc2", completionOrdinal: 7)
        let snapshot = Scheduler.LeaseLookupSnapshot(
            checkpoints: row.checkpoints, selectedSourceTag: "abc1", selectedResult: selected,
            selectedKeyMatchesRequest: row.keyMatchesRequest,
            equalKeyEntries: row.entries, candidateCount: 1, scheduledRootCount: 2,
            storedPendingCount: 1, leasedCount: 0, enumeratedPendingCount: row.enumeratedPending,
            selectedResultIsPending: row.selectedPending,
            transitions: row.hasHistory
                ? [
                    .init(ordinal: 2, sourceTag: "abc1", fromCase: "pendingResult", toCase: "absent", isNoOp: false),
                    .init(ordinal: 3, sourceTag: "abc1", fromCase: "absent", toCase: "absent", isNoOp: true),
                ] : [],
            build: .init(compilerRange: row.compilerRange, languageRange: row.languageRange))
        let history =
            row.hasHistory
            ? ["transition: 2:abc1:pendingResult->absent:no-op=false", "transition: 3:abc1:absent->absent:no-op=true"]
            : []
        let summary =
            "Selected result must remain pending until leased; reread state: \(row.checkpoints.afterLeaseCreation), "
            + "candidates: 1, scheduled roots: 2, pending: 1, leased: 0"
        let checkpoints =
            "checkpoints: after-selection=\(row.checkpoints.afterSelection), "
            + "before-lease-id=\(row.checkpoints.beforeLeaseCreation), "
            + "after-lease-id=\(row.checkpoints.afterLeaseCreation), first-nil=\(row.firstNil)"
        let recount =
            "pending-recount: \(row.enumeratedPending), matches-stored=\(row.enumeratedPending == 1), "
            + "selected-result-present=\(row.selectedPending)"
        let build =
            "build: compiler-range=\(row.compilerRange), language-range=\(row.languageRange), "
            + "optimization=unknown at compile time, exclusivity=unknown at compile time"
        let expected =
            ([
                summary, checkpoints,
                "selected: source=abc1, result=abc2@7, key-matches-request=\(row.keyMatchesRequest)",
                "equal-keys: count=\(row.entries.count)",
            ] + row.entryLines + [recount, "transitions: count=\(history.count)"] + history + [build]).joined(
                separator: "\n")

        #expect(Scheduler.formatLeaseLookup(snapshot) == expected, "Literal report row: \(row.name)")
    }

    static let rows: [FormatterRow] = [
        .init(
            name: "first lookup absent",
            checkpoints: .init(
                afterSelection: "absent", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-selection"),
        .init(
            name: "pre-allocation lookup absent",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "absent", afterLeaseCreation: "absent"),
            firstNil: "before-lease-id"),
        .init(
            name: "post-allocation lookup absent",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id"),
        .init(
            name: "wrong case without nil",
            checkpoints: .init(
                afterSelection: "pendingResultAndDirty", beforeLeaseCreation: "pendingResultAndDirty",
                afterLeaseCreation: "running"), firstNil: "none"),
        .init(
            name: "equal key retains case and identity",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id",
            entries: [
                .init(
                    stateCase: "pendingResultAndDirty", result: .init(resultTag: "abc2", completionOrdinal: 7),
                    hashesAgree: true)
            ],
            entryLines: ["equal-key: pendingResultAndDirty:abc2@7:hash-agree=true"]),
        .init(
            name: "multiple equal keys preserve disagreeing hash and absent result",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id",
            entries: [
                .init(
                    stateCase: "leasedResult", result: .init(resultTag: "abc3", completionOrdinal: 8), hashesAgree: true
                ),
                .init(stateCase: "running", result: nil, hashesAgree: false),
            ],
            entryLines: ["equal-key: leasedResult:abc3@8:hash-agree=true", "equal-key: running:none:hash-agree=false"]),
        .init(
            name: "pending recount under stored count",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id", enumeratedPending: 0, selectedPending: false),
        .init(
            name: "pending recount over stored count",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id", enumeratedPending: 2),
        .init(
            name: "key differs from result request",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id", keyMatchesRequest: false, selectedPending: false),
        .init(
            name: "ordered transitions include no-op",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id", hasHistory: true),
        .init(
            name: "build labels describe ranges only",
            checkpoints: .init(
                afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent"),
            firstNil: "after-lease-id", compilerRange: "<6.4", languageRange: "<6.0"),
    ]
}
