import AgentStudioCore
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation

@testable import AgentStudioTerminal

struct RegisteredTerminalActivityDeadline: Sendable {
    let scope: TerminalActivityDeadlineScope
    let deadline: Duration
}

/// Reuses the projector's existing scoped registration and disposition sink.
struct TerminalActivityDeadlineFacts: Sendable {
    let clock: TestPushClock
    let origin: TestPushClock.Instant
    let facts: FactRecorder<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>
    private let source: LocalFactSource<TerminalActivityDeadlineScope, TerminalActivityProjectorFact>

    init(clock: TestPushClock) throws {
        self.clock = clock
        origin = clock.now
        source = LocalFactSource(
            vocabulary: FactVocabulary(
                describeScope: { String(describing: $0) },
                describeFact: { String(describing: $0) },
                isClosing: { _, fact in
                    if case .deadlineDisposition = fact { return true }
                    return false
                }
            )
        )
        facts = try source.attach()
    }

    var sink: TerminalActivityProjectorFactSink { source.sink }

    func expectNextRegistration(
        paneID: UUID, kind: TerminalActivityDeadlineKind = .unseen,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> RegisteredTerminalActivityDeadline {
        let scope = try await facts.expectNextOperation(
            matching: { $0.paneID == paneID && $0.kind == kind },
            opening: {
                if case .deadlineRegistered(let actualKind, _) = $0 { return actualKind == kind }
                return false
            },
            "\(kind) deadline registered for \(paneID)",
            fileID: fileID, line: line, function: function
        )
        let registration = try await facts.expectNext(
            in: scope,
            where: {
                if case .deadlineRegistered(let actualKind, _) = $0 { return actualKind == kind }
                return false
            },
            "absolute \(kind) deadline registration",
            fileID: fileID, line: line, function: function
        )
        guard case .deadlineRegistered(_, let deadline) = registration else {
            throw UnexpectedFact.forExpectation(
                expected: "deadline registration", actual: String(describing: registration),
                scope: String(describing: scope), callSite: "\(fileID):\(line) \(function)")
        }
        return RegisteredTerminalActivityDeadline(scope: scope, deadline: deadline)
    }

    func fire(
        _ registration: RegisteredTerminalActivityDeadline,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityProjectorFact {
        clock.advance(to: origin.advanced(by: registration.deadline))
        return try await expectDisposition(
            for: registration, .fired, fileID: fileID, line: line, function: function)
    }

    func expectDisposition(
        for registration: RegisteredTerminalActivityDeadline, _ disposition: TerminalActivityDeadlineDisposition,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityProjectorFact {
        try await facts.expectNext(
            in: registration.scope,
            where: { $0 == .deadlineDisposition(registration.scope.kind, disposition) },
            "\(registration.scope.kind) deadline \(disposition)",
            fileID: fileID, line: line, function: function
        )
    }

    func finish() async throws { try await facts.finish() }
}

final class TerminalActivityRouterFactSource: Sendable {
    private let source = LocalFactSource(
        vocabulary: FactVocabulary<TerminalActivityRouterFactScope, TerminalActivityRouterFact>(
            describeScope: { String(describing: $0) },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                switch fact {
                case .runtimeEnvelopeHandled, .lifecycleCompleted: true
                case .lifecycleEnqueued: false
                }
            }
        )
    )

    var sink: TerminalActivityRouterFactSink { source.sink }

    func attach() throws -> FactRecorder<TerminalActivityRouterFactScope, TerminalActivityRouterFact> {
        try source.attach()
    }
}

extension FactRecorder where Scope == TerminalActivityRouterFactScope, Fact == TerminalActivityRouterFact {
    @MainActor
    func startRouter(
        _ router: TerminalActivityRouter,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityRouterFactScope {
        await router.start()
        let scope = try await expectNextLifecycleEnqueued(.start, fileID: fileID, line: line, function: function)
        _ = try await expectLifecycleCompleted(in: scope, fileID: fileID, line: line, function: function)
        return scope
    }

    @MainActor
    func stopRouter(
        _ router: TerminalActivityRouter,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityRouterFactScope {
        await router.stop()
        let scope = try await expectNextLifecycleEnqueued(.stop, fileID: fileID, line: line, function: function)
        _ = try await expectLifecycleCompleted(in: scope, fileID: fileID, line: line, function: function)
        return scope
    }

    func expectRuntimeEnvelopeHandled(
        paneID: UUID, eventID: UUID,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityRouterFact {
        try await expectNext(
            in: .runtimeEnvelope(paneID: paneID, eventID: eventID), where: { $0 == .runtimeEnvelopeHandled },
            "terminal runtime envelope handled",
            fileID: fileID, line: line, function: function
        )
    }

    func expectNextLifecycleEnqueued(
        _ kind: TerminalActivityRouterLifecycleKind,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityRouterFactScope {
        let scope = try await expectNextOperation(
            matching: {
                if case .lifecycle = $0 { return true }
                return false
            },
            opening: { $0 == .lifecycleEnqueued(kind) },
            "terminal router lifecycle \(kind) enqueued",
            fileID: fileID, line: line, function: function
        )
        try await expectNext(in: scope, .lifecycleEnqueued(kind), fileID: fileID, line: line, function: function)
        return scope
    }

    func expectLifecycleCompleted(
        in scope: TerminalActivityRouterFactScope,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> TerminalActivityRouterFact {
        try await expectNext(
            in: scope, where: { $0 == .lifecycleCompleted }, "terminal router lifecycle completed",
            fileID: fileID, line: line, function: function
        )
    }
}
