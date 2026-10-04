import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Provider permission hook script arguments")
struct ProviderPermissionHookScriptTests {
    @Test("Owned shell entry points forward wait policy and provider version", arguments: ["claude", "codex"])
    func scriptForwardsPermissionPolicy(provider: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "permission hook argv \(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appending(path: "argument recorder.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appending(
            path:
                "Sources/AgentStudio/Resources/AgentPackage/providers/\(provider)/hooks/agentstudio-\(provider)-hook.sh"
        )
        var arguments = [script.path, "PermissionRequest"]
        var expected = ["hook", provider, "PermissionRequest"]
        if provider == "claude" {
            arguments += ["2.1.286"]
            expected += ["--provider-version", "2.1.286"]
        }
        arguments += ["--permission-policy", "wait"]
        expected += ["--permission-policy", "wait"]
        let output = try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: arguments,
            environment: ["AGENTSTUDIO_CLI": stub.path])
        #expect(output.terminationStatus == 0)
        let argumentsText = try #require(String(data: output.standardOutput, encoding: .utf8))
        #expect(argumentsText.split(separator: "\n").map(String.init) == expected)
        #expect(output.standardError.isEmpty)
    }
}
