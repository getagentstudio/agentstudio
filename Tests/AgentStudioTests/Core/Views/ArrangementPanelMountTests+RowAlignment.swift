import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

extension ArrangementPanelMountTests {
    enum AlignmentRow: Sendable, CaseIterable { case agent, shell, bridge, hidden, wrapped }

    @Test(
        "Status, first title line, Hidden and actions share one center; kind tile shares title top",
        arguments: AlignmentRow.allCases)
    func rowControlsShareTitleFirstLine(rowKind: AlignmentRow) throws {
        try withTestCoreAtoms { _ in
            let rows = arrangementTableFrameRows(longText: false)
            let row: PaneVisibilityInfo
            switch rowKind {
            case .agent: row = rows[0]
            case .shell: row = rows[1]
            case .bridge: row = rows[3]
            case .hidden: row = rows[4]
            case .wrapped:
                row = .init(
                    id: UUIDv7.generate(), title: "First title line\nSecond title line", isMinimized: true,
                    supportsZoom: true, paneNote: "Details stay below the title", cwdPath: "~/code/projects/scratch")
            }
            let subject = ArrangementPaneGroupRow(
                pane: row, octiconLoader: makeCoreTestOcticonLoader(),
                commandActionResolver: makePresentedCommandAction, isHighlighted: false)
            let host = NSHostingView(
                rootView: subject.frame(width: 496).padding(12)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
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
                    rootView: Text("First title line").font(.system(size: 13, weight: .semibold)).fixedSize())
                let firstLineHeight = firstLine.fittingSize.height
                let titleTop = host.isFlipped ? title.minY : title.maxY
                let center = titleTop + (host.isFlipped ? 1 : -1) * firstLineHeight / 2
                let tolerance = 1 / scale
                var measured: [String: CGRect] = ["title": title]
                for suffix in ["status-glyph", "zoom", "visibility"] + (row.isMinimized ? ["hidden"] : []) {
                    let rect = try bounds(suffix)
                    measured[suffix] = rect
                    #expect(
                        abs(rect.midY - center) <= tolerance,
                        "\(rowKind): \(suffix) must center on the first title line")
                }
                let glyph = try bounds("kind-glyph")
                measured["kind-glyph"] = glyph
                let glyphTop = host.isFlipped ? glyph.minY : glyph.maxY
                #expect(abs(glyphTop - titleTop) <= tolerance, "\(rowKind): kind tile top must equal title top")
                for suffix in ["agent", "cwd", "detail"] {
                    if let view = findArrangementPanelView(in: host, identifier: prefix + suffix) {
                        #expect(abs(view.convert(view.bounds, to: host).minX - title.minX) <= tolerance)
                    }
                }
                print(
                    "ARRANGEMENT_TITLE_ALIGNMENT", rowKind, "scale", scale, "title", title, "firstLineHeight",
                    firstLineHeight, "glyph", glyph)
                try recordTitleAlignment(rowKind, host: host, scale: scale, titleCenter: center, measured: measured)
                try captureArrangementPanel(host, named: "d106-alignment-\(rowKind)-520")
            }
        }
    }

    @Test("Arrangements status glyph retains the sidebar's icon and tone", arguments: [0, 1, 2, 3])
    func statusGlyphMatchesSidebar(statusIndex: Int) throws {
        let statuses: [AgentSessionStatus] = [
            .working(.active), .needsYou(.question), .failed(.init(category: "Build")), .idle(.ready),
        ]
        let kinds: [StatusLine.Kind] = [.working, .needsYou, .failed, .idle]
        let tones: [PaneContextChipTone] = [.accent, .warning, .danger, .neutral]
        let spec = LocalActionSpec.paneSessionStatus(statuses[statusIndex]).actionSpec
        let pane = PaneVisibilityInfo(
            id: UUIDv7.generate(), title: "Status", isMinimized: false, cwdPath: "~/code/projects/scratch",
            agentStatus: .agent(
                .init(kind: kinds[statusIndex], label: spec.label, detail: spec.helpText, icon: spec.icon)))
        let loader = makeCoreTestOcticonLoader()
        let subject = ArrangementPaneGroupRow(
            pane: pane, octiconLoader: loader, commandActionResolver: makePresentedCommandAction, isHighlighted: false)
        let actual = NSHostingView(
            rootView: subject.statusGlyph.frame(width: 40, height: 40).background(Color.black).environment(
                \.colorScheme, .dark
            ).transaction { $0.disablesAnimations = true })
        let reference = NSHostingView(
            rootView: LiteralMainSidebarStatusGlyph(
                icon: spec.icon, color: tones[statusIndex].foregroundColor, pulse: statusIndex == 0,
                loader: loader
            )
            .frame(width: 11, height: 11).frame(width: 40, height: 40)
            .background(Color.black).environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true })
        actual.frame.size = CGSize(width: 40, height: 40)
        reference.frame.size = actual.frame.size
        try withAlignmentWindow(actual) { _ in
            try withAlignmentWindow(reference) { _ in
                let actualPixels = try alignmentPixels(actual)
                let expectedPixels = try alignmentPixels(reference)
                #expect(
                    actualPixels == expectedPixels,
                    "The old independent Circle must not stand in for the shared status glyph")
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
            "row": String(describing: row), "scale": scale, "host_flipped": host.isFlipped,
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
        try #require(window.backingScaleFactor == 2, "Native geometry proof needs the actual 2x screen")
        try operation(window.backingScaleFactor)
    }

    private func alignmentPixels(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}

// Literal pre-extraction sidebar renderer; animations are disabled by the surrounding native proof transaction.
private struct LiteralMainSidebarStatusGlyph: View {
    let icon: CommandIcon
    let color: Color
    let pulse: Bool
    let loader: OcticonLoader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        icon.swiftUIImage(loader: loader, size: 10)
            .opacity(!reduceMotion && pulse && dimmed ? 0.6 : 1)
            .animation(
                !reduceMotion && pulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
                value: dimmed
            )
            .onChange(of: !reduceMotion && pulse, initial: true) { _, active in dimmed = active }
            .foregroundStyle(color)
    }
}
