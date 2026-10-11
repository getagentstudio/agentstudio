import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation

@testable import AgentStudioCore
@testable import AgentStudioTerminal

struct RecordedTerminalActivitySettle: Sendable {
    let envelope: PaneEnvelope
    let activity: TerminalSettledActivity
}

/// The stop marker relays an awaited producer shutdown after accepted bus work settles.
/// It is test-local observation vocabulary, not a new runtime envelope.
enum TerminalActivityEventObservation: Sendable {
    case event(PaneEnvelope)
    case producerStopped(TerminalActivityRouterFactScope)
}

/// Terminal-test observations of existing Core-owned runtime envelopes.
enum TerminalActivityEventFactSource {
    static func attach(
        bus: EventBus<RuntimeEnvelope>, subscriberName: String
    ) async -> FactRecorder<UUID, TerminalActivityEventObservation> {
        let subscription = await bus.subscribe(
            policy: .criticalUnbounded, subscriberName: subscriberName,
            factInterest: .matching([.paneTerminalActivity]))
        return EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary<UUID, TerminalActivityEventObservation>(
                describeScope: { $0.uuidString },
                describeFact: {
                    switch $0 {
                    case .event(let envelope): String(describing: envelope.event)
                    case .producerStopped(let stopScope): "terminal producer stopped: \(stopScope)"
                    }
                },
                isClosing: { _, fact in
                    if case .producerStopped = fact { return true }
                    return false
                }
            ),
            replayWasTruncated: {
                if case .possiblyTruncated = subscription.replayStatus { return true }
                return false
            },
            classify: {
                guard case .pane(let envelope) = $0,
                    case .terminalActivity = envelope.event
                else { return nil }
                return (envelope.paneId.uuid, .event(envelope))
            }
        )
    }
}

extension FactRecorder where Scope == UUID, Fact == TerminalActivityEventObservation {
    func expectNextPaneObservation(
        paneID: UUID, isPinnedToBottom: Bool,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> PaneEnvelope {
        let observation = try await expectNext(
            in: paneID,
            where: {
                guard case .event(let envelope) = $0,
                    case .terminalActivity(.paneObservationChanged(let observation)) = envelope.event
                else { return false }
                return observation.isPinnedToBottom == isPinnedToBottom
            },
            "pane observation changed to pinned=\(isPinnedToBottom)",
            fileID: fileID, line: line, function: function
        )
        guard case .event(let envelope) = observation else {
            throw UnexpectedFact.forExpectation(
                expected: "pane observation", actual: String(describing: observation),
                scope: paneID.uuidString, callSite: "\(fileID):\(line) \(function)")
        }
        return envelope
    }

    func expectNextUnseenActivity(
        paneID: UUID, windowID: UUID? = nil,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> RecordedTerminalActivitySettle {
        let observation = try await expectNext(
            in: paneID,
            where: {
                if case .event(let envelope) = $0,
                    case .terminalActivity(.unseenActivitySettled(let activity)) = envelope.event
                {
                    if let windowID { return activity.burstWindowId == windowID }
                    return true
                }
                return false
            },
            "unseen activity settled",
            fileID: fileID, line: line, function: function
        )
        guard case .event(let envelope) = observation,
            case .terminalActivity(.unseenActivitySettled(let activity)) = envelope.event
        else {
            throw UnexpectedFact.forExpectation(
                expected: "unseen activity settled", actual: String(describing: observation),
                scope: paneID.uuidString, callSite: "\(fileID):\(line) \(function)")
        }
        return RecordedTerminalActivitySettle(envelope: envelope, activity: activity)
    }

    /// Call after stopRouter returns its verified owner scope; drain accepted
    /// bus work before relaying that correlated close into this observation stream.
    func expectNoUnseenActivityThroughStoppedProducer(
        paneID: UUID, from opening: OpeningPosition<UUID>, stopScope: TerminalActivityRouterFactScope,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityEventObservation {
        // The caller consumed lifecycleCompleted for this stop: performStop joins
        // pending derived bus posts. A lifecycle fact alone cannot order this separate
        // collector; mark drains its accepted subscription prefix before the relay.
        _ = await mark(paneID)
        append(scope: paneID, fact: .producerStopped(stopScope))
        try await expectNone(
            of: {
                if case .event(let envelope) = $0,
                    case .terminalActivity(.unseenActivitySettled) = envelope.event
                {
                    return true
                }
                return false
            },
            "unseen activity through producer stop", from: opening,
            closedBy: {
                if case .producerStopped(let actualStopScope) = $0 { return actualStopScope == stopScope }
                return false
            },
            fileID: fileID, line: line, function: function
        )
        return .producerStopped(stopScope)
    }
}
