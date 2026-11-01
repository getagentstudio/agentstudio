import AgentStudioCore

enum PaneContextActionSnapshot: Sendable {
    case messages(PaneContextDetail?)
    case card
}
