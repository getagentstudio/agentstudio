import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct PaneContextPopoverRedesignTests {
    enum ActionRole: CaseIterable { case utility, rowDismiss, alternative, commit }

    @Test("Default shared chips retain main's exact sidebar paint", arguments: [false, true])
    func defaultChipKeepsMainPaint(iconOnly: Bool) throws {
        try withMounted(
            SidebarChip(
                icon: .system("clock"), octiconLoader: .init(resourceBundle: .main),
                text: iconOnly ? nil : "2 min ago", style: .neutral)
        ) { actual in
            try withMounted(literalMainChip(iconOnly: iconOnly)) { reference in
                let actualPixels = try pixels(actual)
                let expectedPixels = try pixels(reference)
                #expect(actualPixels == expectedPixels, "Popover paint must not change a default sidebar chip")
            }
        }
    }

    private func literalMainChip(iconOnly: Bool) -> some View {
        HStack(spacing: AppStyles.Shell.Sidebar.chipContentSpacing) {
            Image(systemName: "clock")
                .font(.system(size: AppStyles.Shell.Sidebar.chipIconSize, weight: .medium))
            if !iconOnly {
                Text("2 min ago")
                    .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .padding(
            .horizontal,
            iconOnly
                ? AppStyles.Shell.Sidebar.chipIconOnlyHorizontalPadding : AppStyles.Shell.Sidebar.chipHorizontalPadding
        )
        .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
        .background(
            Capsule().fill(Color.white.opacity(AppStyles.Shell.Sidebar.chipBackgroundOpacity))
                .overlay(Capsule().fill(Color.black.opacity(AppStyles.Shell.Sidebar.chipMuteOverlayOpacity)))
        )
        .foregroundStyle(Color.secondary.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity))
        .overlay(Capsule().stroke(Color.white.opacity(AppStyles.Shell.Sidebar.chipBorderOpacity), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: true)
    }

    @Test(arguments: ActionRole.allCases)
    func explicitRolesPaintTheAcceptedControl(role: ActionRole) throws {
        let loader = OcticonLoader(resourceBundle: .main)
        let control = PaneContextControlModel(
            identifier: "proof.action", label: "Action", icon: .system("terminal"),
            tooltip: .init(text: "Catalog tooltip", shortcutDisplayText: nil))
        let actualRole: PaneContextActionButton.Role =
            switch role {
            case .utility: .utility(loader)
            case .rowDismiss: .rowDismiss(loader)
            case .alternative: .alternative
            case .commit: .commit
            }
        try withMounted(PaneContextActionButton(control, role: actualRole) {}) { actual in
            try withMounted(referenceAction(role, loader: loader, tooltip: control.tooltip)) { reference in
                if role == .alternative || role == .commit {
                    try recordPaintReview(actual, name: "action-\(role)-actual")
                    try recordPaintReview(reference, name: "action-\(role)-reference")
                }
                #expect(
                    try pixels(actual) == pixels(reference), "Role must choose its accepted renderer and paint: \(role)"
                )
                let button = try #require(findButton(in: actual))
                #expect(button.accessibilityLabel() == "Action")
                #expect(button.accessibilityHelp() == "Catalog tooltip")
                if role == .rowDismiss { #expect(button.bounds.size == CGSize(width: 24, height: 24)) }
            }
        }
    }

    @Test(arguments: [
        "One-line prose remains proportional", "Prose remains proportional\nacross paragraph breaks",
    ])
    func proseKeepsItsPreparedFontAndAgeOnItsOwnLine(message: String) throws {
        try withMounted(PaneContextMessageText(body: message, age: .init(text: "12 hr ago"), identifier: "proof.body"))
        { actual in
            try withMounted(
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(
                            .system(
                                size: 12,
                                design: .default)
                        )
                        .lineSpacing(2).foregroundStyle(.primary)
                    Text("12 hr ago").font(.system(size: 12)).foregroundStyle(.secondary)
                }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ) { reference in
                let actualPixels = try pixels(actual)
                let expectedPixels = try pixels(reference)
                #expect(actualPixels == expectedPixels, "Body font/whitespace/metadata must match N1b and R2")
            }
        }
    }

    @Test
    func detailsSelectionPaintsTheSharedAccent() throws {
        let loader = OcticonLoader(resourceBundle: .main)
        let control = PaneContextControlModel(
            identifier: "proof.details", label: "Details", icon: .system("chevron.right"),
            tooltip: .init(text: "Show the full content", shortcutDisplayText: nil))
        try withMounted(PaneContextActionButton(control, role: .details(loader), isSelected: true) {}) { actual in
            // D92-B keeps the accepted geometry and uses semantic system selection paint.
            try withMounted(
                HStack(spacing: 4) {
                    Text("Details")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .selectedContentBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(
                                Color(nsColor: .controlAccentColor), lineWidth: 1)
                        }
                }
            ) { reference in
                try recordPaintReview(actual, name: "details-selected-actual")
                try recordPaintReview(reference, name: "details-selected-reference")
                let actualPixels = try pixels(actual)
                let expectedPixels = try pixels(reference)
                #expect(
                    actualPixels == expectedPixels, "The selected Details trigger must paint the shared active variant")
            }
        }
    }

    @Test
    func preparedCodeSpansPaintInsideProportionalProse() throws {
        let prose = "Prose before\n"
        let code = "```swift\nlet count = 42\n```"
        let after = "\nProse after"
        let row = MessageRowModel(
            id: UUIDv7.generate(), sourcePaneId: UUIDv7.generate(), sourceLabel: nil,
            sender: .pane(UUIDv7.generate()), sentAt: .distantPast, sourceOccurredAt: nil,
            body: prose + code + after, bodyFont: .proportional(pointSize: 12), why: nil,
            importance: .info, shape: .notice(.unread), actions: [], kind: .notice(.info),
            kindIcon: .system("info.circle"), age: .init(text: "Now"), isDimmed: false,
            settledLabel: nil, availability: .noticeActions)
        var expectedProse = AttributedString(prose)
        expectedProse.font = .system(size: 12)
        var expectedCode = AttributedString("let count = 42")
        expectedCode.font = .system(size: 11, design: .monospaced)
        var expectedAfter = AttributedString(after)
        expectedAfter.font = .system(size: 12)
        try withMounted(
            PaneContextMessageText(
                value: .init(row: row), octiconLoader: .init(resourceBundle: .main), onDetails: {},
                onBodyGeometry: { _, _ in })
        ) { actual in
            try withMounted(
                VStack(alignment: .leading, spacing: 4) {
                    Text(expectedProse + expectedCode + expectedAfter).font(.system(size: 12))
                        .lineSpacing(2).foregroundStyle(.primary).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Now").font(.system(size: 12)).foregroundStyle(.secondary)
                }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ) { reference in
                let actualPixels = try pixels(actual)
                let expectedPixels = try pixels(reference)
                #expect(actualPixels == expectedPixels, "Code spans must survive the actual prepared text renderer")
            }
        }
    }

    @Test("A native plain button-toggle paints only its shared SidebarChip", arguments: [false, true])
    func nativeChipToggleHasNoSecondPlate(selected: Bool) throws {
        let chip = SidebarChip(
            octiconLoader: .init(resourceBundle: .main), text: "Needs you 1", style: .neutral, isSelected: selected,
            paint: .popover)
        try withMounted(
            Toggle(isOn: .constant(selected)) { chip }.toggleStyle(.button).buttonStyle(.plain)
        ) { actual in
            try withMounted(chip) { reference in
                print("CHIP_PLATE_SCALE", selected, actual.window?.backingScaleFactor ?? 0)
                let actualPixels = try pixels(actual)
                let referencePixels = try pixels(reference)
                #expect(actualPixels == referencePixels, "The native toggle must add no bezel or clip chip paint")
            }
        }
    }

    @Test("SidebarChip keeps its capsule outline inside the painted bounds", arguments: [false, true])
    func chipOutlineStaysInsideItsBounds(selected: Bool) throws {
        try withMounted(
            SidebarChip(
                octiconLoader: .init(resourceBundle: .main), text: "Needs you 1", style: .neutral,
                isSelected: selected, paint: .popover)
        ) { actual in
            try withMounted(referenceSidebarChip(selected: selected)) { reference in
                try recordPaintReview(actual, name: "chip-\(selected)-actual")
                try recordPaintReview(reference, name: "chip-\(selected)-reference")
                let actualPixels = try pixels(actual)
                let referencePixels = try pixels(reference)
                #expect(actualPixels == referencePixels, "Centered strokes may not escape the shared chip's bounds")
                if actualPixels != referencePixels {
                    recordChipPixelDifference(actualPixels, referencePixels, view: actual)
                }
            }
        }
    }

    private func recordPaintReview(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_PAINT_REFERENCE_DIR"] else { return }
        let output = URL(filePath: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appending(path: name + ".png"))
    }

    private func recordChipPixelDifference(_ actual: Data, _ reference: Data, view: NSView) {
        let width = Int(view.bounds.width * (view.window?.backingScaleFactor ?? 1))
        guard width > 0, actual.count == reference.count else {
            print("CHIP_PIXEL_DIFFERENCE incompatible raster dimensions", actual.count, reference.count)
            return
        }
        let actualBytes = [UInt8](actual)
        let referenceBytes = [UInt8](reference)
        let differing = actualBytes.indices.filter { actualBytes[$0] != referenceBytes[$0] }
        print(
            "CHIP_PIXEL_DIFFERENCE", "width", width, "bytes", differing.count,
            "maximum", differing.map { abs(Int(actualBytes[$0]) - Int(referenceBytes[$0])) }.max() ?? 0,
            "first",
            differing.prefix(8).map { "\($0 / 4 % width),\($0 / 4 / width):\(actualBytes[$0])/\(referenceBytes[$0])" })

    }

    private func referenceSidebarChip(selected: Bool) -> some View {
        // Fill and ring share paint bounds; a separate overlay can round colors differently at 1x.
        Text("Needs you 1")
            .font(.system(size: AppStyles.Shell.Sidebar.chipFontSize, weight: .medium).monospacedDigit())
            .padding(.horizontal, AppStyles.Shell.Sidebar.chipHorizontalPadding)
            .frame(height: AppStyles.Shell.Sidebar.chipLineHeight)
            .background {
                Capsule(style: .circular).fill(
                    selected
                        ? Color(nsColor: .selectedContentBackgroundColor)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay {
                    Capsule(style: .circular).strokeBorder(
                        selected
                            ? Color(nsColor: .controlAccentColor)
                            : Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .foregroundStyle(
                selected
                    ? Color(nsColor: .alternateSelectedControlTextColor)
                    : Color.secondary.opacity(AppStyles.Shell.Sidebar.chipForegroundOpacity)
            )
            .fixedSize(horizontal: true, vertical: true)
    }

    @Test
    func contentHeadingPaintsSentenceCaseAndNeutralCountWithoutChip() throws {
        try withMounted(PopoverPanelSectionHeader("Needs you", variant: .content(count: 3))) { actual in
            try withMounted(
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Needs you").font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    Text("3").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            ) { reference in
                let actualPixels = try pixels(actual)
                let expectedPixels = try pixels(reference)
                #expect(actualPixels == expectedPixels, "N2 heading must carry neutral text, no glyph/chip/uppercase")
            }
        }
    }

    @ViewBuilder private func referenceAction(
        _ role: ActionRole, loader: OcticonLoader, tooltip: ControlTooltipRenderValue
    ) -> some View {
        switch role {
        case .utility, .rowDismiss:
            ToolbarActionButton(
                presentation: .init(
                    icon: .system("terminal"), label: "Action", identifier: "reference",
                    tooltip: tooltip, isEnabled: true, content: .icon(label: role == .utility ? "Action" : nil),
                    selection: .normal),
                octiconLoader: loader, action: {})
        case .alternative, .commit:
            Text("Action").font(.system(size: 12, weight: role == .commit ? .medium : .regular))
                .foregroundStyle(
                    role == .commit ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary
                )
                .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            role == .commit
                                ? Color(nsColor: .controlAccentColor) : Color(nsColor: .controlBackgroundColor)
                        )
                        .overlay {
                            if role == .alternative {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
                            }
                        }
                }
        }
    }

    private func withMounted<Content: View>(_ content: Content, assertions: (NSView) throws -> Void) throws {
        let host = NSHostingView(
            rootView: content.frame(width: 300, height: 140, alignment: .topLeading)
                .background(Color.black).environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        try assertions(host)
    }

    private func findButton(in view: NSView) -> AccessibilityPressBridgeView? {
        if let button = view as? AccessibilityPressBridgeView { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }

    private func pixels(_ view: NSView) throws -> Data {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }
}
