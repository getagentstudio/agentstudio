import AgentStudioDeadlineTestSupport
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Approval CLI through the real socket and service", .serialized)
struct CLIPaneContextApprovalTests {
    @Test("G24 the real CLI prints Approve with reason or Deny without one", arguments: [true, false])
    func decisionsRoundTripThroughTheRealRunner(approve: Bool) async throws {
        try await withS5PaneCLIContext { context in
            let reason = approve ? "Reviewed the migration" : nil
            let answer = AskAnswerValue.decision(approve ? .approve : .deny, reason: reason)
            let arguments = ["approval", "Approve migration?", "--timeout", "10"]
            let run = try await runWaiting(context, arguments: arguments) { request in
                #expect(
                    await context.domain.service.answer(
                        .init(
                            messageId: .init(existingUUID: request.messageId),
                            paneId: .init(existingUUID: context.domain.paneId),
                            by: .localUser, value: answer)) == .answered)
            }
            #expect(run.output.exitCode == 0)
            #expect(run.output.standardError.isEmpty)
            let output = try JSONDecoder().decode([String: String].self, from: Data(run.output.standardOutput.utf8))
            #expect(
                output
                    == (approve ? ["decision": "approve", "reason": "Reviewed the migration"] : ["decision": "deny"]))
            #expect(context.port.wire.methods == ["auth.login", "pane.message.ask"])
            #expect(context.port.asks.count == 1)
            #expect(context.port.messages.isEmpty)
            #expect(run.request.writer == context.writer)
            #expect(
                run.request.shape
                    == .ask(
                        reason: .approval, form: .approval,
                        waiting: .blocking(deadline: context.domain.time.now.addingTimeInterval(10))))
            let source = PaneId(existingUUID: context.domain.paneId)
            let read = await context.domain.service.readDetail(.init(paneId: source, page: .first))
            let detail = try #require(
                { () -> PaneContextDetail? in
                    if case .detail(let value) = read { return value }
                    return nil
                }())
            #expect(
                detail.messages.first?.shape
                    == .ask(
                        .approval, .approval,
                        .blocking(deadline: context.domain.time.now.addingTimeInterval(10)),
                        .answered(by: .localUser, value: answer, receipt: .notYetConfirmed)))
            let display = try #require(await context.domain.service.readDisplay(paneId: source))
            #expect(display.own.kinds == .zero)
            #expect(display.own.oldestOpenAsk == nil)
        }
    }

    enum Terminal: String, CaseIterable, Sendable { case expired, handedBack, withdrawn, stale }

    @Test("G24 every non-answer outcome matches ask --wait byte for byte", arguments: Terminal.allCases)
    func terminalOutputRetainsAskParity(_ terminal: Terminal) async throws {
        let approval = try await terminalOutput(verb: "approval", terminal: terminal)
        let ask = try await terminalOutput(verb: "ask", terminal: terminal)

        #expect(approval.exitCode == ask.exitCode)
        #expect(approval.standardOutput == ask.standardOutput)
        #expect(approval.standardError == ask.standardError)
        #expect(approval.standardOutput.contains("\"kind\":\"\(terminal.rawValue)\""))
        #expect(!approval.standardOutput.contains("\"decision\""))
    }

    @Test("G24 binding and storage failures retain ask --wait output and exit", arguments: [false, true])
    func failuresRetainAskParity(storageUnavailable: Bool) async throws {
        try await withS5PaneCLIContext(bindSession: storageUnavailable) { context in
            if storageUnavailable { await context.domain.service.stop() }
            let approval = await context.runWithWallClock(
                ["approval", "Request", "--timeout", "10"], now: context.domain.time.now)
            let ask = await context.runWithWallClock(
                ["ask", "Request", "--reason", "approval", "--wait", "--timeout", "10"], now: context.domain.time.now)

            #expect(approval.exitCode != 0)
            #expect(approval.exitCode == ask.exitCode)
            #expect(approval.standardOutput == ask.standardOutput)
            #expect(approval.standardError == ask.standardError)
            #expect(approval.standardError.contains(storageUnavailable ? "unavailable" : "bindingRequired"))
            #expect(!approval.standardOutput.contains("\"decision\""))
        }
    }

    private func terminalOutput(verb: String, terminal: Terminal) async throws -> ClientCommandLineOutcome {
        try await withS5PaneCLIContext { context in
            let arguments =
                verb == "approval"
                ? ["approval", "Request", "--timeout", "10"]
                : ["ask", "Request", "--reason", "approval", "--wait", "--timeout", "10"]
            let run = try await runWaiting(context, arguments: arguments) { request in
                let id = AgentMessageId(existingUUID: request.messageId)
                let pane = PaneId(existingUUID: context.domain.paneId)
                switch terminal {
                case .expired: context.domain.clock.advance(by: .seconds(10))
                case .handedBack:
                    #expect(await context.domain.service.dismiss(messageId: id, paneId: pane) == .done)
                case .withdrawn:
                    #expect(
                        await context.domain.service.settleAsk(id, paneId: pane, cause: .callerGone)
                            == .settled(.withdrawn))
                case .stale:
                    #expect(
                        await context.domain.service.settleAsk(id, paneId: pane, cause: .appStopping)
                            == .settled(.stale))
                }
            }
            return run.output
        }
    }

    private func runWaiting(
        _ context: S5PaneCLIContext, arguments: [String],
        settle: @Sendable (IPCPaneMessageAskParams) async throws -> Void
    ) async throws -> (output: ClientCommandLineOutcome, request: IPCPaneMessageAskParams) {
        let recorder = try context.domain.facts.attach()
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        let now = context.domain.time.now
        let call = Task {
            let output = await context.runWithWallClock(arguments, now: now, deadlineTiming: driver.timing)
            context.domain.facts.sink(context.domain.paneId, .joined)
            return output
        }
        do {
            // A refusal/client completion closes this same scope, so admission cannot hang.
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(1))
            let request = try #require(context.port.asks.last)
            try await settle(request)
            return (await call.value, request)
        } catch {
            driver.cancel()
            call.cancel()
            _ = await call.value
            throw error
        }
    }
}
