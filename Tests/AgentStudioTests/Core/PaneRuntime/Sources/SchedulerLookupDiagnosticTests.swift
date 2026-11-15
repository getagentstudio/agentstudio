import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Scheduler lookup diagnostic capture and transition history")
struct SchedulerLookupDiagnosticTests {
    typealias Scheduler = WatchedFolderScanScheduler

    @Test("capture reads real pending, dirty, leased and removed custody without changing it", arguments: 0..<5)
    func captureRealStore(custody: Int) throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        let other = try SchedulerLookupDiagnosticFixture(ordinal: 8)
        let sourceID = fixture.request.sourceID
        var store = Scheduler.SchedulingStateStore()
        store[other.request.sourceID] = .pendingResult(other.pending)
        switch custody {
        case 0: store[sourceID] = .pendingResult(fixture.pending)
        case 1: store[sourceID] = .pendingResultAndDirty(fixture.pending, fixture.demand)
        case 2: store[sourceID] = .leasedResult(fixture.leased)
        case 3: store[sourceID] = .leasedResultAndDirty(fixture.leased, fixture.demand)
        default:
            store[sourceID] = .pendingResult(fixture.pending)
            store.removeValue(forKey: sourceID)
        }
        let history = store.recentTransitions
        let checkpoints = Scheduler.LeaseLookupCheckpoints(
            afterSelection: "pendingResult", beforeLeaseCreation: "absent", afterLeaseCreation: "running")
        let snapshot = store.captureLeaseLookup(
            selectedSourceID: sourceID, selected: fixture.pending,
            checkpoints: checkpoints,
            candidateCount: 9)

        #expect(snapshot.checkpoints == checkpoints)
        #expect(snapshot.transitions == history)
        #expect(snapshot.selectedSourceTag == Scheduler.diagnosticTag(sourceID))
        #expect(snapshot.candidateCount == 9)
        #expect(snapshot.selectedKeyMatchesRequest)
        #expect(snapshot.equalKeyEntries.count == (custody == 4 ? 0 : 1))
        #expect(snapshot.enumeratedPendingCount == (custody < 2 ? 2 : 1))
        #expect(snapshot.storedPendingCount == snapshot.enumeratedPendingCount)
        #expect(snapshot.leasedCount == (custody == 2 || custody == 3 ? 1 : 0))
        #expect(snapshot.scheduledRootCount == (custody == 4 ? 1 : 2))
        #expect(snapshot.selectedResultIsPending == (custody < 2))
        #expect(snapshot.selectedResult.completionOrdinal == 7)
        #expect(snapshot.selectedResult.resultTag == Scheduler.diagnosticTag(fixture.pending.result.resultID))
        let expectedCases = ["pendingResult", "pendingResultAndDirty", "leasedResult", "leasedResultAndDirty"]
        if custody < 4 {
            let entry = try #require(snapshot.equalKeyEntries.first)
            #expect(entry.stateCase == expectedCases[custody])
            #expect(entry.hashesAgree)
            #expect(entry.result == snapshot.selectedResult)
        }
        #expect(store.recentTransitions == history, "Failure capture is read-only")
    }

    @Test("capture compares full result identity and key independently")
    func captureIdentityMismatch() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        let other = try SchedulerLookupDiagnosticFixture(ordinal: 8)
        var store = Scheduler.SchedulingStateStore()
        store[fixture.request.sourceID] = .pendingResult(fixture.pending)
        let checkpoints = Scheduler.LeaseLookupCheckpoints(
            afterSelection: "pendingResult", beforeLeaseCreation: "pendingResult", afterLeaseCreation: "absent")
        let foreign = store.captureLeaseLookup(
            selectedSourceID: fixture.request.sourceID, selected: other.pending,
            checkpoints: checkpoints, candidateCount: 1)
        #expect(!foreign.selectedKeyMatchesRequest)
        #expect(!foreign.selectedResultIsPending)
        #expect(foreign.equalKeyEntries.first?.result?.completionOrdinal == 7)
        var anotherOrdinal = Scheduler.PendingResult(result: fixture.pending.result, completionOrdinal: 99)
        let ordinalMismatch = store.captureLeaseLookup(
            selectedSourceID: fixture.request.sourceID, selected: anotherOrdinal,
            checkpoints: checkpoints, candidateCount: 1)
        #expect(ordinalMismatch.selectedKeyMatchesRequest)
        #expect(!ordinalMismatch.selectedResultIsPending)
        anotherOrdinal = Scheduler.PendingResult(result: other.pending.result, completionOrdinal: 7)
        let resultMismatch = store.captureLeaseLookup(
            selectedSourceID: fixture.request.sourceID, selected: anotherOrdinal,
            checkpoints: checkpoints, candidateCount: 1)
        #expect(!resultMismatch.selectedResultIsPending, "Matching ordinal alone is not result identity")
    }

    @Test("both state writers record replacements and marked absent removal")
    func bothMutationAPIs() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        let sourceID = fixture.request.sourceID
        var store = Scheduler.SchedulingStateStore()
        #expect(store.recentTransitions.isEmpty)
        store[sourceID] = .queuedNew(fixture.queued)
        store[sourceID] = .queuedNew(fixture.queued)
        #expect(store.counts.ready == 1)
        #expect(store.removeValue(forKey: sourceID) != nil)
        #expect(store.removeValue(forKey: sourceID) == nil)
        store[sourceID] = .pendingResult(fixture.pending)
        store[sourceID] = nil
        let history = store.recentTransitions
        #expect(history.map(\.ordinal) == [1, 2, 3, 4, 5, 6])
        #expect(history.map(\.fromCase) == ["absent", "queuedNew", "queuedNew", "absent", "absent", "pendingResult"])
        #expect(history.map(\.toCase) == ["queuedNew", "queuedNew", "absent", "absent", "pendingResult", "absent"])
        #expect(history.map(\.isNoOp) == [false, false, false, true, false, false])
        #expect(history.allSatisfy { $0.sourceTag == Scheduler.diagnosticTag(sourceID) })
        #expect(store.counts.ready == 0)
        #expect(store.counts.pending == 0)
        #expect(store.scheduledRootCount == 0)
    }

    @Test("history keeps the last 32 in chronological order through multiple wraps", arguments: [32, 33, 65])
    func ringWrap(writeCount: Int) throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        let other = try SchedulerLookupDiagnosticFixture()
        var store = Scheduler.SchedulingStateStore()
        for ordinal in 1...writeCount {
            let selectedFixture = ordinal.isMultiple(of: 2) ? fixture : other
            store[selectedFixture.request.sourceID] = .pendingResult(selectedFixture.pending)
        }
        let expectedOrdinals = Array((writeCount - 31)...writeCount).map(UInt64.init)
        let history = store.recentTransitions
        #expect(history.count == 32)
        #expect(history.map(\.ordinal) == expectedOrdinals)
        #expect(
            history.map(\.sourceTag)
                == expectedOrdinals.map {
                    Scheduler.diagnosticTag($0.isMultiple(of: 2) ? fixture.request.sourceID : other.request.sourceID)
                })
        #expect(history.allSatisfy { $0.toCase == "pendingResult" && !$0.isNoOp })
        #expect(store.counts.pending == 2)
    }

    @Test("history describes every state case and leaves ready indexes intact")
    func allCasesAndReadOnlyOperations() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        let expected = [
            "queuedNew", "queuedSuspended", "queuedSuspendedAndDirty", "running", "runningAndDirty",
            "awaitingValidation", "awaitingValidationAndDirty", "pendingResult", "pendingResultAndDirty",
            "leasedResult", "leasedResultAndDirty",
        ]
        var store = Scheduler.SchedulingStateStore()
        for state in fixture.allStates { store[fixture.request.sourceID] = state }
        #expect(store.recentTransitions.map(\.toCase) == expected)
        #expect(store.recentTransitions.map(\.fromCase) == ["absent"] + expected.dropLast())
        #expect(store.counts.leased == 1)
        #expect(store.counts.dirtyFollowUps == 1)
        store[fixture.request.sourceID] = .queuedNew(fixture.queued)
        let before = store.recentTransitions
        #expect(store.oldestReadyScan()?.request.sourceID == fixture.request.sourceID)
        #expect(store[fixture.request.sourceID] != nil)
        #expect(Array(store).count == 1)
        #expect(store.recentTransitions == before)
        #expect(store.readySelectionCount == 1)
        #expect(store.readySelectionWorkUnitCount == 1)
        #expect(store.counts.ready == 1)
        #expect(store.counts.leased == 0)
        #expect(store.counts.dirtyFollowUps == 0)
    }

    @Test("tags never expose the raw source or result UUID")
    func opaqueTags() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        for tag in [
            Scheduler.diagnosticTag(fixture.request.sourceID), Scheduler.diagnosticTag(fixture.pending.result.resultID),
        ] {
            #expect(!tag.isEmpty && tag.count <= 8)
            #expect(tag.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(tag != fixture.request.sourceID.rootID.uuidString)
            #expect(tag != fixture.pending.result.resultID.rawValue.uuidString)
        }
    }
}
