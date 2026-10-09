import AgentStudioCore
import AgentStudioTestHarness
import Foundation

package struct RecordedTerminalActivitySettle: Sendable {
    package let envelope: PaneEnvelope
    package let activity: TerminalSettledActivity
}

/// The stop marker relays an awaited producer shutdown after accepted bus work settles.
/// It is test-local observation vocabulary, not a new runtime envelope.
package enum TerminalActivityEventObservation: Sendable {
    case event(PaneEnvelope)
    case producerStopped
}

/// Core-owned runtime envelopes shared by Terminal and executable integration tests.
package enum TerminalActivityEventFactSource {
    package static func attach(
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
                    case .producerStopped: "terminal producer stopped"
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
    package func expectNextPaneObservation(
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

    package func expectNextUnseenActivity(
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

    /// Call only after the real producer's stop has returned; settle its accepted
    /// bus prefix before relaying that causal close into this observation stream.
    package func expectNoUnseenActivityThroughStoppedProducer(
        paneID: UUID, from opening: OpeningPosition<UUID>,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityEventObservation {
        _ = await mark(paneID)
        append(scope: paneID, fact: .producerStopped)
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
                if case .producerStopped = $0 { return true }
                return false
            },
            fileID: fileID, line: line, function: function
        )
        return .producerStopped
    }
}
