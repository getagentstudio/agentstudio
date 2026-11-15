/// Snapshot target identity, independent of visibility, surfaces, or activity.
/// Core owns the read value because persistence, Terminal and App consume it.
package struct ScrollbackPaneBinding: Equatable, Hashable, Sendable {
    package let paneID: PaneId
    package let sessionID: ZmxSessionID

    package init(paneID: PaneId, sessionID: ZmxSessionID) {
        self.paneID = paneID
        self.sessionID = sessionID
    }
}
