import AgentStudioInfrastructure
import SwiftUI

package struct SidebarSearchField<FocusValue: Hashable>: View {
    @Binding var text: String

    let placeholder: String
    let focusedField: FocusState<FocusValue?>.Binding
    let focusValue: FocusValue
    let clearHelp: String?
    let shortcutDisplay: ShortcutDisplayText?
    let shortcutStyle: SidebarShortcutHint.Style
    let onSubmit: () -> Void
    let onExit: () -> Void
    let onDownArrow: (() -> KeyPress.Result)?

    package init(
        placeholder: String,
        text: Binding<String>,
        focusedField: FocusState<FocusValue?>.Binding,
        focusValue: FocusValue,
        clearHelp: String? = nil,
        shortcutDisplay: ShortcutDisplayText? = nil,
        shortcutStyle: SidebarShortcutHint.Style = .toolbarStamp,
        onSubmit: @escaping () -> Void = {},
        onExit: @escaping () -> Void = {},
        onDownArrow: (() -> KeyPress.Result)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.focusedField = focusedField
        self.focusValue = focusValue
        self.clearHelp = clearHelp
        self.shortcutDisplay = shortcutDisplay
        self.shortcutStyle = shortcutStyle
        self.onSubmit = onSubmit
        self.onExit = onExit
        self.onDownArrow = onDownArrow
    }

    package var body: some View {
        let trailingActionVisibility = SidebarTrailingActionVisibility(
            shortcutDisplay: shortcutDisplay
        )
        HStack(spacing: AppStyles.Shell.Sidebar.SearchField.contentSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppStyles.Shell.Sidebar.SearchField.iconSize))
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: AppStyles.Shell.Sidebar.SearchField.textSize))
                .foregroundStyle(.primary)
                .focused(focusedField, equals: focusValue)
                .onSubmit {
                    onSubmit()
                }
                .onExitCommand {
                    onExit()
                }
                .onKeyPress(.downArrow) {
                    onDownArrow?() ?? .ignored
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppStyles.Shell.Sidebar.SearchField.textSize))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearHelp ?? "")
                .help(clearHelp ?? "")
                .opacity(trailingActionVisibility.opacity)
                .allowsHitTesting(trailingActionVisibility.allowsHitTesting)
                .accessibilityHidden(trailingActionVisibility.accessibilityHidden)
                .transition(
                    .opacity.animation(
                        .easeOut(duration: AppStyles.Shell.Sidebar.SearchField.clearTransitionDuration)
                    )
                )
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppStyles.Shell.Sidebar.SearchField.horizontalPadding)
        .padding(.vertical, AppStyles.Shell.Sidebar.SearchField.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: AppStyles.Shell.Sidebar.SearchField.cornerRadius)
                .fill(Color.primary.opacity(AppStyles.Shell.Sidebar.SearchField.backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyles.Shell.Sidebar.SearchField.cornerRadius)
                .strokeBorder(
                    Color.primary.opacity(AppStyles.Shell.Sidebar.SearchField.borderOpacity),
                    lineWidth: AppStyles.Shell.Sidebar.SearchField.borderWidth
                )
        )
        .contentShape(
            RoundedRectangle(cornerRadius: AppStyles.Shell.Sidebar.SearchField.cornerRadius)
        )
        .sidebarShortcutHint(
            shortcutDisplay,
            style: shortcutStyle,
            alignment: .trailing,
            offset: CGSize(
                width: -AppStyles.Shell.Sidebar.KeyboardHint.controlTrailingInset,
                height: 0
            )
        )
        .onTapGesture {
            focusedField.wrappedValue = focusValue
        }
    }

}
