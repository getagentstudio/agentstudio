import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite(.serialized)
struct PaneContextPopoverRedesignTests {
    enum ActionRole: CaseIterable { case utility, rowDismiss, alternative, commit }

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
            // D85's accepted shared selected variant: blue15%fill and blue outline; existing24ptform geometry.
            let accent = Color(.sRGB, red: 64 / 255.0, green: 156 / 255.0, blue: 1)
            try withMounted(
                HStack(spacing: 4) {
                    Text("Details")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12)).foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.15))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(accent, lineWidth: 1) }
                }
            ) { reference in
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
                    role == .commit ? Color(.sRGB, red: 29 / 255.0, green: 31 / 255.0, blue: 33 / 255.0) : Color.primary
                )
                .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(role == .commit ? Color(.sRGB, red: 64 / 255.0, green: 156 / 255.0, blue: 1) : .clear)
                        .overlay {
                            if role == .alternative {
                                RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18))
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
