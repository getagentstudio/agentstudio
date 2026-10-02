import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Darwin
import Foundation
import Testing

enum VendorPinMismatch: String, CaseIterable {
    case linkedGhosttyGitlink
    case linkedZmxGitlink
    case primaryGhosttyGitlink
    case primaryZmxGitlink
    case primaryGhosttySubmoduleHead
    case primaryZmxSubmoduleHead
}

enum VendorInvalidPrimarySource: String, CaseIterable {
    case missingFramework
    case symlinkedFramework
    case nestedFrameworkSymlink
    case missingFrameworkSliceHeader
    case frameworkIsFile
    case missingZmxOutput
    case zmxIsNotExecutable
    case symlinkedGhosttyResources
    case missingGhosttyTerminfo
}

struct VendorCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct VendorWorktreeFixture {
    let temporaryRoot: URL
    let primaryRoot: URL
    let linkedRoot: URL
    let ghosttyRepository: URL
    let zmxRepository: URL
    let ghosttyFirstCommit: String
    let ghosttySecondCommit: String
    let zmxFirstCommit: String
    let zmxSecondCommit: String

    private let fileManager = FileManager.default

    init() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "AgentStudio vendor fixture \(UUID().uuidString)")
        primaryRoot = temporaryRoot.appending(path: "primary AgentStudio")
        linkedRoot = temporaryRoot.appending(path: "linked worker")
        ghosttyRepository = temporaryRoot.appending(path: "dummy Ghostty source")
        zmxRepository = temporaryRoot.appending(path: "dummy zmx source")

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let ghosttyCommits = try await Self.makeDummyVendorRepository(
            at: ghosttyRepository,
            markerName: "ghostty")
        ghosttyFirstCommit = ghosttyCommits.first
        ghosttySecondCommit = ghosttyCommits.second
        let zmxCommits = try await Self.makeDummyVendorRepository(
            at: zmxRepository,
            markerName: "zmx")
        zmxFirstCommit = zmxCommits.first
        zmxSecondCommit = zmxCommits.second

        try requireSuccess(await Self.runGit(["init", primaryRoot.path], in: temporaryRoot))
        try await configureGit(in: primaryRoot)
        try writeTrackedSuperprojectFiles()
        try requireSuccess(
            await Self.runGit(
                ["-c", "protocol.file.allow=always", "submodule", "add", ghosttyRepository.path, "vendor/ghostty"],
                in: primaryRoot))
        try requireSuccess(
            await Self.runGit(
                ["-c", "protocol.file.allow=always", "submodule", "add", zmxRepository.path, "vendor/zmx"],
                in: primaryRoot))
        try requireSuccess(
            await Self.runGit(["checkout", ghosttyFirstCommit], in: primaryRoot.appending(path: "vendor/ghostty")))
        try requireSuccess(
            await Self.runGit(["checkout", zmxFirstCommit], in: primaryRoot.appending(path: "vendor/zmx")))
        try requireSuccess(await Self.runGit(["add", "."], in: primaryRoot))
        try requireSuccess(await Self.runGit(["commit", "-m", "fixture superproject"], in: primaryRoot))
        try publishPrimaryOutputs()
        try requireSuccess(
            await Self.runGit(
                ["worktree", "add", "-b", "linked-fixture", linkedRoot.path],
                in: primaryRoot))
    }

    var primaryFrameworkURL: URL {
        primaryRoot.appending(path: "Frameworks/GhosttyKit.xcframework")
    }

    var linkedFrameworkURL: URL {
        linkedRoot.appending(path: "Frameworks/GhosttyKit.xcframework")
    }

    var primaryZmxOutputURL: URL {
        primaryRoot.appending(path: "vendor/zmx/zig-out")
    }

    var linkedZmxOutputURL: URL {
        linkedRoot.appending(path: "vendor/zmx/zig-out")
    }

    var primaryGhosttyResourcesURL: URL {
        primaryRoot.appending(path: "Sources/AgentStudio/Resources/ghostty")
    }

    var linkedGhosttyResourcesURL: URL {
        linkedRoot.appending(path: "Sources/AgentStudio/Resources/ghostty")
    }

    var primaryGhosttyTerminfoURL: URL {
        primaryRoot.appending(path: "Sources/AgentStudio/Resources/terminfo/67/ghostty")
    }

    var linkedGhosttyTerminfoURL: URL {
        linkedRoot.appending(path: "Sources/AgentStudio/Resources/terminfo/67/ghostty")
    }

    var primaryTrackedTerminfoURL: URL {
        primaryRoot.appending(path: "Sources/AgentStudio/Resources/terminfo/78/xterm-256color")
    }

    func cleanup() {
        try? fileManager.removeItem(at: temporaryRoot)
    }

    func runHelper(
        _ command: String,
        in worktree: URL,
        currentDirectory: URL? = nil,
        environment: [String: String] = [:]
    ) async throws -> VendorCommandResult {
        try await Self.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [worktree.appending(path: "scripts/vendor-worktree.sh").path, command],
            in: currentDirectory ?? worktree,
            environment: environment)
    }

    func gitStatus(in worktree: URL) async throws -> String {
        let result = try await Self.runGit(["status", "--short"], in: worktree)
        try requireSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkedOutRevision(path: String, in worktree: URL) async throws -> String {
        let result = try await Self.runGit(["-C", path, "rev-parse", "HEAD"], in: worktree)
        try requireSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requireSuccess(_ result: VendorCommandResult) throws {
        try Self.requireSuccess(result)
    }

    func primaryOutputSnapshot(allowMissing: Bool = false) throws -> [String: Data] {
        try snapshot(
            urls: [
                primaryFrameworkURL,
                primaryZmxOutputURL,
                primaryGhosttyResourcesURL,
                primaryGhosttyTerminfoURL,
            ],
            allowMissing: allowMissing)
    }

    func sharedProjectionSnapshot() throws -> [String: Data] {
        try snapshot(
            urls: [
                linkedGhosttyResourcesURL,
                linkedGhosttyTerminfoURL,
            ],
            allowMissing: false)
    }

    func localProjectionSnapshot() throws -> [String: Data] {
        try snapshot(
            urls: [
                linkedFrameworkURL,
                linkedZmxOutputURL,
                linkedGhosttyResourcesURL,
                linkedGhosttyTerminfoURL,
            ],
            allowMissing: false)
    }

    func expectExactSharedProjection() throws {
        #expect(try canonicalSymlinkTarget(linkedFrameworkURL) == primaryFrameworkURL.resolvingSymlinksInPath().path)
        #expect(try canonicalSymlinkTarget(linkedZmxOutputURL) == primaryZmxOutputURL.resolvingSymlinksInPath().path)
        #expect(try isSymbolicLink(linkedGhosttyResourcesURL) == false)
        #expect(try isSymbolicLink(linkedGhosttyTerminfoURL) == false)
        #expect(
            try snapshot(urls: [linkedGhosttyResourcesURL], allowMissing: false)
                == snapshot(urls: [primaryGhosttyResourcesURL], allowMissing: false))
        #expect(try Data(contentsOf: linkedGhosttyTerminfoURL) == Data(contentsOf: primaryGhosttyTerminfoURL))
        try assertNoNestedSymlinks(in: linkedGhosttyResourcesURL)
    }

    func expectCompleteLocalProjection() throws {
        for url in [
            linkedFrameworkURL,
            linkedZmxOutputURL,
            linkedGhosttyResourcesURL,
            linkedGhosttyTerminfoURL,
        ] {
            #expect(fileManager.fileExists(atPath: url.path))
            #expect(try isSymbolicLink(url) == false)
        }
    }

    func apply(_ mismatch: VendorPinMismatch) async throws {
        switch mismatch {
        case .linkedGhosttyGitlink:
            try await updateGitlink(
                worktree: linkedRoot,
                path: "vendor/ghostty",
                commit: ghosttySecondCommit)
        case .linkedZmxGitlink:
            try await updateGitlink(
                worktree: linkedRoot,
                path: "vendor/zmx",
                commit: zmxSecondCommit)
        case .primaryGhosttyGitlink:
            try await updateGitlink(
                worktree: primaryRoot,
                path: "vendor/ghostty",
                commit: ghosttySecondCommit)
        case .primaryZmxGitlink:
            try await updateGitlink(
                worktree: primaryRoot,
                path: "vendor/zmx",
                commit: zmxSecondCommit)
        case .primaryGhosttySubmoduleHead:
            try requireSuccess(
                await Self.runGit(
                    ["checkout", ghosttySecondCommit],
                    in: primaryRoot.appending(path: "vendor/ghostty")))
        case .primaryZmxSubmoduleHead:
            try requireSuccess(
                await Self.runGit(
                    ["checkout", zmxSecondCommit],
                    in: primaryRoot.appending(path: "vendor/zmx")))
        }
    }

    func apply(_ invalidSource: VendorInvalidPrimarySource) throws {
        switch invalidSource {
        case .missingFramework:
            try fileManager.removeItem(at: primaryFrameworkURL)
        case .symlinkedFramework:
            try fileManager.removeItem(at: primaryFrameworkURL)
            try fileManager.createSymbolicLink(
                at: primaryFrameworkURL,
                withDestinationURL: primaryGhosttyResourcesURL)
        case .nestedFrameworkSymlink:
            let externalLibrary = temporaryRoot.appending(path: "external libghostty")
            try Data("external framework library".utf8).write(to: externalLibrary)
            let nestedLibrary = primaryFrameworkURL.appending(path: "macos-arm64/libghostty.a")
            try fileManager.removeItem(at: nestedLibrary)
            try fileManager.createSymbolicLink(
                at: nestedLibrary,
                withDestinationURL: externalLibrary)
        case .missingFrameworkSliceHeader:
            try fileManager.removeItem(
                at: primaryFrameworkURL.appending(path: "macos-arm64/Headers"))
        case .frameworkIsFile:
            try fileManager.removeItem(at: primaryFrameworkURL)
            try Data("not a framework".utf8).write(to: primaryFrameworkURL)
        case .missingZmxOutput:
            try fileManager.removeItem(at: primaryZmxOutputURL)
        case .zmxIsNotExecutable:
            chmod(primaryZmxOutputURL.appending(path: "bin/zmx").path, 0o644)
        case .symlinkedGhosttyResources:
            let replacement = temporaryRoot.appending(path: "foreign resources")
            try fileManager.copyItem(at: primaryGhosttyResourcesURL, to: replacement)
            try fileManager.removeItem(at: primaryGhosttyResourcesURL)
            try fileManager.createSymbolicLink(
                at: primaryGhosttyResourcesURL,
                withDestinationURL: replacement)
        case .missingGhosttyTerminfo:
            try fileManager.removeItem(at: primaryGhosttyTerminfoURL)
        }
    }

    func makeCommandSpies(logURL: URL) async throws -> URL {
        let git = try await TestToolResolver.resolved().git
        let directory = temporaryRoot.appending(path: "command spies")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(
            at: directory.appending(path: "git"),
            contents: """
                #!/bin/bash
                printf 'git %s\\n' "$*" >> \(Self.shellQuote(logURL.path))
                exec \(Self.shellQuote(git.path)) "$@"
                """)
        try writeExecutable(
            at: directory.appending(path: "zig"),
            contents: """
                #!/bin/bash
                printf 'zig %s\\n' "$*" >> \(Self.shellQuote(logURL.path))
                exit 97
                """)
        try Data().write(to: logURL)
        return directory
    }

    func makeLocalProducerSpies() throws -> URL {
        let directory = temporaryRoot.appending(path: "local producer spies")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(
            at: directory.appending(path: "mise"),
            contents: """
                #!/bin/bash
                set -euo pipefail
                mkdir -p Frameworks/GhosttyKit.xcframework/macos-arm64/Headers
                printf 'local framework\\n' > Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty.a
                printf '// local ghostty header\\n' > Frameworks/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h
                mkdir -p vendor/zmx/zig-out/bin
                printf '#!/bin/bash\\necho local-zmx\\n' > vendor/zmx/zig-out/bin/zmx
                chmod 700 vendor/zmx/zig-out/bin/zmx
                mkdir -p Sources/AgentStudio/Resources/ghostty/shell-integration
                printf 'local shell\\n' > Sources/AgentStudio/Resources/ghostty/shell-integration/ghostty.sh
                mkdir -p Sources/AgentStudio/Resources/terminfo/67
                printf 'local terminfo\\n' > Sources/AgentStudio/Resources/terminfo/67/ghostty
                """)
        return directory
    }

    func makeFailingCopySpy() throws -> URL {
        let directory = temporaryRoot.appending(path: "failing copy spy")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(
            at: directory.appending(path: "cp"),
            contents: """
                #!/bin/bash
                exit 71
                """)
        return directory
    }

    /// Builds a faithful minimal XCFramework slice: the static library AND the
    /// slice header. `vendor-worktree.sh` preflights the header, so a fixture
    /// with only the library is not a valid stand-in for a real vendor build.
    static func populateFrameworkSlice(at framework: URL, using fileManager: FileManager) throws {
        let sliceRoot = framework.appending(path: "macos-arm64")
        let headerDirectory = sliceRoot.appending(path: "Headers")
        try fileManager.createDirectory(at: headerDirectory, withIntermediateDirectories: true)
        try Data("primary ghostty library".utf8)
            .write(to: sliceRoot.appending(path: "libghostty.a"))
        try Data("// fixture ghostty header\n".utf8)
            .write(to: headerDirectory.appending(path: "ghostty.h"))
    }

    private func updateGitlink(worktree: URL, path: String, commit: String) async throws {
        try requireSuccess(
            await Self.runGit(
                ["update-index", "--add", "--cacheinfo", "160000,\(commit),\(path)"],
                in: worktree))
        try requireSuccess(await Self.runGit(["commit", "-m", "change \(path) pin"], in: worktree))
    }

    private func publishPrimaryOutputs() throws {
        try Self.populateFrameworkSlice(at: primaryFrameworkURL, using: fileManager)

        let zmxBinary = primaryZmxOutputURL.appending(path: "bin/zmx")
        try fileManager.createDirectory(
            at: zmxBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try writeExecutable(
            at: zmxBinary,
            contents: "#!/bin/bash\necho fixture-zmx\n")

        let shellIntegration =
            primaryGhosttyResourcesURL
            .appending(path: "shell-integration/ghostty.sh")
        try fileManager.createDirectory(
            at: shellIntegration.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("primary shell integration".utf8).write(to: shellIntegration)

        try fileManager.createDirectory(
            at: primaryGhosttyTerminfoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("primary ghostty terminfo".utf8).write(to: primaryGhosttyTerminfoURL)
    }

    private func writeTrackedSuperprojectFiles() throws {
        let productionScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "scripts/vendor-worktree.sh")
        guard fileManager.fileExists(atPath: productionScript.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: productionScript.path])
        }
        let fixtureScript = primaryRoot.appending(path: "scripts/vendor-worktree.sh")
        try fileManager.createDirectory(
            at: fixtureScript.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.copyItem(at: productionScript, to: fixtureScript)
        chmod(fixtureScript.path, 0o755)

        let trackedTerminfo = primaryTrackedTerminfoURL
        try fileManager.createDirectory(
            at: trackedTerminfo.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("tracked custom xterm".utf8).write(to: trackedTerminfo)
        try """
        Frameworks/GhosttyKit.xcframework
        vendor/zmx/zig-out
        Sources/AgentStudio/Resources/ghostty
        Sources/AgentStudio/Resources/terminfo/67
        """.appending("\n").write(
            to: primaryRoot.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8)
    }

    private func configureGit(in repository: URL) async throws {
        try requireSuccess(await Self.runGit(["config", "user.name", "Fixture"], in: repository))
        try requireSuccess(await Self.runGit(["config", "user.email", "fixture@example.invalid"], in: repository))
        try requireSuccess(await Self.runGit(["config", "commit.gpgsign", "false"], in: repository))
    }

    private func canonicalSymlinkTarget(_ url: URL) throws -> String {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        #expect(destination.hasPrefix("/"), "Shared links must use absolute targets")
        return URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }

    private func assertNoNestedSymlinks(in root: URL) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey])
        else {
            Issue.record("Could not enumerate \(root.path)")
            return
        }
        for case let child as URL in enumerator {
            #expect(try isSymbolicLink(child) == false)
        }
    }

    private func snapshot(urls: [URL], allowMissing: Bool) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for root in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                if allowMissing {
                    result[root.lastPathComponent] = Data("<missing>".utf8)
                    continue
                }
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
            }
            if !isDirectory.boolValue {
                result[root.lastPathComponent] = try Data(contentsOf: root)
                continue
            }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let child as URL in enumerator {
                var childIsDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDirectory),
                    !childIsDirectory.boolValue
                else {
                    continue
                }
                let relativePath = child.path.replacingOccurrences(
                    of: root.path + "/",
                    with: "")
                result["\(root.lastPathComponent)/\(relativePath)"] = try Data(contentsOf: child)
            }
        }
        return result
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    private static func makeDummyVendorRepository(
        at repository: URL,
        markerName: String
    ) async throws -> (first: String, second: String) {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try requireSuccess(await runGit(["init"], in: repository))
        try requireSuccess(await runGit(["config", "user.name", "Fixture"], in: repository))
        try requireSuccess(await runGit(["config", "user.email", "fixture@example.invalid"], in: repository))
        try requireSuccess(await runGit(["config", "commit.gpgsign", "false"], in: repository))
        try Data("\(markerName) revision one".utf8).write(to: repository.appending(path: "build.zig"))
        try requireSuccess(await runGit(["add", "."], in: repository))
        try requireSuccess(await runGit(["commit", "-m", "first"], in: repository))
        let first = try await gitRevision(in: repository)
        try Data("\(markerName) revision two".utf8).write(to: repository.appending(path: "build.zig"))
        try requireSuccess(await runGit(["commit", "-am", "second"], in: repository))
        return (first, try await gitRevision(in: repository))
    }

    private static func gitRevision(in repository: URL) async throws -> String {
        let result = try await runGit(["rev-parse", "HEAD"], in: repository)
        try requireSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runGit(_ arguments: [String], in directory: URL) async throws -> VendorCommandResult {
        try await run(
            executable: try await TestToolResolver.resolved().git,
            arguments: arguments,
            in: directory,
            environment: ["GIT_ALLOW_PROTOCOL": "file"])
    }

    private static func run(
        executable: URL,
        arguments: [String],
        in directory: URL,
        environment: [String: String]
    ) async throws -> VendorCommandResult {
        try await withoutBlockingCooperativePool {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appending(path: "vendor-worktree-output-\(UUIDv7.generate().uuidString)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var mergedEnvironment = ProcessInfo.processInfo.environment
            mergedEnvironment["CI"] = "false"
            mergedEnvironment["GITHUB_ACTIONS"] = "false"
            mergedEnvironment.removeValue(forKey: "SWIFT_BUILD_DIR")
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
            process.environment = mergedEnvironment
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try TestToolResolver.launch(process)
            process.waitUntilExit()
            TestToolResolver.recordFailedExit(process)
            try stdoutHandle.close()
            try stderrHandle.close()
            return VendorCommandResult(
                exitCode: process.terminationStatus,
                stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
                stderr: try String(contentsOf: stderrURL, encoding: .utf8)
            )
        }
    }

    private static func requireSuccess(_ result: VendorCommandResult) throws {
        guard result.exitCode == 0 else {
            throw CocoaError(
                .executableLoad,
                userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
