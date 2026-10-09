import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

struct BridgePaneReviewBuildAdmissionTrace {
    let source:
        LocalFactSource<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >
    let recorder:
        FactRecorder<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >

    init() throws {
        let vocabulary = FactVocabulary<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: isReviewBuildAdmissionFactClosing
        )
        let source = LocalFactSource<
            BridgePaneReviewBuildAdmissionScope,
            BridgePaneReviewBuildAdmissionFact
        >(vocabulary: vocabulary)
        self.source = source
        recorder = try source.attach()
    }

    func expectNoAdmission(
        for input: BridgePaneReviewBuildAdmissionInput,
        from opening: OpeningPosition<BridgePaneReviewBuildAdmissionScope>
    ) async -> Bool {
        do {
            try await recorder.expectNone(
                of: { fact in
                    if case .admitted = fact { true } else { false }
                },
                "Review build admission while hidden",
                from: opening,
                closedBy: { $0 == .deferredHidden(input: input) }
            )
            return true
        } catch {
            return false
        }
    }

    func nextAdmittedAttempt() async throws -> UUID {
        let scope = try await recorder.expectNextOperation(
            matching: { if case .attempt = $0 { true } else { false } },
            opening: { if case .admitted = $0 { true } else { false } },
            "Review package build admission"
        )
        guard case .attempt(let attempt) = scope else {
            throw BridgePaneReviewBuildAdmissionTraceError.expectedAttemptScope
        }
        guard
            case .admitted(attempt) = try await recorder.expectNext(
                in: scope,
                where: { $0 == .admitted(attempt: attempt) },
                "admitted Review package build"
            )
        else {
            throw BridgePaneReviewBuildAdmissionTraceError.expectedAdmission
        }
        return attempt
    }

    func nextAttemptOutcome() async throws -> BridgePaneReviewBuildAttemptOutcome {
        let attempt = try await nextAdmittedAttempt()
        return try await attemptOutcome(for: attempt)
    }

    func attemptOutcome(
        for attempt: UUID
    ) async throws -> BridgePaneReviewBuildAttemptOutcome {
        guard
            case .attemptEnded(_, let outcome) = try await recorder.expectNext(
                in: .attempt(attempt),
                where: {
                    if case .attemptEnded(let endedAttempt, _) = $0 { endedAttempt == attempt } else { false }
                },
                "Review package build attempt end"
            )
        else {
            throw BridgePaneReviewBuildAdmissionTraceError.expectedAttemptEnd
        }
        return outcome
    }

    func finish() async throws {
        source.end()
        try await recorder.finish()
    }
}

private func isReviewBuildAdmissionFactClosing(
    scope: BridgePaneReviewBuildAdmissionScope,
    fact: BridgePaneReviewBuildAdmissionFact
) -> Bool {
    switch (scope, fact) {
    case (.hiddenInput(let input), .deferredHidden(let closedInput)):
        input == closedInput
    case (.hiddenInput, .attemptEnded):
        true
    case (.attempt(let scopeAttempt), .attemptEnded(let attempt, _)):
        scopeAttempt == attempt
    default:
        false
    }
}

private enum BridgePaneReviewBuildAdmissionTraceError: Error {
    case expectedAttemptScope
    case expectedAdmission
    case expectedAttemptEnd
}
