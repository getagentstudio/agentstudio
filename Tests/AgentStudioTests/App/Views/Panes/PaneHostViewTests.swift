import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneHostViewTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test
    func paneHost_preservesIdentityAcrossMountedContentSwaps() {
        let paneId = UUID()
        let host = PaneHostView(paneId: paneId)
        let firstMount = TestMountedContentView()
        let secondMount = TestMountedContentView()

        let hostIdentity = ObjectIdentifier(host)
        let containerIdentity = ObjectIdentifier(host.swiftUIContainer)

        host.mountContentView(firstMount)
        host.mountContentView(secondMount)

        #expect(ObjectIdentifier(host) == hostIdentity)
        #expect(ObjectIdentifier(host.swiftUIContainer) == containerIdentity)
        #expect(secondMount.superview === host.contentContainerViewForTesting)
    }

    @Test
    func paneHost_managementLayerShieldStaysOnHostNotMountedContent() {
        let host = PaneHostView(paneId: UUID())
        host.mountContentView(TestMountedContentView())

        #expect(host.interactionShieldForTesting != nil)
        #expect(host.contentContainerViewForTesting.subviews.count == 1)
    }

    @Test
    func paneHost_resolvesTypedMountedContent() {
        let host = PaneHostView(paneId: UUID())
        let mountedContent = TestMountedContentView()
        host.mountContentView(mountedContent)

        #expect(host.mountedContent(as: TestMountedContentView.self) === mountedContent)
        #expect(host.mountedContent(as: NSButton.self) == nil)
    }

    @Test
    func paneHost_notifiesWhenAttachedToWindow() {
        let paneId = UUID()
        let host = PaneHostView(paneId: paneId)
        let mountedContent = TestMountedContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        var attachedPaneId: UUID?
        host.onAttachedToWindow = { attachedPaneId = $0 }
        host.mountContentView(mountedContent)
        window.contentView?.addSubview(host)

        #expect(attachedPaneId == paneId)
    }

    @Test("mounted descendant fitting constraints cannot resize the pane host")
    func mountedDescendantFittingConstraintsCannotResizePaneHost() {
        let expectedSize = NSSize(width: 1000, height: 600)
        let host = PaneHostView(paneId: UUIDv7.generate())
        let mountedContent = TestMountedContentView()
        let sizingPressureView = NSView()
        sizingPressureView.translatesAutoresizingMaskIntoConstraints = false
        mountedContent.addSubview(sizingPressureView)
        host.mountContentView(mountedContent)

        let preferredWidthConstraint = sizingPressureView.widthAnchor.constraint(
            equalTo: mountedContent.widthAnchor,
            constant: -24
        )
        preferredWidthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sizingPressureView.topAnchor.constraint(equalTo: mountedContent.topAnchor, constant: 12),
            sizingPressureView.centerXAnchor.constraint(equalTo: mountedContent.centerXAnchor),
            sizingPressureView.leadingAnchor.constraint(
                greaterThanOrEqualTo: mountedContent.leadingAnchor,
                constant: 12
            ),
            sizingPressureView.trailingAnchor.constraint(
                lessThanOrEqualTo: mountedContent.trailingAnchor,
                constant: -12
            ),
            sizingPressureView.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            sizingPressureView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            preferredWidthConstraint,
        ])

        let hostingView = NSHostingView(
            rootView: PaneViewRepresentable(paneHost: host)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hostingView.frame = NSRect(origin: .zero, size: expectedSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: expectedSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        #expect(host.swiftUIContainer.frame.size == expectedSize)
        #expect(host.frame.size == expectedSize)
        #expect(host.bounds.size == expectedSize)
        #expect(host.contentContainerViewForTesting.frame.size == expectedSize)
        #expect(mountedContent.frame.size == expectedSize)

        let resizedAllocation = NSSize(width: 1200, height: 700)
        window.setContentSize(resizedAllocation)
        hostingView.frame.size = resizedAllocation
        hostingView.layoutSubtreeIfNeeded()

        #expect(host.frame.size == resizedAllocation)
        #expect(host.bounds.size == resizedAllocation)
        #expect(host.contentContainerViewForTesting.frame.size == resizedAllocation)
        #expect(mountedContent.frame.size == resizedAllocation)
    }

    @Test("pane host restores focus after same-window SwiftUI container remount")
    func paneHostRestoresFocusAfterSameWindowSwiftUIContainerRemount() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)

        #expect(window.makeFirstResponder(host))
        #expect(window.firstResponder === host)

        let container = host.swiftUIContainer
        contentView.addSubview(container)

        #expect(window.firstResponder === host)
    }

    @Test("pane host does not override focus taken during same-window remount")
    func paneHostDoesNotOverrideFocusTakenDuringSameWindowRemount() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let otherResponder = TestFocusablePaneView()
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)
        contentView.addSubview(otherResponder)

        #expect(window.makeFirstResponder(host))
        let container = host.swiftUIContainer
        #expect(window.makeFirstResponder(otherResponder))
        contentView.addSubview(container)

        #expect(window.firstResponder === otherResponder)
    }

    @Test("pane host does not restore focus after an intentional clear during remount")
    func paneHostDoesNotRestoreFocusAfterIntentionalClearDuringRemount() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)

        #expect(window.makeFirstResponder(host))
        let container = host.swiftUIContainer
        #expect(window.makeFirstResponder(nil))
        contentView.addSubview(container)

        #expect(window.firstResponder !== host)
    }

    @Test("pane host does not restore focus when remounted in another window")
    func paneHostDoesNotRestoreFocusWhenRemountedInAnotherWindow() throws {
        let sourceWindow = makePaneHostFocusWindow()
        let destinationWindow = makePaneHostFocusWindow()
        defer {
            sourceWindow.close()
            destinationWindow.close()
        }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let sourceContentView = try #require(sourceWindow.contentView)
        let destinationContentView = try #require(destinationWindow.contentView)
        sourceContentView.addSubview(host)

        #expect(sourceWindow.makeFirstResponder(host))
        let container = host.swiftUIContainer
        destinationContentView.addSubview(container)

        #expect(destinationWindow.firstResponder !== host)
    }

    @Test("pane host does not restore focus under a hidden ancestor")
    func paneHostDoesNotRestoreFocusUnderHiddenAncestor() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let hiddenAncestor = NSView(frame: .zero)
        hiddenAncestor.isHidden = true
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)
        contentView.addSubview(hiddenAncestor)

        #expect(window.makeFirstResponder(host))
        let container = host.swiftUIContainer
        hiddenAncestor.addSubview(container)

        #expect(window.firstResponder !== host)
    }

    @Test("pane host clears remount focus memory after one attach")
    func paneHostClearsRemountFocusMemoryAfterOneAttach() throws {
        let sourceWindow = makePaneHostFocusWindow()
        let destinationWindow = makePaneHostFocusWindow()
        defer {
            sourceWindow.close()
            destinationWindow.close()
        }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let otherResponder = TestFocusablePaneView()
        let hiddenAncestor = NSView(frame: .zero)
        hiddenAncestor.isHidden = true
        let sourceContentView = try #require(sourceWindow.contentView)
        sourceContentView.addSubview(host)
        sourceContentView.addSubview(otherResponder)
        sourceContentView.addSubview(hiddenAncestor)

        #expect(sourceWindow.makeFirstResponder(host))
        let container = host.swiftUIContainer
        hiddenAncestor.addSubview(container)
        hiddenAncestor.isHidden = false
        #expect(sourceWindow.firstResponder !== host)

        let stagingView = NSView(frame: .zero)
        stagingView.addSubview(container)
        sourceContentView.addSubview(container)

        #expect(sourceWindow.firstResponder !== host)
    }

    @Test("pane host restores a focused descendant after same-window remount")
    func paneHostRestoresFocusedDescendantAfterSameWindowRemount() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let descendant = TestFocusableMountedContentView()
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)
        host.mountContentView(descendant)

        #expect(window.makeFirstResponder(descendant))
        let container = host.swiftUIContainer
        contentView.addSubview(container)

        #expect(window.firstResponder === descendant)
    }

    @Test("pane host does not restore a removed focused descendant")
    func paneHostDoesNotRestoreRemovedFocusedDescendant() throws {
        let window = makePaneHostFocusWindow()
        defer { window.close() }
        let host = PaneHostView(paneId: UUIDv7.generate())
        let descendant = TestFocusableMountedContentView()
        let contentView = try #require(window.contentView)
        contentView.addSubview(host)
        host.mountContentView(descendant)

        #expect(window.makeFirstResponder(descendant))
        let container = host.swiftUIContainer
        host.unmountContentView()
        contentView.addSubview(container)

        #expect(window.firstResponder !== descendant)
    }
}

@MainActor
private func makePaneHostFocusWindow() -> PaneResponderTrackingWindow {
    let window = PaneResponderTrackingWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: true
    )
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    return window
}

@MainActor
private final class TestFocusablePaneView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class TestFocusableMountedContentView: NSView, PaneMountedContent {
    init() {
        super.init(frame: .zero)
    }

    override var acceptsFirstResponder: Bool { true }

    func setContentInteractionEnabled(_: Bool) {}

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

@MainActor
private final class TestMountedContentView: NSView, PaneMountedContent {
    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setContentInteractionEnabled(_: Bool) {}
}
