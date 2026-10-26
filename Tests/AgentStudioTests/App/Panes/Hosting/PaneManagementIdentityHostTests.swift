import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Observation
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityHostTests {
    @Test("the same native card advances, replaces activity and retires its task on hide")
    func nativeHostOwnsActivityDeadlineLifetime() async throws {
        let fixture = NativeCardFixture()
        let clock = fixture.clock
        let pane = fixture.context.paneId
        let initialInput = clock.now
        do {
            try #require(try await clock.nextOperation(pane: pane, input: initialInput) == .started)
            try await clock.entered(pane: pane, input: initialInput)
            let firstDeadline = initialInput.advanced(by: .seconds(60))
            try await clock.registered(firstDeadline, pane: pane, currentInput: initialInput)
            try await clock.applied(pane: pane, input: initialInput)
            try fixture.expectRendered(text: "Now")
            let hostIdentity = ObjectIdentifier(fixture.host)

            clock.advance(by: .seconds(60))

            let secondDeadline = firstDeadline.advanced(by: .seconds(60))
            try await clock.registered(secondDeadline, pane: pane, currentInput: initialInput)
            try await clock.applied(pane: pane, input: initialInput)
            #expect(ObjectIdentifier(fixture.host) == hostIdentity)
            try fixture.expectRendered(text: "1 min ago")

            let replacementInput = clock.now
            fixture.replaceActivity()
            let replacement = try await clock.nextOperation(pane: pane, input: replacementInput)
            // A wrong key returns unchanged: fail before awaiting any terminal worker fact.
            try #require(
                replacement == .replaced(cancelRequested: true), "Native replacement must request cancellation")
            try await clock.replacedWorkers(pane: pane, oldInput: initialInput, newInput: replacementInput)
            try await clock.registered(
                secondDeadline, pane: pane, currentInput: replacementInput, retiredInput: initialInput)
            try await clock.applied(pane: pane, input: replacementInput)
            #expect(clock.pendingSleepCount == 1)
            try fixture.expectRendered(text: "Now")

            // The old worker has ended and the new worker registered its own deadline.
            // Only now advance through the former deadline to exclude stale publication.
            clock.advance(by: .seconds(60))
            let thirdDeadline = secondDeadline.advanced(by: .seconds(60))
            try await clock.registered(
                thirdDeadline, pane: pane, currentInput: replacementInput)
            try await clock.applied(pane: pane, input: replacementInput)
            #expect(ObjectIdentifier(fixture.host) == hostIdentity)
            try fixture.expectRendered(text: "1 min ago")

            fixture.hide()
            let hidden = try await clock.nextHideResult()
            // An omitted cancel returns requested=false instead of stranding a wait.
            try #require(hidden == .cancelled(requested: true), "Native hide must request cancellation")
            try await clock.cancelledWorker(pane: pane, input: replacementInput)
            #expect(clock.pendingSleepCount == 0)
            try fixture.expectHidden()
            clock.advance(by: .seconds(300))
            try fixture.expectHidden()
            try await clock.finish()
            fixture.close()
        } catch {
            fixture.hide()
            try? await clock.retire()
            try? await clock.facts.finish()
            fixture.close()
            throw error
        }
    }
}

@MainActor
@Observable
private final class NativeCardVisibility {
    var isVisible = true
    var wallDate = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private struct NativeCardRoot: View {
    let visibility: NativeCardVisibility
    let context: PaneManagementContext
    let store: WorkspaceStore
    let loader: OcticonLoader
    let clock: NativeCardTestClock

    var body: some View {
        Group {
            if visibility.isVisible {
                ManagementPaneIdentityOverlay(
                    context: context, octiconLoader: loader, store: store, clock: clock, wallNow: visibility.wallDate,
                    onRelativeTimeEvent: { clock.observeOwner($0) },
                    onRelativeTimeReady: { clock.observePreparation($0, id: $1) })
            }
        }
        .frame(width: 1000, height: 320, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
private final class NativeCardFixture {
    let clock: NativeCardTestClock
    let visibility: NativeCardVisibility
    let store: WorkspaceStore
    let context: PaneManagementContext
    let loader: OcticonLoader
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let atoms: CoreAtoms
    private let initialInstant: ContinuousClock.Instant

    init() {
        let clock = NativeCardTestClock()
        let visibility = NativeCardVisibility()
        self.clock = clock
        initialInstant = clock.now
        self.visibility = visibility
        // SwiftUI may evaluate outside the calling TaskLocal scope. Use the isolated
        // process's installed atom scope for both capture and native graph evaluation.
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        self.atoms = atoms
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        self.store = store
        let pane = store.createPane(title: "Clock proof")
        let context = PaneManagementContext.project(paneId: pane.id, store: store)
        self.context = context
        let loader = makeTestOcticonLoader()
        self.loader = loader
        atoms.paneActivityTime.apply([
            .set(pane.id, .init(orderingInstant: clock.now, wallTime: visibility.wallDate, source: .terminal))
        ])
        let root = NativeCardRoot(visibility: visibility, context: context, store: store, loader: loader, clock: clock)
        let host = NSHostingView(rootView: AnyView(root))
        self.host = host
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 320)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    func replaceActivity() {
        let elapsed = initialInstant.duration(to: clock.now).components
        let date = Date(timeIntervalSince1970: 1_800_000_000)
            .addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        visibility.wallDate = date
        atoms.paneActivityTime.apply([
            .set(context.paneId, .init(orderingInstant: clock.now, wallTime: date, source: .terminal))
        ])
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func hide() {
        visibility.isVisible = false
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func expectRendered(text: String) throws {
        let elements = PaneIdentityCardFixture.elements(in: host)
        #expect(elements.contains { $0.label == "ACTIVE \(text)" }, "The mounted metadata age must match exactly")
        try PaneIdentityCardFixture.expectContained(in: host)
        // Independent references reject the retired compact clock and play chips.
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.clock), octiconLoader: loader, text: text == "Now" ? "Now" : "1m",
                style: .accent(AppStyles.Shell.Sidebar.chipInfoColor)), present: false, name: "clock-\(text)")
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.playCircleFill), octiconLoader: loader,
                text: nil, style: .accent(.accentColor)), present: false, name: "active-\(text)")
    }

    func expectHidden() throws {
        #expect(PaneIdentityCardFixture.frames(in: host)["container"] == nil)
        #expect(!(try PaneManagementIdentityTestInk.ink(in: host, maximumX: nil)).points.contains(true))
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        atoms.paneActivityTime.apply([.remove(context.paneId)])
        store.removePane(context.paneId)
    }

    private func expectIndependentChip(_ chip: SidebarChip, present: Bool, name: String) throws {
        let reference = NSHostingView(
            rootView:
                chip
                .background(Color.white.opacity(AppStyles.General.Fill.muted))
                .background(AppStyles.Shell.PaneChrome.background)
                .environment(\.colorScheme, .dark))
        reference.frame = CGRect(origin: .zero, size: reference.fittingSize)
        let window = NSWindow(contentRect: reference.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = reference
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        let needle = try PaneManagementIdentityTestInk.ink(in: reference, maximumX: nil)
        #expect(needle.points.contains(true), "Independent chip reference must contain actual glyph/text ink")
        let found = PaneManagementIdentityTestInk.contains(
            needle, in: try PaneManagementIdentityTestInk.ink(in: host, maximumX: nil))
        #expect(found == present, "Independent \(name) chip ink must be present=\(present)")
    }

}
