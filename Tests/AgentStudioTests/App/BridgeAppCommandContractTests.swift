import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Pane Zoom and Viewer app command hard-cut contracts")
struct BridgeAppCommandContractTests {
    @Test("Pane Zoom and Zoom-local Viewer coexist with durable Review and Files commands")
    func zoomAndDurableViewerCommandIdentitiesAreSeparate() {
        // Arrange
        let expectedCommandIdentities: Set<String> = [
            "zoomPane",
            "showViewer",
            "showBridgeReview",
            "showBridgeFiles",
            "openBridgeReviewInNewTab",
            "openBridgeFilesInNewTab",
        ]
        let retiredCommandIdentities: Set<String> = [
            "toggleSplitZoom"
        ]

        // Act
        let commandIdentities = Set(AppCommand.allCases.map(\.rawValue))

        // Assert
        #expect(expectedCommandIdentities.isSubset(of: commandIdentities))
        #expect(commandIdentities.isDisjoint(with: retiredCommandIdentities))
    }

    @Test("Bridge Web View Reload is a no-shortcut browser presentation escape hatch")
    func bridgeWebViewReloadCommandCatalogContract() throws {
        // Arrange
        let reloadBridgeWebView = try #require(
            AppCommand(rawValue: "reloadBridgeWebView")
        )

        // Act
        let definition = AppCommandDispatcher.shared.definition(for: reloadBridgeWebView)

        // Assert
        #expect(definition.label == "Reload Bridge")
        #expect(definition.icon == .system(.arrowClockwise))
        #expect(
            definition.helpText
                == "Reload the Bridge browser page and discard browser presentation state without refreshing worktree source data"
        )
        #expect(definition.surfacePolicy == .exposed([.commandBar, .bridgePage]))
        #expect(definition.targeting == .contextualAndTargeted([.pane], preferredInvocation: .contextual))
        #expect(definition.visibleWhen == [.hasActivePane, .paneIsBridge])
        #expect(definition.shortcut == nil)
        #expect(definition.globalKeyBinding == nil)
    }

    @Test("Command-R remains exclusively the Management Layer toggle")
    func commandRDoesNotDispatchBridgeWebViewReload() throws {
        // Arrange
        let reloadBridgeWebView = try #require(
            AppCommand(rawValue: "reloadBridgeWebView")
        )
        let commandR = ShortcutTrigger(
            key: .character(.r),
            modifiers: [.command]
        )

        // Act
        let resolvedShortcut = ShortcutDecoder.shortcut(for: commandR, in: .global)
        let reloadShortcuts = AppShortcut.allCases.filter {
            $0.command == reloadBridgeWebView
        }

        // Assert
        #expect(resolvedShortcut == .toggleManagementLayer)
        #expect(reloadShortcuts.isEmpty)
    }

    @Test("Review is available contextually and for worktree targets")
    func reviewCommandCatalogContract() throws {
        // Arrange
        let showReview = try #require(AppCommand(rawValue: "showBridgeReview"))

        // Act
        let definition = AppCommandDispatcher.shared.definition(for: showReview)

        // Assert
        #expect(definition.surfacePolicy == .exposed([.commandBar, .contextMenu]))
        #expect(
            definition.targeting
                == .contextualAndTargeted([.worktree], preferredInvocation: .contextual)
        )
    }
}
