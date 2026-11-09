import Foundation

package struct RuntimeCommandEnvelope: Sendable {
    package let commandId: UUID
    package let correlationId: UUID?
    package let targetPaneId: PaneId
    package let command: PaneRuntimeCommand
    package let timestamp: ContinuousClock.Instant

    package init(
        commandId: UUID,
        correlationId: UUID?,
        targetPaneId: PaneId,
        command: PaneRuntimeCommand,
        timestamp: ContinuousClock.Instant
    ) {
        self.commandId = commandId
        self.correlationId = correlationId
        self.targetPaneId = targetPaneId
        self.command = command
        self.timestamp = timestamp
    }
}

package protocol RuntimeKindCommand: Sendable {}

package enum PaneRuntimeCommand: Sendable {
    case activate
    case deactivate
    case prepareForClose
    case requestSnapshot
    case terminal(TerminalCommand)
    case browser(BrowserCommand)
    case diff(DiffCommand)
    case editor(EditorCommand)
    case plugin(any RuntimeKindCommand)
}

extension PaneRuntimeCommand {
    package var requiredCapability: PaneCapability {
        switch self {
        case .terminal:
            return .input
        case .browser:
            return .navigation
        case .diff:
            return .diffReview
        case .editor:
            return .editorActions
        case .plugin(let pluginCommand):
            return .plugin(String(describing: type(of: pluginCommand)))
        case .activate, .deactivate, .prepareForClose, .requestSnapshot:
            return .input
        }
    }
}

package enum TerminalCommand: Sendable {
    case sendInput(String)
    case resize(cols: Int, rows: Int)
    case clearScrollback
    case scrollToBottom
    case scrollPageFractional(fraction: Double)
    case jumpToPrompt(delta: Int)
}

package enum BrowserCommand: Sendable {
    case navigate(url: URL)
    case reload(hard: Bool)
    case stop
    /// Opens the browser pane's tab picker.
    case showTabs
}

package enum DiffCommand: Sendable {
    case loadDiff(DiffArtifact)
}

package enum EditorCommand: Sendable {
    case openFile(path: String, line: Int?, column: Int?)
    case save
    case revert
}
