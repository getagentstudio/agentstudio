/// The app's preceding run decides B1, independently of a pane's last look.
package struct TerminalRestoreLaunchBoot: Equatable, Sendable {
    package let previousBootId: String?
    package let currentBootId: String

    package var isSameBoot: Bool { previousBootId == nil || previousBootId == currentBootId }

    package init(previousBootId: String?, currentBootId: String) {
        self.previousBootId = previousBootId
        self.currentBootId = currentBootId
    }
}
