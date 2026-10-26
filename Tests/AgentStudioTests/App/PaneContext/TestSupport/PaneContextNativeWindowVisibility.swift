import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

/// Observes the actual window property, independently of the action that asks it to close.
@MainActor
final class PaneContextNativeWindowVisibility {
    enum Fact: Equatable, Sendable { case visible, hidden, producerEnded, retired, waiting }
    let facts = FactRecorder<Int, Fact>(
        vocabulary: .init(
            describeScope: { "native window visibility \($0)" }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .hidden || fact == .producerEnded || fact == .retired }))
    private let window: NSWindow
    private var observation: NSKeyValueObservation?
    private var closed = false

    init(_ window: NSWindow) {
        self.window = window
        observation = window.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.observed(window.isVisible) }
        }
    }

    isolated deinit { observation?.invalidate() }

    func hidden() async throws {
        if !window.isVisible { return }
        facts.append(scope: 1, fact: .waiting)
        while true {
            let fact = try await facts.expectNext(
                in: 0, where: { _ in true }, "native window hidden, producer ending or retirement")
            switch fact {
            case .visible: continue
            case .hidden: return
            default: throw VisibilityFailure.unexpected(fact)
            }
        }
    }

    func producerEnded() {
        guard !closed else { return }
        closed = true
        facts.append(scope: 0, fact: .producerEnded)
    }

    func finish() async throws {
        observation?.invalidate()
        observation = nil
        if !closed {
            closed = true
            facts.append(scope: 0, fact: .retired)
        }
        facts.receive(.ended)
        try await facts.finish()
    }

    private func observed(_ visible: Bool) {
        guard !closed else { return }
        if !visible { closed = true }
        facts.append(scope: 0, fact: visible ? .visible : .hidden)
    }
}

private enum VisibilityFailure: Error { case unexpected(PaneContextNativeWindowVisibility.Fact) }
