import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite(.serialized)
final class KeyboardCharacterFilteringTests {
    struct KeyEventTextCase: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String?
        let expectedText: String?
        var testDescription: String { name }
    }

    nonisolated static let keyEventTextCases: [KeyEventTextCase] = [
        .init(name: "nil text", text: nil, expectedText: nil),
        .init(name: "empty text", text: "", expectedText: nil),
        .init(name: "single C0 control", text: "\u{03}", expectedText: nil),
        .init(name: "single DEL", text: "\u{7F}", expectedText: nil),
        .init(name: "text begins with C0 control", text: "\u{03}x", expectedText: nil),
        .init(name: "text begins with DEL", text: "\u{7F}x", expectedText: nil),
        .init(name: "ordinary text", text: "c", expectedText: "c"),
        .init(name: "space", text: " ", expectedText: " "),
        .init(name: "non-ASCII text", text: "あ", expectedText: "あ"),
        .init(name: "PUA key text", text: "\u{F704}", expectedText: "\u{F704}"),
        .init(name: "printable text containing DEL later", text: "x\u{7F}", expectedText: "x\u{7F}"),
    ]

    @Test("Ghostty key text rejects empty or leading ASCII control text", arguments: keyEventTextCases)
    func ghosttyKeyEventTextFilter(testCase: KeyEventTextCase) {
        #expect(ghosttyKeyEventText(from: testCase.text) == testCase.expectedText)
    }

    // MARK: - filterGhosttyCharacters Tests

    @Test
    func test_filterGhosttyCharacters_nilInput_returnsNil() {
        // Arrange
        let characters: String? = nil

        // Act
        let result = filterGhosttyCharacters(
            characters: characters,
            byApplyingModifiers: { _ in "x" },
            modifierFlags: []
        )

        // Assert
        #expect(result == nil)
    }

    @Test
    func test_filterGhosttyCharacters_normalChar_returnsUnchanged() {
        // Arrange
        let characters = "a"

        // Act
        let result = filterGhosttyCharacters(
            characters: characters,
            byApplyingModifiers: { _ in "x" },
            modifierFlags: []
        )

        // Assert
        #expect(result == "a")
    }

    @Test
    func test_filterGhosttyCharacters_controlChar_stripsControlModifier() {
        // Arrange - 0x03 is Ctrl+C
        let characters = "\u{03}"
        var appliedFlags: NSEvent.ModifierFlags?

        // Act
        let result = filterGhosttyCharacters(
            characters: characters,
            byApplyingModifiers: { flags in
                appliedFlags = flags
                return "c"
            },
            modifierFlags: .control
        )

        // Assert
        #expect(result == "c")
        #expect(appliedFlags != nil)
        #expect(!(appliedFlags!.contains(.control)), "Control should be stripped")
    }

    @Test
    func test_filterGhosttyCharacters_functionKey_returnsNil() {
        // Arrange - F1 key in PUA range
        let characters = "\u{F704}"  // NSF1FunctionKey

        // Act
        let result = filterGhosttyCharacters(
            characters: characters,
            byApplyingModifiers: { _ in "x" },
            modifierFlags: []
        )

        // Assert
        #expect(result == nil, "Function keys should not be sent as text")
    }

    // MARK: - ghosttyKeyEventText Tests

    @Test("a modifier-only flagsChanged event reads no characters and keeps its modifier state")
    func test_ghosttyKeyEventText_flagsChanged_sendsNoTextAndKeepsMods() throws {
        // Arrange - Command pressed alone, as AppKit delivers it to flagsChanged.
        let commandKeyCode: CGKeyCode = 0x37
        let source = try #require(CGEvent(keyboardEventSource: nil, virtualKey: commandKeyCode, keyDown: true))
        source.type = .flagsChanged
        source.flags = .maskCommand
        let event = try #require(NSEvent(cgEvent: source))
        #expect(event.type == .flagsChanged)

        // Act - reading characters from this event raises in AppKit.
        let text = ghosttyKeyEventText(for: event)
        let mods = ghosttyMods(from: event.modifierFlags)

        // Assert
        #expect(text == nil)
        #expect(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test("a key-down event keeps its filtered text")
    func test_ghosttyKeyEventText_keyDown_returnsCharacters() throws {
        // Arrange
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        // Act
        let text = ghosttyKeyEventText(for: event)

        // Assert
        #expect(text == "a")
    }
}
