import AgentStudioCore

package enum SessionsPaneViewedPolicy {
    package static func isPersonFocus(_ trigger: PaneFocusTrigger) -> Bool {
        switch trigger {
        case .contentClick, .tabClick, .keyboard: true
        case .drawer(.selectPane), .drawer(.contentClick): true
        case .drawer(.toggle), .mode, .refocusRequest, .command: false
        }
    }
}
