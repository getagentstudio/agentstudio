import Foundation

package enum WorktreeCommandLine {
    package static func dispatch(
        arguments: [String],
        currentDirectory: URL,
        output: @Sendable (String) -> Void,
        errorOutput: @Sendable (String) -> Void,
        runIPCCommand: @Sendable () -> Int32
    ) async -> Int32 {
        guard arguments.first == "worktree" else {
            return runIPCCommand()
        }

        return await run(
            arguments: Array(arguments.dropFirst()),
            currentDirectory: currentDirectory,
            output: output,
            errorOutput: errorOutput
        )
    }

    /// `runner` defaults to the production one; tests pass one whose remote client allows Git's
    /// `file` transport, so the command line can fetch from local bare remotes.
    package static func run(
        arguments: [String],
        currentDirectory: URL,
        output: @Sendable (String) -> Void,
        errorOutput: @Sendable (String) -> Void,
        runner: WorktreeOperationRunner = WorktreeOperationRunner()
    ) async -> Int32 {
        do {
            let invocation = try WorktreeCommandLineArgumentParser.parse(
                arguments,
                currentDirectory: currentDirectory
            )
            let outcome = await runner.run(invocation.request)
            let response = try WorktreeCommandLineFormatter.format(
                outcome: outcome,
                usesJSONOutput: invocation.usesJSONOutput
            )
            output(response.text)
            return response.exitCode
        } catch let stop as WorktreeCreationStop {
            let response = try? WorktreeCommandLineFormatter.format(
                outcome: .refused(.creationStopped(stop)), usesJSONOutput: arguments.contains("--json")
            )
            output(response?.text ?? "failed: outputEncodingFailed")
            return response?.exitCode ?? 2
        } catch let error as WorktreeCommandLineArgumentError {
            errorOutput(error.message)
            return 64
        } catch {
            output("failed: outputEncodingFailed")
            return 2
        }
    }
}
