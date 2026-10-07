import AgentStudioCore
import Synchronization

package final class TestPaneContextMembership: PaneContextMembershipReading, Sendable {
    private let views = Mutex<[PaneId: [PaneId]]>([:])

    package init() {}

    package func sources(for paneId: PaneId) -> [PaneId]? {
        views.withLock { $0[paneId] }
    }

    package func addPane(_ paneId: PaneId) {
        views.withLock { $0[paneId] = [paneId] }
    }

    package func setDrawers(_ drawers: [PaneId], for owner: PaneId) {
        views.withLock { current in
            current[owner] = [owner] + drawers
            for drawer in drawers { current[drawer] = [drawer] }
        }
    }

    package func removePane(_ paneId: PaneId) {
        _ = views.withLock { $0.removeValue(forKey: paneId) }
    }
}
