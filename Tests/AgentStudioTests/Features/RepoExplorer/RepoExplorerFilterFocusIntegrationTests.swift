import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Observation
import SwiftUI
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Repo Explorer SwiftUI filter focus", .serialized)
struct RepoExplorerFilterFocusIntegrationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("filter Return leaves the production list as first responder after SwiftUI updates")
    func filterReturnRetainsListResponder() async throws {
        let sidebarState = CoreAtomScope.store.workspaceSidebarState
        let previousFilterText = sidebarState.filterText
        let previousSidebarCollapsed = sidebarState.sidebarCollapsed
        let previousSidebarSurface = sidebarState.sidebarSurface
        let previousSidebarHasFocus = sidebarState.sidebarHasFocus
        sidebarState.setSidebarCollapsed(false)
        sidebarState.setSidebarSurface(.panes)
        let view = RepoExplorerView(
            store: WorkspaceStore(startsObserving: false),
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
            bridgeAttendanceSnapshot: { _ in nil },
            commandDispatcher: FakeRepoExplorerAppCommandDispatcher(),
            onRefocusActivePane: {},
            onSidebarVisibleWorktreesChanged: {}
        )
        let hostingView = RepoExplorerFilterHostingView(rootView: AnyView(view))
        let window = RepoExplorerFilterWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            hostingView.rootView = AnyView(EmptyView())
            hostingView.layoutSubtreeIfNeeded()
            window.close()
            sidebarState.setFilterText(previousFilterText)
            sidebarState.setSidebarCollapsed(previousSidebarCollapsed)
            sidebarState.setSidebarSurface(previousSidebarSurface)
            sidebarState.setSidebarHasFocus(previousSidebarHasFocus)
        }
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let listHost = try #require(
            await hostingView.descendant(RepoExplorerMaterializationHost.self)
        )
        let textField = try #require(await hostingView.descendant(NSTextField.self))

        // Use the production FocusState request and the native shared field editor.
        var filterFocusAccepted = false
        #expect(
            await window.performAndWaitForFirstResponder(
                matching: { textField.currentEditor() === window.firstResponder },
                action: { filterFocusAccepted = RepoExplorerView.requestFilterFocus(on: listHost) }
            )
        )
        #expect(filterFocusAccepted)
        let editor = try #require(textField.currentEditor() as? NSTextView)
        let filterTextWaiter = RepoExplorerFilterObservableConditionWaiter {
            sidebarState.filterText == "prf123-no-match"
        }
        editor.insertText("prf123-no-match", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await filterTextWaiter.wait())

        let enterEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            ))
        #expect(
            await window.performAndWaitForFirstResponder(
                matching: { window.firstResponder === listHost },
                action: { window.sendEvent(enterEvent) }
            )
        )
        #expect(textField.currentEditor() == nil)
        #expect(sidebarState.filterText == "prf123-no-match")
        #expect(sidebarState.sidebarHasFocus)
    }

    @Test("Repos to Panes surface switching preserves active list keyboard focus")
    func reposToPanesSwitchPreservesListKeyboardFocus() async throws {
        let sidebarState = CoreAtomScope.store.workspaceSidebarState
        let previousFilterText = sidebarState.filterText
        let previousSidebarCollapsed = sidebarState.sidebarCollapsed
        let previousSidebarSurface = sidebarState.sidebarSurface
        let previousSidebarHasFocus = sidebarState.sidebarHasFocus
        sidebarState.setSidebarCollapsed(false)
        sidebarState.setSidebarSurface(.repos)

        let view = RepoExplorerView(
            store: WorkspaceStore(startsObserving: false),
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(sidebarState: sidebarState),
            bridgeAttendanceSnapshot: { _ in nil },
            commandDispatcher: FakeRepoExplorerAppCommandDispatcher(),
            onRefocusActivePane: {},
            onSidebarVisibleWorktreesChanged: {}
        )
        let hostingView = RepoExplorerFilterHostingView(rootView: AnyView(view))
        let window = RepoExplorerFilterWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            hostingView.rootView = AnyView(EmptyView())
            hostingView.layoutSubtreeIfNeeded()
            window.close()
            sidebarState.setFilterText(previousFilterText)
            sidebarState.setSidebarCollapsed(previousSidebarCollapsed)
            sidebarState.setSidebarSurface(previousSidebarSurface)
            sidebarState.setSidebarHasFocus(previousSidebarHasFocus)
        }

        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let listHost = try #require(
            await hostingView.descendant(RepoExplorerMaterializationHost.self)
        )
        #expect(window.makeFirstResponder(listHost))
        #expect(window.firstResponder === listHost)
        #expect(sidebarState.sidebarHasFocus)

        sidebarState.setSidebarSurface(.panes)
        hostingView.layoutSubtreeIfNeeded()

        #expect(!sidebarState.sidebarCollapsed)
        #expect(view.isProjectionDemanded)
        #expect(window.firstResponder === listHost)
        #expect(sidebarState.sidebarHasFocus)
    }

    @Test("opening an organization selector reports preview eligibility loss")
    func organizationSelectorOpeningReportsPreviewEligibilityLoss() throws {
        var eligibilityLossCount = 0
        let view = RepoExplorerView(
            store: WorkspaceStore(startsObserving: false),
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
            bridgeAttendanceSnapshot: { _ in nil },
            commandDispatcher: FakeRepoExplorerAppCommandDispatcher(),
            onRefocusActivePane: {},
            onPreviewEligibilityLoss: { eligibilityLossCount += 1 },
            onSidebarVisibleWorktreesChanged: {}
        )
        let hostingView = NSHostingView(rootView: AnyView(view.repoToolbarRow))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 40)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            hostingView.rootView = AnyView(EmptyView())
            hostingView.layoutSubtreeIfNeeded()
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        for location in [
            NSPoint(x: 340, y: 10),
            NSPoint(x: 340, y: 20),
            NSPoint(x: 340, y: 30),
            NSPoint(x: 320, y: 10),
            NSPoint(x: 320, y: 20),
            NSPoint(x: 320, y: 30),
        ] where eligibilityLossCount == 0 {
            let down = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: location,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            let up = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: location,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
            window.sendEvent(down)
            window.sendEvent(up)
        }

        #expect(eligibilityLossCount == 1)
    }

    @Test(
        "shell-style direct list focus works from cold native and requested filter focus",
        arguments: ColdFilterFocusEntry.allCases
    )
    func shellStyleDirectListFocusFromColdFilter(
        entry: ColdFilterFocusEntry
    ) async throws {
        let sharedCoreAtoms = CoreAtomScope.store
        try await withAsyncTestCoreAtoms(using: sharedCoreAtoms) { atoms in
            let sidebarState = atoms.workspaceSidebarState
            let previousFilterText = sidebarState.filterText
            let previousFilterVisibility = sidebarState.isFilterVisible
            let previousSidebarCollapsed = sidebarState.sidebarCollapsed
            let previousSidebarSurface = sidebarState.sidebarSurface
            let previousSidebarHasFocus = sidebarState.sidebarHasFocus
            let previousManagementActive = atoms.managementLayer.isActive
            let previousKeyWindowID = atoms.windowLifecycle.keyWindowId
            let previousFocusedWindowID = atoms.windowLifecycle.focusedWindowId
            let workspaceWindowID =
                previousKeyWindowID
                ?? previousFocusedWindowID
                ?? atoms.windowLifecycle.registeredWindowIds.first
                ?? UUIDv7.generate()
            defer {
                sidebarState.setFilterText(previousFilterText)
                sidebarState.setFilterVisible(previousFilterVisibility)
                sidebarState.setSidebarCollapsed(previousSidebarCollapsed)
                sidebarState.setSidebarSurface(previousSidebarSurface)
                sidebarState.setSidebarHasFocus(previousSidebarHasFocus)
                if atoms.managementLayer.isActive != previousManagementActive {
                    atoms.managementLayer.toggle()
                }
                restoreColdFocusWindowLifecycle(
                    atoms.windowLifecycle,
                    previousKeyWindowID: previousKeyWindowID,
                    previousFocusedWindowID: previousFocusedWindowID
                )
            }
            sidebarState.setSidebarCollapsed(false)
            sidebarState.setSidebarSurface(.repos)
            sidebarState.setSidebarHasFocus(false)
            atoms.managementLayer.deactivate()
            atoms.windowLifecycle.recordWindowRegistered(workspaceWindowID)
            atoms.windowLifecycle.recordWindowBecameKey(workspaceWindowID)

            let dispatcher = ColdFocusRecordingCommandDispatcher()
            let view = RepoExplorerView(
                store: WorkspaceStore(startsObserving: false),
                octiconLoader: makeRepoExplorerTestOcticonLoader(),
                repoExplorerPrefs: RepoExplorerSidebarPrefsAtom(),
                bridgeAttendanceSnapshot: { _ in nil },
                commandDispatcher: dispatcher,
                onRefocusActivePane: {},
                onSidebarVisibleWorktreesChanged: {}
            )
            let hostingView = RepoExplorerFilterHostingView(rootView: AnyView(view))
            let window = makeColdFocusWindow(hostingView)
            defer {
                hostingView.rootView = AnyView(EmptyView())
                hostingView.layoutSubtreeIfNeeded()
                window.close()
            }
            let listHost = try await coldFocusListHost(in: hostingView)
            let textField = try #require(
                firstFilterDescendant(NSTextField.self, in: hostingView)
            )
            dispatcher.listHost = listHost

            await focusColdFilter(
                entry: entry,
                window: window,
                textField: textField,
                listHost: listHost
            )

            if entry == .filterAfterRuntimeFocusReset {
                #expect(sidebarState.sidebarHasFocus)
                // Exact runtime effect of the post-presentation UIStateStore hydration.
                sidebarState.setSidebarHasFocus(false)
            }
            #expect(window.makeFirstResponder(listHost))
            hostingView.layoutSubtreeIfNeeded()
            #expect(window.firstResponder === listHost)
            #expect(sidebarState.sidebarHasFocus)

            window.sendEvent(try coldFocusKeyEvent("p", keyCode: 35, window: window))
            #expect(dispatcher.commands == [.showPanesSidebar])
            #expect(window.firstResponder === listHost)

            let filterEvent = try coldFocusKeyEvent("f", keyCode: 3, window: window)
            #expect(
                await window.performAndWaitForFirstResponder(
                    matching: { textField.currentEditor() === window.firstResponder },
                    action: { window.sendEvent(filterEvent) }
                )
            )
            #expect(dispatcher.commands == [.showPanesSidebar, .filterSidebar])
        }
    }
}

enum ColdFilterFocusEntry: CaseIterable, Sendable {
    case initialNativeFieldFocus
    case explicitFocusStateRequest
    case filterAfterRuntimeFocusReset
}

@MainActor
private final class ColdFocusRecordingCommandDispatcher: AppCommandDispatching {
    weak var listHost: RepoExplorerMaterializationHost?
    private(set) var commands: [AppCommand] = []

    func dispatch(_ command: AppCommand) -> Bool {
        commands.append(command)
        if command == .filterSidebar, let listHost {
            _ = RepoExplorerView.requestFilterFocus(on: listHost)
        }
        return true
    }

    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { true }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { true }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}

@MainActor
private func firstFilterDescendant<ViewType: NSView>(_ type: ViewType.Type, in view: NSView) -> ViewType? {
    if let match = view as? ViewType { return match }
    for subview in view.subviews {
        if let match = firstFilterDescendant(type, in: subview) { return match }
    }
    return nil
}

@MainActor
private func makeColdFocusWindow(
    _ hostingView: RepoExplorerFilterHostingView
) -> RepoExplorerFilterWindow {
    let window = RepoExplorerFilterWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func coldFocusListHost(
    in hostingView: RepoExplorerFilterHostingView
) async throws -> RepoExplorerMaterializationHost {
    try #require(await hostingView.descendant(RepoExplorerMaterializationHost.self))
}

@MainActor
private final class RepoExplorerFilterHostingView: NSHostingView<AnyView> {
    private var descendantCondition: (() -> Bool)?
    private var descendantContinuation: CheckedContinuation<Void, Never>?

    func descendant<ViewType: NSView>(_ type: ViewType.Type) async -> ViewType? {
        layoutSubtreeIfNeeded()
        if let match = firstFilterDescendant(type, in: self) { return match }
        await withCheckedContinuation { continuation in
            precondition(descendantContinuation == nil)
            descendantCondition = { [weak self] in
                guard let self else { return false }
                return firstFilterDescendant(type, in: self) != nil
            }
            descendantContinuation = continuation
            needsLayout = true
        }
        return firstFilterDescendant(type, in: self)
    }

    override func layout() {
        super.layout()
        guard descendantCondition?() == true else { return }
        descendantCondition = nil
        descendantContinuation?.resume()
        descendantContinuation = nil
    }
}

@MainActor
private final class RepoExplorerFilterWindow: NSWindow {
    private var responderCondition: (() -> Bool)?
    private var responderContinuation: CheckedContinuation<Bool, Never>?

    func performAndWaitForFirstResponder(
        matching condition: @escaping () -> Bool,
        action: () -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            precondition(responderContinuation == nil)
            responderCondition = condition
            responderContinuation = continuation
            action()
            resolveResponderWaitIfSatisfied()
        }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        resolveResponderWaitIfSatisfied()
        return accepted
    }

    private func resolveResponderWaitIfSatisfied() {
        guard responderCondition?() == true else { return }
        responderCondition = nil
        responderContinuation?.resume(returning: true)
        responderContinuation = nil
    }
}

@MainActor
private func focusColdFilter(
    entry: ColdFilterFocusEntry,
    window: RepoExplorerFilterWindow,
    textField: NSTextField,
    listHost: RepoExplorerMaterializationHost
) async {
    switch entry {
    case .initialNativeFieldFocus:
        var nativeFocusAccepted = false
        #expect(
            await window.performAndWaitForFirstResponder(
                matching: { textField.currentEditor() === window.firstResponder },
                action: { nativeFocusAccepted = window.makeFirstResponder(textField) }
            )
        )
        #expect(nativeFocusAccepted)
    case .explicitFocusStateRequest, .filterAfterRuntimeFocusReset:
        var filterFocusAccepted = false
        #expect(
            await window.performAndWaitForFirstResponder(
                matching: { textField.currentEditor() === window.firstResponder },
                action: {
                    filterFocusAccepted = RepoExplorerView.requestFilterFocus(on: listHost)
                }
            )
        )
        #expect(filterFocusAccepted)
    }
}

@MainActor
private final class RepoExplorerFilterObservableConditionWaiter {
    private let condition: @MainActor () -> Bool
    private var continuation: CheckedContinuation<Bool, Never>?

    init(condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    func wait() async -> Bool {
        if condition() { return true }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            observeCondition()
        }
    }

    private func observeCondition() {
        guard continuation != nil else { return }
        if condition() {
            continuation?.resume(returning: true)
            continuation = nil
            return
        }
        withObservationTracking {
            _ = condition()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeCondition()
            }
        }
    }
}

@MainActor
private func coldFocusKeyEvent(
    _ characters: String,
    keyCode: UInt16,
    window: NSWindow
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

@MainActor
private func restoreColdFocusWindowLifecycle(
    _ windowLifecycle: WindowLifecycleAtom,
    previousKeyWindowID: UUID?,
    previousFocusedWindowID: UUID?
) {
    if let currentKeyWindowID = windowLifecycle.keyWindowId {
        windowLifecycle.recordWindowResignedKey(currentKeyWindowID)
    }
    if let currentFocusedWindowID = windowLifecycle.focusedWindowId {
        windowLifecycle.recordWindowResignedFocused(currentFocusedWindowID)
    }
    if let previousKeyWindowID {
        windowLifecycle.recordWindowBecameKey(previousKeyWindowID)
    }
    if let previousFocusedWindowID {
        windowLifecycle.recordWindowBecameFocused(previousFocusedWindowID)
    } else if let previousKeyWindowID {
        windowLifecycle.recordWindowResignedFocused(previousKeyWindowID)
    }
}
