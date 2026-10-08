import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree new preflight")
struct WorktreeNewPreflightTests {
    @Test("new option combinations are refusals rather than usage errors")
    func refusesInvalidCreationCombinations() async throws {
        let combinations: [([String], String)] = [
            (["--changes-only"], "changesOnlyNeedsFrom"),
            (["--tracked-only", "--from", "/tmp/source"], "trackedOnlyExcludesSource"),
            (["--tracked-only", "--changes-only"], "trackedOnlyExcludesSource"),
        ]
        for (options, reason) in combinations {
            for json in [false, true] {
                let probe = WorktreeCreationCommandLineProbe()
                let exit = await WorktreeCommandLine.run(
                    arguments: ["new", "feature/example"] + options + (json ? ["--json"] : []),
                    currentDirectory: URL(fileURLWithPath: "/tmp"),
                    output: { probe.appendOutput($0) }, errorOutput: { probe.appendError($0) }
                )
                #expect(exit == 1)
                #expect(probe.errorSnapshot().isEmpty)
                let output = try #require(probe.outputSnapshot().first)
                #expect(output.contains(reason))
                #expect(output.contains("options"))
            }
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
}
