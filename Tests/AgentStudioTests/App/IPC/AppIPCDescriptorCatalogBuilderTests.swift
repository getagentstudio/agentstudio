import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio

/// `AppIPCDescriptorCatalogBuilder` is App-owned (`Sources/AgentStudio/App/IPCComposition`),
/// so its coverage lives in the App test target rather than `AgentStudioAppIPCTests`.
@Suite("App IPC descriptor catalog builder")
struct AppIPCDescriptorCatalogBuilderTests {
    @Test("descriptor catalog builder reports a missing system ping")
    func descriptorCatalogBuilderReportsMissingSystemPing() throws {
        let catalog = try Self.makeBuiltInMethodCatalog()
        let availableDescriptors = catalog.erasedDescriptors.filter {
            $0.metadata.name != "system.ping"
        }

        #expect(throws: AppIPCDescriptorCatalogBuilder.BuildError.systemPingMissing) {
            try AppIPCDescriptorCatalogBuilder.composeSystemCapabilities(
                availableDescriptors: availableDescriptors,
                recognizedUnexposedMethods: []
            )
        }
    }

    private static func makeBuiltInMethodCatalog() throws -> IPCBuiltInMethodCatalog {
        try IPCBuiltInMethodCatalog(
            inputs: IPCBuiltInMethodCatalogInputs(
                terminalWaitMaximumSeconds: 10,
                relationships: IPCBuiltInMethodRelationshipInputs(
                    paneFocus: .noInteractiveIdentity,
                    paneClose: .noInteractiveIdentity,
                    drawerToggle: .noInteractiveIdentity,
                    drawerAddPane: .noInteractiveIdentity,
                    bridgeDiffLoad: .noInteractiveIdentity,
                    bridgeFileViewOpen: .noInteractiveIdentity
                ),
                examples: IPCBuiltInMethodExampleContext(
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
            )
        )
    }
}
