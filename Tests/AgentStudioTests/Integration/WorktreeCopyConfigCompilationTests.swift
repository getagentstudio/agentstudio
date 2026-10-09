import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree copy config compilation")
struct WorktreeCopyConfigCompilationTests {
    @Test("include strings compile to SDK patterns with their declaration spelling")
    func compilesIncludePatterns() throws {
        let include = [".build*/", "/Frameworks/", "cache/**/asset?.bin"]
        let patterns = try WorktreeCopyConfig(include: include).compiledIncludePatterns(
            configurationPath: URL(fileURLWithPath: "/repo/.agentstudio.config.json"))
        #expect(patterns.map(\.rawValue) == include)
        #expect(patterns[0].matches(".build-agent-1", isDirectory: true))
        #expect(patterns[1].matches("Frameworks", isDirectory: true))
        #expect(
            try WorktreeCopyConfig().compiledIncludePatterns(
                configurationPath: URL(fileURLWithPath: "/repo/.agentstudio.config.json")
            ).isEmpty)
    }

    @Test(
        "invalid include strings preserve declaration path, entry and typed SDK error",
        arguments: ["!cache/", "#comment", ""])
    func refusesInvalidInclude(pattern: String) {
        let configPath = URL(fileURLWithPath: "/repo/.agentstudio.config.json")
        do {
            _ = try WorktreeCopyConfig(include: [pattern]).compiledIncludePatterns(configurationPath: configPath)
            Issue.record("expected configInvalid before materialization")
        } catch {
            guard case .configInvalid(let path, let errorDetail) = error else {
                Issue.record("expected configInvalid, received \(error)")
                return
            }
            #expect(path == configPath.path)
            #expect(errorDetail.contains(String(reflecting: pattern)))
            let reason = pattern.isEmpty ? "empty" : pattern.hasPrefix("!") ? "negationNotSupported" : "malformed"
            #expect(errorDetail.contains(reason))
        }
    }

    @Test("copy-on-write formatter preserves nonempty report patterns and skipped paths")
    func formatsCopyRuleEvidence() throws {
        let report = GitWorktreeMaterializationReport(
            clonedRegularFileCount: 2, createdDirectoryCount: 1, recreatedSymbolicLinkCount: 0,
            preservedHardLinkCount: 0, preservedGitRepositoryCount: 0, recreatedFIFOCount: 0,
            logicalRegularFileBytes: 32, skippedEntries: [], normalizedEntries: [],
            ignoredIncludedPatterns: ["cache/"], ignoredExcludedCount: 7, nestedWorktreesSkipped: ["nested/source"],
            sourceState: .asIs, submodulesNotAtStart: [], largeFiles: nil)
        let summary = makeCreatedSummary(
            branch: "feature/report", path: URL(fileURLWithPath: "/repo.feature-report"),
            repository: URL(fileURLWithPath: "/repo"), materialization: .copyOnWrite(report))
        let json = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: true)
        let document = try #require(JSONSerialization.jsonObject(with: Data(json.text.utf8)) as? [String: Any])
        let materialization = try #require(document["materialization"] as? [String: Any])
        #expect(materialization["ignoredIncludedPatterns"] as? [String] == ["cache/"])
        #expect(materialization["ignoredExcludedCount"] as? Int == 7)
        #expect(materialization["nestedWorktreesSkipped"] as? [String] == ["nested/source"])
        #expect(materialization["sourceState"] as? String == "asIs")
        #expect((materialization["submodulesNotAtStart"] as? [String])?.isEmpty == true)
        // LR31: the copy-rule report is in --json only; the human line says what was created.
        let human = try WorktreeCommandLineFormatter.format(outcome: .created(summary), usesJSONOutput: false)
        #expect(human.text == "created feature/report at /repo.feature-report (copy-on-write)")
    }
}
