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
    case opened
    case actionCompleted
    case taskEnded
    case worker(PaneRelativeTimeRefresh.Event)
}

enum NativePopoverScope: Hashable, Sendable {
    case readSources([PaneContextRefreshKey.Source])
    case action(Int)
    case worker
}

/// Mounts the production entry and popover, retaining its live controller binding.
@MainActor
final class PaneContextNativePopoverWindow {
    private final class Sink {
        var controller: PaneContextPopoverController?
        var operations: [PaneManagementIdentityCapture.VisibleInput] = []
        var completedActions = 0
        var actionTasks: [Task<Void, Never>] = []
        let facts = FactRecorder<NativePopoverScope, NativePopoverFact>(
            vocabulary: .init(
                describeScope: { "native popover channel \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { scope, fact in
                    switch (scope, fact) {
                    case (.action, .taskEnded): true
                    default: false
                    }
                }))
    }
    let clock: NativeCardTestClock
    let window: NSWindow
    private let sink: Sink
    private var renderedInput: PaneManagementIdentityCapture.VisibleInput?
    private let currentReadKey: @MainActor () -> PaneContextRefreshKey
    var controller: PaneContextPopoverController? { sink.controller }
    var facts: FactRecorder<NativePopoverScope, NativePopoverFact> { sink.facts }
    var actionCompletionCount: Int { sink.completedActions }

    init(
        paneId: PaneId, readers: PaneContextUIReaders, location: PaneContextPopoverLocation,
        wallNow: Date, agentLine: RepoExplorerPaneContextLine? = nil, includingDrawers: Bool = true
    ) {
        let clock = NativeCardTestClock()
        let sink = Sink()
        let reference = clock.now
        let presentation: RepoExplorerPaneContextControlPresentation =
            agentLine.map { .agentLine($0) }
            ?? .kind(.init(kind: .needsYou, count: 1))
        let host = NSHostingView(
            rootView: PaneContextPopoverHost(
                paneId: paneId, presentation: presentation, location: location, readers: readers,
                octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in }, includingDrawers: includingDrawers,
                onReadCompleted: { key, value in
                    sink.controller = value
                    sink.facts.append(scope: .readSources(key.sources), fact: .opened)
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
                onRelativeTimeEvent: { event in
                    clock.observeOwner(event)
                    if case .operation(let input, _) = event { sink.operations.append(input) }
                    sink.facts.append(scope: .worker, fact: .worker(event))
                }))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.clock = clock
        self.sink = sink
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
        try await facts.expectNext(in: .readSources(currentReadKey().sources), .opened)
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

    private func isOlder(
        _ actual: PaneManagementIdentityCapture.VisibleInput,
        than expected: PaneManagementIdentityCapture.VisibleInput
    ) -> Bool {
        guard case .popover(let old, let oldContent) = actual,
            case .popover(let current, let currentContent) = expected
        else { return false }
        return old.paneId == current.paneId && oldContent == currentContent
            && old.revision.value < current.revision.value
    }

    func press(_ identifier: String) throws {
        let button = try #require(
            find(identifier) as? any NSAccessibilityProtocol, "Missing native control: \(identifier)")
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
        sink.controller?.close()
        for task in sink.actionTasks {
            task.cancel()
            await task.value
        }
        window.contentView = nil
        window.close()
        try await clock.retire()
        facts.receive(.ended)
        try await facts.finish()
        try await clock.facts.finish()
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
