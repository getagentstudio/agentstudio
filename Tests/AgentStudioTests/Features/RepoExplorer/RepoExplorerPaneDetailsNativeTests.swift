import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Pane row details native restoration", .serialized)
struct RepoExplorerPaneDetailsNativeTests {
    @Test("A real expanded pane row paints the shared Git chips it receives")
    func actualProjectedPaneRendersGitDetails() async throws {
        var row = try restoredDetailsRow()
        row.displayVariant = .expanded
        let loader = makeRepoExplorerTestOcticonLoader()
        let actual = try bitmap(
            RepoExplorerPaneRow(row: row, octiconLoader: loader, onFocus: {}).frame(width: 900))
        let expected = try bitmap(
            SidebarGitStatusChips(
                branchStatus: try #require(row.branchStatus), octiconLoader: loader, usesPanesLoadingChip: true
            ).fixedSize())
        let appears = await Self.containsPaint(actual: actual, expected: expected)
        #expect(appears, "Prepared PR, changes and sync must paint through the real pane row")
    }

    @Test(
        "Each restored detail paints in the real compact and expanded pane row",
        arguments: [false, true], PaneRestoredNativeElement.allCases)
    func actualProjectedPaneRendersEachDetail(expanded: Bool, element: PaneRestoredNativeElement) async throws {
        var row = try restoredDetailsRow()
        row.displayVariant = expanded ? .expanded : .compact
        let loader = makeRepoExplorerTestOcticonLoader()
        let controls: RepoExplorerPaneContextControlFactory = { _, presentation in
            guard case .kind(let chip) = presentation else { return nil }
            return AnyView(
                PaneMessageKindChip(
                    model: chip, control: PaneMessageKindChipProjection.control(chip),
                    octiconLoader: loader, onOpen: {}))
        }
        let actual = try bitmap(
            RepoExplorerPaneRow(
                row: row, octiconLoader: loader, paneContextControl: controls, onFocus: {}
            ).frame(width: 900))
        let variant = try #require(expanded ? row.variants?.expanded : row.variants?.compact)
        let expected = try bitmap(expectedDetail(element, row: row, variant: variant, loader: loader).fixedSize())

        let appears = await Self.containsPaint(actual: actual, expected: expected)
        let shouldAppear = expanded || (element != .changes && element != .sync)
        #expect(
            appears == shouldAppear,
            "Native \(expanded ? "expanded" : "compact") row: \(element) paint must be \(shouldAppear ? "present" : "absent")"
        )
    }

    private func expectedDetail(
        _ element: PaneRestoredNativeElement, row: RepoExplorerProjectedPaneRow,
        variant: RepoExplorerPaneRowVariant, loader: OcticonLoader
    ) throws -> AnyView {
        switch element {
        case .drawer:
            let spec = LocalActionSpec.sidebarPaneDrawer.actionSpec
            let icon: SidebarChip.Icon
            switch spec.icon {
            case .system(let symbol): icon = .system(symbol.rawValue)
            case .octicon(let symbol): icon = .octicon(symbol.rawValue)
            }
            return AnyView(SidebarChip(icon: icon, octiconLoader: loader, text: spec.label, style: .neutral))
        case .active:
            return AnyView(
                SidebarChip(
                    icon: .system(.playCircleFill), octiconLoader: loader, text: nil, style: .accent(.accentColor)))
        case .branch:
            return AnyView(
                SidebarMetadataLine(
                    icon: metadataIcon(.sidebarPaneBranch, loader: loader), text: try #require(row.branchContextText)))
        case .note:
            return AnyView(
                SidebarMetadataLine(
                    icon: metadataIcon(.sidebarPaneNote, loader: loader), text: try #require(row.secondaryLine?.text)))
        case .pullRequest:
            return AnyView(SidebarPullRequestChipSpec.chip(count: 2, octiconLoader: loader))
        case .changes:
            return AnyView(SidebarDiffChip(octiconLoader: loader, detail: .lineCounts(added: 19, deleted: 7)))
        case .sync:
            return AnyView(
                SidebarStatusSyncChip(octiconLoader: loader, aheadText: "5", behindText: "3", hasSyncSignal: true))
        case .message:
            let chip = KindChipModel(kind: .needsYou, count: 1)
            return AnyView(
                PaneMessageKindChip(
                    model: chip, control: PaneMessageKindChipProjection.control(chip), octiconLoader: loader, onOpen: {}
                ))
        case .clock:
            return AnyView(
                SidebarChip(
                    icon: .system(.clock), octiconLoader: loader,
                    text: variant.activityChip?.text ?? variant.recencyText,
                    style: .accent(AppStyles.Shell.Sidebar.chipInfoColor)))
        }
    }

    private func metadataIcon(_ action: LocalActionSpec, loader: OcticonLoader) -> SidebarMetadataLine.IconSource {
        switch action.actionSpec.icon {
        case .system(let symbol): .systemName(symbol.rawValue)
        case .octicon(let symbol): .octicon(name: symbol.rawValue, loader: loader)
        }
    }

    private func bitmap<V: View>(_ view: V) throws -> PaneDetailsPixelBuffer {
        let host = NSHostingView(rootView: view.padding(8).background(Color.black).environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 950, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = host
        window.orderFront(nil)
        host.frame = .init(x: 0, y: 0, width: 950, height: 250)
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let rgba = try #require(rep.bitmapData)
        try #require(rep.bitsPerSample == 8 && rep.samplesPerPixel >= 3)
        return .init(
            width: rep.pixelsWide, height: rep.pixelsHigh, stride: rep.bytesPerRow,
            samples: rep.samplesPerPixel,
            bytes: Array(UnsafeBufferPointer(start: rgba, count: rep.bytesPerRow * rep.pixelsHigh)))
    }

    @concurrent nonisolated private static func containsPaint(
        actual: PaneDetailsPixelBuffer, expected: PaneDetailsPixelBuffer
    ) async -> Bool {
        // Ignore only the shared empty black backdrop. Match every painted pixel, including each
        // glyph and count; an omitted element cannot match its independent native template.
        var painted: [(x: Int, y: Int, rgb: [UInt8])] = []
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                let rgb = expected.rgb(x, y)
                if rgb.max() ?? 0 > 8 { painted.append((x, y, rgb)) }
            }
        }
        guard let minX = painted.map(\.x).min(), let minY = painted.map(\.y).min(),
            let maxX = painted.map(\.x).max(), let maxY = painted.map(\.y).max(),
            actual.width > maxX - minX, actual.height > maxY - minY
        else { return false }
        for top in 0..<(actual.height - (maxY - minY)) {
            for left in 0..<(actual.width - (maxX - minX)) {
                if painted.allSatisfy({ pixel in
                    actual.rgb(left + pixel.x - minX, top + pixel.y - minY) == pixel.rgb
                }) {
                    return true
                }
            }
        }
        return false
    }
}

private struct PaneDetailsPixelBuffer: Sendable {
    let width: Int
    let height: Int
    let stride: Int
    let samples: Int
    let bytes: [UInt8]

    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
        let offset = y * stride + x * samples
        return Array(bytes[offset..<(offset + 3)])
    }
}

enum PaneRestoredNativeElement: String, CaseIterable, Sendable {
    case drawer, active, branch, note, pullRequest, changes, sync, message, clock
}
