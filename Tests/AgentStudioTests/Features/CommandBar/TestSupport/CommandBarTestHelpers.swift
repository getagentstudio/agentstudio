import AppKit
import Testing

@testable import AgentStudioCommandBar
@testable import AgentStudioCore

func commandBarSurfaceRejectedTargetedSpecResolver(
    command: AppCommand,
    targetType: SearchItemType
) -> AppCommandSpec? {
    let catalogSpec = command.definition
    return CommandBarCommandPresentation.commandBarTargetedSpec(
        for: command,
        targetType: targetType,
        definitionResolver: { requestedCommand in
            guard requestedCommand == command else { return requestedCommand.definition }
            return AppCommandSpec(
                command: catalogSpec.command,
                shortcut: catalogSpec.shortcut,
                displayShortcutTrigger: catalogSpec.displayShortcutTrigger,
                label: catalogSpec.label,
                icon: catalogSpec.icon,
                helpText: catalogSpec.helpText,
                surfacePolicy: .exposed([.contextMenu]),
                targeting: catalogSpec.targeting,
                requiresManagementLayer: catalogSpec.requiresManagementLayer,
                visibleWhen: catalogSpec.visibleWhen,
                commandBarGroupName: catalogSpec.commandBarGroupName,
                commandBarGroupPriority: catalogSpec.commandBarGroupPriority
            )
        }
    )
}

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

@MainActor
func eventually(
    _ description: String,
    maxTurns: Int = 200,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<maxTurns {
        if condition() {
            return
        }
        await Task.yield()
    }
    #expect(condition(), "\(description) timed out")
}
