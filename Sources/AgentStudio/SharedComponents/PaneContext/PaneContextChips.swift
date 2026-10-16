import AgentStudioInfrastructure
import SwiftUI

extension PaneContextChipTone {
    @MainActor fileprivate var style: SidebarChip.Style {
        switch self {
        case .neutral: .neutral
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .danger
        }
    }
}
extension PaneContextControlModel.Icon {
    @MainActor fileprivate var chipIcon: SidebarChip.Icon {
        switch self {
        case .system(let name): .system(name)
        case .octicon(let name): .octicon(name)
        }
    }
}

package struct MessagesChip: View {
    private let count: Int
    private let tone: PaneContextChipTone
    private let control: PaneContextControlModel
    private let octiconLoader: OcticonLoader
    private let onOpen: @MainActor () -> Void
    package init(
        count: Int, tone: PaneContextChipTone, control: PaneContextControlModel,
        octiconLoader: OcticonLoader, onOpen: @escaping @MainActor () -> Void
    ) {
        self.count = count
        self.tone = tone
        self.control = control
        self.octiconLoader = octiconLoader
        self.onOpen = onOpen
    }
    package var body: some View {
        Button(action: onOpen) {
            SidebarChip(
                icon: control.icon.chipIcon, octiconLoader: octiconLoader,
                text: String(count), style: tone.style)
        }
        .buttonStyle(.plain)
        .controlHelp(control.tooltip)
        .accessibilityHidden(true)
        .background {
            AccessibilityPressBridge(
                identifier: control.identifier, label: control.label,
                help: control.tooltip.text, action: onOpen)
        }
    }
}
