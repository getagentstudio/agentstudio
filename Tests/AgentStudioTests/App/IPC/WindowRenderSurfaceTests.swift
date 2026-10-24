import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite("Window render crop surfaces", .serialized)
struct WindowRenderSurfaceTests {
    @Test("native coordinates map into actual PNG top-left points", arguments: [false, true])
    func windowSurfacesUseImageCoordinates(flipped: Bool) async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let root = SurfaceCoordinateRoot(flipped: flipped)
        fixture.window.contentView = root
        fixture.window.setContentSize(NSSize(width: 96, height: 64))
        root.bounds.origin = CGPoint(x: 10, y: 20)
        let paneId = UUIDv7.generate()
        let marker = CaptureRegionMarkerView(kind: "paneLeaf", id: paneId.uuidString)
        marker.frame = CGRect(x: 30, y: 28, width: 20, height: 12)
        root.addSubview(marker)

        let result = try await WindowContentRenderer.render(
            window: fixture.window, workspaceWindowId: fixture.windowId, rendersDirectory: fixture.rendersDirectory)

        let surface = try #require(result.surfaces.first)
        #expect(result.surfaces.count == 1)
        #expect(surface.kind == .paneLeaf && surface.paneId == paneId && !surface.clipped)
        #expect(surface.frame == .init(x: 20, y: flipped ? 8 : 44, width: 20, height: 12))
        let bitmap = try decodedWindowRenderBitmap(path: result.image.path)
        let pixel = try #require(
            bitmap.colorAt(x: Int(25 * result.image.scale), y: Int((flipped ? 12 : 48) * result.image.scale)))
        #expect(pixel.redComponent > 0.98 && pixel.greenComponent < 0.02 && pixel.blueComponent < 0.02)
    }

    @Test("hidden and fully clipped regions disappear; partial intersections retain clipping")
    func windowSurfacesRespectVisibilityAndClipping() throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let root = try #require(fixture.window.contentView)
        let parent = NSView(frame: CGRect(x: 10, y: 10, width: 30, height: 20))
        parent.clipsToBounds = true
        root.addSubview(parent)
        let partial = marker(frame: CGRect(x: 20, y: 0, width: 20, height: 10), in: parent)
        let outside = marker(frame: CGRect(x: 40, y: 0, width: 10, height: 10), in: parent)
        let hiddenParent = NSView(frame: root.bounds)
        hiddenParent.isHidden = true
        root.addSubview(hiddenParent)
        let hidden = marker(frame: root.bounds, in: hiddenParent)
        let detached = CaptureRegionMarkerView(kind: "paneCard", id: UUIDv7.generate().uuidString)
        detached.frame = root.bounds
        let overflowingParent = NSView(frame: CGRect(x: 60, y: 10, width: 5, height: 5))
        overflowingParent.clipsToBounds = false
        root.addSubview(overflowingParent)
        let overflow = marker(frame: CGRect(x: 0, y: 0, width: 15, height: 10), in: overflowingParent)

        let surfaces = WindowRenderSurfaceCollector.collect(window: fixture.window, contentView: root)

        #expect(surfaces.count == 2)
        let clipped = try #require(surfaces.first { $0.paneId?.uuidString == partial.regionID })
        #expect(clipped.clipped)
        #expect(clipped.frame == .init(x: 30, y: 44, width: 10, height: 10))
        #expect(surfaces.first { $0.paneId?.uuidString == overflow.regionID }?.frame.width == 15)
        for absent in [outside, hidden, detached] {
            #expect(!surfaces.contains { $0.paneId?.uuidString == absent.regionID })
        }
    }

    @Test("SwiftUI hidden and clipped compositions apply to their native markers")
    func windowSurfacesRespectSwiftUIVisibility() throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let partialId = UUIDv7.generate()
        let hiddenId = UUIDv7.generate()
        let host = NSHostingView(
            rootView: HStack(spacing: 0) {
                Color.red.frame(width: 80, height: 50)
                    .background { CaptureRegionMarker(kind: "paneLeaf", id: partialId.uuidString) }
                    .frame(width: 30, height: 20, alignment: .topLeading).clipped()
                Color.green.frame(width: 30, height: 20)
                    .background { CaptureRegionMarker(kind: "paneLeaf", id: hiddenId.uuidString) }
                    .hidden()
            }.frame(width: 96, height: 64, alignment: .topLeading))
        fixture.window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let surfaces = WindowRenderSurfaceCollector.collect(window: fixture.window, contentView: host)

        #expect(surfaces.count == 1)
        let visible = try #require(surfaces.first)
        #expect(visible.paneId == partialId && visible.clipped)
        #expect(visible.frame == .init(x: 0, y: 0, width: 30, height: 20))
    }

    @Test("repeated controls require exactly one visible containing toolbar")
    func windowToolbarAttributionRequiresUniqueVisibleMarker() throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let root = try #require(fixture.window.contentView)
        let first = marker(frame: CGRect(x: 0, y: 0, width: 40, height: 20), in: root, kind: "paneToolbar")
        let second = marker(frame: CGRect(x: 0, y: 0, width: 40, height: 20), in: root, kind: "paneToolbar")
        addControl(frame: CGRect(x: 5, y: 5, width: 10, height: 5), in: root)
        addControl(frame: CGRect(x: 60, y: 5, width: 10, height: 5), in: root)
        let line = AccessibilityLabelBridgeView()
        line.identifier = .init("paneSurfaceToolbar.agentLine")
        line.frame = CGRect(x: 20, y: 5, width: 10, height: 5)
        root.addSubview(line)

        let ambiguous = WindowRenderSurfaceCollector.collect(window: fixture.window, contentView: root)
        #expect(ambiguous.filter { $0.kind == .toolbarControl }.count == 2)
        #expect(
            ambiguous.filter { $0.kind == .toolbarControl || $0.kind == .agentLine }.allSatisfy { $0.paneId == nil })
        second.isHidden = true
        let unique = WindowRenderSurfaceCollector.collect(window: fixture.window, contentView: root)
        #expect(unique.first { $0.kind == .toolbarControl && $0.frame.x == 5 }?.paneId?.uuidString == first.regionID)
        #expect(unique.first { $0.kind == .agentLine }?.paneId?.uuidString == first.regionID)
        #expect(unique.first { $0.kind == .toolbarControl && $0.frame.x == 60 }?.paneId == nil)
        first.frame.origin.x = 200
        let clipped = WindowRenderSurfaceCollector.collect(window: fixture.window, contentView: root)
        #expect(clipped.allSatisfy { $0.paneId == nil })
    }

    private func marker(frame: CGRect, in parent: NSView, kind: String = "paneLeaf") -> CaptureRegionMarkerView {
        let marker = CaptureRegionMarkerView(kind: kind, id: UUIDv7.generate().uuidString)
        marker.frame = frame
        parent.addSubview(marker)
        return marker
    }

    private func addControl(frame: CGRect, in parent: NSView) {
        let control = AccessibilityPressBridgeView()
        control.identifier = .init("paneSurfaceToolbar.copyPath")
        control.frame = frame
        parent.addSubview(control)
    }
}

@MainActor
private final class SurfaceCoordinateRoot: NSView {
    let usesFlippedCoordinates: Bool
    override var isFlipped: Bool { usesFlippedCoordinates }
    init(flipped: Bool) {
        usesFlippedCoordinates = flipped
        super.init(frame: CGRect(x: 0, y: 0, width: 96, height: 64))
    }
    required init?(coder _: NSCoder) { nil }
    override func draw(_: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.red.setFill()
        CGRect(x: 30, y: 28, width: 20, height: 12).fill()
    }
}
