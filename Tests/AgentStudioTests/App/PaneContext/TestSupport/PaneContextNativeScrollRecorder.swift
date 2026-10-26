import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

/// Joins the actual scroll producer before a test samples native geometry.
@MainActor
final class PaneContextNativeScrollRecorder {
    enum Scope: Hashable, Sendable {
        case starts
        case operation(UUID)
    }
    enum Fact: Equatable, Sendable {
        case started(PaneContextPopoverScrollOperation)
        case ended(PaneContextPopoverScrollOutcome)
        case producerEnded
        case retired
    }
    let facts = FactRecorder<Scope, Fact>(
        vocabulary: .init(
            describeScope: { "native scroll \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { scope, fact in
                if case .operation = scope { return fact == .producerEnded }
                return false
            }))
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var monitors: [Task<Void, Never>] = []
    private var endedProducers: Set<UUID> = []
    private var retired = false
    private(set) var operations: [PaneContextPopoverScrollOperation] = []
    private(set) var outcomes: [UUID: [PaneContextPopoverScrollOutcome]] = [:]

    func observe(_ event: PaneContextPopoverScrollEvent) {
        switch event {
        case .started(let operation, let task):
            operations.append(operation)
            tasks[operation.id] = task
            facts.append(scope: .starts, fact: .started(operation))
            monitors.append(
                Task {
                    await task.value
                    endedProducers.insert(operation.id)
                    facts.append(scope: .operation(operation.id), fact: .producerEnded)
                })
        case .ended(let operation, let outcome):
            outcomes[operation.id, default: []].append(outcome)
            facts.append(scope: .operation(operation.id), fact: .ended(outcome))
        }
    }

    func completed(requested: PaneContextMessagesTarget) async throws -> PaneContextPopoverScrollOutcome {
        let start = try await facts.expectNext(
            in: .starts, where: { _ in true }, "scroll task start or native view retirement")
        guard case .started(let operation) = start else { throw ScrollFailure.unexpected(start) }
        #expect(operation.requested == requested)
        let task = try #require(tasks[operation.id])
        await task.value
        let terminal = try await facts.expectNext(
            in: .operation(operation.id), where: { _ in true },
            "scroll application, producer ending without a result, or native retirement")
        guard case .ended(let outcome) = terminal else { throw ScrollFailure.unexpected(terminal) }
        let end = try await facts.expectNext(
            in: .operation(operation.id), where: { _ in true }, "scroll producer end or native retirement")
        #expect(end == .producerEnded)
        #expect(outcomes[operation.id] == [outcome], "Each actual scroll operation has exactly one terminal outcome")
        return outcome
    }

    func retire() {
        guard !retired else { return }
        retired = true
        facts.append(scope: .starts, fact: .retired)
        for operation in operations where !endedProducers.contains(operation.id) {
            facts.append(scope: .operation(operation.id), fact: .retired)
        }
    }

    func joinAnnouncedProducers() async {
        let announced = Array(tasks.values)
        for task in announced { await task.value }
    }

    func finish() async throws {
        for task in tasks.values {
            task.cancel()
            await task.value
        }
        for monitor in monitors { await monitor.value }
        facts.receive(.ended)
        try await facts.finish()
    }
}

private enum ScrollFailure: Error { case unexpected(PaneContextNativeScrollRecorder.Fact) }
