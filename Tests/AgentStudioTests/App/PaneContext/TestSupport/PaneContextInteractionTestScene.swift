import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

/// Real composition, prepared host and person actions; input enters at the controls' normal binding boundary.
@MainActor
final class PaneContextInteractionTestScene {
    let fixture: CompositionFactoryFixture
    let host: PaneContextPreparedNativeHost
    let choice: AgentMessageId
    let text: AgentMessageId
    let notice: AgentMessageId
    private var closed = false

    private init(
        fixture: CompositionFactoryFixture, host: PaneContextPreparedNativeHost,
        choice: AgentMessageId, text: AgentMessageId, notice: AgentMessageId
    ) {
        self.fixture = fixture
        self.host = host
        self.choice = choice
        self.text = text
        self.notice = notice
    }

    static func make(entry: PaneContextPopoverEntry? = nil) async throws -> PaneContextInteractionTestScene {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            let choice = AgentMessageId.generateUUIDv7()
            let text = AgentMessageId.generateUUIDv7()
            let notice = AgentMessageId.generateUUIDv7()
            let requests: [(AgentMessageId, String, PaneMessageSendShape)] = [
                (
                    choice, "Pick the preview color",
                    .ask(
                        reason: .question,
                        form: .choice(
                            options: [
                                .init(id: try .init("red"), label: "Red"), .init(id: try .init("blue"), label: "Blue"),
                            ], allowsMultiple: false), waiting: .nonBlocking)
                ),
                (
                    text, "Describe the check",
                    .ask(
                        reason: .question,
                        form: .freeText(placeholder: "Your reply"), waiting: .nonBlocking)
                ),
                (notice, (1...33).map { "Information line \($0)" }.joined(separator: "\n"), .notice),
            ]
            for (id, body, shape) in requests {
                let result = await fixture.composition.paneContextService.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: id == notice ? .info : .attention, body: body, why: nil, actions: [], shape: shape))
                try #require(result == .created(id))
            }
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: entry ?? .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            try await host.open()
            try await host.rendered()
            try await host.bodyLayoutsPrepared()
            return .init(fixture: fixture, host: host, choice: choice, text: text, notice: notice)
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    func key(_ message: AgentMessageId) -> MessageRowModel.Key {
        .init(sourcePaneId: fixture.ownerId.uuid, messageId: message.uuid)
    }

    func bindings() throws -> MessagesPopoverBindings {
        let handle = try #require(host.handle)
        let value = try #require(handle.atom.latestAcceptedValue)
        return host.interactions.bindings(
            versions: value.interactions.versions, opening: handle.opening.epoch,
            currentVersions: { handle.atom.latestAcceptedValue?.interactions.versions })
    }

    func filter(_ value: Int) async throws {
        try bindings().selectedFilter.wrappedValue = value
        try await host.bodyLayoutsPrepared()
    }

    func submitControl(_ message: AgentMessageId) throws -> any NSAccessibilityProtocol {
        let identifier = PaneContextPopoverControlProjection.controls().submit.identifier(in: key(message).controlScope)
        return try #require(
            host.native.find(identifier) as? any NSAccessibilityProtocol,
            "The real Submit control was absent after the renderer input changed")
    }

    func submit(_ message: AgentMessageId, action: Int) async throws {
        let button = try submitControl(message)
        try #require(button.isAccessibilityEnabled(), "The retained pick must still enable its real Submit control")
        try host.native.press(
            PaneContextPopoverControlProjection.controls().submit.identifier(in: key(message).controlScope))
        try await host.actionCompleted(action)
        try await host.bodyLayoutsPrepared()
    }

    func detailControl(presented: Bool) -> String {
        let controls = PaneContextPopoverControlProjection.controls()
        if presented { return controls.closeDetails.identifier }
        return controls.showDetails.identifier(in: PaneContextTextBodyKey.message(key(notice)).textIdentifier)
    }

    func detailsValue(_ message: AgentMessageId) throws -> PaneContextMessageTextValue {
        guard case .messages(let model, _) = host.value?.content.body else { throw SceneFailure.missingMessage }
        return .init(row: try #require(model.messageRows.first { $0.key == key(message) }))
    }

    private enum SceneFailure: Error { case missingMessage }

    func close() async throws {
        guard !closed else { return }
        closed = true
        try await host.close()
        try await fixture.close()
    }
}
