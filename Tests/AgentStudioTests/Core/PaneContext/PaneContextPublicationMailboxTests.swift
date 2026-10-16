import AgentStudioTestSupport
import Testing

@testable import AgentStudioCore

@Suite("Pane context publication mailbox")
struct PaneContextPublicationMailboxTests {
    @Test("Equal pending or in-flight desired values are suppressed off-main")
    func desiredEqualitySurvivesBatchTake() {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        let display = presentationDisplay(title: "A")
        #expect(mailbox.offer(display, for: pane))
        #expect(!mailbox.offer(display, for: pane))
        #expect(mailbox.takeBatch() == [pane: .set(display)])
        #expect(!mailbox.offer(display, for: pane))
        #expect(mailbox.takeBatch().isEmpty)
        #expect(mailbox.counts().suppressed == 2)
    }

    @Test("A to B to A ends at A, using desired B rather than the applied baseline")
    func returnToAppliedValueStillPublishes() {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        let first = presentationDisplay(title: "A")
        mailbox.offer(first, for: pane)
        _ = mailbox.takeBatch()
        mailbox.offer(presentationDisplay(title: "B"), for: pane)
        #expect(mailbox.offer(first, for: pane))
        #expect(mailbox.takeBatch() == [pane: .set(first)])
        #expect(mailbox.counts().coalesced == 1)
    }

    @Test("A revision-only change publishes even when badges and text are equal")
    func revisionParticipatesInEquality() {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        mailbox.offer(presentationDisplay(revision: 1), for: pane)
        #expect(mailbox.offer(presentationDisplay(revision: 2), for: pane))
        #expect(mailbox.takeBatch() == [pane: .set(presentationDisplay(revision: 2))])
    }

    @Test("Retirement replaces a pending set and prevents resurrection")
    func retirementJoinsSetLane() {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        mailbox.offer(presentationDisplay(title: "Pending"), for: pane)
        mailbox.retire(pane)
        #expect(!mailbox.offer(presentationDisplay(title: "Late"), for: pane))
        #expect(mailbox.takeBatch() == [pane: .remove])
        #expect(!mailbox.offer(presentationDisplay(), for: pane))
        #expect(mailbox.takeBatch().isEmpty)
    }

    @Test("Full reconciliation publishes every live owner and removes a deleted known key")
    func fullReconcileRetiresMissingKey() {
        let membership = TestPaneContextMembership()
        let mailbox = PaneContextPublicationMailbox(isPresent: { membership.sources(for: $0) != nil })
        let survivor = PaneId.generateUUIDv7()
        let deleted = PaneId.generateUUIDv7()
        let newcomer = PaneId.generateUUIDv7()
        for paneId in [survivor, deleted, newcomer] { membership.addPane(paneId) }
        mailbox.offer(presentationDisplay(title: "Survivor"), for: survivor)
        mailbox.offer(presentationDisplay(title: "Deleted during hold"), for: deleted)
        _ = mailbox.takeBatch()
        let current = presentationDisplay(revision: 2, title: "Current")
        let new = presentationDisplay(title: "New")
        membership.removePane(deleted)
        mailbox.reconcile([survivor: current, newcomer: new])
        #expect(mailbox.takeBatch() == [survivor: .set(current), newcomer: .set(new), deleted: .remove])
        #expect(!mailbox.offer(presentationDisplay(title: "Resurrect"), for: deleted))
    }

    @Test("Closing the mailbox rejects sets and removals")
    func closeRejectsFurtherPublication() {
        let mailbox = PaneContextPublicationMailbox(isPresent: { _ in true })
        let pane = PaneId.generateUUIDv7()
        mailbox.close()
        #expect(!mailbox.offer(presentationDisplay(), for: pane))
        mailbox.retire(pane)
        #expect(mailbox.takeBatch().isEmpty)
    }
}
