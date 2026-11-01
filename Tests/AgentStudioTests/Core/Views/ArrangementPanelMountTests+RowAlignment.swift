import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

extension ArrangementPanelMountTests {
    enum AlignmentRow: Sendable, CaseIterable { case agent, shell, bridge, web, hidden, wrapped }

    @Test(
        "Small status, kind glyph and controls share the single title line center",
        arguments: AlignmentRow.allCases)
    func rowControlsShareTitleFirstLine(rowKind: AlignmentRow) throws {
        try withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: false)
            let row: PaneVisibilityInfo
            switch rowKind {
            case .agent: row = rows[0]
            case .shell: row = rows[1]
            case .bridge: row = rows[3]
            case .web:
                row = .init(
                    id: UUIDv7.generate(), title: "New Tab", isMinimized: false, paneIcon: .system(.globe))
            case .hidden: row = rows[4]
            case .wrapped:
                row = .init(
                    id: UUIDv7.generate(), title: "First title line\nSecond title line", isMinimized: true,
                    supportsZoom: true, detailLine: .note("Details stay below the title"))
            }
            let subject = ArrangementPaneGroupRow(
                pane: row, octiconLoader: makeCoreTestOcticonLoader(),
                commandActionResolver: makePresentedCommandAction, isHighlighted: false)
            let host = NSHostingView(
                rootView: subject.frame(width: 496).padding(12)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                    .environment(\.displayScale, 2))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            try withAlignmentWindow(host) { scale in
                let prefix = "arrangement-panel-pane-\(row.id.uuidString)-"
                @MainActor func bounds(_ suffix: String) throws -> CGRect {
                    let found = findArrangementPanelView(in: host, identifier: prefix + suffix)
                    let view = try #require(found)
                    let bounds = view.convert(view.bounds, to: host)
                    try #require(bounds.width > 0 && bounds.height > 0)
                    return bounds
                }
                let title = try bounds("title")
                let firstLine = NSHostingView(
                    rootView: Text("First title line").font(.system(size: 13, weight: .regular)).fixedSize())
                let firstLineHeight = firstLine.fittingSize.height
                let titleTop = host.isFlipped ? title.minY : title.maxY
                let center = titleTop + (host.isFlipped ? 1 : -1) * firstLineHeight / 2
                let tolerance = 1 / scale
                var measured: [String: CGRect] = ["title": title]
                for suffix in ["status-glyph", "kind-glyph", "zoom", "visibility"] {
                    let rect = try bounds(suffix)
                    measured[suffix] = rect
                    #expect(
                        abs(rect.midY - center) <= tolerance,
                        "\(rowKind): \(suffix) must center on the first title line")
                }
                let glyph = try bounds("kind-glyph")
                measured["kind-glyph"] = glyph
                #expect(glyph.width == 20 && glyph.height == 20)
                #expect(title.height <= firstLineHeight + tolerance)
                for suffix in ["agent", "detail"] {
                    if let view = findArrangementPanelView(in: host, identifier: prefix + suffix) {
                        #expect(abs(view.convert(view.bounds, to: host).minX - title.minX) <= tolerance)
                    }
                }
                print(
                    "ARRANGEMENT_TITLE_ALIGNMENT", rowKind, "targetRasterScale", scale,
                    "windowBackingScale", host.window?.backingScaleFactor ?? 0, "title", title, "firstLineHeight",
                    firstLineHeight, "glyph", glyph)
                try recordTitleAlignment(rowKind, host: host, scale: scale, titleCenter: center, measured: measured)
                try captureArrangementPanel(host, named: "d106-alignment-\(rowKind)-520")
            }
        }
    }

    private func recordTitleAlignment(
        _ row: AlignmentRow, host: NSView, scale: CGFloat, titleCenter: CGFloat, measured: [String: CGRect]
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_ARRANGEMENT_FRAME_DIRECTORY"] else {
            return
        }
        let record: [String: Any] = [
            "row": String(describing: row), "target_raster_scale": scale,
            "window_backing_scale": host.window?.backingScaleFactor ?? 0, "host_flipped": host.isFlipped,
            "host_size": [host.bounds.width, host.bounds.height], "title_first_line_center": titleCenter,
            "frames": measured.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
            "center_errors_in_pixels": measured.filter { $0.key != "title" && $0.key != "kind-glyph" }
                .mapValues { abs($0.midY - titleCenter) * scale },
        ]
        let root = URL(filePath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "d106-alignment-\(row).json"))
    }

    private func withAlignmentWindow(_ host: NSView, operation: (CGFloat) throws -> Void) throws {
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // Geometry is in points; retain the one-pixel tolerance of the explicit 2x raster below.
        try operation(2)
    }

}
