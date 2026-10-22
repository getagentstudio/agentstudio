import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Real CLI agent help", .serialized)
struct CLIAgentHelpScriptTests {
    @Test("help lists every entry summary and eligibility without an app connection")
    func helpIsTheOfflineAgentEntryPoint() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["help"])
        #expect(output.process.terminationStatus == 0)
        #expect(output.process.standardError.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardOutput, encoding: .utf8))
        for entry in IPCBuiltInMethodIndex().entries {
            let line = try #require(text.split(separator: "\n").first { $0.contains("\(entry.name) — ") })
            #expect(line.contains(entry.summary))
            #expect(
                ["[agent: own pane]", "[agent: read-only]", "[agent: not yet allowed]"].contains { line.hasSuffix($0) })
        }
        #expect(!text.contains("Discovery: agentstudio system.capabilities"))
        #expect(text.contains("Method help: agentstudio <method> --help"))
    }

    @Test("offline help includes command and discovery envelopes with conditional command eligibility")
    func helpIncludesEveryCallableEnvelope() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["help"])
        #expect(output.process.terminationStatus == 0)
        #expect(output.process.standardError.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardOutput, encoding: .utf8))
        for method in ["command.execute", "command.list", "system.capabilities"] {
            #expect(text.split(separator: "\n").contains { $0.hasPrefix("  \(method) — ") })
        }
        if let execution = text.split(separator: "\n").first(where: { $0.hasPrefix("  command.execute — ") }) {
            #expect(execution.contains("command"))
            #expect(execution.contains("conditional") || execution.contains("depends"))
        }
    }

    @Test("raw command help is offline and shows command id, argument syntax and one example")
    func rawCommandExecutionHelpIsDiscoverable() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["command.execute", "--help"])
        #expect(output.process.terminationStatus == 0)
        #expect(output.process.standardError.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardOutput, encoding: .utf8))
        #expect(text.contains("--command-id"))
        #expect(text.contains("--arg"))
        #expect(text.contains("key=value"))
        let examples = text.split(separator: "\n").filter {
            $0.contains("agentstudio command.execute") && !$0.contains("Usage:")
        }
        #expect(examples.count == 1)
    }

    @Test("unknown command-method spelling suggests the same complete offline name inventory")
    func commandMethodSuggestionIsDiscoverable() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["command.excute"])
        #expect(output.process.terminationStatus != 0)
        #expect(output.process.standardOutput.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardError, encoding: .utf8))
        #expect(text.contains("agentstudio help"))
        #expect(text.contains("command.execute"))
    }

    @Test("method help has its arguments and one example from that descriptor")
    func methodHelpShowsOneExistingExample() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["pane.split", "--help"])
        #expect(output.process.terminationStatus == 0)
        #expect(output.process.standardError.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardOutput, encoding: .utf8))
        #expect(text.contains("--handle"))
        #expect(text.contains("--direction"))
        let examples = text.split(separator: "\n").filter {
            $0.contains("agentstudio pane.split") && !$0.contains("Usage:")
        }
        #expect(examples.count == 1)
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let entry = try #require(IPCBuiltInMethodIndex().entry(named: "pane.split"))
        let descriptor = try entry.makeRepresentation(inputs: inputs).erasedDescriptor
        let example = try #require(descriptor.metadata.examples.first)
        let data = try JSONEncoder().encode(example)
        let document = try JSONSerialization.jsonObject(with: data)
        let fields = try #require(document as? [String: Any])
        let parameters = try #require(fields["parameters"] as? [String: Any])
        let handle = try #require(parameters["handle"] as? String)
        let direction = try #require(parameters["direction"] as? String)
        if let printed = examples.first {
            #expect(printed.contains(handle))
            #expect(printed.contains(direction))
        }
    }

    @Test("unknown method names help and a close entry without connecting or naming capabilities")
    func unknownMethodGuidesAnAgentLocally() async throws {
        let output = try await runOfflineHelpProcess(arguments: ["pane.splt"])
        #expect(output.process.terminationStatus != 0)
        #expect(output.process.standardOutput.isEmpty)
        #expect(output.connections == 0)
        let text = try #require(String(data: output.process.standardError, encoding: .utf8))
        let document = try JSONSerialization.jsonObject(with: output.process.standardError)
        let fields = try #require(document as? [String: Any])
        #expect(fields["reason"] as? String == "unknownMethod")
        #expect(fields["fieldPath"] as? String == "$.method")
        #expect(text.contains("agentstudio help"))
        #expect(text.contains("pane.split"))
        #expect(!text.contains("system.capabilities"))
        let names = IPCBuiltInMethodIndex().entries.map(\.name)
        let suggestions = names.filter { text.contains($0) }
        #expect(!suggestions.isEmpty)
        #expect(suggestions.count <= 3)
    }

    @Test("the bundled skill teaches offline help before the seven pane verbs")
    func bundledSkillNamesTheDiscoveryEntryPoints() throws {
        let skill = Self.repositoryRoot.appending(path: "Sources/AgentStudio/Resources/AgentPackage/skills/agentstudio")
        let text = try String(contentsOf: skill.appending(path: "SKILL.md"), encoding: .utf8)
        // These paths and examples come from the reviewed ba54fd8de skill,
        // whose root introduces offline help and routes to bundled references.
        let expectedReferences: Set<String> = [
            "references/worktrees.md", "references/pane-communication.md", "references/pane-context.md",
            "references/commands-and-ipc.md", "references/panes-and-terminals.md",
            "references/worktree-recovery.md", "references/recovery.md",
        ]
        let pattern = try NSRegularExpression(pattern: #"references/[A-Za-z0-9._/-]+[.]md"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let paths = try matches.map { match in
            String(text[try #require(Range(match.range, in: text))])
        }
        #expect(Set(paths) == expectedReferences)
        let firstReference = try #require(matches.first).range.location
        let help = try #require(text.range(of: "\"$AS_CLI\" --help"))
        let offline = try #require(text.range(of: "Local help works without the app"))
        #expect(NSRange(help, in: text).location < firstReference)
        #expect(NSRange(offline, in: text).location < firstReference)

        var references: [String: String] = [:]
        for path in Set(paths) {
            let bundledFile = skill.appending(path: path)
            var isDirectory: ObjCBool = false
            try #require(
                FileManager.default.fileExists(atPath: bundledFile.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue, "Unresolved bundled skill reference: \(path)")
            references[path] = try String(contentsOf: bundledFile, encoding: .utf8)
        }
        let commands = try #require(references["references/commands-and-ipc.md"])
        let methodHelp = try #require(commands.range(of: "\"$AS_CLI\" command.execute --help"))
        #expect(commands.contains("known `METHOD --help` read the compiled local contracts without connecting"))
        for example in ["help --live", "system.capabilities", "command.list", "system.identify"] {
            let commandExample = try #require(commands.range(of: "\"$AS_CLI\" \(example)"))
            #expect(methodHelp.lowerBound < commandExample.lowerBound)
        }
        let linkedText = references.values.joined(separator: "\n")
        for verb in ["notify", "ask", "withdraw", "answers", "line", "title", "pane"] {
            #expect(
                linkedText.contains("\"$AS_CLI\" \(verb) ") || linkedText.contains("\"$AS_CLI\" \(verb)\n"),
                "No friendly \(verb) example in the root's bundled references")
        }
        #expect(!text.contains("## The four calls"))
        #expect(!linkedText.contains("## The four calls"))
    }

    fileprivate static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}

private struct OfflineHelpProcessObservation: Sendable {
    let process: ExitedProcessOutput
    let connections: Int
}

private final class OfflineHelpConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private func runOfflineHelpProcess(arguments: [String]) async throws -> OfflineHelpProcessObservation {
    guard let buildPath = ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"] else {
        throw OfflineHelpFixtureError.missingBuildPath
    }
    let buildURL =
        buildPath.hasPrefix("/")
        ? URL(fileURLWithPath: buildPath) : CLIAgentHelpScriptTests.repositoryRoot.appending(path: buildPath)
    let executable = buildURL.appending(path: "debug/agentstudio-cli")
    let socketPath = "/tmp/agent-help-\(UUIDv7.generate().uuidString).sock"
    let listener = UnixSocketListener(endpoint: UnixSocketEndpoint(path: socketPath))
    let counter = OfflineHelpConnectionCounter()
    try listener.start { connection in
        counter.record()
        connection.close()
    }
    let output: ExitedProcessOutput
    do {
        output = try await runProcessToExit(
            executableURL: executable, arguments: arguments,
            environment: [
                "AGENTSTUDIO_CLI": executable.path, "AGENTSTUDIO_PANE_TOKEN": "help-fixture-token",
                "AGENTSTUDIO_IPC_SOCKET": socketPath,
            ])
    } catch {
        await valueFromDedicatedThread { listener.stop() }
        try? FileManager.default.removeItem(atPath: socketPath)
        throw error
    }
    await valueFromDedicatedThread { listener.stop() }
    try? FileManager.default.removeItem(atPath: socketPath)
    return OfflineHelpProcessObservation(process: output, connections: counter.value)
}

private enum OfflineHelpFixtureError: Error { case missingBuildPath }
