import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Darwin process chain invoked command names")
struct DarwinProcessChainFactsReaderTests {
    @Test("a real sh shebang trampoline preserves the provider's shell election")
    func realHookScriptTrampolineChain() async throws {
        // Arrange: execute a script file so the kernel chooses its shebang interpreter.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-hook-chain-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hook.sh")
        try """
        #!/bin/sh
        /usr/bin/perl -e '$| = 1; print "$$\\n"; scalar <STDIN>;'
        exit $?

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        // Act: the child's PID handshake holds the real script alive until stdin closes.
        let observation = try await Self.observeHookScript(at: script)

        // Assert after teardown: BSD facts retain the trampoline's actual kernel name.
        let wrapper = try #require(observation.wrapper)
        #expect(["sh", "bash", "dash"].contains(wrapper.executableName))
        #expect(wrapper.incarnation.pid == observation.scriptPID)
        #expect(wrapper.parentPID == getpid())
        #expect(observation.peer?.parentPID == observation.scriptPID)
        #expect(observation.terminationStatus == 0)
        let expectedShell = try #require(observation.expectedShell)
        guard case .agentShell(let shell, _) = observation.chain else {
            Issue.record("Real shebang wrapper \(wrapper.executableName) failed election: \(observation.chain)")
            return
        }
        #expect(shell == expectedShell)
        #expect(observation.chain.isMainEligible(terminalLeader: expectedShell))
    }

    @Test("unclassified paths retain the argv-zero launcher contract", arguments: ["claude", "agent"])
    func invokedCommandName(name: String) async throws {
        // Arrange: both children execute sleep; only their invocation names differ.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstudio-process-chain-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandPath = directory.appendingPathComponent(name).path
        if name == "claude" {
            try FileManager.default.createSymbolicLink(atPath: commandPath, withDestinationPath: "/bin/sleep")
        }

        // Act: spawn returns after exec. No readiness delay or polling is needed.
        let observation = try await valueFromDedicatedThread {
            try Self.observeOwnedChild(executable: name == "claude" ? commandPath : "/bin/sleep", argvZero: commandPath)
        }

        // Assert after the child is terminated and reaped, including when the reader is wrong.
        #expect(observation.kernelName == "sleep")
        #expect(observation.argumentsReadError == nil, "KERN_PROCARGS2 errno: \(observation.argumentsReadError ?? 0)")
        let facts = try #require(observation.facts)
        #expect(facts.executableName == name)
        #expect(facts.incarnation.pid == observation.childPID)
        #expect(facts.parentPID == getpid())
        #expect(observation.terminationResult == 0)
        #expect(observation.reapedPID == observation.childPID)
        #expect(observation.waitStatus & 0x7f == SIGKILL)
    }

    private struct ChildObservation: Sendable {
        let facts: ProcessChainProcessFacts?
        let kernelName: String?
        let argumentsReadError: Int32?
        let childPID: pid_t
        let terminationResult: Int32
        let reapedPID: pid_t
        let waitStatus: Int32
    }

    private enum ChildSpawnError: Error {
        case allocationFailed
        case spawnFailed(Int32)
        case missingPeerHandshake
        case unavailablePeerVersion
    }

    private struct HookScriptObservation: Sendable {
        let wrapper: ProcessChainProcessFacts?
        let peer: ProcessChainProcessFacts?
        let expectedShell: ZmxProcessIncarnation?
        let chain: ProcessChainObservation
        let scriptPID: pid_t
        let terminationStatus: Int32
    }

    private static func observeHookScript(at script: URL) async throws -> HookScriptObservation {
        try await valueFromDedicatedThread {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = script
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            // Close the parent's duplicate write end so process exit also ends a missing handshake.
            output.fileHandleForWriting.closeFile()
            defer {
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                input.fileHandleForReading.closeFile()
                output.fileHandleForReading.closeFile()
            }
            var handshake = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }
                handshake.append(byte)
            }
            guard let text = String(data: handshake, encoding: .utf8), let peerPID = Int32(text), peerPID > 0 else {
                throw ChildSpawnError.missingPeerHandshake
            }
            let reader = DarwinProcessChainFactsReader()
            guard let peerVersion = reader.pidVersion(of: peerPID) else {
                throw ChildSpawnError.unavailablePeerVersion
            }
            let wrapper = reader.bsdInfo(of: process.processIdentifier)
            let peer = reader.bsdInfo(of: peerPID)
            let expectedShell = reader.bsdInfo(of: getppid())?.incarnation
            let chain = DarwinProcessChainReader(facts: HookScriptProviderFacts(providerPID: getpid()), readLimit: 20)
                .observe(peer: .init(pid: peerPID, pidVersion: peerVersion), provider: "codex")
            // EOF releases the peer, and the script waits for it before reporting exit.
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return .init(
                wrapper: wrapper, peer: peer, expectedShell: expectedShell, chain: chain,
                scriptPID: process.processIdentifier, terminationStatus: process.terminationStatus)
        }
    }

    private static func observeOwnedChild(executable: String, argvZero: String) throws -> ChildObservation {
        guard let command = strdup(argvZero) else { throw ChildSpawnError.allocationFailed }
        defer { free(command) }
        // This keeps the owned fixture alive until SIGKILL; no verdict waits for this duration.
        guard let duration = strdup("86400") else { throw ChildSpawnError.allocationFailed }
        defer { free(duration) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [command, duration, nil]
        var childPID: pid_t = 0
        let spawnResult = posix_spawn(&childPID, executable, nil, nil, &arguments, environ)
        guard spawnResult == 0 else { throw ChildSpawnError.spawnFailed(spawnResult) }

        // Nothing below throws before cleanup. All blocking work stays on this dedicated thread.
        let reader = DarwinProcessChainFactsReader()
        let rawFacts = reader.bsdInfo(of: childPID)
        let facts = rawFacts.flatMap { raw in
            reader.executableName(of: raw).map {
                ProcessChainProcessFacts(incarnation: raw.incarnation, parentPID: raw.parentPID, executableName: $0)
            }
        }
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let informationRead = proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &information, informationSize)
        let kernelName =
            informationRead == informationSize
            ? withUnsafeBytes(of: information.pbi_name) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            } : nil
        // Independently distinguish sandbox denial from a reader that chooses the wrong name.
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, childPID]
        var buffer = [UInt8](repeating: 0, count: Int(ARG_MAX))
        var bufferSize = buffer.count
        let readResult = buffer.withUnsafeMutableBytes { sysctl(&query, 3, $0.baseAddress, &bufferSize, nil, 0) }
        let argumentsReadError = readResult == 0 ? nil : errno
        let terminationResult = kill(childPID, SIGKILL)
        var waitStatus: Int32 = 0
        let reapedPID = waitpid(childPID, &waitStatus, 0)
        return .init(
            facts: facts, kernelName: kernelName, argumentsReadError: argumentsReadError,
            childPID: childPID, terminationResult: terminationResult, reapedPID: reapedPID, waitStatus: waitStatus)
    }
}

/// Only provider identity is substituted; the script, peer and every BSD continuity read stay real.
private struct HookScriptProviderFacts: ProcessChainFactsReading {
    let providerPID: pid_t
    private let reader = DarwinProcessChainFactsReader()

    func pidVersion(of pid: Int32) -> UInt32? { reader.pidVersion(of: pid) }
    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? { reader.bsdInfo(of: pid) }
    func executableName(of process: ProcessChainProcessFacts) -> String? {
        process.incarnation.pid == providerPID ? "codex" : reader.executableName(of: process)
    }
}
