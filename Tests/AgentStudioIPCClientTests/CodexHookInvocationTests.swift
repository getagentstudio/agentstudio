import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

/// Codex treats a non-zero hook exit as a reason to block the turn, so the
/// runner's contract is narrow and absolute: never a non-zero exit, never a
/// word on standard output, never the payload in a log line.
@Suite("Codex hook invocation")
struct CodexHookInvocationTests {
    @Test(
        "Codex SessionEnd selects the synchronous short limit; every other installed hook keeps the async limit",
        arguments: CodexHookEventName.installedEvents)
    func hookDeliverySelectsProviderLimit(event: CodexHookEventName) throws {
        let payload = try JSONDecoder().decode(CodexHookPayload.self, from: CodexFixtures.data(for: event))
        let projected = try #require(
            CodexHookProjection.project(eventName: event, payload: payload))
        let selected = ProviderHookDelivery.codexCallLimit(for: projected.event.name)
        let expected: Duration = event == .sessionEnd ? .milliseconds(250) : .seconds(2)
        #expect(selected == expected)
        #expect(CLIPolicy.synchronousLifecycleHookLimit == .milliseconds(250))
    }

    @Test("a projected event with a pane credential is delivered once")
    func projectedEventIsDelivered() throws {
        // Arrange
        let recorder = DeliveryRecorder()
        let props = try Self.props(
            eventName: "UserPromptSubmit", environment: Self.paneEnvironment, recorder: recorder)

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        let delivered = try #require(recorder.delivered.first)
        #expect(recorder.delivered.count == 1)
        #expect(delivered.params.handle == "self")
        #expect(delivered.params.event.name == .turnStart)

        #expect(delivered.configuration.socketPath == "/tmp/agentstudio-test.sock")
        #expect(delivered.configuration.authToken == "pane-token")
        #expect(recorder.errorLines.isEmpty)
    }

    @Test(
        "a missing pane credential exits zero, delivers nothing and says nothing",
        arguments: [
            ["AGENTSTUDIO_IPC_SOCKET": "/tmp/agentstudio-test.sock"],
            ["AGENTSTUDIO_PANE_TOKEN": "pane-token"],
            ["AGENTSTUDIO_PANE_TOKEN": "", "AGENTSTUDIO_IPC_SOCKET": "/tmp/s.sock"],
            [:],
        ]
    )
    func missingPaneCredentialIsSilent(environment: [String: String]) throws {
        // Arrange
        let recorder = DeliveryRecorder()
        let props = try Self.props(
            eventName: "SessionStart", environment: environment, recorder: recorder)

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.errorLines.isEmpty)
        #expect(recorder.standardInputReads == 0)
    }

    @Test("an event Agent Studio does not model reads nothing and delivers nothing")
    func unmodelledEventIsANoOp() throws {
        // Arrange
        let recorder = DeliveryRecorder()
        let props = try Self.props(
            eventName: "PostToolUse", environment: Self.paneEnvironment, recorder: recorder)

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.standardInputReads == 0)
        #expect(recorder.errorLines.isEmpty)
    }

    @Test("an unreadable payload exits zero and logs one line without the payload")
    func unreadablePayloadIsOneQuietLine() {
        // Arrange
        let recorder = DeliveryRecorder()
        let secret = "{not json - user prompt about the acme merger}"
        let props = ProviderHookInvocation.Props(
            eventName: "Stop",
            environment: Self.paneEnvironment,
            standardInput: { Data(secret.utf8) },
            correlationIdProvider: { Self.correlationId },
            delivery: recorder.delivery,
            standardErrorSink: recorder.recordError
        )

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.errorLines.count == 1)
        #expect(recorder.errorLines[0].contains("acme") == false)
        #expect(recorder.errorLines[0].contains("Stop"))
    }

    @Test("a rejected delivery exits zero and logs one line naming the reason")
    func rejectedDeliveryExitsZero() throws {
        // Arrange
        let recorder = DeliveryRecorder(failure: .rejected("bindingRequired"))
        let props = try Self.props(
            eventName: "SessionStart", environment: Self.paneEnvironment, recorder: recorder)

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        #expect(recorder.errorLines.count == 1)
        #expect(recorder.errorLines[0].contains("bindingRequired"))
    }

    @Test("an event name Codex never emits exits zero")
    func unknownEventNameExitsZero() throws {
        // Arrange
        let recorder = DeliveryRecorder()
        let props = try Self.props(
            eventName: "NotAnEvent", environment: Self.paneEnvironment, recorder: recorder)

        // Act
        let status = ProviderHookInvocation.runCodexHook(props)

        // Assert
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.errorLines.count == 1)
    }

    @Test(
        "the subcommand parser keys hooks and package actions by provider",
        arguments: [
            (
                ["hook", "codex", "SessionStart"],
                AgentPackageSubcommand.hook(provider: "codex", eventName: "SessionStart")
            ),
            (["package", "install", "codex"], .install(provider: "codex", providerHomePath: nil)),
            (
                ["package", "install", "codex", "--codex-home", "/tmp/home"],
                .install(provider: "codex", providerHomePath: "/tmp/home")
            ),
            (["package", "uninstall", "codex"], .uninstall(provider: "codex", providerHomePath: nil)),
        ]
    )
    func subcommandParsing(arguments: [String], expected: AgentPackageSubcommand) {
        // Arrange / Act / Assert
        #expect(AgentPackageSubcommand.parse(arguments) == expected)
    }

    @Test(
        "anything that is not a provider subcommand falls through to the descriptor surface",
        arguments: [
            ["session.query"], ["hook"], ["hook", "codex"], ["package"], ["package", "list", "codex"],
            ["package", "install"],
        ]
    )
    func nonSubcommandArgumentsFallThrough(arguments: [String]) {
        // Arrange / Act / Assert
        #expect(AgentPackageSubcommand.parse(arguments) == nil)
    }

    private static let correlationId = UUID(uuidString: "01994d31-0000-7000-8000-000000000001") ?? UUID()

    private static let paneEnvironment = [
        "AGENTSTUDIO_PANE_TOKEN": "pane-token",
        "AGENTSTUDIO_IPC_SOCKET": "/tmp/agentstudio-test.sock",
    ]

    private static func props(
        eventName: String,
        environment: [String: String],
        recorder: DeliveryRecorder
    ) throws -> ProviderHookInvocation.Props {
        let payload = CodexHookEventName(rawValue: eventName).flatMap {
            try? CodexFixtures.data(for: $0)
        }
        return ProviderHookInvocation.Props(
            eventName: eventName,
            environment: environment,
            standardInput: {
                recorder.recordStandardInputRead()
                return payload ?? Data("{}".utf8)
            },
            correlationIdProvider: { correlationId },
            delivery: recorder.delivery,
            standardErrorSink: recorder.recordError
        )
    }
}

/// Collects what the runner tried to do. A class because the runner takes
/// escaping closures and the test reads the results after they ran, all on the
/// one thread the runner uses.
private final class DeliveryRecorder: @unchecked Sendable {
    struct Delivered {
        let params: IPCSessionEventParams
        let configuration: AgentStudioIPCClientConfiguration
    }

    private(set) var delivered: [Delivered] = []
    private(set) var errorLines: [String] = []
    private(set) var standardInputReads = 0
    private let failure: ProviderHookFailure?

    init(failure: ProviderHookFailure? = nil) {
        self.failure = failure
    }

    var delivery: ProviderHookDelivery {
        ProviderHookDelivery { [self] params, configuration, _ in
            if let failure { throw failure }
            delivered.append(Delivered(params: params, configuration: configuration))
        }
    }

    func recordError(_ line: String) {
        errorLines.append(line)
    }

    func recordStandardInputRead() {
        standardInputReads += 1
    }
}
