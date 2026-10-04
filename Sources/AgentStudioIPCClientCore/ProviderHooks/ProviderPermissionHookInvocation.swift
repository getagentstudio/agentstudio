import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation
import Synchronization

/// Uses the ordinary compiled ask --wait recipe; provider stdout contains only a decision.
package enum ProviderPermissionHookInvocation {
    package static func handle(
        props: AgentStudioIPCClientCommandLineRunner.Props, sourceOccurredAt: Date,
        startedAt: ContinuousClock.Instant, eventDelivery: ProviderHookDelivery? = nil
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
            switch try ProviderPermissionHookProjection.project(
                provider: provider,
                payload: payload,
                sourceOccurredAt: sourceOccurredAt,
                providerVersion: providerVersion(provider: provider, arguments: props.arguments),
                correlationIdentifier: props.identifierGenerator(),
                freshOccurrenceIdentifier: props.identifierGenerator)
            {
            case .readOnlyQuestion:
                return ClaudeCodeHookInvocation.handle(
                    .init(
                        sourceOccurredAt: sourceOccurredAt, arguments: props.arguments,
                        environment: props.environment, standardInput: { payload },
                        identifierGenerator: props.identifierGenerator,
                        diagnosticSink: { _ in CLIDiagnostics.record(.providerHookFailed) })) ?? 0
            case .approval(let request):
                try waitForDecision(
                    request, props: props, sourceOccurredAt: sourceOccurredAt, startedAt: startedAt,
                    eventDelivery: eventDelivery)
            }
        } catch {
            CLIDiagnostics.record(.providerHookFailed)
        }
        return 0
    }

    private static func waitForDecision(
        _ request: ProviderPermissionHookRequest, props: AgentStudioIPCClientCommandLineRunner.Props,
        sourceOccurredAt: Date, startedAt: ContinuousClock.Instant, eventDelivery: ProviderHookDelivery?
    ) throws {
        let deadline = CallDeadline(limit: CLIPolicy.permissionCallLimit, startedAt: startedAt)
        do {
            let delivery =
                eventDelivery
                ?? ProviderHookDelivery.liveIPC(
                    exampleIdentifierProvider: props.identifierGenerator, environment: props.environment)
            try delivery.deliver(
                request.sessionEvent,
                try paneConfiguration(environment: props.environment))
        } catch {
            // Activity is best effort. The approval ask must still receive the full
            // remaining portion of the shared permission-call deadline.
            CLIDiagnostics.record(.providerHookFailed)
        }
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
        try PaneCLICommandRunner(props: askProps, global: global, deadline: deadline, totalDeadline: deadline).run(
            intent)
        guard deadline.remainingBudget > .zero, let text = resultText.withLock({ $0 }) else { return }
        let outcome = try JSONDecoder().decode(IPCPaneAskOutcome.self, from: Data(text.utf8))
        if let decision = try ProviderPermissionHookDecision.json(for: outcome) {
            props.standardOutputSink(decision)
        }
    }

    private static func paneConfiguration(
        environment: [String: String]
    ) throws -> AgentStudioIPCClientConfiguration {
        guard let token = environment["AGENTSTUDIO_PANE_TOKEN"], !token.isEmpty,
            let socketPath = environment["AGENTSTUDIO_IPC_SOCKET"], !socketPath.isEmpty
        else {
            throw ProviderHookFailure.methodUnavailable
        }
        return AgentStudioIPCClientConfiguration(socketPath: socketPath, authToken: token)
    }

    private static func providerVersion(
        provider: ProviderPermissionHookProvider, arguments: [String]
    ) -> String? {
        guard provider == .claude,
            let flagIndex = arguments.firstIndex(of: "--provider-version"),
            let valueIndex = arguments.index(
                flagIndex, offsetBy: 1, limitedBy: arguments.index(before: arguments.endIndex))
        else {
            return nil
        }
        let value = arguments[valueIndex]
        return value.isEmpty ? nil : value
    }
}
