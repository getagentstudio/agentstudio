import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents

package struct RepoExplorerPaneContextLine: Equatable, Sendable {
    package let text: String
    package let icon: CommandIcon
    package let tooltip: ControlTooltipRenderValue
    package let tone: PaneContextChipTone
    package let stale: Bool

    static func agent(_ line: AgentLineDetail) -> Self {
        let spec = LocalActionSpec.showPaneAgentLine(line.work).actionSpec
        let tone: PaneContextChipTone =
            switch line.work {
            case .working: .success
            case .monitoring: .info
            case .blockedOnYou: .warning
            case .done: .neutral
            case .failed: .danger
            }
        return Self(
            text: line.summary, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "showPaneAgentLine")),
            tone: tone, stale: line.stale)
    }
    package static func connection(_ reason: AgentConnectionRefusalReason) -> Self {
        let spec = LocalActionSpec.paneAgentConnectionIssue(reason).actionSpec
        return Self(
            text: spec.label, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "paneAgentConnectionIssue")),
            tone: .warning, stale: false)
    }

    package static func session(_ status: AgentSessionStatus) -> Self? {
        guard status != .unknown else { return nil }
        let spec = LocalActionSpec.paneSessionStatus(status).actionSpec
        let tone: PaneContextChipTone =
            switch status {
            case .needsYou: .warning
            case .failed: .danger
            case .working: .success
            case .idle, .unknown: .neutral
            }
        return Self(
            text: spec.label, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "paneSessionStatus")),
            tone: tone, stale: false)
    }
}
