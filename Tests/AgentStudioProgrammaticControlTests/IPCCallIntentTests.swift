import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC call intent catalog")
struct IPCCallIntentTests {
    @Test("the full inventory grants claim eligibility only to the four status writes")
    func exactIntentInventory() throws {
        let catalog = try IPCBuiltInMethodCatalog(inputs: IPCBuiltInMethodCatalogTestFixture.makeInputs())
        let expected: [IPCCallIntent: Set<String>] = [
            .status: ["session.status", "pane.line.set", "pane.title.set", "pane.writer.claimEpoch"],
            .identity: ["session.event", "session.refusal"],
            .message: ["pane.message.send", "pane.message.ask", "pane.message.withdraw"],
            .read: [
                "pane.list", "pane.current", "pane.snapshot", "terminal.status", "terminal.snapshot", "terminal.wait",
                "pane.message.changes", "pane.context.get", "session.query", "bridge.diff.getPackage",
                "bridge.diff.renderState", "bridge.fileView.getContent", "window.render",
            ],
            .control: [
                "auth.login", "auth.status", "bridge.diff.collapseFile", "bridge.diff.expandFile", "bridge.diff.load",
                "bridge.diff.refresh", "bridge.diff.scrollToFile", "bridge.diff.selectFile",
                "bridge.fileTree.revealPath",
                "bridge.fileTree.search", "bridge.fileTree.setFilter", "bridge.fileView.open",
                "bridge.fileView.showMarkdownPreview", "bridge.telemetry.flush", "bridge.telemetry.snapshot",
                "drawer.addPane", "drawer.toggle", "events.subscribe", "events.unsubscribe", "pane.close", "pane.focus",
                "pane.split", "sidebar.grouping.get", "sidebar.surface.get", "system.identify", "system.ping",
                "system.version", "terminal.send", "ui.arrangements.open", "ui.commandBar.open", "window.current",
                "window.list", "window.resize", "workspace.current", "workspace.list",
            ],
        ]
        for (intent, names) in expected {
            #expect(
                Set(catalog.erasedDescriptors.filter { $0.metadata.callIntent == intent }.map(\.metadata.name)) == names
            )
        }
        let classified = expected.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        #expect(classified == Set(catalog.erasedDescriptors.map(\.metadata.name)))
        #expect(IPCCallIntent.status.effective(hasSessionWriter: true) == .identity)
        #expect(IPCCallIntent.status.effective(hasSessionWriter: false) == .status)
    }

    @Test("status report accepts a refusal without session identity and strictly rejects mixed variants")
    func reportVariantsAreStrict() throws {
        let descriptor = try IPCBuiltInMethodCatalog(inputs: IPCBuiltInMethodCatalogTestFixture.makeInputs()).sessions
            .sessionStatus
        let data = try JSONEncoder().encode(descriptor.examples[0].parameters)
        let valid = try descriptor.decodeParameters(from: data)
        #expect(valid.report == .refusal(reason: .noSessionId))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var report = try #require(object["report"] as? [String: Any])
        report["providerSessionId"] = "cannot-smuggle-identity"
        object["report"] = report
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(from: JSONSerialization.data(withJSONObject: object))
        }
        object["report"] = ["kind": "refusal", "reason": "arbitraryPayload"]
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
