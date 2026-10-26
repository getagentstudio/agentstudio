import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

@testable import AgentStudioCore

/// Literal V3 facts and oracles from specification r5 / the approved storyboard.
/// Expectations never call a product rule or use another surface's output.
struct PaneContextScenario: Sendable, CustomStringConvertible {
    var activityAgeSeconds: Double = 0
    var description: String { id }
    enum SessionInput: Sendable, Equatable {
        case ready, working, question, approval, ended, unverifiedWorking, unbound
    }
    enum FormInput: Sendable, Equatable { case singleChoice, multipleChoice, approval }
    enum AnswerInput: Sendable, Equatable { case open, pending, confirmed, unconfirmed, dismissed }
    enum MessageInput: Sendable {
        case notice(MessageImportance, String, NoticeState, drawer: Bool = false)
        case ask(FormInput, String, AnswerInput)
    }
    enum PromptInput: Sendable {
        case absent
        case approvalWithoutSummary
        case syntheticApprovalSummary
        case syntheticTwoListedOneOmitted
    }
    struct LineInput: Sendable {
        let text: String
        let ageSeconds: Double
    }
    struct Expected: Sendable {
        let sidebarStatus: String?
        let cardStatus: String?
        let agentLine: String?
        let bracketedAge: String?
        let counts: PaneMessageKindCounts
        let chips: [KindChipModel]
        let toolbar: ToolbarItemModel
        let activityChip: String?
        let groups: [String]
        let settledLabel: String?
    }

    let id: String
    let session: SessionInput
    let line: LineInput?
    let messages: [MessageInput]
    let prompts: PromptInput
    let expected: Expected

    var isSyntheticPromptInput: Bool {
        switch prompts {
        case .syntheticApprovalSummary, .syntheticTwoListedOneOmitted: true
        case .absent, .approvalWithoutSummary: false
        }
    }

    static let title = "Assistant capabilities overview"
    static let writtenAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let longFailure = """
        Build failed while compiling the Sessions module.
        SessionsIngestion.swift:142: generic parameter 'Clock' could not be inferred.
        The build stopped before running the test bundle.
        No application files were changed by this failure.
        Review the diagnostic and update the affected call site.
        Then run the focused test lane again.
        """

    /// S15 stays in this inventory; its approval driver is enabled at P6, as the Lead approved.
    static let all: [Self] = [
        .init(
            activityAgeSeconds: 60, id: "S1", session: .ready, line: nil, messages: [], prompts: .absent,
            expected: .init(
                sidebarStatus: "Idle · ready", cardStatus: "Idle · ready", agentLine: nil, bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [], toolbar: .none, activityChip: "1m",
                groups: [], settledLabel: nil)),
        .init(
            id: "S2", session: .working, line: nil, messages: [], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: nil, bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [], toolbar: .none,
                activityChip: "Now", groups: [], settledLabel: nil)),
        .init(
            id: "S3", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 0),
            messages: [], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .agentLine(text: "Running tests (3/7)", bracketedAge: "[Now]"),
                activityChip: nil, groups: [], settledLabel: nil)),
        .init(
            id: "S4", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 120),
            messages: [], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[2 min ago]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .agentLine(text: "Running tests (3/7)", bracketedAge: "[2 min ago]"),
                activityChip: nil, groups: [], settledLabel: nil)),
        .init(
            id: "S5", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 180),
            messages: [.notice(.info, "Branch rebased onto main", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[3 min ago]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
        .init(
            id: "S6", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 180),
            messages: [
                .notice(.info, "Branch rebased onto main", .unread), .notice(.done, "Tests passed (412)", .unread),
            ],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[3 min ago]",
                counts: .init(failure: 0, needsYou: 0, done: 1, info: 1),
                chips: [.init(kind: .done, count: 1), .init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .done, count: 1), .init(kind: .info, count: 1)]),
                activityChip: nil, groups: ["Done", "Info"], settledLabel: nil)),
        .init(
            id: "S7", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 180),
            messages: [
                .notice(.info, "Branch rebased onto main", .unread), .notice(.done, "Tests passed (412)", .unread),
                .notice(.attention, "Review the migration plan before I apply it", .unread),
            ],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[3 min ago]",
                counts: .init(failure: 0, needsYou: 1, done: 1, info: 1),
                chips: [.init(kind: .needsYou, count: 1), .init(kind: .done, count: 1), .init(kind: .info, count: 1)],
                toolbar: .chips([
                    .init(kind: .needsYou, count: 1), .init(kind: .done, count: 1), .init(kind: .info, count: 1),
                ]),
                activityChip: nil, groups: ["Needs you", "Done", "Info"], settledLabel: nil)),
        .init(
            id: "S8", session: .working, line: .init(text: "Running tests (3/7)", ageSeconds: 180),
            messages: [
                .notice(.info, "Branch rebased onto main", .unread), .notice(.done, "Tests passed (412)", .unread),
                .notice(.attention, "Review the migration plan before I apply it", .unread),
                .notice(.failure, "Build failed: 3 errors in SessionsIngestion.swift", .unread),
            ],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Running tests (3/7)",
                bracketedAge: "[3 min ago]",
                counts: .init(failure: 1, needsYou: 1, done: 1, info: 1),
                chips: [
                    .init(kind: .failure, count: 1), .init(kind: .needsYou, count: 1), .init(kind: .done, count: 1),
                    .init(kind: .info, count: 1),
                ],
                toolbar: .chips([
                    .init(kind: .failure, count: 1), .init(kind: .needsYou, count: 1), .init(kind: .done, count: 1),
                    .init(kind: .info, count: 1),
                ]),
                activityChip: nil, groups: ["Needs you", "Done", "Info"], settledLabel: nil)),
        .init(
            id: "S9", session: .question, line: .init(text: "Waiting for your answer", ageSeconds: 0),
            messages: [.ask(.singleChoice, "Pick a color for the test?", .open)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Needs you · question", cardStatus: "Needs you · question",
                agentLine: "Waiting for your answer", bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 1, done: 0, info: 0), chips: [.init(kind: .needsYou, count: 1)],
                toolbar: .chips([.init(kind: .needsYou, count: 1)]), activityChip: nil,
                groups: ["Needs you"], settledLabel: nil)),
        .init(
            id: "S10-pending", session: .working, line: .init(text: "Using blue", ageSeconds: 0),
            messages: [.ask(.singleChoice, "Pick a color for the test?", .pending)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Using blue", bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .agentLine(text: "Using blue", bracketedAge: "[Now]"),
                activityChip: nil, groups: ["Resolved"], settledLabel: "Answer sent, waiting for the agent")),
        .init(
            id: "S10-confirmed", session: .working, line: .init(text: "Using blue", ageSeconds: 0),
            messages: [.ask(.singleChoice, "Pick a color for the test?", .confirmed)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Using blue", bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .agentLine(text: "Using blue", bracketedAge: "[Now]"),
                activityChip: nil, groups: ["Resolved"], settledLabel: "Answered: blue")),
        .init(
            id: "S11", session: .working,
            line: .init(
                text: "Applying migration 3 of 7 to the sessions table and rebuilding indexes", ageSeconds: 240),
            messages: [
                .notice(.info, "Branch rebased onto main", .unread, drawer: true),
                .notice(.done, "Tests passed (412)", .unread),
                .notice(.attention, "Review the migration plan before I apply it", .unread),
                .notice(.failure, "Build failed: 3 errors in SessionsIngestion.swift", .unread),
            ],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working",
                agentLine: "Applying migration 3 of 7 to the sessions table and rebuilding indexes",
                bracketedAge: "[4 min ago]",
                counts: .init(failure: 1, needsYou: 1, done: 1, info: 1),
                chips: [
                    .init(kind: .failure, count: 1), .init(kind: .needsYou, count: 1), .init(kind: .done, count: 1),
                    .init(kind: .info, count: 1),
                ],
                toolbar: .chips([
                    .init(kind: .failure, count: 1), .init(kind: .needsYou, count: 1), .init(kind: .done, count: 1),
                    .init(kind: .info, count: 1),
                ]),
                activityChip: nil, groups: ["Needs you", "Done", "Info"], settledLabel: nil)),
        .init(
            activityAgeSeconds: 540, id: "S12", session: .unbound, line: nil, messages: [], prompts: .absent,
            expected: .init(
                sidebarStatus: nil, cardStatus: nil, agentLine: nil, bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [], toolbar: .none, activityChip: "9m",
                groups: [], settledLabel: nil)),
        .init(
            id: "S13", session: .unbound, line: .init(text: "Deploy preview ready", ageSeconds: 300),
            messages: [.notice(.info, "Branch rebased onto main", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: nil, cardStatus: nil, agentLine: "Deploy preview ready", bracketedAge: "[5 min ago]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
        .init(
            id: "S14", session: .question, line: nil,
            messages: [.ask(.multipleChoice, "Which suites should I rerun?", .open)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Needs you · question", cardStatus: "Needs you · question", agentLine: nil,
                bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 1, done: 0, info: 0), chips: [.init(kind: .needsYou, count: 1)],
                toolbar: .chips([.init(kind: .needsYou, count: 1)]), activityChip: "Now", groups: ["Needs you"],
                settledLabel: nil)),
        .init(
            id: "S15", session: .approval, line: nil,
            messages: [.ask(.approval, "Approve running the migration?", .open)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Needs you · approval", cardStatus: "Needs you · approval", agentLine: nil,
                bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 1, done: 0, info: 0), chips: [.init(kind: .needsYou, count: 1)],
                toolbar: .chips([.init(kind: .needsYou, count: 1)]), activityChip: "Now", groups: ["Needs you"],
                settledLabel: nil)),
        .init(
            id: "S16a-synthetic-input", session: .approval, line: nil, messages: [], prompts: .syntheticApprovalSummary,
            expected: .init(
                sidebarStatus: "Needs you · approval: Allow write to ~/.zshrc?", cardStatus: "Needs you · approval",
                agentLine: nil, bracketedAge: nil, counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .none, activityChip: "Now",
                groups: ["Needs you"], settledLabel: nil)),
        .init(
            id: "S16b", session: .approval, line: nil, messages: [], prompts: .approvalWithoutSummary,
            expected: .init(
                sidebarStatus: "Needs you · approval", cardStatus: "Needs you · approval", agentLine: nil,
                bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [], toolbar: .none,
                activityChip: "Now", groups: ["Needs you"], settledLabel: nil)),
        .init(
            id: "S17", session: .working, line: nil, messages: [.notice(.failure, longFailure, .unread)],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: nil, bracketedAge: nil,
                counts: .init(failure: 1, needsYou: 0, done: 0, info: 0), chips: [.init(kind: .failure, count: 1)],
                toolbar: .chips([.init(kind: .failure, count: 1)]), activityChip: "Now", groups: ["Needs you"],
                settledLabel: nil)),
        .init(
            id: "S18-synthetic-input", session: .approval, line: nil, messages: [],
            prompts: .syntheticTwoListedOneOmitted,
            expected: .init(
                sidebarStatus: "Needs you · approval: Allow write to ~/.zshrc?", cardStatus: "Needs you · approval",
                agentLine: nil, bracketedAge: nil, counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [],
                toolbar: .none, activityChip: "Now",
                groups: ["Needs you"], settledLabel: nil)),
        .init(
            id: "S19", session: .working, line: nil,
            messages: [
                .ask(.singleChoice, "Review the migration plan before I apply it", .dismissed),
                .ask(.singleChoice, "Pick a color for the test?", .unconfirmed),
                .notice(.info, "Branch rebased onto main", .withdrawn),
                .notice(.failure, "Build failed: 3 errors in SessionsIngestion.swift", .read),
            ],
            prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: nil, bracketedAge: nil,
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 0), chips: [], toolbar: .none,
                activityChip: "Now", groups: ["Resolved"], settledLabel: nil)),
    ]

    static let evidenceCases: [Self] = [
        .init(
            id: "G10-live", session: .working, line: .init(text: "Independent pane line", ageSeconds: 0),
            messages: [.notice(.info, "Independent pane notice", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Working", cardStatus: "Working", agentLine: "Independent pane line",
                bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
        .init(
            id: "G10-ended", session: .ended, line: .init(text: "Independent pane line", ageSeconds: 0),
            messages: [.notice(.info, "Independent pane notice", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: "Idle · ended", cardStatus: "Idle · ended", agentLine: "Independent pane line",
                bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
        .init(
            id: "G10-unverified-working", session: .unverifiedWorking,
            line: .init(text: "Independent pane line", ageSeconds: 0),
            messages: [.notice(.info, "Independent pane notice", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: nil, cardStatus: nil, agentLine: "Independent pane line", bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
        .init(
            id: "G10-none", session: .unbound, line: .init(text: "Independent pane line", ageSeconds: 0),
            messages: [.notice(.info, "Independent pane notice", .unread)], prompts: .absent,
            expected: .init(
                sidebarStatus: nil, cardStatus: nil, agentLine: "Independent pane line", bracketedAge: "[Now]",
                counts: .init(failure: 0, needsYou: 0, done: 0, info: 1), chips: [.init(kind: .info, count: 1)],
                toolbar: .chips([.init(kind: .info, count: 1)]), activityChip: nil, groups: ["Info"], settledLabel: nil)
        ),
    ]
}
