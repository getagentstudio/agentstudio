import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// One real socket, one real Sessions database. These cases exist to prove the
/// whole path: transport, authorization, canonical pane targeting, the App
/// adapter's mapping and the durable Sessions reduction underneath it.
@MainActor
@Suite("App IPC sessions vertical", .serialized, SessionsVerticalHarnessTrait(providerProfiles: .defaultProfiles))
struct AgentStudioIPCSessionsVerticalTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("only a first qualified hook from the pane's own credential changes its activity time")
    func hookActivityAdmissionUsesCommittedPaneProvenance() async throws {
        let harness = try await SessionsVerticalHarness.make(installActivityClock: true)
        do {
            let clock = try #require(harness.appDelegate.paneActivityClock)
            let activityAtom = harness.appDelegate.atomStore.core.paneActivityTime
            do {
                let conversationId = "activity-\(harness.boundPaneId.uuidString)"
                _ = try await harness.sessionEvent(
                    paneId: harness.boundPaneId,
                    provider: SessionsVerticalHarness.qualifiedProvider,
                    name: "sessionStart",
                    conversationId: conversationId,
                    authentication: .boundPane
                )
                #expect(try await clock.settled() == .quiescent)
                #expect(activityAtom.value(for: harness.boundPaneId) == nil)

                let occurrenceId = UUIDv7.generate()
                let correlationId = UUIDv7.generate()
                let first = try await harness.sessionEvent(
                    paneId: harness.boundPaneId,
                    provider: SessionsVerticalHarness.qualifiedProvider,
                    name: "turnStart",
                    conversationId: conversationId,
                    occurrenceId: occurrenceId,
                    correlationId: correlationId,
                    authentication: .boundPane
                )
                #expect(first.disposition == .admitted)
                #expect(try await clock.settled() == .quiescent)
                let firstTime = try #require(activityAtom.value(for: harness.boundPaneId))
                let firstRevision = activityAtom.revision(for: harness.boundPaneId)

                do {
                    _ = try await harness.sessionEvent(
                        paneId: harness.boundPaneId,
                        provider: SessionsVerticalHarness.qualifiedProvider,
                        name: "turnStart",
                        conversationId: conversationId,
                        occurrenceId: occurrenceId,
                        correlationId: correlationId,
                        authentication: .boundPane
                    )
                } catch SessionsVerticalHarnessError.requestFailed(let method, let code, _) {
                    #expect(method == "session.event")
                    #expect(code == -32_007)
                }
                #expect(try await clock.settled() == .quiescent)
                #expect(activityAtom.value(for: harness.boundPaneId) == firstTime)
                #expect(activityAtom.revision(for: harness.boundPaneId) == firstRevision)

                let otherConversation = "other-\(harness.sparePaneId.uuidString)"
                _ = try await harness.sessionEvent(
                    paneId: harness.sparePaneId,
                    provider: SessionsVerticalHarness.qualifiedProvider,
                    name: "sessionStart",
                    conversationId: otherConversation
                )
                _ = try await harness.sessionEvent(
                    paneId: harness.sparePaneId,
                    provider: SessionsVerticalHarness.qualifiedProvider,
                    name: "turnStart",
                    conversationId: otherConversation
                )
                #expect(try await clock.settled() == .quiescent)
                #expect(activityAtom.value(for: harness.sparePaneId) == nil)

                _ = try await harness.sessionEvent(
                    paneId: harness.boundPaneId,
                    provider: SessionsVerticalHarness.qualifiedProvider,
                    name: "sessionEnd",
                    conversationId: conversationId,
                    authentication: .boundPane
                )
                #expect(try await clock.settled() == .quiescent)
                #expect(activityAtom.revision(for: harness.boundPaneId) == firstRevision)
            } catch {
                await clock.shutdown()
                throw error
            }
            await clock.shutdown()
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("a qualified provider session start binds the pane and an unknown provider does not")
    func qualifiedSessionStartBindsThePane() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()

        let admitted = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-bind"
        )
        #expect(admitted.disposition == .admitted)

        let unknown = try await harness.sessionEvent(
            paneId: harness.sparePaneId,
            provider: IPCSessionProviderIdentity(identifier: "never-shipped", version: "9.9.9", mode: "interactive"),
            name: "sessionStart",
            conversationId: "conversation-unknown"
        )
        #expect(unknown.disposition == .unknownCapability)

        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .live)
        #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .unbound)
    }

    @Test("a needs-you report reaches the query as agent-reported state with a request identity")
    func needsYouReportReachesTheQuery() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()

        let report = try await harness.sessionReport(
            paneId: harness.boundPaneId,
            kind: "needsYou",
            explanation: "waiting on approval"
        )
        #expect(report.state == .needsYou)
        #expect(report.origin == .agentReported)
        let requestId = try #require(report.requestId)

        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.state == .needsYou)
        #expect(queried.origin == .agentReported)
        #expect(queried.needsYou?.requestId == requestId)
        #expect(queried.needsYou?.explanation == "waiting on approval")
    }

    @Test("a done report reaches the query as agent-reported done")
    func doneReportReachesTheQuery() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()

        let report = try await harness.sessionReport(paneId: harness.boundPaneId, kind: "done", explanation: nil)
        #expect(report.state == .done)

        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.state == .done)
        #expect(queried.origin == .agentReported)
        #expect(queried.needsYou == nil)
    }

    @Test("a message with Unicode and an embedded newline round-trips exactly")
    func messageTextRoundTripsExactly() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()
        let text = "migration \u{1F680} done\nsecond line \u{00E9}\u{4E2D}"

        let sent = try await harness.sessionMessage(paneId: harness.boundPaneId, text: text)
        #expect(sent.attributed)

        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.messages.map(\.text) == [text])
        #expect(queried.messages.first?.seen == false)
        #expect(queried.messages.first?.occurrenceId == sent.occurrenceId)
    }

    @Test("the same message correlation sent twice stores one occurrence and returns the same result")
    func repeatedMessageCorrelationStoresOneOccurrence() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()
        let correlationId = UUIDv7.generate()

        let first = try await harness.sessionMessage(
            paneId: harness.boundPaneId, text: "only once", correlationId: correlationId
        )
        let second = try await harness.sessionMessage(
            paneId: harness.boundPaneId, text: "only once", correlationId: correlationId
        )

        #expect(first == second)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).messages.count == 1)
    }

    @Test("an unbound pane keeps a message durable and unattributed but refuses a deliberate report")
    func unboundPaneKeepsMessagesAndRefusesReports() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()

        // The same awkward text as the bound case: an unattributed message is a
        // successful durable outcome, so it may not lose a byte either.
        let text = "no binding yet \u{1F9ED}\nsecond line \u{00E9}\u{4E2D}"
        let sent = try await harness.sessionMessage(paneId: harness.sparePaneId, text: text)
        #expect(!sent.attributed)

        let queried = try await harness.sessionQuery(paneId: harness.sparePaneId)
        #expect(queried.messages.map(\.text) == [text])
        #expect(queried.messages.first?.occurrenceId == sent.occurrenceId)
        #expect(queried.sourceHealth == .unbound)

        let failure = try await harness.rawSessionReport(
            paneId: harness.sparePaneId, kind: "needsYou", explanation: "nobody home"
        )
        let errorData = try #require(failure.error?.data)
        guard case .object(let fields) = errorData, case .string(let reason)? = fields["reason"] else {
            Issue.record("an unbound deliberate report did not report a typed reason")
            return
        }
        #expect(reason == "bindingRequired")
    }

    /// Program design, Binding admission: an ended or older generation arriving
    /// after the one that replaced it is historical only and never replaces it.
    /// A provider that has not noticed it was replaced keeps sending, and the
    /// generation an event belongs to is the conversation it names — not
    /// whatever the pane happens to be bound to when the event lands.
    @Test("a delayed event from a replaced conversation becomes history and leaves the new generation alone")
    func delayedEventFromReplacedConversationStaysHistorical() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        // Arrange: conversation A binds the pane, then conversation B replaces it.
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-a"
        )
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-b"
        )
        let delayedOccurrenceId = UUIDv7.generate()

        // Act: A reports a turn start it began before it was replaced.
        let delayed = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "turnStart",
            conversationId: "conversation-a",
            occurrenceId: delayedOccurrenceId
        )

        // Assert: it is durable against A's own generation and invisible to B.
        #expect(delayed.disposition == .admitted)
        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.state == .unknown)
        #expect(queried.sourceHealth == .live)
        let snapshot = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        #expect(snapshot.historicalOccurrenceIds == [delayedOccurrenceId])
    }

    /// A delayed end retires the generation it names. Ending B because A said
    /// so would take the pane's live source away from a conversation that never
    /// finished.
    @Test("a delayed session end from a replaced conversation leaves the live source alone")
    func delayedSessionEndFromReplacedConversationLeavesTheLiveSource() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        // Arrange
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-a"
        )
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-b"
        )

        // Act: A ends. Its generation was already retired when B replaced it,
        // so this is a duplicate the reduction absorbs.
        let delayedEnd = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionEnd",
            conversationId: "conversation-a"
        )

        // Assert
        #expect(delayedEnd.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .live)

        // Act: B ends its own generation.
        let liveEnd = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionEnd",
            conversationId: "conversation-b"
        )

        // Assert
        #expect(liveEnd.disposition == .admitted)
        #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .ended)
    }

    /// A conversation identifier this pane never bound is not late evidence
    /// about anything. Recording it against the current generation would make
    /// one pane's state answer for a session that was never on it.
    @Test("an event naming a conversation the pane never bound is refused and stores nothing")
    func eventNamingAnUnknownConversationIsRefused() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        // Arrange
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-a"
        )

        // Act
        let foreign = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "turnStart",
            conversationId: "conversation-never-bound"
        )

        // Assert
        #expect(foreign.disposition == .unqualified)
        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.state == .unknown)
        #expect(queried.sourceHealth == .live)
        let snapshot = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        #expect(snapshot.historicalOccurrenceIds.isEmpty)
    }

    /// The event's own conversation still drives the pane it is bound to. This
    /// is the case the delayed-event rule must not cost anything.
    @Test("an event from the conversation that owns the live generation still drives the pane")
    func eventFromTheLiveConversationStillDrivesThePane() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        // Arrange
        _ = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "sessionStart",
            conversationId: "conversation-a"
        )

        // Act
        let turnStart = try await harness.sessionEvent(
            paneId: harness.boundPaneId,
            provider: SessionsVerticalHarness.qualifiedProvider,
            name: "turnStart",
            conversationId: "conversation-a"
        )

        // Assert
        #expect(turnStart.disposition == .admitted)
        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.state == .running)
        #expect(queried.origin == .reported)
    }
}
