import AgentStudioIPCClientCore
import AgentStudioPrimitives
import AgentStudioWorktreeOperations
import Foundation

/// Routes the worktree subcommand before it builds any IPC credentials; other
/// invocations continue through the descriptor CLI runner with real process IO.
@main
struct AgentStudioIPCClientMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let exitCode = await WorktreeCommandLine.dispatch(
            arguments: arguments,
            currentDirectory: currentDirectory,
            output: { print($0) },
            errorOutput: { fputs("\($0)\n", stderr) },
            runIPCCommand: {
                AgentStudioIPCClientCommandLineRunner.run(
                    props: AgentStudioIPCClientCommandLineRunner.Props(
                        arguments: arguments,
                        environment: ProcessInfo.processInfo.environment,
                        executablePath: CommandLine.arguments[0],
                        bundleExecutableURL: Bundle.main.executableURL,
                        standardInput: { FileHandle.standardInput.readDataToEndOfFile() },
                        identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { print($0) },
                        standardErrorSink: { fputs("\($0)\n", stderr) },
                        standardInputFileDescriptor: FileHandle.standardInput.fileDescriptor
                    )
                )
            }
        )
        exit(exitCode)
    }
}
