import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Git pre-push hook")
struct GitHooksPrePushScriptTests {
    @Test("forwards branch refs and hook arguments to Git LFS")
    func forwardsBranchPushToGitLFS() async throws {
        // Arrange
        let fixture = try GitHooksPrePushFixture(includeGitLFS: true)
        defer { fixture.remove() }
        let refs =
            "refs/heads/feature 1111111111111111111111111111111111111111 refs/heads/feature 2222222222222222222222222222222222222222\n"

        // Act
        let result = try await fixture.runHook(refs: refs, arguments: ["origin", "https://example.test/repo.git"])

        // Assert
        #expect(result.exitCode == 0, Comment(rawValue: result.stderr))
        #expect(try fixture.lfsArguments() == ["pre-push", "origin", "https://example.test/repo.git"])
        #expect(try fixture.lfsStdin() == refs)
    }

    @Test("refuses a bare version tag before invoking Git LFS")
    func refusesBareVersionTag() async throws {
        // Arrange
        let fixture = try GitHooksPrePushFixture(includeGitLFS: true)
        defer { fixture.remove() }
        let refs =
            "refs/heads/main 1111111111111111111111111111111111111111 refs/tags/1.2.3 2222222222222222222222222222222222222222\n"

        // Act
        let result = try await fixture.runHook(refs: refs, arguments: ["origin", "https://example.test/repo.git"])

        // Assert
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("pre-push: refusing to push bare version tag '1.2.3'."))
        #expect(result.stderr.contains("pre-push: release workflow triggers on 'v*' — use 'v1.2.3' instead."))
        #expect(!fixture.lfsWasInvoked())
    }

    @Test("fails with the Git LFS not-found message when Git LFS is absent")
    func failsWhenGitLFSIsMissing() async throws {
        // Arrange
        let fixture = try GitHooksPrePushFixture(includeGitLFS: false)
        defer { fixture.remove() }
        let refs =
            "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222\n"

        // Act
        let result = try await fixture.runHook(refs: refs, arguments: ["origin", "https://example.test/repo.git"])

        // Assert
        #expect(result.exitCode == 2)
        #expect(
            result.stderr.contains(
                "This repository is configured for Git LFS but 'git-lfs' was not found on your path."))
    }
}

private struct GitHookProcessResult: Sendable {
    let exitCode: Int32
    let stderr: String
}

private final class GitHooksPrePushFixture: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let root: URL
    private let bin: URL
    private let lfsArgumentsURL: URL
    private let lfsStdinURL: URL
    private let hookURL: URL

    init(includeGitLFS: Bool) throws {
        root = fileManager.temporaryDirectory.appending(path: "git-hooks-pre-push-\(UUIDv7.generate().uuidString)")
        bin = root.appending(path: "bin")
        lfsArgumentsURL = root.appending(path: "git-lfs-arguments.log")
        lfsStdinURL = root.appending(path: "git-lfs-stdin.log")
        hookURL = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
            .appending(path: ".githooks/pre-push")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            at: bin.appending(path: "git"),
            contents: """
                #!/bin/sh
                if [ "$1" = "lfs" ]; then
                  shift
                  exec git-lfs "$@"
                fi
                exit 127
                """
        )
        if includeGitLFS {
            try writeExecutable(
                at: bin.appending(path: "git-lfs"),
                contents: """
                    #!/bin/sh
                    : > "$FAKE_GIT_LFS_ARGUMENTS"
                    for argument in "$@"; do
                      printf '%s\\n' "$argument" >> "$FAKE_GIT_LFS_ARGUMENTS"
                    done
                    cat > "$FAKE_GIT_LFS_STDIN"
                    """
            )
        }
    }

    func runHook(refs: String, arguments: [String]) async throws -> GitHookProcessResult {
        try await withoutBlockingCooperativePool {
            let standardError = Pipe()
            let standardInput = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [hookURL.path] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
            process.environment = [
                "PATH": "\(bin.path):/usr/bin:/bin",
                "FAKE_GIT_LFS_ARGUMENTS": lfsArgumentsURL.path,
                "FAKE_GIT_LFS_STDIN": lfsStdinURL.path,
            ]
            process.standardInput = standardInput
            process.standardError = standardError
            try process.run()
            standardInput.fileHandleForWriting.write(Data(refs.utf8))
            try standardInput.fileHandleForWriting.close()
            process.waitUntilExit()
            let stderr =
                String(
                    data: standardError.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            return GitHookProcessResult(exitCode: process.terminationStatus, stderr: stderr)
        }
    }

    func lfsArguments() throws -> [String] {
        try String(contentsOf: lfsArgumentsURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    func lfsStdin() throws -> String {
        try String(contentsOf: lfsStdinURL, encoding: .utf8)
    }

    func lfsWasInvoked() -> Bool {
        fileManager.fileExists(atPath: lfsArgumentsURL.path)
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
