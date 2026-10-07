import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioSessions

@Suite("Session status publication")
struct SessionStatusPublicationTests {
    @Test("equal desired values publish nothing even while pending or in flight")
    func equalityUsesDesiredValue() {
        let mailbox = SessionStatusPublicationMailbox()
        let paneId = PaneId.generateUUIDv7()
        #expect(mailbox.offer(.working(.active), for: paneId))
        #expect(!mailbox.offer(.working(.active), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .set(.working(.active))])
        #expect(!mailbox.offer(.working(.active), for: paneId))
        #expect(mailbox.takeBatch().isEmpty)
    }

    @Test("A to B to A publishes the final A against desired B, not the applied baseline")
    func returnToPreviousValueIsNotSuppressed() {
        let mailbox = SessionStatusPublicationMailbox()
        let paneId = PaneId.generateUUIDv7()
        mailbox.offer(.working(.active), for: paneId)
        _ = mailbox.takeBatch()
        mailbox.offer(.needsYou(.question), for: paneId)
        #expect(mailbox.offer(.working(.active), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .set(.working(.active))])
    }

    @Test("retirement joins the mailbox and rejects every later set")
    func retiredPaneNeverResurrects() {
        let mailbox = SessionStatusPublicationMailbox()
        let paneId = PaneId.generateUUIDv7()
        mailbox.offer(.working(.active), for: paneId)
        mailbox.retire(paneId)
        #expect(!mailbox.offer(.idle(.ended), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .remove])
        #expect(!mailbox.offer(.working(.active), for: paneId))
        #expect(mailbox.takeBatch().isEmpty)
    }

    @Test("one batch carries multiple panes and an ended binding stays until retirement")
    func batchingAndEndedStatusRetention() async {
        let mailbox = SessionStatusPublicationMailbox()
        let recorded = Mutex<[[PaneId: SessionStatusPublication]]>([])
        let lane = SessionStatusPublicationLane(
            mailbox: mailbox, sink: { batch in recorded.withLock { $0.append(batch) } })
        let firstPane = PaneId.generateUUIDv7()
        let secondPane = PaneId.generateUUIDv7()
        mailbox.offer(.idle(.ended), for: firstPane)
        mailbox.offer(.needsYou(.approval), for: secondPane)
        await lane.publishPending()
        #expect(recorded.withLock { $0 } == [[firstPane: .set(.idle(.ended)), secondPane: .set(.needsYou(.approval))]])
        #expect(!mailbox.offer(.idle(.ended), for: firstPane))
        await lane.publishPending()
        #expect(recorded.withLock { $0.count } == 1)
        await lane.shutdown()
    }

    @Test("a burst while the sink is held coalesces behind exactly one awaited batch")
    func heldSinkCoalescesAndPreservesOrder() async throws {
        let mailbox = SessionStatusPublicationMailbox()
        let heldSink = HeldStep<[PaneId: SessionStatusPublication]>("first Sessions status sink")
        let recorded = Mutex<[[PaneId: SessionStatusPublication]]>([])
        let lane = SessionStatusPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                MainActor.preconditionIsolated()
                recorded.withLock { $0.append(batch) }
                try? await heldSink.arrive(batch)
            })
        let paneId = PaneId.generateUUIDv7()
        mailbox.offer(.working(.active), for: paneId)
        let firstDrain = Task { await lane.publishPending() }
        let arrival: [PaneId: SessionStatusPublication]
        do {
            arrival = try await heldSink.firstArrival()
        } catch {
            heldSink.retire()
            firstDrain.cancel()
            await firstDrain.value
            await lane.shutdown()
            throw error
        }
        #expect(arrival == [paneId: .set(.working(.active))])
        mailbox.offer(.needsYou(.approval), for: paneId)
        mailbox.offer(.idle(.done), for: paneId)
        mailbox.offer(.working(.monitoring), for: paneId)
        #expect(!mailbox.offer(.working(.monitoring), for: paneId))
        heldSink.release()
        await firstDrain.value
        await lane.publishPending()
        #expect(recorded.withLock { $0 } == [[paneId: .set(.working(.active))], [paneId: .set(.working(.monitoring))]])
        await lane.shutdown()
    }
}
