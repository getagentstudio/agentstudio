import AgentStudioCore

struct PaneContextSelectedAsk: Sendable, Equatable {
    let key: PaneContextMessageKey
    let detail: AgentMessageDetail
    let generation: UInt64
}

enum PaneContextActionSnapshot: Sendable {
    case messages(PaneContextDetail?)
    case selectedAsk(PaneContextSelectedAsk?)
}
