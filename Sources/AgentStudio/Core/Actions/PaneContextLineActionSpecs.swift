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
            icon = .system(.circleFill)
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
