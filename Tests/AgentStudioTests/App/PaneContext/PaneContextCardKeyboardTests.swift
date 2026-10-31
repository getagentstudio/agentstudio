import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Management-card native keyboard ownership", .serialized)
struct PaneContextCardKeyboardTests {
    @Test("D80 a focused card receives native typing through the real management monitor and submits that text")
    func focusedCardTypingReachesTheRealPersonService() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        let atoms = CoreAtomScope.store
        defer {
            // Record product cleanup assertions before clearing only this fixture's leaked data on a faulted subject.
            for surface in atoms.transientKeyboardSurface.surfaces
            where surface.kind == .paneContextCardTextForm(paneId: host.fixture.ownerId.uuid) {
                atoms.transientKeyboardSurface.dismiss(surface.token)
            }
        }
        let workspaceWindowId = UUIDv7.generate()
        atoms.windowLifecycle.recordWindowRegistered(workspaceWindowId)
        atoms.windowLifecycle.recordWindowBecameKey(workspaceWindowId)
        let monitor = ManagementLayerMonitor(commandDispatcher: AppTerminalFixtureCommandDispatcher())
        do {
            try #require(atoms.transientKeyboardSurface.surfaces.isEmpty)
            monitor.toggle()
            try await host.open()
            try #require(host.window.native.window.makeFirstResponder(host.window.native.window))
            host.window.native.layout()
            #expect(
                monitor.keyDownDecision(keyCode: 0, modifierFlags: [], charactersIgnoringModifiers: "a") == .consume)
            let field = try #require(host.window.native.editableFields.first)
            field.selectText(nil)
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(field.window?.firstResponder === editor)
            try send("a", code: 0, to: host.window.native.window)
            host.window.native.layout()
            #expect(field.stringValue == "a", "The actual management monitor must allow the focused card's native edit")
            monitor.stopMonitoring()
            try send("b", code: 11, to: host.window.native.window)
            host.window.native.layout()
            #expect(field.stringValue == "ab", "The same native route must keep working after monitor retirement")
            #expect(await host.person.answers.isEmpty)
            try host.window.native.press("pane-context.submit." + host.scope)
            try await host.window.actionCompleted()
            #expect(
                await host.person.answers == [
                    .init(messageId: host.id, paneId: host.fixture.ownerId, by: .localUser, value: .text("ab"))
                ])
            monitor.deactivate()
            try await host.close()
            #expect(atoms.transientKeyboardSurface.surfaces.isEmpty)
            atoms.windowLifecycle.recordWindowResignedKey(workspaceWindowId)
            atoms.windowLifecycle.recordWindowResignedFocused(workspaceWindowId)
        } catch {
            monitor.stopMonitoring()
            monitor.deactivate()
            try? await host.close()
            atoms.windowLifecycle.recordWindowResignedKey(workspaceWindowId)
            atoms.windowLifecycle.recordWindowResignedFocused(workspaceWindowId)
            throw error
        }
    }

    @Test("D80 an unfocused card withdraws its claim and the real monitor still consumes management typing")
    func focusLossRestoresManagementConsumption() async throws {
        let rig = try await PaneContextCardKeyboardWindow.make()
        do {
            try rig.focusReceiver()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            try rig.focusCard(0)
            #expect(
                CoreAtomScope.store.transientKeyboardSurface.surfaces.map(\.kind) == [
                    .paneContextCardTextForm(paneId: rig.cards[0].pane.uuid)
                ])
            try rig.focusReceiver()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            try rig.send("a", code: 0)
            #expect(rig.keyReceiver.received.isEmpty, "Unfocused management typing must still be consumed")
            rig.monitor.stopMonitoring()
            try rig.send("b", code: 11)
            #expect(rig.keyReceiver.received == ["b"], "The same real native receiver proves the event route is active")
            await rig.close()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
        } catch {
            await rig.close()
            throw error
        }
    }

    @Test("D80 two mounted cards register only the actual focused field, including shared-editor transfers")
    func twoCardsOnlyTheFocusedOneClaims() async throws {
        let rig = try await PaneContextCardKeyboardWindow.make()
        do {
            try rig.focusReceiver()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            for index in [0, 1, 0] {
                try rig.focusCard(index)
                #expect(
                    CoreAtomScope.store.transientKeyboardSurface.surfaces.map(\.kind) == [
                        .paneContextCardTextForm(paneId: rig.cards[index].pane.uuid)
                    ], "Only the native field's card may claim, before another layout or key event")
            }
            await rig.close()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
        } catch {
            await rig.close()
            throw error
        }
    }

    @Test("D80 card retirement and management exit both withdraw the focused registration", arguments: [true, false])
    func retirementAndManagementExitWithdrawClaims(retire: Bool) async throws {
        let rig = try await PaneContextCardKeyboardWindow.make()
        do {
            try rig.focusCard(0)
            try #require(CoreAtomScope.store.transientKeyboardSurface.surfaces.count == 1)
            if retire {
                rig.retireCards()
            } else {
                rig.monitor.deactivate()
                rig.render()
            }
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            await rig.close()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
        } catch {
            await rig.close()
            throw error
        }
    }

    @Test("D80 Escape reaches native editing first; after focus leaves, Escape exits management")
    func nativeEditingPrecedesManagementEscape() async throws {
        let rig = try await PaneContextCardKeyboardWindow.make()
        do {
            try rig.focusCard(0)
            #expect(
                rig.monitor.keyDownDecision(keyCode: 53, modifierFlags: [], charactersIgnoringModifiers: "\u{1b}")
                    == .passThrough)
            try rig.send("\u{1b}", code: 53)
            #expect(rig.monitor.isActive, "Native editing owns Escape while its field is focused")
            try rig.focusReceiver()
            #expect(CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty)
            try rig.send("\u{1b}", code: 53)
            #expect(!rig.monitor.isActive, "Management receives Escape once native editing releases focus")
            await rig.close()
        } catch {
            await rig.close()
            throw error
        }
    }

    private func send(_ text: String, code: UInt16, to window: NSWindow) throws {
        let event = try #require(
            makeKeyEvent(
                characters: text, charactersIgnoringModifiers: text, keyCode: code, windowNumber: window.windowNumber))
        NSApp.sendEvent(event)
    }

    @Test("D80 the normal Messages window retains native typing and acquires no card keyboard claim")
    func messagesInTheirOwnWindowStillReceiveTyping() async throws {
        let host = try await PaneContextCardServiceHost.make(form: .freeText(placeholder: "Reply"))
        let monitor = ManagementLayerMonitor(commandDispatcher: AppTerminalFixtureCommandDispatcher())
        do {
            try #require(!monitor.isActive, "This regression covers normal Messages typing outside management mode")
            try await host.open()
            let opening = try host.window.beginOpening()
            try await host.window.completeOpening(opening)
            try await host.window.rendered()
            let popover = try #require(host.window.native.popoverWindow)
            try #require(popover !== host.window.native.window)
            let field = try #require(host.window.native.editableFields.first { $0.window === popover })
            field.selectText(nil)
            try #require(popover.firstResponder === field.currentEditor())
            try send("a", code: 0, to: popover)
            #expect(field.stringValue == "a")
            #expect(
                CoreAtomScope.store.transientKeyboardSurface.surfaces.isEmpty,
                "A separate Messages editor must never create the card-only registration")
            monitor.stopMonitoring()
            try await host.close()
        } catch {
            monitor.stopMonitoring()
            try? await host.close()
            throw error
        }
    }
}
