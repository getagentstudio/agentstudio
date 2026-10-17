import AgentStudioCore
import Foundation
import Testing

@testable import AgentStudioTerminal

extension GhosttyActionRouterTests {
    @Test("registered surface routes commandFinished payload through runtime envelope")
    func actionRouter_endToEnd_commandFinishedPayloadReachesRuntime() async throws {
        let sourceInstant = ContinuousClock.now
        try await withGhosttyActionRouterTestFixture { fixture in
            #expect(
                fixture.route(
                    .commandFinished,
                    .commandFinished(exitCode: 7, duration: 42, sourceInstant: sourceInstant)
                )
            )

            let replay = await fixture.runtime.eventsSince(seq: 0)
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
}
