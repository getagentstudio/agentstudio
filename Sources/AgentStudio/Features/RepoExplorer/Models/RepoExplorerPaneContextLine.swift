import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents

package enum PaneLineGlyphMotion: Equatable, Sendable {
    case still
    case opacityPulse
    case rotate
}

package struct RepoExplorerPaneContextLine: Equatable, Sendable {
    package let text: String
    package let icon: CommandIcon
    package let tooltip: ControlTooltipRenderValue
    package let tone: PaneContextChipTone
    package let glyphMotion: PaneLineGlyphMotion
    package let stale: Bool

    static func agent(_ line: AgentLineDetail) -> Self {
        let spec = LocalActionSpec.showPaneAgentLine(line.work).actionSpec
        let tone: PaneContextChipTone =
            switch line.work {
            case .working: .accent
            case .monitoring: .info
            case .blockedOnYou: .warning
            case .done: .neutral
            case .failed: .danger
            }
        let glyphMotion: PaneLineGlyphMotion =
            switch line.work {
            case .working: .opacityPulse
            case .monitoring: .rotate
            case .blockedOnYou, .done, .failed: .still
            }
        return Self(
            text: line.summary, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "showPaneAgentLine")),
            tone: tone, glyphMotion: glyphMotion, stale: line.stale)
    }
    package static func connection(_ reason: AgentConnectionRefusalReason) -> Self {
        let spec = LocalActionSpec.paneAgentConnectionIssue(reason).actionSpec
        return Self(
            text: spec.label, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(
                provenance: .localAction(rawValue: "paneAgentConnectionIssue"), textOverride: spec.helpText),
            tone: .warning, glyphMotion: .still, stale: false)
    }

    package static func session(_ status: AgentSessionStatus) -> Self? {
        guard status != .unknown else { return nil }
        let spec = LocalActionSpec.paneSessionStatus(status).actionSpec
        let tone: PaneContextChipTone =
            switch status {
            case .needsYou: .warning
            case .failed: .danger
            case .working: .accent
            case .idle, .unknown: .neutral
            }
        let glyphMotion: PaneLineGlyphMotion =
            switch status {
            case .working(.active): .opacityPulse
            case .working(.monitoring): .rotate
            case .needsYou, .failed, .idle, .unknown: .still
            }
        return Self(
            text: spec.label, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "paneSessionStatus")),
            tone: tone, glyphMotion: glyphMotion, stale: false)
    }
}
