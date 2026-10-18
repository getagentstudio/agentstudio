import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioTestSupport

@Suite("Cursor hook script process")
struct CursorHookScriptProcessTests {
    @Test(
        "the shipped Cursor script stays silent without a CLI or running app",
        arguments: ["absent", "missing", "nonexecutable", "appDown"])
    func scriptSilence(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "as-cursor-script-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = project.appending(
            path: "Sources/AgentStudio/Resources/AgentPackage/providers/cursor/hooks/agentstudio-cursor-hook.sh")
        let input = root.appending(path: "payload.json")
        try Data(#"{"conversation_id":"fixture","generation_id":"turn"}"#.utf8).write(to: input)
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }
        var environment = [
            "AGENTSTUDIO_IPC_SOCKET": "/tmp/as-cursor-down-\(UUIDv7.generate().uuidString.suffix(12)).sock",
            "AGENTSTUDIO_PANE_TOKEN": "fixture",
            "AGENTSTUDIO_PANE_ID": UUIDv7.generate().uuidString,
            "AGENTSTUDIO_WORKSPACE_ID": UUIDv7.generate().uuidString,
        ]
        switch scenario {
        case "missing": environment["AGENTSTUDIO_CLI"] = root.appending(path: "missing-cli").path
        case "nonexecutable":
            let cli = root.appending(path: "nonexecutable")
            try Data("not executable".utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cli.path)
            environment["AGENTSTUDIO_CLI"] = cli.path
        case "appDown": environment["AGENTSTUDIO_CLI"] = try cliExecutableURL().path
        default: break
        }
        let result = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, "beforeSubmitPrompt"],
            environment: environment, standardInput: inputHandle)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
    }
}
