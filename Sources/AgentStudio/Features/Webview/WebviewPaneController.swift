import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Observation
import WebKit
import os

/// Per-pane browser controller. A browser pane holds ordered browser tabs
/// through a pure `WebviewTabList`, shows the active tab's page, and keeps
/// each tab's page loaded from its first selection until it closes.
@Observable
@MainActor
package final class WebviewPaneController {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "WebviewPaneController")

    // MARK: - State

    let paneId: UUID
    let runtime: WebviewRuntime
    private(set) var tabList: WebviewTabList
    /// Pages for tabs selected at least once and not closed since.
    private var loadedTabPages: [WebviewTabId: WebviewTabPage] = [:]
    var showNavigation: Bool
    var isFindPresented: Bool = false
    var isTabPickerPresented: Bool = false
    private(set) var isContentInteractionEnabled: Bool
    @ObservationIgnored private let tabPageFactory: any WebviewTabPageFactory
    @ObservationIgnored private let tabSwitchProbe: AgentStudioInteractionPerformanceProbe?
    @ObservationIgnored private var pendingTabSwitch: PendingTabSwitch?

    private struct PendingTabSwitch {
        let tabId: WebviewTabId
        let correlationId: UUID
    }

    /// Called when a page finishes loading with the new display title.
    /// Wired by the coordinator to sync pane metadata in the store.
    package var onTitleChange: ((String) -> Void)?

    /// Runs a pane-targeted `AppCommand` for this pane through the app's
    /// command dispatcher. Wired by the coordinator.
    package var runPaneCommand: ((AppCommand) -> Void)?

    /// Called when the person closes the last tab. Wired by the coordinator to
    /// close the browser pane through the existing close action.
    package var onLastTabClosed: (() -> Void)?

    // MARK: - Derived State

    /// The active tab's page. Every mutation that changes the active tab loads
    /// its page in the same turn, so this lookup always succeeds.
    var activeTabPage: WebviewTabPage {
        guard let loaded = loadedTabPages[tabList.activeTabId] else {
            preconditionFailure("WebviewPaneController active tab has no loaded page")
        }
        return loaded
    }

    var page: WebPage { activeTabPage.page }
    var loadedTabCount: Int { loadedTabPages.count }
    var activeTabId: WebviewTabId { tabList.activeTabId }
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

    convenience init(
        paneId: UUID,
        state: WebviewState,
        tabPageFactory: any WebviewTabPageFactory = WebKitWebviewTabPageFactory(),
        tabSwitchProbe: AgentStudioInteractionPerformanceProbe? = nil
    ) {
        self.init(
            paneId: paneId,
            tabList: WebviewTabList(firstTab: WebviewTab(id: .generate(), url: state.url, title: state.title)),
            showNavigation: state.showNavigation,
            tabPageFactory: tabPageFactory,
            tabSwitchProbe: tabSwitchProbe
        )
    }

    /// Only the active tab gets a page now; every other tab gets one when it is
    /// first selected.
    init(
        paneId: UUID,
        tabList: WebviewTabList,
        showNavigation: Bool,
        tabPageFactory: any WebviewTabPageFactory = WebKitWebviewTabPageFactory(),
        tabSwitchProbe: AgentStudioInteractionPerformanceProbe? = nil
    ) {
        self.paneId = paneId
        let runtimePaneId = PaneId(existingUUID: paneId)
        self.runtime = WebviewRuntime(
            paneId: runtimePaneId,
            metadata: Self.makeDefaultRuntimeMetadata(paneId: runtimePaneId, title: tabList.activeTab.title)
        )
        self.tabList = tabList
        self.showNavigation = showNavigation
        self.isContentInteractionEnabled = !atom(\.managementLayer).isActive
        self.tabPageFactory = tabPageFactory
        self.tabSwitchProbe = tabSwitchProbe

        runtime.commandHandler = self
        if !runtime.transitionToReady() {
            Self.logger.error(
                "Failed to transition webview runtime to ready for pane \(paneId.uuidString, privacy: .public)"
            )
        }
        showActiveTabLoadingOnFirstSelection()
    }

    // MARK: - Tabs

    /// Opens a page as the active tab. A tab already showing the page is made
    /// active and loads the page again, so rewritten content shows; no tab is added.
    @discardableResult
    func openPage(_ url: URL, title: String = "") -> WebviewTabOpenResult {
        let result = tabList.open(BrowserPageAddress(url: url), title: title)
        _ = ensureActiveTabPage().page.load(url)
        return result
    }

    /// Makes an open tab active, loading its page on first selection. Starts
    /// the tab-switch timing that `tabViewCommitted(_:)` settles.
    func selectTab(_ id: WebviewTabId) {
        guard id != tabList.activeTabId, tabList.select(id) else { return }
        if let tabSwitchProbe {
            let correlationId = UUIDv7.generate()
            tabSwitchProbe.beginInteraction(.browserTabSwitch, correlationId: correlationId)
            pendingTabSwitch = PendingTabSwitch(tabId: id, correlationId: correlationId)
        }
        showActiveTabLoadingOnFirstSelection()
    }

    /// Called by the pane view once the Core Animation transaction that mounts
    /// a tab's view has committed. Settles the pending switch to that tab.
    func tabViewCommitted(_ id: WebviewTabId) {
        guard let pendingTabSwitch, pendingTabSwitch.tabId == id else { return }
        self.pendingTabSwitch = nil
        tabSwitchProbe?.settleInteraction(correlationId: pendingTabSwitch.correlationId)
    }

    /// Closes one tab into Recently Closed. Closing the last tab asks the
    /// coordinator to close the browser pane.
    func closeTab(_ id: WebviewTabId) {
        switch tabList.close(id) {
        case .notOpen:
            return
        case .closedLast:
            onLastTabClosed?()
        case .closed:
            releasePage(for: id)
            showActiveTabLoadingOnFirstSelection()
        }
    }

    /// Reopens a Recently Closed tab as the active tab, with a new page.
    func reopenTab(_ id: WebviewClosedTabId) {
        guard tabList.reopen(id) != nil else { return }
        showActiveTabLoadingOnFirstSelection()
    }

    private func showActiveTabLoadingOnFirstSelection() {
        let wasLoaded = loadedTabPages[tabList.activeTabId] != nil
        let tabPage = ensureActiveTabPage()
        if !wasLoaded {
            loadIfWeb(tabList.activeTab.url, in: tabPage)
        }
    }

    /// Returns the active tab's page, creating it through the factory on the
    /// tab's first selection. Never loads an address.
    private func ensureActiveTabPage() -> WebviewTabPage {
        let activeId = tabList.activeTabId
        if let loaded = loadedTabPages[activeId] { return loaded }
        let created = tabPageFactory.makeTabPage(
            contentInteractionEnabled: isContentInteractionEnabled,
            onCommittedNavigation: { [weak self] url, title in
                self?.tabList.update(activeId, url: url, title: title)
            }
        )
        loadedTabPages[activeId] = created
        return created
    }

    /// Ends every loaded tab's observation and interaction work when the pane
    /// is retired, so no task keeps a closed pane's pages alive.
    func retireAllTabPages() {
        for tabPage in loadedTabPages.values {
            tabPage.close()
        }
    }

    private func releasePage(for id: WebviewTabId) {
        guard let released = loadedTabPages.removeValue(forKey: id) else { return }
        released.close()
    }

    private func loadIfWeb(_ url: URL, in tabPage: WebviewTabPage) {
        guard url.scheme != "about" else { return }
        _ = tabPage.page.load(url)
    }

    // MARK: - Content Interaction

    /// Called by the pane view when the management layer toggles. Applies to
    /// every loaded tab, so an inactive tab can't keep interaction enabled and
    /// then become active; tabs loaded later start from this state.
    func setWebContentInteractionEnabled(_ enabled: Bool) {
        isContentInteractionEnabled = enabled
        for tabPage in loadedTabPages.values {
            tabPage.setContentInteractionEnabled(enabled)
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
        title: String
    ) -> PaneMetadata {
        PaneMetadata(
            paneId: paneId,
            contentType: .browser,
            title: title.isEmpty ? "Web" : title
        )
    }
}

extension WebviewPaneController: WebviewRuntimeCommandHandling {
    /// Runtime commands act on the active tab's page.
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
        case .showTabs:
            isTabPickerPresented = true
            return true
        }
    }
}
