import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree new preflight")
struct WorktreeNewPreflightTests {
    private static let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
    private static let repository = currentDirectory.appending(path: "repositories/main").standardizedFileURL
    private static let source = currentDirectory.appending(path: "linked/nested").standardizedFileURL

    @Test("new maps every creation flag and accepted combination to its request")
    func parsesCreationFlagsAndCombinations() throws {
        let rows: [(arguments: [String], request: WorktreeCreateRequest, usesJSONOutput: Bool)] = [
            (["--repo", "repositories/main", "--json"], Self.request(start: Self.repository), true),
            (["--no-fork"], Self.request(materialization: .checkout), false),
            (["--no-fetch"], Self.request(fetchPolicy: .skip), false),
            (["--from-branch", "release"], Self.request(startBranch: "release"), false),
            (["--from-branch", "upstream/release"], Self.request(startBranch: "upstream/release"), false),
            (["--from", "linked/nested"], Self.request(source: .worktree(Self.source)), false),
            (
                ["--from", "linked/nested", "--from-branch", "origin/release"],
                Self.request(source: .worktree(Self.source), startBranch: "origin/release"), false
            ),
            (
                ["--no-fork", "--from", "linked/nested"],
                Self.request(source: .worktree(Self.source), materialization: .checkout), false
            ),
            (
                ["--no-fork", "--from-branch", "release"],
                Self.request(startBranch: "release", materialization: .checkout), false
            ),
            (
                [
                    "--from-branch", "release", "--from", "linked/nested", "--no-fork", "--no-fetch", "--repo",
                    "repositories/main", "--json",
                ],
                Self.request(
                    start: Self.repository, source: .worktree(Self.source), startBranch: "release",
                    materialization: .checkout, fetchPolicy: .skip),
                true
            ),
            (
                ["--changes-only", "--from", "linked/nested"],
                Self.request(source: .worktree(Self.source), materialization: .changesOnly), false
            ),
            (
                ["--changes-only", "--from", "linked/nested", "--no-fetch"],
                Self.request(source: .worktree(Self.source), materialization: .changesOnly, fetchPolicy: .skip),
                false
            ),
        ]
        for row in rows {
            #expect(
                try WorktreeCommandLineArgumentParser.parse(
                    ["new", "feat"] + row.arguments, currentDirectory: Self.currentDirectory)
                    == WorktreeCommandLineInvocation(request: .create(row.request), usesJSONOutput: row.usesJSONOutput),
                "new feat \(row.arguments.joined(separator: " "))"
            )
        }
    }

    @Test("removed and excluded creation flags are usage errors with exit 64")
    func rejectsCreationUsageErrors() async throws {
        let rows: [(arguments: [String], error: WorktreeCommandLineArgumentError)] = [
            (["--tracked-only"], .unknownOption),
            (["--tracked-only", "--from", "linked/nested"], .unknownOption),
            (
                ["--changes-only", "--no-fork", "--from", "linked/nested"],
                .conflictingOptions("--changes-only", "--no-fork")
            ),
            (["--changes-only", "--no-fork"], .conflictingOptions("--changes-only", "--no-fork")),
            (
                ["--changes-only", "--from", "linked/nested", "--from-branch", "release"],
                .conflictingOptions("--changes-only", "--from-branch")
            ),
            (["--no-fork", "--no-fork"], .duplicateOption("--no-fork")),
            (["--no-fetch", "--no-fetch"], .duplicateOption("--no-fetch")),
        ]
        for row in rows {
            let arguments = ["new", "feat"] + row.arguments
            #expect(throws: row.error) {
                try WorktreeCommandLineArgumentParser.parse(arguments, currentDirectory: Self.currentDirectory)
            }
            for json in [false, true] {
                let probe = WorktreeCreationCommandLineProbe()
                let exit = await WorktreeCommandLine.run(
                    arguments: arguments + (json ? ["--json"] : []), currentDirectory: Self.currentDirectory,
                    output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
                )
                #expect(exit == 64, "\(arguments.joined(separator: " "))")
                #expect(probe.outputSnapshot().isEmpty)
                #expect(probe.errorSnapshot() == [row.error.message])
            }
        }
        for subcommand in [["list"], ["remove", "feat"], ["prune"]] {
            #expect(throws: WorktreeCommandLineArgumentError.unsupportedOption) {
                try WorktreeCommandLineArgumentParser.parse(
                    subcommand + ["--no-fork"], currentDirectory: Self.currentDirectory)
            }
        }
    }

    @Test("--changes-only without --from is a refusal with options, not a usage error")
    func refusesChangesOnlyWithoutSource() async throws {
        for json in [false, true] {
            let probe = WorktreeCreationCommandLineProbe()
            let exit = await WorktreeCommandLine.run(
                arguments: ["new", "feature/example", "--changes-only"] + (json ? ["--json"] : []),
                currentDirectory: URL(fileURLWithPath: "/tmp"),
                output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
            )
            #expect(exit == 1)
            #expect(probe.errorSnapshot().isEmpty)
            let output = try #require(probe.outputSnapshot().first)
            #expect(output.contains("changesOnlyNeedsFrom"))
            #expect(output.contains("options"))
        }
    }

    @Test("removed fork verb names new --from on stderr even with JSON")
    func rejectsRemovedForkVerb() async {
        for options in [[], ["--json"]] {
            let probe = WorktreeCreationCommandLineProbe()
            let exit = await WorktreeCommandLine.run(
                arguments: ["fork", "feature/example"] + options,
                currentDirectory: URL(fileURLWithPath: "/tmp"),
                output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
            )
            #expect(exit == 64)
            #expect(probe.outputSnapshot().isEmpty)
            #expect(probe.errorSnapshot().count == 1)
            #expect(probe.errorSnapshot().first?.contains("new --from") == true)
        }
    }

    private static func request(
        start: URL = currentDirectory,
        source: WorktreeCreateSource = .mainWorktree,
        startBranch: String? = nil,
        materialization: WorktreeCreateMaterialization = .copyOnWrite,
        fetchPolicy: WorktreeFetchPolicy = .fetch
    ) -> WorktreeCreateRequest {
        WorktreeCreateRequest(
            start: start, branch: "feat", source: source, startBranch: startBranch,
            materialization: materialization, fetchPolicy: fetchPolicy)
    }
}
