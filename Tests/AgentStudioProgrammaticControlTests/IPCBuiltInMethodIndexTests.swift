import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC deferred built-in method index")
struct IPCBuiltInMethodIndexTests {
    @Test("index keys retain the independent exact 47-method oracle and full catalog surface")
    func indexHasExactCompiledNameSet() throws {
        let index = IPCBuiltInMethodIndex()
        let catalog = try IPCBuiltInMethodCatalog(inputs: inputs)
        let names = index.entries.map(\.name)
        #expect(names == expectedStaticMethodNames)
        #expect(names.count == 47)
        #expect(Set(names).count == names.count)
        #expect(Set(names) == Set(catalog.erasedDescriptors.map { $0.metadata.name }))
    }

    @Test("every real entry factory retains its key, summary and complete app catalog metadata")
    func everyFactoryMatchesEntryAndFullCatalog() throws {
        let fixture = inputs
        let catalog = try IPCBuiltInMethodCatalog(inputs: fixture)
        let metadata = Dictionary(
            uniqueKeysWithValues: catalog.erasedDescriptors.map { ($0.metadata.name, $0.metadata) })
        for entry in IPCBuiltInMethodIndex().entries {
            let descriptor = try entry.makeRepresentation(inputs: fixture).erasedDescriptor
            #expect(descriptor.metadata.name == entry.name, "entry: \(entry.name)")
            #expect(descriptor.metadata.description == entry.summary, "entry: \(entry.name)")
            #expect(descriptor.metadata == metadata[entry.name], "entry: \(entry.name)")
            #expect(descriptor.metadata.modelCalls == entry.modelCalls, "entry: \(entry.name)")
            #expect(descriptor.metadata.correlationPolicy == entry.correlationPolicy, "entry: \(entry.name)")
        }
    }

    private var inputs: IPCBuiltInMethodCatalogInputs {
        IPCBuiltInMethodCatalogTestFixture.makeInputs()
    }

    private var expectedStaticMethodNames: [String] {
        [
            "auth.login",
            "auth.status",
            "bridge.diff.collapseFile",
            "bridge.diff.expandFile",
            "bridge.diff.getPackage",
            "bridge.diff.load",
            "bridge.diff.refresh",
            "bridge.diff.renderState",
            "bridge.diff.scrollToFile",
            "bridge.diff.selectFile",
            "bridge.fileTree.revealPath",
            "bridge.fileTree.search",
            "bridge.fileTree.setFilter",
            "bridge.fileView.getContent",
            "bridge.fileView.open",
            "bridge.fileView.showMarkdownPreview",
            "bridge.telemetry.flush",
            "bridge.telemetry.snapshot",
            "drawer.addPane",
            "drawer.toggle",
            "events.subscribe",
            "events.unsubscribe",
            "pane.close",
            "pane.current",
            "pane.focus",
            "pane.list",
            "pane.snapshot",
            "pane.split",
            "session.event",
            "session.message",
            "session.query",
            "session.report",
            "sidebar.grouping.get",
            "sidebar.surface.get",
            "system.identify",
            "system.ping",
            "system.version",
            "terminal.send",
            "terminal.snapshot",
            "terminal.status",
            "terminal.wait",
            "ui.arrangements.open",
            "ui.commandBar.open",
            "window.current",
            "window.list",
            "workspace.current",
            "workspace.list",
        ]
    }
}
