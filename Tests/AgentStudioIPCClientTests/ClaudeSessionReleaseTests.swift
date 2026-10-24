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
        #expect(observed.exitCode == 0)
        #expect(observed.afterExit == "unknown")
    }

    @Test(
        "the mapped executable may follow many regions at any ASLR address",
        arguments: [0x1_0000_0000, 0x2_0000_0000] as [UInt64])
    func mappedExecutableBeyondSearchWindow(executableAddress: UInt64) {
        let executablePath = "/scratch/claude/versions/9.9.9"
        let regionCount = 12
        var requestedAddresses: [UInt64] = []
        let observed = ClaudeSessionRelease.regionExecutablePath(pid: 123) { pid, address in
            #expect(pid == 123)
            requestedAddresses.append(address)
            let regionIndex = requestedAddresses.count - 1
            guard regionIndex <= regionCount else { return nil }
            return Self.region(
                address: regionIndex == regionCount ? executableAddress : UInt64(regionIndex) * 0x4000,
                size: 0x4000,
                executablePath: regionIndex == regionCount ? executablePath : nil)
        }
        #expect(observed == executablePath)
        #expect(requestedAddresses == (0...regionCount).map { UInt64($0) * 0x4000 })
    }

    @Test("region lookup may return a mapping containing the requested address")
    func mappedExecutableContainsRequestedAddress() {
        let executablePath = "/scratch/claude/versions/9.9.9"
        var requestedAddresses: [UInt64] = []
        let observed = ClaudeSessionRelease.regionExecutablePath(pid: 123) { _, address in
            requestedAddresses.append(address)
            switch requestedAddresses.count {
            case 1: return Self.region(address: 0, size: 0x4000)
            case 2: return Self.region(address: 0x2000, size: 0x4000, executablePath: executablePath)
            default: return nil
            }
        }
        #expect(observed == executablePath)
        #expect(requestedAddresses == [0, 0x4000])
    }

    @Test(
        "region enumeration ends on a nonadvancing or overflowing region",
        arguments: [
            (UInt64(0), UInt64(0)), (0, 0x4000), (UInt64.max - 1, 2),
        ] as [(UInt64, UInt64)])
    func mappedExecutableRejectsInvalidProgress(regionBounds: (UInt64, UInt64)) {
        var requestCount = 0
        let observed = ClaudeSessionRelease.regionExecutablePath(pid: 123) { _, _ in
            requestCount += 1
            guard requestCount <= 2 else {
                Issue.record("Region enumeration queried past an invalid or retired region")
                return nil
            }
            return Self.region(address: regionBounds.0, size: regionBounds.1)
        }
        #expect(observed == nil)
        #expect(requestCount <= 2)
    }

    private static func region(address: UInt64, size: UInt64, executablePath: String? = nil) -> proc_regionwithpathinfo
    {
        var region = proc_regionwithpathinfo()
        region.prp_prinfo.pri_address = address
        region.prp_prinfo.pri_size = size
        if let executablePath {
            region.prp_prinfo.pri_protection = UInt32(VM_PROT_READ | VM_PROT_EXECUTE)
            withUnsafeMutableBytes(of: &region.prp_vip.vip_path) { bytes in
                bytes.copyBytes(from: executablePath.utf8)
            }
        }
        return region
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
            let environment = try nativeFixtureEnvironment(root: root)
            // A relocated system binary can be killed for an invalid platform signature before main.
            // Give only this disposable fixture its own signature so the test observes running code.
            let signer = Process()
            signer.executableURL = URL(filePath: "/usr/bin/codesign", directoryHint: .notDirectory)
            signer.arguments = ["--force", "--sign", "-", executable.path]
            signer.environment = environment
            signer.standardInput = FileHandle.nullDevice
            signer.standardOutput = FileHandle.nullDevice
            signer.standardError = FileHandle.standardError
            try TestToolResolver.launch(signer)
            signer.waitUntilExit()
            guard signer.terminationStatus == 0 else {
                throw NativeProcessFailure.fixtureSigningFailed(signer.terminationStatus)
            }
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.waitUntilExit() }
                try? input.fileHandleForReading.close()
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            }
            process.executableURL = executable
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try TestToolResolver.launch(process)
            try output.fileHandleForWriting.close()
            // Spawn completion does not mean the copied executable has reached its body.
            // Wait for cat's own reply before unlinking its code; EOF exposes an early exit.
            let readinessMarker = Data("agentstudio-native-ready\n".utf8)
            try input.fileHandleForWriting.write(contentsOf: readinessMarker)
            var readinessReply = Data()
            while readinessReply.count < readinessMarker.count {
                guard
                    let chunk = try output.fileHandleForReading.read(
                        upToCount: readinessMarker.count - readinessReply.count),
                    !chunk.isEmpty
                else { throw NativeProcessFailure.exitedBeforeReadiness }
                readinessReply.append(chunk)
            }
            guard readinessReply == readinessMarker else { throw NativeProcessFailure.invalidReadinessReply }
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

    private static func nativeFixtureEnvironment(root: URL) throws -> [String: String] {
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
        return environment
    }
}

private enum NativeProcessFailure: Error {
    case unconfinedHome
    case exitedBeforeReadiness
    case invalidReadinessReply
    case fixtureSigningFailed(Int32)
}
