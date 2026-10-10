typealias TerminalActivityDeadlineScope = String
enum TerminalActivityProjectorFact { case deadlineRegistered }
typealias TerminalActivityProjectorFactSink =
    (TerminalActivityDeadlineScope, TerminalActivityProjectorFact) -> Void

actor TerminalActivityProjector {
    let factSink: TerminalActivityProjectorFactSink?
    var unseenDeadlineScopes: [String: TerminalActivityDeadlineScope] = [:]
    var unseenCloseTasks: [String: Task<Void, Never>] = [:]

    func scheduleUnseenClose(_ paneID: String) {
        let scope = TerminalActivityDeadlineScope()
        unseenDeadlineScopes[paneID] = scope
        unseenCloseTasks[paneID] = Task {
            await deadlineClockSleep()
            closeProductionWindow(paneID)
            factSink?(scope, .deadlineRegistered)
        }
    }

    private func deadlineClockSleep() async {}
    private func closeProductionWindow(_ paneID: String) {}
}
