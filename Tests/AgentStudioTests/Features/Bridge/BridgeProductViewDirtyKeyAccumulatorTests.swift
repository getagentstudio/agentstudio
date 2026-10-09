import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product view dirty-key accumulation")
struct BridgeProductViewDirtyKeyAccumulatorTests {
    @Test("repeated mutations coalesce by key and preserve view-domain isolation")
    func repeatedMutationsCoalesceWithinOneDomain() {
        var accumulator = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 2)
        let defaultView = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .singleDomain,
            incarnation: "first"
        )
        let secondDomain = BridgeProductViewDomainKey(
            viewId: "file-view",
            domain: .init(rawValue: "other-domain"),
            incarnation: "first"
        )
        let reviewView = BridgeProductViewDomainKey(
            viewId: "review-view",
            domain: .singleDomain,
            incarnation: "first"
        )

        accumulator.open(defaultView, scanGeneration: 1)
        accumulator.open(secondDomain, scanGeneration: 1)
        accumulator.open(reviewView, scanGeneration: 1)
        _ = accumulator.takePending(for: defaultView)
        _ = accumulator.takePending(for: secondDomain)
        _ = accumulator.takePending(for: reviewView)

        for revision in 1...50 {
            _ = accumulator.recordChange(for: defaultView, scanGeneration: 1, recordKey: "file-a", revision: revision)
        }
        _ = accumulator.recordChange(for: secondDomain, scanGeneration: 1, recordKey: "file-b", revision: 3)
        _ = accumulator.recordChange(for: reviewView, scanGeneration: 1, recordKey: "review-a", revision: 7)

        #expect(accumulator.pending(for: defaultView) == .keys(["file-a": 50]))
        #expect(accumulator.pending(for: secondDomain) == .keys(["file-b": 3]))
        #expect(accumulator.pending(for: reviewView) == .keys(["review-a": 7]))
    }

    @Test("dirty-key overflow requests a snapshot only for its view and domain")
    func overflowIsScopedToOneViewDomain() {
        var accumulator = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 2)
        let overflowing = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let sibling = BridgeProductViewDomainKey(viewId: "review-view", domain: .singleDomain, incarnation: "first")

        accumulator.open(overflowing, scanGeneration: 1)
        accumulator.open(sibling, scanGeneration: 1)
        _ = accumulator.takePending(for: overflowing)
        _ = accumulator.takePending(for: sibling)

        _ = accumulator.recordChange(for: overflowing, scanGeneration: 1, recordKey: "a", revision: 1)
        _ = accumulator.recordChange(for: overflowing, scanGeneration: 1, recordKey: "b", revision: 2)
        _ = accumulator.recordChange(for: overflowing, scanGeneration: 1, recordKey: "c", revision: 3)
        _ = accumulator.recordChange(for: sibling, scanGeneration: 1, recordKey: "x", revision: 4)

        #expect(accumulator.pending(for: overflowing) == .snapshotRequired(.newerInput))
        #expect(accumulator.pending(for: sibling) == .keys(["x": 4]))
    }

    @Test("restoring an unfinished capture retains newer changes")
    func restoringCaptureDoesNotRegressRevision() {
        var accumulator = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 2)
        let view = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        accumulator.open(view, scanGeneration: 1)
        _ = accumulator.takePending(for: view)
        _ = accumulator.recordChange(for: view, scanGeneration: 1, recordKey: "a", revision: 1)
        let captured = accumulator.takePending(for: view)
        _ = accumulator.recordChange(for: view, scanGeneration: 1, recordKey: "a", revision: 3)
        _ = accumulator.recordChange(for: view, scanGeneration: 1, recordKey: "b", revision: 4)

        accumulator.restore(captured, for: view)

        #expect(accumulator.pending(for: view) == .keys(["a": 3, "b": 4]))
    }

    @Test("a retired incarnation and scan cannot dirty its successor")
    func domainIncarnationsStayIsolated() {
        var accumulator = BridgeProductViewDirtyKeyAccumulator(maximumDirtyKeysPerViewDomain: 1)
        let retired = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "first")
        let successor = BridgeProductViewDomainKey(viewId: "file-view", domain: .singleDomain, incarnation: "second")
        accumulator.open(retired, scanGeneration: 1)
        _ = accumulator.takePending(for: retired)
        _ = accumulator.recordChange(for: retired, scanGeneration: 1, recordKey: "old", revision: 1)
        accumulator.open(successor, scanGeneration: 1)
        _ = accumulator.takePending(for: successor)
        let staleIncarnation = accumulator.recordChange(for: retired, scanGeneration: 1, recordKey: "old", revision: 3)
        let current = accumulator.recordChange(for: successor, scanGeneration: 1, recordKey: "new", revision: 2)
        let advanced = accumulator.advanceScanGeneration(for: successor, to: 2)
        _ = accumulator.takePending(for: successor)
        let staleScan = accumulator.recordChange(for: successor, scanGeneration: 1, recordKey: "stale", revision: 4)
        let freshScan = accumulator.recordChange(for: successor, scanGeneration: 2, recordKey: "fresh", revision: 5)

        #expect(!staleIncarnation && current && advanced && !staleScan && freshScan)
        #expect(accumulator.pending(for: retired) == .keys([:]))
        #expect(accumulator.pending(for: successor) == .keys(["fresh": 5]))
    }
}
