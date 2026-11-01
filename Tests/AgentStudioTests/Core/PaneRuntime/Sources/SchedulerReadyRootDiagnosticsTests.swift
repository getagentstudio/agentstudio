import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Scheduler ready-root fault context")
struct SchedulerReadyRootDiagnosticsTests {
    typealias Scheduler = WatchedFolderScanScheduler

    @Test("capture retains selected node links and exact queue endpoints without mutating the store")
    func captureRealQueue() throws {
        // Arrange
        let first = try SchedulerLookupDiagnosticFixture()
        let selected = try SchedulerLookupDiagnosticFixture()
        let last = try SchedulerLookupDiagnosticFixture()
        let ownerIdentity = UUIDv7.generate()
        var store = Scheduler.SchedulingStateStore(schedulerIdentity: ownerIdentity)
        store[first.request.sourceID] = .queuedNew(first.queued)
        store[selected.request.sourceID] = .queuedNew(selected.queued)
        store[last.request.sourceID] = .queuedNew(last.queued)
        let history = store.recentTransitions
        let ordinal = store.currentTransitionOrdinal

        // Act
        let snapshot = store.captureReadyRootSynchronization(selectedSourceID: selected.request.sourceID)

        // Assert
        #expect(snapshot.storedState == .queuedNew)
        #expect(snapshot.readyCount == 3)
        #expect(snapshot.scheduledRootCount == 3)
        #expect(snapshot.readyNodeCount == 3)
        #expect(snapshot.selectedSourceTag == Scheduler.diagnosticTag(selected.request.sourceID))
        #expect(snapshot.schedulerTag == Scheduler.diagnosticTag(ownerIdentity))
        #expect(snapshot.firstReadySourceTag == Scheduler.diagnosticTag(first.request.sourceID))
        #expect(snapshot.lastReadySourceTag == Scheduler.diagnosticTag(last.request.sourceID))
        #expect(
            snapshot.selectedNode
                == .present(
                    previousSourceTag: Scheduler.diagnosticTag(first.request.sourceID),
                    nextSourceTag: Scheduler.diagnosticTag(last.request.sourceID)))
        #expect(snapshot.transitionOrdinal == ordinal)
        #expect(snapshot.transitions == history)
        #expect(store.recentTransitions == history)
        #expect(store.currentTransitionOrdinal == ordinal)
        #expect(store.readySelectionCount == 0)
        #expect(store.oldestReadyScan()?.request.sourceID == first.request.sourceID)
    }

    @Test("a missing node differs from a present node with empty neighbor links")
    func missingAndSingleNode() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        var store = Scheduler.SchedulingStateStore()
        let missing = store.captureReadyRootSynchronization(selectedSourceID: fixture.request.sourceID)
        #expect(missing.storedState == .absent)
        #expect(missing.schedulerTag == nil)
        #expect(missing.firstReadySourceTag == nil)
        #expect(missing.lastReadySourceTag == nil)
        #expect(missing.selectedNode == .absent)
        #expect(missing.transitions.isEmpty)

        store[fixture.request.sourceID] = .queuedNew(fixture.queued)
        let present = store.captureReadyRootSynchronization(selectedSourceID: fixture.request.sourceID)
        #expect(present.selectedNode == .present(previousSourceTag: nil, nextSourceTag: nil))
        #expect(present.readyNodeCount == 1)
        store[fixture.request.sourceID] = .pendingResult(fixture.pending)
        let pending = store.captureReadyRootSynchronization(selectedSourceID: fixture.request.sourceID)
        #expect(pending.storedState == .pendingResult)
        #expect(pending.selectedNode == .absent)
        #expect(pending.readyNodeCount == 0)
    }

    @Test("fault formatting preserves the existing chronological 32-entry ring after wrap")
    func realRingFormatting() throws {
        let fixture = try SchedulerLookupDiagnosticFixture()
        var store = Scheduler.SchedulingStateStore()
        for _ in 0..<65 { store[fixture.request.sourceID] = .pendingResult(fixture.pending) }
        let snapshot = store.captureReadyRootSynchronization(selectedSourceID: fixture.request.sourceID)
        let lines = Scheduler.formatReadyRootSynchronization(snapshot).split(separator: "\n").map(String.init)
        let tag = Scheduler.diagnosticTag(fixture.request.sourceID)
        let expectedTransitions = (34...65).map {
            "transition: \($0):\(tag):pendingResult->pendingResult:no-op=false"
        }
        #expect(snapshot.transitions.map(\.ordinal) == Array(34...65).map(UInt64.init))
        #expect(lines.count == 36)
        #expect(lines[3] == "transitions: ordinal=65, count=32")
        #expect(Array(lines.dropFirst(4)) == expectedTransitions)
    }

    @Test("an inconsistent ready-root report retains exact scalar evidence and lease-style transition lines")
    func inconsistentReportFormatting() {
        let snapshot = Scheduler.ReadyRootSynchronizationSnapshot(
            storedState: .awaitingValidation, readyCount: 1, scheduledRootCount: 2, readyNodeCount: 1,
            selectedSourceTag: "abc1", schedulerTag: "def2",
            firstReadySourceTag: "abc1", lastReadySourceTag: "abc3",
            selectedNode: .present(previousSourceTag: "abc4", nextSourceTag: "abc3"),
            transitionOrdinal: 42,
            transitions: [
                .init(ordinal: 41, sourceTag: "abc1", fromCase: "running", toCase: "awaitingValidation", isNoOp: false),
                .init(ordinal: 42, sourceTag: "abc3", fromCase: "absent", toCase: "absent", isNoOp: true),
            ])
        let expected = """
            selected: source=abc1, scheduler=def2
            ready-queue: head=abc1, tail=abc3
            selected-node: present, previous=abc4, next=abc3
            transitions: ordinal=42, count=2
            transition: 41:abc1:running->awaitingValidation:no-op=false
            transition: 42:abc3:absent->absent:no-op=true
            """
        #expect(Scheduler.formatReadyRootSynchronization(snapshot) == expected)
    }

    @Test("empty report has explicit unavailable identity and absent node without inventing IDs")
    func emptyReportFormatting() {
        let snapshot = Scheduler.ReadyRootSynchronizationSnapshot(
            storedState: .absent, readyCount: 0, scheduledRootCount: 0, readyNodeCount: 0,
            selectedSourceTag: "abc1", schedulerTag: nil, firstReadySourceTag: nil, lastReadySourceTag: nil,
            selectedNode: .absent, transitionOrdinal: 0, transitions: [])
        #expect(
            Scheduler.formatReadyRootSynchronization(snapshot) == """
                selected: source=abc1, scheduler=unavailable
                ready-queue: head=none, tail=none
                selected-node: absent
                transitions: ordinal=0, count=0
                """
        )
    }
}
