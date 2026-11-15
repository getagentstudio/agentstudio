import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Cursor hook invocation")
struct CursorHookInvocationTests {
    @Test("input, rejected login and status fallback share the Cursor hook deadline")
    func cursorDeadlineIncludesInputAndFallback() {
        let timing = CursorHookTiming()
        let budgets = Mutex<[Duration]>([])
        let delivery = ProviderHookDelivery(
            deliver: { _, _, deadline in
                budgets.withLock { $0.append(deadline.remainingBudget) }
                timing.advance(by: .milliseconds(500))
                throw IPCDescriptorClientFailure(disposition: .authenticationRejected, reason: .authenticationResponse)
            },
            recordRefusal: { _, _, _ in Issue.record("Valid input must not produce a payload refusal") },
            reportStatus: { _, _, deadline in
                budgets.withLock { $0.append(deadline.remainingBudget) }
                timing.advance(by: .milliseconds(500))
                #expect(deadline.remainingBudget == .zero)
            })
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: "beforeSubmitPrompt", environment: Self.environment,
                standardInput: {
                    timing.advance(by: .seconds(1))
                    return Data(#"{"conversation_id":"session","generation_id":"turn"}"#.utf8)
                },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery, standardErrorSink: { _ in },
                deadline: CallDeadline(limit: .seconds(5), timing: timing)))
        #expect(result == 0)
        #expect(budgets.withLock { $0 } == [.seconds(1), .milliseconds(500)])
        #expect(timing.elapsed == .seconds(2))
    }

    @Test("input and delivery errors never escape the hook", arguments: [false, true])
    func failuresReturnZero(inputFails: Bool) {
        let diagnostics = Mutex<[String]>([])
        let refusals = Mutex<[IPCSessionRefusalReason]>([])
        let delivery = ProviderHookDelivery(
            deliver: { _, _, _ in throw CursorInputError.closed },
            recordRefusal: { params, _, _ in refusals.withLock { $0.append(params.reason) } },
            reportStatus: { _, _, _ in Issue.record("An ordinary delivery failure must not retry without auth") })
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: "beforeSubmitPrompt", environment: Self.environment,
                standardInput: {
                    if inputFails { throw CursorInputError.closed }
                    return Data(#"{"conversation_id":"session"}"#.utf8)
                },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery,
                standardErrorSink: { label in diagnostics.withLock { $0.append(label) } }))
        #expect(result == 0)
        #expect(refusals.withLock { $0 } == (inputFails ? [.undecodablePayload] : []))
        #expect(diagnostics.withLock { $0 } == [inputFails ? "undecodablePayload" : "appUnavailable"])
    }

    @Test(
        "invalid input reports a finite refusal without a session event",
        arguments: [
            ("{}", IPCSessionRefusalReason.noSessionId),
            (#"{"conversation_id":null}"#, .noSessionId),
            (#"{"conversation_id":""}"#, .noSessionId),
            ("not json", .undecodablePayload),
        ])
    func invalidPayloadRefuses(scenario: (String, IPCSessionRefusalReason)) {
        let events = Mutex<[IPCSessionEventParams]>([])
        let refusals = Mutex<[IPCSessionRefusalParams]>([])
        let delivery = ProviderHookDelivery(
            deliver: { params, _, _ in events.withLock { $0.append(params) } },
            recordRefusal: { params, _, _ in refusals.withLock { $0.append(params) } },
            reportStatus: { _, _, _ in })
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: "beforeSubmitPrompt", environment: Self.environment,
                standardInput: { Data(scenario.0.utf8) },
                correlationIdProvider: { UUIDv7.generate() },
                delivery: delivery, standardErrorSink: { _ in }))
        #expect(result == 0)
        #expect(events.withLock { $0.isEmpty })
        #expect(refusals.withLock { $0.map(\.reason) } == [scenario.1])
    }

    @Test("rejected login uses the existing pane-status route", arguments: [false, true])
    func statusFallback(absentToken: Bool) {
        let statuses = Mutex<[IPCSessionStatusParams]>([])
        let delivery = ProviderHookDelivery(
            deliver: { _, _, _ in
                throw IPCDescriptorClientFailure(disposition: .authenticationRejected, reason: .authenticationResponse)
            },
            recordRefusal: { _, _, _ in },
            reportStatus: { params, configuration, _ in
                #expect(configuration.authToken == nil)
                statuses.withLock { $0.append(params) }
            })
        var environment = Self.environment
        if absentToken { environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN") }
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: "beforeSubmitPrompt", environment: environment,
                standardInput: { Data(#"{"conversation_id":"session","generation_id":"turn"}"#.utf8) },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery, standardErrorSink: { _ in }))
        #expect(result == 0)
        let reports = statuses.withLock { $0 }
        #expect(reports.count == 1)
        #expect(reports.first?.tokenOutcome == (absentToken ? .absent : .rejected))
        guard case .hook(let event, let provider, let session)? = reports.first?.report else {
            Issue.record("Cursor fallback must carry its hook fact")
            return
        }
        #expect(provider.identifier == "cursor")
        #expect(session == "session")
        #expect(event.name == .turnStart)
    }

    @Test("unknown hooks skip input and an exhausted deadline never sends", arguments: [false, true])
    func silentFailurePaths(unknown: Bool) {
        let calls = Mutex(0)
        let delivery = ProviderHookDelivery(
            deliver: { _, _, _ in calls.withLock { $0 += 1 } },
            recordRefusal: { _, _, _ in calls.withLock { $0 += 1 } },
            reportStatus: { _, _, _ in calls.withLock { $0 += 1 } })
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: unknown ? "futureHook" : "beforeSubmitPrompt", environment: Self.environment,
                standardInput: {
                    if unknown { Issue.record("Unregistered hook must not read input") }
                    return Data(#"{"conversation_id":"session"}"#.utf8)
                },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery, standardErrorSink: { _ in },
                deadline: CallDeadline(limit: .zero)))
        #expect(result == 0)
        #expect(calls.withLock { $0 } == 0)
    }

    private static var environment: [String: String] {
        [
            "AGENTSTUDIO_PANE_TOKEN": "fixture", "AGENTSTUDIO_IPC_SOCKET": "/fixture/socket",
            "AGENTSTUDIO_PANE_ID": UUIDv7.generate().uuidString,
            "AGENTSTUDIO_WORKSPACE_ID": UUIDv7.generate().uuidString,
        ]
    }
}

private enum CursorInputError: Error { case closed }

private final class CursorHookTiming: CallDeadlineTiming, Sendable {
    private let origin = ContinuousClock.now
    private let elapsedTime = Mutex<Duration>(.zero)
    var elapsed: Duration { elapsedTime.withLock { $0 } }
    func now() -> ContinuousClock.Instant { origin.advanced(by: elapsed) }
    func advance(by duration: Duration) { elapsedTime.withLock { $0 += duration } }
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) -> CallDeadlineReadiness {
        Issue.record("The injected delivery must not wait on a socket")
        return .timedOut
    }
}

extension CursorHookInvocationTests {
    @Test(
        "all six observer payloads cross the real invocation decoder",
        arguments: ["sessionStart", "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop"])
    func observerInvocation(eventName: String) {
        let events = Mutex<[IPCSessionEventParams]>([])
        let delivery = ProviderHookDelivery(
            deliver: { params, _, _ in events.withLock { $0.append(params) } },
            recordRefusal: { _, _, _ in Issue.record("Valid observer payload was refused") },
            reportStatus: { _, _, _ in Issue.record("Authenticated delivery must not fall back") })
        let result = ProviderHookInvocation.runCursorHook(
            .init(
                eventName: eventName, environment: Self.environment,
                standardInput: {
                    Data(
                        #"{"conversation_id":"parent","generation_id":"turn","tool_use_id":"tool-A","tool_name":"Shell","subagent_id":"child-A","status":"error"}"#
                            .utf8)
                },
                correlationIdProvider: { UUIDv7.generate() }, delivery: delivery, standardErrorSink: { _ in }))
        #expect(result == 0)
        let delivered = events.withLock { $0 }
        #expect(delivered.count == 1)
        let expected: IPCSessionEventName
        switch eventName {
        case "sessionStart": expected = .sessionStart
        case "preToolUse": expected = .toolActivity
        case "postToolUse": expected = .toolCompleted
        case "postToolUseFailure": expected = .toolFailed
        default: expected = .subagentActivity
        }
        #expect(delivered.first?.event.name == expected)
    }
}
