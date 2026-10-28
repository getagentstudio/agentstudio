import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

/// Correlates real owner outcomes with the exact row's native AX application.
final class PaneContextPreparedMessageLeafRecorder: Sendable {
    struct Target: Hashable, Sendable {
        let publication: UUID
        let producer: PaneContextPopoverProducer
        let request: PaneContextPopoverRequestIdentity
        let row: MessageRowModel.Key

        init(_ publication: PaneContextPopoverPublication, row: MessageRowModel.Key) {
            self.publication = publication.id
            producer = publication.producer
            request = publication.request
            self.row = row
        }
    }
    enum Outcome: Sendable {
        case applied(PaneContextMessageTextApplication.Value)
        case updateEndedWithoutApplication
        case superseded
        case retired
        case ownerFailed
    }
    private enum Event: Sendable {
        case owner(PaneContextPopoverOwnerScope, PaneContextPopoverOwnerFact)
        case presentation(PaneContextPopoverApplicationEvent)
        case row(PaneContextPopoverMessageApplicationEvent)
    }
    private struct Waiting {
        let facts: FactRecorder<Target, Outcome>
        var begun = false
        var closed = false
    }
    private struct State {
        var events: [Event] = []
        var waiting: [Target: Waiting] = [:]
    }
    private let state = Mutex(State())

    func observeOwner(_ scope: PaneContextPopoverOwnerScope, _ fact: PaneContextPopoverOwnerFact) {
        receive(.owner(scope, fact))
    }
    func observePresentation(_ event: PaneContextPopoverApplicationEvent) { receive(.presentation(event)) }
    func observeRow(_ event: PaneContextPopoverMessageApplicationEvent) { receive(.row(event)) }

    func applied(to target: Target) -> PaneContextMessageTextApplication.Value? {
        state.withLock { state in
            for event in state.events.reversed() {
                guard case .row(let event) = event, matches(event.publication, target),
                    case .applied(let value) = event.event, value.row.key == target.row,
                    value.native.key.producerId == target.producer.id, value.native.key.valueId == target.publication
                else { continue }
                return value
            }
            return nil
        }
    }

    func requireCurrent(_ target: Target) throws {
        try requireCurrent(key: target.request.key, opening: target.request.openingEpoch, producer: target.producer)
    }
    func requireCurrent(_ publication: PaneContextPopoverPublication) throws {
        try requireCurrent(
            key: publication.request.key, opening: publication.request.openingEpoch, producer: publication.producer)
    }
    private func requireCurrent(
        key expectedKey: PaneContextPopoverConsumerKey, opening expectedOpening: UInt64,
        producer expectedProducer: PaneContextPopoverProducer
    ) throws {
        let terminal: Outcome? = state.withLock { state in
            for event in state.events.reversed() {
                switch event {
                case .owner(.consumer(let key, let opening), .retired)
                where key == expectedKey && opening == expectedOpening:
                    return .retired
                case .owner(.execution(let key, let id), let fact)
                where key == expectedKey && expectedProducer == .execution(id):
                    switch fact {
                    case .readFailed, .finished(.failed): return .ownerFailed
                    case .finished(.cancelled): return .retired
                    case .finished(.superseded): return .superseded
                    default: break
                    }
                case .owner(.input(let id), let fact) where expectedProducer == .input(id):
                    switch fact {
                    case .superseded: return .superseded
                    case .cancelled: return .retired
                    default: break
                    }
                default: break
                }
            }
            return nil
        }
        if let terminal { throw Failure.nativeOutcome(terminal) }
    }

    /// D56 fallback: the native-never-began case has only the unchanged runner hang bound.
    func wait(for target: Target, expectedLabel: String, age: String, isRead: Bool) async throws
        -> PaneContextMessageTextApplication.Value
    {
        try requireCurrent(target)
        let facts = state.withLock { state in
            let facts = FactRecorder<Target, Outcome>(
                vocabulary: .init(
                    describeScope: { String(describing: $0) }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var waiting = Waiting(facts: facts)
            for event in state.events { apply(event, to: target, waiting: &waiting) }
            state.waiting[target] = waiting
            return facts
        }
        do {
            let outcome = try await facts.expectNext(
                in: target, where: { _ in true },
                "native message leaf key=\(target) age=\(age) read=\(isRead); applied/superseded/retired/owner-failed")
            _ = state.withLock { $0.waiting.removeValue(forKey: target) }
            facts.receive(.ended)
            try await facts.finish()
            guard case .applied(let value) = outcome else { throw Failure.nativeOutcome(outcome) }
            try requireCurrent(target)
            try #require(value.native.label == expectedLabel, "Native AX leaf applied a different dated label")
            try #require(
                value.row.age.text == age && value.row.isRead == isRead,
                "Exact native row applied a different age/read value: \(value)")
            return value
        } catch {
            _ = state.withLock { $0.waiting.removeValue(forKey: target) }
            facts.receive(.ended)
            try? await facts.finish()
            throw error
        }
    }

    private func receive(_ event: Event) {
        state.withLock { state in
            state.events.append(event)
            for target in Array(state.waiting.keys) {
                guard var waiting = state.waiting[target] else { continue }
                apply(event, to: target, waiting: &waiting)
                state.waiting[target] = waiting
            }
        }
    }
    private func apply(_ event: Event, to target: Target, waiting: inout Waiting) {
        guard !waiting.closed else { return }
        let outcome: Outcome?
        switch event {
        case .owner(let scope, let fact) where scope == target.producer.scope(for: target.request.key):
            switch fact {
            case .readFailed, .finished(.failed): outcome = .ownerFailed
            case .finished(.cancelled), .cancelled: outcome = .retired
            case .finished(.superseded), .superseded: outcome = .superseded
            case .finished(.published), .finished(.equal), .inputFinished:
                waiting.begun = true
                outcome = nil
            default: outcome = nil
            }
        case .owner(.consumer(let key, let opening), .retired)
        where key == target.request.key && opening == target.request.openingEpoch:
            outcome = .retired
        case .presentation(.prepared(let value)):
            if matches(value.publication, target) {
                waiting.begun = true
                outcome = nil
            } else if waiting.begun && sameOpening(value.publication, target) {
                outcome = .superseded
            } else {
                outcome = nil
            }
        case .row(let event) where matches(event.publication, target):
            switch event.event {
            case .applied(let value)
            where value.row.key == target.row
                && value.native.key.producerId == target.producer.id && value.native.key.valueId == target.publication:
                outcome = .applied(value)
            case .retired(let value) where value.row.key == target.row: outcome = .retired
            case .updateEnded(let value) where value.row.key == target.row: outcome = .updateEndedWithoutApplication
            default: outcome = nil
            }
        default: outcome = nil
        }
        if let outcome {
            waiting.closed = true
            waiting.facts.append(scope: target, fact: outcome)
        }
    }
    private func matches(_ publication: PaneContextPopoverPublication, _ target: Target) -> Bool {
        publication.id == target.publication && publication.producer == target.producer
            && publication.request == target.request
    }
    private func sameOpening(_ publication: PaneContextPopoverPublication, _ target: Target) -> Bool {
        publication.request.key == target.request.key && publication.request.openingEpoch == target.request.openingEpoch
    }
    private enum Failure: Error { case nativeOutcome(Outcome) }
}
