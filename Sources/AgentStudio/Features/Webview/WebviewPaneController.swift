import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation
import WebKit
import os

/// Per-pane browser controller. Each webview pane owns one controller
/// that manages a single WebPage and exposes observable navigation state
/// for SwiftUI views.
@Observable
@MainActor
package final class WebviewPaneController {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "WebviewPaneController")

    // MARK: - State

    let paneId: UUID
    let runtime: WebviewRuntime
    private(set) var page: WebPage
    var showNavigation: Bool
    var isFindPresented: Bool = false
    private let userContentController: WKUserContentController
    private var managementScript: WKUserScript
    private(set) var isContentInteractionEnabled: Bool
    private var interactionApplyTask: Task<Void, Never>?

    /// Called when a page finishes loading with the new display title.
    /// Wired by the coordinator to sync pane metadata in the store.
    package var onTitleChange: ((String) -> Void)?

    // MARK: - Shared Configuration

    /// All webview panes share the same persistent data store (cookies, local storage).
    static let sharedWebsiteDataStore: WKWebsiteDataStore = {
        if let identifier = AppStorageIdentity.current.websiteDataStoreIdentifier() {
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
        return .default()
    }()

    // MARK: - Derived State

    var url: URL? { page.url }
    var title: String { page.title }
    var isLoading: Bool { page.isLoading }
    var estimatedProgress: Double { page.estimatedProgress }

    var canGoBack: Bool {
        !page.backForwardList.backList.isEmpty
    }

    var canGoForward: Bool {
        !page.backForwardList.forwardList.isEmpty
    }

    // MARK: - Init

    init(paneId: UUID, state: WebviewState) {
        self.paneId = paneId
        let runtimePaneId = PaneId(existingUUID: paneId)
        let runtimeMetadata = Self.makeDefaultRuntimeMetadata(
            paneId: runtimePaneId,
            state: state
        )
        self.runtime = WebviewRuntime(
            paneId: runtimePaneId,
            metadata: runtimeMetadata
        )
        self.showNavigation = state.showNavigation
        let blockInteraction = atom(\.managementLayer).isActive
        let initialManagementScript = WebInteractionManagementScript.makeUserScript(
            blockInteraction: blockInteraction
        )
        self.managementScript = initialManagementScript
        self.isContentInteractionEnabled = !blockInteraction

        var config = WebPage.Configuration()
        config.websiteDataStore = Self.sharedWebsiteDataStore
        config.userContentController.addUserScript(initialManagementScript)
        self.userContentController = config.userContentController

        self.page = WebPage(
            configuration: config,
            navigationDecider: WebviewNavigationDecider(),
            dialogPresenter: WebviewDialogHandler()
        )
        runtime.commandHandler = self
        if !runtime.transitionToReady() {
            Self.logger.error(
                "Failed to transition webview runtime to ready for pane \(paneId.uuidString, privacy: .public)"
            )
        }
        if state.url.scheme != "about" {
            _ = page.load(state.url)
        }
    }

    // MARK: - Content Interaction

    /// Called by the pane view when management layer toggles. Keeps both the currently
    /// loaded document and future navigations in sync with the interaction state.
    func setWebContentInteractionEnabled(_ enabled: Bool) {
        let didChange = enabled != isContentInteractionEnabled
        isContentInteractionEnabled = enabled

        if didChange {
            refreshPersistentManagementScript()
        }
        applyCurrentDocumentInteractionState()
    }

    private func refreshPersistentManagementScript() {
        userContentController.removeAllUserScripts()
        managementScript = WebInteractionManagementScript.makeUserScript(
            blockInteraction: !isContentInteractionEnabled
        )
        userContentController.addUserScript(managementScript)
    }

    private func applyCurrentDocumentInteractionState() {
        let script = WebInteractionManagementScript.makeRuntimeToggleSource(
            blockInteraction: !isContentInteractionEnabled
        )
        interactionApplyTask?.cancel()
        let page = self.page
        let shouldReapplyAfterLoad = page.isLoading

        interactionApplyTask = Task { @MainActor in
            do {
                _ = try await page.callJavaScript(script)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.debug(
                    "Failed to apply interaction script for pane \(self.paneId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            guard shouldReapplyAfterLoad else { return }

            let deadline = ContinuousClock.now + .seconds(2)
            while page.isLoading, ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                await Task.yield()
            }

            if Task.isCancelled { return }
            do {
                _ = try await page.callJavaScript(script)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.debug(
                    "Failed to reapply interaction script for pane \(self.paneId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Navigation

    func goBack() {
        guard let backItem = page.backForwardList.backList.last else { return }
        _ = page.load(backItem)
    }

    func goForward() {
        guard let forwardItem = page.backForwardList.forwardList.first else { return }
        _ = page.load(forwardItem)
    }

    func reload() {
        _ = page.reload()
    }

    func stopLoading() {
        page.stopLoading()
    }

    /// Navigate to the new tab page (about:blank).
    func goHome() {
        _ = page.load(URL(string: "about:blank")!)
    }

    /// Navigate to a URL string. Auto-prepends https:// for scheme-less input.
    func navigate(to urlString: String) {
        let normalized = Self.normalizeURLString(urlString)
        guard let url = URL(string: normalized) else { return }
        _ = page.load(url)
    }

    // MARK: - Persistence

    /// Capture current state back to serializable model.
    func snapshot() -> WebviewState {
        WebviewState(
            url: page.url ?? URL(string: "about:blank")!,
            title: page.title,
            showNavigation: showNavigation
        )
    }

    // MARK: - History

    /// Record the current page's URL and title in the URL history service,
    /// and notify the coordinator to sync the pane title in the store.
    func recordCurrentPage() {
        guard let url = page.url,
            !page.isLoading
        else { return }
        let displayTitle = page.title.isEmpty ? (url.host() ?? "Web") : page.title
        URLHistoryService.shared.record(url: url, title: displayTitle)
        onTitleChange?(displayTitle)
        runtime.ingestBrowserEvent(
            .navigationCompleted(url: url, statusCode: nil)
        )
        runtime.ingestBrowserEvent(
            .pageLoaded(url: url)
        )
    }

    // MARK: - URL Normalization

    static func normalizeURLString(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("about:") || trimmed.hasPrefix("data:") { return trimmed }
        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.") || trimmed.hasPrefix("[::1]") {
            return "http://\(trimmed)"
        }
        return "https://\(trimmed)"
    }

    private static func makeDefaultRuntimeMetadata(
        paneId: PaneId,
        state: WebviewState
    ) -> PaneMetadata {
        let title = state.title.isEmpty ? "Web" : state.title
        return PaneMetadata(
            paneId: paneId,
            contentType: .browser,
            title: title
        )
    }
}

extension WebviewPaneController: WebviewRuntimeCommandHandling {
    func handleBrowserCommand(_ command: BrowserCommand) -> Bool {
        switch command {
        case .navigate(let url):
            _ = page.load(url)
            return true
        case .reload:
            _ = page.reload()
            return true
        case .stop:
            page.stopLoading()
            return true
        }
    }
}
