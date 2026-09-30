import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

/// The own-pane re-check runs inside validation against the fresh snapshot, so
/// the membership an agent was authorized for must still hold when its
/// action is applied.
@Suite("Workspace command validator own-pane re-check")
struct ActionValidatorOwnPaneTests {
    private let tabId = UUIDv7.generate()
    private let parentPaneId = UUIDv7.generate()
    private let childPaneId = UUIDv7.generate()
    private let otherPaneId = UUIDv7.generate()

    private func snapshot(childParent: UUID?) -> ActionStateSnapshot {
        let mainPanes = childParent == nil ? [parentPaneId, childPaneId, otherPaneId] : [parentPaneId, otherPaneId]
        return ActionStateSnapshot(
            tabs: [
                TabSnapshot(
                    id: tabId, visiblePaneIds: mainPanes, ownedPaneIds: mainPanes, activePaneId: parentPaneId)
            ],
            activeTabId: tabId,
            isManagementLayerActive: false,
            knownPaneIds: [parentPaneId, childPaneId, otherPaneId],
            drawerParentByPaneId: childParent.map { [childPaneId: $0] } ?? [:]
        )
    }

    private var agent: WorkspaceOwnPaneAssertion { WorkspaceOwnPaneAssertion(boundPaneId: parentPaneId) }

    @Test("closing an own drawer child validates while the child is still in the own pane")
    func ownDrawerChildCloseValidates() {
        let result = WorkspaceCommandValidator.validate(
            .removeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: childPaneId),
            ownPaneAssertion: agent,
            state: snapshot(childParent: parentPaneId)
        )

        #expect(
            (try? result.get().action) == .removeDrawerPane(parentPaneId: parentPaneId, drawerPaneId: childPaneId))
    }

    @Test("a child detached after authorization is outside the own pane")
    func detachedChildIsOutside() {
        let result = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: childPaneId),
            ownPaneAssertion: agent,
            state: snapshot(childParent: nil)
        )

        #expect(result == .failure(.outsideOwnPane(paneId: childPaneId)))
    }

    @Test("another pane, the own pane itself, and actions agents never apply are refused")
    func foreignSelfAndUnsupportedActionsAreRefused() {
        let state = snapshot(childParent: parentPaneId)

        let foreign = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: otherPaneId), ownPaneAssertion: agent, state: state)
        let closeSelf = WorkspaceCommandValidator.validate(
            .closePane(tabId: tabId, paneId: parentPaneId), ownPaneAssertion: agent, state: state)
        let toggle = WorkspaceCommandValidator.validate(
            .toggleDrawer(paneId: parentPaneId), ownPaneAssertion: agent, state: state)

        #expect(foreign == .failure(.outsideOwnPane(paneId: otherPaneId)))
        #expect(closeSelf == .failure(.outsideOwnPane(paneId: parentPaneId)))
        #expect(toggle == .failure(.outsideOwnPane(paneId: parentPaneId)))
    }

    @Test("a drawer-terminal agent's own pane excludes its parent and siblings")
    func drawerTerminalOwnsOnlyItself() {
        let drawerAgent = WorkspaceOwnPaneAssertion(boundPaneId: childPaneId)
        let state = snapshot(childParent: parentPaneId)

        #expect(drawerAgent.admits(childPaneId, state: state))
        #expect(!drawerAgent.admits(parentPaneId, state: state))
        #expect(!drawerAgent.admits(otherPaneId, state: state))
    }
}
