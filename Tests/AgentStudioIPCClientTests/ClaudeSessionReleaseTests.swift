import AgentStudioPrimitives
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Running Claude release")
struct ClaudeSessionReleaseTests {
    @Test(
        "native layouts identify the release and other executables remain unknown",
        arguments: [
            ("/scratch/claude/versions/9.9.9", "9.9.9"),
            ("/scratch/.local/share/claude/versions/2.1.308", "2.1.308"),
            ("/usr/local/bin/node", "unknown"),
            ("/scratch/npm/claude", "unknown"),
            ("/scratch/claude/versions/9.9.9/claude", "unknown"),
            ("/scratch/claude/versions/", "unknown"),
            ("", "unknown"),
        ])
    func nativeReleasePath(row: (String, String)) {
        #expect(ClaudeSessionRelease.release(fromExecutablePath: row.0) == row.1)
    }

    @Test(
        "missing and malformed Claude pid never use an installed release",
        arguments: [nil, "", "bad", "0", "-1"] as [String?])
    func missingClaudePID(pid: String?) {
        var environment: [String: String] = [:]
        environment["CLAUDE_PID"] = pid
        #expect(ClaudeSessionRelease.current(environment: environment) == "unknown")
    }

    @Test("the running native executable remains identifiable after unlink and is unknown after exit")
    func runningReleaseSurvivesUnlink() async throws {
        let observed = try await Self.observeNativeProcess()
        #expect(observed.beforeUnlink == "9.9.9")
        #expect(observed.primaryPathUnavailable)
        #expect(observed.afterUnlink == "9.9.9")
        #expect(observed.wasRunningAfterUnlink, "fixture exit status: \(observed.exitCode)")
        #expect(observed.afterExit == "unknown")
    }

    private struct NativeProcessObservation: Sendable {
        let beforeUnlink: String
        let primaryPathUnavailable: Bool
        let afterUnlink: String
        let wasRunningAfterUnlink: Bool
        let exitCode: Int32
        let afterExit: String
    }

    private static func observeNativeProcess() async throws -> NativeProcessObservation {
        try await valueFromDedicatedThread {
            let root = FileManager.default.temporaryDirectory.appending(path: "claude-release-\(UUIDv7.generate())")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "claude/versions")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appending(path: "9.9.9")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: executable)
            let home = root.appending(path: "home")
            let claude = home.appending(path: ".claude")
            let codex = home.appending(path: ".codex")
            let cursor = home.appending(path: ".cursor")
            let environment = [
                "HOME": home.path, "CLAUDE_CONFIG_DIR": claude.path, "CODEX_HOME": codex.path, "PATH": "/usr/bin:/bin",
                "TMPDIR": root.path,
            ]
            // Even this non-provider child gets the same home-resolution preflight.
            let resolved = [
                ClaudeCodePackageCommand.resolvedConfigurationDirectory(
                    options: .init(configurationDirectoryPath: claude.path), environment: environment),
                CodexPackageInstaller.codexHome(explicitPath: codex.path, environment: environment),
                CursorPackageInstaller.cursorHome(explicitPath: cursor.path),
            ]
            guard
                resolved.allSatisfy({
                    $0?.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") == true
                })
            else {
                throw NativeProcessFailure.unconfinedHome
            }
            let process = Process()
            let input = Pipe()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.waitUntilExit() }
                try? input.fileHandleForReading.close()
            }
            process.executableURL = executable
            process.environment = environment
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try TestToolResolver.launch(process)
            let pid = process.processIdentifier
            let hookEnvironment = ["CLAUDE_PID": String(pid)]
            let before = ClaudeSessionRelease.current(environment: hookEnvironment)
            try FileManager.default.removeItem(at: executable)
            var pathBuffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let primaryCount = pathBuffer.withUnsafeMutableBytes { bytes -> Int32 in
                guard let address = bytes.baseAddress else { return 0 }
                return proc_pidpath(pid, address, UInt32(bytes.count))
            }
            let after = ClaudeSessionRelease.current(environment: hookEnvironment)
            let wasRunning = process.isRunning
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return .init(
                beforeUnlink: before, primaryPathUnavailable: primaryCount <= 0, afterUnlink: after,
                wasRunningAfterUnlink: wasRunning, exitCode: process.terminationStatus,
                afterExit: ClaudeSessionRelease.current(environment: hookEnvironment))
        }
    }
}

private enum NativeProcessFailure: Error { case unconfinedHome }
