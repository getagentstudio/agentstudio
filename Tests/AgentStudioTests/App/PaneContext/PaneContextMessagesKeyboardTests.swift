import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Messages native keyboard events", .serialized)
struct PaneContextMessagesKeyboardTests {
    @Test("Normal Messages receives a real application key event in its own native editor")
    func messagesInTheirOwnWindowStillReceiveTyping() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        let monitor = ManagementLayerMonitor(commandDispatcher: AppTerminalFixtureCommandDispatcher())
        do {
            try #require(!monitor.isActive, "Normal Messages typing is outside management mode")
            try await host.open()
            let opening = try host.window.beginOpening()
            try await host.window.completeOpening(opening)
            try await host.window.rendered()
            let popover = try #require(host.window.native.popoverWindow)
            try #require(popover !== host.window.native.window)
            let field = try #require(host.window.native.editableFields.first { $0.window === popover })
            field.selectText(nil)
            try #require(popover.firstResponder === field.currentEditor())
            let event = try #require(
                makeKeyEvent(
                    characters: "a", charactersIgnoringModifiers: "a", keyCode: 0, windowNumber: popover.windowNumber))
            NSApp.sendEvent(event)
            #expect(field.stringValue == "a")
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            monitor.stopMonitoring()
            try await host.close()
        } catch {
            monitor.stopMonitoring()
            try? await host.close()
            throw error
        }
    }
}
