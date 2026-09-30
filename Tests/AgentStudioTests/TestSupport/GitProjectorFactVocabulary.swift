import AgentStudioCore
import AgentStudioTestHarness
import Foundation

extension FactVocabulary<GitProjectorScope, GitProjectorFact> {
    package static let gitProjector = FactVocabulary(
        describeScope: { String(describing: $0) },
        describeFact: { String(describing: $0) },
        isClosing: { scope, fact in
            switch (scope, fact) {
            case (.intake(_, _, _), .changesetAccepted),
                (.intake(_, _, _), .changesetCoalesced(_)),
                (.intake(_, _, _), .changesetDropped(_)),
                (.refresh(_, _), .refreshClosed(_)),
                (.deadline(_, _, _), .deadlineDisposition(_)),
                (.capacity(_, _), .capacityRetryClosed(_)),
                (.backoff(_, _), .backoffClosed),
                (.quarantine(_, _), .quarantineClosed),
                (.lifetime(_), .shutdownCompleted):
                true
            default:
                false
            }
        }
    )
}

extension FactRecorder where Scope == GitProjectorScope, Fact == GitProjectorFact {
    package func expectNextRefreshStarted(
        worktreeId: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> UInt64 {
        let scopeMatches: @Sendable (GitProjectorScope) -> Bool = {
            if case .refresh(let scopedWorktreeId, _) = $0 { return scopedWorktreeId == worktreeId }
            return false
        }
        let openingMatches: @Sendable (GitProjectorFact) -> Bool = { $0 == .refreshAdmitted }
        let scope = try await expectNextOperation(
            matching: scopeMatches, opening: openingMatches, "refresh admitted for \(worktreeId)",
            fileID: fileID, line: line, function: function
        )
        guard case .refresh(_, let requestSequence) = scope else {
            throw UnexpectedFact.forExpectation(
                expected: "refresh scope", actual: String(describing: scope),
                scope: String(describing: scope), callSite: "\(fileID):\(line) \(function)")
        }
        try await expectRefreshStarted(
            worktreeId: worktreeId, requestSequence: requestSequence,
            fileID: fileID, line: line, function: function
        )
        return requestSequence
    }

    package func expectRefreshStarted(
        worktreeId: UUID, requestSequence: UInt64,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws {
        let scope = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: requestSequence)
        try await expectNext(in: scope, .refreshAdmitted, fileID: fileID, line: line, function: function)
        try await expectNext(in: scope, .refreshStarted, fileID: fileID, line: line, function: function)
    }

    package func expectRefreshClosed(
        worktreeId: UUID,
        requestSequence: UInt64,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> GitProjectorRefreshOutcome {
        let scope = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: requestSequence)
        while true {
            let fact = try await expectNext(
                in: scope, where: { _ in true }, "refresh closed",
                fileID: fileID, line: line, function: function
            )
            switch fact {
            case .refreshAdmitted, .refreshStarted:
                continue
            case .refreshClosed(let outcome):
                return outcome
            default:
                throw UnexpectedFact.forExpectation(
                    expected: "refresh fact", actual: String(describing: fact),
                    scope: String(describing: scope), callSite: "\(fileID):\(line) \(function)")
            }
        }
    }

    /// Consume earlier input facts in this lifetime and stop at the requested envelope.
    /// Each iteration awaits an emitted fact; no scheduler turn or elapsed time decides the verdict.
    package func expectHandledEnvelope(
        seq expectedSequence: UInt64,
        lifetime: UInt64 = 1,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> GitProjectorEnvelopeDisposition {
        while true {
            let fact = try await expectNext(
                in: .lifetime(lifetime), where: { _ in true }, "envelope handled through sequence \(expectedSequence)",
                fileID: fileID, line: line, function: function
            )
            guard case .envelopeHandled(let sequence, let disposition) = fact else {
                throw UnexpectedFact.forExpectation(
                    expected: "envelope handled through sequence \(expectedSequence)",
                    actual: String(describing: fact),
                    scope: String(describing: GitProjectorScope.lifetime(lifetime)),
                    callSite: "\(fileID):\(line) \(function)")
            }
            if sequence == expectedSequence { return disposition }
            if sequence > expectedSequence {
                throw UnexpectedProjectorEnvelopeSequence(expected: expectedSequence, actual: sequence)
            }
        }
    }

    package func expectShutdownCompleted(
        lifetime: UInt64 = 1,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> UInt64 {
        var droppedEnvelopes: UInt64 = 0
        while true {
            let fact = try await expectNext(
                in: .lifetime(lifetime), where: { _ in true }, "shutdown completed",
                fileID: fileID, line: line, function: function
            )
            switch fact {
            case .envelopesDropped(let count):
                droppedEnvelopes &+= count
            case .envelopeHandled:
                continue
            case .shutdownCompleted:
                try await finish()
                return droppedEnvelopes
            default:
                throw UnexpectedFact.forExpectation(
                    expected: "lifetime fact", actual: String(describing: fact),
                    scope: String(describing: GitProjectorScope.lifetime(lifetime)),
                    callSite: "\(fileID):\(line) \(function)")
            }
        }
    }

    package func expectNoDroppedEnvelopes(
        from opening: OpeningPosition<GitProjectorScope>,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws {
        try await expectNone(
            of: {
                if case .envelopesDropped = $0 { return true }
                return false
            },
            "dropped projector envelopes",
            from: opening,
            closedBy: { $0 == .shutdownCompleted },
            fileID: fileID, line: line, function: function
        )
        try await finish()
    }
}

private struct UnexpectedProjectorEnvelopeSequence: Error {
    let expected: UInt64
    let actual: UInt64
}

/// Adapts the projector's fact sink to the local recorder.
package final class GitProjectorFactSource: Sendable {
    package init() {}

    private let localSource = LocalFactSource(
        vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)

    package var sink: GitProjectorFactSink {
        localSource.sink
    }

    package func attach() throws -> FactRecorder<GitProjectorScope, GitProjectorFact> {
        try localSource.attach()
    }

    package func expectNextRefreshClosed(
        facts: FactRecorder<GitProjectorScope, GitProjectorFact>,
        worktreeId: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> GitProjectorRefreshOutcome {
        let scopeMatches: @Sendable (GitProjectorScope) -> Bool = {
            if case .refresh(let scopedWorktreeId, _) = $0 { return scopedWorktreeId == worktreeId }
            return false
        }
        let openingMatches: @Sendable (GitProjectorFact) -> Bool = { $0 == .refreshAdmitted }
        let scope = try await facts.expectNextOperation(
            matching: scopeMatches, opening: openingMatches, "refresh admitted for \(worktreeId)",
            fileID: fileID, line: line, function: function
        )
        guard case .refresh(_, let requestSequence) = scope else {
            throw UnexpectedFact.forExpectation(
                expected: "refresh scope", actual: String(describing: scope),
                scope: String(describing: scope), callSite: "\(fileID):\(line) \(function)")
        }
        return try await facts.expectRefreshClosed(
            worktreeId: worktreeId, requestSequence: requestSequence,
            fileID: fileID, line: line, function: function
        )
    }

    package func expectDeadlineRegistered(
        facts: FactRecorder<GitProjectorScope, GitProjectorFact>,
        worktreeId: UUID,
        kind: GitProjectorDeadlineKind,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> GitProjectorScope {
        let description = "\(kind) deadline registered for \(worktreeId)"
        let scopeMatches: @Sendable (GitProjectorScope) -> Bool = {
            if case .deadline(let scopedWorktreeId, let scopedKind, _) = $0 {
                return scopedWorktreeId == worktreeId && scopedKind == kind
            }
            return false
        }
        let openingMatches: @Sendable (GitProjectorFact) -> Bool = { $0 == .deadlineRegistered(kind) }
        let scope = try await facts.expectNextOperation(
            matching: scopeMatches, opening: openingMatches, description,
            fileID: fileID, line: line, function: function
        )
        try await facts.expectNext(
            in: scope, .deadlineRegistered(kind), fileID: fileID, line: line, function: function
        )
        return scope
    }

    package func expectDeadlineRegistered(
        facts: FactRecorder<GitProjectorScope, GitProjectorFact>,
        kind: GitProjectorDeadlineKind,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> GitProjectorScope {
        let scopeMatches: @Sendable (GitProjectorScope) -> Bool = {
            if case .deadline(_, let scopedKind, _) = $0 { return scopedKind == kind }
            return false
        }
        let openingMatches: @Sendable (GitProjectorFact) -> Bool = { $0 == .deadlineRegistered(kind) }
        let scope = try await facts.expectNextOperation(
            matching: scopeMatches, opening: openingMatches, "\(kind) deadline registered",
            fileID: fileID, line: line, function: function
        )
        try await facts.expectNext(
            in: scope, .deadlineRegistered(kind), fileID: fileID, line: line, function: function
        )
        return scope
    }
}
