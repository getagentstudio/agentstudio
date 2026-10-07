import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import CoreText
import GhosttyKit
import Observation

@MainActor
enum GhosttyMouseVisibilityCoordinator {
    private static var hiddenToken: UUID?
    private static var cursorHidden = false

    static func update(token: UUID, isVisible: Bool, isFocused: Bool) {
        guard isFocused, !isVisible else {
            release(token: token)
            return
        }

        guard hiddenToken != token else { return }
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
        hiddenToken = token
    }

    static func release(token: UUID) {
        guard hiddenToken == token else { return }
        hiddenToken = nil
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }
}

extension Ghostty.SurfaceView {
    // MARK: - Input Handling

    nonisolated static func shouldAcceptKeyEquivalent(
        isWindowFirstResponder: Bool
    ) -> Bool {
        isWindowFirstResponder
    }

    package override func keyDown(with event: NSEvent) {
        endRestorePhaseIfLatched()
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translation = ghosttyKeyTranslationPlan(for: event) { originalMods in
            guard let surface else { return originalMods }
            return ghostty_surface_key_translation_mods(surface, originalMods)
        }
        let translationEvent = translation.event

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hasMarkedTextBefore = markedText.length > 0
        let keyboardLayoutIDBefore = hasMarkedTextBefore ? nil : currentKeyboardLayoutID()

        // If we are in a keyDown then we don't need to redispatch a command-modded
        // key event, so reset this to nil because `interpretKeyEvents` may dispatch it.
        self.lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])

        guard
            !shouldAbortKeyDownForKeyboardLayoutChange(
                hasMarkedTextBefore: hasMarkedTextBefore,
                keyboardLayoutIDBefore: keyboardLayoutIDBefore,
                currentKeyboardLayoutID: { currentKeyboardLayoutID() }
            )
        else { return }

        syncPreedit(clearIfNeeded: hasMarkedTextBefore)
        let composing = markedText.length > 0 || hasMarkedTextBefore

        if hasMarkedTextBefore,
            let list = keyTextAccumulator,
            !list.isEmpty
        {
            for text in list {
                guard !shouldSuppressComposingControlInput(text, composing: composing) else { continue }
                _ = committedTextAction(action, text: text)
            }

            if shouldReplayCommittedPreeditKey(
                keyCode: translationEvent.keyCode,
                modifierFlags: translationEvent.modifierFlags
            ) {
                sendKeyEvent(
                    ghosttyKeyEventPlan(
                        for: event,
                        action: action,
                        text: nil,
                        translationModifiers: translationEvent.modifierFlags,
                        composing: false
                    )
                )
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list {
                guard !shouldSuppressComposingControlInput(text, composing: composing) else { continue }
                sendKeyEvent(
                    ghosttyKeyEventPlan(
                        for: event,
                        action: action,
                        text: text,
                        translationModifiers: translationEvent.modifierFlags
                    )
                )
            }
        } else {
            guard !shouldSuppressComposingControlInput(event.characters, composing: composing) else { return }
            sendKeyEvent(
                ghosttyKeyEventPlan(
                    for: event,
                    action: action,
                    text: ghosttyKeyEventText(for: translationEvent),
                    translationModifiers: translationEvent.modifierFlags,
                    composing: composing
                )
            )
        }
    }

    /// Releases carry no text, as in upstream Ghostty.
    package override func keyUp(with event: NSEvent) {
        sendKeyEvent(ghosttyKeyEventPlan(for: event, action: GHOSTTY_ACTION_RELEASE, text: nil))
    }

    /// Modifier-only events follow upstream Ghostty: press or release by
    /// side, never text, and nothing while an input method is composing.
    package override func flagsChanged(with event: NSEvent) {
        guard let plan = ghosttyModifierKeyEventPlan(for: event, hasMarkedText: hasMarkedText()) else { return }
        sendKeyEvent(plan)
    }

    static let appOwnedShortcuts: [AppShortcut] = AppShortcut.allCases.filter {
        $0.contexts.contains(.terminalAppOwned)
    }

    enum TerminalAppOwnedShortcutHandling: Equatable {
        case notHandled
        case swallowed
        case dispatched(AppCommand)
    }

    static func shouldSuppressTerminalHostTrigger(_ trigger: ShortcutTrigger) -> Bool {
        AppShortcutDispatchPolicy.shouldSuppressTerminalHostTrigger(trigger)
    }

    static func handleTerminalAppOwnedShortcut(
        trigger: ShortcutTrigger,
        context: KeyboardRoutingContext,
        sourcePaneId: UUID? = nil,
        canDispatch: (AppCommand, UUID?) -> Bool,
        dispatch: (AppCommand, UUID?) -> Void
    ) -> TerminalAppOwnedShortcutHandling {
        guard let shortcut = ShortcutDecoder.shortcut(for: trigger, in: .terminalAppOwned),
            Self.appOwnedShortcuts.contains(shortcut)
        else {
            return .notHandled
        }

        // A missing Ghostty source must not turn terminal input into a contextual
        // command for whichever pane happens to be selected now.
        if AppShortcutDispatchPolicy.isTerminalRuntimeCommand(shortcut.command), sourcePaneId == nil {
            return .swallowed
        }

        let targetPaneId = AppShortcutDispatchPolicy.sourcePaneTarget(
            for: shortcut.command,
            sourcePaneId: sourcePaneId
        )
        guard
            AppShortcutDispatchPolicy.shouldDispatchTerminalAppOwnedShortcut(shortcut, context: context),
            canDispatch(shortcut.command, targetPaneId)
        else {
            // Terminal app-owned chords are reserved by Agent Studio.
            // Swallow rejected matches so they never leak to Ghostty or
            // host terminal defaults such as clear scrollback.
            return .swallowed
        }

        dispatch(shortcut.command, targetPaneId)
        return .dispatched(shortcut.command)
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // App-owned focus-hygiene exception from #285: reject any view that is not the live first responder.
        guard
            Self.shouldAcceptKeyEquivalent(
                isWindowFirstResponder: window?.firstResponder === self
            )
        else { return false }

        if let trigger = ShortcutDecoder.decode(event: event) {
            if Self.shouldSuppressTerminalHostTrigger(trigger) {
                return true
            }

            let keyboardContext = KeyboardRoutingContext.current(
                windowLifecycle: atom(\.windowLifecycle),
                managementLayer: atom(\.managementLayer),
                uiState: atom(\.workspaceSidebarState),
                commandBarSurface: atom(\.commandBarSurface),
                transientKeyboardSurface: atom(\.transientKeyboardSurface)
            )

            let sourcePaneId =
                terminalRuntime?.paneId.uuid
                ?? SurfaceManager.shared
                .surfaceId(forView: self)
                .flatMap { SurfaceManager.shared.paneId(for: $0) }

            switch Self.handleTerminalAppOwnedShortcut(
                trigger: trigger,
                context: keyboardContext,
                sourcePaneId: sourcePaneId,
                canDispatch: { command, targetPaneId in
                    if let targetPaneId {
                        return appCommandDispatcher.canDispatch(command, target: targetPaneId, targetType: .pane)
                    }
                    return appCommandDispatcher.canDispatch(command)
                },
                dispatch: { command, targetPaneId in
                    if let targetPaneId {
                        appCommandDispatcher.dispatch(command, target: targetPaneId, targetType: .pane)
                        return
                    }
                    appCommandDispatcher.dispatch(command)
                }
            ) {
            case .notHandled:
                break
            case .swallowed, .dispatched:
                return true
            }
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            // App-owned exception 2/2: Agent Studio's menu chords outrank Ghostty defaults.
            if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
                return true
            }
        }

        // We do not port upstream's binding-specific menu dispatch: it depends on
        // keySequence/keyTables and an AppDelegate route that this surface lacks.
        let keyIsBinding = ghosttyKeyBindingMatches(event)
        let decision = ghosttyKeyEquivalentDecision(
            for: GhosttyKeyEquivalentInput(
                isGhosttyBinding: keyIsBinding,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                lastPerformKeyEvent: lastPerformKeyEvent
            )
        )

        switch decision {
        case .handleGhosttyBinding:
            keyDown(with: event)
            return true
        case .handleControlReturn:
            return sendKeyDownEquivalent(event, characters: "\r")
        case .handleControlSlash:
            return sendKeyDownEquivalent(event, characters: "_")
        case .passToSystem:
            return false
        case .resetTimestampAndPassToSystem:
            lastPerformKeyEvent = nil
            return false
        case .rememberTimestamp(let timestamp):
            lastPerformKeyEvent = timestamp
            return false
        case .replayTimestampedKey(let text):
            lastPerformKeyEvent = nil
            return sendKeyDownEquivalent(event, characters: text)
        }
    }

    package override func doCommand(by selector: Selector) {
        guard let currentEvent = NSApp.currentEvent,
            ghosttyShouldRedispatchCommandEvent(
                lastPerformKeyEvent: lastPerformKeyEvent,
                currentEventTimestamp: currentEvent.timestamp
            )
        else {
            return
        }

        NSApp.sendEvent(currentEvent)
    }

    private func ghosttyKeyBindingMatches(_ event: NSEvent) -> Bool {
        guard let surface else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = ghosttyMods(from: event.modifierFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = false
        keyEvent.text = nil

        if event.type == .keyDown || event.type == .keyUp,
            let characters = event.characters(byApplyingModifiers: []),
            let codepoint = characters.unicodeScalars.first
        {
            keyEvent.unshifted_codepoint = codepoint.value
        }

        let consumedModifiers = event.modifierFlags.subtracting([.control, .command])
        keyEvent.consumed_mods = ghosttyMods(from: consumedModifiers)
        let bindingText = ghosttyBindingText(for: event.characters)

        return bindingText.withCString { pointer in
            keyEvent.text = pointer
            var bindingFlags = ghostty_binding_flags_e(0)
            return ghostty_surface_key_is_binding(surface, keyEvent, &bindingFlags)
        }
    }

    private func sendKeyDownEquivalent(_ event: NSEvent, characters: String) -> Bool {
        guard
            let modifiedEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
        else {
            return false
        }

        keyDown(with: modifiedEvent)
        return true
    }

    private func sendKeyEvent(_ plan: GhosttyKeyEventPlan) {
        guard let surface else { return }
        performanceTraceRecorder?.recordSidebarPerformanceTerminalInput()

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = plan.action
        keyEvent.mods = plan.mods
        keyEvent.keycode = plan.keycode
        keyEvent.composing = plan.composing
        keyEvent.unshifted_codepoint = plan.unshiftedCodepoint
        keyEvent.consumed_mods = plan.consumedMods

        if let text = plan.text {
            text.withCString { ptr in
                keyEvent.text = ptr
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            ghostty_surface_key(surface, keyEvent)
        }
    }

    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        performanceTraceRecorder?.recordSidebarPerformanceTerminalInput()

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = 0
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0

        return text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Syncs AppKit's marked text with Ghostty's preedit state.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let text = markedText.string
            let utf8Length = text.utf8CString.count
            guard utf8Length > 0 else { return }
            text.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(utf8Length - 1))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Mouse Input

    package override func mouseDown(with event: NSEvent) {
        sendMouseButton(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    package override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    package override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    package override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    package override func otherMouseDown(with event: NSEvent) {
        let button = ghosttyMouseButton(from: event.buttonNumber)
        sendMouseButton(event, action: GHOSTTY_MOUSE_PRESS, button: button)
    }

    package override func otherMouseUp(with event: NSEvent) {
        let button = ghosttyMouseButton(from: event.buttonNumber)
        sendMouseButton(event, action: GHOSTTY_MOUSE_RELEASE, button: button)
    }

    package override func mouseMoved(with event: NSEvent) {
        guard !atom(\.managementLayer).isActive else { return }
        sendMousePos(event)
    }

    package override func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    package override func rightMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    package override func otherMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    package override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let translatedScroll = GhosttyScrollTranslation.translate(event: event)
        ghostty_surface_mouse_scroll(
            surface,
            translatedScroll.deltaX,
            translatedScroll.deltaY,
            translatedScroll.scrollMods
        )
    }

    private func sendMouseButton(
        _ event: NSEvent,
        action: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        let mods = ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_button(surface, action, button, mods)
    }

    func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }

        let pos = convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
    }

    private func ghosttyMouseButton(from buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        default: return GHOSTTY_MOUSE_LEFT
        }
    }

    // MARK: - Edit Menu Responders

    @objc func copy(_ sender: Any?) {
        _ = performBindingAction(.copyToClipboard)
    }

    @objc func paste(_ sender: Any?) {
        endRestorePhaseIfLatched()
        _ = performBindingAction(.pasteFromClipboard)
    }

    /// SR6b (Program Design item 13): the cold-pane restore-phase latch.
    /// Nil check for every pane that isn't restoring — the one steady-state
    /// cost this adds to every keystroke. For a cold pane's first qualifying
    /// input, one synchronous accumulator call under its own lock; nothing
    /// async runs from here, so there is no `Task` racing output.
    func endRestorePhaseIfLatched() {
        guard let generation = restorePhaseLatch else { return }
        restorePhaseLatch = nil
        guard let paneID = SurfaceManager.shared.paneId(for: managedSurfaceID) else { return }
        Ghostty.ActionRouter.localActionAccumulator.markRestorePhaseEnded(
            surfaceID: managedSurfaceID,
            generation: generation,
            contextBeforeControl: Ghostty.ActionRouter.terminalActivityProjectionContext(paneID: paneID)
        )
    }

    @objc package override func selectAll(_ sender: Any?) {
        _ = performBindingAction(.selectAll)
    }

    // MARK: - Public API

    func sendText(_ text: String) {
        guard let surface else { return }
        performanceTraceRecorder?.recordSidebarPerformanceTerminalInput()
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func bindRuntime(_ runtime: TerminalRuntime) {
        terminalRuntime = runtime
        applyMouseShape(runtime.mouseShape)
        applyMouseVisibility(isVisible: runtime.isMouseVisible)
        observeMouseState(runtime: runtime)
    }

    private func observeMouseState(runtime expectedRuntime: TerminalRuntime) {
        withObservationTracking {
            _ = expectedRuntime.mouseShape
            _ = expectedRuntime.isMouseVisible
        } onChange: { [weak self, weak expectedRuntime] in
            Task { @MainActor [weak self, weak expectedRuntime] in
                guard let self, let expectedRuntime, let runtime = self.terminalRuntime,
                    runtime === expectedRuntime
                else { return }
                self.applyMouseShape(runtime.mouseShape)
                self.applyMouseVisibility(isVisible: runtime.isMouseVisible)
                self.observeMouseState(runtime: runtime)
            }
        }
    }

    private func applyMouseShape(_ mouseShape: TerminalMouseShape?) {
        guard let mouseShape else { return }
        switch mouseShape {
        case .text:
            NSCursor.iBeam.set()
        case .pointer:
            NSCursor.pointingHand.set()
        case .crosshair:
            NSCursor.crosshair.set()
        case .verticalText:
            NSCursor.iBeamCursorForVerticalLayout.set()
        case .other:
            NSCursor.arrow.set()
        }
    }

    func applyMouseVisibility(isVisible: Bool) {
        GhosttyMouseVisibilityCoordinator.update(
            token: mouseVisibilityToken,
            isVisible: isVisible,
            isFocused: focused
        )
    }
}

extension Ghostty.SurfaceView: @preconcurrency NSTextInputClient {
    package func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }

        var text = ""
        switch string {
        case let attributedString as NSAttributedString:
            text = attributedString.string
        case let inputString as NSString:
            if let lead = GhosttyLeadSurrogate(inputString) {
                leadSurrogate = lead
            } else if let trail = GhosttyTrailSurrogate(inputString) {
                text = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                text = inputString as String
                leadSurrogate = nil
            }
        default:
            return
        }

        // SR6b: `insertText` is the IME's commit callback (a composing
        // update goes through `setMarkedText` instead), so every call here
        // is already "committed" — no separate check needed.
        endRestorePhaseIfLatched()
        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
            return
        }

        if !text.isEmpty {
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: text)
        }
    }

    package func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let string = string as? String {
            markedText = NSMutableAttributedString(string: string)
        } else if let attributedString = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributedString)
        }

        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    package func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    package func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }

        // Selection can change between reading this value and AppKit using it.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return ghosttyTextInputSelectionRange(
            offsetStart: Int(text.offset_start),
            offsetLength: Int(text.offset_len)
        )
    }

    package func markedRange() -> NSRange {
        ghosttyTextInputMarkedRange(length: markedText.length)
    }

    package func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    package func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString?
    {
        guard let surface else { return nil }
        guard range.length > 0 else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        // AppKit sometimes proposes unrelated ranges, so return Ghostty's current selection.
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // The dictionary retains the unretained CTFont; release Ghostty's original copy.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return NSAttributedString(string: String(cString: text.text), attributes: attributes)
    }

    package func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    package func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        let cellSize = reportedCellSize ?? .zero
        var x: Double = 0
        var y: Double = 0
        var width = Double(cellSize.width)
        var height = Double(cellSize.height)

        // QuickLook requests a range that differs from the terminal selection.
        if range.length > 0, range != selectedRange() {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }

        let viewRect = ghosttyTextInputViewRect(
            pointAndSize: GhosttyIMEPointAndSize(x: x, y: y, width: width, height: height),
            characterRange: range,
            cellSize: cellSize,
            viewHeight: frame.size.height
        )
        let windowRect = convert(viewRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    package func characterIndex(for point: NSPoint) -> Int {
        0
    }
}
