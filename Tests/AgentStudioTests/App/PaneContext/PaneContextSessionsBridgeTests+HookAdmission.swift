import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension PaneContextSessionsBridgeTests {
    @Test(
        "each binding decision row passes through the real adapter and SQLite owner",
        arguments: AdapterBindingRow.allCases)
    func adapterBindingTable(row: AdapterBindingRow) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(ingestion: fixture.ingestion, now: { fixture.time.now })
            let paneId = fixture.paneId.uuid
            let otherPane = PaneId.generateUUIDv7()
            fixture.membership.addPane(otherPane)
            switch row {
            case .startEmpty, .activityEmpty: break
            case .startReplaces, .unseenReplaces:
                _ = try await sendBindingHook(
                    adapter, pane: paneId, session: "other", name: .sessionStart)
            case .startMoves, .activeElsewhere:
                _ = try await sendBindingHook(
                    adapter, pane: otherPane.uuid, session: "session-A", name: .sessionStart)
            case .active, .ended, .startRevives:
                _ = try await sendBindingHook(
                    adapter, pane: paneId, session: "session-A", name: .sessionStart)
            }
            if row == .ended || row == .startRevives {
                _ = try await sendBindingHook(
                    adapter, pane: paneId, session: "session-A", name: .sessionEnd)
            }
            let start = [AdapterBindingRow.startEmpty, .startReplaces, .startMoves, .startRevives].contains(row)
            let admitted = try await sendBindingHook(
                adapter, pane: paneId, session: "session-A",
                name: start ? .sessionStart : .toolActivity)
            #expect(admitted.disposition == .admitted)
            let read = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
            switch row {
            case .activeElsewhere:
                #expect(read.sourceHealth == .unbound)
                let other = try await adapter.readSessionState(paneId: otherPane.uuid, params: .init(handle: "self"))
                #expect(other.sourceHealth == .live)
                #expect(other.session?.status == .unknown)
            case .ended:
                #expect(read.sourceHealth == .ended)
                #expect(read.session?.status == .idle(state: .ended))
            default:
                #expect(read.sourceHealth == .live)
                #expect(read.session?.conversationId == "session-A")
                #expect(read.session?.status == (start ? .unknown : .working(state: .active)))
            }
            if row == .startMoves {
                #expect(
                    try await adapter.readSessionState(paneId: otherPane.uuid, params: .init(handle: "self"))
                        .sourceHealth == .ended)
            }
        }
    }

    @Test(
        "real adapter binds a first non-start hook without a provider-version gate",
        arguments: ["2.1.289", "0.160.0", "9.9.9"])
    func firstHookUsesPaneAndSession(version: String) async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(ingestion: fixture.ingestion, now: { fixture.time.now })
            let params = hookParameters(name: .toolActivity, session: "running", version: version)
            let accepted = try await adapter.recordProviderEvent(
                paneId: fixture.paneId.uuid, params: params, provenance: .matchingPane)
            #expect(accepted.disposition == .admitted)
            let query = try await adapter.readSessionState(paneId: fixture.paneId.uuid, params: .init(handle: "self"))
            #expect(query.session?.status == .working(state: .active))
            let detail = try await AgentStudioIPCPaneContextAdapter(
                service: fixture.service, ingestion: fixture.ingestion
            )
            .readContext(
                paneId: fixture.paneId.uuid, params: .init(handle: "self", page: .first),
                replyEnvelopeOverheadBytes: 128)
            #expect(detail.session == query.session)
        }
    }

    @Test("ended record-only permission stays out of status after reopen; only Start revives")
    func endedFactCannotReopenStatus() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(ingestion: fixture.ingestion, now: { fixture.time.now })
            for name in [IPCSessionEventName.sessionEnd, .permission] {
                _ = try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid,
                    params: hookParameters(name: name, session: "ended"), provenance: .matchingPane)
            }
            let before = try await fixture.ingestion.sessionSummary(paneId: fixture.paneId.uuid)
            #expect(before?.status == .idle(.ended))
            await fixture.ingestion.finish()
            let restored = fixture.makeIngestion()
            fixture.bridge.connect(service: fixture.service, ingestion: restored)
            do {
                #expect(try await restored.sessionSummary(paneId: fixture.paneId.uuid) == before)
                _ = try await AgentStudioIPCSessionsAdapter(ingestion: restored).recordProviderEvent(
                    paneId: fixture.paneId.uuid,
                    params: hookParameters(name: .sessionStart, session: "ended"), provenance: .matchingPane)
                #expect(try await restored.sessionSummary(paneId: fixture.paneId.uuid)?.status == .unknown)
                await restored.finish()
            } catch {
                await restored.finish()
                throw error
            }
        }
    }

    @Test("same wire identity is not hook replay and changed content still records")
    func wireIdentityDoesNotGateHook() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let adapter = AgentStudioIPCSessionsAdapter(ingestion: fixture.ingestion)
            let first = hookParameters(name: .toolActivity, session: "first")
            for session in ["first", "first", "replacement"] {
                let event = IPCSessionEventIdentity(
                    name: .toolActivity, conversationId: session, turnId: "same-turn",
                    requestId: nil, toolId: "same-tool", subagentId: nil, occurrenceId: first.event.occurrenceId)
                _ = try await adapter.recordProviderEvent(
                    paneId: fixture.paneId.uuid,
                    params: .init(
                        handle: "self", provider: first.provider, event: event, correlationId: first.correlationId),
                    provenance: .matchingPane)
            }
            let context = try await fixture.ingestion.repository.statusContext(paneId: fixture.paneId.uuid)
            #expect(context.evidence.count == 3)
            #expect(Set(context.evidence.map(\.recordId)).count == 3)
            #expect(context.currentBinding?.providerConversationId == "replacement")
        }
    }
}

enum AdapterBindingRow: CaseIterable, Equatable, Sendable {
    case startEmpty, activityEmpty, active, startReplaces, unseenReplaces, startMoves, activeElsewhere, ended,
        startRevives
}

private func sendBindingHook(
    _ adapter: AgentStudioIPCSessionsAdapter,
    pane: UUID, session: String, name: IPCSessionEventName
) async throws -> IPCSessionEventResult {
    try await adapter.recordProviderEvent(
        paneId: pane,
        params: hookParameters(name: name, session: session), provenance: .matchingPane)
}

private func hookParameters(
    name: IPCSessionEventName, session: String,
    version: String = "9.9.9"
) -> IPCSessionEventParams {
    .init(
        handle: "self", provider: .init(identifier: "claude-code", version: version, mode: "cli"),
        event: .init(
            name: name, conversationId: session, turnId: "turn-A", requestId: nil, toolId: nil,
            subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate())
}
