import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@Suite("Terminal compact output and activity consumers")
struct TerminalCompactOutputConsumerTests {
    @Test("activity windows preserve compact output values", arguments: [false, true])
    func compactOutputIsUnchanged(hasActivityConsumer: Bool) async throws {
        let updates = Mutex<[TerminalActivityCompactUpdate]>([])
        let sink: (@Sendable (PaneActivityOccurrence) -> Void)?
        if hasActivityConsumer {
            sink = { (_: PaneActivityOccurrence) in }
        } else {
            sink = nil
        }
        let projector = TerminalActivityProjector(clock: TestPushClock(), activitySink: sink)
        let surfaceId = UUIDv7.generate()
        let paneId = UUIDv7.generate()
        await projector.configure { outcomes in
            for case .compactStateChanged(let update) in outcomes { updates.withLock { $0.append(update) } }
        }
        for (first, latest) in [(100, 140), (140, 220), (220, 220), (220, 260)] {
            var aggregate = TerminalScrollbarActivityAggregate(
                state: .init(top: first - 40, bottom: first, total: first), observedAtMilliseconds: 1000)
            aggregate.merge(
                state: .init(top: latest - 40, bottom: latest, total: latest),
                observedAtMilliseconds: 1100)
            await projector.ingest(
                surfaceID: surfaceId, paneID: paneId, aggregate: aggregate,
                latestState: .init(top: latest - 40, bottom: latest, total: latest),
                context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30))
        }
        await projector.reset()
        let expected = [(140, 40), (220, 120), (260, 160)].map { total, added in
            TerminalActivityCompactUpdate(
                surfaceID: surfaceId, paneID: paneId,
                scrollbarState: .init(top: total - 40, bottom: total, total: total),
                outputBurst: .accumulating(
                    .init(baselineTotal: 100, latestTotal: total, addedRows: added, threshold: 30)))
        }
        #expect(updates.withLock { $0 } == expected)
    }
}
