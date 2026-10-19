/// Claude Code 2.1.303 exposes `CLAUDE_CODE_SESSION_KIND=bg` on background hosts
/// and a nonempty `CLAUDE_JOB_DIR` to their hooks and shell tools. This is
/// undocumented behavior observed 2026-10-18; recheck both when Claude changes.
/// Such sessions inherit a pane environment without being attached to that pane.
enum PaneSessionReportingPolicy {
    static func isBackgroundSession(environment: [String: String]) -> Bool {
        environment["CLAUDE_CODE_SESSION_KIND"] == "bg"
            || environment["CLAUDE_JOB_DIR"].map { !$0.isEmpty } == true
    }

    static func isPaneReportingMethod(_ command: String) -> Bool {
        let method = PaneCLIVerb(rawValue: command)?.methodName ?? command
        switch method {
        case "pane.message.send", "pane.message.ask", "pane.line.set", "pane.title.set", "pane.writer.claimEpoch",
            "session.event", "session.status", "session.refusal":
            return true
        default:
            return false
        }
    }
}
