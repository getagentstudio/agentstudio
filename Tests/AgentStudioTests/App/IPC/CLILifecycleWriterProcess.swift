import AgentStudioPrimitives
import AgentStudioTestHarness
import Foundation
import Synchronization

enum LifecycleProcessFixtureFailure: Error { case buildDirectoryMissing, prematureReadyEOF }

/// Owns only the child it starts; a pipe EOF closes the pre-commit hold proof.
final class CLILifecycleWriterProcess: @unchecked Sendable {
    struct Output: Sendable {
        let status: Int32
        let text: String
    }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let facts: FactRecorder<UUID, Int32>
    private let scope = UUIDv7.generate()
    private let joined = Mutex<Output?>(nil)

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        let source = LocalFactSource<UUID, Int32>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "CLI process exit \($0)" },
                isClosing: { _, _ in true }))
        facts = try source.attach()
        let scope = scope
        process.terminationHandler = { source.sink(scope, $0.terminationStatus) }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try output.fileHandleForWriting.close()
    }

    func expectPrecommitHold() async throws -> String {
        let reader = output.fileHandleForReading
        let bytes = try await valueFromDedicatedThread {
            var bytes = Data()
            while bytes.count < 6 {
                guard let next = try reader.read(upToCount: 6 - bytes.count), !next.isEmpty else {
                    throw LifecycleProcessFixtureFailure.prematureReadyEOF
                }
                bytes.append(next)
            }
            return bytes
        }
        guard bytes == Data("ready\n".utf8) else { throw LifecycleProcessFixtureFailure.prematureReadyEOF }
        return String(bytes: bytes, encoding: .utf8) ?? "<non-UTF8 ready bytes>"
    }

    func releasePrecommitHold(payload: Data) async throws {
        let writer = input.fileHandleForWriting
        try await valueFromDedicatedThread {
            try writer.write(contentsOf: payload)
            try writer.close()
        }
    }

    func finish() async throws -> Output {
        if let result = joined.withLock({ $0 }) { return result }
        let status = try await facts.expectNext(in: scope, where: { _ in true }, "owned lifecycle writer exit")
        let reader = output.fileHandleForReading
        let text = await valueFromDedicatedThread {
            String(bytes: reader.readDataToEndOfFile(), encoding: .utf8) ?? "<non-UTF8 CLI output>"
        }
        let result = Output(status: status, text: text)
        joined.withLock { $0 = result }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try await facts.finish()
        return result
    }

    func stop() async {
        if process.isRunning { process.terminate() }
        _ = try? await finish()
    }
}
