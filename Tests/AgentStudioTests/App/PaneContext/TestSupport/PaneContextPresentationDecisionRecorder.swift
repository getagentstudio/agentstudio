import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

/// D44 gate evidence is the owner's state decision. Physical hiding belongs to the J9 journey.
@MainActor
final class PaneContextPresentationDecisionRecorder {
    enum Fact: Equatable, Sendable {
        case started(UUID)
        case decided(isPresented: Bool)
        case producerEnded(cancelled: Bool)
        case retired
    }
    private let facts = FactRecorder<UUID, Fact>(
        vocabulary: .init(
            describeScope: { "presentation decision for press \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                switch fact {
                case .producerEnded, .retired: true
                default: false
                }
            }))
    private var openings: [UUID: PaneContextPopoverOpeningReadback] = [:]
    private var unattributedOpenings: [ObjectIdentifier] = []
    private var activePress: UUID?
    private var presses: Set<UUID> = []
    private var asynchronousPresses: Set<UUID> = []
    private var closedPresses: Set<UUID> = []
    private var operationPresses: [UUID: UUID] = [:]
    private var producers: [Task<Void, Never>] = []
    private var monitors: [Task<Void, Never>] = []
    private var unattributedOperations: [UUID] = []
    private var retired = false

    func beginPress() throws -> UUID {
        guard !retired else { throw DecisionFailure.retired }
        let press = UUIDv7.generate()
        activePress = press
        presses.insert(press)
        return press
    }

    func pressReturned(_ press: UUID) {
        activePress = nil
        if !asynchronousPresses.contains(press) {
            close(press, with: .producerEnded(cancelled: false))
        }
    }

    func observe(_ event: PaneContextPopoverPresentationEvent) {
        switch event {
        case .opened(let readback):
            guard let press = activePress else {
                unattributedOpenings.append(readback.ownerIdentity)
                return
            }
            openings[press] = readback
        case .started(let operation, let producer):
            guard let press = activePress else {
                unattributedOperations.append(operation)
                return
            }
            operationPresses[operation] = press
            facts.append(scope: press, fact: .started(operation))
            switch producer {
            case .synchronous: break
            case .task(let task):
                asynchronousPresses.insert(press)
                producers.append(task)
                monitors.append(
                    Task {
                        await task.value
                        close(press, with: .producerEnded(cancelled: task.isCancelled))
                    })
            }
        case .decided(let operation, let isPresented):
            guard !retired else { return }
            guard let press = operationPresses[operation] else {
                unattributedOperations.append(operation)
                return
            }
            facts.append(scope: press, fact: .decided(isPresented: isPresented))
        }
    }

    func opening(for press: UUID) throws -> PaneContextPopoverOpeningReadback {
        guard let opening = openings[press] else { throw DecisionFailure.endedWithoutOpening }
        return opening
    }

    func decision(for press: UUID) async throws -> Bool {
        guard !retired else { throw DecisionFailure.retired }
        while true {
            let fact = try await facts.expectNext(
                in: press, where: { _ in true }, "host presentation decision, action ending/refusal, or retirement")
            switch fact {
            case .started: continue
            case .decided(let isPresented): return isPresented
            case .producerEnded(let cancelled): throw DecisionFailure.endedWithoutDecision(cancelled: cancelled)
            case .retired: throw DecisionFailure.retired
            }
        }
    }

    func retire() {
        guard !retired else { return }
        retired = true
        for press in presses { close(press, with: .retired) }
    }

    private func close(_ press: UUID, with fact: Fact) {
        guard closedPresses.insert(press).inserted else { return }
        facts.append(scope: press, fact: fact)
    }

    func finish() async throws {
        retire()
        for producer in producers {
            producer.cancel()
            await producer.value
        }
        for monitor in monitors { await monitor.value }
        #expect(unattributedOpenings.isEmpty, "Every opening must originate at its native press")
        #expect(unattributedOperations.isEmpty, "Every presentation operation must originate at its correlated press")
        facts.receive(.ended)
        try await facts.finish()
    }
}

private enum DecisionFailure: Error {
    case endedWithoutOpening
    case endedWithoutDecision(cancelled: Bool)
    case retired
}
