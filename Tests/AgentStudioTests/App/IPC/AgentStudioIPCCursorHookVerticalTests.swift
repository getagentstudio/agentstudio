import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Drives real Cursor hook documents through the projection, the real IPC socket
/// and the real Sessions database. Nothing here hand-writes a `session.event`
/// body: whatever the installed hook would send is what the app admits, so a
/// projection change that the app refuses fails here.
@MainActor
@Suite("Cursor hook vertical", .serialized)
struct AgentStudioIPCCursorHookVerticalTests {
    init() { installTestCoreAtomsIfNeeded() }

    /// The projected call, retargeted from the hook's `self` handle to the
    /// harness pane. Only the handle changes: provider identity, event identity
    /// and the derived occurrence stay exactly as the hook would send them.
    private static func addressed(_ event: String, to paneId: UUID) throws -> IPCSessionEventParams {
        let params = try CursorHookTestDocuments.projectedParams(event)
        return IPCSessionEventParams(
            handle: paneId.uuidString,
            provider: params.provider,
            event: params.event,
            correlationId: params.correlationId
        )
    }

    private func send(
        _ event: String,
        paneId: UUID,
        harness: SessionsVerticalHarness
    ) async throws -> IPCSessionEventResult {
        try await harness.decoded(
            method: "session.event",
            params: try JSONDecoder().decode(
                JSONValue.self, from: try JSONEncoder().encode(Self.addressed(event, to: paneId))
            )
        )
    }

    @Test("A real Cursor session's hooks bind the pane and complete the turn")
    func cursorHooksDriveTheSessionLifecycle() async throws {
        // Arrange
        let harness = try await SessionsVerticalHarness.make(
            additionalProviderProfiles: [.cursorCommandLine]
        )
        do {
            let paneId = harness.boundPaneId

            // Act
            let sessionStart = try await send("sessionStart", paneId: paneId, harness: harness)
            let turnStart = try await send("beforeSubmitPrompt", paneId: paneId, harness: harness)
            let tool = try await send("preToolUse", paneId: paneId, harness: harness)
            let afterTool = try await harness.sessionQuery(paneId: paneId)
            let turnDone = try await send("stop", paneId: paneId, harness: harness)
            let afterStop = try await harness.sessionQuery(paneId: paneId)
            let sessionEnd = try await send("sessionEnd", paneId: paneId, harness: harness)
            let afterSessionEnd = try await harness.sessionQuery(paneId: paneId)

            // Assert
            #expect(sessionStart.disposition == .admitted)
            #expect(turnStart.disposition == .admitted)
            #expect(tool.disposition == .admitted)
            #expect(turnDone.disposition == .admitted)
            #expect(sessionEnd.disposition == .admitted)
            #expect(afterTool.sourceHealth == .live)
            // Cursor reports nothing that asks the person for a decision, so a
            // Cursor session never reaches needs-you from its hooks alone.
            #expect(afterTool.session?.status == .working(state: .active))
            #expect(afterStop.sourceHealth == .live)
            // `sessionEnd` retires the source generation itself rather than
            // recording evidence against it, so the pane reports a source that has
            // ended rather than one that is live with nothing arriving on it.
            #expect(afterSessionEnd.sourceHealth == .ended)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("A replayed tool-use hook returns its recorded outcome without being counted twice")
    func replayedToolHookReturnsRecordedOutcome() async throws {
        // Arrange: the hook derives one occurrence identity per tool invocation
        // but mints a fresh correlation per process, so a Cursor retry of the
        // same hook arrives as the same occurrence under a new correlation.
        let harness = try await SessionsVerticalHarness.make(
            additionalProviderProfiles: [.cursorCommandLine]
        )
        do {
            let paneId = harness.boundPaneId
            _ = try await send("sessionStart", paneId: paneId, harness: harness)
            _ = try await send("beforeSubmitPrompt", paneId: paneId, harness: harness)
            let firstParams = try Self.addressed("preToolUse", to: paneId)
            let replayParams = try Self.addressed("preToolUse", to: paneId)
            #expect(replayParams.provider == firstParams.provider)
            #expect(replayParams.event == firstParams.event)
            #expect(replayParams.handle == firstParams.handle)
            #expect(replayParams.correlationId != firstParams.correlationId)
            let first = try await harness.sessionEvent(params: firstParams)
            let beforeReplay = try await harness.paneSnapshot(paneId: paneId)
            let beforeStatus = try await harness.sessionQuery(paneId: paneId).session

            // Act
            let replay = try await harness.response(
                method: "session.event",
                params: try JSONDecoder().decode(
                    JSONValue.self,
                    from: try JSONEncoder().encode(replayParams)
                )
            )

            // Assert
            #expect(first.disposition == .admitted)
            #expect(replay.error == nil)
            let recordedResult = try #require(replay.result)
            let replayResult = try JSONDecoder().decode(
                IPCSessionEventResult.self, from: JSONEncoder().encode(recordedResult))
            #expect(replayResult.disposition == .admitted)
            #expect(replayResult.paneId == first.paneId)
            #expect(replayResult.correlationId == replayParams.correlationId)
            let afterReplay = try await harness.paneSnapshot(paneId: paneId)
            let afterStatus = try await harness.sessionQuery(paneId: paneId).session
            #expect(afterStatus == beforeStatus)
            // Correlation aliases advance the operation ledger, not the domain state.
            #expect(afterReplay.currentBinding == beforeReplay.currentBinding)
            #expect(afterReplay.staleAttention == beforeReplay.staleAttention)
            #expect(afterReplay.results == beforeReplay.results)
            #expect(Set(afterReplay.historicalOccurrenceIds) == Set(beforeReplay.historicalOccurrenceIds))
            #expect(afterReplay.losses == beforeReplay.losses)
            #expect(try await harness.sessionQuery(paneId: paneId).session?.status == .working(state: .active))
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    @Test("Another Cursor release is refused rather than admitted as qualified")
    func unknownReleaseIsRefused() async throws {
        // Arrange
        let harness = try await SessionsVerticalHarness.make(
            additionalProviderProfiles: [.cursorCommandLine]
        )
        do {
            let projected = try CursorHookTestDocuments.projectedParams("sessionStart")
            let upgraded = IPCSessionEventParams(
                handle: harness.sparePaneId.uuidString,
                provider: IPCSessionProviderIdentity(
                    identifier: projected.provider.identifier,
                    version: "2099.01.01-ffffff0",
                    mode: projected.provider.mode
                ),
                event: projected.event,
                correlationId: UUIDv7.generate()
            )

            // Act
            let result: IPCSessionEventResult = try await harness.decoded(
                method: "session.event",
                params: try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(upgraded))
            )

            // Assert
            #expect(result.disposition == .unknownCapability)
            #expect(try await harness.sessionQuery(paneId: harness.sparePaneId).sourceHealth == .unbound)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

}
