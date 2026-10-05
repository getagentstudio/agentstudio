import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions evidence reducer")
struct SessionsEvidenceReducerTests {
    @Test(
        "the binding table applies precedence without qualification or generation decisions",
        arguments: BindingTableScenario.allCases)
    func bindingTable(scenario: BindingTableScenario) async throws {
        let fixture = try SessionsDatabaseFixture()
        let repository = fixture.makeRepository()
        let pane = UUIDv7.generate()
        let otherPane = UUIDv7.generate()
        let initial: SessionsHookCommit?
        switch scenario {
        case .firstStart, .firstActivity: initial = nil
        case .replaceStart, .unseenReplaces:
            initial = try await repository.applyHook(makeHookAdmission(paneId: pane, sessionId: "other-session"))
        case .active, .ended, .revive:
            initial = try await repository.applyHook(makeHookAdmission(paneId: pane))
        case .move, .activeElsewhere:
            initial = try await repository.applyHook(makeHookAdmission(paneId: otherPane))
        }
        if scenario == .ended || scenario == .revive {
            _ = try await repository.applyHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
        }
        let isStart = [.firstStart, .replaceStart, .move, .revive].contains(scenario)
        let result = try await repository.applyHook(
            makeHookAdmission(
                paneId: pane,
                eventName: isStart ? .sessionStart : .toolActivity,
                signal: isStart ? .sessionStart : .toolActivity(toolName: "Read")))
        if scenario == .activeElsewhere || scenario == .ended {
            #expect(result.disposition == .recordedOnly)
            #expect(result.evidence.statusEffect == .recordedOnly)
            #expect(result.binding.bindingGenerationId == initial?.binding.bindingGenerationId)
            #expect(result.endedBindings.isEmpty)
        } else if scenario == .active {
            #expect(result.disposition == .applied)
            #expect(result.binding.bindingGenerationId == initial?.binding.bindingGenerationId)
        } else {
            #expect(result.disposition == .bound)
            #expect(result.binding.paneId == pane)
            #expect(result.binding.status == .active)
            #expect(result.evidence.statusEffect == .applied)
            if let initial {
                if scenario == .revive {
                    #expect(result.binding.bindingGenerationId == initial.binding.bindingGenerationId)
                } else {
                    #expect(result.binding.bindingGenerationId != initial.binding.bindingGenerationId)
                    let status = try await fixture.sqliteAccess.read {
                        try String.fetchOne(
                            $0, sql: "SELECT status FROM sessions_pane_binding WHERE binding_generation_id = ?",
                            arguments: [initial.binding.bindingGenerationId.uuidString])
                    }
                    #expect(status == "ended")
                }
            }
        }
    }
}

enum BindingTableScenario: CaseIterable, Equatable, Sendable {
    case firstStart, firstActivity, replaceStart, unseenReplaces, active, activeElsewhere, ended, move, revive
}
