import AgentStudioProgrammaticControl
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AppKit

@MainActor
enum WindowRenderSurfaceCollector {
    private struct Region {
        let kind: IPCWindowRenderSurfaceKind
        let paneId: UUID?
        let identifier: String?
        let original: CGRect
        let visible: CGRect
    }

    static func collect(window: NSWindow, contentView: NSView) -> [IPCWindowRenderSurface] {
        var regions: [Region] = []
        if let split = window.contentViewController as? MainSplitViewController, split.splitViewItems.count == 2 {
            append(split.splitViewItems[0].viewController.view, kind: .sidebar, root: contentView, into: &regions)
            append(split.splitViewItems[1].viewController.view, kind: .tabContent, root: contentView, into: &regions)
        }
        walk(contentView, root: contentView, into: &regions)
        let toolbars = regions.filter { $0.kind == .paneToolbar }
        return regions.map { region in
            var paneId = region.paneId
            if region.kind == .toolbarControl || region.kind == .agentLine {
                let containing = toolbars.filter { $0.visible.contains(region.original) }
                paneId = containing.count == 1 ? containing[0].paneId : nil
            }
            let frame = region.visible
            let top =
                contentView.isFlipped ? frame.minY - contentView.bounds.minY : contentView.bounds.maxY - frame.maxY
            return .init(
                kind: region.kind, paneId: paneId, identifier: region.identifier,
                frame: .init(x: frame.minX - contentView.bounds.minX, y: top, width: frame.width, height: frame.height),
                clipped: region.visible != region.original)
        }
    }

    private static func walk(_ view: NSView, root: NSView, into regions: inout [Region]) {
        if let marker = view as? CaptureRegionMarkerView,
            let paneId = UUID(uuidString: marker.regionID)
        {
            switch marker.regionKind {
            case "paneLeaf": append(view, kind: .paneLeaf, paneId: paneId, root: root, into: &regions)
            case "paneToolbar": append(view, kind: .paneToolbar, paneId: paneId, root: root, into: &regions)
            case "paneCard": append(view, kind: .paneCard, paneId: paneId, root: root, into: &regions)
            default: break
            }
        } else if view is AccessibilityPressBridgeView || view is AccessibilityLabelBridgeView,
            let identifier = view.identifier?.rawValue, identifier.hasPrefix("paneSurfaceToolbar.")
        {
            append(
                view, kind: identifier == "paneSurfaceToolbar.agentLine" ? .agentLine : .toolbarControl,
                identifier: identifier, root: root, into: &regions)
        } else if let row = RepoExplorerCaptureRowIdentity.capture(from: view) {
            append(view, kind: .sidebarRow, paneId: row.paneId, identifier: row.identifier, root: root, into: &regions)
        }
        for child in view.subviews { walk(child, root: root, into: &regions) }
    }

    private static func append(
        _ view: NSView, kind: IPCWindowRenderSurfaceKind, paneId: UUID? = nil, identifier: String? = nil,
        root: NSView, into regions: inout [Region]
    ) {
        guard view.window === root.window, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
            view === root || view.isDescendant(of: root)
        else { return }
        let original = view.convert(view.bounds, to: root)
        guard original.width.isFinite, original.height.isFinite, original.minX.isFinite, original.minY.isFinite,
            original.width > 0, original.height > 0
        else { return }
        var visible = original.intersection(root.bounds)
        var ancestor = view.superview
        while let container = ancestor, container !== root {
            if container.clipsToBounds || container is NSClipView {
                visible = visible.intersection(container.convert(container.bounds, to: root))
            }
            ancestor = container.superview
        }
        guard !visible.isNull, !visible.isEmpty else { return }
        regions.append(.init(kind: kind, paneId: paneId, identifier: identifier, original: original, visible: visible))
    }
}
