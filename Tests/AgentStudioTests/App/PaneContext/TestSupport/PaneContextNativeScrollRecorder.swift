import AgentStudioInfrastructure
import AgentStudioTestHarness
import AppKit
import Foundation
import Testing

@testable import AgentStudio

/// Separates the scroll sender's outcome from observed native viewport application.
@MainActor
final class PaneContextNativeScrollRecorder {
    enum Scope: Hashable, Sendable {
        case starts
        case operation(UUID)
        case viewport(UUID)
    }
    enum Fact: Equatable, Sendable {
        case started(PaneContextPopoverScrollOperation)
        case ended(PaneContextPopoverScrollOutcome)
        case producerEnded
        case retired
        case boundsChanged(CGRect)
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
    private var viewportScopes: Set<Scope> = []
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
        for scope in viewportScopes { facts.append(scope: scope, fact: .retired) }
        for operation in operations where !endedProducers.contains(operation.id) {
            facts.append(scope: .operation(operation.id), fact: .retired)
        }
    }

    /// NSClipView owns the observable state; a sender task returning does not apply layout.
    func viewport(
        _ scroll: NSScrollView, matches predicate: (CGRect) -> Bool
    ) async throws {
        let scope = Scope.viewport(UUIDv7.generate())
        guard !retired else { throw ScrollFailure.unexpected(.retired) }
        viewportScopes.insert(scope)
        let clip = scroll.contentView
        let window = try #require(scroll.window, "The native scroll view retired before viewport observation")
        let previouslyPosted = clip.postsBoundsChangedNotifications
        clip.postsBoundsChangedNotifications = true
        let bounds = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [facts] _ in
            MainActor.assumeIsolated {
                facts.append(scope: scope, fact: .boundsChanged(scroll.documentVisibleRect))
            }
        }
        let retirement = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [facts] _ in facts.append(scope: scope, fact: .retired) }
        defer {
            NotificationCenter.default.removeObserver(bounds)
            NotificationCenter.default.removeObserver(retirement)
            clip.postsBoundsChangedNotifications = previouslyPosted
            viewportScopes.remove(scope)
        }
        facts.append(scope: scope, fact: .boundsChanged(scroll.documentVisibleRect))
        while true {
            let observed = try await facts.expectNext(
                in: scope, where: { _ in true }, "native clip bounds matching destination or view retirement")
            guard case .boundsChanged(let visible) = observed else { throw ScrollFailure.unexpected(observed) }
            if predicate(visible) { return }
        }
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
