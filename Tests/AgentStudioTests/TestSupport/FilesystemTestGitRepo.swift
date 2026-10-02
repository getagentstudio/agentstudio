import AgentStudioTestHarness
import Foundation

package enum FilesystemTestGitRepo {
    package static func create(named prefix: String) async throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "tmp")
            .appending(path: "filesystem-git-tests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let repoURL = root.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try await runGit(at: repoURL, args: ["init"])
        try await runGit(at: repoURL, args: ["symbolic-ref", "HEAD", "refs/heads/main"])
        try await runGit(at: repoURL, args: ["config", "user.email", "luna-tests@example.com"])
        try await runGit(at: repoURL, args: ["config", "user.name", "Luna Tests"])
        try await runGit(at: repoURL, args: ["config", "commit.gpgsign", "false"])
        try await runGit(at: repoURL, args: ["config", "tag.gpgsign", "false"])
        return repoURL
    }

    package static func seedTrackedAndUntrackedChanges(at repoURL: URL) async throws {
        let trackedFileURL = repoURL.appending(path: "tracked.txt")
        let untrackedFileURL = repoURL.appending(path: "untracked.txt")

        try "initial\n".write(to: trackedFileURL, atomically: true, encoding: .utf8)
        try await runGit(at: repoURL, args: ["add", "tracked.txt"])
        try await runGit(at: repoURL, args: ["commit", "-m", "Initial commit"])

        try "initial\nupdated\n".write(to: trackedFileURL, atomically: true, encoding: .utf8)
        try "new file\n".write(to: untrackedFileURL, atomically: true, encoding: .utf8)
    }

    package static func destroy(_ repoURL: URL) {
        try? FileManager.default.removeItem(at: repoURL)
    }

    @discardableResult
    package static func runGit(at repoURL: URL, args: [String]) async throws -> String {
        let git = try await TestToolResolver.resolved().git
        return try await withoutBlockingCooperativePool {
            let outputDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: FileManager.default.temporaryDirectory,
                create: true
            )
            defer { try? FileManager.default.removeItem(at: outputDirectory) }
            let stdoutURL = outputDirectory.appending(path: "stdout.log")
            let stderrURL = outputDirectory.appending(path: "stderr.log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            process.executableURL = git
            process.arguments = ["-C", repoURL.path] + args
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try TestToolResolver.launch(process)
            process.waitUntilExit()
            TestToolResolver.recordFailedExit(process)
            try stdoutHandle.close()
            try stderrHandle.close()

            guard process.terminationStatus == 0 else {
                let stderrText = try String(contentsOf: stderrURL, encoding: .utf8)
                throw NSError(
                    domain: "FilesystemTestGitRepo",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: "git command failed (\(args.joined(separator: " "))): \(stderrText)"
                    ]
                )
            }

            return try String(contentsOf: stdoutURL, encoding: .utf8)
        }
    }
}
