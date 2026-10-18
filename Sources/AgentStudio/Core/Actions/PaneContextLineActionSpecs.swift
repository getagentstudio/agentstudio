/// Data readouts and the Agent Line action share the command display pipeline.
enum PaneContextLineActionSpecs {
    static func agentLine(_ work: AgentLineWork) -> ActionSpec {
        let icon: CommandIcon
        switch work {
        case .working: icon = .system(.circleFill)
        case .monitoring: icon = .system(.circleDotted)
        case .blockedOnYou: icon = .system(.flag)
        case .done: icon = .system(.checkmark)
        case .failed: icon = .system(.xmarkOctagon)
        }
        return ActionSpec(label: "Agent Line", helpText: "Show this agent's work", icon: icon)
    }
    static func connectionIssue(_ reason: AgentConnectionRefusalReason) -> ActionSpec {
        let text: String =
            switch reason {
            case .credentialNotRecognized, .intentRequiresToken:
                "Messages unavailable · restart this shell to reconnect"
            case .paneNotFound:
                "Agent identity unavailable · run this from an open Agent Studio pane"
            case .paneRetired:
                "Agent identity unavailable · this pane has closed"
            case .otherWorkspace:
                "Agent identity unavailable · run this from the matching workspace"
            case .noSessionId:
                "Agent identity unavailable · the provider did not supply a session ID"
            case .undecodablePayload:
                "Agent identity unavailable · the provider hook report could not be read"
            case .queueFull:
                "Agent report not accepted · the app’s report queue is full"
            case .appUnavailable:
                "Agent request unavailable · Agent Studio could not be reached"
            case .deadlineExceeded:
                "Agent request unavailable · the app did not reply in time"
            case .orderingStoreUnavailable:
                "Agent Line unavailable · restart Agent Studio"
            }
        return ActionSpec(label: text, helpText: "\(text) · \(reason.rawValue)", icon: .system(.flag))
    }

    static func sessionStatus(_ status: AgentSessionStatus) -> ActionSpec {
        let text: String
        let icon: CommandIcon
        switch status {
        case .needsYou(let reason):
            let word =
                switch reason {
                case .approval: "approval"
                case .question: "question"
                case .blocked: "blocked"
                }
            text = "Needs you · \(word)"
            icon = .system(.flag)
        case .failed(let failure):
            text = failure.category.isEmpty ? "Failed" : "Failed · \(failure.category)"
            icon = .system(.xmarkOctagon)
        case .working(let work):
            text = work == .monitoring ? "Working · monitoring" : "Working"
            icon = work == .monitoring ? .system(.circleDotted) : .system(.circleFill)
        case .idle(let state):
            let word =
                switch state {
                case .done: "done"
                case .ready: "ready"
                case .interrupted: "interrupted"
                case .ended: "ended"
                }
            text = "Idle · \(word)"
            icon = state == .done ? .system(.checkmark) : .system(.circle)
        case .unknown:
            text = ""
            icon = .system(.circle)
        }
        return ActionSpec(label: text, helpText: text, icon: icon)
    }
}
