import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Live native Messages forms", .serialized)
struct PaneContextPopoverNativeServiceTests {
    @Test(
        "G13/G14 native forms submit once through the refresh owner and SQLite, then disappear",
        arguments: ExistingPopoverForm.allCases, [PaneContextPopoverLocation.sidebar, .pane])
    func nativeFormsSettleAndRebind(form: ExistingPopoverForm, location: PaneContextPopoverLocation) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender,
                        sourceOccurredAt: nil, importance: .attention, body: "Answer this request",
                        why: "Native form proof",
                        actions: [], shape: .ask(reason: .question, form: try form.request(), waiting: .nonBlocking)))
                    == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let person = PaneContextNativePersonRecorder(service)
            let adapter = PaneContextUIAdapter(reader: service, person: person)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                location: location, wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            #expect(mounted.native.find("pane-context.dismiss-all-notices") == nil)
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            try fillAndSubmit(form, in: mounted, row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
            try await mounted.actionCompleted()
            mounted.native.layout()
            try await mounted.rendered()
            #expect(
                await person.answers == [
                    .init(
                        messageId: id, paneId: fixture.ownerId,
                        by: .localUser, value: try form.expectedAnswer())
                ])
            guard case .detail(let detail) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else {
                throw NativePopoverProofFailure.missingDetail
            }
            #expect(
                detail.messages.first?.shape
                    == .ask(
                        .question, try form.request(), .nonBlocking,
                        .answered(by: .localUser, value: try form.expectedAnswer(), receipt: .notYetConfirmed)))
            assertNoForm(in: mounted.native, scope: scope)
            #expect(mounted.native.labels().contains { $0.contains("Answer sent, waiting for the agent") })
            guard
                case .page(let changes) = await service.changes(
                    .init(
                        paneId: fixture.ownerId,
                        writer: sender, after: .init(0)))
            else { throw NativePopoverProofFailure.missingDetail }
            #expect(changes.entries.map(\.messageId) == [id])
            #expect(changes.entries.map(\.kind) == [.answer(try form.expectedAnswer())])
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G09 colliding message IDs keep separate native drafts and source/form parsing")
    func collidingDrawerAndOwnerIDsUseTheirOwnDrafts() async throws {
        installTestCoreAtomsIfNeeded()
        let atoms = CoreAtomScope.store
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        let pane = store.createPane(title: "Collision owner")
        defer { store.removePane(pane.id) }
        let fixture = try await CompositionFactoryFixture.make(ownerId: .init(existingUUID: pane.id))
        try #require(
            store.paneAtom.addDrawerPane(
                to: pane.id, content: pane.content, metadata: pane.metadata,
                childPaneId: fixture.drawerId.uuid, expandsDrawer: false) != nil)
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let owner = try await fixture.bind(paneId: fixture.ownerId)
            let drawer = try await fixture.bind(paneId: fixture.drawerId)
            let id = AgentMessageId.generateUUIDv7()
            for (source, binding, form) in [
                (fixture.ownerId, owner, ExistingPopoverForm.multipleChoice),
                (fixture.drawerId, drawer, .freeText),
            ] {
                try #require(
                    await service.send(
                        .init(
                            paneId: source, messageId: id, sender: try fixture.sender(binding),
                            sourceOccurredAt: nil, importance: .attention, body: "Scoped \(form)", why: nil,
                            actions: [],
                            shape: .ask(reason: .question, form: try form.request(), waiting: .nonBlocking)))
                        == .created(id))
            }
            await fixture.composition.presentationLane.publishPending()
            let person = PaneContextNativePersonRecorder(service)
            let adapter = PaneContextUIAdapter(reader: service, person: person)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                location: .sidebar, wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            let ownerScope = "\(fixture.ownerId.uuid).\(id.uuid)"
            let drawerScope = "\(fixture.drawerId.uuid).\(id.uuid)"
            try mounted.native.press("pane-context.choice.red.\(ownerScope)")
            try fillAndSubmit(
                .freeText, in: mounted, row: .init(sourcePaneId: fixture.drawerId.uuid, messageId: id.uuid))
            try await mounted.actionCompleted()
            mounted.native.layout()
            try await mounted.rendered()
            #expect(
                await person.answers == [
                    .init(
                        messageId: id, paneId: fixture.drawerId,
                        by: .localUser, value: .text("A real response"))
                ])
            #expect(mounted.native.find("pane-context.submit.\(ownerScope)") != nil)
            assertNoForm(in: mounted.native, scope: drawerScope, otherChoicesRemain: true)
            try mounted.native.press("pane-context.submit.\(ownerScope)")
            try await mounted.actionCompleted(1)
            #expect(
                await person.answers == [
                    .init(messageId: id, paneId: fixture.drawerId, by: .localUser, value: .text("A real response")),
                    .init(messageId: id, paneId: fixture.ownerId, by: .localUser, value: .choices([try .init("red")])),
                ])
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test(
        "G13/G15 real cursor acknowledgment and real sender end rebind settled native controls",
        arguments: [true, false])
    func receiptTransitionsKeepControlsAbsent(confirm: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender,
                        sourceOccurredAt: nil, importance: .attention, body: "A receipt request", why: nil, actions: [],
                        shape: .ask(
                            reason: .question, form: try ExistingPopoverForm.singleChoice.request(),
                            waiting: .nonBlocking))) == .created(id))
            let hook = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.drawerId.uuid,
                    providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "independent-prompt",
                    eventName: SessionProviderSignal.permission(toolName: "Bash", questions: nil).name,
                    turnId: nil, signal: .permission(toolName: "Bash", questions: nil), recordId: UUIDv7.generate(),
                    admittedAt: fixture.now, chain: TestMainAgentChain.observation))
            guard case .committed = hook else { throw NativePopoverProofFailure.missingDetail }
            let status = SessionStatusAtom()
            let mailbox = await fixture.composition.ingestion.statusPublicationMailbox
            status.apply(mailbox.takeBatch())
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: status, presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                location: .sidebar, wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            try mounted.bindSingleChoice("blue", row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
            try mounted.native.press("pane-context.submit.\(scope)")
            try await mounted.actionCompleted()
            mounted.native.layout()
            try await mounted.rendered()
            assertNoForm(in: mounted.native, scope: scope)
            #expect(mounted.native.labels().contains("Answer sent, waiting for the agent"))
            guard
                case .page(let pending) = await service.changes(
                    .init(
                        paneId: fixture.ownerId,
                        writer: sender, after: .init(0)))
            else { throw NativePopoverProofFailure.missingDetail }
            #expect(pending.entries.map(\.kind) == [.answer(.choices([try .init("blue")]))])
            if confirm {
                guard
                    case .page(let acknowledged) = await service.changes(
                        .init(
                            paneId: fixture.ownerId,
                            writer: sender, after: pending.nextPosition))
                else { throw NativePopoverProofFailure.missingDetail }
                #expect(acknowledged.entries.isEmpty)
            } else {
                let ended = try await fixture.composition.liveSessionsAdapter.recordProviderEvent(
                    paneId: fixture.ownerId.uuid,
                    params: .init(
                        handle: "self",
                        provider: .init(
                            identifier: ClaudeCodeProviderIdentity.identifier,
                            version: ClaudeCodeProviderIdentity.supportedExactVersion,
                            mode: ClaudeCodeProviderIdentity.operatingMode),
                        event: .init(
                            name: .sessionEnd, conversationId: binding.providerConversationId,
                            turnId: nil, requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                        correlationId: UUIDv7.generate()), provenance: .matchingPane)
                #expect(ended.disposition == .admitted)
            }
            await fixture.composition.presentationLane.publishPending()
            try await mounted.refresh()
            mounted.native.layout()
            try await mounted.rendered()
            assertNoForm(in: mounted.native, scope: scope)
            #expect(
                mounted.native.labels().contains(
                    confirm ? "Answered: Blue" : "Answer sent; the agent didn't confirm it"))
            #expect(status.value(for: fixture.drawerId)?.status == .needsYou(.approval))
            #expect(
                try await fixture.composition.ingestion.sessionSummary(paneId: fixture.drawerId.uuid)?.status
                    == .needsYou(.approval))
            #expect(mounted.value?.shape?.messages.groups.map(\.kind) == [.needsYou, .resolved])
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G15 native dismissal uses the real waiting-mode transition", arguments: [true, false])
    func nativeDismissalRebindsTheCorrectTerminalLabel(blocking: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let id = AgentMessageId.generateUUIDv7()
            let waiting: AskWaiting = blocking ? .blocking(deadline: fixture.now.addingTimeInterval(600)) : .nonBlocking
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil, importance: .attention, body: "Dismiss this request", why: nil,
                        actions: [],
                        shape: .ask(reason: .question, form: .freeText(placeholder: "Reply"), waiting: waiting)))
                    == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let mounted = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                location: .pane, wallNow: fixture.now)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            try mounted.native.press("pane-context.dismiss.\(scope)")
            try await mounted.actionCompleted()
            mounted.native.layout()
            try await mounted.rendered()
            assertNoForm(in: mounted.native, scope: scope)
            #expect(mounted.native.labels().contains(blocking ? "Handed back to the agent" : "Dismissed"))
            guard case .detail(let stored) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first)),
                case .ask(_, _, _, let state)? = stored.messages.first?.shape
            else { throw NativePopoverProofFailure.missingDetail }
            #expect(state == (blocking ? .handedBack : .dismissed))
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func fillAndSubmit(
        _ form: ExistingPopoverForm, in host: PaneContextPreparedNativeHost,
        row: MessageRowModel.Key
    ) throws {
        let window = host.native
        let scope = row.controlScope
        switch form {
        case .singleChoice:
            try host.bindSingleChoice("blue", row: row)
            try window.press("pane-context.submit.\(scope)")
        case .multipleChoice:
            try window.press("pane-context.choice.blue.\(scope)")
            window.layout()
            try window.press("pane-context.choice.red.\(scope)")
            window.layout()
            try window.press("pane-context.submit.\(scope)")
        case .freeText:
            try window.typeText(placeholder: "Reply", value: "A real response")
            try window.press("pane-context.submit.\(scope)")
        case .elicitation:
            try window.typeText(placeholder: "Project", value: "staging")
            try window.typeText(placeholder: "Workers", value: "2")
            try window.press("pane-context.field.\(scope).enabled")
            window.layout()
            try window.press("pane-context.submit.\(scope)")
        }
    }

    private func assertNoForm(
        in window: PaneContextNativePopoverWindow, scope: String, otherChoicesRemain: Bool = false
    ) {
        #expect(window.editableFields.isEmpty)
        if !otherChoicesRemain {
            let header = window.find("pane-context.messages-header") as? any NSAccessibilityProtocol
            #expect(header != nil, "Current Messages chrome retains its pinned header")
            #expect(window.nativeButtons.isEmpty, "Settled forms must leave no AppKit form widgets or retired menu")
            for filter in PaneContextPopoverControlProjection.controls().filters.dropFirst() {
                let chip = window.find(filter.identifier) as? any NSAccessibilityProtocol
                #expect(chip != nil, "A settled list must retain every filter chip")
                if let headerFrame = header?.accessibilityFrame(), let chipFrame = chip?.accessibilityFrame() {
                    #expect(
                        headerFrame.contains(CGPoint(x: chipFrame.midX, y: chipFrame.midY))
                            && chipFrame.minY >= headerFrame.minY && chipFrame.maxY <= headerFrame.maxY,
                        "The filter chip belongs to the pinned header, not a settled row")
                }
            }
        }
        for prefix in [
            "pane-context.choice.red", "pane-context.choice.blue", "pane-context.submit", "pane-context.dismiss",
        ] {
            #expect(window.find(prefix + "." + scope) == nil, "Settled row retained \(prefix)")
        }
        for field in ["text", "project", "workers", "enabled", "choice"] {
            #expect(window.find("pane-context.field.\(scope).\(field)") == nil)
        }
    }
}

private enum NativePopoverProofFailure: Error { case missingDetail }
