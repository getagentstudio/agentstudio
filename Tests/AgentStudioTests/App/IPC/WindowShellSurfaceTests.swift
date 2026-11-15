import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer
@testable import AgentStudioTestSupport

@MainActor
@Suite("Native shell and bound sidebar crop surfaces", .serialized)
struct WindowShellSurfaceTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("render locates actual split owners and the currently bound partly clipped sidebar cell")
    func windowSurfacesLocateShellAndCurrentSidebarBinding() async throws {
        let filesystem = try WindowRenderTestFixture()
        defer { filesystem.tearDown() }
        let cell = RepoExplorerTableRowCell(octiconLoader: makeTestOcticonLoader())
        _ = cell.bind(row: row(groupID: "A"), visibleGeneration: 1)
        let outcome = await withUnloadedMainSplitViewControllerHarness(
            startsObserving: false,
            sidebarRootViewBuilder: { _, _ in AnyView(CaptureSidebarCellHost(cell: cell)) },
            body: { harness -> Result<Void, any Error> in
                harness.window.isReleasedWhenClosed = false
                defer {
                    harness.window.contentViewController = nil
                    harness.window.orderOut(nil)
                    harness.window.close()
                }
                do {
                    harness.window.contentViewController = harness.controller
                    harness.controller.loadViewIfNeeded()
                    harness.window.setContentSize(NSSize(width: 1000, height: 700))
                    harness.controller.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
                    harness.controller.splitView.frame = harness.controller.view.bounds
                    harness.controller.view.layoutSubtreeIfNeeded()
                    harness.controller.viewDidLayout()
                    let first = try await WindowContentRenderer.render(
                        window: harness.window, workspaceWindowId: filesystem.windowId,
                        rendersDirectory: filesystem.rendersDirectory)
                    let sidebar = try #require(first.surfaces.first { $0.kind == .sidebar })
                    let content = try #require(first.surfaces.first { $0.kind == .tabContent })
                    #expect(sidebar.frame.x == 0 && sidebar.frame.y == 0)
                    #expect(sidebar.frame.width >= 250 && sidebar.frame.height > 0)
                    // ShellSplitView explicitly has a zero-width divider.
                    #expect(content.frame.x == sidebar.frame.width)
                    #expect(content.frame.y == 0)
                    #expect(content.frame.height == sidebar.frame.height)
                    let capturedRow = try #require(first.surfaces.first { $0.kind == .sidebarRow })
                    #expect(capturedRow.identifier == "5:group1:A" && capturedRow.paneId == nil)
                    #expect(capturedRow.clipped && capturedRow.frame.height == 40 && capturedRow.frame.width == 240)
                    _ = cell.bind(row: row(groupID: "B"), visibleGeneration: 2)
                    let rebound = WindowRenderSurfaceCollector.collect(
                        window: harness.window, contentView: harness.controller.view)
                    #expect(rebound.filter { $0.kind == .sidebarRow }.map(\.identifier) == ["5:group1:B"])
                    cell.clearBindingForReuse()
                    let cleared = WindowRenderSurfaceCollector.collect(
                        window: harness.window, contentView: harness.controller.view)
                    #expect(!cleared.contains { $0.kind == .sidebarRow })
                    harness.controller.splitViewItems[0].viewController.view.isHidden = true
                    let hidden = WindowRenderSurfaceCollector.collect(
                        window: harness.window, contentView: harness.controller.view)
                    #expect(!hidden.contains { $0.kind == .sidebar })
                    return .success(())
                } catch { return .failure(error) }
            })
        try outcome.get()
    }

    private func row(groupID: String) -> RepoExplorerMaterializedRow {
        let presentation = RepoExplorerMaterializedRowPresentation.groupHeader(
            .init(
                groupID: groupID, icon: .repo, title: "Same visible label", organizationName: nil, colorHex: nil,
                isExpanded: true, repoIDs: [], semanticRepoPath: nil, paneDestinations: []))
        return .init(
            id: .group(groupID: groupID), contentRevision: .init(presentation: presentation),
            layout: .make(for: presentation), representedRepoID: nil, representedWorktreeID: nil)
    }
}

private struct CaptureSidebarCellHost: NSViewRepresentable {
    let cell: RepoExplorerTableRowCell

    func makeNSView(context _: Context) -> NSView {
        let root = NSView()
        let clip = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        clip.clipsToBounds = true
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        clip.addSubview(cell)
        root.addSubview(clip)
        return root
    }

    func updateNSView(_: NSView, context _: Context) {}
}
