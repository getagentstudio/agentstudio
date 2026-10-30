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
@Suite("Native Messages geometry", .serialized)
struct PaneContextPopoverGeometryTests {
    @Test(
        "D85 title and footer stay outside scrolling rows; the read pane scrolls full text separately",
        arguments: [false, true])
    func fullContentAndPinnedFooter(long: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            let body = long ? (0..<32).map { "Visible message line \($0)" }.joined(separator: "\n") : "A short notice"
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.drawerId, messageId: id,
                        sender: .pane(fixture.drawerId), sourceOccurredAt: nil, importance: .failure,
                        body: body, why: "An explanation after the full body", actions: [], shape: .notice))
                    == .created(id))
            if long {
                // A full list still reaches its viewport cap after inline expansion is retired.
                for index in 0..<6 {
                    let extra = AgentMessageId.generateUUIDv7()
                    try #require(
                        await service.send(
                            .init(
                                paneId: fixture.drawerId, messageId: extra, sender: .pane(fixture.drawerId),
                                sourceOccurredAt: nil, importance: .info, body: "Additional visible notice \(index)",
                                why: nil, actions: [], shape: .notice)) == .created(extra))
                }
            }
            await fixture.composition.presentationLane.publishPending()
            let mounted = makeUnfilteredGeometryHost(fixture)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            if long {
                try await mounted.bodyLayoutsPrepared()
                let more = try #require(
                    mounted.native.find(
                        "pane-context.message-details.pane-context.message-text.\(fixture.drawerId.uuid).\(id.uuid)")
                        as? any NSAccessibilityProtocol)
                try #require(more.accessibilityPerformPress())
                try await mounted.bodyLayoutsPrepared()
            }
            let panel = try #require(mounted.native.find("pane-context.popover-panel") as? NSView)
            let footer = try #require(mounted.native.find("pane-context.messages-footer") as? NSView)
            let header = try #require(mounted.native.find("pane-context.messages-header") as? NSView)
            let text = try #require(
                mounted.native.find("pane-context.message-text.\(fixture.drawerId.uuid).\(id.uuid)") as? NSView)
            #expect(panel.bounds.width == (long ? 560 : 480))
            #expect(panel.bounds.height <= 480)
            #expect(panel.bounds.height > 80)
            #expect(mounted.native.labels().contains(body + "\nAn explanation after the full body Now"))
            #expect(mounted.native.labels().contains("Drawer · Drawer pane"))
            let dismissAll = try #require(mounted.native.find("pane-context.dismiss-all-notices") as? NSView)
            let goToPane = try #require(mounted.native.find("pane-context.go-to-pane") as? NSView)
            #expect(dismissAll.accessibilityLabel() == "Dismiss all notices")
            #expect(goToPane.accessibilityLabel() == "Go to pane")
            let panelRect = panel.convert(panel.bounds, to: nil)
            let footerRect = footer.convert(footer.bounds, to: nil)
            #expect(panelRect.contains(footerRect))
            #expect(footerRect.contains(dismissAll.convert(dismissAll.bounds, to: nil)))
            #expect(footerRect.contains(goToPane.convert(goToPane.bounds, to: nil)))
            let scroll = try #require(text.enclosingScrollView)
            #expect(!header.isDescendant(of: scroll), "The Messages title must be outside the rows' scroll view")
            #expect(!footer.isDescendant(of: scroll), "The footer must be outside the rows' scroll view")
            #expect(panelRect.contains(header.convert(header.bounds, to: nil)))
            #expect(!header.convert(header.bounds, to: nil).intersects(scroll.convert(scroll.bounds, to: nil)))
            if long {
                #expect(panel.bounds.height == 480)
                #expect(text.bounds.height < 200, "The primary message remains capped while its full text is read")
                let document = try #require(scroll.documentView)
                #expect(document.bounds.height > scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: .init(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                mounted.native.layout()
                #expect(scroll.contentView.bounds.minY > 0)
                #expect(panel.convert(panel.bounds, to: nil).contains(header.convert(header.bounds, to: nil)))
                #expect(panel.convert(panel.bounds, to: nil).contains(footer.convert(footer.bounds, to: nil)))
                let full = try #require(mounted.native.find("pane-context.details-text") as? NSView)
                let readScroll = try #require(full.enclosingScrollView)
                #expect(full.bounds.height > readScroll.contentView.bounds.height)
                let fullDocument = try #require(readScroll.documentView)
                readScroll.contentView.scroll(
                    to: .init(x: 0, y: fullDocument.bounds.maxY - readScroll.contentView.bounds.height))
                readScroll.reflectScrolledClipView(readScroll.contentView)
                mounted.native.layout()
                #expect(readScroll.contentView.bounds.minY > 0, "The independent right pane reaches later text")
            } else {
                #expect(panel.bounds.height < 480)
                #expect(text.bounds.height < 100)
            }
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("G20 native group ordering and mixed E5/E7 timestamps retain the canonical E7 tie order")
    func mixedGroupsAndTiedPromptsHavePaintedOrder() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        var window: PaneContextPreparedNativeHost?
        do {
            var ids: [AgentMessageId] = []
            for (importance, body) in [
                (MessageImportance.failure, "Main failure"), (.done, "Completed work"),
                (.info, "Information"), (.info, "Withdrawn information"),
            ] {
                let id = AgentMessageId.generateUUIDv7()
                ids.append(id)
                try #require(
                    await service.send(
                        .init(
                            paneId: fixture.ownerId, messageId: id,
                            sender: .pane(fixture.ownerId), sourceOccurredAt: nil, importance: importance, body: body,
                            why: nil, actions: [], shape: .notice)) == .created(id))
            }
            try #require(
                await service.withdraw(
                    messageId: ids[3], paneId: fixture.ownerId,
                    writer: .pane(fixture.ownerId)) == .withdrawn)
            for (pane, summary) in [
                (fixture.ownerId, "Main provider prompt"), (fixture.drawerId, "Drawer provider prompt"),
            ] {
                let signal = SessionProviderSignal.elicitation(id: "prompt", summary: summary)
                let result = try await fixture.composition.ingestion.submitHook(
                    .init(
                        paneId: pane.uuid,
                        providerIdentifier: "codex", providerVersion: "9.9.9", sessionId: "ordered-\(pane.uuid)",
                        eventName: signal.name, turnId: nil, signal: signal, recordId: UUIDv7.generate(),
                        admittedAt: fixture.now.addingTimeInterval(1), chain: TestMainAgentChain.observation))
                guard case .committed = result else { throw PopoverGeometryProofFailure.hookNotCommitted }
            }
            await fixture.composition.presentationLane.publishPending()
            let mounted = makeUnfilteredGeometryHost(fixture)
            window = mounted
            try await mounted.open()
            try await mounted.rendered()
            let headers = try ["failed", "needsYou", "done", "info", "resolved"].map { name -> CGRect in
                let view = try #require(mounted.native.find("pane-context.group." + name) as? NSView)
                return view.convert(view.bounds, to: nil)
            }
            #expect(zip(headers, headers.dropFirst()).allSatisfy { $0.minY > $1.maxY })
            let main = try #require(
                mounted.native.find("pane-context.provider-prompt.\(fixture.ownerId.uuid).0") as? NSView)
            let drawer = try #require(
                mounted.native.find("pane-context.provider-prompt.\(fixture.drawerId.uuid).0") as? NSView)
            let failure = try #require(
                mounted.native.find("pane-context.message-text.\(fixture.ownerId.uuid).\(ids[0].uuid)") as? NSView)
            #expect(main.convert(main.bounds, to: nil).minY > drawer.convert(drawer.bounds, to: nil).maxY)
            #expect(failure.convert(failure.bounds, to: nil).minY > main.convert(main.bounds, to: nil).maxY)
            #expect(mounted.native.labels().contains("Needs you · question: Main provider prompt Now"))
            #expect(mounted.native.labels().contains("Needs you · question: Drawer provider prompt Now"))
            try await mounted.close()
            window = nil
            try await fixture.close()
        } catch {
            try? await window?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func makeUnfilteredGeometryHost(_ fixture: CompositionFactoryFixture) -> PaneContextPreparedNativeHost {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        return owners.makeNativeHost(
            paneId: fixture.ownerId,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            wallNow: fixture.now)
    }

    @Test("G20 a held Loading read and unavailable outcomes preserve 480 points", arguments: [false, true])
    func loadingAndUnavailableKeepTheirWidth(initiallyUnavailable: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let detail = PaneContextPopoverShapingTests.detail(paneId: pane)
        let ports = PaneContextPopoverTestPorts(
            detail,
            results: initiallyUnavailable ? [.unavailable(.databaseUnavailable)] : [], heldReads: [0])
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: PaneContextPresentationAtom(),
            pane: { _ in nil }, serviceProvider: { adapter })
        let mounted = owners.makeNativeHost(
            paneId: pane, entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            location: .sidebar,
            wallNow: Date(timeIntervalSince1970: 1_800_000_000))
        var readMonitor: Task<Void, Never>?
        do {
            let opening = try mounted.beginOpening()
            readMonitor = Task {
                await opening.task.value
                await ports.detailProducerEnded(beforeRead: 0)
            }
            try await ports.reads.expectNext(in: 0, .started(.init(paneId: pane, page: .first)))
            _ = try await mounted.consumer(for: opening)
            try await mounted.renderedNote("Loading…")
            let loadingPanel = try #require(mounted.native.find("pane-context.popover-panel") as? NSView)
            #expect(loadingPanel.bounds.width == 480)
            #expect(mounted.native.labels().contains("Loading…"))
            await ports.release(0)
            try await mounted.completeOpening(opening)
            mounted.native.layout()
            if !initiallyUnavailable {
                try await mounted.rendered()
                let original = mounted.value?.shape
                await ports.enqueue(.unavailable(.databaseUnavailable))
                try await mounted.refresh()
                mounted.native.layout()
                try await mounted.rendered()
                #expect(mounted.value?.shape == original)
            }
            if initiallyUnavailable {
                try await mounted.renderedNote("Context unavailable: database unavailable")
            }
            let failedPanel = try #require(mounted.native.find("pane-context.popover-panel") as? NSView)
            #expect(failedPanel.bounds.width == 480)
            #expect(mounted.native.labels().contains("Context unavailable: database unavailable"))
            try await mounted.close()
            await readMonitor?.value
            try await ports.finish()
        } catch {
            await ports.release(0)
            try? await mounted.close()
            await readMonitor?.value
            try? await ports.finish()
            throw error
        }
    }
}

private enum PopoverGeometryProofFailure: Error { case hookNotCommitted }
