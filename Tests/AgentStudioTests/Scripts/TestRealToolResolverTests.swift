import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@Suite("Real test tool resolution")
struct TestRealToolResolverTests {
    @Test("fixture commits never launch automatic maintenance", arguments: ["direct", "env", "shell"])
    func fixtureCommitDoesNotLaunchMaintenance(launchRoute: String) async throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let traceDirectory = directory.appending(path: "trace")
        try FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
        let git = try await TestToolResolver.resolved().git
        // Caller configuration must survive the launch policy. Ignore the host's
        // Git configuration so signing, hooks and maintenance preferences cannot mask it.
        let environment = [
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Fixture Test",
            "GIT_CONFIG_KEY_1": "user.email", "GIT_CONFIG_VALUE_1": "fixture@example.com",
            "GIT_CONFIG_KEY_2": "commit.gpgsign", "GIT_CONFIG_VALUE_2": "false",
        ]
        let initialized = try await runProcessToExit(
            executableURL: git, arguments: ["init", directory.path], environment: environment)
        try #require(initialized.terminationStatus == 0)

        let commitArguments = ["commit", "--allow-empty", "-m", "Fixture commit"]
        let executable: URL
        let arguments: [String]
        switch launchRoute {
        case "env":
            executable = URL(fileURLWithPath: "/usr/bin/env")
            arguments = [git.path] + commitArguments
        case "shell":
            executable = URL(fileURLWithPath: "/bin/sh")
            arguments = ["-c", "exec \"$@\"", "fixture-git", git.path] + commitArguments
        default:
            executable = git
            arguments = commitArguments
        }
        let committed = try await runProcessToExit(
            executableURL: executable, arguments: arguments, currentDirectoryURL: directory,
            environment: environment.merging(["GIT_TRACE2_EVENT": traceDirectory.path]) { _, value in value })
        try #require(
            committed.terminationStatus == 0,
            Comment(rawValue: String(bytes: committed.standardError, encoding: .utf8) ?? "Non-UTF-8 Git stderr"))

        // The commit records child_start before exiting. Assert only its completed
        // events; detached child activity never contributes to the verdict.
        let traceFiles = try FileManager.default.contentsOfDirectory(
            at: traceDirectory, includingPropertiesForKeys: nil)
        var commitTraces: [[GitTraceEvent]] = []
        for traceFile in traceFiles {
            let traceText = try String(contentsOf: traceFile, encoding: .utf8)
            let firstLine = traceText.split(separator: "\n").first
            guard let firstLine else { continue }
            let firstEvent = try JSONDecoder().decode(GitTraceEvent.self, from: Data(firstLine.utf8))
            // Child trace SIDs contain a slash; only the root process is ours.
            guard !firstEvent.sid.contains("/") else { continue }
            let events = try traceText.split(separator: "\n").map {
                try JSONDecoder().decode(GitTraceEvent.self, from: Data($0.utf8))
            }
            guard events.contains(where: { $0.event == "start" && $0.argv?.contains("commit") == true }) else {
                continue
            }
            print("fixture_git_trace route=\(launchRoute) path=\(traceFile.path)\n\(traceText)")
            commitTraces.append(events)
        }
        try #require(commitTraces.count == 1)
        let commitTrace = try #require(commitTraces.first)
        #expect(commitTrace.contains(where: { $0.event == "exit" && $0.code == 0 }))
        let maintenanceChildren = commitTrace.filter {
            $0.event == "child_start" && $0.argv?.contains(where: { $0.contains("maintenance") }) == true
        }
        print("fixture_git_maintenance route=\(launchRoute) children=\(maintenanceChildren.count)")
        #expect(maintenanceChildren.isEmpty)
    }

    @Test("fixture git disables maintenance and gc while preserving caller configuration")
    func fixtureGitConfigurationDisablesAutomaticUpkeep() async throws {
        let git = try await TestToolResolver.resolved().git
        let environment = [
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "maintenance.auto", "GIT_CONFIG_VALUE_0": "true",
            "GIT_CONFIG_KEY_1": "gc.auto", "GIT_CONFIG_VALUE_1": "999",
            "GIT_CONFIG_KEY_2": "test.fixture", "GIT_CONFIG_VALUE_2": "kept",
        ]
        for (configKey, expectedValue) in [("maintenance.auto", "false"), ("gc.auto", "0"), ("test.fixture", "kept")] {
            let result = try await runProcessToExit(
                executableURL: git, arguments: ["config", "--get", configKey],
                currentDirectoryURL: FileManager.default.temporaryDirectory, environment: environment)
            try #require(result.terminationStatus == 0)
            let configValue = try #require(String(bytes: result.standardOutput, encoding: .utf8))
            #expect(configValue.trimmingCharacters(in: .whitespacesAndNewlines) == expectedValue)
        }
    }

    @Test("test launchers do not invoke the shared system tool aliases")
    func launchersAvoidSystemAliases() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let files = try #require(
            FileManager.default.enumerator(
                at: root.appending(path: "Tests"), includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for tool in ["git", "python3"] where line.contains("/usr/bin/" + tool) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let aliasVariable = tool == "git" ? "gitAlias" : "pythonAlias"
                    let metadataRead =
                        file.path == root.appending(path: "Tests/AgentStudioTestHarness/ResolvedTestTools.swift").path
                        && trimmed == "let \(aliasVariable) = try TestToolIdentity.read(\"/usr/bin/\(tool)\")"
                    let architectureAssertion =
                        file.path
                        == root.appending(
                            path: "Tests/AgentStudioTests/Architecture/FilesystemActorHotPathArchitectureTests.swift"
                        ).path
                        && (trimmed == "#expect(!source.contains(\"/usr/bin/\(tool)\"))"
                            || trimmed == "\"/usr/bin/\(tool)\",")
                    // These exact observations are data, not launches. No file
                    // gets permission to add a direct shim launcher later.
                    if !metadataRead && !architectureAssertion {
                        violations.append("\(file.path):\(offset + 1)")
                    }
                }
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }

    @Test("resolved tools are real distinct executables and emit their identities")
    func resolvesDistinctRealTools() async throws {
        let tools = try await TestToolResolver.resolved()
        #expect(!tools.git.path.hasPrefix("/usr/bin/"), Comment(rawValue: tools.identityReceipt))
        #expect(!tools.python3.path.hasPrefix("/usr/bin/"), Comment(rawValue: tools.identityReceipt))
        #expect(tools.git != tools.python3)
        let json = try #require(tools.identityReceipt.split(separator: "\t").last)
        let identities = try JSONDecoder().decode([String: TestToolIdentity].self, from: Data(json.utf8))
        #expect(Set(identities.keys) == ["resolved_git", "resolved_python3", "alias_git", "alias_python3"])
        let git = try #require(identities["resolved_git"])
        let python = try #require(identities["resolved_python3"])
        #expect(git.realpath == tools.git.path)
        #expect(python.realpath == tools.python3.path)
        #expect(!git.sharesFile(with: python), Comment(rawValue: tools.identityReceipt))
        for alias in [try #require(identities["alias_git"]), try #require(identities["alias_python3"])] {
            #expect(!git.sharesFile(with: alias), Comment(rawValue: tools.identityReceipt))
            #expect(!python.sharesFile(with: alias), Comment(rawValue: tools.identityReceipt))
        }
        for identity in identities.values {
            #expect(identity.links > 0)
            #expect(identity.size > 0)
        }
    }

    @Test("concurrent callers use the same process resolution")
    func concurrentCallersShareResolution() async throws {
        async let first = TestToolResolver.resolved()
        async let second = TestToolResolver.resolved()
        let (firstTools, secondTools) = try await (first, second)
        #expect(firstTools.identityReceipt == secondTools.identityReceipt)
        #expect(try await TestToolResolver.resolveCommand("git") == firstTools.git.path)
        #expect(try await TestToolResolver.resolveCommand("python3") == firstTools.python3.path)
    }

    @Test("a failed real launch reports bounded requested inputs")
    func failedLaunchReportsInputs() async throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observation = await valueFromDedicatedThread {
            let process = Process()
            process.executableURL = directory.appending(path: "missing-executable")
            process.currentDirectoryURL = directory
            process.arguments = ["add", "."]
            let launchThrew: Bool
            do {
                try TestToolResolver.launch(process)
                launchThrew = false
            } catch {
                launchThrew = true
            }
            let receipt = TestToolResolver.failureReceipt(for: process, exitStatus: 7)
            process.arguments = Array(repeating: String(repeating: "a", count: 500), count: 100)
            return FailedLaunchObservation(
                launchThrew: launchThrew,
                executablePath: process.executableURL?.path,
                receipt: receipt,
                boundedReceipt: TestToolResolver.failureReceipt(for: process, exitStatus: nil))
        }
        #expect(observation.launchThrew)
        let json = try #require(observation.receipt.split(separator: "\t").last)
        let record = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(record["executable"] as? String == observation.executablePath)
        #expect(record["argv"] as? [String] == ["add", "."])
        #expect(record["cwd"] as? String == directory.path)
        #expect(record["exitStatus"] as? Int == 7)
        #expect(observation.boundedReceipt.utf8.count < 8000)
        #expect(observation.boundedReceipt.contains("\"argvTruncated\":true"))
    }
}

private struct GitTraceEvent: Decodable {
    let event: String
    let sid: String
    let argv: [String]?
    let code: Int?
}

private struct FailedLaunchObservation: Sendable {
    let launchThrew: Bool
    let executablePath: String?
    let receipt: String
    let boundedReceipt: String
}
