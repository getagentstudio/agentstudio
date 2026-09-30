import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("AgentStudio IPC command presentation isolation")
struct AgentStudioIPCCommandPresentationIsolationTests {
    @Test("S3 catalog excludes presentation and future debug commands")
    func s3CatalogExcludesPresentationAndFutureDebugCommands() async throws {
        let catalog = try await makeIPCCommandCatalogOffMain(
            from: makeIPCCommandAdapterForPresentationIsolationTests())
        let ids = Set(catalog.commands.map(\.id.rawValue))

        #expect(catalog.commands.count == 24)
        #expect(ids.contains(AppCommand.zoomPane.rawValue))
        #expect(ids.contains(AppCommand.showReposSidebar.rawValue))
        #expect(!ids.contains(AppCommand.showCommandBarEverything.rawValue))
        #expect(!ids.contains(AppCommand.closePane.rawValue))
        #expect(!ids.contains(AppCommand.showInboxNotifications.rawValue))
        for command in retiredPanesOrganizationCommands {
            #expect(!ids.contains(command.rawValue))
        }
    }

    @Test("App-owned policy keeps headless, presentation, and dormant meanings distinct")
    func appOwnedPolicyKeepsExecutionMeaningsDistinct() {
        #expect(AppCommand.zoomPane.ipcSpec.exposure == .allChannels)
        #expect(AppCommand.zoomPane.ipcSpec.executionMode == .headless)
        #expect(AppCommand.zoomPane.ipcSpec.argumentVariants == [.pane])
        #expect(AppCommand.zoomPane.ipcSpec.resultVariants == [.applied])

        #expect(AppCommand.showCommandBarEverything.ipcSpec.exposure == .debugTesting)
        #expect(AppCommand.showCommandBarEverything.ipcSpec.executionMode == .uiPresentation)
        #expect(AppCommand.showCommandBarEverything.ipcSpec.resultVariants == [.presented])

        #expect(AppCommand.showInboxNotifications.ipcSpec.exposure == .debugTesting)
        #expect(AppCommand.showInboxNotifications.ipcSpec.argumentVariants == [.noArguments])
        #expect(AppCommand.showInboxNotifications.ipcSpec.resultVariants == [.unavailable])

        for command in retiredPanesOrganizationCommands {
            #expect(command.ipcSpec.exposure == .debugTesting)
            #expect(command.ipcSpec.resultVariants == [.unavailable])
        }
    }

    @Test("encoded command descriptors exclude interactive presentation policy")
    func encodedCommandDescriptorsExcludeInteractivePresentationPolicy() async throws {
        let catalog = try await makeIPCCommandCatalogOffMain(
            from: makeIPCCommandAdapterForPresentationIsolationTests())
        let encoded = try JSONEncoder().encode(catalog)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let commands = try #require(object["commands"] as? [[String: Any]])
        let interactivePolicyKeys = Set([
            "surfacePolicy",
            "surfaces",
            "targeting",
            "preferredInvocation",
            "visibleWhen",
            "requirements",
        ])

        #expect(!commands.isEmpty)
        for command in commands {
            #expect(Set(command.keys).isDisjoint(with: interactivePolicyKeys))
            #expect(command["argumentVariants"] != nil)
            #expect(command["resultVariants"] != nil)
            #expect(command["argumentSchema"] != nil)
            #expect(command["resultSchema"] != nil)
        }
    }
}
