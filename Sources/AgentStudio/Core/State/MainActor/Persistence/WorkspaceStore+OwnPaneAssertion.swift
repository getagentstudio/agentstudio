import Foundation

extension WorkspaceStore {
    /// Whether `paneId` is still inside the asserting agent's own pane in the
    /// current pane graph. Owners that apply an effect immediately, without a
    /// workspace action, check this in the same main-actor step as the handoff.
    package func ownPaneAssertionHolds(_ assertion: WorkspaceOwnPaneAssertion, for paneId: UUID) -> Bool {
        assertion.admits(
            paneId,
            paneExists: { paneAtom.pane($0) != nil },
            drawerParentOf: { paneAtom.pane($0)?.parentPaneId }
        )
    }
}
