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
    case waitingForRead(Int)
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
    case projectionWait
    case readSources([PaneContextRefreshKey.Source])
    case cardReadSources([PaneContextRefreshKey.Source])
    case action(Int)
    case readOperation(Int)
    case worker
    case publication
    case popoverPublication
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
        struct ProjectionOperation {
            let input: PaneManagementIdentityCapture.VisibleInput
            let id: UUID
        }
        var reads: [ReadOperation] = []
        var readMonitors: [Task<Void, Never>] = []
        var endedReads: Set<Int> = []
        var retired = false
        var cancelReadsOnStart = false
        var controller: PaneContextPopoverController?
        var cardController: PaneContextPopoverController?
        var operations: [ProjectionOperation] = []
        var publishedOperations: Set<UUID> = []
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

        func observe(_ event: PaneRelativeTimeRefresh.Event) {
            facts.append(scope: .worker, fact: .worker(event))
            switch event {
            case .operation(let input, let result, let id):
                if result != .unchanged { operations.append(.init(input: input, id: id)) }
                if let scope = publicationScope(input) { facts.append(scope: scope, fact: .worker(event)) }
            case .ended(let input, let outcome, let id):
                guard let index = operations.lastIndex(where: { $0.id == id }), let scope = publicationScope(input)
                else { return }
                facts.append(scope: scope, fact: .projectionEnded(operation: index, outcome))
            case .entered, .hidden: break
            }
        }

        func published(_ input: PaneManagementIdentityCapture.VisibleInput, id: UUID) {
            guard operations.contains(where: { $0.id == id && $0.input == input }), let scope = publicationScope(input)
            else {
                Issue.record("Native publication has no matching producing worker: \(id)")
                return
            }
            publishedOperations.insert(id)
            facts.append(scope: scope, fact: .presentationReady(input))
        }

        private func publicationScope(_ input: PaneManagementIdentityCapture.VisibleInput) -> NativePopoverScope? {
            switch input {
            case .card: .publication
            case .popover: .popoverPublication
            case .toolbar: nil
            }
        }
    }
    let clock: NativeCardTestClock
    let window: NSWindow
    let scrolling: PaneContextNativeScrollRecorder
    private let sink: Sink
    private let isCard: Bool
    private let messageEntryKind: KindChipModel.Kind
    private let messageEntryIdentifier: String?
    private var isPresentingMessages = false
    private var verifiedReads: [NativePopoverScope: Int] = [:]
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
        onReadStarted: @escaping @MainActor (PaneContextReadOperation) -> Void = { _ in },
        messageEntryKind: KindChipModel.Kind = .needsYou,
        messageEntry: PaneContextPopoverEntry? = nil
    ) {
        let clock = NativeCardTestClock()
        let sink = Sink()
        let scrolling = PaneContextNativeScrollRecorder()
        sink.cancelReadsOnStart = cancelReadsOnStart
        let reference = clock.now
        let presentation: RepoExplorerPaneContextControlPresentation =
            agentLine.map { .agentLine($0) }
            ?? .kind(.init(kind: messageEntryKind, count: 1))
        let onRelativeTimeEvent: @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void = { event in
            clock.observeOwner(event)
            sink.observe(event)
        }
        let root: AnyView
        if let card {
            root = AnyView(
                ManagementPaneIdentityOverlay(
                    context: card.context,
                    octiconLoader: makeTestOcticonLoader(), store: card.store, clock: clock, wallNow: wallNow,
                    onRelativeTimeEvent: onRelativeTimeEvent,
                    onRelativeTimeReady: { input, id in sink.published(input, id: id) },
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
                    onScrollEvent: { scrolling.observe($0) },
                    onActionCompleted: {
                        sink.facts.append(scope: .action(sink.completedActions), fact: .actionCompleted)
                        sink.completedActions += 1
                    }, onActionTaskStarted: { sink.actionTasks.append($0) }
                )
                .environment(\.paneContextUIReaders, readers))
        } else {
            root = AnyView(
                PaneContextPopoverHost(
                    paneId: paneId, presentation: messageEntry ?? .init(presentation), location: location,
                    readers: readers,
                    octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in }, includingDrawers: includingDrawers,
                    onReadCompleted: { read, value in
                        sink.controller = value
                        sink.completed(read)
                    },
                    onReadTaskStarted: { read, task in
                        sink.started(read, task: task)
                        onReadStarted(read)
                    },
                    onScrollEvent: { scrolling.observe($0) },
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
                    onRelativeTimeEvent: onRelativeTimeEvent,
                    onRelativeTimeReady: { input, id in sink.published(input, id: id) }))
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
        self.scrolling = scrolling
        self.messageEntryKind = messageEntryKind
        if case .messagesAction(let control, _) = messageEntry {
            messageEntryIdentifier = control.identifier
        } else {
            messageEntryIdentifier = nil
        }
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
        try await readCompleted(for: isCard && !isPresentingMessages ? .publication : .popoverPublication)
    }

    private func readCompleted(for publicationScope: NativePopoverScope) async throws {
        while true {
            let scope: NativePopoverScope =
                publicationScope == .publication
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
                let readController = publicationScope == .publication ? sink.cardController : sink.controller
                if sink.reads[index].key != currentReadKey(), readController?.needsRevisionRefresh == true { continue }
                guard end == .readEnded(cancelled: false) else {
                    throw NativePopoverRenderFailure.unexpectedOutcome(end)
                }
                verifiedReads[publicationScope] = max(verifiedReads[publicationScope] ?? -1, index)
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
        try press(
            agentLine
                ? "pane-context.agent-line" : messageEntryIdentifier ?? "pane-context.messages.\(messageEntryKind)")
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
        let published = try await waitForPublication(in: .popoverPublication) {
            let state = try #require(self.controller?.state)
            let input = PaneManagementIdentityCapture.VisibleInput.popover(state, agentLine ? .agentLine : .messages)
            return try #require(
                self.sink.operations.lastIndex { $0.input == input },
                "Visible host did not start its shaped popover worker")
        }
        let content = try #require(
            { () -> PaneManagementIdentityCapture.PopoverContent? in
                if case .popover(_, let content) = published.input { return content }
                return nil
            }(), "Expected an observed popover publication")
        #expect(content == (agentLine ? .agentLine : .messages))
    }

    func renderedCard() async throws {
        let published = try await waitForPublication(in: .publication) {
            let controller = self.sink.cardController
            return try #require(
                self.sink.operations.lastIndex { operation in
                    if case .card(let card) = operation.input {
                        return card.selectedAsk == controller?.selectedAsk
                            && card.detailMessages == controller?.state?.messages
                            && card.cardUnavailable == (controller?.unavailableNote != nil)
                    }
                    return false
                }, "The mounted card did not observe its completed read")
        }
        try #require(
            { () -> Bool in
                if case .card = published.input { return true }
                return false
            }(), "Expected an observed card publication")
    }

    private func waitForPublication(
        in scope: NativePopoverScope, currentOperation: @MainActor () throws -> Int
    ) async throws -> Sink.ProjectionOperation {
        while true {
            try #require(!sink.retired, "The native projection view retired before publication")
            let latestRead = sink.reads.indices.last {
                (sink.reads[$0].operation.location == .card) == (scope == .publication)
            }
            if let latestRead, latestRead > (verifiedReads[scope] ?? -1) {
                facts.append(scope: .projectionWait, fact: .waitingForRead(latestRead))
                try await readCompleted(for: scope)
                continue
            }
            layout()
            let index = try currentOperation()
            let operation = sink.operations[index]
            if sink.publishedOperations.contains(operation.id) { return operation }
            let fact = try await facts.expectNext(
                in: scope, where: { _ in true }, "current worker publication, terminal outcome or view retirement")
            switch fact {
            case .presentationReady, .worker(.operation): continue
            case .projectionEnded(let ended, _) where ended < index: continue
            case .projectionEnded(let ended, _) where ended > index:
                // The expected snapshot can be superseded while its publication wait is suspended.
                guard try currentOperation() > index else { throw NativePopoverRenderFailure.unexpectedOutcome(fact) }
                continue
            case .projectionEnded(_, .completed) where sink.publishedOperations.contains(operation.id): continue
            default: throw NativePopoverRenderFailure.unexpectedOutcome(fact)
            }
        }
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
        try await scrolling.finish()
        facts.receive(.ended)
        try await facts.finish()
        try await clock.facts.finish()
    }

    func cancelReads() { for read in sink.reads { read.task.cancel() } }

    func retireView() {
        guard !sink.retired else { return }
        sink.retired = true
        scrolling.retire()
        let scopes = Set(sink.reads.map(\.scope)).union([
            .cardReadSources(currentReadKey().sources), .readSources(currentReadKey().sources),
        ])
        for scope in scopes { facts.append(scope: scope, fact: .viewRetired) }
        facts.append(scope: .publication, fact: .viewRetired)
        facts.append(scope: .popoverPublication, fact: .viewRetired)
        facts.append(scope: .projectionWait, fact: .viewRetired)
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
