import AgentStudioIPCTransport
import Foundation

/// Routes Claude Code hooks ahead of descriptor parsing. Package syntax and
/// installation are owned by the CLI runner.
package enum ClaudeCodeProviderRouter {
    /// - Returns: the process exit code when the arguments address a Claude Code
    ///   provider command, and `nil` when they belong to the descriptor CLI.
    package static func exitCode(
        arguments: [String],
        environment: [String: String],
        standardInput: @escaping () throws -> Data,
        identifierGenerator: @escaping () -> UUID,
        diagnosticSink: @escaping (String) -> Void = { _ in CLIDiagnostics.record(.providerCommandFailed) },
        deadline: CallDeadline? = nil
    ) -> Int32? {
        ClaudeCodeHookInvocation.handle(
            ClaudeCodeHookInvocationInputs(
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                identifierGenerator: identifierGenerator,
                diagnosticSink: diagnosticSink,
                deadline: deadline
            )
        )
    }
}
