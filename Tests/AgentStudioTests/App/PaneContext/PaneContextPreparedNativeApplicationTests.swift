import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Prepared popover native application", .serialized)
struct PaneContextPreparedNativeApplicationTests {
    @Test("D56 one synchronous owning-host update applies the newly published minute to the exact row")
    func oneHostUpdateAppliesPublishedMinute() async throws {
        let bridge = PopoverOwnerFactBridge()
        let leaf = PaneContextPreparedMessageLeafRecorder()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        let fixture = try await CompositionFactoryFixture.make(wallNow: { time.now })
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { pane in
                .init(
                    structuralFacts: nil, title: "Owner", note: nil, session: nil,
                    display: fixture.presentationAtom.value(for: pane), activity: nil)
            },
            serviceProvider: { adapter },
            observe: { scope, fact in
                bridge.observe(scope, fact)
                leaf.observeOwner(scope, fact)
            })
        var mounted: PaneContextNativePopoverWindow?
        do {
            let message = AgentMessageId.generateUUIDv7()
            try #require(
                await fixture.composition.paneContextService.send(
                    .init(
                        paneId: fixture.ownerId, messageId: message, sender: .pane(fixture.ownerId),
                        sourceOccurredAt: nil,
                        importance: .info, body: "A persistent notice", why: "A full explanation", actions: [],
                        shape: .notice)) == .created(message))
            await fixture.composition.presentationLane.publishPending()
            let sink = NativeOpening()
            let host = PaneContextPreparedPopoverHost(
                paneId: fixture.ownerId,
                presentation: .messagesAction(
                    PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                location: .pane, bindings: bindings, octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in },
                onRenderingTaskStarted: { sink.tasks.append($0) }, onConsumerStarted: { sink.consumer = $0 },
                onApplication: { leaf.observePresentation($0) }, onMessageApplication: { leaf.observeRow($0) })
            let window = PaneContextNativePopoverWindow(preparedRoot: AnyView(host))
            mounted = window
            try window.press("pane-context.messages")
            try #require(sink.tasks.count == 1, "The native press did not synchronously announce its rendering task")
            await sink.tasks[0].value
            let consumer = try #require(sink.consumer, "The actual rendering producer ended without a consumer")
            try await consumePublished(consumer.opening.initialExecution, key: consumer.key, bridge: bridge)
            let row = MessageRowModel.Key(sourcePaneId: fixture.ownerId.uuid, messageId: message.uuid)
            let initial = try #require(consumer.atom.value)
            let target = PaneContextPreparedMessageLeafRecorder.Target(initial.publication, row: row)
            // Initial application establishes the actual popover window. It is not the calibration verdict.
            _ = try await leaf.wait(
                for: target, expectedLabel: "A persistent notice\nA full explanation Now", age: "Now", isRead: false)
            let identifier = "pane-context.message-text." + row.controlScope
            let native = try #require(window.find(identifier) as? NSView)
            let owningWindow = try #require(native.window)
            let hostingView = try #require(owningWindow.contentView)
            let wake = try #require(await bindings.owner.scheduledWakeProducer())
            let scope = PopoverOwnerProofScope(channel: .owner(.deadline(wake.sequence)))
            try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
            try await bridge.facts.expectNext(in: scope, .clockRegistered(clock.now.advanced(by: .seconds(60))))
            clock.advance(by: .seconds(60))
            await wake.task.value
            let execution = try #require(await bindings.owner.latestExecution(for: consumer.key))
            try #require(execution.id != consumer.opening.initialExecution.id)
            try await consumePublished(execution, key: consumer.key, bridge: bridge)
            let published = try #require(consumer.atom.value)
            let minute = PaneContextPreparedMessageLeafRecorder.Target(published.publication, row: row)
            try leaf.requireCurrent(minute)
            let before = leaf.applied(to: minute)
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            let during = leaf.applied(to: minute)
            owningWindow.displayIfNeeded()
            let after = leaf.applied(to: minute)
            print(
                "D56 calibration publication=\(published.publication.id) window=\(owningWindow.windowNumber) host=\(type(of: hostingView)) before=\(before?.row.age.text ?? "<pending>") during=\(during?.row.age.text ?? "<pending>") after=\(after?.row.age.text ?? "<pending>") flushedPending=\(before == nil && after != nil)"
            )
            let applied = try #require(
                after, "D56 one forced host update did not apply the exact published row; no native wait follows")
            #expect(applied.row.age.text == "1 min ago")
            #expect(applied.native.label == "A persistent notice\nA full explanation 1 min ago")
            #expect(
                (window.find(identifier) as? any NSAccessibilityProtocol)?.accessibilityLabel() == applied.native.label)
            try await window.close()
            mounted = nil
            await bindings.stop()
            #expect(clock.pendingSleepCount == 0)
            bridge.facts.receive(.ended)
            try await bridge.facts.finish()
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            await bindings.stop()
            bridge.facts.receive(.ended)
            try? await bridge.facts.finish()
            try? await fixture.close()
            throw error
        }
    }

    private func consumePublished(
        _ execution: PaneContextPopoverExecution, key: PaneContextPopoverConsumerKey,
        bridge: PopoverOwnerFactBridge
    ) async throws {
        await execution.task.value
        try #require(
            bridge.didFinish(.execution(key, execution.id)), "The producing task ended without its terminal owner fact")
        let scope = PopoverOwnerProofScope(channel: .owner(.execution(key, execution.id)))
        while true {
            let fact = try await bridge.facts.expectNext(
                in: scope, where: { _ in true },
                "the exact owner's published/equal or failure/supersession/retirement outcome")
            if case .owner(.finished(let outcome)) = fact {
                try #require(
                    outcome == .published || outcome == .equal, "Owner ended without a current publication: \(outcome)")
                return
            }
        }
    }
    private final class NativeOpening {
        var tasks: [Task<Void, Never>] = []
        var consumer: PaneContextPopoverConsumerHandle?
    }
}
