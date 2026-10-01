import Foundation

/// A process freezes its developer-selected tools once. The normal receipt lets
/// CI compare actual executable identities with Apple's shared selector aliases;
/// different path strings alone do not prove different executable identities.
package struct ResolvedTestTools: Sendable {
    package let git: URL
    package let python3: URL
    package let identityReceipt: String
}

package struct TestToolIdentity: Codable, Equatable, Sendable {
    package let requestedPath: String
    package let realpath: String
    package let device: UInt64
    package let inode: UInt64
    package let links: UInt64
    package let size: UInt64

    private enum CodingKeys: String, CodingKey {
        case requestedPath, realpath, size
        case device = "st_dev"
        case inode = "st_ino"
        case links = "st_nlink"
    }

    package func sharesFile(with other: Self) -> Bool {
        device == other.device && inode == other.inode
    }

    static func read(_ path: String) throws -> Self {
        let realpath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try FileManager.default.attributesOfItem(atPath: realpath)
        func number(_ key: FileAttributeKey) throws -> UInt64 {
            guard let value = attributes[key] as? NSNumber else {
                throw CocoaError(
                    .fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Missing file identity: \(key)"])
            }
            return value.uint64Value
        }
        return try Self(
            requestedPath: path, realpath: realpath,
            device: number(.systemNumber), inode: number(.systemFileNumber),
            links: number(.referenceCount), size: number(.size))
    }
}

package enum TestToolResolver {
    private static let resolution = Task {
        try await valueFromDedicatedThread {
            func find(_ tool: String) throws -> URL {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["--find", tool]
                process.standardOutput = output
                try launch(process)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                recordFailedExit(process)
                let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0, path.hasPrefix("/"),
                    FileManager.default.isExecutableFile(atPath: path)
                else {
                    throw CocoaError(
                        .executableNotLoadable, userInfo: [NSLocalizedDescriptionKey: "xcrun could not resolve \(tool)"]
                    )
                }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }

            let git = try find("git")
            let python = try find("python3")
            let gitIdentity = try TestToolIdentity.read(git.path)
            let pythonIdentity = try TestToolIdentity.read(python.path)
            let gitAlias = try TestToolIdentity.read("/usr/bin/git")
            let pythonAlias = try TestToolIdentity.read("/usr/bin/python3")
            let receipt =
                "test_tool_identity\t"
                + (try json([
                    "resolved_git": gitIdentity, "resolved_python3": pythonIdentity,
                    "alias_git": gitAlias, "alias_python3": pythonAlias,
                ]))
            emit(receipt)
            return ResolvedTestTools(git: git, python3: python, identityReceipt: receipt)
        }
    }

    package static func resolved() async throws -> ResolvedTestTools {
        try await resolution.value
    }

    /// Preserve ordinary command contracts; Git and Python are developer tools,
    /// and must bypass PATH and the system aliases in every real test launcher.
    package static func resolveCommand(_ command: String) async throws -> String {
        switch command {
        case "git": return try await resolved().git.path
        case "python3": return try await resolved().python3.path
        default: return command
        }
    }

    package static func launch(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            emit(failureReceipt(for: process, exitStatus: nil))
            throw error
        }
    }

    package static func recordFailedExit(_ process: Process) {
        if process.terminationStatus != 0 {
            emit(failureReceipt(for: process, exitStatus: process.terminationStatus))
        }
    }

    // No environment, stdout, stderr or error payload: only bounded requested
    // launch inputs. Nonzero exit is included because #418 reached Python and
    // failed there rather than throwing from Process.run().
    package static func failureReceipt(for process: Process, exitStatus: Int32?) -> String {
        let receipt = LaunchFailureReceipt(
            executable: String((process.executableURL?.path ?? "<unset>").prefix(512)),
            argv: (process.arguments ?? []).prefix(32).map { String($0.prefix(128)) },
            cwd: String((process.currentDirectoryURL?.path ?? FileManager.default.currentDirectoryPath).prefix(512)),
            exitStatus: exitStatus,
            argvTruncated: (process.arguments ?? []).count > 32
                || (process.arguments ?? []).contains { $0.count > 128 })
        return "test_tool_launch_failure\t" + ((try? json(receipt)) ?? "{\"encoding_failed\":true}")
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let text = String(bytes: try encoder.encode(value), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private struct LaunchFailureReceipt: Encodable {
    let executable: String
    let argv: [String]
    let cwd: String
    let exitStatus: Int32?
    let argvTruncated: Bool
}
