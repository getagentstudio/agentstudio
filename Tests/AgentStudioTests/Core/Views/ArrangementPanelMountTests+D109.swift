import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

extension ArrangementPanelMountTests {
    @Test("D109 repository grouping merges its worktrees and puts iconless Other last")
    func repositoryComposition() async throws {
        let scene = try D109ArrangementScene()
        let projection = try await ArrangementTableProjector.project(scene.input)
        #expect(projection.groups.map(\.title) == ["context-preview", "Other"])
        #expect(projection.groups.first?.panes.map(\.id) == Array(scene.ids.prefix(4)))
        try withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups)
            let key = "arrangement-panel-group-repository-\(scene.repoId.uuidString)"
            let header = try #require(findArrangementPanelView(in: host, identifier: key))
            #expect(header.accessibilityLabel() == "context-preview")
            #expect(findArrangementPanelView(in: host, identifier: key + "-icon") != nil)
            #expect(findArrangementPanelView(in: host, identifier: "arrangement-panel-group-other-icon") == nil)
        }
    }

    @Test("D109 native kind glyphs are small and linked terminals use git-worktree")
    func compactKindComposition() async throws {
        let scene = try D109ArrangementScene()
        let projection = try await ArrangementTableProjector.project(scene.input)
        let icons: [CommandIcon] = [
            .octicon(.gitWorktree), .octicon(.gitWorktree), .octicon(.gitWorktree), .octicon(.gitWorktree),
            .system(.terminal), .system(.globe),
        ]
        try withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups)
            for (row, expected) in zip(projection.panes, icons) {
                #expect(row.paneIcon == expected)
                let icon = try #require(
                    findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(row.id)-kind-glyph"))
                #expect(icon.bounds.size == CGSize(width: 20, height: 20))
            }
            let title = try #require(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(scene.ids[0])-title"))
            #expect(title.bounds.height <= 20, "The long title stays on line one")
            let branch = try #require(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(scene.ids[0])-branch"))
            #expect(branch.accessibilityLabel() == "main")
        }
    }

    @Test("D109 Agent Line precedes note, note is the fallback, then there is no third line", arguments: [0, 1, 2])
    func detailLineComposition(mode: Int) async throws {
        let scene = try D109ArrangementScene(detailMode: mode)
        let projection = try await ArrangementTableProjector.project(scene.input)
        withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups)
            let detail = findArrangementPanelView(
                in: host, identifier: "arrangement-panel-pane-\(scene.ids[0])-detail")
            switch mode {
            case 0:
                #expect(
                    detail?.accessibilityLabel() == "The UI-fix preview is ready for the owner to explore. [5 min ago]")
            case 1: #expect(detail?.accessibilityLabel() == "Fallback pane note")
            default: #expect(detail == nil)
            }
            for id in scene.ids {
                #expect(findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(id)-cwd") == nil)
            }
        }
    }

    @Test("D109 native agent line two reuses message chips only for nonzero kinds", arguments: [false, true])
    func messageChipComposition(hasMessages: Bool) async throws {
        let scene = try D109ArrangementScene(hasMessages: hasMessages)
        let projection = try await ArrangementTableProjector.project(scene.input)
        try withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups)
            let agent = try #require(
                findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(scene.ids[0])-agent"))
            #expect(agent.accessibilityLabel() == "Claude")
            #expect(agent.accessibilityValue() as? String == "Needs you")
            for (kind, label) in [
                ("failure", "Failed, 1"), ("needsYou", "Needs you, 1"), ("done", "Done, 1"), ("info", "Info, 4"),
            ] {
                let chip = findArrangementPanelView(
                    in: host, identifier: "arrangement-panel-pane-\(scene.ids[0])-messages-\(kind)")
                #expect((chip != nil) == hasMessages)
                if hasMessages { #expect(chip?.accessibilityLabel() == label) }
            }
            for id in scene.ids.dropFirst() {
                #expect(findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(id)-agent") == nil)
            }
        }
    }

    @Test("D109 active status is filled and idle or missing status is an empty circle", arguments: 0..<5)
    func statusMarkComposition(index: Int) async throws {
        let statuses: [AgentSessionStatus?] = [
            .needsYou(.question), .working(.active), .failed(.init(category: "Build")), .idle(.ready), nil,
        ]
        let scene = try D109ArrangementScene(status: statuses[index])
        let projection = try await ArrangementTableProjector.project(scene.input)
        let row = try #require(projection.panes.first)
        let expected: CommandIcon = .system(index < 3 ? .circleFill : .circle)
        if case .agent(let status) = row.agentStatus { #expect(status.icon == expected) }
        let loader = makeCoreTestOcticonLoader()
        let subject = ArrangementPaneGroupRow(
            pane: row, octiconLoader: loader, commandActionResolver: makePresentedCommandAction, isHighlighted: false)
        let actual = NSHostingView(
            rootView: subject.statusGlyph.frame(width: 40, height: 40).background(Color.black)
                .environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true })
        let colors: [Color] = [
            PaneContextChipTone.warning.foregroundColor, PaneContextChipTone.accent.foregroundColor,
            PaneContextChipTone.danger.foregroundColor, .secondary, .secondary,
        ]
        let reference = NSHostingView(
            rootView: expected.swiftUIImage(loader: loader, size: 8).foregroundStyle(colors[index])
                .frame(width: 8, height: 8).frame(width: 40, height: 40).background(Color.black)
                .environment(\.colorScheme, .dark))
        actual.frame.size = CGSize(width: 40, height: 40)
        reference.frame.size = actual.frame.size
        let observed = try d109Pixels(actual)
        let literal = try d109Pixels(reference)
        #expect(observed == literal, "The native status mark must match the literal 8pt circle")
        #expect(
            stride(from: 0, to: literal.count, by: 4).contains {
                literal[$0] != 0 || literal[$0 + 1] != 0 || literal[$0 + 2] != 0
            })
    }

    @Test("D109 hidden rows have no Hidden readout and their whole status paint is dimmed")
    func hiddenComposition() async throws {
        let scene = try D109ArrangementScene(hiddenAgent: true)
        let projection = try await ArrangementTableProjector.project(scene.input)
        try withTestCoreAtoms { _ in
            let host = makeArrangementPanelHostingView(
                panes: projection.panes, zoomMode: nil, tableMetrics: projection.tableMetrics,
                paneGroups: projection.groups)
            for id in [scene.ids[0], scene.ids[3]] {
                #expect(findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(id)-hidden") == nil)
                let restore = try #require(
                    findArrangementPanelView(in: host, identifier: "arrangement-panel-pane-\(id)-visibility"))
                #expect(restore.accessibilityLabel() == "Show Pane")
            }
        }
        let visibleScene = try D109ArrangementScene()
        let visible = try await ArrangementTableProjector.project(visibleScene.input)
        let visiblePixels = try d109StatusPaint(try #require(visible.panes.first))
        let visiblePaint = await d109ChromaticInk(visiblePixels)
        let hiddenPaint = try d109StatusPaint(try #require(projection.panes.first))
        #expect(visiblePaint > 0, "The visible active mark must paint semantic color")
        let reference = NSHostingView(
            rootView:
                CommandIcon.system(.circleFill).swiftUIImage(loader: makeCoreTestOcticonLoader(), size: 8)
                .foregroundStyle(PaneContextChipTone.warning.foregroundColor)
                .frame(width: 8, height: 8).background(Color.white.opacity(0.04))
                .opacity(0.5).background(Color.black).environment(\.colorScheme, .dark))
        reference.frame.size = CGSize(width: 8, height: 8)
        #expect(
            hiddenPaint == (try d109Pixels(reference)),
            "Whole-row hidden paint must match the independent native half-opacity reference")
    }
}

struct D109ArrangementScene {
    let repoId: UUID
    let ids: [UUID]
    let input: ArrangementTableInput

    init(
        detailMode: Int = 0, hasMessages: Bool = true, hiddenAgent: Bool = false,
        status: AgentSessionStatus? = .needsYou(.question), longTitle: Bool = true
    ) throws {
        repoId = UUIDv7.generate()
        ids = (0..<6).map { _ in UUIDv7.generate() }
        let main = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "Main checkout", path: URL(filePath: "/tmp/context-preview"))
        let preview = Worktree(
            id: UUIDv7.generate(), repoId: repoId, name: "Preview checkout",
            path: URL(filePath: "/tmp/context-preview.preview-layout"))
        let repo = Repo(id: repoId, name: "context-preview", repoPath: main.path, worktrees: [main, preview])
        let provider = try BridgeAgentProviderName("claude-code")
        var sources: [UUID: ArrangementTableInput.PaneSource] = [:]
        for index in ids.indices {
            let linked = index < 4
            let worktree = index == 0 ? main : preview
            let title =
                index == 0
                ? (longTitle
                    ? "Review the pane context display and arrangements alignment across a carefully prepared isolated preview workspace"
                    : "Review the preview")
                : (index == 5 ? "New Tab" : "zsh")
            let pane = Pane(
                id: ids[index],
                content: index == 5
                    ? .webview(.init(url: URL(filePath: "/tmp/new-tab")))
                    : .terminal(.init(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: .init(
                    launchDirectory: index == 5 ? nil : URL(filePath: "/tmp/context-preview"), title: title,
                    facets: .init(
                        repoId: linked ? repo.id : nil, worktreeId: linked ? worktree.id : nil,
                        cwd: index == 5 ? nil : URL(filePath: "/tmp/context-preview")),
                    note: index == 0 && detailMode < 2 ? "Fallback pane note" : nil))
            let counts: PaneMessageCounts =
                index == 0 && hasMessages
                ? .init(kinds: .init(failure: 1, needsYou: 1, done: 1, info: 4), newestOpenBlockingAskId: nil) : .zero
            let line: AgentLineDetail? =
                index == 0 && detailMode == 0
                ? .init(
                    summary: "The UI-fix preview is ready for the owner to explore.", refs: [],
                    writer: .pane(.init(existingUUID: ids[0])), updatedAt: Date(timeIntervalSince1970: 700)) : nil
            sources[ids[index]] = .init(
                state: .init(pane: pane),
                display: .init(
                    revision: .init(1), agentTitle: nil, agentLine: line, own: counts,
                    includingDrawers: counts, pullRequests: .notApplicable),
                session: index == 0
                    ? status.map { .init(status: $0, evidence: .verifiedLive, provider: provider) } : nil,
                repository: linked ? repo : nil, worktree: linked ? worktree : nil,
                repositoryUnavailable: false, worktreeUnavailable: false,
                enrichment: linked
                    ? .init(worktreeId: worktree.id, repoId: repo.id, branch: index == 0 ? "main" : "preview/layout")
                    : nil)
        }
        let arrangement = UUIDv7.generate()
        let minimized: Set<UUID> = hiddenAgent ? [ids[0], ids[3]] : [ids[3]]
        input = .init(
            graph: .init(
                tabId: UUIDv7.generate(), allPaneIds: ids,
                arrangements: [
                    .init(
                        id: arrangement, name: "Default", isDefault: true,
                        layout: .autoTiled(ids), minimizedPaneIds: minimized, drawerViews: [:])
                ]),
            activeArrangementId: arrangement, sources: sources, zoom: nil, shellExecutablePath: "/bin/zsh",
            referenceDate: Date(timeIntervalSince1970: 1000))
    }
}

@MainActor
private func d109Pixels(_ host: NSView, region: ((NSView) throws -> CGRect)? = nil) throws -> Data {
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
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let rect = try region?(host) ?? host.bounds
    let pixelWidth = Int(rect.width * 2)
    let pixelHeight = Int(rect.height * 2)
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = rect.size
    host.cacheDisplay(in: rect, to: bitmap)
    let image = try #require(bitmap.cgImage)
    var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(
            CGContext(
                data: buffer.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }
    return Data(bytes)
}

@MainActor
private func d109StatusPaint(_ row: PaneVisibilityInfo) throws -> Data {
    let view = NSHostingView(
        rootView: ArrangementPaneGroupRow(
            pane: row, octiconLoader: makeCoreTestOcticonLoader(),
            commandActionResolver: makePresentedCommandAction, isHighlighted: false
        )
        .frame(width: 520).background(Color.black).environment(\.colorScheme, .dark)
        .transaction { $0.disablesAnimations = true })
    view.frame.size = view.fittingSize
    return try d109Pixels(view) { host in
        let mark = try #require(
            findArrangementPanelView(
                in: host, identifier: "arrangement-panel-pane-\(row.id)-status-glyph"))
        return mark.convert(mark.bounds, to: host)
    }
}

@concurrent
nonisolated
    private func d109ChromaticInk(_ pixels: Data) async -> Int
{
    stride(from: 0, to: pixels.count, by: 4).reduce(0) { total, offset in
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        return total + max(red, green, blue) - min(red, green, blue)
    }
}
