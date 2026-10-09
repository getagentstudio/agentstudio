import AgentStudioCore
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCommandBar

@MainActor
@Suite(.serialized)
struct CommandBarBridgeReloadPresentationTests {
    init() {
        installTestCoreAtomsIfNeeded()
    }

    @Test("Bridge Reload presentation follows the typed command context")
    func bridgeReloadRequiresBridgeCommandContext() {
        // Arrange
        let dispatcher = FakeAppCommandDispatcher()
        let nonBridgeContext = CommandContext(
            focusedContentType: .terminal,
            satisfiedRequirements: [.hasActivePane]
        )
        let bridgeContext = CommandContext(
            focusedContentType: .bridge,
            satisfiedRequirements: [.hasActivePane, .paneIsBridge]
        )

        // Act
        let nonBridgeItems = CommandBarDataSource.items(
            scope: .commands,
            store: WorkspaceStore(),
            repoCache: RepoCacheAtom(),
            dispatcher: dispatcher,
            focusedPane: nil,
            commandContext: nonBridgeContext
        )
        let bridgeItems = CommandBarDataSource.items(
            scope: .commands,
            store: WorkspaceStore(),
            repoCache: RepoCacheAtom(),
            dispatcher: dispatcher,
            focusedPane: nil,
            commandContext: bridgeContext
        )

        // Assert
        #expect(!nonBridgeItems.contains { $0.id == "cmd-reloadBridgeWebView" })
        #expect(bridgeItems.contains { $0.id == "cmd-reloadBridgeWebView" })
        #expect(bridgeItems.first { $0.id == "cmd-reloadBridgeWebView" }?.title == "Reload Bridge")
    }
}
