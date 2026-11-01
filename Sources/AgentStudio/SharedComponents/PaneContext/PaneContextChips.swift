import AgentStudioInfrastructure
import SwiftUI

extension KindChipModel.Kind {
    @MainActor package var style: SidebarChip.Style {
        switch self {
        case .failure: .danger
        case .needsYou: .warning
        case .done: .success
        case .info: .neutral
        }
    }
}

package struct PaneMessageKindChip: View {
    let model: KindChipModel
    let control: PaneContextControlModel
    let octiconLoader: OcticonLoader
    let onOpen: @MainActor () -> Void

    package init(
        model: KindChipModel, control: PaneContextControlModel, octiconLoader: OcticonLoader,
        onOpen: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.control = control
        self.octiconLoader = octiconLoader
        self.onOpen = onOpen
    }

    package var body: some View {
        Button(action: onOpen) {
            chipLabel
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

    /// The same plain button's intrinsic size, without effects or an accessibility bridge.
    package var minimumSizeContent: some View {
        Button(action: {}, label: { chipLabel }).buttonStyle(.plain).accessibilityHidden(true)
    }

    private var chipLabel: some View {
        Self.label(model: model, control: control, octiconLoader: octiconLoader)
    }

    package static func label(
        model: KindChipModel, control: PaneContextControlModel, octiconLoader: OcticonLoader
    ) -> some View {
        SidebarChip(
            icon: control.icon.chipIcon, octiconLoader: octiconLoader,
            text: String(model.count), style: model.kind.style)
    }
}

extension PaneContextChipTone {
    @MainActor package var foregroundColor: Color { style.foreground }

    @MainActor fileprivate var style: SidebarChip.Style {
        switch self {
        case .neutral: .neutral
        case .accent: .accent(AppStyles.General.Accent.primaryColor)
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .danger: .danger
        }
    }
}
extension PaneContextControlModel.Icon {
    @MainActor var chipIcon: SidebarChip.Icon {
        switch self {
        case .system(let name): .system(name)
        case .octicon(let name): .octicon(name)
        }
    }
}
