import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

@MainActor
@Suite(.serialized)
struct PaneManagementIdentityHostTests {
    @Test(
        "the same native card advances, replaces activity and retires its task on hide", arguments: [false, true])
    func nativeHostOwnsActivityDeadlineLifetime(forwardingAlreadyCompleted: Bool) async throws {
        let fixture = try await NativeCardFixture()
        let clock = fixture.rendering.clock
        let origin = clock.now
        do {
            try fixture.expectRendered(text: "Now")
            let identity = ObjectIdentifier(fixture.host)
            try await fixture.rendering.advance(by: .seconds(60), registeredAt: origin.advanced(by: .seconds(60)))
            #expect(ObjectIdentifier(fixture.host) == identity)
            try fixture.expectRendered(text: "1 min ago")
            try await fixture.replaceActivity(forwardingAlreadyCompleted: forwardingAlreadyCompleted)
            #expect(ObjectIdentifier(fixture.host) == identity)
            try fixture.expectRendered(text: "Now")
            // Canonical activity is background input: its trailing execution is at70s.
            // The replacement's own next age boundary remains120s, not the old timestamp.
            try await fixture.rendering.advance(by: .seconds(50), registeredAt: origin.advanced(by: .seconds(120)))
            #expect(ObjectIdentifier(fixture.host) == identity)
            try fixture.expectRendered(text: "1 min ago")
            try await fixture.rendering.hide()
            try fixture.expectHidden()
            clock.advance(by: .seconds(300))
            try fixture.expectHidden()
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

@MainActor
private final class NativeCardFixture {
    let rendering: PaneManagementPreparedCardHarness
    let context: PaneManagementContext
    let loader: OcticonLoader
    let store: WorkspaceStore
    private let atoms: CoreAtoms
    private let ports: PaneContextPopoverTestPorts
    private let orderingOrigin = ContinuousClock.now
    private let origin: TestPushClock.Instant
    private var closed = false
    var host: NSHostingView<AnyView> { rendering.host }

    init() async throws {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        self.atoms = atoms
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        self.store = store
        let pane = store.createPane(title: "Clock proof")
        let paneId = PaneId(existingUUID: pane.id)
        context = .project(paneId: pane.id, store: store)
        loader = makeTestOcticonLoader()
        let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: paneId))
        self.ports = ports
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        atoms.paneActivityTime.apply([
            .set(
                pane.id,
                .init(
                    orderingInstant: orderingOrigin,
                    wallTime: Date(timeIntervalSince1970: 1_800_000_000), source: .terminal))
        ])
        var owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: atoms.paneContextPresentation,
            pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
        owners.activity = { atoms.paneActivityTime.value(for: $0.uuid) }
        do {
            rendering = try await PaneManagementPreparedCardHarness(
                context: context, owners: owners,
                wallNow: Date(timeIntervalSince1970: 1_800_000_000), height: 320)
        } catch {
            try? await ports.finish()
            atoms.paneActivityTime.apply([.remove(pane.id)])
            store.removePane(pane.id)
            throw error
        }
        origin = rendering.clock.now
        do { try await rendering.open() } catch {
            try? await close()
            throw error
        }
    }

    func replaceActivity(forwardingAlreadyCompleted: Bool) async throws {
        let checkpoint = rendering.prepared.bridge.receivedInputs
        let elapsed = origin.duration(to: rendering.clock.now)
        atoms.paneActivityTime.apply([
            .set(
                context.paneId,
                .init(
                    orderingInstant: orderingOrigin.advanced(by: elapsed),
                    wallTime: rendering.time.now, source: .terminal))
        ])
        if forwardingAlreadyCompleted {
            let handle = try #require(rendering.prepared.cardHandle)
            let inputs = rendering.prepared.bindings.inputs
            for producer in inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
                await producer.value
            }
            try #require(inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch).isEmpty)
        }
        try await rendering.canonicalChangeCompleted(since: checkpoint)
    }
    func expectRendered(text: String) throws {
        let elements = PaneIdentityCardFixture.elements(in: host)
        #expect(elements.contains { $0.label == "ACTIVE \(text)" }, "The mounted metadata age must match exactly")
        try PaneIdentityCardFixture.expectContained(in: host)
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.clock), octiconLoader: loader,
                text: text == "Now" ? "Now" : "1m", style: .accent(AppStyles.Shell.Sidebar.chipInfoColor)),
            present: false, name: "clock-\(text)")
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.playCircleFill), octiconLoader: loader,
                text: nil, style: .accent(.accentColor)), present: false, name: "active-\(text)")
    }
    func expectHidden() throws {
        #expect(PaneIdentityCardFixture.frames(in: host)["container"] == nil)
        #expect(!(try PaneManagementIdentityTestInk.ink(in: host, maximumX: nil)).points.contains(true))
    }
    func close() async throws {
        guard !closed else { return }
        closed = true
        do {
            try await rendering.close()
            try await ports.finish()
            atoms.paneActivityTime.apply([.remove(context.paneId)])
            store.removePane(context.paneId)
        } catch {
            try? await ports.finish()
            atoms.paneActivityTime.apply([.remove(context.paneId)])
            store.removePane(context.paneId)
            throw error
        }
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
