import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import Foundation

package struct RepoExplorerPaneContextLine: Equatable, Sendable {
    package let text: String
    package let icon: CommandIcon
    package let tooltip: ControlTooltipRenderValue
    package let tone: PaneContextChipTone
    package let glyphMotion: PaneLineGlyphMotion
    package let ageText: String?

    package static func agent(_ line: AgentLineDetail, now: Date) -> Self {
        let spec = LocalActionSpec.showPaneAgentLine.actionSpec
        return Self(
            text: line.summary, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "showPaneAgentLine")),
            tone: .neutral, glyphMotion: .still,
            ageText: PaneContextPresentationRules.agentLineAge(referenceDate: line.updatedAt, now: now))
    }
    package static func nextMessageAgeChangeDate(_ line: AgentLineDetail, now: Date) -> Date {
        PaneContextPresentationRules.age(referenceDate: line.updatedAt, now: now).nextChange
    }

    package static func connection(_ reason: AgentConnectionRefusalReason) -> Self {
        let spec = LocalActionSpec.paneAgentConnectionIssue(reason).actionSpec
        return Self(
            text: spec.label, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(
                provenance: .localAction(rawValue: "paneAgentConnectionIssue"), textOverride: spec.helpText),
            tone: .warning, glyphMotion: .still, ageText: nil)
    }

    package static func session(_ status: AgentSessionStatus) -> Self? {
        guard let line = PaneContextPresentationRules.statusLine(for: status) else { return nil }
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
            text: line.text, icon: spec.icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "paneSessionStatus")),
            tone: tone, glyphMotion: glyphMotion, ageText: nil)
    }

    package static func status(_ line: StatusLine, presentation: PaneAgentStatusPresentation?) -> Self? {
        let source: AgentSessionStatus =
            switch line.kind {
            case .needsYou: .needsYou(presentation?.compactPrompt?.reason ?? .blocked)
            case .working: .working(.active)
            case .monitoring: .working(.monitoring)
            case .failed: presentation?.status ?? .failed(.init(category: ""))
            case .idle: presentation?.status ?? .idle(.ready)
            }
        guard let rendered = session(source) else { return nil }
        let spec = LocalActionSpec.paneSessionStatus(source).actionSpec
        return Self(
            text: line.text, icon: rendered.icon,
            tooltip: spec.controlTooltipRenderValue(
                provenance: .localAction(rawValue: "paneSessionStatus"), textOverride: line.text),
            tone: rendered.tone, glyphMotion: rendered.glyphMotion, ageText: nil)
    }
}
