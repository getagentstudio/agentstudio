import AgentStudioIPCTransport
import Foundation

/// Routes the two Claude Code provider commands — the hook projection and the
/// package installer — ahead of the descriptor CLI. Neither is a catalog
/// method: one runs as a Claude Code child process, the other edits Claude
/// Code's own configuration, and neither has a pane target or a correlation.
package enum ClaudeCodeProviderRouter {
    /// - Returns: the process exit code when the arguments address a Claude Code
    ///   provider command, and `nil` when they belong to the descriptor CLI.
    package static func exitCode(
        arguments: [String],
        environment: [String: String],
        executablePath: String,
        standardInput: @escaping () throws -> Data,
        identifierGenerator: @escaping () -> UUID,
        noticeSink: @escaping (String) -> Void = { print($0) },
        diagnosticSink: @escaping (String) -> Void = { _ in CLIDiagnostics.record(.providerCommandFailed) },
        deadline: CallDeadline? = nil
    ) -> Int32? {
        if let code = ClaudeCodeHookInvocation.handle(
            ClaudeCodeHookInvocationInputs(
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                identifierGenerator: identifierGenerator,
                diagnosticSink: diagnosticSink,
                deadline: deadline
            )
        ) {
            return code
        }
        return ClaudeCodePackageCommand.handle(
            ClaudeCodePackageCommandInputs(
                arguments: arguments,
                environment: environment,
                executableURL: URL(fileURLWithPath: executablePath).resolvingSymlinksInPath(),
                noticeSink: noticeSink,
                errorSink: diagnosticSink
            )
        )
    }
}
