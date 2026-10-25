import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Real Messages lifecycle", .serialized)
struct PaneContextPopoverLifecycleTests {
    @Test(
        "G16 every notice state reaches the real native actions and footer",
        arguments: PaneContextPopoverShapingTests.notices)
    func noticeStateTableReachesNativeView(scenario: PaneContextPopoverShapingTests.NoticeCase) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: scenario.importance, body: "A retained notice",
                        why: "Full explanation",
                        actions: [.openFile(path: "fixture.swift", line: 3)], shape: .notice)) == .created(id))
            switch scenario.state {
            case .unread: break
            case .read: try #require(await service.markRead(messageId: id, paneId: fixture.ownerId) == .done)
            case .dismissed: try #require(await service.dismiss(messageId: id, paneId: fixture.ownerId) == .done)
            case .withdrawn:
                try #require(
                    await service.withdraw(
                        messageId: id, paneId: fixture.ownerId,
                        writer: .pane(fixture.ownerId)) == .withdrawn)
            }
            await fixture.composition.presentationLane.publishPending()
            let mounted = makeWindow(fixture)
            window = mounted
            try await mounted.open()
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            let visible = scenario.state != .dismissed
            let actionable = scenario.state == .unread || scenario.state == .read
            #expect((mounted.find("pane-context.message-text." + scope) != nil) == visible)
            #expect((mounted.find("pane-context.dismiss." + scope) != nil) == actionable)
            #expect((mounted.find("pane-context.open-file." + scope + ".0") != nil) == actionable)
            #expect((mounted.find("pane-context.dismiss-all-notices") != nil) == actionable)
            #expect(mounted.find("pane-context.mark-read." + scope) == nil)
            #expect(mounted.find("pane-context.message-details." + scope) == nil)
            #expect(mounted.find("pane-context.go-to-pane") != nil)
            if let group = scenario.group {
                #expect(mounted.find("pane-context.group." + group.rawValue) != nil)
                #expect(mounted.labels().contains("A retained notice\nFull explanation Now"))
            } else {
                #expect(mounted.controller?.state?.messages.groups.isEmpty == true)
            }
            if let label = scenario.label { #expect(mounted.labels().contains(label)) }
            #expect(
                mounted.controller?.state?.messages.messageRows.first?.isDimmed
                    == (visible ? scenario.state == .read : nil))
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G16 read info dims the actual painted body while retaining its actions")
    func readNoticeDimsTheNativePaint() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil, importance: .info, body: "The retained notice must become dimmer",
                        why: nil,
                        actions: [], shape: .notice)) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let mounted = makeWindow(fixture)
            window = mounted
            try await mounted.open()
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            let text = try #require(mounted.find("pane-context.message-text." + scope) as? NSView)
            let root = try #require(text.window?.contentView)
            let region = root.convert(text.bounds, from: text).insetBy(dx: -2, dy: -2)
            let unread = try PaneContextToolbarRenderingTests().pixels(in: root, rect: region)
            try #require(await service.markRead(messageId: id, paneId: fixture.ownerId) == .done)
            await fixture.composition.presentationLane.publishPending()
            await mounted.controller?.refresh()
            mounted.layout()
            try await mounted.rendered()
            let readText = try #require(mounted.find("pane-context.message-text." + scope) as? NSView)
            let readRegion = root.convert(readText.bounds, from: readText).insetBy(dx: -2, dy: -2)
            #expect(readRegion == region)
            let read = try PaneContextToolbarRenderingTests().pixels(in: root, rect: readRegion)
            #expect(read != unread, "A read state must change the actual body pixels")
            let readContrast = await PaneContextPixelContrast.measure(read)
            let unreadContrast = await PaneContextPixelContrast.measure(unread)
            #expect(readContrast < unreadContrast, "Read text must approach its unchanged background")
            #expect(mounted.find("pane-context.dismiss." + scope) != nil)
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
        "G16 native Dismiss all uses current main/drawer scope and preserves asks, prompts and other panes",
        arguments: [false, true])
    func dismissAllPreservesOtherEntities(drawerOnly: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            let outside = PaneId.generateUUIDv7()
            fixture.directory.install(
                .init(
                    workspaceId: fixture.workspaceId, membershipRevision: 2,
                    entries: [
                        .init(paneId: fixture.ownerId, placement: .layout, ownedDrawerChildIds: [fixture.drawerId]),
                        .init(
                            paneId: fixture.drawerId, placement: .drawerChild(parentPaneID: fixture.ownerId.uuid),
                            ownedDrawerChildIds: []),
                        .init(paneId: outside, placement: .layout, ownedDrawerChildIds: []),
                    ]))
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let askId = AgentMessageId.generateUUIDv7()
            let waiting = AskWaiting.blocking(deadline: fixture.now.addingTimeInterval(600))
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: askId,
                        sender: try fixture.sender(binding), sourceOccurredAt: nil, importance: .attention,
                        body: "Keep this ask", why: nil, actions: [],
                        shape: .ask(reason: .question, form: .freeText(placeholder: "Reply"), waiting: waiting)))
                    == .created(askId))
            var notices: [(PaneId, AgentMessageId)] = []
            for pane in [fixture.ownerId, fixture.ownerId, fixture.drawerId, outside] {
                let id = AgentMessageId.generateUUIDv7()
                notices.append((pane, id))
                try #require(
                    await service.send(
                        .init(
                            paneId: pane, messageId: id, sender: .pane(pane),
                            sourceOccurredAt: nil, importance: .info, body: "A scoped notice", why: nil,
                            actions: [], shape: .notice)) == .created(id))
            }
            try #require(await service.markRead(messageId: notices[1].1, paneId: fixture.ownerId) == .done)
            let signal = SessionProviderSignal.permission(toolName: "Bash", questions: nil)
            let result = try await fixture.composition.ingestion.submitHook(
                .init(
                    paneId: fixture.drawerId.uuid,
                    providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "kept-provider-prompt",
                    eventName: signal.name, turnId: nil, signal: signal, recordId: UUIDv7.generate(),
                    admittedAt: fixture.now, chain: TestMainAgentChain.observation))
            guard case .committed = result else { throw LifecycleProofFailure.missingDetail }
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let selected = drawerOnly ? fixture.drawerId : fixture.ownerId
            let mounted = PaneContextNativePopoverWindow(
                paneId: selected, readers: readers,
                location: .sidebar, wallNow: fixture.now, includingDrawers: !drawerOnly)
            window = mounted
            try await mounted.open()
            try mounted.press("pane-context.dismiss-all-notices")
            try await mounted.actionCompleted()
            mounted.layout()
            try await mounted.rendered()
            #expect(mounted.find("pane-context.dismiss-all-notices") == nil)
            #expect(mounted.controller?.actionFeedback == (drawerOnly ? "Dismissed 1 notices" : "Dismissed 3 notices"))
            guard case .detail(let owner) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first)),
                case .detail(let other) = await service.readDetail(.init(paneId: outside, page: .first))
            else {
                throw LifecycleProofFailure.missingDetail
            }
            #expect(
                owner.messages.first { $0.id == askId }?.shape
                    == .ask(.question, .freeText(placeholder: "Reply"), waiting, .open))
            #expect(owner.hasDismissibleNotices == drawerOnly)
            #expect(other.messages.first?.shape == .notice(.unread))
            #expect(
                try await fixture.composition.ingestion.sessionSummary(paneId: fixture.drawerId.uuid)?.providerPrompts
                    .count == 1)
            #expect(mounted.controller?.state.map(PaneContextPopoverShapingTests.prompts)?.count == 1)
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
        "G16 expired, withdrawn and stale asks use real service transitions before native presentation",
        arguments: TerminalAskSample.allCases)
    func remainingAskTerminalsHaveNoNativeActions(sample: TerminalAskSample) async throws {
        let time = PaneContextTestWallDate()
        let fixture = try await CompositionFactoryFixture.make(wallNow: { time.now })
        let service = fixture.composition.paneContextService
        var window: PaneContextNativePopoverWindow?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let sender = try fixture.sender(binding)
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender,
                        sourceOccurredAt: nil, importance: .attention, body: "A terminating ask", why: nil, actions: [],
                        shape: .ask(
                            reason: .question, form: .freeText(placeholder: "Reply"),
                            waiting: .blocking(deadline: time.now.addingTimeInterval(600))))) == .created(id))
            switch sample {
            case .expired:
                time.advance(by: 601)
                try #require(
                    await service.settleAsk(id, paneId: fixture.ownerId, cause: .deadline) == .settled(.expired))
            case .withdrawn:
                try #require(
                    await service.withdraw(messageId: id, paneId: fixture.ownerId, writer: sender) == .withdrawn)
            case .stale:
                try #require(
                    await service.settleAsk(id, paneId: fixture.ownerId, cause: .appStopping) == .settled(.stale))
            }
            await fixture.composition.presentationLane.publishPending()
            let mounted = makeWindow(fixture, wallNow: time.now)
            window = mounted
            try await mounted.open()
            let scope = "\(fixture.ownerId.uuid).\(id.uuid)"
            #expect(mounted.find("pane-context.message-text." + scope) != nil)
            #expect(mounted.find("pane-context.group.resolved") != nil)
            #expect(mounted.labels().contains(sample.label))
            #expect(mounted.editableFields.isEmpty)
            #expect(mounted.find("pane-context.submit." + scope) == nil)
            #expect(mounted.find("pane-context.dismiss." + scope) == nil)
            #expect(mounted.find("pane-context.dismiss-all-notices") == nil)
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func makeWindow(_ fixture: CompositionFactoryFixture, wallNow: Date? = nil)
        -> PaneContextNativePopoverWindow
    {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let readers = PaneContextUIReaders(
            sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        return .init(paneId: fixture.ownerId, readers: readers, location: .sidebar, wallNow: wallNow ?? fixture.now)
    }
}

enum TerminalAskSample: CaseIterable, Sendable {
    case expired, withdrawn, stale
    var label: String {
        switch self {
        case .expired: "Expired"
        case .withdrawn: "Withdrawn by the agent"
        case .stale: "No longer current"
        }
    }
}

private enum LifecycleProofFailure: Error { case missingDetail }
