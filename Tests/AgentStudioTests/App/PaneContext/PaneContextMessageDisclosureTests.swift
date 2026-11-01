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
@Suite("Message disclosure behavior", .serialized)
struct PaneContextMessageDisclosureTests {
    @Test("D85 full-text reading remains within its measured admission bound")
    func plainTextReadingRequiresTheMeasuredBodyBound() {
        // D85 qualifies the whole SwiftUI Text through4096UTF8bytes, including4097blank lines.
        // A larger admission needs new measurements or a viewport text surface before this bound changes.
        #expect(
            AppPolicies.PaneContext.maximumBodyBytes <= 4096,
            "D85's full-text rendering proof does not cover a larger body admission")
    }

    enum ReadTarget: CaseIterable, Sendable {
        case failed, done, info, approval, singleChoice, multipleChoice, freeText, elicitation, providerPrompt

        func shape() throws -> PaneMessageSendShape {
            let form: AskForm
            switch self {
            case .failed, .done, .info, .providerPrompt: return .notice
            case .approval: form = .approval
            case .singleChoice: form = try ExistingPopoverForm.singleChoice.request()
            case .multipleChoice: form = try ExistingPopoverForm.multipleChoice.request()
            case .freeText: form = try ExistingPopoverForm.freeText.request()
            case .elicitation: form = try ExistingPopoverForm.elicitation.request()
            }
            return .ask(reason: self == .approval ? .approval : .question, form: form, waiting: .nonBlocking)
        }
    }
    private static let fullBody = (1...33).map { "diagnostic \($0): compiler note" }.joined(separator: "\n")

    @Test("D85 capped text opens one selected read pane without expanding the list; full text scrolls")
    func detailsReadTheFullBodyAndKeepTheListCapped() async throws {
        try await withDisclosure(body: Self.fullBody) { _, host, row, _ in
            let label = try host.appliedMessage(row, expectedLabel: Self.fullBody + " Now", age: "Now", isRead: false)
            #expect(label.native.label == Self.fullBody + " Now")
            let details = try control(host, row: row, presented: false)
            #expect(details.accessibilityLabel() == "Details")
            let originalHeight = try textHeight(host, row: row)
            try #require(details.accessibilityPerformPress())
            host.native.layout()
            let panel = try #require(host.native.find("pane-context.details-panel") as? NSView)
            #expect(try control(host, row: row, presented: true).accessibilityLabel() == "Close details")
            #expect(details.isAccessibilitySelected(), "The real selected trigger must expose its active state")
            #expect(try textHeight(host, row: row) == originalHeight, "Details never expands the primary row")
            let full = try #require(host.native.find("pane-context.details-text") as? any NSAccessibilityProtocol)
            #expect(full.accessibilityLabel() == Self.fullBody)
            let title = try #require(
                host.native.find("pane-context.details-panel.title") as? any NSAccessibilityProtocol)
            #expect(title.accessibilityLabel() == "diagnostic 1: compiler note")
            #expect(panel.bounds.width == 365)
            let scroll = try #require(
                (full as? NSView)?.enclosingScrollView,
                "The full-text native leaf must belong to the reading pane's real scroll view")
            let document = try #require(scroll.documentView)
            #expect(document.bounds.height > scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: .init(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.native.layout()
            #expect(scroll.contentView.bounds.minY > 0)
            try #require(try control(host, row: row, presented: true).accessibilityPerformPress())
            host.native.layout()
            #expect(host.native.find("pane-context.details-panel") == nil)
            #expect(try textHeight(host, row: row) == originalHeight)
        }
    }

    @Test("D85 wrapped visual lines still have an independent count behind the details affordance")
    func wrappedLinesHaveAnIndependentMonospacedCount() async throws {
        let body = "Build output\n```\n" + String(repeating: "W", count: 700) + "\n```\nEnd"
        try await withDisclosure(body: body) { _, host, row, _ in
            let leaf = try #require(host.native.find(textIdentifier(row)) as? NSView)
            let glyphAdvance = ("W" as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            ]).width
            let columns = Int(floor(leaf.bounds.width / glyphAdvance))
            try #require(columns > 0)
            let expectedLines = Int(ceil(700.0 / Double(columns))) + 2
            #expect(host.value?.bodyMeasurements[.message(row)]?.visualLines == expectedLines)
            #expect(try control(host, row: row, presented: false).accessibilityLabel() == "Details")
        }
    }

    @Test("D85 refresh and age updates retain the read target; close releases it and fences the next opening")
    func detailsBelongToTheOpening() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var active: PaneContextPreparedNativeHost?
        do {
            let row = try await seed(fixture, body: Self.fullBody)
            let first = makeHost(fixture)
            active = first
            try await first.open()
            try await first.bodyLayoutsPrepared()
            try #require(try control(first, row: row, presented: false).accessibilityPerformPress())
            first.native.layout()
            try await first.refresh()
            try await first.rendered()
            #expect(first.native.find("pane-context.details-panel") != nil)
            try await first.advance(by: .seconds(60), registeredAt: first.clock.now.advanced(by: .seconds(60)))
            _ = try first.appliedMessage(
                row, expectedLabel: Self.fullBody + " 1 min ago", age: "1 min ago", isRead: false)
            #expect(first.native.find("pane-context.details-panel") != nil)
            try await first.close()
            active = nil
            let second = makeHost(fixture)
            active = second
            try await second.open()
            try await second.bodyLayoutsPrepared()
            #expect(second.native.find("pane-context.details-panel") == nil)
            #expect(try control(second, row: row, presented: false).accessibilityLabel() == "Details")
            try await second.close()
            active = nil
            try await fixture.close()
        } catch {
            try? await active?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("D85 Escape closes the read pane before the Messages popover")
    func escapeClosesTheDetailsFirst() async throws {
        try await withDisclosure(body: Self.fullBody) { _, host, row, _ in
            try #require(try control(host, row: row, presented: false).accessibilityPerformPress())
            host.native.layout()
            let window = try #require(host.native.popoverWindow)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.sendEvent(event)
            host.native.layout()
            #expect(host.native.find("pane-context.details-panel") == nil)
            #expect(host.native.find("pane-context.popover-panel") != nil)
        }
    }

    @Test(
        "D85 every notice group, ask form and provider prompt opens the same full read pane",
        arguments: ReadTarget.allCases)
    func everyTextKindHasDetails(target: ReadTarget) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let id = AgentMessageId.generateUUIDv7()
            let key: PaneContextTextBodyKey
            let expectedBody: String
            if target == .providerPrompt {
                let signal = SessionProviderSignal.elicitation(id: "read-full-prompt", summary: Self.fullBody)
                let result = try await fixture.composition.ingestion.submitHook(
                    .init(
                        paneId: fixture.ownerId.uuid, providerIdentifier: "codex", providerVersion: "9.9.9",
                        sessionId: "detail-prompt", eventName: signal.name, turnId: nil, signal: signal,
                        recordId: UUIDv7.generate(), admittedAt: fixture.now, chain: TestMainAgentChain.observation))
                guard case .committed = result else { throw ReadFailure.promptNotCommitted }
                key = .providerPrompt(source: fixture.ownerId.uuid, ordinal: 0)
                expectedBody = "Needs you · question: " + Self.fullBody
            } else {
                let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
                let importance: MessageImportance = target == .failed ? .failure : target == .done ? .done : .info
                try #require(
                    await fixture.composition.paneContextService.send(
                        .init(
                            paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                            importance: importance, body: Self.fullBody, why: nil, actions: [],
                            shape: try target.shape())) == .created(id))
                key = .message(.init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
                expectedBody = Self.fullBody
            }
            await fixture.composition.presentationLane.publishPending()
            let host = makeHost(fixture)
            mounted = host
            try await host.open()
            try await host.bodyLayoutsPrepared()
            let details = try #require(
                host.native.find(
                    PaneContextPopoverControlProjection.controls().showDetails.identifier(in: key.textIdentifier))
                    as? any NSAccessibilityProtocol)
            if case .message(let rowKey) = key,
                [.singleChoice, .multipleChoice, .freeText, .elicitation].contains(target)
            {
                let submit = try #require(
                    host.native.find(
                        PaneContextPopoverControlProjection.controls().submit.identifier(in: rowKey.controlScope))
                        as? NSView)
                let detailsView = try #require(details as? NSView)
                let submitRect = submit.convert(submit.bounds, to: nil)
                let detailsRect = detailsView.convert(detailsView.bounds, to: nil)
                #expect(submitRect.midY == detailsRect.midY, "D85d Submit and Details share one commit row")
                #expect(submitRect.maxX < detailsRect.minX, "D85d secondary Details follows left-aligned Submit")
            }
            try #require(details.accessibilityPerformPress())
            host.native.layout()
            #expect(
                (host.native.find("pane-context.details-text") as? any NSAccessibilityProtocol)?.accessibilityLabel()
                    == expectedBody)
            #expect(host.native.find("pane-context.details-panel") != nil)
            #expect(details.isAccessibilitySelected())
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("D85 choosing a second item replaces the one read target and its active trigger")
    func selectingAnotherItemReplacesDetails() async throws {
        try await withDisclosure(body: Self.fullBody) { fixture, host, first, _ in
            try #require(try control(host, row: first, presented: false).accessibilityPerformPress())
            host.native.layout()
            let secondBody = "Second item title\n" + Self.fullBody
            let second = try await seed(fixture, body: secondBody)
            try await host.refresh()
            try await host.bodyLayoutsPrepared()
            try #require(try control(host, row: second, presented: false).accessibilityPerformPress())
            host.native.layout()
            #expect(
                (host.native.find("pane-context.details-text") as? any NSAccessibilityProtocol)?.accessibilityLabel()
                    == secondBody)
            #expect(
                (host.native.find("pane-context.details-panel.title") as? any NSAccessibilityProtocol)?
                    .accessibilityLabel() == "Second item title")
            #expect(try control(host, row: second, presented: false).isAccessibilitySelected())
            #expect(try !control(host, row: first, presented: false).isAccessibilitySelected())
        }
    }

    private enum ReadFailure: Error { case promptNotCommitted }

    @Test("D85 inserting a provider prompt never marks different content as the item being read")
    func providerInsertionKeepsTheReadMarkerHonest() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        let oldBody =
            "Earlier provider question\n" + (1...18).map { "Original question line \($0)" }.joined(separator: "\n")
        let newBody =
            "Newer provider question\n" + (1...18).map { "Different question line \($0)" }.joined(separator: "\n")
        do {
            try await seedPrompt(fixture, id: "original", body: oldBody, offset: 0)
            let host = makeHost(fixture)
            mounted = host
            try await host.open()
            try await host.bodyLayoutsPrepared()
            let prefix = PaneContextPopoverControlProjection.controls().showDetails
            let originalControl = prefix.identifier(
                in: PaneContextTextBodyKey.providerPrompt(
                    source: fixture.ownerId.uuid, ordinal: 0
                ).textIdentifier)
            try host.native.press(originalControl)
            host.native.layout()
            let originalFull = try #require(
                host.native.find("pane-context.details-text") as? any NSAccessibilityProtocol)
            #expect(originalFull.accessibilityLabel() == "Needs you · question: " + oldBody)
            #expect(
                (host.native.find(originalControl) as? any NSAccessibilityProtocol)?.isAccessibilitySelected() == true)
            let renderedInput = try providerBindings(host)
            let renderedSnapshot = try #require(renderedInput.details.wrappedValue)
            try await host.advance(by: .seconds(60), registeredAt: host.clock.now.advanced(by: .seconds(60)))
            #expect(
                host.native.find("pane-context.details-panel") != nil, "An age-only publication retains the read target"
            )
            renderedInput.selectedFilter.wrappedValue = 8
            host.native.layout()
            #expect(
                host.native.find("pane-context.details-panel") != nil, "Hiding a group cannot retire the read target")
            renderedInput.selectedFilter.wrappedValue = 15
            try await host.bodyLayoutsPrepared()

            try await seedPrompt(fixture, id: "newer", body: newBody, offset: 1)
            try await host.refresh()
            try await host.bodyLayoutsPrepared()
            let newer = try #require(host.native.find(originalControl) as? any NSAccessibilityProtocol)
            let older = try #require(
                host.native.find(
                    prefix.identifier(
                        in: PaneContextTextBodyKey.providerPrompt(
                            source: fixture.ownerId.uuid, ordinal: 1
                        ).textIdentifier)) as? any NSAccessibilityProtocol)
            if let full = host.native.find("pane-context.details-text") as? any NSAccessibilityProtocol {
                #expect(
                    full.accessibilityLabel() == "Needs you · question: " + oldBody,
                    "A refresh cannot silently switch the content being read")
                #expect(
                    !newer.isAccessibilitySelected(),
                    "A reused ordinal cannot mark a different provider question as selected")
                #expect(
                    older.isAccessibilitySelected(), "The active marker must refer to the content in the reading pane")
            } else {
                #expect(
                    !newer.isAccessibilitySelected() && !older.isAccessibilitySelected(),
                    "A closed reading pane has no selected trigger")
            }
            let currentInput = try providerBindings(host)
            let selectionBeforeStaleCallback = currentInput.details.wrappedValue
            let retainedBeforeStaleCallback = host.interactions.retainedRowCount
            renderedInput.details.wrappedValue = renderedSnapshot
            #expect(
                currentInput.details.wrappedValue == selectionBeforeStaleCallback,
                "A callback captured before insertion cannot reopen or retarget a different slot version")
            #expect(
                host.interactions.retainedRowCount == retainedBeforeStaleCallback,
                "A refused stale callback cannot retain its old read payload behind a hidden pane")
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func providerBindings(_ host: PaneContextPreparedNativeHost) throws -> MessagesPopoverBindings {
        let handle = try #require(host.handle)
        let value = try #require(handle.atom.latestAcceptedValue)
        return host.interactions.bindings(
            versions: value.interactions.versions, opening: handle.opening.epoch,
            currentVersions: { handle.atom.latestAcceptedValue?.interactions.versions },
            providerVersions: value.interactions.providerVersions,
            currentProviderVersions: { handle.atom.latestAcceptedValue?.interactions.providerVersions })
    }

    private func seedPrompt(_ fixture: CompositionFactoryFixture, id: String, body: String, offset: TimeInterval)
        async throws
    {
        let signal = SessionProviderSignal.elicitation(id: id, summary: body)
        let result = try await fixture.composition.ingestion.submitHook(
            .init(
                paneId: fixture.ownerId.uuid, providerIdentifier: "codex", providerVersion: "9.9.9",
                sessionId: "detail-marker", eventName: signal.name, turnId: nil, signal: signal,
                recordId: UUIDv7.generate(), admittedAt: fixture.now.addingTimeInterval(offset),
                chain: TestMainAgentChain.observation))
        guard case .committed = result else { throw ReadFailure.promptNotCommitted }
        await fixture.composition.presentationLane.publishPending()
    }

    private func withDisclosure(
        body: String,
        operation:
            @MainActor (
                CompositionFactoryFixture, PaneContextPreparedNativeHost, MessageRowModel.Key,
                @MainActor () -> [PaneContextPopoverHeightWrite]
            ) async throws -> Void
    ) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var active: PaneContextPreparedNativeHost?
        var writes: [PaneContextPopoverHeightWrite] = []
        do {
            let row = try await seed(fixture, body: body)
            let host = makeHost(fixture) { writes.append($0) }
            active = host
            try await host.open()
            try await host.rendered()
            try await host.bodyLayoutsPrepared()
            try await operation(fixture, host, row, { writes })
            let beforeClose = writes.count
            try await host.close()
            active = nil
            #expect(writes.count - beforeClose <= 3, "Retirement cannot start a layout feedback loop")
            try await fixture.close()
        } catch {
            try? await active?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func seed(_ fixture: CompositionFactoryFixture, body: String) async throws -> MessageRowModel.Key {
        let id = AgentMessageId.generateUUIDv7()
        try #require(
            await fixture.composition.paneContextService.send(
                .init(
                    paneId: fixture.ownerId, messageId: id, sender: .pane(fixture.ownerId), sourceOccurredAt: nil,
                    importance: .failure, body: body, why: nil, actions: [], shape: .notice)) == .created(id))
        await fixture.composition.presentationLane.publishPending()
        return .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid)
    }

    private func makeHost(
        _ fixture: CompositionFactoryFixture,
        onHeightWrite: (@MainActor (PaneContextPopoverHeightWrite) -> Void)? = nil
    ) -> PaneContextPreparedNativeHost {
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: .init(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        return .init(
            paneId: fixture.ownerId, sourceOwners: owners,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            clock: clock, wallNow: { time.now }, bridge: bridge, onPanelHeightWrite: onHeightWrite)
    }

    private func controlIdentifier(_ row: MessageRowModel.Key, presented: Bool) -> String {
        presented ? "pane-context.close-message-details" : "pane-context.message-details." + textIdentifier(row)
    }
    private func textIdentifier(_ row: MessageRowModel.Key) -> String {
        "pane-context.message-text." + row.controlScope
    }
    private func control(_ host: PaneContextPreparedNativeHost, row: MessageRowModel.Key, presented: Bool) throws
        -> any NSAccessibilityProtocol
    {
        try #require(
            host.native.find(controlIdentifier(row, presented: presented)) as? any NSAccessibilityProtocol,
            "Missing real disclosure control for presented=\(presented)")
    }
    private func textHeight(_ host: PaneContextPreparedNativeHost, row: MessageRowModel.Key) throws -> CGFloat {
        try #require(host.native.find(textIdentifier(row)) as? NSView).bounds.height
    }
}
