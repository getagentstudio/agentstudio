import AgentStudioIPCTransport
import Foundation
import Testing

@Suite("CLI integration status", .serialized)
struct AppIPCCLIPackageStatusTests {
    @Test("status is a local read-only verb with structured output", arguments: ["claude", "codex", "cursor"])
    func packageStatusIsLocallyAvailable(provider: String) async throws {
        let fixture = try PackageSubprocessFixture()
        defer { fixture.dispose() }
        let arguments = try fixture.preflight(arguments: ["package", "status", provider, "--json"])
        let output = try await runCLI(
            executableURL: cliExecutableURL(), arguments: arguments,
            environment: fixture.environment, currentDirectoryURL: fixture.root)
        #expect(output.exitCode == 1)
        let value = try JSONDecoder().decode(JSONValue.self, from: output.standardOutput)
        guard case .object(let fields) = value else {
            Issue.record("status did not return an object")
            return
        }
        #expect(fields["provider"] == .string(provider))
        #expect(fields["verdict"] == .string("notInstalled"))
        #expect(output.standardError.isEmpty)
    }
}
