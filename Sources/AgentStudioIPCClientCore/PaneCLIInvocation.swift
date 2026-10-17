import AgentStudioProgrammaticControl
import Foundation

/// CLI syntax projects the compiled pane methods; it creates no RPC identity.
typealias PaneCLIVerb = IPCModelCallVariant

extension IPCModelCallVariant {
    var methodName: String {
        switch self {
        case .notify, .ask: "pane.message.send"
        case .withdraw: "pane.message.withdraw"
        case .answers: "pane.message.changes"
        case .line: "pane.line.set"
        case .title: "pane.title.set"
        case .pane: "pane.context.get"
        }
    }

    func methodName(arguments: [String]) -> String {
        self == .ask && arguments.contains("--wait") ? "pane.message.ask" : methodName
    }

    var ordered: Bool { self == .line || self == .title }

    var usage: String {
        switch self {
        case .notify: "notify TEXT [--kind info|attention|done|failure] [--open file:line]"
        case .ask: "ask QUESTION [--reason approval|question|blocked] [--choice a,b] [--wait --timeout SECONDS]"
        case .withdraw: "withdraw ID"
        case .answers: "answers"
        case .line:
            "line SUMMARY [--working --step 3/7 | --monitoring TARGET | --blocked-on-you ACTION | --done | --failed REASON] [--detail TEXT] [--expires SECONDS] | line --clear"
        case .title: "title TEXT | title --reset"
        case .pane: "pane"
        }
    }
}

struct PaneCLIMessageDraft: Sendable {
    let body: String
    let importance: IPCPaneMessageImportance
    let actions: [IPCPaneMessageAction]
    let createdAt: Date
}

struct PaneCLIAskDraft: Sendable {
    let message: PaneCLIMessageDraft
    let reason: IPCPaneAskReason
    let form: IPCPaneAskForm
    let timeout: TimeInterval?
}

enum PaneCLIIntent: Sendable {
    case notify(PaneCLIMessageDraft)
    case ask(PaneCLIAskDraft)
    case withdraw(UUID)
    case answers
    case line(IPCPaneAgentLineInput?)
    case title(String?)
    case pane

    var callLimit: Duration {
        if case .ask(let draft) = self, let seconds = draft.timeout { return .seconds(seconds + 2) }
        return CLIPolicy.ordinaryCallLimit
    }

    static func parse(_ arguments: [String], now: Date) throws -> Self {
        guard let name = arguments.first, let verb = PaneCLIVerb(rawValue: name) else { throw invalid() }
        let options = try PaneCLIOptions(arguments: Array(arguments.dropFirst()), verb: verb)
        switch verb {
        case .notify: return .notify(try options.message(now: now))
        case .ask:
            let timeout = try options.duration("--timeout")
            guard timeout == nil || options.flags.contains("--wait") else { throw invalid() }
            let form: IPCPaneAskForm
            if let choices = options.values["--choice"] {
                let labels = choices.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard labels.allSatisfy({ !$0.isEmpty }), Set(labels).count == labels.count else { throw invalid() }
                form = .choice(options: labels.map { .init(id: $0, label: $0) }, allowsMultiple: false)
            } else {
                form = .freeText(placeholder: nil)
            }
            guard let reason = IPCPaneAskReason(rawValue: options.values["--reason"] ?? "question") else {
                throw invalid()
            }
            return .ask(
                .init(
                    message: try options.message(now: now), reason: reason, form: form,
                    timeout: options.flags.contains("--wait")
                        ? (timeout ?? (CLIPolicy.defaultAskTimeout / .seconds(1))) : nil))
        case .withdraw:
            guard let id = UUID(uuidString: try options.text()) else { throw invalid() }
            return .withdraw(id)
        case .answers:
            guard options.positionals.isEmpty else { throw invalid() }
            return .answers
        case .pane:
            guard options.positionals.isEmpty else { throw invalid() }
            return .pane
        case .title:
            if options.flags.contains("--reset") {
                guard options.positionals.isEmpty else { throw invalid() }
                return .title(nil)
            }
            return .title(try options.text())
        case .line: return try parseAgentLine(options, now: now)
        }
    }

    private static func parseAgentLine(_ options: PaneCLIOptions, now: Date) throws -> Self {
        if options.flags.contains("--clear") {
            guard options.positionals.isEmpty, options.flags.count == 1, options.values.isEmpty else {
                throw invalid()
            }
            return .line(nil)
        }
        let work: IPCPaneAgentLineWork
        let selected =
            options.flags.intersection(["--working", "--done"]).count
            + ["--monitoring", "--blocked-on-you", "--failed"].filter { options.values[$0] != nil }.count
        guard selected <= 1 else { throw invalid() }
        if options.flags.contains("--done") {
            work = .done
        } else if let target = options.values["--monitoring"] {
            work = .monitoring(target: target)
        } else if let action = options.values["--blocked-on-you"] {
            work = .blockedOnYou(action: action)
        } else if let reason = options.values["--failed"] {
            work = .failed(summary: reason)
        } else {
            let progress: IPCPaneAgentLineProgress
            if let step = options.values["--step"] {
                let parts = step.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]),
                    total > 0, current >= 0, current <= total
                else { throw invalid() }
                progress = .step(current: current, total: total)
            } else {
                progress = .indeterminate
            }
            work = .working(progress: progress)
        }
        if options.values["--step"] != nil {
            guard case .working = work else { throw invalid() }
        }
        let lifetime: IPCPaneAgentLineLifetime
        if let seconds = try options.duration("--expires") {
            lifetime = .expires(at: now.addingTimeInterval(seconds))
        } else {
            lifetime = .untilReplaced
        }
        return .line(
            .init(
                summary: try options.text(), work: work, detail: options.values["--detail"], refs: [],
                lifetime: lifetime))
    }

    static func invalid() -> AgentStudioIPCClientError { .init(reason: .invalidArguments) }
}

private struct PaneCLIOptions {
    var flags = Set<String>()
    var values: [String: String] = [:]
    var positionals: [String] = []

    init(arguments: [String], verb: PaneCLIVerb) throws {
        let flagNames: Set<String>
        let valueNames: Set<String>
        switch verb {
        case .notify:
            flagNames = []
            valueNames = ["--kind", "--open"]
        case .ask:
            flagNames = ["--wait"]
            valueNames = ["--reason", "--choice", "--timeout", "--kind", "--open"]
        case .title:
            flagNames = ["--reset"]
            valueNames = []
        case .line:
            flagNames = ["--clear", "--working", "--done"]
            valueNames = ["--step", "--monitoring", "--blocked-on-you", "--failed", "--detail", "--expires"]
        case .withdraw, .answers, .pane:
            flagNames = []
            valueNames = []
        }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if flagNames.contains(argument) {
                guard flags.insert(argument).inserted else { throw PaneCLIIntent.invalid() }
            } else if valueNames.contains(argument) {
                guard values[argument] == nil, index < arguments.count else { throw PaneCLIIntent.invalid() }
                values[argument] = arguments[index]
                index += 1
            } else {
                guard !argument.hasPrefix("--") else { throw PaneCLIIntent.invalid() }
                positionals.append(argument)
            }
        }
    }

    func text() throws -> String {
        guard positionals.count == 1, let text = positionals.first, !text.isEmpty else { throw PaneCLIIntent.invalid() }
        return text
    }

    func duration(_ option: String) throws -> TimeInterval? {
        guard let value = values[option] else { return nil }
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds <= Double(Int64.max) - 2 else {
            throw PaneCLIIntent.invalid()
        }
        return seconds
    }

    func message(now: Date) throws -> PaneCLIMessageDraft {
        guard let importance = IPCPaneMessageImportance(rawValue: values["--kind"] ?? "info") else {
            throw PaneCLIIntent.invalid()
        }
        var actions: [IPCPaneMessageAction] = []
        if let location = values["--open"] {
            let parts = location.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count > 1, let line = Int(parts.last ?? "") {
                guard line > 0 else { throw PaneCLIIntent.invalid() }
                actions = [.openFile(path: parts.dropLast().joined(separator: ":"), line: line)]
            } else {
                actions = [.openFile(path: location, line: nil)]
            }
        }
        return PaneCLIMessageDraft(body: try text(), importance: importance, actions: actions, createdAt: now)
    }
}
