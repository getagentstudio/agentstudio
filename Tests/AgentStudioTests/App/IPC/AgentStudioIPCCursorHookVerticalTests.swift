import AgentStudioDeadlineTestSupport
import AgentStudioIPCClientCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("App IPC Cursor hook vertical", .serialized)
struct AgentStudioIPCCursorHookVerticalTests {
    @Test("Cursor prompt and stop report the real session status", arguments: ["completed", "aborted", "error"])
    func cursorTurnReachesSessions(stopStatus: String) async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            try #require(try await runHook("beforeSubmitPrompt", conversation: "cursor-A", harness: harness) == 0)
            let working = try await harness.sessionQuery(paneId: harness.boundPaneId)
            #expect(working.session?.status == .working(state: .active))
            try #require(try await runHook("stop", conversation: "cursor-A", status: stopStatus, harness: harness) == 0)
            let stopped = try await harness.sessionQuery(paneId: harness.boundPaneId)
            switch stopStatus {
            case "completed": #expect(stopped.session?.status == .idle(state: .done))
            case "aborted": #expect(stopped.session?.status == .idle(state: .interrupted))
            default:
                guard case .failed? = stopped.session?.status else {
                    Issue.record("Cursor error stop must report failed")
                    await harness.tearDown()
                    return
                }
            }
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("Cursor keeps the active main and binds a successor only after session end")
    func cursorRespectsMainSessionAdmission() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            _ = try await runHook("beforeSubmitPrompt", conversation: "cursor-A", harness: harness)
            _ = try await runHook("beforeSubmitPrompt", conversation: "cursor-B", harness: harness)
            let active = try await harness.sessionQuery(paneId: harness.boundPaneId)
            #expect(active.session?.conversationId == "cursor-A")
            _ = try await runHook("sessionEnd", conversation: "cursor-A", harness: harness)
            _ = try await runHook("beforeSubmitPrompt", conversation: "cursor-B", harness: harness)
            let successor = try await harness.sessionQuery(paneId: harness.boundPaneId)
            #expect(successor.session?.conversationId == "cursor-B")
            #expect(successor.session?.status == .working(state: .active))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    private func runHook(
        _ event: String, conversation: String, status: String? = nil, harness: SessionsVerticalHarness
    ) async throws -> Int32 {
        let environment = [
            "AGENTSTUDIO_IPC_SOCKET": harness.socketPath,
            "AGENTSTUDIO_PANE_ID": harness.boundPaneId.uuidString,
            "AGENTSTUDIO_WORKSPACE_ID": harness.commandHarness.store.identityAtom.workspaceId.uuidString,
            "AGENTSTUDIO_PANE_TOKEN": harness.boundPaneToken?.rawValue ?? "",
        ]
        let driver = ControlledDeadlineDriver()
        defer { driver.close() }
        return try await valueFromDedicatedThread {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForReading.close() }
            var payload = ["conversation_id": conversation, "generation_id": "turn", "hook_event_name": event]
            payload["status"] = status
            defer { try? pipe.fileHandleForWriting.close() }
            try pipe.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(payload))
            try pipe.fileHandleForWriting.close()
            return AgentStudioIPCClientCommandLineRunner.run(
                props: .init(
                    arguments: ["hook", "cursor", event], environment: environment,
                    executablePath: "/isolated-fixture/agentstudio", bundleExecutableURL: nil,
                    standardInput: { Data() }, identifierGenerator: { UUIDv7.generate() },
                    standardOutputSink: { _ in }, standardErrorSink: { _ in },
                    standardInputFileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                    deadlineTiming: driver.timing))
        }
    }
}
