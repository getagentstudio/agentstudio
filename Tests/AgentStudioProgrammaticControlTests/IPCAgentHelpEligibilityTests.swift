import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Agent help eligibility preservation")
struct IPCAgentHelpEligibilityTests {
    @Test("every entry factory preserves the complete current eligibility table including legacy nil values")
    func entryFactoriesPreserveCurrentEligibility() throws {
        let index = IPCBuiltInMethodIndex()
        let inputs = IPCBuiltInMethodCatalogTestFixture.makeInputs()
        #expect(Set(index.entries.map(\.name)) == Set(Self.expected.keys))
        for entry in index.entries {
            let baseline = try #require(Self.expected[entry.name])
            let descriptor = try entry.makeRepresentation(inputs: inputs).erasedDescriptor
            #expect(entry.agentEligibility == baseline.declaredValue, "entry: \(entry.name)")
            #expect(descriptor.metadata.agentEligibility == baseline.declaredValue, "method: \(entry.name)")
        }
    }

    /// Literal source-grounded oracle, never generated from the value under test.
    private static let expected: [String: ExistingEligibility] = [
        "auth.login": .legacy,
        "auth.status": .legacy,
        "bridge.diff.collapseFile": .notYetAllowed,
        "bridge.diff.expandFile": .notYetAllowed,
        "bridge.diff.getPackage": .notYetAllowed,
        "bridge.diff.load": .notYetAllowed,
        "bridge.diff.refresh": .notYetAllowed,
        "bridge.diff.renderState": .notYetAllowed,
        "bridge.diff.scrollToFile": .notYetAllowed,
        "bridge.diff.selectFile": .notYetAllowed,
        "bridge.fileTree.revealPath": .notYetAllowed,
        "bridge.fileTree.search": .notYetAllowed,
        "bridge.fileTree.setFilter": .notYetAllowed,
        "bridge.fileView.getContent": .notYetAllowed,
        "bridge.fileView.open": .notYetAllowed,
        "bridge.fileView.showMarkdownPreview": .notYetAllowed,
        "bridge.telemetry.flush": .notYetAllowed,
        "bridge.telemetry.snapshot": .notYetAllowed,
        "drawer.addPane": .ownPane,
        "drawer.toggle": .notYetAllowed,
        "events.subscribe": .legacy,
        "events.unsubscribe": .legacy,
        "pane.close": .ownPane,
        "pane.current": .anyTarget,
        "pane.focus": .notYetAllowed,
        "pane.list": .anyTarget,
        "pane.snapshot": .ownPane,
        "pane.split": .notYetAllowed,
        "session.event": .legacy,
        "session.message": .legacy,
        "session.query": .legacy,
        "session.report": .legacy,
        "sidebar.grouping.get": .notYetAllowed,
        "sidebar.surface.get": .notYetAllowed,
        "system.identify": .anyTarget,
        "system.ping": .anyTarget,
        "system.version": .anyTarget,
        "terminal.send": .ownPane,
        "terminal.snapshot": .ownPane,
        "terminal.status": .ownPane,
        "terminal.wait": .ownPane,
        "ui.arrangements.open": .notYetAllowed,
        "ui.commandBar.open": .notYetAllowed,
        "window.current": .anyTarget,
        "window.list": .anyTarget,
        "workspace.current": .anyTarget,
        "workspace.list": .anyTarget,
    ]
}

private enum ExistingEligibility {
    case legacy
    case ownPane
    case anyTarget
    case notYetAllowed

    var declaredValue: IPCAgentEligibility? {
        switch self {
        case .legacy: nil
        case .ownPane: .ownPane
        case .anyTarget: .anyTarget
        case .notYetAllowed: .notYetAllowed
        }
    }
}
