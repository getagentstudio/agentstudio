import Foundation

/// Routes the two Cursor provider commands — the hook projection and the
/// package installer — ahead of the descriptor CLI. Neither is a catalog
/// method: one runs as a Cursor child process, the other edits Cursor's own
/// configuration, and neither has a pane target or a correlation.
package enum CursorProviderRouter {
    /// - Returns: the process exit code when the arguments address a Cursor
    ///   provider command, and `nil` when they belong to the descriptor CLI.
    package static func exitCode(
        arguments: [String],
        environment: [String: String],
        executablePath: String,
        standardInput: @escaping () throws -> Data,
        identifierGenerator: @escaping () -> UUID,
        noticeSink: @escaping (String) -> Void = { print($0) },
        diagnosticSink: @escaping (String) -> Void = { _ in CLIDiagnostics.record(.providerCommandFailed) }
    ) -> Int32? {
        if let code = CursorHookInvocation.handle(
            CursorHookInvocationInputs(
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                identifierGenerator: identifierGenerator,
                diagnosticSink: diagnosticSink
            )
        ) {
            return code
        }
        return CursorPackageCommand.handle(
            CursorPackageCommandInputs(
                arguments: arguments,
                environment: environment,
                executableURL: URL(fileURLWithPath: executablePath).resolvingSymlinksInPath(),
                noticeSink: noticeSink,
                errorSink: diagnosticSink
            )
        )
    }
}
