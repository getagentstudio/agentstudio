import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioRepoExplorer

extension PaneContextToolbarRenderingTests {
    @Test(
        "a long toolbar message keeps the complete age visible and advances in the same host",
        arguments: [480.0, 1000.0])
    func toolbarMessageAgeDoesNotTruncate(width: Double) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let pane = PaneId.generateUUIDv7()
            let detail = AgentLineDetail(
                summary: String(repeating: "W", count: 200), refs: [], writer: .pane(pane),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation, pane: { _ in nil })
            atoms.paneContextPresentation.apply([
                pane: .set(
                    .init(
                        revision: .init(1), agentTitle: nil, agentLine: detail,
                        own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
            ])
            try await withMountedToolbar(pane: pane, readers: readers, width: width) { mounted in
                let identity = ObjectIdentifier(mounted.host)
                let controls = buttonFrames(in: mounted.host)
                try expectFullAge("[2 min ago]", in: mounted, width: width)
                let clock = try #require(mounted.clock)

                clock.advance(by: .seconds(55))
                try await clock.registered(
                    clock.now.advanced(by: .seconds(60)), pane: pane.uuid, currentInput: nil)
                try await clock.applied(pane: pane.uuid, input: nil)

                mounted.host.layoutSubtreeIfNeeded()
                mounted.host.displayIfNeeded()
                #expect(ObjectIdentifier(mounted.host) == identity)
                #expect(buttonFrames(in: mounted.host) == controls)
                try expectFullAge("[3 min ago]", in: mounted, width: width)
                for (advance, next, expectedAge) in [
                    (3420, 3600, "[1 hr ago]"), (82_800, 86_400, "[1 day ago]"), (86_400, 86_400, "[2 days ago]"),
                ] {
                    clock.advance(by: .seconds(advance))
                    try await clock.registered(
                        clock.now.advanced(by: .seconds(next)), pane: pane.uuid, currentInput: nil)
                    try await clock.applied(pane: pane.uuid, input: nil)
                    mounted.host.layoutSubtreeIfNeeded()
                    mounted.host.displayIfNeeded()
                    try expectFullAge(expectedAge, in: mounted, width: width)
                    #expect(ObjectIdentifier(mounted.host) == identity)
                    #expect(buttonFrames(in: mounted.host) == controls)
                }
                #expect(atoms.paneContextPresentation.value(for: pane)?.agentLine == detail)
            }
            atoms.paneContextPresentation.remove([pane])
        }
    }

    func expectFullAge(_ text: String, in mounted: PaneContextToolbarTestHost, width: Double) throws {
        let reference = mountCard(
            AnyView(
                Text(text).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                    .foregroundStyle(Color.secondary).fixedSize()), width: nil)
        defer { reference.window.close() }
        let referenceInk = try ink(in: reference.host, minimumBrightness: 60)
        #expect(referenceInk.mask.contains(true))
        let paintsWholeAge = containsTextInk(referenceInk, in: try ink(in: mounted.host, minimumBrightness: 60))
        if !paintsWholeAge {
            recordAgeFailure(mounted.host, name: "actual-\(Int(width))-\(text)")
            recordAgeFailure(reference.host, name: "reference-\(Int(width))-\(text)")
        }
        #expect(paintsWholeAge, "The complete literal age must paint even when the message is truncated")
        let ageView = try #require(findAgeView(in: mounted.host))
        let rect = mounted.host.convert(ageView.bounds, from: ageView)
        #expect(ageView.accessibilityLabel() == text)
        #expect(
            rect.width >= reference.host.fittingSize.width - 0.5,
            "The whole age needs its intrinsic width; AX text alone does not prove visible text")
        #expect(rect.minX >= 0 && rect.maxX <= width)
        let controls = buttonFrames(in: mounted.host)
        let leading: Set<String> = [
            "paneSurfaceToolbar.drawerToggle", "paneSurfaceToolbar.drawerAdd",
            "paneSurfaceToolbar.pinPane", "paneSurfaceToolbar.note",
        ]
        let middleStart = try #require(controls.filter { leading.contains($0.key) }.values.map(\.maxX).max())
        let middleEnd = try #require(controls.filter { !leading.contains($0.key) }.values.map(\.minX).min())
        #expect(rect.maxX <= middleEnd)
        let textView = try #require(findLineTextView(in: mounted.host))
        let textRect = mounted.host.convert(textView.bounds, from: textView)
        #expect(textRect.width <= 360)
        #expect(
            abs(rect.minX - textRect.maxX) < 0.5, "The age carries its one leading space: age \(rect), text \(textRect)"
        )
        #expect(textRect.minX > middleStart)

    }

    private func recordAgeFailure(_ host: NSView, name: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        Attachment.record(Array(png), named: name + ".png")
        let directory = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
            .appending(path: "tmp/handback")
        try? png.write(to: directory.appending(path: "p3-age-" + name + ".png"))
    }

    private func findLineTextView(in view: NSView) -> AccessibilityLabelBridgeView? {
        if let label = view as? AccessibilityLabelBridgeView,
            label.accessibilityIdentifier() == "paneContext.agentLine.text"
        {
            return label
        }
        return view.subviews.lazy.compactMap { findLineTextView(in: $0) }.first
    }

    private func findAgeView(in view: NSView) -> AccessibilityLabelBridgeView? {
        if let label = view as? AccessibilityLabelBridgeView,
            label.accessibilityIdentifier() == "paneContext.agentLine.age"
        {
            return label
        }
        return view.subviews.lazy.compactMap { findAgeView(in: $0) }.first
    }
}
