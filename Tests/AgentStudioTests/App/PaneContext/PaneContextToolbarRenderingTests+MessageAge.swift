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
            atoms.paneContextPresentation.apply([
                pane: .set(
                    .init(
                        revision: .init(1), agentTitle: nil, agentLine: detail,
                        own: .zero, includingDrawers: .zero, pullRequests: .notApplicable))
            ])
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation, pane: { _ in nil })
            try await withMountedToolbar(pane: pane, readers: readers, width: width) { mounted in
                let identity = ObjectIdentifier(mounted.host)
                let controls = buttonFrames(in: mounted.host)
                try expectFullAge("[2 min ago]", in: mounted, width: width)
                let clock = try #require(mounted.clock)

                clock.advance(by: .seconds(55))
                try await clock.registered(
                    clock.now.advanced(by: .seconds(60)), pane: pane.uuid, currentInput: nil)

                mounted.host.layoutSubtreeIfNeeded()
                mounted.host.displayIfNeeded()
                #expect(ObjectIdentifier(mounted.host) == identity)
                #expect(buttonFrames(in: mounted.host) == controls)
                try expectFullAge("[3 min ago]", in: mounted, width: width)
                #expect(atoms.paneContextPresentation.value(for: pane)?.agentLine == detail)
            }
            atoms.paneContextPresentation.remove([pane])
        }
    }

    private func expectFullAge(_ text: String, in mounted: PaneContextToolbarTestHost, width: Double) throws {
        let reference = mountCard(
            AnyView(
                Text(text).font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                    .foregroundStyle(Color.secondary).fixedSize()), width: nil)
        defer { reference.window.close() }
        let referenceInk = try ink(in: reference.host, minimumBrightness: 60)
        #expect(referenceInk.mask.contains(true))
        #expect(
            containsTextInk(referenceInk, in: try ink(in: mounted.host, minimumBrightness: 60)),
            "The complete literal age must paint even when the message is truncated")
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
        #expect(rect.maxX <= min(middleEnd, middleStart + 360 + AppStyles.Shell.DrawerToolbar.trailingClusterSpacing))

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
