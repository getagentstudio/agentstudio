import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioTerminal

@MainActor
private final class PaneSearchActionPerformer: TerminalSurfaceActionPerforming {
    private(set) var actions: [TerminalSurfaceAction] = []

    @discardableResult
    func performBindingAction(_ action: TerminalSurfaceAction) -> Bool {
        actions.append(action)
        return true
    }
}

@MainActor
private final class PaneScrollActionPerformer: TerminalSurfaceActionPerforming {
    @discardableResult
    func performBindingAction(_ action: TerminalSurfaceAction) -> Bool {
        _ = action
        return true
    }
}

@Suite("TerminalPaneMountView search responders", .serialized)
@MainActor
struct TerminalPaneMountViewSearchTests {
    @Test("starting search focuses the search field")
    func startingSearchFocusesSearchField() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.layoutSubtreeIfNeeded()

        let searchField = try #require(
            firstSubview(of: NSSearchField.self, in: mountView)
        )
        #expect(searchField.currentEditor() != nil)
        #expect(window.firstResponder === searchField.currentEditor())
    }

    @Test("Cmd-F keeps Find open and focused when its field already owns focus")
    func commandFKeepsFindOpenWhenSearchFieldOwnsFocus() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.startSearch(nil)

        let searchField = try #require(
            firstSubview(of: NSSearchField.self, in: mountView)
        )
        #expect(mountView.searchOverlayView != nil)
        #expect(searchField.currentEditor() != nil)
        #expect(window.firstResponder === searchField.currentEditor())
        #expect(performer.actions == [.startSearch])
    }

    @Test("Cmd-F refocuses an open Find field from its owning terminal")
    func commandFRefocusesOpenFindFromOwningTerminal() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let otherMountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Other Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let splitContentView = NSView()
        splitContentView.addSubview(mountView)
        splitContentView.addSubview(otherMountView)
        mountView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        otherMountView.frame = NSRect(x: 400, y: 0, width: 400, height: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = splitContentView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.layoutSubtreeIfNeeded()
        let searchField = try #require(
            firstSubview(of: NSSearchField.self, in: mountView)
        )

        mountView.cancelOperation(nil)

        #expect(window.firstResponder === mountView)

        mountView.startSearch(nil)

        #expect(searchField.currentEditor() != nil)
        #expect(window.firstResponder === searchField.currentEditor())
        #expect(window.firstResponder !== otherMountView)
        #expect(performer.actions == [.startSearch])
    }

    @Test("Escape returns focus to the terminal and further Escape does not close Find")
    func escapeReturnsFocusToTerminalWithoutClosingFind() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.cancelOperation(nil)
        mountView.cancelOperation(nil)

        #expect(window.firstResponder === mountView)
        #expect(mountView.searchOverlayView != nil)
        #expect(performer.actions == [.startSearch])
    }

    @Test("Ghostty acknowledgements cannot reverse a newer Find presentation intent")
    func ghosttyAcknowledgementsCannotReverseNewerFindPresentationIntent() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Terminal")
        )
        #expect(runtime.transitionToReady())

        mountView.startSearch(nil)
        runtime.handleGhosttyEvent(.searchStarted(query: nil))
        mountView.applyRuntimeStateSnapshot(runtime)

        try #require(button(accessibilityLabel: "Close Find", in: mountView))
            .performClick(nil)
        mountView.applyRuntimeStateSnapshot(runtime)

        #expect(mountView.searchOverlayView == nil)

        runtime.handleGhosttyEvent(.searchEnded)
        mountView.applyRuntimeStateSnapshot(runtime)
        mountView.startSearch(nil)
        mountView.applyRuntimeStateSnapshot(runtime)

        #expect(mountView.searchOverlayView != nil)
        #expect(performer.actions == [.startSearch, .endSearch, .startSearch])
    }

    @Test("coalesced Ghostty lifecycle settles the latest Find presentation intent")
    func coalescedGhosttyLifecycleSettlesLatestFindPresentationIntent() throws {
        let openingMountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Opening Terminal")
        let openingPerformer = PaneSearchActionPerformer()
        openingMountView.installActionPerformerForTesting(openingPerformer)
        let openingRuntime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Opening Terminal")
        )
        #expect(openingRuntime.transitionToReady())

        openingMountView.startSearch(nil)
        try #require(button(accessibilityLabel: "Close Find", in: openingMountView))
            .performClick(nil)
        openingMountView.startSearch(nil)

        openingRuntime.handleGhosttyEvent(.searchStarted(query: nil))
        openingRuntime.handleGhosttyEvent(.searchEnded)
        openingRuntime.handleGhosttyEvent(.searchStarted(query: nil))
        openingMountView.applyRuntimeStateSnapshot(openingRuntime)

        #expect(openingMountView.searchPresentationState == .open(epoch: 2))
        #expect(openingMountView.searchOverlayView != nil)
        #expect(openingPerformer.actions == [.startSearch, .endSearch, .startSearch])

        let closingMountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Closing Terminal")
        let closingPerformer = PaneSearchActionPerformer()
        closingMountView.installActionPerformerForTesting(closingPerformer)
        let closingRuntime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Closing Terminal")
        )
        #expect(closingRuntime.transitionToReady())

        closingMountView.startSearch(nil)
        try #require(button(accessibilityLabel: "Close Find", in: closingMountView))
            .performClick(nil)
        closingMountView.startSearch(nil)
        try #require(button(accessibilityLabel: "Close Find", in: closingMountView))
            .performClick(nil)

        closingRuntime.handleGhosttyEvent(.searchStarted(query: nil))
        closingRuntime.handleGhosttyEvent(.searchEnded)
        closingRuntime.handleGhosttyEvent(.searchStarted(query: nil))
        closingRuntime.handleGhosttyEvent(.searchEnded)
        closingMountView.applyRuntimeStateSnapshot(closingRuntime)

        #expect(closingMountView.searchPresentationState == .closed(epoch: 2))
        #expect(closingMountView.searchOverlayView == nil)
        #expect(
            closingPerformer.actions == [
                .startSearch,
                .endSearch,
                .startSearch,
                .endSearch,
            ]
        )
    }

    @Test("empty-query Escape closes consecutive Find sessions")
    func emptyQueryEscapeClosesConsecutiveFindSessions() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Terminal")
        )
        #expect(runtime.transitionToReady())
        let accumulator = TerminalLocalActionAccumulator { _, _ in }
        let surfaceID = UUIDv7.generate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        for expectedEpoch in UInt64(1)...2 {
            mountView.startSearch(nil)
            applySearchLifecycle(
                .searchStarted(query: nil),
                from: accumulator,
                surfaceID: surfaceID,
                to: runtime,
                mountedBy: mountView
            )
            #expect(mountView.searchPresentationState == .open(epoch: expectedEpoch))
            let searchOverlay = try #require(mountView.searchOverlayView)
            let searchField = try #require(
                firstSubview(of: NSSearchField.self, in: searchOverlay)
            )
            let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
            #expect(searchField.stringValue.isEmpty)
            #expect(window.firstResponder === fieldEditor)
            #expect(
                searchOverlay.control(
                    searchField,
                    textView: fieldEditor,
                    doCommandBy: #selector(NSResponder.cancelOperation(_:))
                )
            )
            #expect(window.firstResponder === mountView)
            #expect(mountView.searchPresentationState == .closing(expectedEpoch: expectedEpoch))
            #expect(mountView.searchOverlayView == nil)

            applySearchLifecycle(
                .searchEnded,
                from: accumulator,
                surfaceID: surfaceID,
                to: runtime,
                mountedBy: mountView
            )
            #expect(mountView.searchPresentationState == .closed(epoch: expectedEpoch))
            #expect(mountView.searchOverlayView == nil)
        }

        #expect(
            performer.actions == [
                .startSearch,
                .endSearch,
                .startSearch,
                .endSearch,
            ]
        )
    }

    @Test("typed-query Escape focus transfer precedes both delivered Ghostty ends")
    func typedQueryEscapeFocusTransferPrecedesConsecutiveGhosttyEnds() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Terminal")
        )
        #expect(runtime.transitionToReady())
        let accumulator = TerminalLocalActionAccumulator { _, _ in }
        let surfaceID = UUIDv7.generate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        for expectedEpoch in UInt64(1)...2 {
            mountView.startSearch(nil)
            applySearchLifecycle(
                .searchStarted(query: nil),
                from: accumulator,
                surfaceID: surfaceID,
                to: runtime,
                mountedBy: mountView
            )
            let searchOverlay = try #require(mountView.searchOverlayView)
            let searchField = try #require(
                firstSubview(of: NSSearchField.self, in: searchOverlay)
            )
            let fieldEditor = try #require(searchField.currentEditor() as? NSTextView)
            searchField.stringValue = "needle-\(expectedEpoch)"
            searchOverlay.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: searchField)
            )

            #expect(
                searchOverlay.control(
                    searchField,
                    textView: fieldEditor,
                    doCommandBy: #selector(NSResponder.cancelOperation(_:))
                )
            )
            #expect(window.firstResponder === mountView)

            applySearchLifecycle(
                .searchEnded,
                from: accumulator,
                surfaceID: surfaceID,
                to: runtime,
                mountedBy: mountView
            )
            #expect(mountView.searchPresentationState == .closed(epoch: expectedEpoch))
            #expect(mountView.searchOverlayView == nil)
        }

        #expect(
            performer.actions == [
                .startSearch,
                .search("needle-1"),
                .startSearch,
                .search("needle-2"),
            ]
        )
    }

    @Test("editing the focused search field sends the query to Ghostty")
    func editingFocusedSearchFieldSendsQueryToGhostty() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.layoutSubtreeIfNeeded()

        let searchField = try #require(
            firstSubview(of: NSSearchField.self, in: mountView)
        )
        let fieldEditor = try #require(searchField.currentEditor())
        fieldEditor.insertText("needle")

        #expect(performer.actions == [.startSearch, .search("needle")])
    }

    @Test("runtime result updates preserve the active search draft")
    func runtimeResultUpdatesPreserveActiveSearchDraft() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Terminal")
        )
        #expect(runtime.transitionToReady())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.startSearch(nil)
        mountView.layoutSubtreeIfNeeded()
        let searchField = try #require(
            firstSubview(of: NSSearchField.self, in: mountView)
        )
        let fieldEditor = try #require(searchField.currentEditor())
        fieldEditor.insertText("needle")

        runtime.handleGhosttyEvent(.searchStarted(query: nil))
        runtime.handleGhosttyEvent(.searchMatchesUpdated(totalMatches: 4))
        runtime.handleGhosttyEvent(.searchSelectionChanged(selectedMatchIndex: 0))
        mountView.applyRuntimeStateSnapshot(runtime)

        #expect(searchField.stringValue == "needle")
        #expect(performer.actions == [.startSearch, .search("needle")])
    }

    @Test("search overlay buttons send navigation and close actions")
    func searchOverlayButtonsSendNavigationAndCloseActions() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)
        mountView.startSearch(nil)
        mountView.layoutSubtreeIfNeeded()

        let previousButton = try #require(button(accessibilityLabel: "Previous Match", in: mountView))
        let nextButton = try #require(button(accessibilityLabel: "Next Match", in: mountView))
        let closeButton = try #require(button(accessibilityLabel: "Close Find", in: mountView))

        previousButton.performClick(nil)
        nextButton.performClick(nil)
        closeButton.performClick(nil)

        #expect(
            performer.actions == [
                .startSearch,
                .navigateSearch(.previous),
                .navigateSearch(.next),
                .endSearch,
            ]
        )
        #expect(mountView.searchOverlayView == nil)
    }

    @Test("mount view search responders and close button send exact ghostty binding actions")
    func mountViewSearchRespondersAndCloseButtonSendExactGhosttyBindingActions() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)

        mountView.startSearch(nil)
        mountView.findNext(nil)
        mountView.findPrevious(nil)
        let closeButton = try #require(button(accessibilityLabel: "Close Find", in: mountView))
        closeButton.performClick(nil)

        #expect(
            performer.actions == [
                .startSearch,
                .navigateSearch(.next),
                .navigateSearch(.previous),
                .endSearch,
            ])
    }

    @Test("search overlay fills available pane width up to its maximum")
    func searchOverlayFillsAvailablePaneWidthUpToMaximum() throws {
        let wideMountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Wide Terminal")
        wideMountView.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
        wideMountView.ensureSearchOverlayForTesting()
        wideMountView.layoutSubtreeIfNeeded()
        let wideFrame = try #require(wideMountView.searchOverlayFrameForTesting)

        let narrowMountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Narrow Terminal")
        narrowMountView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        narrowMountView.ensureSearchOverlayForTesting()
        narrowMountView.layoutSubtreeIfNeeded()
        let narrowFrame = try #require(narrowMountView.searchOverlayFrameForTesting)

        #expect(abs(wideFrame.width - 720) <= 1)
        #expect(abs(narrowFrame.width - 376) <= 1)
    }

    @Test("search navigation and close controls use icon-only accessible buttons")
    func searchControlsUseIconOnlyAccessibleButtons() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        mountView.ensureSearchOverlayForTesting()

        for accessibilityLabel in ["Previous Match", "Next Match", "Close Find"] {
            let iconButton = try #require(
                button(accessibilityLabel: accessibilityLabel, in: mountView)
            )
            #expect(iconButton.title.isEmpty)
            #expect(iconButton.image != nil)
        }
    }

    @Test("hitTest prioritizes search overlay over terminal content")
    func hitTestPrioritizesSearchOverlayOverTerminalContent() {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        mountView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        mountView.ensureSearchOverlayForTesting()
        guard let point = mountView.searchOverlayInteractivePointForTesting else {
            Issue.record("Expected search overlay interactive point for hit-test verification")
            return
        }
        let hitView = mountView.hitTest(point)

        #expect(hitView != nil)
        #expect(hitView !== mountView)
    }

    @Test("hitTest routes every search button center to that button")
    func hitTestRoutesEverySearchButtonCenterToThatButton() throws {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = mountView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        mountView.ensureSearchOverlayForTesting()
        mountView.layoutSubtreeIfNeeded()

        for accessibilityLabel in ["Previous Match", "Next Match", "Close Find"] {
            let searchButton = try #require(
                button(accessibilityLabel: accessibilityLabel, in: mountView)
            )
            let point = mountView.convert(
                NSPoint(x: searchButton.bounds.midX, y: searchButton.bounds.midY),
                from: searchButton
            )

            #expect(searchButton.isEnabled)
            #expect(mountView.hitTest(point) === searchButton)
        }
    }

    @Test("hitTest prioritizes scroll-to-bottom indicator over terminal content")
    func hitTestPrioritizesScrollToBottomIndicatorOverTerminalContent() {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        mountView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        mountView.ensureScrollToBottomIndicatorForTesting()
        guard let indicatorFrame = mountView.scrollToBottomIndicatorFrameForTesting else {
            Issue.record("Expected scroll-to-bottom indicator frame for hit-test verification")
            return
        }

        let point = NSPoint(x: indicatorFrame.midX, y: indicatorFrame.midY)
        let hitView = mountView.hitTest(point)

        #expect(hitView != nil)
        #expect(hitView !== mountView)
    }

    @Test("scroll-to-bottom indicator sits 12 points from trailing and bottom edges")
    func scrollToBottomIndicatorSitsTwelvePointsFromTrailingAndBottomEdges() {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        mountView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        mountView.ensureScrollToBottomIndicatorForTesting()
        guard let indicatorFrame = mountView.scrollToBottomIndicatorFrameForTesting else {
            Issue.record("Expected scroll-to-bottom indicator frame for spacing verification")
            return
        }

        #expect(abs((800 - indicatorFrame.maxX) - 12) <= 1)
        #expect(abs(indicatorFrame.minY - 12) <= 3)
    }

    @Test("cancelOperation without search overlay falls through without emitting actions")
    func cancelOperationWithoutSearchOverlayDoesNotEmitActions() {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let performer = PaneSearchActionPerformer()
        mountView.installActionPerformerForTesting(performer)

        mountView.cancelOperation(nil)

        #expect(performer.actions.isEmpty)
    }

    @Test("bind does not drive the native scroll wrapper directly from runtime replay")
    func bindDoesNotDriveTheNativeScrollWrapperDirectlyFromRuntimeReplay() {
        let mountView = TerminalPaneMountView(paneId: UUIDv7.generate(), title: "Terminal")
        let scrollView = TerminalSurfaceScrollView(actionPerformer: PaneScrollActionPerformer())
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        mountView.installSurfaceScrollViewForTesting(scrollView)

        let runtime = TerminalRuntime(
            paneId: PaneId.generateUUIDv7(),
            metadata: PaneMetadata(title: "Terminal")
        )
        #expect(runtime.transitionToReady())
        runtime.handleGhosttyEvent(.cellSizeChanged(NSSize(width: 8, height: 20)))
        runtime.handleGhosttyEvent(.scrollbarChanged(ScrollbarState(top: 80, bottom: 120, total: 200)))

        mountView.bind(runtime: runtime)

        #expect(scrollView.scrollView.contentView.bounds.origin.y == 0)
    }
}

@MainActor
private func firstSubview<Subview: NSView>(
    of _: Subview.Type,
    in rootView: NSView
) -> Subview? {
    if let matchingView = rootView as? Subview {
        return matchingView
    }

    for subview in rootView.subviews {
        if let matchingView = firstSubview(of: Subview.self, in: subview) {
            return matchingView
        }
    }

    return nil
}

@MainActor
private func button(accessibilityLabel: String, in rootView: NSView) -> NSButton? {
    if let button = rootView as? NSButton, button.accessibilityLabel() == accessibilityLabel {
        return button
    }

    for subview in rootView.subviews {
        if let matchingButton = button(accessibilityLabel: accessibilityLabel, in: subview) {
            return matchingButton
        }
    }

    return nil
}

@MainActor
private func applySearchLifecycle(
    _ action: TerminalLocalAccumulatorAction,
    from accumulator: TerminalLocalActionAccumulator,
    surfaceID: UUID,
    to runtime: TerminalRuntime,
    mountedBy mountView: TerminalPaneMountView
) {
    accumulator.offer(action, for: surfaceID)
    guard let batch = accumulator.beginDrain(for: surfaceID, lane: .immediate) else {
        Issue.record("Expected a terminal search lifecycle batch")
        return
    }
    _ = runtime.applyLocalActionBatch(batch)
    _ = accumulator.finishDrain(for: surfaceID, lane: .immediate)
    mountView.applyRuntimeStateSnapshot(runtime)
}
