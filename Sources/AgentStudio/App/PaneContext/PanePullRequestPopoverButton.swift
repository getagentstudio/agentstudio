import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI

struct PanePullRequestPopoverButton: View {
    let action: PaneSurfaceToolbarAction
    let octiconLoader: OcticonLoader
    var body: some View {
        ToolbarActionButton(
            presentation: .init(
                icon: icon, label: action.state.label, identifier: action.state.accessibilityIdentifier,
                tooltip: action.state.tooltip, isEnabled: action.state.isEnabled,
                content: .icon(label: action.state.visibleLabel), selection: .normal, iconTone: tone),
            octiconLoader: octiconLoader, action: action.perform)
    }
    private var icon: ToolbarActionButtonPresentation.Icon {
        switch action.state.icon {
        case .system(let value): .system(value.rawValue)
        case .octicon(let value): .octicon(value.rawValue)
        }
    }
    private var tone: ToolbarActionButtonPresentation.IconTone {
        switch action.state.iconStatusTone {
        case .success?: .success
        case .warning?: .warning
        case .danger?: .danger
        case nil: .standard
        }
    }
}
