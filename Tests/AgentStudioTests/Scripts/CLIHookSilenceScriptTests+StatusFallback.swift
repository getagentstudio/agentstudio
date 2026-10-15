import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

extension CLIHookSilenceScriptTests {
    @Test(
        "rejected login reconnects only for status within the original ordinary or lifecycle total",
        arguments: HookInputDeadlineCase.matrix, [false, true])
    func rejectedLoginStatusSharesIngressTotal(invocation: HookInputDeadlineCase, exhaustFallback: Bool) async throws {
        let fixture = try HookSilenceProcessFixture(condition: .up, rejectsLogin: true)
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let workspace = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        let observed: HookTotalObservation
        do {
            observed = try await valueFromDedicatedThread {
                try fixture.start()
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close() }
                let data = try JSONSerialization.data(withJSONObject: [
                    "session_id": session, "hook_event_name": invocation.event,
                ])
                try pipe.fileHandleForWriting.write(contentsOf: data)
                try pipe.fileHandleForWriting.close()
                let timing = HookInputDeadlineTiming(
                    inputDescriptor: pipe.fileHandleForReading.fileDescriptor,
                    readsPartialInput: true, completedInput: true, partialInputCost: invocation.partialInputCost,
                    networkReadyCount: 2, networkTimeoutReadIndex: exhaustFallback ? 1 : nil,
                    networkReadinessWait: { try fixture.waitForNetworkResponse($0) })
                var environment = fixture.environment(
                    executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .unset)
                environment["AGENTSTUDIO_PANE_ID"] = pane.uuidString
                environment["AGENTSTUDIO_WORKSPACE_ID"] = workspace.uuidString
                let streams = Mutex<[String]>([])
                let status = AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", invocation.provider, invocation.event], environment: environment,
                        executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { line in streams.withLock { $0.append(line) } },
                        standardErrorSink: { line in streams.withLock { $0.append(line) } },
                        standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor, deadlineTiming: timing))
                return HookTotalObservation(
                    exitCode: status, streamLines: streams.withLock { $0 }, controlledElapsed: timing.elapsed,
                    networkWaitBudgets: timing.networkWaits, ordinaryInputReadCount: 0,
                    inputWaitEvents: timing.inputWaitEvents)
            }
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
        #expect(observed.exitCode == 0)
        #expect(observed.streamLines.isEmpty)
        #expect(observed.controlledElapsed == (exhaustFallback ? invocation.totalLimit : invocation.partialInputCost))
        let remaining = invocation.totalLimit - invocation.partialInputCost
        #expect(!observed.networkWaitBudgets.isEmpty)
        #expect(observed.networkWaitBudgets.allSatisfy { $0 == remaining })
        #expect(fixture.requests.map(\.method) == ["auth.login", "session.status"])
        #expect(fixture.responses.first?.error?.code == -32_001)
        let request = try #require(fixture.requests.last?.params)
        let status = try JSONDecoder().decode(IPCSessionStatusParams.self, from: JSONEncoder().encode(request))
        #expect(status.paneClaim == .init(paneId: pane, workspaceId: workspace))
        #expect(status.tokenOutcome == .rejected)
        guard case .hook(let event, let provider, let sessionID) = status.report else {
            Issue.record("Expected projected status, not an identity event")
            return
        }
        #expect(sessionID == session)
        #expect(event.conversationId == session)
        #expect(provider.identifier == (invocation.provider == "claude" ? "claude-code" : "codex"))
        #expect(event.name == (invocation.event == "SessionEnd" ? .sessionEnd : .sessionStart))
    }
}

extension CLIHookSilenceScriptTests {
    @Test(
        "healthy hooks never fall back; absent and rejected tokens report hooks or payload refusals",
        arguments: ["claude", "codex"], HookStatusPayloadScenario.matrix)
    func statusFallbackPayloadAndTokenMatrix(
        provider: String, scenario: HookStatusPayloadScenario
    ) async throws {
        let token = scenario.token
        let payload = scenario.payload
        let fixture = try HookSilenceProcessFixture(condition: .up, rejectsLogin: token == .rejected)
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let workspace = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        let observed: Int32
        do {
            observed = try await valueFromDedicatedThread {
                try fixture.start()
                let driver = ControlledDeadlineDriver()
                defer { driver.close() }
                let pipe = Pipe()
                defer { try? pipe.fileHandleForReading.close() }
                let data: Data
                switch payload {
                case .hook:
                    data = try JSONSerialization.data(withJSONObject: [
                        "session_id": session, "hook_event_name": "SessionStart",
                    ])
                case .missingSession: data = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
                case .undecodable: data = Data("invalid private payload".utf8)
                }
                try pipe.fileHandleForWriting.write(contentsOf: data)
                try pipe.fileHandleForWriting.close()
                var environment = fixture.environment(
                    executable: URL(fileURLWithPath: "/fixture/agentstudio-cli"), storeSetting: .unset)
                environment["AGENTSTUDIO_PANE_ID"] = pane.uuidString
                environment["AGENTSTUDIO_WORKSPACE_ID"] = workspace.uuidString
                if token == .absent { environment.removeValue(forKey: "AGENTSTUDIO_PANE_TOKEN") }
                return AgentStudioIPCClientCommandLineRunner.run(
                    props: .init(
                        arguments: ["hook", provider, "SessionStart"], environment: environment,
                        executablePath: "/fixture/agentstudio-cli", bundleExecutableURL: nil,
                        standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                        standardOutputSink: { _ in Issue.record("Hook wrote stdout") },
                        standardErrorSink: { _ in Issue.record("Hook wrote stderr") },
                        standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                        deadlineTiming: driver.timing))
            }
        } catch {
            await fixture.shutdown()
            throw error
        }
        await fixture.shutdown()
        #expect(observed == 0)
        if token == .healthy {
            #expect(
                fixture.requests.map(\.method) == [
                    "auth.login", payload == .hook ? "session.event" : "session.refusal",
                ])
            return
        }
        #expect(
            fixture.requests.map(\.method)
                == (token == .absent ? ["session.status"] : ["auth.login", "session.status"]))
        let params = try #require(fixture.requests.last?.params)
        let status = try JSONDecoder().decode(IPCSessionStatusParams.self, from: JSONEncoder().encode(params))
        #expect(status.paneClaim == .init(paneId: pane, workspaceId: workspace))
        #expect(status.tokenOutcome == (token == .absent ? .absent : .rejected))
        switch payload {
        case .hook:
            guard case .hook(_, _, let sessionID) = status.report else {
                Issue.record("Missing hook status")
                return
            }
            #expect(sessionID == session)
        case .missingSession: #expect(status.report == .refusal(reason: .noSessionId))
        case .undecodable: #expect(status.report == .refusal(reason: .undecodablePayload))
        }
    }
}

enum HookStatusTokenCase: CaseIterable, Equatable, Sendable { case healthy, rejected, absent }
enum HookStatusPayloadCase: CaseIterable, Equatable, Sendable { case hook, missingSession, undecodable }

struct HookStatusPayloadScenario: Sendable {
    let token: HookStatusTokenCase
    let payload: HookStatusPayloadCase
    static let matrix = HookStatusTokenCase.allCases.flatMap { token in
        HookStatusPayloadCase.allCases.map { Self(token: token, payload: $0) }
    }
}
