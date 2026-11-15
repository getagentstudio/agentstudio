import Foundation

extension AppCommand {
    enum CommandBarGroupPriority {
        static let terminal = 1
        static let pane = 2
        static let focus = 3
        static let tab = 4
        static let repo = 5
        static let window = 6
        static let sidebar = 7
        static let inbox = 8
        static let webview = 9
        static let worktreeViewer = 10
        static let bridge = 11
        static let auth = 12
        static let agent = 13
        static let miscellaneous = 14
    }
}
