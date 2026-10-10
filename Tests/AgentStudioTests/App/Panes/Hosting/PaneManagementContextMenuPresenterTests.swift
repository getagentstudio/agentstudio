import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioTestSupport

@MainActor
@Suite("Pane management native context menu", .serialized)
struct PaneManagementContextMenuPresenterTests {
    init() {
        _ = NSApplication.shared
    }

    @Test("Move destinations are projected only when AppKit opens the submenu")
    func moveDestinationsAreBuiltOnSubmenuOpenAndStayFresh() throws {
        let dispatcher = PaneManagementContextMenuRecordingDispatcher()
        let paneID = UUIDv7.generate()
        dispatcher.enabledCommands = [.extractPaneToTab, .movePaneToTab]
        let extractPresentation = try #require(
            PaneLeafCommandPresentation.resolve(
                command: .extractPaneToTab,
                surface: .contextMenu,
                targetPaneId: paneID,
                dispatcher: dispatcher
            )
        )
        let movePresentation = try #require(
            PaneLeafCommandPresentation.resolve(
                command: .movePaneToTab,
                surface: .contextMenu,
                targetPaneId: paneID,
                dispatcher: dispatcher
            )
        )
        let presenter = PaneManagementContextMenuPresenter(
            octiconLoader: makeTestOcticonLoader()
        )
        var destinationProjectionCount = 0
        var destinationTitles = ["Tab 2 · Before Rename"]
        var selectedDestinationTitles: [String] = []

        let menu = try #require(
            presenter.makeMenu(
                extractPresentation: extractPresentation,
                movePresentation: movePresentation,
                destinationProvider: {
                    destinationProjectionCount += 1
                    return destinationTitles.map { title in
                        PaneMoveDestinationMenuPresenter.Destination(
                            title: title,
                            perform: { selectedDestinationTitles.append(title) }
                        )
                    }
                }
            )
        )

        #expect(destinationProjectionCount == 0)
        #expect(
            menu.items.map(\.title) == [
                AppCommand.extractPaneToTab.definition.label,
                AppCommand.movePaneToTab.definition.label,
            ]
        )
        #expect(menu.items.allSatisfy { $0.image != nil })
        #expect(menu.items.allSatisfy { $0.isEnabled })

        let moveMenu = try #require(
            menu.item(withTitle: AppCommand.movePaneToTab.definition.label)?.submenu
        )
        #expect(moveMenu.items.isEmpty)
        #expect(moveMenu.delegate === presenter)

        destinationTitles = ["Tab 3 · After Rename", "Tab 2 · Current"]
        moveMenu.delegate?.menuNeedsUpdate?(moveMenu)

        #expect(destinationProjectionCount == 1)
        #expect(moveMenu.items.map(\.title) == destinationTitles)
        moveMenu.performActionForItem(at: 1)
        #expect(selectedDestinationTitles == ["Tab 2 · Current"])

        destinationTitles = ["Tab 4 · Added Immediately Before Reopen"]
        moveMenu.delegate?.menuNeedsUpdate?(moveMenu)

        #expect(destinationProjectionCount == 2)
        #expect(moveMenu.items.map(\.title) == destinationTitles)
    }

    @Test("Root command enablement and activation retain command authority")
    func rootCommandEnablementAndActivationUsePresentationAuthority() throws {
        let dispatcher = PaneManagementContextMenuRecordingDispatcher()
        let paneID = UUIDv7.generate()
        dispatcher.enabledCommands = [.extractPaneToTab]
        let extractPresentation = try #require(
            PaneLeafCommandPresentation.resolve(
                command: .extractPaneToTab,
                surface: .contextMenu,
                targetPaneId: paneID,
                dispatcher: dispatcher
            )
        )
        let movePresentation = try #require(
            PaneLeafCommandPresentation.resolve(
                command: .movePaneToTab,
                surface: .contextMenu,
                targetPaneId: paneID,
                dispatcher: dispatcher
            )
        )
        let presenter = PaneManagementContextMenuPresenter(
            octiconLoader: makeTestOcticonLoader()
        )
        let menu = try #require(
            presenter.makeMenu(
                extractPresentation: extractPresentation,
                movePresentation: movePresentation,
                destinationProvider: { [] }
            )
        )

        #expect(menu.items[0].isEnabled)
        #expect(!menu.items[1].isEnabled)

        dispatcher.enabledCommands = []
        menu.performActionForItem(at: 0)
        #expect(dispatcher.dispatchedCommands.isEmpty)

        dispatcher.enabledCommands = [.extractPaneToTab]
        menu.performActionForItem(at: 0)
        #expect(dispatcher.dispatchedCommands == [.extractPaneToTab])
        #expect(dispatcher.dispatchedPaneIDs == [paneID])
    }

    @Test("Capture view admits only visible in-bounds secondary gestures")
    func captureViewAdmitsOnlyVisibleInBoundsContextMenuGestures() throws {
        var installedEventHandler: ((NSEvent) -> NSEvent?)?
        var installationCount = 0
        var removalCount = 0
        let monitorToken = NSObject()
        let captureView = PaneManagementContextMenuCaptureView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 80),
            eventMonitorInstaller: { _, eventHandler in
                installationCount += 1
                installedEventHandler = eventHandler
                return monitorToken
            },
            eventMonitorRemover: { removedMonitor in
                #expect((removedMonitor as? NSObject) === monitorToken)
                removalCount += 1
            }
        )
        let containerView = NSView(frame: captureView.frame)
        containerView.addSubview(captureView)
        let window = makeWindow(frame: containerView.frame)
        window.contentView = containerView
        defer {
            captureView.detach()
            window.close()
        }

        var admittedEvents: [NSEvent.EventType] = []
        captureView.update(isEnabled: true) { event, _ in
            admittedEvents.append(event.type)
            return true
        }
        #expect(captureView.hasInstalledEventMonitor)
        #expect(installationCount == 1)
        captureView.update(isEnabled: true) { event, _ in
            admittedEvents.append(event.type)
            return true
        }
        #expect(captureView.hasInstalledEventMonitor)
        #expect(installationCount == 1)

        let primaryClick = try mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 40, y: 30),
            window: window
        )
        #expect(captureView.processContextMenuEvent(primaryClick) === primaryClick)

        let outsideRightClick = try mouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 140, y: 30),
            window: window
        )
        #expect(captureView.processContextMenuEvent(outsideRightClick) === outsideRightClick)

        let differentWindow = makeWindow(frame: containerView.frame)
        defer { differentWindow.close() }
        let differentWindowRightClick = try mouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 40, y: 30),
            window: differentWindow
        )
        #expect(
            captureView.processContextMenuEvent(differentWindowRightClick)
                === differentWindowRightClick
        )

        let rightClick = try mouseEvent(
            type: .rightMouseDown,
            location: CGPoint(x: 40, y: 30),
            window: window
        )
        let eventHandler = try #require(installedEventHandler)
        #expect(eventHandler(rightClick) == nil)

        let controlClick = try mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 40, y: 30),
            modifierFlags: [.control],
            window: window
        )
        #expect(captureView.processContextMenuEvent(controlClick) == nil)
        #expect(admittedEvents == [.rightMouseDown, .leftMouseDown])

        containerView.isHidden = true
        #expect(captureView.processContextMenuEvent(rightClick) === rightClick)
        #expect(admittedEvents == [.rightMouseDown, .leftMouseDown])
        containerView.isHidden = false

        captureView.update(isEnabled: false) { _, _ in
            Issue.record("disabled capture view must not request a context menu")
            return true
        }
        #expect(!captureView.hasInstalledEventMonitor)
        #expect(removalCount == 1)
        #expect(captureView.processContextMenuEvent(rightClick) === rightClick)
        #expect(captureView.hitTest(CGPoint(x: 40, y: 30)) == nil)
        captureView.detach()
        #expect(removalCount == 1)
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: CGPoint,
        modifierFlags: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}

@MainActor
private final class PaneManagementContextMenuRecordingDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    var enabledCommands: Set<AppCommand> = []
    private(set) var dispatchedCommands: [AppCommand] = []
    private(set) var dispatchedPaneIDs: [UUID] = []

    func dispatch(_ command: AppCommand) -> Bool {
        dispatchedCommands.append(command)
        return true
    }

    func dispatch(
        _ command: AppCommand,
        target: UUID,
        targetType _: SearchItemType
    ) {
        dispatchedCommands.append(command)
        dispatchedPaneIDs.append(target)
    }

    func canDispatch(_ command: AppCommand) -> Bool {
        enabledCommands.contains(command)
    }

    func canDispatch(
        _ command: AppCommand,
        target _: UUID,
        targetType _: SearchItemType
    ) -> Bool {
        enabledCommands.contains(command)
    }

    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? {
        nil
    }

    func dispatchMovePaneToTab(
        sourcePaneId _: UUID,
        sourceTabId _: UUID?,
        targetTabId _: UUID
    ) {}
}
