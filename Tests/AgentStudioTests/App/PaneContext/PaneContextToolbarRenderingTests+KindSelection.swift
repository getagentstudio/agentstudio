import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextToolbarRenderingTests {
    @Test("G22 measured toolbar yields Git before hiding the whole context item", arguments: [390.0, 520.0, 1400.0])
    func compactToolbarSelectionAndGeometry(width: Double) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let statuses = SessionStatusAtom()
            statuses.apply([pane: .set(.init(status: .working(.active), evidence: .verifiedLive))])
            let readers = PaneContextTestSourceOwners(
                sessionStatus: statuses, presentation: atoms.paneContextPresentation, pane: { _ in nil },
                serviceProvider: { nil })
            let now = Date(timeIntervalSince1970: 1_800_000_125)
            let line = AgentLineDetail(
                summary: String(repeating: "Wide work description ", count: 20), refs: [], writer: .pane(pane),
                updatedAt: now.addingTimeInterval(-8 * 86_400))
            let scenarios: [(PaneMessageKindCounts, AgentLineDetail?, [String])] = [
                (.zero, nil, []), (.zero, line, []),
                (.init(failure: 1, needsYou: 1, done: 1, info: 1), line, ["failure", "needsYou", "done", "info"]),
                (.init(failure: 0, needsYou: 0, done: 0, info: 1), line, ["info"]),
            ]
            var fixedBaseline: [String: CGRect]?
            for (kinds, detail, expectedKinds) in scenarios {
                let counts = PaneMessageCounts(kinds: kinds, newestOpenBlockingAskId: nil)
                atoms.paneContextPresentation.apply([
                    pane: .set(
                        .init(
                            revision: .init(1), agentTitle: nil, agentLine: detail,
                            own: counts, includingDrawers: counts, pullRequests: .notApplicable))
                ])
                let reference = try referenceFit(kinds: expectedKinds, hasLine: detail != nil)
                try await withMountedToolbar(pane: pane, readers: readers, width: width) { mounted in
                    let frames = buttonFrames(in: mounted.host)
                    let fixed = frames.filter { !$0.key.hasPrefix("pane-context.messages.") }
                    if let fixedBaseline { #expect(fixed == fixedBaseline) } else { fixedBaseline = fixed }
                    #expect(fixed.count == 9)
                    #expect(mounted.host.bounds.width == CGFloat(width))
                    #expect(mounted.host.bounds.height == DrawerLayout.iconStripHeight)
                    #expect(mounted.host.fittingSize.width <= width)
                    let start = try #require(frames["paneSurfaceToolbar.note"]).maxX
                    let end = try firstTrailingAction(in: fixed)
                    let available = end - start
                    let drawsItem = reference.minimumWidth > 0 && reference.minimumWidth <= available
                    let expectsGit =
                        reference.minimumWidth == 0
                        ? reference.gitWidth <= available
                        : drawsItem && reference.minimumWidth + reference.gitWidth <= available
                    let git = labelBridge(in: mounted.host, identifier: "paneSurfaceToolbar.gitStatus")
                    #expect(
                        (git != nil) == expectsGit,
                        "At \(width): \(available) pt available, item \(reference.minimumWidth), Git \(reference.gitWidth)"
                    )
                    if let git {
                        let rect = mounted.host.convert(git.bounds, from: git)
                        #expect(rect.minX >= start && rect.maxX <= end)
                    }
                    let visibleKinds = drawsItem ? expectedKinds : []
                    let chips = try expectKindGeometry(
                        visibleKinds, frames: frames, in: mounted.host, start: start, end: end)
                    try expectKindPalette(visibleKinds, frames: chips, in: mounted, width: width)
                    try expectItemDivider(
                        in: mounted, drawsItem: drawsItem, region: start...end,
                        content: !expectedKinds.isEmpty ? .chips : (detail != nil ? .agentLine : .empty),
                        firstChip: chips.first, width: width)
                    let labels = accessibilityLabels(in: mounted.host)
                    #expect(!labels.contains("Working"))
                    if !expectedKinds.isEmpty { #expect(!labels.contains("[8 days ago]")) }
                    if width >= 1400 && expectedKinds.count == 4 { #expect(git != nil && chips.count == 4) }
                }
            }
        }
    }

    private func referenceFit(kinds: [String], hasLine: Bool) throws -> (minimumWidth: CGFloat, gitWidth: CGFloat) {
        let content: AnyView
        if !kinds.isEmpty {
            content = frozenKindItem(kinds)
        } else if hasLine {
            content = AnyView(
                HStack(spacing: 0) {
                    Divider().frame(width: 1, height: 16).padding(.horizontal, 6)
                    Image(systemName: "text.bubble").frame(width: 14)
                    Color.clear.frame(width: 4, height: 0)
                    Text("… [8 days ago]").font(.system(size: 12)).fixedSize()
                }.fixedSize().background {
                    AccessibilityLabelBridge(identifier: "reference.lineMinimum", label: "", role: .staticText)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
        } else {
            content = AnyView(Color.clear.frame(width: 0, height: 0))
        }
        let reference = mountCard(toolbarRoot(contextContent: content, width: 1400), width: 1400)
        defer { reference.window.close() }
        let frames = buttonFrames(in: reference.host)
        let end = try firstTrailingAction(in: frames)
        let git = try #require(labelBridge(in: reference.host, identifier: "paneSurfaceToolbar.gitStatus"))
        let gitWidth = end - reference.host.convert(git.bounds, from: git).minX
        let minimum: CGFloat
        if let lastKind = kinds.last {
            minimum =
                try #require(frames["reference." + lastKind]).maxX
                - (try #require(frames["paneSurfaceToolbar.note"])).maxX
        } else if hasLine {
            minimum = try #require(labelBridge(in: reference.host, identifier: "reference.lineMinimum")).bounds.width
        } else {
            minimum = 0
        }
        return (minimum, gitWidth)
    }

    private func firstTrailingAction(in frames: [String: CGRect]) throws -> CGFloat {
        let leading: Set<String> = [
            "paneSurfaceToolbar.drawerToggle", "paneSurfaceToolbar.drawerAdd",
            "paneSurfaceToolbar.pinPane", "paneSurfaceToolbar.note",
        ]
        return try #require(
            frames.filter {
                !leading.contains($0.key) && !$0.key.hasPrefix("reference.")
                    && !$0.key.hasPrefix("pane-context.")
            }.values.map(\.minX).min())
    }

    private func expectKindGeometry(
        _ kinds: [String], frames: [String: CGRect], in host: NSView,
        start: CGFloat, end: CGFloat
    ) throws -> [CGRect] {
        let identifiers = kinds.map { "pane-context.messages." + $0 }
        #expect(Set(frames.keys.filter { $0.hasPrefix("pane-context.messages.") }) == Set(identifiers))
        let chips = try identifiers.map { try #require(frames[$0]) }
        #expect(zip(chips, chips.dropFirst()).allSatisfy { $0.0.maxX <= $0.1.minX })
        #expect(chips.allSatisfy { $0.width > 0 && $0.minX >= start && $0.maxX <= end })
        #expect(chips.allSatisfy { abs($0.midY - host.bounds.midY) < 1 })
        return chips
    }

    private func expectKindPalette(
        _ kinds: [String], frames: [CGRect], in mounted: PaneContextToolbarTestHost,
        width: CGFloat
    ) throws {
        guard !kinds.isEmpty else { return }
        let reference = mountCard(toolbarRoot(contextContent: frozenKindItem(kinds), width: width), width: width)
        defer { reference.window.close() }
        let referenceFrames = buttonFrames(in: reference.host)
        for (kind, rect) in zip(kinds, frames) {
            let referenceRect = try #require(referenceFrames["reference." + kind])
            #expect(rect == referenceRect)
            let actualPixels = try pixels(in: mounted.host, rect: rect)
            let referencePixels = try pixels(in: reference.host, rect: referenceRect)
            if actualPixels != referencePixels {
                recordToolbarPaint(mounted.host, name: "actual-" + kind, rect: rect)
                recordToolbarPaint(reference.host, name: "reference-" + kind, rect: referenceRect)
            }
            #expect(
                actualPixels == referencePixels,
                "The full \(kind) chip must paint with its literal glyph and semantic colour")
        }
    }

    private func expectItemDivider(
        in mounted: PaneContextToolbarTestHost, drawsItem: Bool,
        region: ClosedRange<CGFloat>, content: ToolbarFixtureContent, firstChip: CGRect?, width: CGFloat
    ) throws {
        let divider = labelBridge(in: mounted.host, identifier: "paneSurfaceToolbar.contextDivider")
        #expect((divider != nil) == drawsItem)
        if let divider {
            let rect = mounted.host.convert(divider.bounds, from: divider)
            #expect(rect.minX > region.lowerBound)
            if let firstChip { #expect(rect.maxX <= firstChip.minX) }
            if content == .agentLine { try expectFullAge("[8 days ago]", in: mounted, width: width) }
        } else if content != .empty {
            #expect(!accessibilityLabels(in: mounted.host).contains("[8 days ago]"))
            let region = CGRect(
                x: region.lowerBound + 1, y: 0,
                width: region.upperBound - region.lowerBound - 2, height: mounted.host.bounds.height)
            // Equivalent native parent and crop coordinates keep background/edge rasterization
            // independent of the optional context item. O20 still requires exact absence.
            let reference = mountCard(
                toolbarRoot(contextContent: AnyView(EmptyView()), width: width, includesGit: false), width: width)
            defer { reference.window.close() }
            let actualPixels = try pixels(in: mounted.host, rect: region)
            let referencePixels = try pixels(in: reference.host, rect: region)
            if actualPixels != referencePixels {
                recordToolbarPaint(mounted.host, name: "hidden-actual", rect: region)
                recordToolbarPaint(reference.host, name: "hidden-reference", rect: region)
            }
            #expect(
                actualPixels == referencePixels,
                "A hidden item leaves no partial chip, text, icon or divider")
        }
    }

    private func frozenKindItem(_ kinds: [String]) -> AnyView {
        AnyView(
            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                Divider().frame(width: 1, height: 16).padding(.horizontal, 6)
                ForEach(kinds, id: \.self) { kind in
                    frozenKindChip(kind).background {
                        AccessibilityPressBridge(identifier: "reference." + kind, label: kind, action: {})
                    }
                }
            }.fixedSize().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
    }

    func frozenKindChip(_ kind: String, background: Color = AppStyles.Shell.DrawerToolbar.background) -> AnyView {
        let icon: String
        let style: SidebarChip.Style
        switch kind {
        case "failure":
            icon = "xmark"
            style = .danger
        case "needsYou":
            icon = "flag"
            style = .warning
        case "done":
            icon = "checkmark"
            style = .success
        default:
            icon = "info.circle"
            style = .neutral
        }
        return AnyView(
            Button(
                action: {},
                label: {
                    SidebarChip(icon: .system(icon), octiconLoader: makeTestOcticonLoader(), text: "1", style: style)
                }
            ).buttonStyle(.plain).background(background))
    }

    private func labelBridge(in view: NSView, identifier: String) -> AccessibilityLabelBridgeView? {
        if let label = view as? AccessibilityLabelBridgeView,
            label.accessibilityIdentifier() == identifier
        {
            return label
        }
        return view.subviews.lazy.compactMap { labelBridge(in: $0, identifier: identifier) }.first
    }

    private func recordToolbarPaint(_ host: NSView, name: String, rect: CGRect? = nil) {
        let region = rect ?? host.bounds
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: region) else { return }
        host.cacheDisplay(in: region, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        Attachment.record(Array(png), named: "toolbar-" + name + ".png")
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        try? png.write(to: root.appending(path: "tmp/handback/p3-toolbar-" + name + ".png"))
    }
}

private enum ToolbarFixtureContent { case empty, agentLine, chips }
