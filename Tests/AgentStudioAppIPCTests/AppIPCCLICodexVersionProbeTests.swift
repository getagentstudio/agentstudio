import AgentStudioIPCTransport
import CryptoKit
import Foundation
import Testing

/// Local provider-runtime proof. CI exercises the inspector and probe failure
/// contracts without requiring a globally installed Codex release.
@Suite("Codex version probe isolation", .serialized)
struct AppIPCCLICodexVersionProbeTests {
    @Test(
        "status probes real Codex 0.163 in a private home and cleans it",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_CODEX_PROBE_EXECUTABLE"] != nil))
    func realCodexVersionProbeIsIsolated() async throws {
        let actualCodex = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_CODEX_PROBE_EXECUTABLE"])
        let fixture = try PackageSubprocessFixture()
        defer { fixture.dispose() }
        let binaryDirectory = fixture.root.appending(path: "bin")
        let capture = fixture.root.appending(path: "probe-receipt")
        for directory in [binaryDirectory, capture] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let wrapper = binaryDirectory.appending(path: "codex")
        let body = """
            #!/bin/sh
            printf '%s\\n' "$CODEX_HOME" > "$PROBE_CAPTURE/home"
            /usr/bin/stat -f %Lp "$CODEX_HOME" > "$PROBE_CAPTURE/mode"
            printf '%s\\n' "$HOME" "$CLAUDE_CONFIG_DIR" "$UNCHANGED_SENTINEL" > "$PROBE_CAPTURE/inherited"
            "$ACTUAL_CODEX" "$@" > "$PROBE_CAPTURE/version"
            probe_exit=$?
            /bin/cat "$PROBE_CAPTURE/version"
            exit "$probe_exit"

            """
        try Data(body.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        var environment = fixture.environment
        environment["PATH"] = binaryDirectory.path + ":/usr/bin:/bin"
        environment["ACTUAL_CODEX"] = actualCodex
        environment["PROBE_CAPTURE"] = capture.path
        environment["UNCHANGED_SENTINEL"] = "unchanged"
        environment["TMPDIR"] = "/private/tmp"
        let executable = try cliExecutableURL()
        let installation = try await runCLI(
            executableURL: executable,
            arguments: fixture.preflight(arguments: ["package", "install", "codex"]),
            environment: environment, currentDirectoryURL: fixture.root)
        try #require(installation.exitCode == 0)
        let providerHome = fixture.root.appending(path: "home/.codex")
        let before = try manifest(providerHome)
        let status = try await runCLI(
            executableURL: executable,
            arguments: fixture.preflight(arguments: ["package", "status", "codex", "--json"]),
            environment: environment, currentDirectoryURL: fixture.root)
        let after = try manifest(providerHome)
        let added = after.keys.filter { before[$0] == nil }.sorted()
        #expect(after == before, "status added provider paths: \(added)")
        #expect(added.isEmpty)
        #expect(status.exitCode == 1)
        let value = try JSONDecoder().decode(JSONValue.self, from: status.standardOutput)
        guard case .object(let fields) = value else {
            Issue.record("status response was not an object")
            return
        }
        #expect(fields["verdict"] == .string("notTrusted"))
        #expect(status.standardError.isEmpty)
        let home = try String(contentsOf: capture.appending(path: "home"), encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: home))
        #expect(!home.hasPrefix(fixture.root.path + "/"))
        #expect(
            try String(contentsOf: capture.appending(path: "mode"), encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines) == "700")
        #expect(try String(contentsOf: capture.appending(path: "version"), encoding: .utf8) == "codex-cli 0.163.0\n")
        #expect(
            try String(contentsOf: capture.appending(path: "inherited"), encoding: .utf8)
                == "\(try #require(environment["HOME"]))\n\(try #require(environment["CLAUDE_CONFIG_DIR"]))\nunchanged\n"
        )
    }

    private func manifest(_ root: URL) throws -> [String: String] {
        try Dictionary(
            uniqueKeysWithValues: FileManager.default.subpathsOfDirectory(atPath: root.path).map { path in
                let url = root.appending(path: path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let value: String
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory: value = "directory"
                case .typeSymbolicLink:
                    value = "symlink:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                default:
                    value = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                }
                return (path, value)
            })
    }
}
