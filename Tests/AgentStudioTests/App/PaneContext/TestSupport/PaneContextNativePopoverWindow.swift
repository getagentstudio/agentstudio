import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

enum NativePopoverFact: Equatable, Sendable {
    case readStarted(Int)
    case opened
    case actionCompleted
    case taskEnded
    case readEnded(cancelled: Bool)
    case viewRetired
    case worker(PaneRelativeTimeRefresh.Event)
    case presentationReady(PaneManagementIdentityCapture.VisibleInput)
    case projectionEnded(operation: Int, PaneRelativeTimeRefresh.WorkerOutcome)
}

enum NativePopoverScope: Hashable, Sendable {
    case readSources([PaneContextRefreshKey.Source])
    case cardReadSources([PaneContextRefreshKey.Source])
    case action(Int)
    case readOperation(Int)
    case worker
    case publication
}

/// Mounts the production entry and popover, retaining its live controller binding.
@MainActor
final class PaneContextNativePopoverWindow {
    @MainActor private final class Sink {
        struct ReadOperation {
            let operation: PaneContextReadOperation
            var key: PaneContextRefreshKey { operation.key }
            let scope: NativePopoverScope
            let task: Task<Void, Never>
        }
        var reads: [ReadOperation] = []
        var readMonitors: [Task<Void, Never>] = []
        var endedReads: Set<Int> = []
        var retired = false
        var cancelReadsOnStart = false
        var controller: PaneContextPopoverController?
        var cardController: PaneContextPopoverController?
        var operations: [PaneManagementIdentityCapture.VisibleInput] = []
        var readyInput: PaneManagementIdentityCapture.VisibleInput?
        var completedActions = 0
        var actionTasks: [Task<Void, Never>] = []
        var goToPaneTargets: [UUID] = []
        let facts = FactRecorder<NativePopoverScope, NativePopoverFact>(
            vocabulary: .init(
                describeScope: { "native popover channel \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { scope, fact in
                    switch (scope, fact) {
                    case (.action, .taskEnded), (.readOperation, .readEnded): true
                    default: false
                    }
                }))

        func started(_ operation: PaneContextReadOperation, task: Task<Void, Never>) {
            let scope: NativePopoverScope =
                operation.location == .card
                ? .cardReadSources(operation.key.sources) : .readSources(operation.key.sources)
            let index = reads.count
            reads.append(.init(operation: operation, scope: scope, task: task))
            facts.append(scope: scope, fact: .readStarted(index))
            if cancelReadsOnStart { task.cancel() }
            readMonitors.append(
                Task {
                    await task.value
                    endedReads.insert(index)
                    facts.append(scope: .readOperation(index), fact: .readEnded(cancelled: task.isCancelled))
                })
        }

        func completed(_ operation: PaneContextReadOperation) {
            guard let index = reads.lastIndex(where: { $0.operation == operation }) else {
                Issue.record(
                    "Unattributed native completion: \(operation); producers=\(reads.map { $0.operation })")
                return
            }
            facts.append(scope: .readOperation(index), fact: .opened)
        }
    }
    let clock: NativeCardTestClock
    let window: NSWindow
    private let sink: Sink
    private let isCard: Bool
    private var isPresentingMessages = false
    private var renderedInput: PaneManagementIdentityCapture.VisibleInput?
    private let currentReadKey: @MainActor () -> PaneContextRefreshKey
    var controller: PaneContextPopoverController? {
        isCard && !isPresentingMessages ? sink.cardController : sink.controller
    }
    var facts: FactRecorder<NativePopoverScope, NativePopoverFact> { sink.facts }
    var actionCompletionCount: Int { sink.completedActions }
    var goToPaneTargets: [UUID] { sink.goToPaneTargets }

    init(
        paneId: PaneId, readers: PaneContextUIReaders, location: PaneContextPopoverLocation,
        wallNow: Date, agentLine: RepoExplorerPaneContextLine? = nil, includingDrawers: Bool = true,
        card: (context: PaneManagementContext, store: WorkspaceStore)? = nil,
        viewportWidth: CGFloat? = nil, cancelReadsOnStart: Bool = false,
        onReadStarted: @escaping @MainActor (PaneContextReadOperation) -> Void = { _ in }
    ) {
        let clock = NativeCardTestClock()
        let sink = Sink()
        sink.cancelReadsOnStart = cancelReadsOnStart
        let reference = clock.now
        let presentation: RepoExplorerPaneContextControlPresentation =
            agentLine.map { .agentLine($0) }
            ?? .kind(.init(kind: .needsYou, count: 1))
        let onRelativeTimeEvent: @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void = { event in
            clock.observeOwner(event)
            if case .operation(let input, _) = event { sink.operations.append(input) }
            sink.facts.append(scope: .worker, fact: .worker(event))
            if case .hidden = event { sink.readyInput = nil }
            if case .ended(let input, let outcome) = event, let index = sink.operations.lastIndex(of: input) {
                sink.facts.append(scope: .publication, fact: .projectionEnded(operation: index, outcome))
            }
        }
        let root: AnyView
        if let card {
            root = AnyView(
                ManagementPaneIdentityOverlay(
                    context: card.context,
                    octiconLoader: makeTestOcticonLoader(), store: card.store, clock: clock, wallNow: wallNow,
                    onRelativeTimeEvent: onRelativeTimeEvent,
                    onRelativeTimeReady: {
                        sink.readyInput = $0
                        sink.facts.append(scope: .publication, fact: .presentationReady($0))
                    },
                    onGoToPane: { sink.goToPaneTargets.append($0) },
                    onReadCompleted: { read, value in
                        if read.location == .card {
                            sink.cardController = value
                        } else {
                            sink.controller = value
                        }
                        sink.completed(read)
                    },
                    onReadTaskStarted: { read, task in
                        sink.started(read, task: task)
                        onReadStarted(read)
                    },
                    onActionCompleted: {
                        sink.facts.append(scope: .action(sink.completedActions), fact: .actionCompleted)
                        sink.completedActions += 1
                    }, onActionTaskStarted: { sink.actionTasks.append($0) }
                )
                .environment(\.paneContextUIReaders, readers))
        } else {
            root = AnyView(
                PaneContextPopoverHost(
                    paneId: paneId, presentation: .init(presentation), location: location, readers: readers,
                    octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in }, includingDrawers: includingDrawers,
                    onReadCompleted: { read, value in
                        sink.controller = value
                        sink.completed(read)
                    },
                    onReadTaskStarted: { read, task in
                        sink.started(read, task: task)
                        onReadStarted(read)
                    },
                    onActionCompleted: {
                        sink.facts.append(scope: .action(sink.completedActions), fact: .actionCompleted)
                        sink.completedActions += 1
                    },
                    onActionTaskStarted: { sink.actionTasks.append($0) },
                    clock: clock,
                    wallNow: {
                        let elapsed = reference.duration(to: clock.now).components
                        return wallNow.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    },
                    onRelativeTimeEvent: onRelativeTimeEvent))
        }
        let content = viewportWidth.map { AnyView(root.frame(width: $0)) } ?? root
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(
            x: 0, y: 0, width: viewportWidth ?? (card == nil ? 280 : 640), height: card == nil ? 80 : 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.clock = clock
        self.sink = sink
        isCard = card != nil
        self.window = window
        currentReadKey = { readers.refreshKey(for: paneId) }
        window.makeKeyAndOrderFront(nil)
        layout()
    }

    func actionCompleted(_ number: Int = 0) async throws {
        try #require(sink.actionTasks.count > number, "The native press did not start its action task")
        await sink.actionTasks[number].value
        facts.append(scope: .action(number), fact: .taskEnded)
        try await facts.expectNext(in: .action(number), .actionCompleted)
        try await facts.expectNext(in: .action(number), .taskEnded)
    }

    func readCompleted() async throws {
        while true {
            let scope: NativePopoverScope =
                isCard && !isPresentingMessages
                ? .cardReadSources(currentReadKey().sources) : .readSources(currentReadKey().sources)
            let start = try await facts.expectNext(
                in: scope, where: { _ in true }, "read task start or view retirement")
            guard case .readStarted(let index) = start else {
                throw NativePopoverRenderFailure.unexpectedOutcome(start)
            }
            let outcome = try await facts.expectNext(
                in: .readOperation(index), where: { _ in true }, "read completion, terminal outcome or view retirement")
            switch outcome {
            case .opened:
                let end = try await facts.expectNext(
                    in: .readOperation(index), where: { _ in true }, "read producer terminal outcome or view retirement"
                )
                guard case .readEnded = end else { throw NativePopoverRenderFailure.unexpectedOutcome(end) }
                if sink.reads.indices.contains(where: { $0 > index && sink.reads[$0].scope == scope }) { continue }
                // Facts can change between task creation and the controller's actual read.
                // A current controller needs no successor merely because its origin key is older.
                if sink.reads[index].key != currentReadKey(), controller?.needsRevisionRefresh == true { continue }
                guard end == .readEnded(cancelled: false) else {
                    throw NativePopoverRenderFailure.unexpectedOutcome(end)
                }
                return
            case .readEnded(cancelled: true) where readWasSuperseded(index): continue
            default: throw NativePopoverRenderFailure.unexpectedOutcome(outcome)
            }
        }
    }

    private func readWasSuperseded(_ index: Int) -> Bool {
        let read = sink.reads[index]
        return read.key != currentReadKey()
            || sink.reads.indices.contains { $0 > index && sink.reads[$0].scope == read.scope }
    }

    func open(agentLine: Bool = false) async throws {
        try press(agentLine ? "pane-context.agent-line" : "pane-context.messages.needsYou")
        try await readCompleted()
        while controller?.state == nil {
            try #require(
                controller?.paneId != nil && controller?.unavailableNote == nil,
                "Read ended without an available pane context")
            try await readCompleted()
        }
        layout()
        try await rendered(agentLine: agentLine)
    }

    func rendered(agentLine: Bool = false) async throws {
        let state = try #require(controller?.state)
        let input = PaneManagementIdentityCapture.VisibleInput.popover(state, agentLine ? .agentLine : .messages)
        if renderedInput == input {
            layout()
            return
        }
        try #require(sink.operations.contains(input), "Visible host did not start its shaped popover worker")
        var sawOperation = false
        while true {
            let fact = try await facts.expectNext(
                in: .worker, where: { _ in true }, "visible popover worker entry or end")
            switch fact {
            case .worker(.operation(let actual, let result)):
                if isOlder(actual, than: input) { continue }
                try #require(actual == input && result != .unchanged, "Wrong visible popover input: \(actual)")
                sawOperation = true
            case .worker(.entered(let actual)):
                if isOlder(actual, than: input) { continue }
                try #require(sawOperation && actual == input)
                renderedInput = input
                layout()
                return
            case .worker(.ended(let actual, _)) where isOlder(actual, than: input): continue
            default:
                throw NativePopoverRenderFailure.unexpectedOutcome(fact)
            }
        }
    }

    func renderedCard() async throws {
        while true {
            layout()
            let controller = self.controller
            let selected = controller?.selectedAsk
            let index = try #require(
                sink.operations.lastIndex(where: { input in
                    if case .card(let card) = input {
                        return card.selectedAsk == selected && card.detailMessages == controller?.state?.messages
                            && card.cardUnavailable == (controller?.unavailableNote != nil)
                    }
                    return false
                }), "The mounted card did not observe its completed read")
            let expected = sink.operations[index]
            if sink.readyInput == expected {
                renderedInput = expected
                return
            }
            let fact = try await facts.expectNext(
                in: .publication, where: { _ in true }, "card publication or view retirement")
            switch fact {
            case .presentationReady: continue
            case .projectionEnded(let ended, _) where ended < index: continue
            // Cancellation has a recorded successor, or view retirement supplies the exit.
            case .projectionEnded(_, .cancelled): continue
            case .projectionEnded(_, .completed) where sink.readyInput == expected: continue
            default: throw NativePopoverRenderFailure.unexpectedOutcome(fact)
            }
        }
    }

    private func isOlder(
        _ actual: PaneManagementIdentityCapture.VisibleInput,
        than expected: PaneManagementIdentityCapture.VisibleInput
    ) -> Bool {
        guard actual != expected, let actualIndex = sink.operations.lastIndex(of: actual),
            let expectedIndex = sink.operations.lastIndex(of: expected)
        else { return false }
        // A focused read can supplement the first page at the same source revision.
        // Require the expected production operation, then retire only recorded predecessors.
        return actualIndex < expectedIndex
    }

    func press(_ identifier: String) throws {
        let button = try #require(
            find(identifier) as? any NSAccessibilityProtocol, "Missing native control: \(identifier)")
        if ["pane-context.card-messages", "pane-context.card-more", "pane-context.answer-in-messages"].contains(
            identifier)
        {
            isPresentingMessages = true
        }
        try #require(button.accessibilityPerformPress(), "Native press refused: \(identifier)")
    }

    var editableFields: [NSTextField] { roots.flatMap { descendants(NSTextField.self, in: $0) }.filter(\.isEditable) }
    var nativeButtons: [NSButton] { roots.flatMap { descendants(NSButton.self, in: $0) } }

    func typeText(placeholder: String, value: String) throws {
        let matches = editableFields.filter { $0.placeholderString == placeholder }
        try #require(
            matches.count == 1,
            "Expected one native field with placeholder \(placeholder); fields=\(editableFields.map { $0.placeholderString ?? "<nil>" })"
        )
        let field = matches[0]
        try #require(field.window?.makeFirstResponder(field) == true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        field.window?.makeFirstResponder(nil)
        #expect(field.stringValue == value)
        layout()
    }

    private func descendants<Child: NSView>(_ type: Child.Type, in root: NSView) -> [Child] {
        if let child = root as? Child { return [child] }
        return root.subviews.flatMap { descendants(type, in: $0) }
    }

    func find(_ identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        for root in roots {
            if let element = find(root, matching: { $0.accessibilityIdentifier() == identifier }, visited: &visited) {
                return element
            }
        }
        return nil
    }

    var popoverWindow: NSWindow? {
        NSApp.windows.first { $0 != window && $0.isVisible && $0.contentView != nil }
    }
    var roots: [NSView] { NSApp.windows.filter(\.isVisible).compactMap(\.contentView) }

    func labels() -> [String] {
        var visited = Set<ObjectIdentifier>()
        var result: [String] = []
        for root in roots { collectLabels(root, visited: &visited, result: &result) }
        return result
    }

    func layout() {
        for window in NSApp.windows where window.isVisible {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func close() async throws {
        retireView()
        sink.controller?.close()
        sink.cardController?.close()
        for read in sink.reads {
            read.task.cancel()
            await read.task.value
        }
        for monitor in sink.readMonitors { await monitor.value }
        for task in sink.actionTasks {
            task.cancel()
            await task.value
        }
        try await clock.retire()
        facts.receive(.ended)
        try await facts.finish()
        try await clock.facts.finish()
    }

    func cancelReads() { for read in sink.reads { read.task.cancel() } }

    func retireView() {
        guard !sink.retired else { return }
        sink.retired = true
        let scopes = Set(sink.reads.map(\.scope)).union([
            .cardReadSources(currentReadKey().sources), .readSources(currentReadKey().sources),
        ])
        for scope in scopes { facts.append(scope: scope, fact: .viewRetired) }
        facts.append(scope: .publication, fact: .viewRetired)
        for index in sink.reads.indices where !sink.endedReads.contains(index) {
            facts.append(scope: .readOperation(index), fact: .viewRetired)
        }
        cancelReads()
        window.contentView = nil
        window.close()
    }

    private func find(
        _ element: AnyObject, matching predicate: (any NSAccessibilityProtocol) -> Bool,
        visited: inout Set<ObjectIdentifier>
    ) -> AnyObject? {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if predicate(accessible) { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(child as AnyObject, matching: predicate, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(child, matching: predicate, visited: &visited) { return found }
        }
        return nil
    }

    private func collectLabels(_ element: AnyObject, visited: inout Set<ObjectIdentifier>, result: inout [String]) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        if let accessible = element as? any NSAccessibilityProtocol {
            if let label = accessible.accessibilityLabel(), !label.isEmpty { result.append(label) }
            if let value = accessible.accessibilityValue() as? String, !value.isEmpty { result.append(value) }
            for child in accessible.accessibilityChildren() ?? [] {
                collectLabels(child as AnyObject, visited: &visited, result: &result)
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            collectLabels(child, visited: &visited, result: &result)
        }
    }
}

private enum NativePopoverRenderFailure: Error { case unexpectedOutcome(NativePopoverFact) }
