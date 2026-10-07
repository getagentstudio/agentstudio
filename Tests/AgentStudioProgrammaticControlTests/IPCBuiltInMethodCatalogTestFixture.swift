import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

/// Shared app-catalog inputs retain the established concrete command relationships and distinct example IDs.
enum IPCBuiltInMethodCatalogTestFixture {
    static var relationships: IPCBuiltInMethodRelationshipInputs {
        .init(
            paneFocus: .appCommand(identifier: "fixture.pane-focus"),
            paneClose: .appCommand(identifier: "fixture.pane-close"),
            drawerToggle: .appCommand(identifier: "fixture.drawer-toggle"),
            drawerAddPane: .appCommand(identifier: "fixture.drawer-add"),
            bridgeDiffLoad: .appCommand(identifier: "fixture.bridge-review-open"),
            bridgeFileViewOpen: .appCommand(identifier: "fixture.bridge-files-open")
        )
    }

    static func makeExampleContext() -> IPCBuiltInMethodExampleContext {
        .init(
            runtimeId: UUIDv7.generate(),
            windowId: UUIDv7.generate(),
            workspaceId: UUIDv7.generate(),
            repositoryId: UUIDv7.generate(),
            worktreeId: UUIDv7.generate(),
            tabId: UUIDv7.generate(),
            paneId: UUIDv7.generate(),
            commandId: UUIDv7.generate(),
            correlationId: UUIDv7.generate(),
            subscriptionId: UUIDv7.generate()
        )
    }

    static func makeInputs() -> IPCBuiltInMethodCatalogInputs {
        .init(relationships: relationships, examples: makeExampleContext())
    }
}
