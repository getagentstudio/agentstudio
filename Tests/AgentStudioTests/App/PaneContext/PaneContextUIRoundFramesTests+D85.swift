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
    enum DetailFrame: String, CaseIterable { case infoClosed, infoOpen, questionOpen }

    @Test("D85 truncated Info and full right-panel reading originals before hardening", arguments: DetailFrame.allCases)
    func renderDetailFrames(frame: DetailFrame) async throws {
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
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            host.native.window.appearance = NSAppearance(named: .darkAqua)
            try await host.open()
            let id = AgentMessageId.generateUUIDv7()
            let question = """
                Which evidence should we collect before changing TextKit retention?

                At opening, identify the executor that runs each text layout.
                Report the total and maximum layout duration for both schedules.
                Distinguish a requested key from a raw native width capture.
                Check whether repeated keys overlap or run again sequentially.
                Preserve the unchanged-minute zero-layout and zero-SQL proof.
                Do not add retention or a cache until the evidence is reviewed.
                """
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                        importance: frame == .questionOpen ? .attention : .info,
                        body: frame == .questionOpen ? question : Self.compilerOutput, why: nil, actions: [],
                        shape: frame == .questionOpen
                            ? .ask(
                                reason: .question, form: .freeText(placeholder: "Report the evidence"),
                                waiting: .nonBlocking)
                            : .notice)) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            try await host.refresh()
            try await host.bodyLayoutsPrepared()
            let handle = try #require(host.handle)
            for producer in host.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
                await producer.value
            }
            try await host.rendered()
            if frame != .infoClosed {
                try host.native.press(
                    PaneContextPopoverControlProjection.controls().showDetails.identifier(
                        in: PaneContextTextBodyKey.message(
                            .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid)
                        ).textIdentifier))
                host.native.layout()
            }
            for root in host.native.roots {
                root.appearance = NSAppearance(named: .darkAqua)
                root.window?.appearance = NSAppearance(named: .darkAqua)
            }
            let split = try #require(host.native.find("pane-context.details-panel.split") as? NSView)
            try applyLocalView(split)
            try save(
                split, name: "d85-" + frame.rawValue + "-480",
                opaqueBackground: AppStyles.Shell.TabBar.titlebarBackground)
            print("D85_FRAME", frame, "width", split.bounds.width, "height", split.bounds.height)
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
