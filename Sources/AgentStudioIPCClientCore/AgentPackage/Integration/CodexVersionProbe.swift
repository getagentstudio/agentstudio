import AgentStudioIPCTransport
import AgentStudioPrimitives
import Darwin
import Foundation

/// The version subprocess owns only a private temporary Codex home, never the
/// inspected provider home. Its stdout and exit signal share one call bound.
package enum CodexVersionProbe {
    package static func read(environment: [String: String], temporaryRoot: URL = FileManager.default.temporaryDirectory)
        -> String?
    {
        let home = temporaryRoot.appending(path: "agentstudio-codex-version-\(UUIDv7.generate())")
        guard mkdir(home.path, 0o700) == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: home) }
        var childEnvironment = environment
        childEnvironment["CODEX_HOME"] = home.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "--version"]
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        let exited = Pipe()
        process.standardOutput = output
        let exitWriter = exited.fileHandleForWriting
        process.terminationHandler = { _ in try? exitWriter.close() }
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? exited.fileHandleForReading.close()
            try? exitWriter.close()
        }
        do {
            let deadline = CallDeadline(limit: CLIPolicy.ordinaryCallLimit)
            try process.run()
            let bytes = try deadline.readInputToEnd(fileDescriptor: output.fileHandleForReading.fileDescriptor)
            _ = try deadline.readInputToEnd(fileDescriptor: exited.fileHandleForReading.fileDescriptor)
            guard process.terminationStatus == 0, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
            return parsedVersion(text)
        } catch {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return nil
        }
    }

    package static func parsedVersion(_ text: String) -> String? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0] == "codex-cli" else { return nil }
        let candidate = String(fields[1])
        let components = candidate.split(separator: ".")
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return candidate
    }
}
