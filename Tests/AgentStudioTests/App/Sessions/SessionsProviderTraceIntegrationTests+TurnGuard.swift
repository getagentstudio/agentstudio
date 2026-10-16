import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test(
        "turn guard uses the real adapter live and after SQLite reload",
        arguments: AdapterTurnGuardRow.allCases, [false, true])
    func adapterTurnGuardTable(row: AdapterTurnGuardRow, reopen: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let paneId = UUIDv7.generate()
        if reopen {
            try await fixture.withIngestion { _, adapter in
                try await primeTurnGuard(row, adapter: adapter, paneId: paneId)
            }
            try await fixture.withIngestion { ingestion, adapter in
                try await assertTurnGuard(row, ingestion: ingestion, adapter: adapter, paneId: paneId)
            }
        } else {
            try await fixture.withIngestion { ingestion, adapter in
                try await primeTurnGuard(row, adapter: adapter, paneId: paneId)
                try await assertTurnGuard(row, ingestion: ingestion, adapter: adapter, paneId: paneId)
            }
        }
    }
}

enum AdapterTurnGuardRow: CaseIterable, Equatable, Sendable {
    case permissionAfterView, lateFailureInNextTurn, delayedStopAndTool, unnamedStop, twoTurnsOld
    case interruptDoesNotClose, unnamedWithoutOpen

    var prelude: [(IPCSessionEventName, String?)] {
        let activity: (IPCSessionEventName, String?) = (.toolActivity, "A")
        switch self {
        case .permissionAfterView, .delayedStopAndTool, .unnamedWithoutOpen:
            return [activity, (.turnDone, "A")]
        case .lateFailureInNextTurn:
            return [activity, (.turnDone, "A"), (.toolActivity, "B")]
        case .unnamedStop: return [activity, (.turnDone, nil)]
        case .twoTurnsOld: return [activity, (.turnDone, "A"), (.toolActivity, "B"), (.turnDone, "B")]
        case .interruptDoesNotClose: return [activity, (.turnAbort, "A")]
        }
    }

    var lateFacts: [(IPCSessionEventName, String?)] {
        switch self {
        case .permissionAfterView, .unnamedStop: return [(.permission, "A")]
        case .lateFailureInNextTurn: return [(.turnFailed, "A")]
        case .delayedStopAndTool: return [(.turnDone, "A"), (.toolActivity, "A")]
        case .twoTurnsOld, .interruptDoesNotClose: return [(.toolActivity, "A")]
        case .unnamedWithoutOpen: return [(.toolActivity, nil)]
        }
    }

    var expectedStatus: IPCPaneSessionStatus {
        switch self {
        case .permissionAfterView: .idle(state: .ready)
        case .delayedStopAndTool, .unnamedStop: .idle(state: .done)
        case .lateFailureInNextTurn, .twoTurnsOld, .interruptDoesNotClose, .unnamedWithoutOpen:
            .working(state: .active)
        }
    }
}

private func primeTurnGuard(
    _ row: AdapterTurnGuardRow, adapter: AgentStudioIPCSessionsAdapter, paneId: UUID
) async throws {
    for (name, turnId) in row.prelude {
        try await sendTurnGuardHook(name, turnId: turnId, adapter: adapter, paneId: paneId)
    }
}

private func assertTurnGuard(
    _ row: AdapterTurnGuardRow, ingestion: SessionsIngestion,
    adapter: AgentStudioIPCSessionsAdapter, paneId: UUID
) async throws {
    let initial = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
    #expect(initial.sourceHealth == .live)
    #expect(initial.session?.conversationId == "guard-session")
    if row == .permissionAfterView {
        // This explicit view fact is causally after the returned Stop/read.
        // Its strict offset is semantic input, never a wait or a time budget.
        ingestion.paneViewedMailbox.noteViewed(
            paneId, viewedAt: ContinuousClock.now.advanced(by: .nanoseconds(1)))
        let viewed = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
        #expect(viewed.session?.status == .idle(state: .ready))
    }
    for (name, turnId) in row.lateFacts {
        try await sendTurnGuardHook(name, turnId: turnId, adapter: adapter, paneId: paneId)
    }
    let result = try await adapter.readSessionState(paneId: paneId, params: .init(handle: "self"))
    #expect(result.sourceHealth == .live)
    #expect(result.session?.status == row.expectedStatus)
    #expect(result.session?.providerPrompts.isEmpty == true)
    let retained = try await ingestion.repository.statusContext(paneId: paneId)
    #expect(retained.evidence.count == row.prelude.count + row.lateFacts.count)
    #expect(retained.evidence.allSatisfy { $0.statusEffect == .applied })
}

private func sendTurnGuardHook(
    _ name: IPCSessionEventName, turnId: String?, adapter: AgentStudioIPCSessionsAdapter, paneId: UUID
) async throws {
    var fields = IPCSessionProviderEventFields()
    fields.toolName = "Bash"
    fields.failureSummary = name == .turnFailed ? "late failure" : nil
    let accepted = try await adapter.recordProviderEvent(
        paneId: paneId,
        params: .init(
            handle: "self", provider: .init(identifier: "claude-code", version: "2.1.289", mode: "interactive"),
            event: .init(
                name: name, conversationId: "guard-session", turnId: turnId, requestId: nil,
                toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate(), providerFields: fields),
            correlationId: UUIDv7.generate()), provenance: .matchingPane)
    #expect(accepted.disposition == .admitted)
}
