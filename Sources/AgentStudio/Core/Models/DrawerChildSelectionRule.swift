import Foundation

enum DrawerChildSelectionRule {
    nonisolated static func firstVisibleChild(
        orderedPaneIds: [UUID],
        minimizedPaneIds: Set<UUID>
    ) -> UUID? {
        orderedPaneIds.first { !minimizedPaneIds.contains($0) }
    }
}
