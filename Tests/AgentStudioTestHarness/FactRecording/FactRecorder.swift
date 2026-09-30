import Synchronization

extension UnexpectedFact {
    package static func forExpectation(expected: String, actual: String, scope: String, callSite: String) -> Self {
        Self(expected: expected, actual: actual, scope: scope, callSite: callSite)
    }
}

/// One source's append-only fact history and per-scope consuming cursors.
package final class FactRecorder<Scope: Hashable & Sendable, Fact: Sendable>: Sendable {
    private let vocabulary: FactVocabulary<Scope, Fact>
    private let expectationLog: ExpectationLog
    private let state = Mutex(RecorderState<Scope, Fact>())

    package init(vocabulary: FactVocabulary<Scope, Fact>, expectationLog: ExpectationLog = .environment) {
        self.vocabulary = vocabulary
        self.expectationLog = expectationLog
    }

    package func installSourceHandle(_ handle: any FactSourceHandle) {
        state.withLock { state in
            precondition(state.sourceHandle == nil, "A recorder has one source")
            state.sourceHandle = handle
        }
    }

    /// The owner calls this synchronously; it never creates a task.
    package func append(scope: Scope, fact: Fact) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.stopping else { return [] }
            if let terminal = state.sourceTerminal {
                state.violations.append(
                    (
                        scope,
                        FactAfterSourceTerminated(
                            actual: vocabulary.describeFact(fact), terminal: terminal.description,
                            scope: vocabulary.describeScope(scope), callSite: "source emission"
                        )
                    ))
            } else {
                state.nextSequence += 1
                record(scope: scope, fact: fact, sequence: state.nextSequence, in: &state)
            }
            state.revision += 1
            return state.takeWaiters()
        }
        for waiter in waiters { waiter.resume() }
    }

    package func receive(_ event: FactSourceEvent<Scope, Fact>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard !state.finished else { return [] }
            switch event {
            case .fact(let scope, let fact, let sequence):
                if let terminal = state.sourceTerminal {
                    state.violations.append(
                        (
                            scope,
                            FactAfterSourceTerminated(
                                actual: vocabulary.describeFact(fact), terminal: terminal.description,
                                scope: vocabulary.describeScope(scope), callSite: "source emission"
                            )
                        ))
                } else {
                    record(scope: scope, fact: fact, sequence: sequence, in: &state)
                }
            case .ended:
                state.sourceTerminal = .ended
            case .lost(let description):
                if state.lossDescription == nil { state.lossDescription = description }
            case .cancelled:
                state.sourceTerminal = .cancelled
            }
            state.revision += 1
            return state.takeWaiters()
        }
        for waiter in waiters { waiter.resume() }
    }

    private func record(scope: Scope, fact: Fact, sequence: UInt64, in state: inout RecorderState<Scope, Fact>) {
        if state.closedScopes.contains(scope) {
            let actual = vocabulary.describeFact(fact)
            let scopeName = vocabulary.describeScope(scope)
            if vocabulary.isClosing(scope, fact) {
                state.violations.append(
                    (scope, DuplicateClose(actual: actual, scope: scopeName, callSite: "source emission")))
            } else {
                state.violations.append(
                    (scope, FactAfterClose(actual: actual, scope: scopeName, callSite: "source emission")))
            }
        } else if vocabulary.isClosing(scope, fact) {
            state.closedScopes.insert(scope)
        }
        state.history.append(RecordedFact(scope: scope, fact: fact, sequence: sequence))
    }

    package func expectNext(
        in scope: Scope, _ expected: Fact,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws where Fact: Equatable {
        _ = try await expectNext(
            in: scope, where: { $0 == expected }, vocabulary.describeFact(expected),
            fileID: fileID, line: line, function: function
        )
    }

    package func expectNext(
        in scope: Scope, where matches: @Sendable (Fact) -> Bool, _ description: String,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> Fact {
        let callSite = "\(fileID):\(line) \(function)"
        let logID = expectationLog.expecting(
            expectedCase: description, scope: vocabulary.describeScope(scope),
            test: "\(fileID) \(function)", callSite: callSite
        )
        do {
            let expectationID = try beginExpectation(scope, description, callSite)
            defer { endExpectation(scope, expectationID) }
            while true {
                try Task.checkCancellation()
                let observation = state.withLock { state -> Observation<Fact> in
                    if let failure = stickyFailure(state, scope, description, callSite) { return .failure(failure) }
                    let cursor = state.cursors[scope, default: 0]
                    if let index = state.history.indices.first(where: {
                        $0 >= cursor && state.history[$0].scope == scope
                    }) {
                        state.cursors[scope] = index + 1
                        return .fact(state.history[index].fact)
                    }
                    if let terminal = state.sourceTerminal {
                        return .failure(sourceFailure(terminal, scope, description, callSite))
                    }
                    if state.stopping {
                        return .failure(
                            SourceEnded(
                                expected: description, scope: vocabulary.describeScope(scope), callSite: callSite))
                    }
                    return .waiting(state.revision)
                }
                switch observation {
                case .fact(let fact):
                    guard matches(fact) else {
                        throw UnexpectedFact(
                            expected: description, actual: vocabulary.describeFact(fact),
                            scope: vocabulary.describeScope(scope), callSite: callSite)
                    }
                    expectationLog.settled(logID, outcome: .matched)
                    return fact
                case .failure(let failure): throw failure
                case .waiting(let revision): try await waitForChange(after: revision)
                }
            }
        } catch {
            expectationLog.settled(logID, outcome: Self.settlement(for: error))
            throw error
        }
    }

    /// Find the next owner-minted operation without advancing its fact cursor.
    package func expectNextOperation(
        matching scopeMatches: @Sendable (Scope) -> Bool,
        opening matchesOpening: @Sendable (Fact) -> Bool, _ description: String,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws -> Scope {
        let callSite = "\(fileID):\(line) \(function)"
        let discoveryScope = "discover: \(description)"
        let logID = expectationLog.expecting(
            expectedCase: description, scope: discoveryScope,
            test: "\(fileID) \(function)", callSite: callSite
        )
        do {
            let expectationID = try state.withLock { state -> UInt64 in
                guard state.activeDiscovery == nil else {
                    throw ConcurrentExpectation(expected: description, scope: discoveryScope, callSite: callSite)
                }
                state.nextExpectationID += 1
                state.activeDiscovery = state.nextExpectationID
                return state.nextExpectationID
            }
            defer {
                state.withLock { state in
                    if state.activeDiscovery == expectationID { state.activeDiscovery = nil }
                }
            }
            while true {
                try Task.checkCancellation()
                let observation = state.withLock { state -> OperationObservation<Scope> in
                    if let loss = state.lossDescription {
                        return .failure(
                            FactsLost(
                                description: loss, expected: description, scope: discoveryScope, callSite: callSite))
                    }
                    var seenScopes: Set<Scope> = []
                    for entry in state.history where scopeMatches(entry.scope) {
                        guard seenScopes.insert(entry.scope).inserted else { continue }
                        guard !state.discoveredScopes.contains(entry.scope) else { continue }
                        if let failure = stickyFailure(state, entry.scope, description, callSite) {
                            return .failure(failure)
                        }
                        guard matchesOpening(entry.fact) else {
                            return .failure(
                                UnexpectedFact(
                                    expected: description, actual: vocabulary.describeFact(entry.fact),
                                    scope: vocabulary.describeScope(entry.scope), callSite: callSite))
                        }
                        state.discoveredScopes.insert(entry.scope)
                        return .scope(entry.scope)
                    }
                    if let terminal = state.sourceTerminal {
                        switch terminal {
                        case .ended:
                            return .failure(
                                SourceEnded(
                                    expected: description, scope: discoveryScope, callSite: callSite))
                        case .cancelled:
                            return .failure(
                                Cancelled(
                                    expected: description, scope: discoveryScope, callSite: callSite))
                        }
                    }
                    if state.stopping {
                        return .failure(
                            SourceEnded(
                                expected: description, scope: discoveryScope, callSite: callSite))
                    }
                    return .waiting(state.revision)
                }
                switch observation {
                case .scope(let scope):
                    expectationLog.settled(logID, outcome: .matched)
                    return scope
                case .failure(let failure): throw failure
                case .waiting(let revision): try await waitForChange(after: revision)
                }
            }
        } catch {
            expectationLog.settled(logID, outcome: Self.settlement(for: error))
            throw error
        }
    }

    package func mark(_ scope: Scope) async -> OpeningPosition<Scope> {
        let handle = state.withLock { $0.sourceHandle }
        await handle?.settleEnqueued()
        return state.withLock {
            OpeningPosition(recorderIdentity: ObjectIdentifier(self), scope: scope, historyIndex: $0.history.count)
        }
    }

    package func expectNone(
        of forbidden: @Sendable (Fact) -> Bool, _ description: String,
        from opening: OpeningPosition<Scope>, closedBy expectedClose: @Sendable (Fact) -> Bool,
        fileID: String = #fileID, line: Int = #line, function: String = #function
    ) async throws {
        let scope = opening.scope
        let callSite = "\(fileID):\(line) \(function)"
        let logID = expectationLog.expecting(
            expectedCase: "no \(description) until close", scope: vocabulary.describeScope(scope),
            test: "\(fileID) \(function)", callSite: callSite
        )
        do {
            guard opening.recorderIdentity == ObjectIdentifier(self) else {
                throw OpeningPositionMisuse(scope: vocabulary.describeScope(scope), callSite: callSite)
            }
            let expectationID = try beginExpectation(scope, description, callSite)
            defer { endExpectation(scope, expectationID) }
            let firstUnconsumedFact = state.withLock { state -> Fact? in
                let cursor = state.cursors[scope, default: 0]
                guard cursor < opening.historyIndex else { return nil }
                return state.history[cursor..<opening.historyIndex]
                    .first(where: { $0.scope == scope })?.fact
            }
            if let firstUnconsumedFact {
                throw UnconsumedFactsBeforeOpening(
                    firstUnconsumedFact: vocabulary.describeFact(firstUnconsumedFact),
                    scope: vocabulary.describeScope(scope), callSite: callSite
                )
            }
            var nextIndex = opening.historyIndex
            while true {
                try Task.checkCancellation()
                let snapshot = state.withLock { state -> ([RecordedFact<Scope, Fact>], UInt64, (any Error)?) in
                    (
                        Array(state.history.dropFirst(nextIndex)), state.revision,
                        stickyFailure(state, scope, description, callSite)
                    )
                }
                if let failure = snapshot.2 { throw failure }
                for entry in snapshot.0 {
                    nextIndex += 1
                    guard entry.scope == scope else { continue }
                    if forbidden(entry.fact) {
                        throw UnexpectedFact(
                            expected: "no \(description)", actual: vocabulary.describeFact(entry.fact),
                            scope: vocabulary.describeScope(scope), callSite: callSite)
                    }
                    if vocabulary.isClosing(scope, entry.fact) {
                        guard expectedClose(entry.fact) else {
                            throw UnexpectedFact(
                                expected: "closing fact for \(description)",
                                actual: vocabulary.describeFact(entry.fact),
                                scope: vocabulary.describeScope(scope), callSite: callSite)
                        }
                        let failure = state.withLock { state -> (any Error)? in
                            if let failure = stickyFailure(state, scope, description, callSite) { return failure }
                            state.cursors[scope] = max(state.cursors[scope, default: 0], nextIndex)
                            return nil
                        }
                        if let failure { throw failure }
                        expectationLog.settled(logID, outcome: .matched)
                        return
                    }
                }
                let endFailure = state.withLock { state -> (any Error)? in
                    if let failure = stickyFailure(state, scope, description, callSite) { return failure }
                    if let terminal = state.sourceTerminal {
                        return sourceFailure(terminal, scope, description, callSite)
                    }
                    if state.stopping {
                        return SourceEnded(
                            expected: description, scope: vocabulary.describeScope(scope), callSite: callSite)
                    }
                    return nil
                }
                if let endFailure { throw endFailure }
                try await waitForChange(after: snapshot.1)
            }
        } catch {
            expectationLog.settled(logID, outcome: Self.settlement(for: error))
            throw error
        }
    }

    private static func settlement(for error: any Error) -> ExpectationLog.Settlement {
        switch error {
        case is FactsLost: .lost
        case is SourceEnded: .ended
        case is Cancelled, is CancellationError: .cancelled
        default: .unexpected
        }
    }

    package func finish() async throws {
        let (stopTask, waiters) = state.withLock { state -> StopOutcome in
            if let stopTask = state.stopTask { return (stopTask, []) }
            state.stopping = true
            let handle = state.sourceHandle
            let stopTask = Task { if let handle { await handle.stop() } }
            state.stopTask = stopTask
            state.revision += 1
            return (stopTask, state.takeWaiters())
        }
        for waiter in waiters { waiter.resume() }
        await stopTask.value
        let failure = state.withLock { state -> (any Error)? in
            state.finished = true
            state.sourceHandle = nil
            if let loss = state.lossDescription {
                return FactsLost(description: loss, expected: "finish", scope: "all scopes", callSite: "finish")
            }
            return state.violations.first?.1
        }
        if let failure { throw failure }
    }

    private func beginExpectation(_ scope: Scope, _ expected: String, _ callSite: String) throws -> UInt64 {
        try state.withLock { state in
            guard state.activeExpectations[scope] == nil else {
                throw ConcurrentExpectation(
                    expected: expected, scope: vocabulary.describeScope(scope), callSite: callSite)
            }
            state.nextExpectationID += 1
            state.activeExpectations[scope] = state.nextExpectationID
            return state.nextExpectationID
        }
    }

    private func endExpectation(_ scope: Scope, _ id: UInt64) {
        state.withLock { state in
            if state.activeExpectations[scope] == id { state.activeExpectations[scope] = nil }
        }
    }

    private func stickyFailure(
        _ state: RecorderState<Scope, Fact>, _ scope: Scope, _ expected: String, _ callSite: String
    ) -> (any Error)? {
        if let loss = state.lossDescription {
            return FactsLost(
                description: loss, expected: expected, scope: vocabulary.describeScope(scope), callSite: callSite)
        }
        return state.violations.first(where: { $0.0 == scope })?.1
    }

    private func sourceFailure(_ terminal: SourceTerminal, _ scope: Scope, _ expected: String, _ callSite: String)
        -> any Error
    {
        switch terminal {
        case .ended: SourceEnded(expected: expected, scope: vocabulary.describeScope(scope), callSite: callSite)
        case .cancelled: Cancelled(expected: expected, scope: vocabulary.describeScope(scope), callSite: callSite)
        }
    }

    private func waitForChange(after revision: UInt64) async throws {
        let waiterID = state.withLock { state -> UInt64 in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let shouldResume = state.withLock { state -> Bool in
                    if state.revision != revision || Task.isCancelled { return true }
                    state.waiters[waiterID] = continuation
                    return false
                }
                if shouldResume {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

private enum Observation<Fact: Sendable>: Sendable {
    case fact(Fact)
    case waiting(UInt64)
    case failure(any Error)
}

private enum OperationObservation<Scope: Sendable>: Sendable {
    case scope(Scope)
    case waiting(UInt64)
    case failure(any Error)
}

private typealias StopOutcome = (Task<Void, Never>, [CheckedContinuation<Void, any Error>])

private struct RecordedFact<Scope: Hashable & Sendable, Fact: Sendable>: Sendable {
    let scope: Scope
    let fact: Fact
    let sequence: UInt64
}

private enum SourceTerminal: Sendable {
    case ended
    case cancelled

    var description: String {
        switch self {
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }
}

private struct RecorderState<Scope: Hashable & Sendable, Fact: Sendable>: Sendable {
    var history: [RecordedFact<Scope, Fact>] = []
    var cursors: [Scope: Int] = [:]
    var closedScopes: Set<Scope> = []
    var violations: [(Scope, any Error)] = []
    var lossDescription: String?
    var sourceTerminal: SourceTerminal?
    var activeExpectations: [Scope: UInt64] = [:]
    var activeDiscovery: UInt64?
    var discoveredScopes: Set<Scope> = []
    var nextExpectationID: UInt64 = 0
    var nextWaiterID: UInt64 = 0
    var nextSequence: UInt64 = 0
    var revision: UInt64 = 0
    var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    var sourceHandle: (any FactSourceHandle)?
    var stopTask: Task<Void, Never>?
    var stopping = false
    var finished = false

    mutating func takeWaiters() -> [CheckedContinuation<Void, any Error>] {
        let collected = Array(waiters.values)
        waiters.removeAll()
        return collected
    }
}
