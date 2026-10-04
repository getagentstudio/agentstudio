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

    @Test("a qualified first End needs its own capability, without an extra Start capability grant")
    func firstEndUsesItsQualifiedCapability() async throws {
        let provider = SessionsVerticalHarness.qualifiedProvider
        let profile = SessionsProviderProfile(
            providerIdentifier: provider.identifier, exactVersion: provider.version,
            operatingMode: provider.mode, qualifiedCapabilities: [.sessionEnd])
        let harness = try await SessionsVerticalHarness.make(providerProfiles: [profile])
        do {
            let ended = try await harness.sessionEvent(
                paneId: harness.boundPaneId, provider: provider,
                name: "sessionEnd", conversationId: "end-only")
            #expect(ended.disposition == .admitted)
            let read = try await harness.sessionQuery(paneId: harness.boundPaneId)
            #expect(read.sourceHealth == .ended)
            #expect(read.session?.status == .idle(state: .ended))
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }

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

    @Test("a retired attention assertion cannot mutate a bound pane")
    func needsYouReportReachesTheQuery() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()
        let before = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        let response = try await harness.rawSessionReport(
            paneId: harness.boundPaneId, kind: "needsYou", explanation: "waiting on approval")
        let after = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        #expect(response.error?.code == -32_601)
        #expect(after == before)
    }

    @Test("a retired done assertion cannot override hook-derived state")
    func doneReportReachesTheQuery() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        _ = try await harness.bindBoundPane()
        let before = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        let response = try await harness.rawSessionReport(paneId: harness.boundPaneId, kind: "done", explanation: nil)
        let after = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        #expect(response.error?.code == -32_601)
        #expect(after == before)
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
        #expect(queried.session?.status == .unknown)
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

    /// Rev34: a qualified first hook establishes its own conversation before
    /// recording evidence, retiring the previously bound conversation.
    @Test("a qualified hook for a never-bound conversation binds it before applying itself")
    func firstHookBindsItsOwnConversation() async throws {
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
        #expect(foreign.disposition == .admitted)
        let queried = try await harness.sessionQuery(paneId: harness.boundPaneId)
        #expect(queried.session?.status == .working(state: .active))
        #expect(queried.sourceHealth == .live)
        let snapshot = try await harness.paneSnapshot(paneId: harness.boundPaneId)
        #expect(snapshot.historicalOccurrenceIds.isEmpty)
        #expect(snapshot.currentBinding?.providerConversationId == "conversation-never-bound")
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
        #expect(queried.session?.status == .working(state: .active))
        #expect(queried.sourceHealth == .live)
    }
}
