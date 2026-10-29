import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextUIRoundFramesTests {
    enum GapFrame: String, CaseIterable { case ask, info, buildOutput }

    @Test("D84a 480-point ask, Info and Build output originals", arguments: GapFrame.allCases)
    func renderGapCorrection(frame: GapFrame) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            host.native.window.appearance = NSAppearance(named: .darkAqua)
            // The real empty opening freezes 480 before the later multiline arrival.
            try await host.open()
            try await host.rendered()
            let body: String
            let shape: PaneMessageSendShape
            switch frame {
            case .ask:
                body = "Type a short reply to verify the pane card"
                shape = .ask(reason: .question, form: .freeText(placeholder: "Your reply"), waiting: .nonBlocking)
            case .info:
                body = "A one-line information notice"
                shape = .notice
            case .buildOutput:
                body = Self.compilerOutput
                shape = .notice
            }
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: frame == .ask ? .attention : (frame == .buildOutput ? .failure : .info),
                        body: body, why: nil, actions: [], shape: shape)) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            try await host.refresh()
            try await host.bodyLayoutsPrepared()
            let handle = try #require(host.handle)
            for producer in host.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
                await producer.value
            }
            try await host.rendered()
            for root in host.native.roots {
                root.appearance = NSAppearance(named: .darkAqua)
                root.window?.appearance = NSAppearance(named: .darkAqua)
            }
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            try applyLocalView(panel)
            #expect(panel.bounds.width == 480)
            try save(
                panel, name: "d84a-" + frame.rawValue + "-480",
                opaqueBackground: AppStyles.Shell.TabBar.titlebarBackground)
            try saveMeasurements(
                host, panel: panel, name: "d84a-" + frame.rawValue + "-480",
                row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

}
