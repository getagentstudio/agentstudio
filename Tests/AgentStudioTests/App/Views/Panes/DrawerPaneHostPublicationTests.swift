import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct DrawerPaneHostPublicationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("visible drawer mounts its host without collapse and reopen", arguments: [false, true])
    func visibleDrawerMountsLateHost(registerBeforePresentation: Bool) async throws {
        let store = WorkspaceStore(startsObserving: false)
        let parent = store.createPane()
        let tab = Tab(paneId: parent.id)
        store.appendTab(tab)
        let child = try #require(store.addDrawerPane(to: parent.id))
        let registry = ViewRegistry()
        registry.ensureSlot(for: child.id)
        let panel = DrawerPanel(
            layout: DrawerGridLayout(topRow: Layout(paneId: child.id)),
            octiconLoader: makeTestOcticonLoader(),
            parentPaneId: parent.id, tabId: tab.id, activeChildId: child.id,
            minimizedPaneIds: [], closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
            height: 500, store: store, repoCache: RepoCacheAtom(),
            editorChooser: AtomRegistry(core: CoreAtomScope.store).editorChooser,
            viewRegistry: registry, action: { _ in },
            commandDispatcher: AppTerminalFixtureCommandDispatcher(),
            arrangementInlineRenameState: ArrangementInlineRenameState(),
            resizeInteraction: nil, onDismiss: {}, onPaneFocusTrigger: { _ in },
            onFocusParentPane: {}, appLifecycleStore: AppLifecycleAtom(),
            paneInboxPresentation: nil, onOpenPaneGitHub: { _ in },
            dropTarget: nil, dragSourcePaneId: nil)
        let host = PaneHostView(paneId: child.id)
        let content = DrawerPublicationContentView()
        host.mountContentView(content)
        if registerBeforePresentation { registry.register(host, for: child.id) }
        var replacementHost: PaneHostView?
        var panelAppeared = false
        let hosting = NSHostingView(rootView: panel.onAppear { panelAppeared = true })
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            registry.unregister(child.id)
            host.retire()
            replacementHost?.retire()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        await eventually("drawer panel appears before late host registration") {
            drainDrawerPresentationRunLoop()
            hosting.layoutSubtreeIfNeeded()
            return panelAppeared
        }
        try #require(panelAppeared)
        if !registerBeforePresentation {
            #expect(registry.view(for: child.id) == nil)
            registry.register(host, for: child.id)
        }

        await eventually("late drawer host attaches") {
            drainDrawerPresentationRunLoop()
            hosting.layoutSubtreeIfNeeded()
            return host.window === window && !host.bounds.isEmpty
        }
        #expect(host.swiftUIContainer.window === window)
        #expect(content.window === window)
        #expect(host.isDescendant(of: hosting))
        #expect(!content.bounds.isEmpty)

        let replacement = PaneHostView(paneId: child.id)
        replacementHost = replacement
        let replacementContent = DrawerPublicationContentView()
        replacement.mountContentView(replacementContent)
        registry.register(replacement, for: child.id)
        host.retire()
        await eventually("replacement drawer host attaches") {
            drainDrawerPresentationRunLoop()
            hosting.layoutSubtreeIfNeeded()
            return replacement.window === window && !replacement.bounds.isEmpty
        }
        #expect(replacement.isDescendant(of: hosting))
        #expect(replacementContent.window === window)
        #expect(!replacementContent.bounds.isEmpty)
        #expect(host.window == nil)
    }
}

@MainActor
private final class DrawerPublicationContentView: NSView, PaneMountedContent {
    func setContentInteractionEnabled(_: Bool) {}
}

private func drainDrawerPresentationRunLoop() {
    RunLoop.main.perform(inModes: [.default]) { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRunInMode(.defaultMode, 1, true)
}
