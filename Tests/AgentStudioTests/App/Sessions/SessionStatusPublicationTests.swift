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
        #expect(mailbox.offer(.init(status: .working(.active)), for: paneId))
        #expect(!mailbox.offer(.init(status: .working(.active)), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .set(.init(status: .working(.active)))])
        #expect(!mailbox.offer(.init(status: .working(.active)), for: paneId))
        #expect(mailbox.takeBatch().isEmpty)
    }

    @Test("A to B to A publishes the final A against desired B, not the applied baseline")
    func returnToPreviousValueIsNotSuppressed() {
        let mailbox = SessionStatusPublicationMailbox()
        let paneId = PaneId.generateUUIDv7()
        mailbox.offer(.init(status: .working(.active)), for: paneId)
        _ = mailbox.takeBatch()
        mailbox.offer(.init(status: .needsYou(.question)), for: paneId)
        #expect(mailbox.offer(.init(status: .working(.active)), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .set(.init(status: .working(.active)))])
    }

    @Test("retirement joins the mailbox and rejects every later set")
    func retiredPaneNeverResurrects() {
        let mailbox = SessionStatusPublicationMailbox()
        let paneId = PaneId.generateUUIDv7()
        mailbox.offer(.init(status: .working(.active)), for: paneId)
        mailbox.retire(paneId)
        #expect(!mailbox.offer(.init(status: .idle(.ended)), for: paneId))
        #expect(mailbox.takeBatch() == [paneId: .remove])
        #expect(!mailbox.offer(.init(status: .working(.active)), for: paneId))
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
        mailbox.offer(.init(status: .idle(.ended)), for: firstPane)
        mailbox.offer(.init(status: .needsYou(.approval)), for: secondPane)
        await lane.publishPending()
        #expect(
            recorded.withLock { $0 } == [
                [firstPane: .set(.init(status: .idle(.ended))), secondPane: .set(.init(status: .needsYou(.approval)))]
            ])
        #expect(!mailbox.offer(.init(status: .idle(.ended)), for: firstPane))
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
        mailbox.offer(.init(status: .working(.active)), for: paneId)
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
        #expect(arrival == [paneId: .set(.init(status: .working(.active)))])
        mailbox.offer(.init(status: .needsYou(.approval)), for: paneId)
        mailbox.offer(.init(status: .idle(.done)), for: paneId)
        mailbox.offer(.init(status: .working(.monitoring)), for: paneId)
        #expect(!mailbox.offer(.init(status: .working(.monitoring)), for: paneId))
        heldSink.release()
        await firstDrain.value
        await lane.publishPending()
        #expect(
            recorded.withLock { $0 } == [
                [paneId: .set(.init(status: .working(.active)))], [paneId: .set(.init(status: .working(.monitoring)))],
            ])
        await lane.shutdown()
    }
    @Test("an issue-only change publishes the cohesive value and equal repeats are suppressed")
    func connectionIssueParticipatesInEquality() {
        let mailbox = SessionStatusPublicationMailbox()
        let pane = PaneId.generateUUIDv7()
        let connected = PaneAgentStatusPresentation(status: .needsYou(.approval))
        let disconnected = PaneAgentStatusPresentation(
            status: .needsYou(.approval), connectionIssue: .credentialNotRecognized)
        #expect(mailbox.offer(connected, for: pane))
        _ = mailbox.takeBatch()
        #expect(mailbox.offer(disconnected, for: pane))
        #expect(!mailbox.offer(disconnected, for: pane))
        #expect(mailbox.takeBatch() == [pane: .set(disconnected)])
    }

    @Test("shutdown drains a final removal behind an in-flight status publication")
    func shutdownJoinsFinalRemoval() async throws {
        let mailbox = SessionStatusPublicationMailbox()
        let held = HeldStep<[PaneId: SessionStatusPublication]>("status sink held before quit removal")
        let recorded = Mutex<[[PaneId: SessionStatusPublication]]>([])
        let lane = SessionStatusPublicationLane(
            mailbox: mailbox,
            sink: { batch in
                recorded.withLock { $0.append(batch) }
                try? await held.arrive(batch)
            })
        let pane = PaneId.generateUUIDv7()
        let presentation = PaneAgentStatusPresentation(
            status: .needsYou(.approval), connectionIssue: .credentialNotRecognized)
        mailbox.offer(presentation, for: pane)
        await lane.start()
        do {
            _ = try await held.firstArrival()
            mailbox.retire(pane)
            let shutdown = Task { await lane.shutdown() }
            held.release()
            await shutdown.value
            #expect(recorded.withLock { $0 } == [[pane: .set(presentation)], [pane: .remove]])
            #expect(!mailbox.offer(presentation, for: pane))
        } catch {
            held.release()
            await lane.shutdown()
            throw error
        }
    }

}
