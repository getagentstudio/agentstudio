import AgentStudioIPCTransport
import Foundation

/// The two provider-package subcommands of the bundled CLI.
///
/// They are parsed apart from the descriptor surface because neither is an IPC
/// method: `hook` is the provider's entry point into the projection, and
/// `package` edits files on disk. Both are keyed by provider so a new provider
/// is one more case, not a second command shape.
package enum AgentPackageSubcommand: Equatable, Sendable {
    case hook(provider: String, eventName: String)
    case install(provider: String, providerHomePath: String?)
    case uninstall(provider: String, providerHomePath: String?)

    package static func parse(_ arguments: [String]) -> Self? {
        switch arguments.first {
        case "hook":
            guard arguments.count == 3 else { return nil }
            return .hook(provider: arguments[1], eventName: arguments[2])
        case "package":
            guard arguments.count >= 3 else { return nil }
            let home = providerHomePath(Array(arguments.dropFirst(3)))
            switch arguments[1] {
            case "install": return .install(provider: arguments[2], providerHomePath: home)
            case "uninstall": return .uninstall(provider: arguments[2], providerHomePath: home)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Accepts the provider-specific home flag (`--codex-home <path>`) and the
    /// neutral spelling, so each provider slice adds a name rather than a parser.
    private static func providerHomePath(_ arguments: [String]) -> String? {
        guard arguments.count == 2,
            ["--codex-home", "--provider-home"].contains(arguments[0])
        else {
            return nil
        }
        return arguments[1]
    }
}

/// Runs a parsed provider-package subcommand.
package struct AgentPackageCommandRunner: Sendable {
    package struct Props: Sendable {
        package let sourceOccurredAt: Date
        package let environment: [String: String]
        package let executableURL: URL?
        package let standardInput: @Sendable () throws -> Data
        package let correlationIdProvider: @Sendable () -> UUID
        package let exampleIdentifierProvider: @Sendable () -> UUID
        package let standardOutputSink: @Sendable (String) -> Void
        package let standardErrorSink: @Sendable (String) -> Void
        package let deadline: CallDeadline?

        package init(
            sourceOccurredAt: Date,
            environment: [String: String],
            executableURL: URL?,
            standardInput: @escaping @Sendable () throws -> Data,
            correlationIdProvider: @escaping @Sendable () -> UUID,
            exampleIdentifierProvider: @escaping @Sendable () -> UUID,
            standardOutputSink: @escaping @Sendable (String) -> Void,
            standardErrorSink: @escaping @Sendable (String) -> Void,
            deadline: CallDeadline? = nil
        ) {
            self.sourceOccurredAt = sourceOccurredAt
            self.environment = environment
            self.executableURL = executableURL
            self.standardInput = standardInput
            self.correlationIdProvider = correlationIdProvider
            self.exampleIdentifierProvider = exampleIdentifierProvider
            self.standardOutputSink = standardOutputSink
            self.standardErrorSink = standardErrorSink
            self.deadline = deadline
        }
    }

    package static func run(_ subcommand: AgentPackageSubcommand, props: Props) -> Int32 {
        switch subcommand {
        case .hook(let provider, let eventName):
            return runHook(provider: provider, eventName: eventName, props: props)
        case .install(let provider, let providerHomePath):
            return runInstaller(
                provider: provider, providerHomePath: providerHomePath, props: props, installs: true)
        case .uninstall(let provider, let providerHomePath):
            return runInstaller(
                provider: provider, providerHomePath: providerHomePath, props: props, installs: false)
        }
    }

    /// A hook never fails the provider: an unknown provider is one line on
    /// standard error and a zero exit, exactly like an unreadable payload.
    private static func runHook(provider: String, eventName: String, props: Props) -> Int32 {
        switch provider {
        case CodexPackageInstaller.providerIdentifier:
            return ProviderHookInvocation.runCodexHook(
                ProviderHookInvocation.Props(
                    sourceOccurredAt: props.sourceOccurredAt,
                    eventName: eventName,
                    environment: props.environment,
                    standardInput: props.standardInput,
                    correlationIdProvider: props.correlationIdProvider,
                    delivery: .liveIPC(
                        exampleIdentifierProvider: props.exampleIdentifierProvider, environment: props.environment),
                    standardErrorSink: props.standardErrorSink,
                    deadline: props.deadline
                )
            )
        default:
            props.standardErrorSink("agentstudio hook: unknown provider \(provider)")
            return 0
        }
    }

    private static func runInstaller(
        provider: String,
        providerHomePath: String?,
        props: Props,
        installs: Bool
    ) -> Int32 {
        guard provider == CodexPackageInstaller.providerIdentifier else {
            props.standardErrorSink("agentstudio package: unknown provider \(provider)")
            return 1
        }
        do {
            let locator = try AgentPackageResourceLocator.resolve(
                executableURL: props.executableURL, environment: props.environment)
            let installerProps = CodexPackageInstaller.Props(
                codexHome: CodexPackageInstaller.codexHome(
                    explicitPath: providerHomePath, environment: props.environment),
                locator: locator
            )
            let lines =
                installs
                ? try CodexPackageInstaller.install(installerProps)
                : try CodexPackageInstaller.uninstall(installerProps)
            lines.forEach(props.standardOutputSink)
            return 0
        } catch {
            props.standardErrorSink("agentstudio package \(provider): \(error)")
            return 1
        }
    }
}
