import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Session status reducer")
struct SessionStatusReducerTests {
    @Test("hook transitions, including unsupported silence, follow the status tree")
    func hookTransitionTable() {
        let failure = SessionFailureSummary(category: "authentication_failed")
        let rows: [(SessionStatusInput, AgentSessionStatus)] = [
            (.userPromptSubmit, .working(.active)),
            (.toolActivity, .working(.active)),
            (.subagentActivity, .working(.active)),
            (.stop, .idle(.done)),
            (.stopFailure(failure), .failed(failure)),
            (.interrupt, .idle(.interrupted)),
            (.sessionEnd, .idle(.ended)),
        ]
        for (input, expected) in rows {
            var fixture = StatusReducerFixture()
            fixture.send(input)
            #expect(fixture.status == expected)
        }
        let untouched = StatusReducerFixture()
        #expect(untouched.status == .unknown)
    }

    @Test("ask reasons outrank every hook state and follow approval > question > blocked")
    func askPrecedenceTable() {
        let summaries: [(OpenAskSummary, AgentSessionStatus)] = [
            (.init(sequence: 1, approval: 1, question: 1, blocked: 1), .needsYou(.approval)),
            (.init(sequence: 1, approval: 0, question: 1, blocked: 1), .needsYou(.question)),
            (.init(sequence: 1, approval: 0, question: 0, blocked: 1), .needsYou(.blocked)),
        ]
        let hooks: [SessionStatusInput] = [
            .userPromptSubmit, .stop, .interrupt,
            .stopFailure(.init(category: "authentication_failed")), .sessionEnd,
            .bindingReplaced(by: UUIDv7.generate()),
        ]
        for (summary, expected) in summaries {
            for hook in hooks {
                var fixture = StatusReducerFixture()
                fixture.send(.openAsks(summary))
                fixture.send(hook)
                #expect(fixture.status == expected)
            }
        }
    }

    @Test("prompt reasons join ask reasons; a drawer session never changes its owner's state")
    func promptAndAskReasonsAreSessionScoped() {
        var owner = StatusReducerFixture()
        owner.send(.toolActivity)
        var drawer = StatusReducerFixture()
        drawer.send(.openAsks(.init(sequence: 1, approval: 0, question: 0, blocked: 1)))
        #expect(owner.status == .working(.active))
        #expect(drawer.status == .needsYou(.blocked))
        drawer.send(.question(toolCallId: "question", questions: statusTestQuestions))
        #expect(drawer.status == .needsYou(.question))
        drawer.send(.permission(toolName: "Bash", questions: nil))
        #expect(drawer.status == .needsYou(.approval))
        drawer.send(.stop)
        #expect(drawer.status == .needsYou(.blocked))
        #expect(owner.status == .working(.active))
    }

    @Test("permission is unaffected by parallel tools and silent interrupts")
    func parallelToolCannotResolvePermission() {
        var fixture = StatusReducerFixture()
        fixture.send(.permission(toolName: "Bash", questions: nil))
        let openedPrompts = fixture.state.providerPrompts
        fixture.send(.toolActivity)
        fixture.send(.toolCompleted(toolCallId: "parallel-call"))
        fixture.send(.toolFailed(toolCallId: "parallel-call"))
        #expect(fixture.status == .needsYou(.approval))
        #expect(fixture.state.providerPrompts == openedPrompts)
        #expect(openedPrompts.values.first?.observedAt == Date(timeIntervalSince1970: 1))
        // Claude's silent interrupt supplies no event; no reduction may guess it.
        #expect(fixture.status == .needsYou(.approval))
    }

    @Test("turn boundaries resolve report-only permissions, including manual deny then Stop")
    func turnBoundaryTable() {
        let rows: [(SessionStatusInput, AgentSessionStatus)] = [
            (.stop, .idle(.done)),
            (.stopFailure(.init(category: "authentication_failed")), .failed(.init(category: "authentication_failed"))),
            (.userPromptSubmit, .working(.active)),
        ]
        for (boundary, expected) in rows {
            var fixture = StatusReducerFixture()
            fixture.send(.permission(toolName: "Bash", questions: nil))
            fixture.send(boundary)
            #expect(fixture.state.providerPrompts.isEmpty)
            #expect(fixture.status == expected)
        }
    }

    @Test("questions resolve only on their own tool completion or failure")
    func questionCorrelationTable() {
        for completion in [
            SessionStatusInput.toolCompleted(toolCallId: "question-call"), .toolFailed(toolCallId: "question-call"),
        ] {
            var fixture = StatusReducerFixture()
            fixture.send(.question(toolCallId: "question-call", questions: statusTestQuestions))
            fixture.send(.toolCompleted(toolCallId: "different-call"))
            #expect(fixture.status == .needsYou(.question))
            #expect(fixture.state.providerPrompts[.toolCall("question-call")] != nil)
            fixture.send(completion)
            #expect(fixture.state.providerPrompts.isEmpty)
            #expect(fixture.status == .working(.active))
        }
    }

    @Test("AskUserQuestion permission folds exactly once into exactly one identical open question")
    func normalQuestionPermissionFold() {
        var fixture = StatusReducerFixture()
        fixture.send(.question(toolCallId: "question-call", questions: statusTestQuestions))
        fixture.send(.permission(toolName: "AskUserQuestion", questions: statusTestQuestions))
        #expect(fixture.state.providerPrompts.count == 1)
        #expect(fixture.state.providerPrompts[.toolCall("question-call")]?.absorbedPermission == true)
        fixture.send(.permission(toolName: "AskUserQuestion", questions: statusTestQuestions))
        #expect(fixture.state.providerPrompts.count == 2)
        fixture.send(.toolCompleted(toolCallId: "question-call"))
        #expect(fixture.status == .needsYou(.question))
        fixture.send(.stop)
        #expect(fixture.status == .idle(.done))
    }

    @Test("lost, different, ambiguous or previous-turn question openings never absorb permission")
    func conservativeQuestionPermissionTable() {
        for scenario in 0..<4 {
            var fixture = StatusReducerFixture()
            if scenario != 0 {
                fixture.send(.question(toolCallId: "first", questions: statusTestQuestions))
            }
            if scenario == 2 {
                fixture.send(.question(toolCallId: "second", questions: statusTestQuestions))
            }
            let questions = scenario == 1 ? statusOtherQuestions : statusTestQuestions
            fixture.send(
                .permission(toolName: "AskUserQuestion", questions: questions),
                turnId: scenario == 3 ? "next-turn" : "turn")
            #expect(fixture.state.providerPrompts[.permission(fixture.sequence)]?.reason == .question)
            fixture.send(.toolCompleted(toolCallId: "first"))
            fixture.send(.toolCompleted(toolCallId: "second"))
            #expect(fixture.status == .needsYou(.question))
        }
    }

    @Test("no-ID elicitation result resolves nothing; IDs require exact matching")
    func elicitationCorrelationTable() {
        var fixture = StatusReducerFixture()
        fixture.send(.elicitation(id: nil, occurrenceId: UUIDv7.generate(), summary: "Choose a color"))
        let prompts = fixture.state.providerPrompts
        fixture.send(.elicitationResult(id: nil))
        #expect(fixture.state.providerPrompts == prompts)
        #expect(fixture.status == .needsYou(.question))
        fixture.send(.stop)
        #expect(fixture.state.providerPrompts.isEmpty)
        fixture.send(.elicitation(id: "form-1", occurrenceId: UUIDv7.generate(), summary: "Choose a color"))
        fixture.send(.elicitationResult(id: "form-2"))
        #expect(fixture.status == .needsYou(.question))
        fixture.send(.elicitationResult(id: "form-1"))
        #expect(fixture.state.providerPrompts.isEmpty)
    }

    @Test("end and replacement override working, failed and done while keeping own asks")
    func endAndReplacementTable() {
        let turns: [SessionStatusInput] = [.toolActivity, .stopFailure(.init(category: "failed")), .stop]
        let endings: [SessionStatusInput] = [.sessionEnd, .bindingReplaced(by: UUIDv7.generate())]
        for turn in turns {
            for ending in endings {
                for hasAsk in [false, true] {
                    var fixture = StatusReducerFixture()
                    fixture.send(turn)
                    fixture.send(.permission(toolName: "Bash", questions: nil))
                    if hasAsk { fixture.send(.openAsks(.init(sequence: 1, approval: 0, question: 0, blocked: 1))) }
                    fixture.send(ending)
                    #expect(fixture.state.providerPrompts.isEmpty)
                    #expect(fixture.status == (hasAsk ? .needsYou(.blocked) : .idle(.ended)))
                }
            }
        }
    }

    @Test("replacement's sessionStart begins fresh state; old session keeps its own asks")
    func replacementStartsFreshState() {
        var old = StatusReducerFixture()
        old.send(.openAsks(.init(sequence: 1, approval: 1, question: 0, blocked: 0)))
        let generation = UUIDv7.generate()
        old.send(.bindingReplaced(by: generation))
        var fresh = StatusReducerFixture()
        fresh.send(.sessionStart(generation: generation))
        #expect(fresh.state.binding == .bound(generation))
        #expect(fresh.status == .unknown)
        #expect(old.status == .needsYou(.approval))
    }

    @Test("stale and equal ask sequences cannot resurrect resolved NEEDS YOU")
    func askSequenceGuard() {
        var fixture = StatusReducerFixture()
        fixture.send(.toolActivity)
        fixture.send(.openAsks(.init(sequence: 2, approval: 0, question: 1, blocked: 0)))
        fixture.send(.openAsks(.init(sequence: 3, approval: 0, question: 0, blocked: 0)))
        fixture.send(.openAsks(.init(sequence: 2, approval: 1, question: 0, blocked: 0)))
        fixture.send(.openAsks(.init(sequence: 3, approval: 1, question: 0, blocked: 0)))
        #expect(fixture.state.openAsks.sequence == 3)
        #expect(fixture.status == .working(.active))
    }

    @Test("Agent Line only refines working and cannot override hook-derived failed or done")
    func agentLineIsOnlyRefinement() {
        var fixture = StatusReducerFixture()
        fixture.send(.agentLine(.monitoring))
        #expect(fixture.status == .unknown)
        fixture.send(.toolActivity)
        #expect(fixture.status == .working(.monitoring))
        fixture.send(.agentLine(nil))
        #expect(fixture.status == .working(.active))
        fixture.send(.stopFailure(.init(category: "failed")))
        fixture.send(.agentLine(.monitoring))
        #expect(fixture.status == .failed(.init(category: "failed")))
        fixture.send(.stop)
        #expect(fixture.status == .idle(.done))
    }

    @Test("pane viewed acknowledges only an earlier done, never a later Stop or replacement")
    func paneViewedUsesMonotonicAdmission() {
        var fixture = StatusReducerFixture()
        let before = fixture.instant
        fixture.send(.stop)
        fixture.send(.paneViewed(before))
        #expect(fixture.status == .idle(.done))
        fixture.send(.paneViewed(fixture.instant.advanced(by: .seconds(1))))
        #expect(fixture.status == .idle(.ready))
        fixture.send(.stop)
        #expect(fixture.status == .idle(.done))
        fixture.send(.bindingReplaced(by: UUIDv7.generate()))
        fixture.send(.paneViewed(fixture.instant.advanced(by: .seconds(1))))
        #expect(fixture.status == .idle(.ended))
    }
}

private struct StatusReducerFixture {
    var state = SessionStatusState(binding: .bound(UUIDv7.generate()))
    var sequence: Int64 = 0
    var instant = ContinuousClock().now

    var status: AgentSessionStatus { SessionStatusReducer.status(of: state) }

    mutating func send(_ input: SessionStatusInput, turnId: String = "turn") {
        sequence += 1
        instant = instant.advanced(by: .seconds(1))
        SessionStatusReducer.apply(
            SessionStatusEvent(
                input: input, sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(sequence)),
                admittedAt: instant, turnId: turnId),
            to: &state
        )
    }
}

private let statusTestQuestions = [
    SessionQuestion(
        question: "Which color?", header: "Color",
        options: [.init(label: "Red", description: "Choose red"), .init(label: "Blue", description: "Choose blue")],
        multiSelect: false)
]
private let statusOtherQuestions = [
    SessionQuestion(
        question: "Which database?", header: "Database",
        options: [.init(label: "SQLite", description: "Local database")], multiSelect: false)
]
