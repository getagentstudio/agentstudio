import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioSharedComponents

@MainActor
@Suite("Shared popover latched height writes", .serialized)
struct PopoverPanelHeightNativeTests {
    @Test(
        "Prepared two-width content revisions do not write unused row heights after opening", arguments: [false, true])
    func latchedShellDiscardsLaterRowsMeasurements(fixedHeight: Bool) throws {
        let mount = PopoverHeightRevisionMount(fixedHeight: fixedHeight)
        defer { mount.close() }
        try mount.publish(.init(number: 0, width: 480, rowsHeight: 80))
        let openingHeight = mount.host.fittingSize.height
        try #require(openingHeight > 0)
        if !fixedHeight { try #require(openingHeight < 480) }
        try #require(Set(mount.writes.map(\.region)) == [.header, .rows, .footer])
        let openingWrites = mount.writes.count

        // Each native publication finishes before the next width is supplied. The first growth
        // proves that the opening latch is already active: an unlatched shell would grow to 480.
        for publication in [
            PopoverHeightRevisionMount.Publication(number: 1, width: 480, rowsHeight: 1192),
            .init(number: 2, width: 463, rowsHeight: 1206),
            .init(number: 3, width: 463, rowsHeight: 1176),
            .init(number: 4, width: 463, rowsHeight: 1206),
        ] {
            try mount.publish(publication)
            #expect(mount.host.fittingSize.height == openingHeight)
        }
        let laterRows = mount.writes.dropFirst(openingWrites).filter { $0.region == .rows }
        #expect(laterRows.isEmpty, "A latched viewport does not consume later rows-height state writes: \(laterRows)")
        #expect(mount.writes.count <= 6, "The original S6 total-height-write bound remains unchanged")
        let previousOpening = mount.opening
        try mount.reopen(.init(number: 5, width: 463, rowsHeight: 100))
        #expect(mount.opening != previousOpening)
        #expect(mount.writes.contains { $0.opening == mount.opening && $0.region == .rows })
        if !fixedHeight { #expect(mount.host.fittingSize.height != openingHeight) }
    }
}

/// Publishes explicit caller content values to the real shared shell. No domain projection is replaced.
@MainActor
private final class PopoverHeightRevisionMount {
    struct Publication {
        let number: Int
        let width: CGFloat
        let rowsHeight: CGFloat
    }

    struct HeightWrite: CustomStringConvertible {
        let opening: Int
        let publication: Int
        let width: CGFloat
        let region: PaneContextPopoverHeightWrite.Region
        let height: CGFloat
        var description: String {
            "opening=\(opening) publication=\(publication) width=\(width) \(region)=\(height)"
        }
    }

    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let window: NSWindow
    private let fixedHeight: Bool
    private var publication = Publication(number: 0, width: 480, rowsHeight: 80)
    private(set) var opening = 0
    private(set) var writes: [HeightWrite] = []

    init(fixedHeight: Bool) {
        _ = NSApplication.shared
        self.fixedHeight = fixedHeight
        window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(.init(x: -10_000, y: -10_000))
        host.frame = .init(x: 0, y: 0, width: 560, height: 600)
        window.contentView = host
        window.orderFront(nil)
    }

    func publish(_ next: Publication) throws {
        publication = next
        print("POPOVER_HEIGHT_PUBLICATION begin", opening, next.number, next.width, next.rowsHeight)
        host.rootView = root()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let content = try #require(findContent(in: host), "Native publication did not apply its content")
        try #require(content.bounds.width == next.width && content.bounds.height == next.rowsHeight)
        print("POPOVER_HEIGHT_PUBLICATION applied", opening, next.number, content.bounds, host.fittingSize)
    }

    func reopen(_ next: Publication) throws {
        window.contentView = nil
        window.orderOut(nil)
        opening += 1
        host.rootView = AnyView(EmptyView())
        window.contentView = host
        window.orderFront(nil)
        try publish(next)
    }

    private func root() -> AnyView {
        let recordHeightWrite: @MainActor (PaneContextPopoverHeightWrite) -> Void = { [weak self] value in
            guard let self else { return }
            let write = HeightWrite(
                opening: opening, publication: publication.number, width: publication.width,
                region: value.region, height: value.height)
            writes.append(write)
            print("POPOVER_HEIGHT_WRITE", write)
        }
        return AnyView(
            PopoverPanel(
                width: 560, height: fixedHeight ? .fixed(480) : .contentSized(maximumHeight: 480),
                onHeightWrite: recordHeightWrite
            ) {
                Color.clear.frame(height: 20)
            } content: {
                Color.clear.frame(width: publication.width, height: publication.rowsHeight)
                    .background {
                        AccessibilityLabelBridge(identifier: "popover-height-revision-content", label: "", role: .group)
                    }
            } footer: {
                Color.clear.frame(height: 20)
            }
            .id(opening))
    }

    private func findContent(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "popover-height-revision-content" { return view }
        for child in view.subviews {
            if let found = findContent(in: child) { return found }
        }
        return nil
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
