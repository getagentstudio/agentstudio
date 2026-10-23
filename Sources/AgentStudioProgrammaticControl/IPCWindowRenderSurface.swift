import Foundation

package enum IPCWindowRenderSurfaceKind: String, Codable, CaseIterable, Sendable {
    case sidebar, tabContent, paneLeaf, paneToolbar, paneCard, toolbarControl, agentLine, sidebarRow
}

package struct IPCWindowSurfaceFrame: Codable, Equatable, Sendable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A visible crop locator in the PNG's top-left point space, not an ink measurement.
package struct IPCWindowRenderSurface: Codable, Equatable, Sendable {
    package let kind: IPCWindowRenderSurfaceKind
    package let paneId: UUID?
    package let identifier: String?
    package let frame: IPCWindowSurfaceFrame
    package let clipped: Bool

    package init(
        kind: IPCWindowRenderSurfaceKind, paneId: UUID? = nil, identifier: String? = nil,
        frame: IPCWindowSurfaceFrame, clipped: Bool
    ) {
        self.kind = kind
        self.paneId = paneId
        self.identifier = identifier
        self.frame = frame
        self.clipped = clipped
    }
}
