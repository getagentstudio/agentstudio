import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

// Extend the owning topology suite so its existing lane classification stays authoritative.
extension CITopologyWorkflowTests {
    @Test("docs-only PR classification gates heavy jobs while quality remains independent")
    func docsOnlyTopologyFailsOpen() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let changes = try docsOnlyJob("changes", in: workflow)
        #expect(changes.contains("runs-on: ubuntu-24.04"))
        #expect(changes.contains("docs_only: ${{ steps.classify.outputs.docs_only }}"))
        #expect(changes.contains("fetch-depth: 0"))
        #expect(changes.contains("github.event.pull_request.base.sha"))
        #expect(changes.contains("github.event.pull_request.head.sha"))
        #expect(changes.contains("python3 scripts/ci-docs-changes.py classify"))
        #expect(!changes.contains("check-changed-doc-links.py"))
        let quality = try docsOnlyJob("code-quality", in: workflow)
        let linkStep = try docsOnlyLinkStep(in: quality)
        #expect(linkStep.contains("if: github.event_name == 'pull_request'"))
        #expect(linkStep.contains("git merge-base"))
        #expect(linkStep.contains("git diff --name-only -z --no-renames"))
        #expect(linkStep.contains("python3 scripts/check-changed-doc-links.py --changed-files"))
        #expect(!linkStep.contains("needs.changes"))
        #expect(!linkStep.contains("docs_only"))
        #expect(!workflow.contains("paths-ignore:"))
        for name in ["swift-test-suite", "bridge-web", "marketing-site-validation"] {
            let job = try docsOnlyJob(name, in: workflow)
            let header = job.components(separatedBy: "    steps:").first ?? ""
            #expect(header.contains("needs: changes"))
            #expect(header.contains("!cancelled()"))
            #expect(header.contains("github.event_name != 'pull_request' || needs.changes.outputs.docs_only != 'true'"))
        }
        let qualityHeader =
            try docsOnlyJob("code-quality", in: workflow).components(separatedBy: "    steps:").first ?? ""
        #expect(!qualityHeader.contains("needs:"))
        #expect(!qualityHeader.contains("if:"))
    }

    @Test("required Code quality rejects a broken anchor in a mixed PR and skips cleanly without changed docs")
    func requiredQualityChecksEveryPRDocChange() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write("docs/target.md", "# Good")
        try fixture.write("docs/guide.md", "[Good](target.md#good)")
        try fixture.write("Sources/Example.swift", "let value = 1")
        let base = try await fixture.commit("base")
        try fixture.write("Sources/Example.swift", "let value = 2")
        let codeHead = try await fixture.commit("code only")
        let noDocs = try await fixture.runQualityLinkStep(base: base, head: codeHead)
        #expect(noDocs.terminationStatus == 0)
        #expect(String(data: noDocs.standardOutput, encoding: .utf8)?.contains("no changed Markdown documents") == true)
        try fixture.write("docs/guide.md", "[Broken](target.md#absent)")
        let mixedHead = try await fixture.commit("code plus broken docs")
        let broken = try await fixture.runQualityLinkStep(base: base, head: mixedHead)
        #expect(broken.terminationStatus == 1)
        #expect(String(data: broken.standardError, encoding: .utf8)?.contains("missing anchor #absent") == true)
        try fixture.write("docs/guide.md", "[Fixed](target.md#good)")
        let fixedHead = try await fixture.commit("fixed docs")
        #expect(try await fixture.runQualityLinkStep(base: base, head: fixedHead).terminationStatus == 0)
    }

    @Test("required link check exempts only the existing architecture-lint doc fixture tree")
    func requiredQualityKeepsNegativeDocFixturesValid() async throws {
        let lintScript = try String(contentsOfFile: "scripts/lint-swift.sh", encoding: .utf8)
        let linkChecker = try String(contentsOfFile: "scripts/check-changed-doc-links.py", encoding: .utf8)
        let fixtureRoot = try String(contentsOfFile: "scripts/architecture-doc-fixture-root.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(lintScript.contains("scripts/architecture-doc-fixture-root.txt"))
        #expect(linkChecker.contains("architecture-doc-fixture-root.txt"))
        #expect(!lintScript.contains(fixtureRoot))
        #expect(!linkChecker.contains(fixtureRoot))
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        let negativeFixture =
            "Tools/AgentStudioArchitectureLint/Tests/AgentStudioArchitectureLintTests/Fixtures/Bad/AGENTS.md"
        try fixture.write(negativeFixture, "[Expected failure](missing.md#absent)")
        try fixture.write("docs/guide.md", "# Guide")
        let base = try await fixture.commit("base")
        try fixture.write(negativeFixture, "[Expected new failure](missing.md#other)")
        let fixtureHead = try await fixture.commit("fixture changed")
        #expect(try await fixture.runQualityLinkStep(base: base, head: fixtureHead).terminationStatus == 0)
        try fixture.write("docs/guide.md", "[Unexpected failure](missing.md#absent)")
        let realDocHead = try await fixture.commit("real doc broken")
        #expect(try await fixture.runQualityLinkStep(base: base, head: realDocHead).terminationStatus == 1)
    }

    @Test("structural scanner finds code-pinned documents and agent documents")
    func docsOnlyScannerFindsPinnedDocs() async throws {
        let python = try await TestToolResolver.resolved().python3
        let result = try await runProcessToExit(
            executableURL: python, arguments: ["scripts/ci-docs-changes.py", "pinned"])
        #expect(result.terminationStatus == 0)
        let output = try #require(String(data: result.standardOutput, encoding: .utf8))
        for path in [
            "AGENTS.md", "CLAUDE.md", "docs/architecture/README.md",
            "docs/architecture/runtime/pane_runtime_architecture.md",
            "docs/architecture/commands/command_specs.md", "docs/architecture/commands/ipc.md",
            "docs/architecture/hosting/appkit_swiftui_architecture.md",
        ] {
            #expect(output.split(separator: "\n").contains(Substring(path)), "missing structural doc pin: \(path)")
        }
    }

    @Test("a literal doc read is code but unpinned prose stays docs-only; all non-PR events are code")
    func docsOnlyClassificationRespectsContractsAndEvents() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write(
            "Tests/DocContract.swift", "let body = try String(contentsOfFile: \"docs/contract.md\", encoding: .utf8)")
        try fixture.write("docs/contract.md", "# Contract")
        try fixture.write("scripts/path-guard.py", "if path.startswith(\"docs/\"): print(path)")
        try fixture.write("docs/guide.md", "# Guide")
        try fixture.write("Tests/fixture.md", "# Test input")
        try fixture.write("README.md", "# Root readme")
        try fixture.write("AGENTS.md", "[Read](docs/contract.md#contract)")
        let base = try await fixture.commit("base")
        try fixture.write("docs/guide.md", "# Revised Guide")
        let docsHead = try await fixture.commit("docs")
        #expect(try await fixture.classify(base: base, head: docsHead) == true)
        for event in ["push", "schedule", "workflow_dispatch"] {
            #expect(try await fixture.classify(base: base, head: docsHead, event: event) == false)
        }
        try fixture.write("docs/contract.md", "# Changed contract")
        let pinnedHead = try await fixture.commit("contract")
        #expect(try await fixture.classify(base: docsHead, head: pinnedHead) == false)
        try fixture.write("Tests/fixture.md", "# Changed test fixture")
        let testHead = try await fixture.commit("test")
        #expect(try await fixture.classify(base: pinnedHead, head: testHead) == false)
        #expect(try await fixture.classify(base: testHead, head: testHead) == false)
        try fixture.write("Sources/Example.swift", "let value = 1")
        let codeHead = try await fixture.commit("code")
        #expect(try await fixture.classify(base: testHead, head: codeHead) == false)
    }

    @Test("literal readers under each owning code root veto documentation skipping")
    func docsOnlyScannerCoversEachCodeRoot() async throws {
        for codeRoot in ["Tests", "Tools", "BridgeWeb", "web", "scripts"] {
            let fixture = try DocsOnlyGitFixture()
            defer { fixture.remove() }
            try fixture.write("\(codeRoot)/reader.swift", "let path = \"docs/contract.md\"")
            try fixture.write("docs/contract.md", "# Contract")
            try fixture.write("docs/contract.json", "{}")
            try fixture.write("\(codeRoot)/data-reader.swift", "let path = \"docs/contract.json\"")
            try fixture.write("docs/diagram.svg", "<svg />")
            try fixture.write("\(codeRoot)/style.css", "background-image: url(\"docs/diagram.svg\");")
            let base = try await fixture.commit("base")
            try fixture.write("docs/contract.md", "# Changed")
            let head = try await fixture.commit("contract")
            #expect(try await fixture.classify(base: base, head: head) == false, "\(codeRoot) did not pin its input")
            try fixture.write("docs/contract.json", "{\"value\":1}")
            let dataHead = try await fixture.commit("data contract")
            #expect(
                try await fixture.classify(base: head, head: dataHead) == false,
                "\(codeRoot) did not pin its data input")
            try fixture.write("docs/diagram.svg", "<svg><g /></svg>")
            let styleHead = try await fixture.commit("style input")
            #expect(
                try await fixture.classify(base: dataHead, head: styleHead) == false,
                "\(codeRoot) did not scan its CSS input")
        }
    }

    @Test("a literal documentation alias and its resolved input both stay code-pinned")
    func docsOnlyScannerPinsDocAliases() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write("Tests/reader.swift", "let path = \"alias.md\"")
        try fixture.write("docs/original.md", "# Original")
        try fixture.write("docs/replacement.md", "# Replacement")
        let alias = fixture.root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "docs/original.md")
        let base = try await fixture.commit("base")
        try fixture.write("docs/original.md", "# Changed input")
        let inputHead = try await fixture.commit("input changed")
        #expect(try await fixture.classify(base: base, head: inputHead) == false)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "docs/replacement.md")
        let aliasHead = try await fixture.commit("alias changed")
        #expect(try await fixture.classify(base: inputHead, head: aliasHead) == false)
    }

    @Test("a broken classifier emits false and fails without authorizing a heavy-job skip")
    func docsOnlyClassifierFailureKeepsFullProof() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write("docs/guide.md", "# Guide")
        let head = try await fixture.commit("base")
        let output = fixture.root.appendingPathComponent("github-output")
        let executable = try await TestToolResolver.resolved().python3
        let result = try await runProcessToExit(
            executableURL: executable,
            arguments: [
                fixture.classifier.path, "classify", "--root", fixture.root.path, "--event", "pull_request",
                "--base", String(repeating: "0", count: 40), "--head", head,
                "--receipt", fixture.receipt.path, "--github-output", output.path,
            ])
        #expect(result.terminationStatus == 1)
        #expect(try String(contentsOf: output, encoding: .utf8) == "docs_only=false\n")
        #expect(String(data: result.standardError, encoding: .utf8)?.contains("run full CI") == true)
    }

    @Test("merge-base diff excludes target-only churn and rename sides retain a code veto")
    func docsOnlyDiffUsesMergeBaseAndBothRenameSides() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write("docs/guide.md", "# Guide")
        try fixture.write("Sources/Example.swift", "let value = 1")
        let base = try await fixture.commit("base")
        try await fixture.git(["checkout", "-q", "-b", "target"])
        try fixture.write("Sources/Example.swift", "let value = 2")
        let target = try await fixture.commit("target-only code")
        try await fixture.git(["checkout", "-q", "-b", "pr", base])
        try fixture.write("docs/guide.md", "# Changed Guide")
        let head = try await fixture.commit("docs-only PR")
        #expect(try await fixture.classify(base: target, head: head) == true)
        try await fixture.git(["mv", "Sources/Example.swift", "docs/renamed.md"])
        let renamedHead = try await fixture.commit("rename code as docs")
        #expect(try await fixture.classify(base: head, head: renamedHead) == false)
    }

    @Test("changed-doc link check passes relative links duplicate and explicit anchors and rejects missing anchors")
    func docsOnlyLinkCheckerValidatesLocalTargets() async throws {
        let fixture = try DocsOnlyGitFixture()
        defer { fixture.remove() }
        try fixture.write("docs/diagram.svg", "<svg><g id=\"present\" /></svg>")
        try fixture.write("docs/target.md", "# Good Heading\n# Good Heading\n<a id=\"explicit\"></a>\nSetext\n======")
        try fixture.write(
            "docs/guide.md",
            "[Good](target.md#good-heading) [Second](target.md#good-heading-1) [Explicit](target.md#explicit) [Setext](target.md#setext)\n[ref]: target.md#good-heading\n[Reference][ref]\n```md\n[Example](missing.md#missing)\n```\n[Network](https://example.invalid/#ignored)"
        )
        let base = try await fixture.commit("base")
        try fixture.write(
            "docs/guide.md", "[Good](target.md#good-heading)\n[Network](https://example.invalid/#ignored)")
        let good = try await fixture.commit("good")
        _ = try await fixture.classify(base: base, head: good)
        let goodResult = try await fixture.checkLinks()
        #expect(goodResult.terminationStatus == 0)
        for target in ["target.md#does-not-exist", "diagram.svg#does-not-exist", "missing.md"] {
            try fixture.write("docs/guide.md", "[Broken](\(target))")
            let bad = try await fixture.commit("broken")
            #expect(try await fixture.classify(base: good, head: bad) == true)
            let badResult = try await fixture.checkLinks()
            #expect(badResult.terminationStatus == 1)
            #expect(
                String(data: badResult.standardError, encoding: .utf8)?.contains(
                    target.split(separator: "#").last ?? "") == true)
        }
    }
}

private func docsOnlyJob(_ name: String, in workflow: String) throws -> String {
    let lines = workflow.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex(of: "  \(name):"))
    let end =
        lines.indices.dropFirst(start + 1).first { index in
            let line = lines[index]
            return line.hasPrefix("  ") && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? lines.endIndex
    return lines[start..<end].joined(separator: "\n")
}

private func docsOnlyLinkStep(in job: String) throws -> String {
    let start = try #require(job.range(of: "      - name: Check changed documentation links\n"))
    let rest = job[start.lowerBound...]
    let end = rest.range(of: "\n      - ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

private struct DocsOnlyGitFixture {
    let root: URL
    let classifier: URL
    let checker: URL
    var receipt: URL { root.appendingPathComponent(".git/receipt.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docs-only-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        classifier = URL(fileURLWithPath: "scripts/ci-docs-changes.py").standardizedFileURL
        checker = URL(fileURLWithPath: "scripts/check-changed-doc-links.py").standardizedFileURL
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ contents: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func git(_ arguments: [String]) async throws {
        let executable = try await TestToolResolver.resolved().git
        let result = try await runProcessToExit(executableURL: executable, arguments: ["-C", root.path] + arguments)
        #expect(
            result.terminationStatus == 0, Comment(rawValue: String(data: result.standardError, encoding: .utf8) ?? ""))
    }

    func commit(_ message: String) async throws -> String {
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            try await git(["init", "-q"])
            try await git(["config", "user.name", "Fixture"])
            try await git(["config", "user.email", "fixture@example.invalid"])
        }
        try await git(["add", "."])
        try await git(["-c", "commit.gpgsign=false", "commit", "-qm", message])
        let executable = try await TestToolResolver.resolved().git
        let result = try await runProcessToExit(
            executableURL: executable, arguments: ["-C", root.path, "rev-parse", "HEAD"])
        return try #require(String(data: result.standardOutput, encoding: .utf8)).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    func classify(base: String, head: String, event: String = "pull_request") async throws -> Bool {
        let executable = try await TestToolResolver.resolved().python3
        let result = try await runProcessToExit(
            executableURL: executable,
            arguments: [
                classifier.path, "classify", "--root", root.path, "--event", event,
                "--base", base, "--head", head, "--receipt", receipt.path,
            ])
        #expect(
            result.terminationStatus == 0, Comment(rawValue: String(data: result.standardError, encoding: .utf8) ?? ""))
        let body = try Data(contentsOf: receipt)
        let record = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(record["docs_only"] as? Bool)
    }

    func runQualityLinkStep(base: String, head: String) async throws -> ExitedProcessOutput {
        let workflow = try String(contentsOfFile: ".github/workflows/ci.yml", encoding: .utf8)
        let step = try docsOnlyLinkStep(in: docsOnlyJob("code-quality", in: workflow))
        let run = try #require(step.range(of: "        run: |\n"))
        let script = step[run.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.dropFirst(10)) }.joined(separator: "\n")
        let fixtureChecker = root.appendingPathComponent("scripts/check-changed-doc-links.py")
        if !FileManager.default.fileExists(atPath: fixtureChecker.path) {
            try FileManager.default.createDirectory(
                at: fixtureChecker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: checker, to: fixtureChecker)
            try FileManager.default.copyItem(
                at: checker.deletingLastPathComponent().appendingPathComponent("architecture-doc-fixture-root.txt"),
                to: fixtureChecker.deletingLastPathComponent().appendingPathComponent(
                    "architecture-doc-fixture-root.txt"))
        }
        let environment = ProcessInfo.processInfo.environment.merging(["BASE_SHA": base, "HEAD_SHA": head]) { _, new in
            new
        }
        return try await runProcessToExit(
            executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-euc", script], currentDirectoryURL: root,
            environment: environment)
    }

    func checkLinks() async throws -> ExitedProcessOutput {
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        let changed = try #require(record["changed_files"] as? [String])
        let paths = root.appendingPathComponent(".git/changed-paths")
        try Data((changed.joined(separator: "\0") + "\0").utf8).write(to: paths)
        let executable = try await TestToolResolver.resolved().python3
        return try await runProcessToExit(
            executableURL: executable,
            arguments: [
                checker.path, "--root", root.path, "--changed-files", paths.path,
            ])
    }
}
