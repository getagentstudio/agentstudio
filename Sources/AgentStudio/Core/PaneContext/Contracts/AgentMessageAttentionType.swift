package enum AgentMessageAttentionType: Sendable, Equatable {
    case needsApproval
    case needsReply
    case attention
    case informational

    package static func classify(
        shape: AgentMessageShape,
        importance: MessageImportance
    ) -> Self {
        let kind: ClassificationShape
        switch shape {
        case .ask(_, _, .blocking, _): kind = .blockingAsk
        case .ask(_, _, .nonBlocking, _): kind = .nonBlockingAsk
        case .notice: kind = .notice
        }
        return classify(kind: kind, importance: importance)
    }

    enum ClassificationShape: Sendable {
        case blockingAsk
        case nonBlockingAsk
        case notice
    }

    static func classify(kind: ClassificationShape, importance: MessageImportance) -> Self {
        switch kind {
        case .blockingAsk: .needsApproval
        case .nonBlockingAsk: .needsReply
        case .notice:
            switch importance {
            case .attention, .failure: .attention
            case .info, .done: .informational
            }
        }
    }

}
