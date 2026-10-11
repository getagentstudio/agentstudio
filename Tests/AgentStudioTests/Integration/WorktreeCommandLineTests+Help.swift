import AgentStudioWorktreeOperations
import Foundation
import Testing

extension WorktreeCommandLineTests {
    @Test("help declares every parser option as a whole token", arguments: ["new", "list", "remove", "prune"])
    func helpDeclaresEveryParserOption(command: String) throws {
        let help = try #require(WorktreeCommandLineHelp.usage(for: command))
        let declaredOptions = Self.declaredHelpOptionTokens(in: help)
        for option in try WorktreeCommandLineArgumentParser.optionNames(for: command).sorted() {
            #expect(declaredOptions.contains(option), "missing \(option) from \(command) help")
        }
    }

    @Test("every help option token is accepted by the real parser", arguments: ["new", "list", "remove", "prune"])
    func parserAcceptsEveryHelpOptionToken(command: String) throws {
        let help = try #require(WorktreeCommandLineHelp.usage(for: command))
        let helpOptions = Set(
            help.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
                .filter { $0.hasPrefix("-") }.map(String.init))
        for option in helpOptions.sorted() {
            do {
                _ = try WorktreeCommandLineArgumentParser.parse(
                    Self.argumentsForHelpOption(option, command: command),
                    currentDirectory: URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true))
            } catch {
                Issue.record("parser rejected \(option) named in \(command) help: \(error)")
            }
        }
    }

    @Test(
        "overview help ignores JSON output in either order",
        arguments: [["--json", "--help"], ["--help", "--json"], ["--json", "-h"], ["-h", "--json"]])
    func overviewHelpIgnoresJSONPosition(arguments: [String]) async {
        await expectHelpOutput(arguments: arguments, expected: WorktreeCommandLineHelp.overview)
    }

    @Test("verb help ignores JSON output before or after help", arguments: ["new", "list", "remove", "prune"])
    func verbHelpIgnoresJSONPosition(command: String) async throws {
        let expected = try #require(WorktreeCommandLineHelp.usage(for: command))
        for flag in ["--help", "-h"] {
            for arguments in [
                ["--json", command, flag], [command, "--json", flag], [command, flag, "--json"],
            ] {
                await expectHelpOutput(arguments: arguments, expected: expected)
            }
        }
    }

    @Test("help followed by a verb prints that verb's usage", arguments: ["new", "list", "remove", "prune"])
    func helpCommandSelectsVerbUsage(command: String) async throws {
        let expected = try #require(WorktreeCommandLineHelp.usage(for: command))
        for arguments in [["help", command], ["--json", "help", command], ["help", command, "--json"]] {
            await expectHelpOutput(arguments: arguments, expected: expected)
        }
    }

    private func expectHelpOutput(arguments: [String], expected: String) async {
        let probe = WorktreeCommandLineTestProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: "/path/that/does/not/exist", isDirectory: true),
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendErrorOutput($0) },
            runner: Self.runnerThatWouldFailIfCalled())
        #expect(exitCode == 0)
        #expect(probe.outputSnapshot() == [expected])
        #expect(probe.errorOutputSnapshot().isEmpty)
    }

    private static func declaredHelpOptionTokens(in help: String) -> Set<String> {
        // Only declarations count: mentions in descriptions or examples cannot hide a missing alias.
        Set(
            help.split(separator: "\n").flatMap { line in
                line.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                    .prefix(while: { $0.hasPrefix("-") }).map(String.init)
            })
    }

    private static func argumentsForHelpOption(_ option: String, command: String) -> [String] {
        var arguments = [command]
        if command == "new" || command == "remove" { arguments.append("feature/help") }
        if option == "--from-branch" || option == "--changes-only" { arguments.append("-c") }
        if option == "--changes-only" { arguments += ["--from", "/tmp/source"] }
        arguments.append(option)
        if WorktreeCommandLineArgumentParser.pathOptions.contains(option) {
            arguments.append("/tmp/help-option")
        } else if WorktreeCommandLineArgumentParser.valueOptions.contains(option) {
            arguments.append("feature/start")
        }
        return arguments
    }
}
