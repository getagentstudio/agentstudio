import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Darwin process chain invoked command names")
struct DarwinProcessChainFactsReaderTests {
    @Test("real launcher names come from argv zero rather than the kernel executable", arguments: ["claude", "agent"])
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
        let facts = DarwinProcessChainFactsReader().bsdInfo(of: childPID)
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
