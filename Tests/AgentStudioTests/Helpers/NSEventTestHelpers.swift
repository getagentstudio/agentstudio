import AppKit

/// Creates a synthetic keyboard event for testing
@MainActor
func makeKeyEvent(
    type: NSEvent.EventType = .keyDown,
    modifierFlags: NSEvent.ModifierFlags = [],
    characters: String = "",
    charactersIgnoringModifiers: String = "",
    keyCode: UInt16 = 0,
    windowNumber: Int = 0,
    isARepeat: Bool = false
) -> NSEvent? {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: isARepeat,
        keyCode: keyCode
    )
}
