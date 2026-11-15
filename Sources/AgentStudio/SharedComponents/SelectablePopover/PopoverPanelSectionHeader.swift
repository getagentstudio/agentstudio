import AgentStudioInfrastructure
import SwiftUI

package struct PopoverPanelSectionHeader<Icon: View>: View {
    package enum Variant {
        case configuration
        case content(count: Int?)
    }
    private let title: String
    private let variant: Variant
    private let showsIcon: Bool
    @ViewBuilder private let icon: () -> Icon

    package init(
        _ title: String, variant: Variant = .configuration, showsIcon: Bool = true,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.title = title
        self.variant = variant
        self.showsIcon = showsIcon
        self.icon = icon
    }

    package var body: some View {
        switch variant {
        case .configuration:
            HStack(spacing: AppStyles.General.Spacing.standard) {
                if showsIcon {
                    icon()
                        .frame(width: AppStyles.General.Icon.compact, height: AppStyles.General.Icon.compact)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: AppStyles.General.Typography.textSm, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, showsIcon ? AppStyles.General.Spacing.loose : 0)
            .accessibilityAddTraits(.isHeader)
        case .content(let count):
            HStack(alignment: .firstTextBaseline, spacing: AppStyles.General.Spacing.standard) {
                Text(title).font(.system(size: AppStyles.General.Typography.textBase, weight: .medium))
                    .foregroundStyle(.primary)
                if let count {
                    Text(String(count)).font(.system(size: AppStyles.General.Typography.textBase))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityAddTraits(.isHeader)
        }
    }
}

extension PopoverPanelSectionHeader where Icon == EmptyView {
    package init(_ title: String, variant: Variant = .configuration) {
        self.init(title, variant: variant, showsIcon: false) { EmptyView() }
    }
}
