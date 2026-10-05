import AgentStudioAppIPC
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Real app catalogs are read as served metadata; raw command requests are
/// compiled independently and the app owns their interpretation and admission.
@MainActor
@Suite(
    "App IPC command catalog discovery", .serialized, SessionsVerticalHarnessTrait(providerProfiles: .defaultProfiles))
struct AgentStudioIPCCommandCatalogDiscoveryTests {
    @Test("the live debug catalog supplies metadata while raw command framing uses the compiled envelope")
    func liveDebugCatalogDecodes() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let bytes = try await harness.resultData(method: "command.list", params: .object([:]))
        let catalog = try JSONDecoder().decode(IPCCommandCatalogResult.self, from: bytes)
        #expect(catalog.commands.contains { $0.id.rawValue == "showReposSidebar" })
        let correlation = UUIDv7.generate()
        let descriptor = try IPCAnyMethodDescriptor(erasing: IPCCommandMethodComposition.compiledExecute())
        let request = IPCRawCommandExecutionRequest(
            commandId: .init(rawValue: "showReposSidebar"), correlationId: correlation,
            arguments: ["kind": "workspaceWindow", "workspaceWindowId": harness.workspaceWindowId.uuidString])
        let invocation = try IPCDescriptorInvocation(
            descriptor: descriptor,
            normalizedParameters: descriptor.normalizeParameters(JSONEncoder().encode(request)), presentation: .tooling)
        #expect(invocation.descriptor.metadata.name == "command.execute")
        let framed = try JSONDecoder().decode(
            IPCRawCommandExecutionRequest.self, from: invocation.normalizedParameters.data)
        #expect(framed == request)
    }

    @Test("the App's advertised command descriptors preserve their validated composition")
    func appCommandDescriptorsPreserveTheirComposition() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()

        let methodCatalog = try await harness.methodCatalog()
        let advertisedList = try #require(
            methodCatalog.methods.first { $0.name == "command.list" })
        let commandListResult = try await harness.resultData(
            method: "command.list", params: .object([:]))
        let catalog = try JSONDecoder().decode(
            IPCCommandCatalogResult.self,
            from: try advertisedList.resultSchema.normalize(commandListResult))

        // Names the command that drifts instead of failing on the whole
        // catalog: one command with a defaulted URL argument broke all 146.
        var driftedCommandIdentifiers: [String] = []
        for command in catalog.commands {
            let recomposed = try IPCCommandDescriptorFactory.make(
                IPCCommandDescriptorInput(
                    id: command.id,
                    title: command.title,
                    description: command.description,
                    exposure: command.exposure,
                    executionMode: command.executionMode,
                    argumentVariants: command.argumentVariants,
                    requiredPrivileges: Set(command.requiredPrivileges),
                    dataScope: command.dataScope,
                    allowedTargetKinds: Set(command.allowedTargetKinds),
                    resultVariants: command.resultVariants,
                    examples: command.examples,
                    agentEligibility: command.agentEligibility
                ))
            if recomposed != command { driftedCommandIdentifiers.append(command.id.rawValue) }
        }

        #expect(catalog.commands.count == 154)
        #expect(driftedCommandIdentifiers.isEmpty, "drifted: \(driftedCommandIdentifiers)")
    }
    @Test("the bundled CLI reaches the server for command.list and command.execute")
    func bundledCLIReachesTheServerForCommands() async throws {
        let harness = try await #require(SessionsVerticalHarnessContext.current).freshPanePair()
        let cli = try CatalogCommandLineHelper.commandLineExecutableURL()

        let environment = [
            "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
            "AGENTSTUDIO_PANE_TOKEN": harness.token.rawValue,
            "PATH": "/usr/bin:/bin",
        ]
        let listing = try await CatalogCommandLineHelper.runCommandLineInterface(
            executableURL: cli, arguments: ["command.list"], environment: environment)

        #expect(listing.exitCode == 0, "command.list stderr: \(listing.standardError)")
        #expect(listing.standardOutput.contains("showReposSidebar"))

        let executionPayload = """
            {"commandId":"showReposSidebar","correlationId":"\(UUIDv7.generate().uuidString)",            "arguments":{"kind":"workspaceWindow",            "workspaceWindowId":"\(harness.workspaceWindowId.uuidString)"}}
            """
        let execution = try await CatalogCommandLineHelper.runCommandLineInterface(
            executableURL: cli,
            arguments: ["command.execute", "--json", executionPayload],
            environment: environment)

        // Only the app's command owner produces `stateUnavailable` on
        // `$.commandId`, so this answer proves the CLI sent its compiled raw envelope
        // and the frame reached the server. Applying a
        // sidebar command needs a real window this headless harness does not
        // build; the decode path it exercises is what round 2 could not reach.
        #expect(execution.standardError.contains("\"reason\":\"stateUnavailable\""))
        #expect(execution.standardError.contains("\"fieldPath\":\"$.commandId\""))
    }

}

@MainActor
@Suite("App IPC stable-channel catalog refusal", .serialized, PaneAgentHarnessTrait())
struct AgentStudioIPCStableCatalogRefusalTests {
    /// Stable-channel names the bundled CLI must send for the app to refuse:
    /// commands whose argument variants the stable union may not carry, and a
    /// debug-only method.
    enum HiddenStableName: String, CaseIterable, Sendable {
        case splitRight
        case closeTab
        case newTab
        case paneFocus = "pane.focus"
    }

    @Test(
        "the bundled CLI takes a pane agent's hidden stable name to the app's named refusal",
        arguments: HiddenStableName.allCases
    )
    func bundledCLIReachesTheAppForAHiddenStableName(name: HiddenStableName) async throws {
        let harness = try #require(PaneAgentHarnessContext.current).harness
        let cli = try CatalogCommandLineHelper.commandLineExecutableURL()
        let environment = [
            "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
            "AGENTSTUDIO_PANE_TOKEN": try harness.agentToken(boundTo: harness.mainPaneId).rawValue,
            "PATH": "/usr/bin:/bin",
        ]
        let before = harness.workspaceFacts()

        let execution = try await CatalogCommandLineHelper.runCommandLineInterface(
            executableURL: cli, arguments: try cliArguments(for: name, harness: harness), environment: environment)

        // None of these is in the stable catalog. The CLI must still send it,
        // typed by its compiled contract, so the app, not the client, answers
        // with the named refusal.
        #expect(execution.exitCode != 0)
        #expect(execution.standardError.contains("\"reason\":\"notYetAllowed\""), "\(execution.standardError)")
        #expect(
            execution.standardError.contains("\"refusedName\":\"\(name.rawValue)\""), "\(execution.standardError)")
        #expect(!execution.standardError.contains("\"reason\":\"unknownCommand\""))
        #expect(!execution.standardError.contains("\"reason\":\"unknownMethod\""))
        #expect(harness.workspaceFacts() == before)
    }

    private func cliArguments(for name: HiddenStableName, harness: PaneAgentControlHarness) throws -> [String] {
        let arguments: IPCCommandArguments
        switch name {
        case .paneFocus:
            return ["pane.focus", "--handle", "self"]
        case .splitRight:
            arguments = try harness.paneArguments(harness.mainPaneId)
        case .closeTab:
            let tabId = try #require(harness.store.tabLayoutAtom.activeTabId)
            arguments = .tab(IPCTabCommandArguments(workspaceWindowId: harness.workspaceWindowId, tabId: tabId))
        case .newTab:
            arguments = .newTab(
                IPCNewTabCommandArguments(workspaceWindowId: harness.workspaceWindowId, launchDirectory: nil))
        }
        let command = try #require(AppCommand(rawValue: name.rawValue))
        let payload = try #require(
            String(bytes: try JSONEncoder().encode(harness.command(command, arguments: arguments)), encoding: .utf8))
        return ["command.execute", "--json", payload]
    }

}

@MainActor
private enum CatalogCommandLineHelper {
    static func commandLineExecutableURL() throws -> URL {
        let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot =
            testFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolvedBuildDirectory =
            buildDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: buildDirectory)
            : projectRoot.appending(path: buildDirectory)
        return resolvedBuildDirectory.appending(path: "debug/agentstudio-cli")
    }

    /// Runs off the MainActor and writes both streams to files.
    ///
    /// The harness server dispatches commands on the MainActor, so blocking it
    /// here would deadlock against the very request the CLI is making. Files
    /// rather than pipes because `command.list` returns far more than a pipe
    /// buffer holds, and a single-threaded pipe drain would stall on it.
    nonisolated static func runCommandLineInterface(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (exitCode: Int32, standardOutput: String, standardError: String) {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "as-cli-out-\(UUIDv7.generate().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory
            .appending(path: "as-cli-err-\(UUIDv7.generate().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let outputHandle = try FileHandle(forWritingTo: outputURL)
                    let errorHandle = try FileHandle(forWritingTo: errorURL)
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    process.environment = environment
                    process.standardOutput = outputHandle
                    process.standardError = errorHandle
                    try process.run()
                    process.waitUntilExit()
                    try? outputHandle.close()
                    try? errorHandle.close()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return (
            exitCode,
            String(data: (try? Data(contentsOf: outputURL)) ?? Data(), encoding: .utf8) ?? "",
            String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? ""
        )
    }
}

extension SessionsVerticalHarness {
    /// The advertised method catalog, read over the socket exactly as the CLI
    /// reads it.
    func methodCatalog() async throws -> IPCMethodCatalogResult {
        try JSONDecoder().decode(
            IPCMethodCatalogResult.self,
            from: try await resultData(method: "system.capabilities", params: .object([:])))
    }

    func resultData(method: String, params: JSONValue) async throws -> Data {
        let message = try JSONRPCCodec.decodeResponse(
            try await responseFrame(method: method, params: params))
        #expect(message.error == nil, "\(method) failed: \(String(describing: message.error))")
        return try JSONEncoder().encode(try #require(message.result))
    }
}
