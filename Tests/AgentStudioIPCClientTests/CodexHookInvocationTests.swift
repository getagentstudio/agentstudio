import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

/// Codex treats a non-zero hook exit as a reason to block the turn, so the
/// runner's contract is narrow and absolute: never a non-zero exit, never a
/// word on standard output, never the payload in a log line.
@Suite("Codex hook invocation")
struct CodexHookInvocationTests {
    @Test(
        "invalid payloads report only their refusal, never a session event",
        arguments: [
            (#"{"hook_event_name":"SessionStart"}"#, IPCSessionRefusalReason.noSessionId),
            (#"{"session_id":null}"#, .noSessionId),
            (#"{"session_id":""}"#, .noSessionId),
            ("not json", .undecodablePayload),
        ])
    func payloadRefusalIsTyped(payload: String, reason: IPCSessionRefusalReason) {
        let recorder = DeliveryRecorder()
        let status = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: "SessionStart", environment: Self.paneEnvironment,
                standardInput: { Data(payload.utf8) }, correlationIdProvider: { Self.correlationId },
                delivery: recorder.delivery, standardErrorSink: recorder.recordError))
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.refusals.count == 1)
        #expect(recorder.refusals.first?.reason == reason)
        #expect(recorder.refusals.first?.correlationId == Self.correlationId)
    }

    @Test("a spent hook deadline never starts a refusal call")
    func spentDeadlineSkipsRefusal() {
        let recorder = DeliveryRecorder()
        let status = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: "SessionStart", environment: Self.paneEnvironment,
                standardInput: { Data("{}".utf8) }, correlationIdProvider: { Self.correlationId },
                delivery: recorder.delivery, standardErrorSink: recorder.recordError,
                deadline: CallDeadline(limit: .zero)))
        #expect(status == 0)
        #expect(recorder.delivered.isEmpty)
        #expect(recorder.refusals.isEmpty)
    }

    @Test(
        "Codex SessionEnd selects the synchronous short limit; every other installed hook keeps the async limit",
        arguments: CodexHookEventName.installedEvents)
    func hookDeliverySelectsProviderLimit(event: CodexHookEventName) throws {
        let selected = ProviderHookDelivery.codexCallLimit(for: event)
        let expected: Duration = event == .sessionEnd ? .milliseconds(250) : .seconds(2)
        #expect(selected == expected)
        #expect(CLIPolicy.synchronousLifecycleHookLimit == .milliseconds(250))
    }

    @Test(
        "the selected event total includes input before delivery",
        arguments: CodexInvocationDeadlineCase.matrix)
    private func invocationDeliversCappedDeadline(testCase: CodexInvocationDeadlineCase) throws {
        let event = testCase.event
        let inputCost = testCase.inputCost
        let payload = try CodexFixtures.data(for: event)
        let timing = HookInvocationDeadlineTiming()
        let ingress = CallDeadline(limit: CLIPolicy.hookCallLimit, timing: timing)
        let recorder = DeliveryRecorder()
        let status = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: event.rawValue,
                environment: Self.paneEnvironment,
                standardInput: {
                    timing.advance(by: inputCost)
                    return payload
                },
                correlationIdProvider: { Self.correlationId },
                delivery: recorder.delivery,
                standardErrorSink: recorder.recordError,
                deadline: ingress))
        #expect(status == 0)
        #expect(recorder.errorLines.isEmpty)
        #expect(recorder.refusals.isEmpty)
        let eventLimit = ProviderHookDelivery.codexCallLimit(for: event)
        let remaining = max(Duration.zero, eventLimit - inputCost)
        if remaining == .zero {
            #expect(recorder.delivered.isEmpty)
            return
        }
        let delivered = try #require(recorder.delivered.first)
        #expect(recorder.delivered.count == 1)
        #expect(delivered.deadline.remainingBudget == remaining)
        // The delivery value keeps the injected ingress clock and its absolute expiration.
        timing.advance(by: .milliseconds(100))
        #expect(delivered.deadline.remainingBudget == max(.zero, remaining - .milliseconds(100)))
    }

    @Test("a tighter supplied SessionEnd ingress deadline remains authoritative")
    func tighterIngressDeadlineIsPreserved() throws {
        let timing = HookInvocationDeadlineTiming()
        let ingress = CallDeadline(limit: .milliseconds(100), timing: timing)
        let recorder = DeliveryRecorder()
        let payload = try CodexFixtures.data(for: .sessionEnd)

        let status = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: CodexHookEventName.sessionEnd.rawValue,
                environment: Self.paneEnvironment,
                standardInput: {
                    timing.advance(by: .milliseconds(20))
                    return payload
                },
                correlationIdProvider: { Self.correlationId },
                delivery: recorder.delivery,
                standardErrorSink: recorder.recordError,
                deadline: ingress))

        #expect(status == 0)
        #expect(try #require(recorder.delivered.first).deadline.remainingBudget == .milliseconds(80))
    }

    @Test("SessionEnd refusal shares the short total after consuming input")
    func refusalSharesSessionEndTotalAfterInput() {
        let timing = HookInvocationDeadlineTiming()
        let ingress = CallDeadline(limit: CLIPolicy.hookCallLimit, timing: timing)
        let recorder = DeliveryRecorder(timing: timing, refusalCost: .milliseconds(50))

        let status = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: CodexHookEventName.sessionEnd.rawValue,
                environment: Self.paneEnvironment,
                standardInput: {
                    timing.advance(by: .milliseconds(200))
                    return Data(#"{"session_id":""}"#.utf8)
                },
                correlationIdProvider: { Self.correlationId },
                delivery: recorder.delivery,
                standardErrorSink: recorder.recordError,
                deadline: ingress))

        #expect(status == 0)
        #expect(recorder.refusals.count == 1)
        #expect(recorder.refusals.first?.reason == .noSessionId)
        #expect(recorder.refusalBudgetsAtCall == [.milliseconds(50)])
        #expect(recorder.refusalDeadlines.first?.remainingBudget == .zero)
        #expect(timing.elapsed == .milliseconds(250))
    }

    @Test("the occurrence identifier uses the existing correlation identifier seam")
    func occurrenceIdentifierUsesCorrelationGenerator() throws {
        let occurrenceIdentifier = UUIDv7.generate()
        let correlationIdentifier = UUIDv7.generate()
        let identifiers = Mutex([occurrenceIdentifier, correlationIdentifier])
        let recorder = DeliveryRecorder()
        let payload = try CodexFixtures.data(for: .preToolUse)
        let props = ProviderHookInvocation.Props(
            eventName: CodexHookEventName.preToolUse.rawValue,
            environment: Self.paneEnvironment,
            standardInput: { payload },
            correlationIdProvider: { identifiers.withLock { $0.removeFirst() } },
            delivery: recorder.delivery,
            standardErrorSink: recorder.recordError)

        let status = ProviderHookInvocation.runCodexHook(props)

        #expect(status == 0)
        let delivered = try #require(recorder.delivered.first)
        #expect(delivered.params.event.occurrenceId == occurrenceIdentifier)
        #expect(delivered.params.correlationId == correlationIdentifier)
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

private struct CodexInvocationDeadlineCase: Sendable {
    let event: CodexHookEventName
    let inputCost: Duration

    static let matrix = [
        Self(event: .sessionEnd, inputCost: .zero),
        Self(event: .sessionEnd, inputCost: .milliseconds(200)),
        Self(event: .sessionEnd, inputCost: .milliseconds(250)),
        Self(event: .stop, inputCost: .zero),
        Self(event: .stop, inputCost: .milliseconds(1800)),
        Self(event: .stop, inputCost: .milliseconds(2100)),
    ]
}

/// Collects what the runner tried to do. A class because the runner takes
/// escaping closures and the test reads the results after they ran, all on the
/// one thread the runner uses.
private final class DeliveryRecorder: @unchecked Sendable {
    struct Delivered {
        let params: IPCSessionEventParams
        let configuration: AgentStudioIPCClientConfiguration
        let deadline: CallDeadline
    }

    private(set) var delivered: [Delivered] = []
    private(set) var refusals: [IPCSessionRefusalParams] = []
    private(set) var refusalDeadlines: [CallDeadline] = []
    private(set) var refusalBudgetsAtCall: [Duration] = []
    private(set) var errorLines: [String] = []
    private(set) var standardInputReads = 0
    private let failure: ProviderHookFailure?
    private let timing: HookInvocationDeadlineTiming?
    private let refusalCost: Duration

    init(
        failure: ProviderHookFailure? = nil,
        timing: HookInvocationDeadlineTiming? = nil,
        refusalCost: Duration = .zero
    ) {
        self.failure = failure
        self.timing = timing
        self.refusalCost = refusalCost
    }

    var delivery: ProviderHookDelivery {
        ProviderHookDelivery(
            deliver: { [self] params, configuration, deadline in
                if let failure { throw failure }
                delivered.append(Delivered(params: params, configuration: configuration, deadline: deadline))
            },
            recordRefusal: { [self] params, _, deadline in
                refusals.append(params)
                refusalDeadlines.append(deadline)
                refusalBudgetsAtCall.append(deadline.remainingBudget)
                timing?.advance(by: refusalCost)
            })
    }

    func recordError(_ line: String) {
        errorLines.append(line)
    }

    func recordStandardInputRead() {
        standardInputReads += 1
    }
}

private final class HookInvocationDeadlineTiming: CallDeadlineTiming, Sendable {
    private let origin: ContinuousClock.Instant
    private let instant: Mutex<ContinuousClock.Instant>

    init() {
        let now = ContinuousClock.now
        origin = now
        instant = Mutex(now)
    }

    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    var elapsed: Duration { origin.duration(to: instant.withLock { $0 }) }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) -> CallDeadlineReadiness {
        Issue.record("Recording delivery must not perform socket I/O")
        return .timedOut
    }
}
