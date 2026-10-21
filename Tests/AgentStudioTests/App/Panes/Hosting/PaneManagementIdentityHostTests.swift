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
            try fixture.expectRendered(text: "Now", active: true)
            let hostIdentity = ObjectIdentifier(fixture.host)

            clock.advance(by: .seconds(60))

            let secondDeadline = firstDeadline.advanced(by: .seconds(60))
            try await clock.registered(secondDeadline, pane: pane, currentInput: initialInput)
            #expect(ObjectIdentifier(fixture.host) == hostIdentity)
            try fixture.expectRendered(text: "1m", active: false)

            let replacementInput = clock.now
            fixture.replaceActivity()
            let replacement = try await clock.nextOperation(pane: pane, input: replacementInput)
            // A wrong key returns unchanged: fail before awaiting any terminal worker fact.
            try #require(
                replacement == .replaced(cancelRequested: true), "Native replacement must request cancellation")
            try await clock.replacedWorkers(pane: pane, oldInput: initialInput, newInput: replacementInput)
            try await clock.registered(
                secondDeadline, pane: pane, currentInput: replacementInput, retiredInput: initialInput)
            #expect(clock.pendingSleepCount == 1)
            try fixture.expectRendered(text: "Now", active: true)

            // The old worker has ended and the new worker registered its own deadline.
            // Only now advance through the former deadline to exclude stale publication.
            clock.advance(by: .seconds(60))
            let thirdDeadline = secondDeadline.advanced(by: .seconds(60))
            try await clock.registered(
                thirdDeadline, pane: pane, currentInput: replacementInput, retiredInput: initialInput)
            #expect(ObjectIdentifier(fixture.host) == hostIdentity)
            try fixture.expectRendered(text: "1m", active: false)

            fixture.hide()
            let hidden = try await clock.nextHideResult()
            // An omitted cancel returns requested=false instead of stranding a wait.
            try #require(hidden == .cancelled(requested: true), "Native hide must request cancellation")
            try await clock.cancelledWorker(pane: pane, input: replacementInput)
            #expect(clock.pendingSleepCount == 0)
            let hiddenPixels = try fixture.pixels()
            clock.advance(by: .seconds(300))
            #expect(try fixture.pixels() == hiddenPixels)
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
                    context: context, octiconLoader: loader, store: store, clock: clock,
                    onRelativeTimeEvent: { clock.observeOwner($0) })
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

    init() {
        let clock = NativeCardTestClock()
        let visibility = NativeCardVisibility()
        self.clock = clock
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
            .set(pane.id, .init(orderingInstant: clock.now, wallTime: .now, source: .terminal))
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
        atoms.paneActivityTime.apply([
            .set(context.paneId, .init(orderingInstant: clock.now, wallTime: .now, source: .terminal))
        ])
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func hide() {
        visibility.isVisible = false
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func expectRendered(text: String, active: Bool) throws {
        // The expected clock text and active glyph are literal. Only unrelated
        // title/identity content is shared with the real context in this reference.
        let reference = NSHostingView(
            rootView: AnyView(
                ManagementPaneIdentityStrip(
                    context: context, octiconLoader: loader, lines: [.title("Clock proof")],
                    recencyText: text, recencyTier: .strongBlue, isActive: active
                )
                .frame(maxWidth: .infinity)
                .background(AppStyles.Shell.PaneChrome.background)
                .frame(width: 1000, height: 320, alignment: .topLeading)
                .background(Color.black)
                .environment(\.colorScheme, .dark)))
        reference.frame = host.frame
        let referenceWindow = NSWindow(
            contentRect: reference.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        referenceWindow.isReleasedWhenClosed = false
        referenceWindow.appearance = NSAppearance(named: .darkAqua)
        referenceWindow.contentView = reference
        referenceWindow.orderFront(nil)
        defer {
            referenceWindow.contentView = nil
            referenceWindow.close()
        }
        #expect(
            try pixels() == Self.pixels(in: reference),
            "The actual mounted card must paint \(text) and active=\(active), including the active glyph")
        // A second oracle bypasses the strip entirely: otherwise a strip that
        // ignored its recency/active arguments could make both sides equally wrong.
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.clock), octiconLoader: loader, text: text,
                style: .accent(AppStyles.Shell.Sidebar.chipInfoColor)), present: true, name: "clock-\(text)")
        try expectIndependentChip(
            SidebarChip(
                icon: .system(.playCircleFill), octiconLoader: loader,
                text: nil, style: .accent(.accentColor)), present: active, name: "active-\(text)")
    }

    func pixels() throws -> Data { try Self.pixels(in: host) }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        atoms.paneActivityTime.apply([.remove(context.paneId)])
        store.removePane(context.paneId)
    }

    private static func pixels(in view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
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
        let needle = try Self.ink(in: reference, maximumX: nil)
        #expect(needle.points.contains(true), "Independent chip reference must contain actual glyph/text ink")
        let found = Self.contains(needle, in: try Self.ink(in: host, maximumX: 360))
        #expect(found == present, "Independent \(name) chip ink must be present=\(present)")
    }

    private static func ink(in view: NSView, maximumX: Int?) throws -> (width: Int, height: Int, points: [Bool]) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let pixelsPerPoint = image.width / Int(view.bounds.width)
        let width = min(image.width, (maximumX ?? Int(view.bounds.width)) * pixelsPerPoint)
        var points: [Bool] = []
        for row in 0..<image.height {
            for column in 0..<width {
                let offset = (row * image.width + column) * 4
                points.append(max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2])) > 100)
            }
        }
        return (width, image.height, points)
    }

    private static func contains(
        _ needle: (width: Int, height: Int, points: [Bool]),
        in haystack: (width: Int, height: Int, points: [Bool])
    ) -> Bool {
        let ink = needle.points.indices.filter { needle.points[$0] }.map {
            (x: $0 % needle.width, y: $0 / needle.width)
        }
        guard !ink.isEmpty, needle.width <= haystack.width, needle.height <= haystack.height else { return false }
        let minimumX = ink.map(\.x).min()!
        let maximumX = ink.map(\.x).max()!
        let minimumY = ink.map(\.y).min()!
        let maximumY = ink.map(\.y).max()!
        let width = maximumX - minimumX + 1
        let height = maximumY - minimumY + 1
        let allowedMisses = width * height / 20
        for originY in 0...(haystack.height - height) {
            for originX in 0...(haystack.width - width) {
                var misses = 0
                for row in 0..<height {
                    for column in 0..<width {
                        let expected = needle.points[(minimumY + row) * needle.width + minimumX + column]
                        let actual = haystack.points[(originY + row) * haystack.width + originX + column]
                        if expected != actual {
                            misses += 1
                            if misses > allowedMisses { break }
                        }
                    }
                    if misses > allowedMisses { break }
                }
                if misses <= allowedMisses { return true }
            }
        }
        return false
    }
}
