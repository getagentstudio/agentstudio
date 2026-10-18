import Foundation

@testable import AgentStudioBridge

struct BridgeProductWebKitBlockedComparison: Sendable {
    let count: Int
    let attemptID: UUID
}

enum BridgeProductWebKitComparisonWaitFailure: Error, Equatable {
    case attemptEnded(UUID, BridgePaneReviewBuildAttemptOutcome)
    case retired(String)
    case comparisonWithoutAdmission
    case sourceEnded
}

/// Merges the producer's existing terminal facts with comparison arrival and page/pane retirement.
struct BridgeProductWebKitReviewComparisonEvents: Sendable {
    private enum Event: Sendable {
        case armed(Int)
        case admitted(UUID)
        case ended(UUID, BridgePaneReviewBuildAttemptOutcome)
        case comparison(Int)
        case retired(String)
    }

    private enum WaitPhase {
        case beforeArm
        case awaitingAdmission
        case awaitingComparison(UUID)
    }

    private let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    func arm(_ count: Int) { continuation.yield(.armed(count)) }
    func arrived(_ count: Int) { continuation.yield(.comparison(count)) }
    func retire(_ reason: String) { continuation.yield(.retired(reason)) }
    func finish() { continuation.finish() }

    func record(_ scope: BridgePaneReviewBuildAdmissionScope, _ fact: BridgePaneReviewBuildAdmissionFact) {
        guard case .attempt(let scopedAttempt) = scope else { return }
        switch fact {
        case .admitted(let attempt) where attempt == scopedAttempt:
            continuation.yield(.admitted(attempt))
        case .attemptEnded(let attempt, let outcome) where attempt == scopedAttempt:
            continuation.yield(.ended(attempt, outcome))
        default:
            break  // Other admission facts do not start or end a producing attempt.
        }
    }

    func waitForBlockedComparisonCount(_ count: Int) async throws -> BridgeProductWebKitBlockedComparison {
        var phase = WaitPhase.beforeArm
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .armed(let armedCount):
                if armedCount == count { phase = .awaitingAdmission }
            case .admitted(let attempt):
                if case .awaitingAdmission = phase { phase = .awaitingComparison(attempt) }
            case .ended(let attempt, let outcome):
                if case .awaitingComparison(attempt) = phase {
                    throw BridgeProductWebKitComparisonWaitFailure.attemptEnded(attempt, outcome)
                }
            case .comparison(let arrivedCount):
                guard arrivedCount == count else { continue }
                guard case .awaitingComparison(let attempt) = phase else {
                    throw BridgeProductWebKitComparisonWaitFailure.comparisonWithoutAdmission
                }
                return .init(count: arrivedCount, attemptID: attempt)
            case .retired(let reason):
                throw BridgeProductWebKitComparisonWaitFailure.retired(reason)
            }
        }
        try Task.checkCancellation()
        throw BridgeProductWebKitComparisonWaitFailure.sourceEnded
    }
}
