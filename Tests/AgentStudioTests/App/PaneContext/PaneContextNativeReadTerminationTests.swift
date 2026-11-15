import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

@MainActor
@Suite("Native read non-arrival exits", .serialized)
struct PaneContextNativeReadTerminationTests {
    @Test(
        "F03 cancellation or view retirement fails the native wait with its outcome and shuts down",
        arguments: [false, true])
    func nonArrivalHasATerminalExit(retire: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let adapter = PaneContextUIAdapter(service: fixture.composition.paneContextService)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: fixture.presentationAtom,
            pane: { _ in nil }, serviceProvider: { adapter })
        let mounted = owners.makeNativeHost(
            paneId: fixture.ownerId, entry: .kind(.init(kind: .needsYou, count: 1)), wallNow: fixture.now)
        do {
            let opening = try mounted.beginOpening()
            if retire { mounted.native.window.close() } else { opening.task.cancel() }
            do {
                _ = try await mounted.consumer(for: opening)
                Issue.record("A read without its completion callback must fail the native witness")
            } catch {
                let outcome = String(describing: error)
                #expect(
                    outcome.contains("endedWithoutConsumer"),
                    "Unexpected non-arrival: \(outcome)")
                Attachment.record(outcome, named: "native-read-non-arrival.txt")
            }
            try await mounted.close()
            #expect(mounted.clock.pendingSleepCount == 0)
            try await fixture.close()
        } catch {
            try? await mounted.close()
            try? await fixture.close()
            throw error
        }
    }
}
