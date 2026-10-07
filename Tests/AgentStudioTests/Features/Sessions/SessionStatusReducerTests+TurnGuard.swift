import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

extension SessionStatusReducerTests {
    @Test(
        "turn guard applies open and new turns but rejects the last closed turn",
        arguments: ReducerTurnGuardRow.allCases)
    func turnGuardTable(row: ReducerTurnGuardRow) {
        var fixture = TurnGuardReducerFixture()
        fixture.send(.toolActivity, turnId: "A")
        switch row {
        case .permissionAfterView:
            fixture.send(.stop, turnId: "A")
            fixture.send(.paneViewed(fixture.instant.advanced(by: .seconds(1))), turnId: nil)
            fixture.send(.permission(toolName: "Bash", questions: nil), turnId: "A")
            #expect(fixture.status == .idle(.ready))
            #expect(fixture.state.providerPrompts.isEmpty)
        case .lateFailureInNextTurn:
            fixture.send(.stop, turnId: "A")
            fixture.send(.toolActivity, turnId: "B")
            fixture.send(.stopFailure(.init(category: "late failure")), turnId: "A")
            #expect(fixture.status == .working(.active))
            #expect(fixture.state.openTurnId == "B")
        case .delayedStopAndTool:
            fixture.send(.stop, turnId: "A")
            fixture.send(.stop, turnId: "A")
            fixture.send(.toolActivity, turnId: "A")
            #expect(fixture.status == .idle(.done))
            #expect(fixture.state.openTurnId == nil)
        case .unnamedStop:
            fixture.send(.stop, turnId: nil)
            #expect(fixture.state.openTurnId == nil)
            #expect(fixture.state.lastClosedTurnId == "A")
            fixture.send(.permission(toolName: "Bash", questions: nil), turnId: "A")
            #expect(fixture.status == .idle(.done))
        case .twoTurnsOld:
            fixture.send(.stop, turnId: "A")
            fixture.send(.toolActivity, turnId: "B")
            fixture.send(.stop, turnId: "B")
            fixture.send(.toolActivity, turnId: "A")
            #expect(fixture.status == .working(.active))
            #expect(fixture.state.openTurnId == "A")
            #expect(fixture.state.lastClosedTurnId == "B")
        case .interruptDoesNotClose:
            fixture.send(.interrupt, turnId: "A")
            #expect(fixture.status == .idle(.interrupted))
            #expect(fixture.state.openTurnId == "A")
            #expect(fixture.state.lastClosedTurnId == nil)
            fixture.send(.toolActivity, turnId: "A")
            #expect(fixture.status == .working(.active))
        case .unnamedWithoutOpen:
            fixture.send(.stop, turnId: "A")
            fixture.send(.toolActivity, turnId: nil)
            #expect(fixture.status == .working(.active))
            #expect(fixture.state.openTurnId == nil)
        }
    }

    @Test("every last-closed turn input leaves the whole status unchanged")
    func lastClosedTurnCannotOpenCloseOrReplaceStatus() {
        let questions = [SessionQuestion(question: "Continue?", header: "Choice", options: [], multiSelect: false)]
        let inputs: [SessionStatusInput] = [
            .userPromptSubmit, .toolActivity, .subagentActivity,
            .permission(toolName: "Bash", questions: nil), .question(toolCallId: "question", questions: questions),
            .toolCompleted(toolCallId: "question"), .toolFailed(toolCallId: "question"),
            .elicitation(id: "form", occurrenceId: UUIDv7.generate(), summary: "Late form"),
            .elicitationResult(id: "form"), .stop, .stopFailure(.init(category: "late failure")), .interrupt,
        ]
        for input in inputs {
            var fixture = TurnGuardReducerFixture()
            fixture.send(.stop, turnId: "A")
            fixture.send(.question(toolCallId: "question", questions: questions), turnId: "B")
            fixture.send(
                .elicitation(id: "form", occurrenceId: UUIDv7.generate(), summary: "Current form"), turnId: "B")
            let before = fixture.state
            fixture.send(input, turnId: "A")
            #expect(fixture.state == before)
        }
    }

    @Test("Stop and StopFailure both close named and unnamed open turns")
    func closingFactsRememberTheNamedTurn() {
        for closing in [SessionStatusInput.stop, .stopFailure(.init(category: "failed"))] {
            for named in [false, true] {
                var fixture = TurnGuardReducerFixture()
                fixture.send(.toolActivity, turnId: "A")
                fixture.send(closing, turnId: named ? "A" : nil)
                #expect(fixture.state.openTurnId == nil)
                #expect(fixture.state.lastClosedTurnId == "A")
                let closed = fixture.state
                fixture.send(.permission(toolName: "Bash", questions: nil), turnId: "A")
                #expect(fixture.state == closed)
            }
        }
    }

    @Test("unnamed prompt facts name the open turn for exact question folding")
    func unnamedPromptUsesOpenTurn() {
        var fixture = TurnGuardReducerFixture()
        let questions = [SessionQuestion(question: "Continue?", header: "Choice", options: [], multiSelect: false)]
        fixture.send(.question(toolCallId: "question", questions: questions), turnId: "A")
        fixture.send(.permission(toolName: "AskUserQuestion", questions: questions), turnId: nil)
        #expect(fixture.state.providerPrompts.count == 1)
        #expect(fixture.state.providerPrompts[.toolCall("question")]?.absorbedPermission == true)
    }

    @Test("binding lifecycle always applies and Start resets both turn identities")
    func bindingLifecycleIsIndependentOfClosedTurn() {
        var fixture = TurnGuardReducerFixture()
        fixture.send(.stop, turnId: "A")
        fixture.send(.sessionEnd, turnId: "A")
        #expect(fixture.status == .idle(.ended))
        fixture.send(.openAsks(.init(sequence: 1, approval: 0, question: 0, blocked: 1)), turnId: "A")
        fixture.send(.agentLine(.monitoring), turnId: "A")
        fixture.send(.sessionStart(generation: UUIDv7.generate()), turnId: "A")
        #expect(fixture.state.openTurnId == nil)
        #expect(fixture.state.lastClosedTurnId == nil)
        #expect(fixture.state.openAsks.blocked == 1)
        #expect(fixture.state.lineWork == .monitoring)
        fixture.send(.bindingReplaced(by: UUIDv7.generate()), turnId: "A")
        #expect(fixture.state.providerPrompts.isEmpty)
        guard case .replaced = fixture.state.binding else {
            Issue.record("Binding replacement must apply")
            return
        }
    }
}

enum ReducerTurnGuardRow: CaseIterable, Sendable {
    case permissionAfterView, lateFailureInNextTurn, delayedStopAndTool, unnamedStop, twoTurnsOld
    case interruptDoesNotClose, unnamedWithoutOpen
}

private struct TurnGuardReducerFixture {
    var state: SessionStatusState

    init(binding: UUID = UUIDv7.generate()) {
        state = SessionStatusState(binding: .bound(binding))
    }
    var instant = ContinuousClock.now
    var sequence: Int64 = 0
    var status: AgentSessionStatus { SessionStatusReducer.status(of: state) }

    mutating func send(_ input: SessionStatusInput, turnId: String?) {
        sequence += 1
        instant = instant.advanced(by: .seconds(1))
        SessionStatusReducer.apply(
            .init(
                input: input, sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(sequence)),
                admittedAt: instant, turnId: turnId), to: &state)
    }
}

extension SessionStatusReducerTests {
    @Test(
        "a compact SessionStart closes its named turn in either admission order",
        arguments: CompactAdmissionOrder.allCases)
    func compactSessionStartClosesNamedTurn(order: CompactAdmissionOrder) {
        let generation = UUIDv7.generate()
        let compactPromptId = "compact-prompt"
        var fixture = TurnGuardReducerFixture(binding: generation)
        switch order {
        case .sessionStartThenSubagentStop:
            fixture.send(.sessionStart(generation: generation), turnId: compactPromptId)
            fixture.send(.subagentActivity, turnId: compactPromptId)
        case .subagentStopThenSessionStart:
            fixture.send(.subagentActivity, turnId: compactPromptId)
            fixture.send(.sessionStart(generation: generation), turnId: compactPromptId)
        }
        #expect(fixture.status == .idle(.done))
        #expect(fixture.state.openTurnId == nil)
        #expect(fixture.state.lastClosedTurnId == compactPromptId)
    }

    @Test("a turn-less SessionStart keeps the live main's existing reset behavior")
    func turnlessSessionStartKeepsExistingReset() {
        let generation = UUIDv7.generate()
        var fixture = TurnGuardReducerFixture(binding: generation)
        fixture.send(.toolActivity, turnId: "turn")
        fixture.send(.sessionStart(generation: generation), turnId: nil)
        #expect(fixture.status == .unknown)
        #expect(fixture.state.openTurnId == nil)
        #expect(fixture.state.lastClosedTurnId == nil)
    }
}

enum CompactAdmissionOrder: CaseIterable, Equatable, Sendable {
    case sessionStartThenSubagentStop
    case subagentStopThenSessionStart
}
