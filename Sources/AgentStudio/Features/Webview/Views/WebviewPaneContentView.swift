import AgentStudioInfrastructure
import QuartzCore
import SwiftUI
import WebKit

/// Root SwiftUI view for a webview pane.
/// Shows the active browser tab: the new-tab page (favorites + recent) or its WebView.
struct WebviewPaneContentView: View {
    @Bindable var controller: WebviewPaneController

    private var isNewTabPage: Bool {
        controller.url == nil || controller.url?.scheme == "about"
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.showNavigation {
                WebviewNavigationBar(controller: controller)
                Divider()
            }

            activeTabContent
                .id(controller.activeTabId)
                .onAppear { reportCommittedTabView(controller.activeTabId) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            // With the navigation bar hidden, the picker attaches at the top of the pane.
            if !controller.showNavigation {
                Color.clear
                    .frame(width: 0, height: 0)
                    .modifier(
                        WebviewTabPickerPopover(controller: controller, toggleGate: nil))
            }
        }
        .onChange(of: controller.isLoading) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                controller.recordCurrentPage()
            }
        }
    }

    @ViewBuilder
    private var activeTabContent: some View {
        if isNewTabPage {
            WebviewNewTabView { url in
                controller.navigate(to: url.absoluteString)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WebView(controller.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The tab's view is mounted in this update; its frame is committed when
    /// the current Core Animation transaction completes.
    private func reportCommittedTabView(_ tabId: WebviewTabId) {
        let controller = self.controller
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                controller.tabViewCommitted(tabId)
            }
        }
    }
}
