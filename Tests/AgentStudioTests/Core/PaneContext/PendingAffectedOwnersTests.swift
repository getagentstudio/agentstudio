import AgentStudioInfrastructure
import Testing

@testable import AgentStudioCore

@Suite("Pending affected owners")
struct PendingAffectedOwnersTests {
    @Test(
        "The named bound preserves owners through the cap, then collapses to all",
        arguments: [
            0, 1, AppPolicies.PaneContext.maximumPendingAffectedOwners,
            AppPolicies.PaneContext.maximumPendingAffectedOwners + 1,
        ])
    func policyBoundary(count: Int) {
        let owners = Set((0..<count).map { _ in PaneId.generateUUIDv7() })
        var pending = PendingAffectedOwners.owners([])
        pending.insert(contentsOf: owners)
        let expected: PendingAffectedOwners =
            count > AppPolicies.PaneContext.maximumPendingAffectedOwners ? .all : .owners(owners)
        #expect(pending == expected)
    }

    @Test("Repeated moves of the same panes deduplicate without collapsing")
    func repeatedMovesDeduplicate() {
        let owners = Set((0..<4).map { _ in PaneId.generateUUIDv7() })
        var pending = PendingAffectedOwners.owners([])
        for _ in 0..<5 { pending.insert(contentsOf: owners) }
        #expect(pending == .owners(owners))
    }

    @Test("All absorbs subsequent inserts, including an empty update")
    func allAbsorbsUpdates() {
        var pending = PendingAffectedOwners.all
        pending.insert(contentsOf: [PaneId.generateUUIDv7()])
        pending.insert(contentsOf: [])
        #expect(pending == .all)
    }

    @Test("Unique inserts accumulated across commits collapse at the named cap")
    func accumulatedUniqueOwnersCollapse() {
        var pending = PendingAffectedOwners.owners([])
        for _ in 0...AppPolicies.PaneContext.maximumPendingAffectedOwners {
            pending.insert(contentsOf: [PaneId.generateUUIDv7()])
        }
        #expect(pending == .all)
    }
}
