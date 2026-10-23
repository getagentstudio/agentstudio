import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCommandBar
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Agent setup prompt command", .serialized)
struct AgentSetupPromptCommandTests {
    init() { installTestCoreAtomsIfNeeded() }
    @Test("Copy Agent Setup Prompt has one command identity and canonical display")
    func copySetupPromptCatalog() throws {
        let command = try #require(AppCommand(rawValue: "copyAgentSetupPrompt"))
        #expect(command.definition.label == "Copy Agent Setup Prompt")
        #expect(command.definition.icon == .system(.documentOnDocument))
        #expect(command.definition.shortcut == nil)
        #expect(command.ipcSpec.exposure == .notExposed)
        let dispatcher = CommandDispatcherFixtureConfiguration().makeDispatcher()
        let rows = CommandBarDataSource.items(
            scope: .commands, store: WorkspaceStore(), repoCache: RepoCacheAtom(), dispatcher: dispatcher,
            focusedPane: nil, commandContext: .empty)
        let row = try #require(rows.first { $0.command == command })
        #expect(row.title == command.definition.label)
        #expect(row.icon == command.definition.icon)
        #expect(row.id == "cmd-copyAgentSetupPrompt")
    }
    @Test("interactive dispatch copies exactly the shared setup prompt through the App shell")
    func interactiveCopyUsesShellOwner() throws {
        let saved = Self.savedPasteboard()
        defer { Self.restorePasteboard(saved) }
        NSPasteboard.general.clearContents()
        let pasteboardReady = NSPasteboard.general.setString("setup-prompt-positive-sentinel", forType: .string)
        try #require(pasteboardReady, "general pasteboard service unavailable before product execution")
        let delegate = AppDelegate()
        let dispatcher = CommandDispatcherFixtureConfiguration(shellOwner: delegate).makeDispatcher()
        #expect(dispatcher.canDispatch(.copyAgentSetupPrompt))
        #expect(dispatcher.dispatch(.copyAgentSetupPrompt))
        let promptMatches = NSPasteboard.general.string(forType: .string) == AgentSetupPrompt.text
        #expect(promptMatches)
        for verb in ["status", "snippet", "install", "uninstall"] {
            #expect(AgentSetupPrompt.text.contains("agentstudio package \(verb)"))
        }
        #expect(AgentSetupPrompt.text.contains("agentstudio skill"))
        #expect(AgentSetupPrompt.text.contains("go-ahead"))
    }

    @Test(
        "explicit command ids and direct headless dispatch cannot copy on any channel",
        arguments: [AgentStudioIPCChannel.debug, .stable, .beta])
    func ipcCannotCopySetupPrompt(channel: AgentStudioIPCChannel) async throws {
        let saved = Self.savedPasteboard()
        defer { Self.restorePasteboard(saved) }
        NSPasteboard.general.clearContents()
        let pasteboardReady = NSPasteboard.general.setString("setup-prompt-refusal-sentinel", forType: .string)
        try #require(pasteboardReady, "general pasteboard service unavailable before IPC refusal proof")
        let owner = RecordingWorkspaceIPCCommandHandler(currentWindowId: UUIDv7.generate())
        let harness = CommandAdapterHarness(channel: channel, workspaceCommandHandler: owner)
        let catalog = try await makeIPCCommandCatalogOffMain(from: harness.adapter, channel: channel)
        #expect(!catalog.commands.contains { $0.id.rawValue == "copyAgentSetupPrompt" })
        let request = IPCCommandExecutionRequest(
            commandId: .init(rawValue: "copyAgentSetupPrompt"), correlationId: UUIDv7.generate(),
            arguments: .noArguments)
        await #expect(throws: AppIPCCommandError(reason: .unsupportedCommand)) {
            try await harness.adapter.executeCommand(request, ownPaneAssertion: nil)
        }
        let outcome = await harness.commandDispatcher.dispatchHeadlessIPC(
            .init(
                command: .copyAgentSetupPrompt, arguments: .typedIPC(.noArguments),
                executionContext: .headlessIPC(admitsDebugTestingCommands: channel == .debug)))
        #expect(outcome == .unsupportedCommand)
        #expect(owner.headlessRequests.isEmpty)
        #expect(harness.shellCommandHandler.handledRequests.isEmpty)
        let clipboardUnchanged = NSPasteboard.general.string(forType: .string) == "setup-prompt-refusal-sentinel"
        #expect(clipboardUnchanged)
    }

    private static func savedPasteboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
    }

}
