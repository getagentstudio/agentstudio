import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

/// The key input each AppKit event sends to Ghostty. Plans preserve original
/// modifiers and carry translated text and composing state; modifier events
/// follow upstream Ghostty's `flagsChanged`.
@MainActor
@Suite(.serialized)
struct GhosttyKeyEventPlanTests {
    struct KeyboardLayoutChangeCase: CustomTestStringConvertible, Sendable {
        let name: String
        let hasMarkedTextBefore: Bool
        let keyboardLayoutIDBefore: String?
        let keyboardLayoutIDAfter: String?
        let shouldAbortKeyDown: Bool
        var testDescription: String { name }
    }

    struct ComposingSuppressionCase: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String?
        let composing: Bool
        let shouldSuppress: Bool
        var testDescription: String { name }
    }

    struct CommittedPreeditReplayCase: CustomTestStringConvertible, Sendable {
        let name: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let shouldReplay: Bool
        var testDescription: String { name }
    }

    nonisolated static let keyboardLayoutChangeCases: [KeyboardLayoutChangeCase] = [
        .init(
            name: "unchanged layout without marked text",
            hasMarkedTextBefore: false,
            keyboardLayoutIDBefore: "layout-a",
            keyboardLayoutIDAfter: "layout-a",
            shouldAbortKeyDown: false
        ),
        .init(
            name: "changed layout without marked text",
            hasMarkedTextBefore: false,
            keyboardLayoutIDBefore: "layout-a",
            keyboardLayoutIDAfter: "layout-b",
            shouldAbortKeyDown: true
        ),
        .init(
            name: "missing layout becomes available without marked text",
            hasMarkedTextBefore: false,
            keyboardLayoutIDBefore: nil,
            keyboardLayoutIDAfter: "layout-a",
            shouldAbortKeyDown: true
        ),
        .init(
            name: "unchanged unavailable layout without marked text",
            hasMarkedTextBefore: false,
            keyboardLayoutIDBefore: nil,
            keyboardLayoutIDAfter: nil,
            shouldAbortKeyDown: false
        ),
        .init(
            name: "layout changes while marked text was already active",
            hasMarkedTextBefore: true,
            keyboardLayoutIDBefore: nil,
            keyboardLayoutIDAfter: "layout-b",
            shouldAbortKeyDown: false
        ),
    ]

    nonisolated static let composingSuppressionCases: [ComposingSuppressionCase] = [
        .init(name: "control character while composing", text: "\u{8}", composing: true, shouldSuppress: true),
        .init(name: "unit separator while composing", text: "\u{1F}", composing: true, shouldSuppress: true),
        .init(name: "control character outside composition", text: "\u{8}", composing: false, shouldSuppress: false),
        .init(name: "missing text while composing", text: nil, composing: true, shouldSuppress: false),
        .init(
            name: "multi-character control text while composing", text: "\u{3}x", composing: true, shouldSuppress: false
        ),
        .init(name: "printable text while composing", text: "あ", composing: true, shouldSuppress: false),
        .init(name: "delete character while composing", text: "\u{7F}", composing: true, shouldSuppress: false),
    ]

    nonisolated static let committedPreeditReplayCases: [CommittedPreeditReplayCase] = [
        .init(name: "down arrow", keyCode: 0x7D, modifiers: [], shouldReplay: true),
        .init(name: "right arrow", keyCode: 0x7C, modifiers: [], shouldReplay: true),
        .init(name: "up arrow", keyCode: 0x7E, modifiers: [], shouldReplay: true),
        .init(name: "plain left arrow", keyCode: 0x7B, modifiers: [], shouldReplay: false),
        .init(name: "shift left arrow", keyCode: 0x7B, modifiers: .shift, shouldReplay: true),
        .init(name: "control left arrow", keyCode: 0x7B, modifiers: .control, shouldReplay: true),
        .init(name: "option left arrow", keyCode: 0x7B, modifiers: .option, shouldReplay: true),
        .init(name: "command left arrow", keyCode: 0x7B, modifiers: .command, shouldReplay: true),
        .init(name: "caps-lock left arrow", keyCode: 0x7B, modifiers: .capsLock, shouldReplay: false),
        .init(name: "escape", keyCode: 0x35, modifiers: [], shouldReplay: false),
    ]

    struct ModifierCase: CustomTestStringConvertible, Sendable {
        let name: String
        let keyCode: CGKeyCode
        let flags: UInt64
        let action: ghostty_input_action_e
        var testDescription: String { name }
    }

    nonisolated static let modifierCases: [ModifierCase] = [
        .init(name: "left shift down", keyCode: 0x38, flags: shift | leftShift, action: GHOSTTY_ACTION_PRESS),
        .init(name: "left shift up", keyCode: 0x38, flags: 0, action: GHOSTTY_ACTION_RELEASE),
        .init(name: "right shift down", keyCode: 0x3C, flags: shift | rightShift, action: GHOSTTY_ACTION_PRESS),
        .init(
            name: "right shift up, left held", keyCode: 0x3C, flags: shift | leftShift,
            action: GHOSTTY_ACTION_RELEASE),
        .init(name: "left control down", keyCode: 0x3B, flags: control | leftControl, action: GHOSTTY_ACTION_PRESS),
        .init(name: "left control up", keyCode: 0x3B, flags: 0, action: GHOSTTY_ACTION_RELEASE),
        .init(name: "right control down", keyCode: 0x3E, flags: control | rightControl, action: GHOSTTY_ACTION_PRESS),
        .init(
            name: "right control up, left held", keyCode: 0x3E, flags: control | leftControl,
            action: GHOSTTY_ACTION_RELEASE),
        .init(name: "left option down", keyCode: 0x3A, flags: option | leftOption, action: GHOSTTY_ACTION_PRESS),
        .init(name: "left option up", keyCode: 0x3A, flags: 0, action: GHOSTTY_ACTION_RELEASE),
        .init(name: "right option down", keyCode: 0x3D, flags: option | rightOption, action: GHOSTTY_ACTION_PRESS),
        .init(
            name: "right option up, left held", keyCode: 0x3D, flags: option | leftOption,
            action: GHOSTTY_ACTION_RELEASE),
        .init(name: "left command down", keyCode: 0x37, flags: command | leftCommand, action: GHOSTTY_ACTION_PRESS),
        .init(name: "left command up", keyCode: 0x37, flags: 0, action: GHOSTTY_ACTION_RELEASE),
        .init(name: "right command down", keyCode: 0x36, flags: command | rightCommand, action: GHOSTTY_ACTION_PRESS),
        .init(
            name: "right command up, left held", keyCode: 0x36, flags: command | leftCommand,
            action: GHOSTTY_ACTION_RELEASE),
        .init(name: "caps lock on", keyCode: 0x39, flags: capsLock, action: GHOSTTY_ACTION_PRESS),
        .init(name: "caps lock off", keyCode: 0x39, flags: 0, action: GHOSTTY_ACTION_RELEASE),
    ]

    @Test(
        "keyboard layout changes suppress keyDown only outside an existing composition",
        arguments: keyboardLayoutChangeCases)
    func keyboardLayoutChangeDecision(testCase: KeyboardLayoutChangeCase) {
        var layoutIDReads = 0

        let shouldAbortKeyDown = shouldAbortKeyDownForKeyboardLayoutChange(
            hasMarkedTextBefore: testCase.hasMarkedTextBefore,
            keyboardLayoutIDBefore: testCase.keyboardLayoutIDBefore,
            currentKeyboardLayoutID: {
                layoutIDReads += 1
                return testCase.keyboardLayoutIDAfter
            }
        )

        #expect(shouldAbortKeyDown == testCase.shouldAbortKeyDown)
        #expect(layoutIDReads == (testCase.hasMarkedTextBefore ? 0 : 1))
    }

    @Test("single control characters are suppressed only while composing", arguments: composingSuppressionCases)
    func composingSuppressionDecision(testCase: ComposingSuppressionCase) {
        #expect(
            shouldSuppressComposingControlInput(testCase.text, composing: testCase.composing)
                == testCase.shouldSuppress
        )
    }

    @Test(
        "committed preedit replays only navigation keys that still affect the terminal",
        arguments: committedPreeditReplayCases)
    func committedPreeditReplayDecision(testCase: CommittedPreeditReplayCase) {
        #expect(
            shouldReplayCommittedPreeditKey(keyCode: testCase.keyCode, modifierFlags: testCase.modifiers)
                == testCase.shouldReplay
        )
    }

    @Test("key event plans preserve the composing state")
    func keyEventPlanComposingState() throws {
        let event = try Self.keyEvent(.keyDown, characters: "a", flags: [], keyCode: 0)

        let plan = ghosttyKeyEventPlan(
            for: event,
            action: GHOSTTY_ACTION_PRESS,
            text: "a",
            composing: true
        )

        #expect(plan.composing)
    }

    @Test("split UTF-16 surrogate input joins into one committed scalar")
    func splitSurrogateInputJoinsIntoOneScalar() {
        let leadText = Self.nsString(codeUnits: [0xD83D])
        let trailText = Self.nsString(codeUnits: [0xDE00])

        guard let lead = GhosttyLeadSurrogate(leadText), let trail = GhosttyTrailSurrogate(trailText) else {
            #expect(Bool(false))
            return
        }

        #expect(lead.encode(trail: trail) == "😀")
        #expect(GhosttyLeadSurrogate(Self.nsString(codeUnits: [0xD83D, 0xDE00])) == nil)
        #expect(GhosttyTrailSurrogate(Self.nsString(codeUnits: [0xD83D, 0xDE00])) == nil)
    }

    @Test("modifier events press or release by side and never read or send text", arguments: modifierCases)
    func modifierEventPlan(testCase: ModifierCase) throws {
        // Arrange
        let event = try Self.modifierEvent(keyCode: testCase.keyCode, flags: testCase.flags)

        // Act
        let plan = try #require(ghosttyModifierKeyEventPlan(for: event, hasMarkedText: false))

        // Assert
        #expect(plan.action == testCase.action)
        #expect(plan.keycode == UInt32(testCase.keyCode))
        #expect(plan.mods == ghosttyMods(from: event.modifierFlags))
        #expect(plan.text == nil)
        #expect(plan.unshiftedCodepoint == 0)
    }

    @Test("a held command modifier reaches Ghostty as SUPER")
    func commandPressCarriesSuper() throws {
        let event = try Self.modifierEvent(keyCode: 0x37, flags: Self.command | Self.leftCommand)

        let plan = try #require(ghosttyModifierKeyEventPlan(for: event, hasMarkedText: false))

        #expect(plan.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
        #expect(plan.consumedMods.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0)
    }

    @Test("no modifier event is sent while an input method is composing")
    func markedTextSendsNothing() throws {
        let event = try Self.modifierEvent(keyCode: 0x3A, flags: Self.option | Self.leftOption)

        #expect(ghosttyModifierKeyEventPlan(for: event, hasMarkedText: true) == nil)
    }

    @Test("a key code that is not a modifier sends nothing")
    func unknownModifierKeyCodeSendsNothing() throws {
        let functionKeyCode: CGKeyCode = 0x3F
        let event = try Self.modifierEvent(keyCode: functionKeyCode, flags: 0)

        #expect(ghosttyModifierKeyEventPlan(for: event, hasMarkedText: false) == nil)
    }

    @Test("a key release sends no text")
    func keyUpSendsNoText() throws {
        let event = try Self.keyEvent(.keyUp, characters: "a", flags: [], keyCode: 0)

        let plan = ghosttyKeyEventPlan(for: event, action: GHOSTTY_ACTION_RELEASE, text: nil)

        #expect(plan.action == GHOSTTY_ACTION_RELEASE)
        #expect(plan.text == nil)
        #expect(ghosttyKeyEventText(for: event) == nil)
    }

    struct KeyDownCase: CustomTestStringConvertible, Sendable {
        let name: String
        let characters: String
        let flags: NSEvent.ModifierFlags
        let keyCode: UInt16
        let text: String?
        let mods: UInt32
        let consumedMods: UInt32
        var testDescription: String { name }
    }

    nonisolated static let keyDownCases: [KeyDownCase] = [
        .init(
            name: "a", characters: "a", flags: [], keyCode: 0, text: "a",
            mods: GHOSTTY_MODS_NONE.rawValue, consumedMods: GHOSTTY_MODS_NONE.rawValue),
        .init(
            name: "shift+a", characters: "A", flags: .shift, keyCode: 0, text: "A",
            mods: GHOSTTY_MODS_SHIFT.rawValue, consumedMods: GHOSTTY_MODS_SHIFT.rawValue),
        .init(
            name: "option+a", characters: "å", flags: .option, keyCode: 0, text: "å",
            mods: GHOSTTY_MODS_ALT.rawValue, consumedMods: GHOSTTY_MODS_ALT.rawValue),
        .init(
            name: "option+left arrow", characters: "\u{F702}", flags: .option, keyCode: 123, text: nil,
            mods: GHOSTTY_MODS_ALT.rawValue, consumedMods: GHOSTTY_MODS_ALT.rawValue),
        .init(
            name: "control+c", characters: "\u{3}", flags: .control, keyCode: 8, text: "c",
            mods: GHOSTTY_MODS_CTRL.rawValue, consumedMods: GHOSTTY_MODS_NONE.rawValue),
        .init(
            name: "right shift+a", characters: "A",
            flags: NSEvent.ModifierFlags(rawValue: UInt(shift | rightShift)), keyCode: 0, text: "A",
            mods: GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue,
            consumedMods: GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue),
        .init(
            name: "right control+c", characters: "c",
            flags: NSEvent.ModifierFlags(rawValue: UInt(control | rightControl)), keyCode: 8, text: "c",
            mods: GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_CTRL_RIGHT.rawValue,
            consumedMods: GHOSTTY_MODS_CTRL_RIGHT.rawValue),
        .init(
            name: "right option+a", characters: "å",
            flags: NSEvent.ModifierFlags(rawValue: UInt(option | rightOption)), keyCode: 0, text: "å",
            mods: GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_ALT_RIGHT.rawValue,
            consumedMods: GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_ALT_RIGHT.rawValue),
        .init(
            name: "right command+a", characters: "a",
            flags: NSEvent.ModifierFlags(rawValue: UInt(command | rightCommand)), keyCode: 0, text: "a",
            mods: GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SUPER_RIGHT.rawValue,
            consumedMods: GHOSTTY_MODS_SUPER_RIGHT.rawValue),
    ]

    @Test("key-down text and modifiers are unchanged", arguments: keyDownCases)
    func keyDownPlanIsUnchanged(testCase: KeyDownCase) throws {
        // Arrange
        let event = try Self.keyEvent(
            .keyDown, characters: testCase.characters, flags: testCase.flags, keyCode: testCase.keyCode)

        // Act — the non-IME keyDown path.
        let plan = ghosttyKeyEventPlan(for: event, action: GHOSTTY_ACTION_PRESS, text: ghosttyKeyEventText(for: event))

        // Assert
        #expect(plan.action == GHOSTTY_ACTION_PRESS)
        #expect(plan.text == testCase.text)
        #expect(plan.mods.rawValue == testCase.mods)
        #expect(plan.consumedMods.rawValue == testCase.consumedMods)
    }

    @Test("input-method text reaches Ghostty unchanged")
    func inputMethodTextIsUnchanged() throws {
        let event = try Self.keyEvent(.keyDown, characters: "a", flags: [], keyCode: 0)

        let plan = ghosttyKeyEventPlan(for: event, action: GHOSTTY_ACTION_PRESS, text: "あ")

        #expect(plan.text == "あ")
    }

    @Test("option-as-alt translation preserves original mods and excludes translated option from consumed mods")
    func optionAsAltTranslationPreservesOriginalModifiers() throws {
        let event = try Self.keyEvent(
            .keyDown,
            characters: "å",
            flags: [.option, .shift, .control, .command, .capsLock, .numericPad],
            keyCode: 0
        )
        var receivedModifiers: UInt32?
        let fakeTranslationModsProvider: (ghostty_input_mods_e) -> ghostty_input_mods_e = { originalMods in
            receivedModifiers = originalMods.rawValue
            return ghostty_input_mods_e(rawValue: originalMods.rawValue & ~GHOSTTY_MODS_ALT.rawValue)
        }

        let translation = ghosttyKeyTranslationPlan(for: event, using: fakeTranslationModsProvider)
        let plan = ghosttyKeyEventPlan(
            for: event,
            action: GHOSTTY_ACTION_PRESS,
            text: "a",
            translationModifiers: translation.event.modifierFlags
        )

        #expect(translation.event !== event)
        #expect(translation.event.modifierFlags.contains(.shift))
        #expect(translation.event.modifierFlags.contains(.control))
        #expect(translation.event.modifierFlags.contains(.command))
        #expect(!translation.event.modifierFlags.contains(.option))
        #expect(translation.event.modifierFlags.contains(.capsLock))
        #expect(translation.event.modifierFlags.contains(.numericPad))
        #expect(receivedModifiers == ghosttyMods(from: event.modifierFlags).rawValue)
        #expect(plan.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(plan.consumedMods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0)
        #expect(plan.consumedMods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(plan.consumedMods.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)
        #expect(plan.consumedMods.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0)
    }

    @Test("key translation reuses the original event when Ghostty leaves modifiers unchanged")
    func unchangedKeyTranslationReusesOriginalEvent() throws {
        let event = try Self.keyEvent(.keyDown, characters: "a", flags: [.shift, .option], keyCode: 0)

        let translation = ghosttyKeyTranslationPlan(for: event) { originalMods in originalMods }

        #expect(translation.event === event)
        #expect(translation.event.modifierFlags == event.modifierFlags)
    }

    // MARK: - Events

    nonisolated private static let shift = CGEventFlags.maskShift.rawValue
    nonisolated private static let control = CGEventFlags.maskControl.rawValue
    nonisolated private static let option = CGEventFlags.maskAlternate.rawValue
    nonisolated private static let command = CGEventFlags.maskCommand.rawValue
    nonisolated private static let capsLock = CGEventFlags.maskAlphaShift.rawValue
    nonisolated private static let leftShift = UInt64(NX_DEVICELSHIFTKEYMASK)
    nonisolated private static let rightShift = UInt64(NX_DEVICERSHIFTKEYMASK)
    nonisolated private static let leftControl = UInt64(NX_DEVICELCTLKEYMASK)
    nonisolated private static let rightControl = UInt64(NX_DEVICERCTLKEYMASK)
    nonisolated private static let leftOption = UInt64(NX_DEVICELALTKEYMASK)
    nonisolated private static let rightOption = UInt64(NX_DEVICERALTKEYMASK)
    nonisolated private static let leftCommand = UInt64(NX_DEVICELCMDKEYMASK)
    nonisolated private static let rightCommand = UInt64(NX_DEVICERCMDKEYMASK)

    /// A real `.flagsChanged` event: reading `characters` from it raises.
    private static func modifierEvent(keyCode: CGKeyCode, flags: UInt64) throws -> NSEvent {
        let source = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        source.type = .flagsChanged
        source.flags = CGEventFlags(rawValue: flags)
        let event = try #require(NSEvent(cgEvent: source))
        #expect(event.type == .flagsChanged)
        return event
    }

    private static func keyEvent(
        _ type: NSEvent.EventType,
        characters: String,
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private static func nsString(codeUnits: [UInt16]) -> NSString {
        codeUnits.withUnsafeBufferPointer { buffer in
            guard let characters = buffer.baseAddress else { return NSString(string: "") }
            return NSString(characters: characters, length: buffer.count)
        }
    }
}
