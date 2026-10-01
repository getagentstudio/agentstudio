import AgentStudioTestHarness
import Foundation
import Testing

@Suite("Real test tool resolution")
struct TestRealToolResolverTests {
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
        try await valueFromDedicatedThread {
            let process = Process()
            process.executableURL = directory.appending(path: "missing-executable")
            process.currentDirectoryURL = directory
            process.arguments = ["add", "."]
            #expect(throws: (any Error).self) { try TestToolResolver.launch(process) }
            let json = try #require(
                TestToolResolver.failureReceipt(for: process, exitStatus: 7).split(separator: "\t").last)
            let record = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(record["executable"] as? String == process.executableURL?.path)
            #expect(record["argv"] as? [String] == ["add", "."])
            #expect(record["cwd"] as? String == directory.path)
            #expect(record["exitStatus"] as? Int == 7)
            process.arguments = Array(repeating: String(repeating: "a", count: 500), count: 100)
            let bounded = TestToolResolver.failureReceipt(for: process, exitStatus: nil)
            #expect(bounded.utf8.count < 8000)
            #expect(bounded.contains("\"argvTruncated\":true"))
        }
    }
}
