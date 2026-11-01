import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

extension ArrangementPanelMountTests {
    enum D109FrameScene: String, CaseIterable, Sendable {
        case chosen = "01-a3-composition-760"
        case compact = "02-compact-520"
        case note = "03-note-fallback-760"
        case hiddenAgent = "04-hidden-agent-760"
        case working = "05-working-760"
        case failed = "06-failed-760"
        case idle = "07-idle-760"
        case noDetail = "08-no-third-line-760"
    }

    @Test("D109 prepared rows fit the real popover width in each visual state", arguments: D109FrameScene.allCases)
    func d109ReferenceFrames(scene: D109FrameScene) async throws {
        let status: AgentSessionStatus?
        switch scene {
        case .compact: status = nil
        case .working: status = .working(.active)
        case .failed: status = .failed(.init(category: "Build"))
        case .idle: status = .idle(.ready)
        default: status = .needsYou(.question)
        }
        let detailMode = scene == .note ? 1 : (scene == .compact || scene == .noDetail ? 2 : 0)
        let source = try D109ArrangementScene(
            detailMode: detailMode, hasMessages: scene != .compact, hiddenAgent: scene == .hiddenAgent,
            status: status, longTitle: scene != .compact)
        let projection = try await ArrangementTableProjector.project(source.input)
        try withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups
            )
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(x: 0, y: 0, width: projection.tableMetrics.panelWidth, height: host.fittingSize.height)
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            #expect(host.bounds.width == (scene == .compact ? 520 : 760))
            try #require(host.bounds.height > 0)
            #expect(projection.groups.map(\.title) == ["context-preview", "Other"])
            for pane in projection.panes {
                let prefix = "arrangement-panel-pane-\(pane.id)-"
                let title = try #require(findArrangementPanelView(in: host, identifier: prefix + "title"))
                let visibility = try #require(findArrangementPanelView(in: host, identifier: prefix + "visibility"))
                let zoom = try #require(findArrangementPanelView(in: host, identifier: prefix + "zoom"))
                #expect(title.bounds.height <= 20)
                for view in [title, visibility, zoom] {
                    let rect = view.convert(view.bounds, to: host)
                    #expect(host.bounds.contains(rect), "Native title and controls stay within the real popover")
                }
                #expect(findArrangementPanelView(in: host, identifier: prefix + "hidden") == nil)
                #expect(findArrangementPanelView(in: host, identifier: prefix + "cwd") == nil)
            }
            try captureD109Frame(host, name: scene.rawValue, panes: projection.panes)
        }
    }

    private func captureD109Frame(_ host: NSView, name: String, panes: [PaneVisibilityInfo]) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_ARRANGEMENT_FRAME_DIRECTORY"] else {
            return
        }
        let width = Int(host.bounds.width * 2)
        let height = Int(host.bounds.height * 2)
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let data = try pixels.withUnsafeMutableBytes { bytes -> Data in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let exported = try #require(context.makeImage())
            return try #require(NSBitmapImageRep(cgImage: exported).representation(using: .png, properties: [:]))
        }
        let opaque = stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }
        #expect(opaque, "Every native frame pixel must be opaque")
        #expect(image.width == width && image.height == height)
        let root = URL(filePath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appending(path: name + ".png"))
        var glyphFrames: [String: [CGFloat]] = [:]
        for pane in panes where !pane.isMinimized {
            let kind: String
            switch pane.paneIcon {
            case .octicon(.gitWorktree): kind = "git-worktree"
            case .system(.terminal): kind = "terminal"
            case .system(.globe): kind = "globe"
            default: continue
            }
            guard glyphFrames[kind] == nil else { continue }
            let marker = try #require(
                findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(pane.id)-kind-glyph"))
            let rect = marker.convert(marker.bounds, to: host)
            let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            glyphFrames[kind] = [rect.minX, top, rect.width, rect.height]
        }
        let metadata: [String: Any] = [
            "logical_width": host.bounds.width, "logical_height": host.bounds.height,
            "pixels_wide": width, "pixels_high": height, "scale": 2, "opaque": opaque, "appearance": "darkAqua",
            "kind_frames_points": glyphFrames,
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: name + ".json"))
        Attachment.record(Array(data), named: name + ".png")
    }
}
