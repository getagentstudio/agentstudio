import Foundation

extension SurfaceManager {
    /// Keep the selected handling even after this operation removes lookup membership.
    func detachTerminalLocalActions(
        surfaceID: UUID, paneID: UUID?, handling: Ghostty.ActionRouter?
    ) {
        if let paneID {
            handling?.closeLocalActions(surfaceID: surfaceID, paneID: paneID)
        } else {
            handling?.retireLocalActions(for: surfaceID)
        }
    }
}
