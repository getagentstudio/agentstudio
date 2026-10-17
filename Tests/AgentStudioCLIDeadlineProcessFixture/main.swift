import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioPrimitives
import Darwin
import Foundation

// Real argv/environment/stdout/stderr and the production descriptor runner;
// stdin is the test-owned clock control pipe, never a shipped CLI test flag.
let timing = ControlledCallDeadlineTiming(controlDescriptor: STDIN_FILENO)
let code = AgentStudioIPCClientCommandLineRunner.run(
    props: .init(
        arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment,
        executablePath: CommandLine.arguments[0], bundleExecutableURL: Bundle.main.executableURL,
        standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
        standardOutputSink: { print($0) }, standardErrorSink: { fputs("\($0)\n", stderr) }, deadlineTiming: timing))
exit(code)
