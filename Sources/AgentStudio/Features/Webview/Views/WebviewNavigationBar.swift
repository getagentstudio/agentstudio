import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI
import WebKit

/// Mini browser toolbar with back/forward/reload and URL bar.
struct WebviewNavigationBar: View {
    @Bindable var controller: WebviewPaneController
    let octiconLoader: OcticonLoader
    @State private var urlFieldText: String = ""
    @State private var tabPickerToggleGate = PopoverToggleGate()

    private var history: URLHistoryService { .shared }

    private var isCurrentPageFavorite: Bool {
        guard let url = controller.url, url.scheme != "about" else { return false }
        return history.isFavorite(url: url)
    }

    var body: some View {
        HStack(spacing: AppStyles.WorkspaceFocus.Webview.navigationControlsSpacing) {
            navigationButtons
            urlField
            progressIndicator
        }
        .padding(.horizontal, AppStyles.WorkspaceFocus.Webview.navigationBarHorizontalPadding)
        .frame(height: AppStyles.WorkspaceFocus.Webview.navigationBarHeight)
        .background(.ultraThinMaterial)
        .onChange(of: controller.url) { _, newURL in
            urlFieldText = newURL?.absoluteString ?? ""
        }
        .onAppear {
            urlFieldText = controller.url?.absoluteString ?? ""
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: AppStyles.WorkspaceFocus.Webview.navigationControlsSpacing) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppStyles.General.Typography.textSm, weight: .medium))
            }
            .disabled(!controller.canGoBack)
            .buttonStyle(.plain)
            .foregroundStyle(controller.canGoBack ? .primary : .quaternary)
            .keyboardShortcut("[", modifiers: .command)
            .help(LocalActionSpec.browserBack.actionSpec.helpText)

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppStyles.General.Typography.textSm, weight: .medium))
            }
            .disabled(!controller.canGoForward)
            .buttonStyle(.plain)
            .foregroundStyle(controller.canGoForward ? .primary : .quaternary)
            .keyboardShortcut("]", modifiers: .command)
            .help(LocalActionSpec.browserForward.actionSpec.helpText)

            if controller.isLoading {
                Button {
                    controller.stopLoading()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(LocalActionSpec.browserStop.actionSpec.helpText)
            } else {
                Button {
                    controller.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .help(LocalActionSpec.browserReload.actionSpec.helpText)
            }

            Button {
                controller.goHome()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: AppStyles.General.Typography.textXs, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help(LocalActionSpec.browserHome.actionSpec.helpText)

            favoriteButton

            tabPickerButton
        }
    }

    // MARK: - Tab Picker

    private var tabPickerButton: some View {
        let spec = AppCommand.showBrowserTabs.definition
        return Button(action: toggleTabPicker) {
            spec.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.General.Typography.textSm)
        }
        .buttonStyle(.plain)
        .foregroundStyle(controller.isTabPickerPresented ? .primary : .secondary)
        .accessibilityLabel(spec.label)
        .controlHelp(spec.controlTooltipRenderValue())
        .modifier(
            WebviewTabPickerPopover(
                controller: controller, octiconLoader: octiconLoader, toggleGate: tabPickerToggleGate))
    }

    /// Opens through the picker's command; a click that just closed the
    /// popover from outside doesn't open it again.
    private func toggleTabPicker() {
        var isPresented = controller.isTabPickerPresented
        tabPickerToggleGate.toggle(isPresented: &isPresented)
        guard isPresented != controller.isTabPickerPresented else { return }
        if isPresented {
            controller.runPaneCommand?(.showBrowserTabs)
        } else {
            controller.isTabPickerPresented = false
        }
    }

    // MARK: - URL Field

    private var urlField: some View {
        HStack(spacing: 4) {
            SelectAllTextField(
                placeholder: "Enter URL",
                text: $urlFieldText,
                onSubmit: {
                    controller.navigate(to: urlFieldText)
                }
            )

            Button {
                controller.navigate(to: urlFieldText)
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: AppStyles.General.Typography.textLg))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppStyles.WorkspaceFocus.Webview.navigationFieldHorizontalPadding)
        .padding(.vertical, AppStyles.WorkspaceFocus.Webview.navigationFieldVerticalPadding)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: AppStyles.WorkspaceFocus.Webview.navigationFieldCornerRadius))
    }

    // MARK: - Favorite

    @ViewBuilder
    private var favoriteButton: some View {
        if let url = controller.url, url.scheme != "about" {
            Divider().frame(height: 16)

            Button {
                if isCurrentPageFavorite {
                    history.removeFavorite(url: url)
                } else {
                    let displayTitle = controller.title.isEmpty ? (url.host() ?? "Web") : controller.title
                    history.addFavorite(url: url, title: displayTitle)
                }
            } label: {
                Image(systemName: isCurrentPageFavorite ? "star.fill" : "star")
                    .font(.system(size: AppStyles.General.Typography.textSm, weight: .medium))
                    .foregroundStyle(isCurrentPageFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)
            .help(
                isCurrentPageFavorite
                    ? LocalActionSpec.browserRemoveFavorite.actionSpec.helpText
                    : LocalActionSpec.browserAddFavorite.actionSpec.helpText
            )
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressIndicator: some View {
        if controller.isLoading {
            ProgressView(value: controller.estimatedProgress)
                .progressViewStyle(.linear)
                .frame(width: 60)
        }
    }
}
