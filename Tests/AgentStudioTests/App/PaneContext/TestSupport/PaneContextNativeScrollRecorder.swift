import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

/// D44 gate evidence is the exact proxy request. Physical clip placement belongs to the J9 journey.
@MainActor
final class PaneContextNativeScrollRecorder {
    enum Scope: Hashable, Sendable {
        case starts
        case operation(UUID)
    }
    enum Fact: Equatable, Sendable {
        case started(PaneContextPopoverScrollOperation)
        case requested(PaneContextPopoverScrollRequest)
        case ended(PaneContextPopoverScrollOutcome)
        case producerEnded
        case retired
    }
    let facts = FactRecorder<Scope, Fact>(
        vocabulary: .init(
            describeScope: { "scroll proxy request \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { scope, fact in
                if case .operation = scope { return fact == .producerEnded || fact == .retired }
                return fact == .retired
            }))
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var monitors: [Task<Void, Never>] = []
    private var closedOperations: Set<UUID> = []
    private var retired = false
    private(set) var operations: [PaneContextPopoverScrollOperation] = []
    private(set) var outcomes: [UUID: [PaneContextPopoverScrollOutcome]] = [:]

    func observe(_ event: PaneContextPopoverScrollEvent) {
        switch event {
        case .started(let operation, let task):
            operations.append(operation)
            tasks[operation.id] = task
            if !retired { facts.append(scope: .starts, fact: .started(operation)) }
            monitors.append(
                Task {
                    await task.value
                    close(operation.id, with: .producerEnded)
                })
            if retired {
                task.cancel()
                close(operation.id, with: .retired)
            }
        case .requested(let operation, let target):
            guard !retired else { return }
            facts.append(scope: .operation(operation.id), fact: .requested(target))
        case .ended(let operation, let outcome):
            guard !retired else { return }
            outcomes[operation.id, default: []].append(outcome)
            facts.append(scope: .operation(operation.id), fact: .ended(outcome))
        }
    }

    func completed(requested: PaneContextMessagesTarget, handingToProxy expected: PaneContextPopoverScrollRequest)
        async throws -> PaneContextPopoverScrollOutcome
    {
        guard !retired else { throw ScrollFailure.unexpected(.retired) }
        let start = try await facts.expectNext(
            in: .starts, where: { _ in true }, "scroll task start or view retirement")
        guard case .started(let operation) = start else { throw ScrollFailure.unexpected(start) }
        try #require(operation.requested == requested)
        var requests: [PaneContextPopoverScrollRequest] = []
        var outcome: PaneContextPopoverScrollOutcome?
        while true {
            let fact = try await facts.expectNext(
                in: .operation(operation.id), where: { _ in true },
                "proxy request, sender result, producer end or retirement")
            switch fact {
            case .requested(let target): requests.append(target)
            case .ended(let value): outcome = value
            case .producerEnded:
                guard requests == [expected] else {
                    throw ScrollFailure.wrongProxyRequests(expected: expected, actual: requests)
                }
                let result = try #require(outcome, "The scroll producer ended without an outcome")
                #expect(outcomes[operation.id] == [result], "Each scroll producer emits exactly one terminal outcome")
                return result
            case .retired: throw ScrollFailure.unexpected(fact)
            case .started: throw ScrollFailure.unexpected(fact)
            }
        }
    }

    func retire() {
        guard !retired else { return }
        retired = true
        facts.append(scope: .starts, fact: .retired)
        for operation in operations { close(operation.id, with: .retired) }
    }

    private func close(_ operation: UUID, with fact: Fact) {
        guard closedOperations.insert(operation).inserted else { return }
        facts.append(scope: .operation(operation), fact: fact)
    }

    func finish() async throws {
        retire()
        for task in tasks.values {
            task.cancel()
            await task.value
        }
        for monitor in monitors { await monitor.value }
        facts.receive(.ended)
        try await facts.finish()
    }
}

private enum ScrollFailure: Error {
    case unexpected(PaneContextNativeScrollRecorder.Fact)
    case wrongProxyRequests(expected: PaneContextPopoverScrollRequest, actual: [PaneContextPopoverScrollRequest])
}
