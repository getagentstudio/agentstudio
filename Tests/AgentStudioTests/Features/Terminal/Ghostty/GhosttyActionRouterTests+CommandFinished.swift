import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import AgentStudioTerminal

extension GhosttyActionRouterTests {
    @Test("registered surface routes commandFinished payload through runtime envelope")
    func actionRouter_endToEnd_commandFinishedPayloadReachesRuntime() async {
        let surfaceViewObjectId = ObjectIdentifier(NSView(frame: .zero))
        let surfaceId = UUID()
        let paneUUID = UUIDv7.generate()
        let paneId = PaneId(existingUUID: paneUUID)
        let runtime = TerminalRuntime(
            paneId: paneId,
            metadata: PaneMetadata(
                paneId: paneId,
                title: "Runtime"
            )
        )
        let runtimeRegistry = RuntimeRegistry()
        _ = runtimeRegistry.register(runtime)
        let lookup = FakeActionRoutingLookup(
            surfaceIdsByViewObjectId: [surfaceViewObjectId: surfaceId],
            paneIdsBySurfaceId: [surfaceId: paneUUID]
        )
        let sourceInstant = ContinuousClock.now

        let originalRegistry = Ghostty.ActionRouter.runtimeRegistryForActionRouting
        Ghostty.ActionRouter.setRuntimeRegistry(runtimeRegistry)
        defer {
            Ghostty.ActionRouter.setRuntimeRegistry(originalRegistry)
        }

        let routed = Ghostty.ActionRouter.routeActionToTerminalRuntimeOnMainActor(
            actionTag: UInt32(GHOSTTY_ACTION_COMMAND_FINISHED.rawValue),
            payload: .commandFinished(exitCode: 7, duration: 42, sourceInstant: sourceInstant),
            surfaceViewObjectId: surfaceViewObjectId,
            routingLookup: lookup
        )

        #expect(routed)

        let replay = await runtime.eventsSince(seq: 0)
        guard
            let firstEvent = replay.events.first,
            case .pane(let paneEnvelope) = firstEvent,
            case .terminal(.commandFinished(let exitCode, let duration)) = paneEnvelope.event
        else {
            Issue.record("Expected replay to include terminal commandFinished event")
            return
        }

        #expect(exitCode == 7)
        #expect(duration == 42)
        #expect(paneEnvelope.timestamp == sourceInstant)
    }
}
