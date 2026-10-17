import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInboxNotification
@testable import AgentStudioInfrastructure
@testable import AgentStudioRepoExplorer
@testable import AgentStudioSharedComponents
@testable import AgentStudioTestSupport

@MainActor
func makeInboxNotificationTestOcticonLoader() -> OcticonLoader {
    OcticonLoader(resourceBundle: Bundle.appResources)
}

@MainActor
@Suite("InboxNotificationSidebarView", .serialized)
struct InboxNotificationSidebarViewTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("mounted dormant Inbox sidebar omits retired command controls")
    func mountedDormantInboxSidebarOmitsRetiredCommandControls() async throws {
        let router = MockAppCommandRouter()
        router.appCommands = [.clearReadInboxNotifications]
        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = router
                configuration.workspaceOwner = nil
            },
            body: { dispatcher in
                let hostingView = NSHostingView(
                    rootView: InboxNotificationSidebarView(
                        inboxAtom: InboxNotificationAtom(),
                        octiconLoader: makeInboxNotificationTestOcticonLoader(),
                        prefsAtom: InboxNotificationPrefsAtom(),
                        uiState: WorkspaceSidebarState(),
                        sidebarCache: SidebarCacheState(),
                        inboxSidebarState: InboxSidebarState(),
                        workspacePaneAtom: WorkspacePaneAtom(),
                        workspaceRepositoryTopologyAtom: RepositoryTopologyAtom(),
                        repoCache: RepoCacheAtom(),
                        dispatcher: dispatcher,
                        onSetRowStateFilter: { _ in },
                        onSetContentMode: { _ in },
                        onRefocusActivePane: {}
                    )
                    .frame(width: 360, height: 420)
                )
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 360, height: 420),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = hostingView
                window.makeKeyAndOrderFront(nil)
                defer { window.orderOut(nil) }
                hostingView.layoutSubtreeIfNeeded()

                #expect(inboxSidebarAccessibleElementCount(in: hostingView, identifier: "inboxSidebarSearchRow") == 1)
                #expect(inboxSidebarAccessibleElementCount(in: hostingView, identifier: "inboxSidebarToolbarRow") == 1)
                #expect(inboxSidebarAccessibleElementCount(in: hostingView, identifier: "inboxSidebarDeleteMenu") == 0)
                #expect(inboxSidebarAccessibleElementCount(in: hostingView, identifier: "inboxSidebarClearButton") == 0)
                #expect(
                    inboxSidebarAccessibleElementCount(in: hostingView, identifier: "inboxSidebarSortButtonFrame") == 0)
                guard
                    inboxSidebarAccessibleElementCount(
                        in: hostingView,
                        identifier: "inboxSidebarDeleteMenu"
                    ) > 0
                else { return }
                guard
                    let searchRow = inboxSidebarDescendant(
                        in: hostingView,
                        identifier: "inboxSidebarSearchRow"
                    ),
                    let toolbarRow = inboxSidebarDescendant(
                        in: hostingView,
                        identifier: "inboxSidebarToolbarRow"
                    ),
                    let deleteMenuView = inboxSidebarDescendant(
                        in: hostingView,
                        identifier: "inboxSidebarDeleteMenu"
                    ),
                    let sortButton = inboxSidebarDescendant(
                        in: hostingView,
                        identifier: "inboxSidebarSortButtonFrame"
                    ),
                    let groupingButton = inboxSidebarDescendant(
                        in: hostingView,
                        identifier: "inboxSidebarGroupingButtonFrame"
                    ),
                    let deleteMenuAccessibleTarget = inboxSidebarAccessibleElement(
                        in: hostingView,
                        identifier: "inboxSidebarDeleteMenu"
                    )
                else {
                    Issue.record("mounted inbox sidebar should expose the delete menu accessibility target")
                    return
                }
                let searchRowFrame = searchRow.convert(searchRow.bounds, to: hostingView)
                let toolbarRowFrame = toolbarRow.convert(toolbarRow.bounds, to: hostingView)
                let deleteMenuFrame = deleteMenuView.convert(deleteMenuView.bounds, to: hostingView)
                let sortButtonFrame = sortButton.convert(sortButton.bounds, to: hostingView)
                let groupingButtonFrame = groupingButton.convert(groupingButton.bounds, to: hostingView)

                #expect(deleteMenuFrame.width > 0)
                #expect(deleteMenuFrame.height > 0)
                #expect(abs(deleteMenuFrame.midY - toolbarRowFrame.midY) < 2)
                #expect(deleteMenuFrame.maxX <= sortButtonFrame.minX)
                #expect(sortButtonFrame.maxX <= groupingButtonFrame.minX)
                #expect(groupingButtonFrame.maxX <= toolbarRowFrame.maxX)
                #expect(searchRowFrame.width > toolbarRowFrame.width * 0.9)

                pressInboxSidebarAccessibleElement(deleteMenuAccessibleTarget)

                #expect(router.handledCommands.isEmpty)
            }
        )
    }

}
