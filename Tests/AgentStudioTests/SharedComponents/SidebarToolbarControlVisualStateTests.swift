import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Sidebar toolbar control visual state", .serialized)
struct SidebarToolbarControlVisualStateTests {
    @Test("outgoing label fade overlaps shared resizing")
    func labelTimingMatchesApprovedSequence() {
        #expect(AppStyles.Shell.Sidebar.ToolbarControl.labelFadeOutDuration == 0.04)
        #expect(AppStyles.Shell.Sidebar.ToolbarControl.selectionResizeDelay == 0.02)
        #expect(AppStyles.Shell.Sidebar.ToolbarControl.selectionResizeDuration == AppStyles.General.Animation.fast)
        #expect(AppStyles.Shell.Sidebar.ToolbarControl.labelFadeInDuration == 0.04)
        #expect(abs(AppStyles.Shell.Sidebar.ToolbarControl.labelFadeInDelay - 0.10) < Double.ulpOfOne)
    }

    @Test(
        "outgoing and incoming label widths exchange together at intermediate progress",
        arguments: [CGFloat(0), 0.25, 0.5, 0.75, 1])
    @MainActor
    func labelWidthsExchangeTogether(progress: CGFloat) {
        func mountedWidth(fraction: CGFloat) -> CGFloat {
            let host = NSHostingView(
                rootView: SidebarToolbarLabelLayout(revealFraction: fraction) {
                    Color.clear.frame(width: 80, height: 20)
                })
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let outgoing = mountedWidth(fraction: 1 - progress)
        let incoming = mountedWidth(fraction: progress)
        #expect(abs(outgoing - 80 * (1 - progress)) < 0.5)
        #expect(abs(incoming - 80 * progress) < 0.5)
        #expect(abs(outgoing + incoming - 80) < 0.5)
    }

    @Test("selected segment expands to show its label")
    @MainActor
    func selectedSegmentExpandsToShowItsLabel() {
        let repoWidth = mountedSegmentedControlWidth(selection: 0)
        let allPanesWidth = mountedSegmentedControlWidth(selection: 1)

        #expect(allPanesWidth > repoWidth)
    }

    @Test("shortcut overlays do not change toggle or filter geometry")
    @MainActor
    func shortcutOverlaysPreserveControlGeometry() throws {
        let toggleWithoutHints = mountedSegmentedControlSize(showsHints: false)
        let toggleWithHints = mountedSegmentedControlSize(showsHints: true)
        #expect(toggleWithHints == toggleWithoutHints)

        for width in [CGFloat(250), CGFloat(320)] {
            let filterWithoutHint = try mountedSearchFieldGeometry(showsHint: false, width: width)
            let filterWithHint = try mountedSearchFieldGeometry(showsHint: true, width: width)
            #expect(filterWithHint.hostSize == filterWithoutHint.hostSize)
            #expect(filterWithHint.textFieldFrameInHost == filterWithoutHint.textFieldFrameInHost)
            let badgeBounds = try #require(filterWithHint.badgeBounds)
            #expect(abs(badgeBounds.midY - filterWithHint.hostSize.height / 2) <= 1)
            #expect(badgeBounds.maxX <= filterWithHint.hostSize.width)
            #expect(filterWithoutHint.badgeBounds == nil)
        }
    }

    @Test("filter shortcut replaces the trailing clear action without leaving it interactive")
    @MainActor
    func filterShortcutDisablesAndRestoresTrailingClearAction() throws {
        let model = SidebarSearchFieldTextModel(text: "filter with clear button")
        let withoutHint = try mountedSearchFieldGeometry(showsHint: false, width: 250, model: model)
        let clearPoint = try clickTrailingControl(in: withoutHint) { model.text.isEmpty }
        #expect(model.text.isEmpty)

        model.text = "filter with clear button"
        let withHint = try mountedSearchFieldGeometry(showsHint: true, width: 250, model: model)
        try click(at: clearPoint, in: withHint)
        #expect(model.text == "filter with clear button")

        let restored = try mountedSearchFieldGeometry(showsHint: false, width: 250, model: model)
        try click(at: clearPoint, in: restored)
        #expect(model.text.isEmpty)
    }

    @Test("shared trailing action visibility disables paint, hit testing, and accessibility together")
    func trailingActionVisibilityIsOneSharedContract() {
        let visible = SidebarTrailingActionVisibility(shortcutDisplay: nil)
        #expect(visible.opacity == 1)
        #expect(visible.allowsHitTesting)
        #expect(!visible.accessibilityHidden)

        let replaced = SidebarTrailingActionVisibility(
            shortcutDisplay: ShortcutDisplayText(value: "1")
        )
        #expect(replaced.opacity == 0)
        #expect(!replaced.allowsHitTesting)
        #expect(replaced.accessibilityHidden)
    }

    @Test("selected segment uses accent paint inside one quiet noninteractive group border")
    func selectedSegmentUsesAccentWithinQuietGroupBorder() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarToolbarSegmentedControl.swift",
            encoding: .utf8
        )

        #expect(source.contains("Text(segment.label)"))
        #expect(source.contains("ChromeToolbarControlPalette.foregroundColor"))
        // The selected fill must come from the same shared palette the Zoom pill family uses (an
        // accent-tinted fill), not an ad-hoc Color.primary opacity — that generic grey fill remains
        // only for the unselected/hover/pressed states.
        #expect(source.contains("ChromeToolbarControlPalette.fillColor"))
        #expect(source.contains("visualState.fillOpacity"))
        #expect(source.components(separatedBy: ".stroke(").count == 2)
        #expect(source.contains(".stroke(AppStyles.General.Stroke.controlGroupColor, lineWidth: 1)"))
        #expect(source.contains(".allowsHitTesting(false)"))
        #expect(!source.contains("ChromeToolbarControlPalette.strokeColor"))
    }

    @Test("selected label fades separately from shared segment resizing and stays clipped")
    func selectedLabelSharesClippedSegmentTransition() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarToolbarSegmentedControl.swift",
            encoding: .utf8
        )

        #expect(!source.contains("if model.showsLabel(for: segment.value)"))
        #expect(source.contains("SidebarToolbarLabelLayout("))
        #expect(!source.contains(".transition("))
        #expect(source.contains(".clipped()"))
        #expect(source.contains("value: model.selection"))
        #expect(source.contains("labelFadeOutDuration"))
        #expect(source.contains("labelFadeInDuration"))
        #expect(source.contains("labelFadeInDelay"))
        #expect(source.contains("selectionResizeDelay"))
        #expect(source.contains("selectionResizeDuration"))
        #expect(!source.contains("AnyTransition.offset"))
    }

    @Test("entity shortcuts are rendered below the selected label, never over the icon")
    func entityShortcutPlacementUsesExistingStampPrimitive() throws {
        let toggleSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarEntityToggle.swift", encoding: .utf8)
        let controlSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarToolbarSegmentedControl.swift", encoding: .utf8
        )
        #expect(toggleSource.contains("shortcutDisplay: shortcutDisplay"))
        #expect(toggleSource.contains("content: .selectedLabel"))
        #expect(!toggleSource.contains("sidebarShortcutHint(shortcutDisplay(value)"))
        #expect(controlSource.contains(".sidebarShortcutHint("))
        #expect(controlSource.contains("alignment: .bottomTrailing"))
        #expect(!controlSource.contains("shortcutRailHeight"))
        #expect(AppStyles.Shell.Sidebar.KeyboardHint.stampFontSize == 12)
        #expect(AppStyles.Shell.Sidebar.KeyboardHint.stampFontWeight == .bold)
        #expect(
            AppStyles.Shell.Sidebar.KeyboardHint.stampForegroundColor
                == AppStyles.Shell.Chrome.ToolbarButton.baseFillColor
        )
        #expect(
            AppStyles.Shell.Sidebar.KeyboardHint.stampBackgroundColor
                == AppStyles.General.Accent.primaryColor
        )
        #expect(
            AppStyles.Shell.Sidebar.KeyboardHint.horizontalPadding
                < AppStyles.General.Spacing.standard
        )
        #expect(
            AppStyles.Shell.Sidebar.KeyboardHint.height
                == AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
        )

        let hintSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarShortcutHint.swift",
            encoding: .utf8
        )
        #expect(!hintSource.contains("isSelected"))
        #expect(!hintSource.contains("stampBorderColor"))
        #expect(hintSource.contains("if style == .keycap"))
    }

    @Test("Repo Explorer toolbar has no standalone keyboard glyph")
    func repoExplorerToolbarOmitsStandaloneKeyboardGlyph() throws {
        let source = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+CommandToolbar.swift",
            encoding: .utf8
        )
        #expect(!source.contains("AppCommand.focusSidebar.definition.icon.swiftUIImage"))

        let searchSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarSearchField.swift",
            encoding: .utf8
        )
        #expect(searchSource.contains(".sidebarShortcutHint("))
        #expect(searchSource.contains("alignment: .trailing"))

        let paneRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerPaneNavigation.swift",
            encoding: .utf8
        )
        #expect(paneRowSource.contains(".sidebarShortcutHint("))
        #expect(paneRowSource.contains("alignment: .trailing"))
        #expect(!paneRowSource.contains("style: .accentGlyph"))

        let worktreeRowSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerWorktreeRow.swift",
            encoding: .utf8
        )
        #expect(worktreeRowSource.contains(".sidebarShortcutHint("))
        #expect(worktreeRowSource.contains("alignment: .trailing"))
    }

    @Test("organization popovers render command-catalog tooltips")
    func organizationPopoversRenderCommandCatalogTooltips() throws {
        let controlSource = try String(
            contentsOfFile: "Sources/AgentStudio/SharedComponents/SidebarToolbarSegmentedControl.swift",
            encoding: .utf8
        )
        let repoExplorerSource = try String(
            contentsOfFile: "Sources/AgentStudio/Features/RepoExplorer/RepoExplorerView+CommandToolbar.swift",
            encoding: .utf8
        )

        #expect(controlSource.contains(".controlHelp(segment.tooltipValue)"))
        #expect(repoExplorerSource.contains("tooltipValue: command.definition.controlTooltipRenderValue("))
        #expect(repoExplorerSource.contains("organizationAction.controlTooltipRenderValue("))
        #expect(repoExplorerSource.contains("selected.definition.controlTooltipRenderValue()"))
    }

    @Test("interaction state precedence is disabled pressed open active hovered idle")
    func interactionStatePrecedence() {
        #expect(resolve(isEnabled: false, isHovered: true, isPressed: true, isActive: true, isOpen: true) == .disabled)
        #expect(resolve(isHovered: true, isPressed: true, isActive: true, isOpen: true) == .pressed)
        #expect(resolve(isHovered: true, isActive: true, isOpen: true) == .open)
        #expect(resolve(isHovered: true, isActive: true) == .active)
        #expect(resolve(isHovered: true) == .hovered)
        #expect(resolve() == .idle)
    }

    @Test("visible interaction states paint stronger fills than idle")
    func visibleInteractionStatesPaintFills() {
        #expect(SidebarToolbarControlVisualState.idle.fillOpacity == 0)
        #expect(SidebarToolbarControlVisualState.hovered.fillOpacity > 0)
        #expect(
            SidebarToolbarControlVisualState.pressed.fillOpacity
                > SidebarToolbarControlVisualState.hovered.fillOpacity
        )
        #expect(
            SidebarToolbarControlVisualState.open.fillOpacity
                >= SidebarToolbarControlVisualState.pressed.fillOpacity
        )
    }

    private func resolve(
        isEnabled: Bool = true,
        isHovered: Bool = false,
        isPressed: Bool = false,
        isActive: Bool = false,
        isOpen: Bool = false
    ) -> SidebarToolbarControlVisualState {
        SidebarToolbarControlVisualState.resolve(
            isEnabled: isEnabled,
            isHovered: isHovered,
            isPressed: isPressed,
            isActive: isActive,
            isOpen: isOpen
        )
    }
    @MainActor
    private func mountedSegmentedControlWidth(selection: Int) -> CGFloat {
        mountedSegmentedControlSize(selection: selection, showsHints: false).width
    }

    @MainActor
    private func mountedSegmentedControlSize(
        selection: Int = 0,
        showsHints: Bool
    ) -> CGSize {
        let segments = [
            SidebarToolbarSegment(
                value: 0,
                label: "By Repo",
                accessibilityIdentifier: "byRepo",
                tooltipValue: ControlTooltipRenderValue(text: "By Repo", shortcutDisplayText: nil),
                isEnabled: true
            ),
            SidebarToolbarSegment(
                value: 1,
                label: "All Panes",
                accessibilityIdentifier: "allPanes",
                tooltipValue: ControlTooltipRenderValue(text: "All Panes", shortcutDisplayText: nil),
                isEnabled: true
            ),
            SidebarToolbarSegment(
                value: 2,
                label: "By Tab",
                accessibilityIdentifier: "byTab",
                tooltipValue: ControlTooltipRenderValue(text: "By Tab", shortcutDisplayText: nil),
                isEnabled: true
            ),
        ]
        let hostingView = NSHostingView(
            rootView: SidebarToolbarSegmentedControl(
                segments: segments,
                selection: selection,
                icon: { _ in Image(systemName: "folder") },
                shortcutDisplay: { value in
                    showsHints ? ShortcutDisplayText(value: value == 0 ? "R" : "P") : nil
                },
                onSelect: { _ in }
            )
        )
        hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    @MainActor
    private func mountedSearchFieldGeometry(
        showsHint: Bool,
        width: CGFloat = 250,
        model: SidebarSearchFieldTextModel = SidebarSearchFieldTextModel(
            text: "filter with clear button"
        )
    ) throws -> SearchFieldGeometry {
        let hostingView = NSHostingView(
            rootView: SidebarSearchFieldGeometryFixture(showsHint: showsHint, model: model)
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: hostingView.fittingSize.height)
        let window = NSWindow(
            contentRect: hostingView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let textField = try #require(firstDescendant(NSTextField.self, in: hostingView))
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let bitmapBadgeBounds = accentBadgeBounds(
            in: bitmap,
            xRange: max(0, bitmap.pixelsWide - 96)..<bitmap.pixelsWide,
            yRange: 0..<bitmap.pixelsHigh
        )
        let pixelScaleX = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        let pixelScaleY = CGFloat(bitmap.pixelsHigh) / hostingView.bounds.height
        let badgeBounds = bitmapBadgeBounds.map { bitmapBounds in
            CGRect(
                x: bitmapBounds.minX / pixelScaleX,
                y: hostingView.bounds.height - bitmapBounds.maxY / pixelScaleY,
                width: bitmapBounds.width / pixelScaleX,
                height: bitmapBounds.height / pixelScaleY
            )
        }
        return SearchFieldGeometry(
            hostSize: hostingView.bounds.size,
            textFieldFrameInHost: hostingView.convert(textField.bounds, from: textField),
            badgeBounds: badgeBounds,
            accessibilityLabels: accessibilityLabels(in: hostingView),
            hostingView: hostingView,
            window: window
        )
    }

    @MainActor
    private func click(at location: NSPoint, in geometry: SearchFieldGeometry) throws {
        let windowLocation = geometry.hostingView.convert(location, to: nil)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            geometry.window.sendEvent(
                try #require(
                    NSEvent.mouseEvent(
                        with: eventType,
                        location: windowLocation,
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: geometry.window.windowNumber,
                        context: nil,
                        eventNumber: eventType == .leftMouseDown ? 1 : 2,
                        clickCount: 1,
                        pressure: eventType == .leftMouseDown ? 1 : 0
                    )
                )
            )
        }
    }

    @MainActor
    private func clickTrailingControl(
        in geometry: SearchFieldGeometry,
        until condition: () -> Bool
    ) throws -> NSPoint {
        for x in stride(
            from: geometry.hostingView.bounds.maxX - 4,
            through: geometry.hostingView.bounds.maxX - 48,
            by: -2
        ) {
            let point = NSPoint(x: x, y: geometry.hostingView.bounds.midY)
            try click(at: point, in: geometry)
            if condition() { return point }
        }
        Issue.record("No trailing clear-action hit target was found")
        return .zero
    }

    private func accentBadgeBounds(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> CGRect? {
        var bounds: CGRect?
        for y in yRange {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    color.redComponent < 0.55,
                    color.greenComponent > 0.45,
                    color.blueComponent > 0.75,
                    color.blueComponent - color.redComponent > 0.3,
                    color.alphaComponent > 0.98
                else { continue }
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        }
        return bounds
    }

    @MainActor
    private func accessibilityLabels(in view: NSView) -> Set<String> {
        var labels = Set<String>()
        if let label = view.accessibilityLabel(), !label.isEmpty {
            labels.insert(label)
        }
        for child in view.accessibilityChildren() ?? [] {
            if let childView = child as? NSView {
                labels.formUnion(accessibilityLabels(in: childView))
            } else if let child = child as? NSAccessibilityElement,
                let label = child.accessibilityLabel(),
                !label.isEmpty
            {
                labels.insert(label)
            }
        }
        return labels
    }

    @MainActor
    private func firstDescendant<ViewType: NSView>(
        _ type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType { return match }
        for subview in view.subviews {
            if let match = firstDescendant(type, in: subview) { return match }
        }
        return nil
    }
}

private struct SearchFieldGeometry: Equatable {
    let hostSize: CGSize
    let textFieldFrameInHost: CGRect
    let badgeBounds: CGRect?
    let accessibilityLabels: Set<String>
    let hostingView: NSHostingView<SidebarSearchFieldGeometryFixture>
    let window: NSWindow

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hostSize == rhs.hostSize
            && lhs.textFieldFrameInHost == rhs.textFieldFrameInHost
            && lhs.badgeBounds == rhs.badgeBounds
            && lhs.accessibilityLabels == rhs.accessibilityLabels
    }
}

@MainActor
private final class SidebarSearchFieldTextModel {
    var text: String

    init(text: String) {
        self.text = text
    }
}

private struct SidebarSearchFieldGeometryFixture: View {
    private enum FocusTarget: Hashable { case filter }

    @FocusState private var focusedField: FocusTarget?
    let showsHint: Bool
    let model: SidebarSearchFieldTextModel

    var body: some View {
        SidebarSearchField(
            placeholder: "Filter...",
            text: Binding(
                get: { model.text },
                set: { model.text = $0 }
            ),
            focusedField: $focusedField,
            focusValue: .filter,
            clearHelp: "Clear filter",
            shortcutDisplay: showsHint ? ShortcutDisplayText(value: "F") : nil
        )
    }
}
