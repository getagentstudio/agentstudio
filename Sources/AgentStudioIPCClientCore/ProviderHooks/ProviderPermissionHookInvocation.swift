import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation
import Synchronization

/// Uses the ordinary compiled ask --wait recipe; provider stdout contains only a decision.
package enum ProviderPermissionHookInvocation {
    package static func handle(
        props: AgentStudioIPCClientCommandLineRunner.Props, sourceOccurredAt: Date,
        startedAt: ContinuousClock.Instant
    ) -> Int32? {
        guard props.arguments.count >= 3, props.arguments[0] == "hook",
            let provider = ProviderPermissionHookProvider(rawValue: props.arguments[1]),
            props.arguments[2] == "PermissionRequest"
        else { return nil }
        // A stale installation never silently retains the old report-only approval path.
        guard props.arguments.suffix(2) == ["--permission-policy", "wait"],
            props.environment["AGENTSTUDIO_PANE_TOKEN"].map({ !$0.isEmpty }) == true
        else { return 0 }
        do {
            let payload = props.standardInput()
            switch try ProviderPermissionHookProjection.project(provider: provider, payload: payload) {
            case .readOnlyQuestion:
                return ClaudeCodeHookInvocation.handle(
                    .init(
                        sourceOccurredAt: sourceOccurredAt, arguments: props.arguments,
                        environment: props.environment, standardInput: { payload },
                        identifierGenerator: props.identifierGenerator,
                        diagnosticSink: { _ in CLIDiagnostics.record(.providerHookFailed) })) ?? 0
            case .approval(let request):
                try waitForDecision(request, props: props, sourceOccurredAt: sourceOccurredAt, startedAt: startedAt)
            }
        } catch {
            CLIDiagnostics.record(.providerHookFailed)
        }
        return 0
    }

    private static func waitForDecision(
        _ request: ProviderPermissionHookRequest, props: AgentStudioIPCClientCommandLineRunner.Props,
        sourceOccurredAt: Date, startedAt: ContinuousClock.Instant
    ) throws {
        let resultText = Mutex<String?>(nil)
        let environment = request.writerEnvironment(props.environment)
        let askProps = AgentStudioIPCClientCommandLineRunner.Props(
            arguments: request.askArguments, environment: environment, executablePath: props.executablePath,
            bundleExecutableURL: props.bundleExecutableURL, standardInput: { Data() },
            identifierGenerator: props.identifierGenerator,
            standardOutputSink: { text in resultText.withLock { $0 = text } },
            standardErrorSink: { _ in }, now: props.now)
        let global = try AgentStudioIPCClientArguments.parseGlobal(
            askProps.arguments, environment: environment, standardInputProvider: askProps.standardInput)
        let intent = try PaneCLIIntent.parse(askProps.arguments, now: sourceOccurredAt)
        let deadline = CallDeadline(limit: CLIPolicy.permissionCallLimit, startedAt: startedAt)
        try PaneCLICommandRunner(props: askProps, global: global, deadline: deadline, totalDeadline: deadline).run(
            intent)
        guard deadline.remainingBudget > .zero, let text = resultText.withLock({ $0 }) else { return }
        let outcome = try JSONDecoder().decode(IPCPaneAskOutcome.self, from: Data(text.utf8))
        if let decision = try ProviderPermissionHookDecision.json(for: outcome) {
            props.standardOutputSink(decision)
        }
    }
}
